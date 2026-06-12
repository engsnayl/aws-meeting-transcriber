resource "aws_cloudwatch_log_group" "ecs_whisper_logs" {
  name              = "/ecs/whisper"
  retention_in_days = 3

  tags = {
    component = "transcribe"
  }
}

# Adopted from live (auto-created by Lambda; no retention set)
resource "aws_cloudwatch_log_group" "file_converter_trigger_logs" {
  name = "/aws/lambda/file-converter-trigger"

  tags = {
    component = "ingest"
  }
}

resource "aws_cloudwatch_log_group" "trigger_whisper_zip_logs" {
  name = "/aws/lambda/trigger-whisper-container-zip"

  tags = {
    component = "transcribe"
  }
}
