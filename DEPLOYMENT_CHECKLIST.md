# Deployment Checklist

Use this checklist to ensure all components are properly configured before and after deployment.

## Pre-Deployment

- [ ] AWS CLI is installed and configured with appropriate permissions
- [ ] Docker is installed and running
- [ ] Terraform is installed
- [ ] OpenAI API key is available
- [ ] SES sender email (`no-reply@engsnayl.com`) is registered and verified in AWS SES
- [ ] AWS region in `main.tf` matches your preferred region
- [ ] S3 bucket name in `main.tf` is unique and available

## Build and Push Docker Images

- [ ] Dockerfile for Lambda trigger container is correct
- [ ] Dockerfile.ecs for Whisper container is correct
- [ ] Build scripts have execute permissions (`chmod +x build_and_deploy.sh`)
- [ ] Docker has sufficient disk space for building images
- [ ] AWS ECR repositories exist (will be created by script if not)
- [ ] Docker login to ECR is successful

## Package Lambda Functions

- [ ] Summary Lambda code is updated for the latest OpenAI API
- [ ] Requirements.txt includes all needed dependencies
- [ ] summary_lambda.zip is created with all dependencies included

## Terraform Application

- [ ] Terraform init completes successfully
- [ ] Terraform plan shows the expected resources
- [ ] Terraform apply completes without errors
- [ ] All AWS resources are created successfully:
  - [ ] S3 bucket
  - [ ] IAM roles and policies
  - [ ] Lambda functions
  - [ ] ECS cluster and task definition
  - [ ] CloudWatch log groups
  - [ ] S3 event notifications
  - [ ] Secrets Manager secret

## Post-Deployment

- [ ] Update the OpenAI API key in Secrets Manager with your actual key
- [ ] Check Lambda functions have the correct environment variables
- [ ] Verify S3 bucket has the required folder structure
- [ ] Confirm ECS task definition has the correct image URL
- [ ] Test the pipeline with a sample audio file
- [ ] Monitor CloudWatch logs for any errors
- [ ] Verify email delivery works

## Testing

- [ ] Upload a test audio file to the S3 bucket's uploads/ folder
- [ ] Confirm Lambda trigger logs show successful execution
- [ ] Check ECS task runs without errors
- [ ] Verify transcript appears in the transcripts/ folder
- [ ] Confirm summary Lambda processes the transcript
- [ ] Check for summary files in the summaries/ folder
- [ ] Receive email with the meeting summary

## Security Check

- [ ] S3 bucket blocks public access
- [ ] IAM roles follow least privilege principle
- [ ] API keys are securely stored in Secrets Manager
- [ ] Network security groups restrict appropriate traffic
- [ ] No sensitive data is hard-coded in any files

## Cleanup After Testing (Optional)

- [ ] Delete test files from S3 bucket
- [ ] Clean up unused Docker images locally
- [ ] Review CloudWatch logs for any issues or improvements