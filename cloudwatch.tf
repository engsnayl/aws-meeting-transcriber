resource "aws_cloudwatch_log_group" "ecs_whisper_logs" {
  name              = "/ecs/whisper"
  retention_in_days = 3

  tags = {
    component = "transcribe"
  }
}
