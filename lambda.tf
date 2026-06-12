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

  tags = {
    component = "transcribe"
  }

  # publish is a Terraform-only deploy flag with no live counterpart;
  # ignored so adopted state converges to tag-only changes.
  lifecycle {
    ignore_changes = [publish]
  }
}

# Live code (handler lambda_function.lambda_handler) is deployed outside
# Terraform via build_and_deploy.sh; filename is ignored so an apply can
# never overwrite the running code.
resource "aws_lambda_function" "summary_lambda" {
  function_name = "whisper-summary"
  filename      = "summary_lambda.zip"
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.9"
  role          = aws_iam_role.summary_lambda_exec.arn
  timeout       = 300
  memory_size   = 1024

  environment {
    variables = {
      OPENAI_SECRET_NAME = aws_secretsmanager_secret.openai.name
    }
  }

  tags = {
    component = "summarise"
  }

  lifecycle {
    ignore_changes = [filename, publish]
  }
}

# Adopted from live: converts uploads (uploads/) before transcription.
# Code is managed outside Terraform; filename is a placeholder.
resource "aws_lambda_function" "file_converter_trigger" {
  function_name = "file-converter-trigger"
  filename      = "file_converter_trigger.zip"
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.9"
  role          = aws_iam_role.lambda_exec.arn
  timeout       = 60
  memory_size   = 128

  environment {
    variables = {
      ECS_CLUSTER        = aws_ecs_cluster.whisper_ecs_cluster.name
      CONVERTER_TASK_DEF = "file-converter" # ECS task def not yet managed by Terraform
      SUBNET_1           = var.subnet_ids[0]
      SECURITY_GROUP     = var.security_group_id
    }
  }

  tags = {
    component = "ingest"
  }

  lifecycle {
    ignore_changes = [filename, publish]
  }
}

# Adopted from live: zip-packaged trigger that starts the Whisper task
# from converted files (processed/). Code managed outside Terraform.
resource "aws_lambda_function" "trigger_whisper_zip" {
  function_name = "trigger-whisper-container-zip"
  filename      = "trigger_whisper_zip.zip"
  handler       = "lambda_function.lambda_handler"
  runtime       = "python3.9"
  role          = aws_iam_role.lambda_exec.arn
  timeout       = 60
  memory_size   = 128

  environment {
    variables = {
      ECS_CLUSTER    = aws_ecs_cluster.whisper_ecs_cluster.name
      ECS_TASK_DEF   = aws_ecs_task_definition.whisper_task.family
      SUBNET_1       = var.subnet_ids[0]
      SECURITY_GROUP = var.security_group_id
    }
  }

  tags = {
    component = "transcribe"
  }

  lifecycle {
    ignore_changes = [filename, publish]
  }
}

resource "aws_lambda_permission" "allow_s3_invoke" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.trigger_whisper.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.recordings.arn
}

# statement_id and source_account match the live console-generated grant
# so the import is clean rather than a destroy/recreate.
resource "aws_lambda_permission" "allow_s3_invoke_summary" {
  statement_id   = "lambda-0370253e-d283-47ea-bec3-5343f385ef90"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.summary_lambda.function_name
  principal      = "s3.amazonaws.com"
  source_arn     = aws_s3_bucket.recordings.arn
  source_account = "340752829546"
}

resource "aws_lambda_permission" "allow_s3_invoke_converter" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.file_converter_trigger.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.recordings.arn
}

resource "aws_lambda_permission" "allow_s3_invoke_zip" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.trigger_whisper_zip.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.recordings.arn
}

# Second live grant on the same function, created by the S3 console
resource "aws_lambda_permission" "allow_s3_invoke_zip_event" {
  statement_id   = "340752829546_event_permissions_from_snaylor-meeting-recordings-bucket_for_trigger-whisper-container-"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.trigger_whisper_zip.function_name
  principal     = "s3.amazonaws.com"
  source_arn     = aws_s3_bucket.recordings.arn
  source_account = "340752829546"
}

# Live three-stage layout: upload -> convert -> transcribe -> summarise
resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = aws_s3_bucket.recordings.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.file_converter_trigger.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "uploads/"
  }

  lambda_function {
    lambda_function_arn = aws_lambda_function.trigger_whisper_zip.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "processed/"
  }

  lambda_function {
    lambda_function_arn = aws_lambda_function.summary_lambda.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "transcripts/"
  }

  depends_on = [
    aws_lambda_permission.allow_s3_invoke_converter,
    aws_lambda_permission.allow_s3_invoke_zip,
    aws_lambda_permission.allow_s3_invoke_zip_event,
    aws_lambda_permission.allow_s3_invoke_summary
  ]
}
