# This Terraform script deploys the full end-to-end architecture:
# - S3 bucket for meeting uploads
# - ECS Fargate task for Whisper transcription
# - Lambda trigger for S3 uploads -> ECS Task
# - Lambda for OpenAI summarisation + SES email
# - IAM roles and secrets

provider "aws" {
  region = "eu-west-1"
}
