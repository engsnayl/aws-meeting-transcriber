#!/bin/bash
set -e

# Configuration
AWS_REGION="eu-west-1"
LAMBDA_ECR_REPO="whisper-lambda"
ECS_ECR_REPO="whisper-ecs"
LAMBDA_IMAGE_TAG="latest"
ECS_IMAGE_TAG="v1"

echo "==== AWS Meeting Transcriber Pipeline Deployment ===="
echo "Region: $AWS_REGION"

# Login to ECR
echo "Logging in to ECR..."
aws ecr get-login-password --region $AWS_REGION | docker login --username AWS --password-stdin "$(aws sts get-caller-identity --query Account --output text).dkr.ecr.$AWS_REGION.amazonaws.com"

# Build and push Lambda container
echo "Building Lambda container..."
cd /c/Users/naylo/Documents/lambda_container_build
docker build -t "$LAMBDA_ECR_REPO:$LAMBDA_IMAGE_TAG" -f Dockerfile .

# Check if Lambda repository exists, create if not
aws ecr describe-repositories --repository-names $LAMBDA_ECR_REPO --region $AWS_REGION || \
    aws ecr create-repository --repository-name $LAMBDA_ECR_REPO --region $AWS_REGION

# Tag and push Lambda image
LAMBDA_ECR_URI="$(aws sts get-caller-identity --query Account --output text).dkr.ecr.$AWS_REGION.amazonaws.com/$LAMBDA_ECR_REPO:$LAMBDA_IMAGE_TAG"
echo "Tagging and pushing Lambda image to $LAMBDA_ECR_URI"
docker tag "$LAMBDA_ECR_REPO:$LAMBDA_IMAGE_TAG" "$LAMBDA_ECR_URI"
docker push "$LAMBDA_ECR_URI"

# Build and push ECS container
echo "Building ECS container..."
docker build -t "$ECS_ECR_REPO:$ECS_IMAGE_TAG" -f Dockerfile.ecs .

# Check if ECS repository exists, create if not
aws ecr describe-repositories --repository-names $ECS_ECR_REPO --region $AWS_REGION || \
    aws ecr create-repository --repository-name $ECS_ECR_REPO --region $AWS_REGION

# Tag and push ECS image
ECS_ECR_URI="$(aws sts get-caller-identity --query Account --output text).dkr.ecr.$AWS_REGION.amazonaws.com/$ECS_ECR_REPO:$ECS_IMAGE_TAG"
echo "Tagging and pushing ECS image to $ECS_ECR_URI"
docker tag "$ECS_ECR_REPO:$ECS_IMAGE_TAG" "$ECS_ECR_URI"
docker push "$ECS_ECR_URI"

echo "Successfully built and pushed Docker images!"
cd ..

# Prepare Lambda deployment package for summary_lambda
echo "Preparing summary_lambda.zip..."
pip install openai boto3 -t package/
cp summary_lambda.py package/
cd package
zip -r ../summary_lambda.zip .
cd ..
rm -rf package/

echo "Applying Terraform configuration..."
terraform init
terraform apply -auto-approve

echo "Deployment complete!"
echo "Remember to update the OpenAI API key in AWS Secrets Manager:"
echo "  Secret Name: openai-api-key"
echo "  Key format should be: {\"api-key\": \"sk-...\"}"

exit 0