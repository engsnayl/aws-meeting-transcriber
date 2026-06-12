# Declarative imports mapping the live resources in account 340752829546
# to their Terraform addresses, to recover lost state. Remove this file
# once the imports have been applied.
#
# Deliberately NOT imported / managed:
# - The OpenAI secret VERSION: the live version holds the real key; it is
#   excluded from the configuration entirely so an apply can never touch it.
# - lambdaExecutionRole inline policy "lambda-ecs-access": exists in AWS but
#   has no resource in this configuration (stays unmanaged).
# - ECS task definition "file-converter" (and any related cluster wiring):
#   referenced by file-converter-trigger's env but not yet under Terraform.
# - Log group /aws/lambda/whisper-summary: auto-created by Lambda, unmanaged.
# - s3 prefix "processed/": exists in the bucket but has no resource here.

# --- S3 ---

import {
  to = aws_s3_bucket.recordings
  id = "snaylor-meeting-recordings-bucket"
}

import {
  to = aws_s3_bucket_public_access_block.block
  id = "snaylor-meeting-recordings-bucket"
}

import {
  to = aws_s3_bucket_versioning.recordings_versioning
  id = "snaylor-meeting-recordings-bucket"
}

import {
  to = aws_s3_object.uploads_prefix
  id = "s3://snaylor-meeting-recordings-bucket/uploads/"
}

import {
  to = aws_s3_object.transcripts_prefix
  id = "s3://snaylor-meeting-recordings-bucket/transcripts/"
}

import {
  to = aws_s3_object.summaries_prefix
  id = "s3://snaylor-meeting-recordings-bucket/summaries/"
}

import {
  to = aws_s3_bucket_notification.bucket_notification
  id = "snaylor-meeting-recordings-bucket"
}

# --- Lambda ---

import {
  to = aws_lambda_function.trigger_whisper
  id = "trigger-whisper-container"
}

import {
  to = aws_lambda_function.summary_lambda
  id = "whisper-summary"
}

import {
  to = aws_lambda_permission.allow_s3_invoke
  id = "trigger-whisper-container/AllowS3Invoke"
}

import {
  to = aws_lambda_permission.allow_s3_invoke_summary
  id = "whisper-summary/lambda-0370253e-d283-47ea-bec3-5343f385ef90"
}

import {
  to = aws_lambda_function.file_converter_trigger
  id = "file-converter-trigger"
}

import {
  to = aws_lambda_function.trigger_whisper_zip
  id = "trigger-whisper-container-zip"
}

import {
  to = aws_lambda_permission.allow_s3_invoke_converter
  id = "file-converter-trigger/AllowS3Invoke"
}

import {
  to = aws_lambda_permission.allow_s3_invoke_zip
  id = "trigger-whisper-container-zip/AllowS3Invoke"
}

import {
  to = aws_lambda_permission.allow_s3_invoke_zip_event
  id = "trigger-whisper-container-zip/340752829546_event_permissions_from_snaylor-meeting-recordings-bucket_for_trigger-whisper-container-"
}

# --- ECS ---

import {
  to = aws_ecs_cluster.whisper_ecs_cluster
  id = "whisper-ecs-cluster-v2"
}

import {
  to = aws_ecs_task_definition.whisper_task
  id = "arn:aws:ecs:eu-west-1:340752829546:task-definition/whisper-transcribe:6"
}

# --- CloudWatch ---

import {
  to = aws_cloudwatch_log_group.ecs_whisper_logs
  id = "/ecs/whisper"
}

import {
  to = aws_cloudwatch_log_group.file_converter_trigger_logs
  id = "/aws/lambda/file-converter-trigger"
}

import {
  to = aws_cloudwatch_log_group.trigger_whisper_zip_logs
  id = "/aws/lambda/trigger-whisper-container-zip"
}

# --- IAM ---

import {
  to = aws_iam_role.ecs_task_exec
  id = "ecsTaskExecutionRole"
}

import {
  to = aws_iam_role.lambda_exec
  id = "lambdaExecutionRole"
}

import {
  to = aws_iam_role_policy.s3_access
  id = "ecsTaskExecutionRole:ecs-s3-access"
}

import {
  to = aws_iam_role_policy.lambda_ecs_invoke_policy
  id = "lambdaExecutionRole:AllowRunWhisperTask"
}

import {
  to = aws_iam_role_policy.lambda_s3_read_access
  id = "lambdaExecutionRole:lambda-read-uploads"
}

import {
  to = aws_iam_role_policy.lambda_ses_access
  id = "lambdaExecutionRole:lambda-ses-access"
}

import {
  to = aws_iam_role_policy_attachment.ecs_task_execution_attach
  id = "ecsTaskExecutionRole/arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

import {
  to = aws_iam_role_policy_attachment.lambda_basic
  id = "lambdaExecutionRole/arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

import {
  to = aws_iam_role.summary_lambda_exec
  id = "LambdaExecutionRoleWithS3_SES_DDB"
}

import {
  to = aws_iam_role_policy_attachment.summary_lambda_basic
  id = "LambdaExecutionRoleWithS3_SES_DDB/arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

import {
  to = aws_iam_role_policy_attachment.summary_lambda_s3
  id = "LambdaExecutionRoleWithS3_SES_DDB/arn:aws:iam::aws:policy/AmazonS3FullAccess"
}

import {
  to = aws_iam_role_policy_attachment.summary_lambda_ses
  id = "LambdaExecutionRoleWithS3_SES_DDB/arn:aws:iam::aws:policy/AmazonSESFullAccess"
}

import {
  to = aws_iam_role_policy_attachment.summary_lambda_secrets
  id = "LambdaExecutionRoleWithS3_SES_DDB/arn:aws:iam::aws:policy/SecretsManagerReadWrite"
}

# --- Secrets / SES ---

import {
  to = aws_secretsmanager_secret.openai
  id = "arn:aws:secretsmanager:eu-west-1:340752829546:secret:openai-api-key-K9DrXE"
}

import {
  to = aws_ses_email_identity.sender
  id = "no-reply@engsnayl.com"
}
