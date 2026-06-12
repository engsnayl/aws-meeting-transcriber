# This Terraform script deploys the full end-to-end architecture:
# - S3 bucket for meeting uploads
# - ECS Fargate task for Whisper transcription
# - Lambda trigger for S3 uploads -> ECS Task
# - Lambda for OpenAI summarisation + SES email
# - IAM roles and secrets

terraform {
  # State bucket is bootstrapped outside Terraform (AWS CLI) on purpose.
  # Terraform 1.10+ native S3 locking; no DynamoDB table needed.
  backend "s3" {
    bucket       = "snaylor-meeting-transcriber-tfstate"
    key          = "meeting-transcriber/terraform.tfstate"
    region       = "eu-west-1"
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.46.0" # aws_bcmdataexports_export requires 5.46+
    }
  }
}

provider "aws" {
  region = "eu-west-1"

  default_tags {
    tags = {
      project     = "meeting-transcriber"
      environment = var.environment
    }
  }
}

# Data Exports (CUR 2.0) and the billing APIs only exist in us-east-1,
# so FinOps resources that need it use this aliased provider.
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"

  default_tags {
    tags = {
      project     = "meeting-transcriber"
      environment = var.environment
    }
  }
}
