resource "aws_secretsmanager_secret" "openai" {
  name = "openai-api-key"

  tags = {
    component = "summarise"
  }

  # Terraform-only attributes (used at delete/replica time, no AWS
  # counterpart); ignored so the adopted resource shows tag-only changes.
  lifecycle {
    ignore_changes = [recovery_window_in_days, force_overwrite_replica_secret]
  }
}

# The secret VALUE is deliberately not managed by Terraform: the live
# version holds the real OpenAI key, set via the AWS console. Managing it
# here (the old aws_secretsmanager_secret_version resource) would let an
# apply overwrite the real key with a placeholder.

resource "aws_ses_email_identity" "sender" {
  email = "no-reply@engsnayl.com"
}
