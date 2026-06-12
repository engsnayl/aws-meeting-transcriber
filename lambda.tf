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

  tags = {
    component = "summarise"
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
