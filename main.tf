# C:\Users\naylo\Documents\meeting-transcriber-terraform\main.tf

# This Terraform script deploys the full end-to-end architecture:
# - S3 bucket for meeting uploads
# - ECS Fargate task for Whisper transcription
# - Lambda trigger for S3 uploads -> ECS Task
# - Lambda for OpenAI summarisation + SES email
# - IAM roles and secrets

provider "aws" {
  region = "eu-west-1"
}

resource "aws_s3_bucket" "recordings" {
  bucket         = "snaylor-meeting-recordings-bucket"
  force_destroy  = true
}

resource "aws_s3_bucket_public_access_block" "block" {
  bucket                  = aws_s3_bucket.recordings.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "uploads_prefix" {
  bucket  = aws_s3_bucket.recordings.id
  key     = "uploads/"
  content = ""
}

resource "aws_s3_object" "transcripts_prefix" {
  bucket  = aws_s3_bucket.recordings.id
  key     = "transcripts/"
  content = ""
}

resource "aws_s3_object" "summaries_prefix" {
  bucket  = aws_s3_bucket.recordings.id
  key     = "summaries/"
  content = ""
}

resource "aws_iam_role" "ecs_task_exec" {
  name = "ecsTaskExecutionRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = "sts:AssumeRole",
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      },
      Effect = "Allow"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_attach" {
  role       = aws_iam_role.ecs_task_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "s3_access" {
  name = "ecs-s3-access"
  role = aws_iam_role.ecs_task_exec.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "s3:GetObject",
          "s3:PutObject"
        ],
        Resource = [
          "${aws_s3_bucket.recordings.arn}/*"
        ]
      }
    ]
  })
}

resource "aws_iam_role" "lambda_exec" {
  name = "lambdaExecutionRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = "sts:AssumeRole",
      Principal = {
        Service = "lambda.amazonaws.com"
      },
      Effect = "Allow"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_ecs_invoke_policy" {
  name = "AllowRunWhisperTask"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = ["ecs:RunTask"],
        Resource = "*"
      },
      {
        Effect = "Allow",
        Action = ["iam:PassRole"],
        Resource = aws_iam_role.ecs_task_exec.arn
      }
    ]
  })
}

resource "aws_iam_role_policy" "lambda_s3_read_access" {
  name = "lambda-read-uploads"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "s3:GetObject",
          "s3:GetObjectAcl"
        ],
        Resource = "${aws_s3_bucket.recordings.arn}/uploads/*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "lambda_ses_access" {
  name = "lambda-ses-access"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "ses:SendEmail",
          "ses:SendRawEmail"
        ],
        Resource = "*"
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "ecs_whisper_logs" {
  name              = "/ecs/whisper"
  retention_in_days = 3
}

resource "aws_lambda_function" "trigger_whisper" {
  function_name = "trigger-whisper-container"
  role          = aws_iam_role.lambda_exec.arn
  package_type  = "Image"
  image_uri     = "340752829546.dkr.ecr.eu-west-1.amazonaws.com/whisper-lambda:latest"
  timeout       = 60
  memory_size   = 512

  environment {
    variables = {
      ECS_CLUSTER    = aws_ecs_cluster.whisper_ecs_cluster.name
      ECS_TASK_DEF   = aws_ecs_task_definition.whisper_task.family
      SUBNET_1       = var.subnet_ids[0]
      SECURITY_GROUP = var.security_group_id
    }
  }
}

resource "aws_lambda_function" "summary_lambda" {
  function_name = "whisper-summary"
  filename      = "summary_lambda.zip"
  handler       = "summary_lambda.lambda_handler"
  runtime       = "python3.9"
  role          = aws_iam_role.lambda_exec.arn
  timeout       = 300
  memory_size   = 1024

  environment {
    variables = {
      OPENAI_SECRET_NAME = aws_secretsmanager_secret.openai.name
    }
  }
}

resource "aws_lambda_permission" "allow_s3_invoke" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.trigger_whisper.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.recordings.arn
}

resource "aws_lambda_permission" "allow_s3_invoke_summary" {
  statement_id  = "AllowS3InvokeSummary"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.summary_lambda.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.recordings.arn
}

resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = aws_s3_bucket.recordings.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.trigger_whisper.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "uploads/"
  }

  lambda_function {
    lambda_function_arn = aws_lambda_function.summary_lambda.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "transcripts/"
    filter_suffix       = ".txt"
  }

  depends_on = [
    aws_lambda_permission.allow_s3_invoke,
    aws_lambda_permission.allow_s3_invoke_summary
  ]
}

resource "aws_secretsmanager_secret" "openai" {
  name = "openai-api-key"
}

resource "aws_secretsmanager_secret_version" "openai_value" {
  secret_id     = aws_secretsmanager_secret.openai.id
  secret_string = jsonencode({
    apiKey = "REPLACE_ME_WITH_YOUR_KEY"
  })
}

resource "aws_ses_email_identity" "sender" {
  email = "no-reply@engsnayl.com"
}

resource "aws_ecs_cluster" "whisper_ecs_cluster" {
  name = "whisper-ecs-cluster-v2"
}

resource "aws_ecs_task_definition" "whisper_task" {
  family                   = "whisper-transcribe"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "1024"
  memory                   = "2048"
  execution_role_arn       = aws_iam_role.ecs_task_exec.arn
  task_role_arn            = aws_iam_role.ecs_task_exec.arn

  container_definitions = jsonencode([
    {
      name      = "whisper-container",
      image     = "340752829546.dkr.ecr.eu-west-1.amazonaws.com/whisper-ecs:v1",
      essential = true,
      environment = [
        {
          name  = "S3_BUCKET"
          value = aws_s3_bucket.recordings.bucket
        },
        {
          name  = "S3_KEY"
          value = "PLACEHOLDER"
        }
      ],
      logConfiguration = {
        logDriver = "awslogs",
        options = {
          awslogs-group         = aws_cloudwatch_log_group.ecs_whisper_logs.name,
          awslogs-region        = "eu-west-1",
          awslogs-stream-prefix = "ecs"
        }
      }
    }
  ])
}

variable "subnet_ids" {
  default = [
    "subnet-030551a0fa3803efd",
    "subnet-030f3ac073b44b1a3",
    "subnet-02f26d4804c9e4a17"
  ]
}

variable "security_group_id" {
  default = "sg-02a7c01d00c08d0c0"
}