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
