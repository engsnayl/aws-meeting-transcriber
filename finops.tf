# FinOps cost visibility:
# - CUR 2.0 data export (hourly, resource IDs) delivered to a dedicated S3 bucket
# - Glue database + Athena workgroup for querying the export
# - Monthly cost budget with email alerts
# See README "FinOps / cost visibility" for the manual steps Terraform cannot do.

data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# S3 bucket for the CUR 2.0 export (versioning deliberately off; the export
# uses OVERWRITE_REPORT so old versions would only accumulate cost)
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "cur_exports" {
  bucket        = "snaylor-meeting-transcriber-cur-exports"
  force_destroy = true

  tags = {
    component = "finops"
  }
}

resource "aws_s3_bucket_public_access_block" "cur_exports_block" {
  bucket                  = aws_s3_bucket.cur_exports.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "cur_exports_expiry" {
  bucket = aws_s3_bucket.cur_exports.id

  rule {
    id     = "expire-cur-data"
    status = "Enabled"

    filter {
      prefix = "cur2/"
    }

    expiration {
      days = 365
    }
  }
}

resource "aws_s3_bucket_policy" "cur_exports_policy" {
  bucket = aws_s3_bucket.cur_exports.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid    = "AllowBillingDataExportsWrite",
        Effect = "Allow",
        Principal = {
          Service = [
            "billingreports.amazonaws.com",
            "bcm-data-exports.amazonaws.com"
          ]
        },
        Action = [
          "s3:PutObject",
          "s3:GetBucketPolicy"
        ],
        Resource = [
          aws_s3_bucket.cur_exports.arn,
          "${aws_s3_bucket.cur_exports.arn}/*"
        ],
        Condition = {
          StringLike = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id,
            "aws:SourceArn" = [
              "arn:aws:cur:us-east-1:${data.aws_caller_identity.current.account_id}:definition/*",
              "arn:aws:bcm-data-exports:us-east-1:${data.aws_caller_identity.current.account_id}:export/*"
            ]
          }
        }
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# CUR 2.0 standard data export (Data Exports API only exists in us-east-1)
# ---------------------------------------------------------------------------

resource "aws_bcmdataexports_export" "cur" {
  provider = aws.us_east_1

  export {
    name        = "meeting-transcriber-cur"
    description = "Hourly CUR 2.0 export with resource IDs for meeting-transcriber cost attribution"

    data_query {
      query_statement = "SELECT identity_line_item_id, identity_time_interval, bill_billing_period_start_date, bill_payer_account_id, line_item_usage_account_id, line_item_line_item_type, line_item_usage_start_date, line_item_usage_end_date, line_item_product_code, line_item_usage_type, line_item_operation, line_item_availability_zone, line_item_resource_id, line_item_usage_amount, line_item_unblended_rate, line_item_unblended_cost, line_item_line_item_description, product_servicecode, pricing_unit, pricing_public_on_demand_cost, resource_tags, cost_category FROM COST_AND_USAGE_REPORT"

      table_configurations = {
        COST_AND_USAGE_REPORT = {
          TIME_GRANULARITY                      = "HOURLY"
          INCLUDE_RESOURCES                     = "TRUE"
          INCLUDE_SPLIT_COST_ALLOCATION_DATA    = "FALSE"
          INCLUDE_MANUAL_DISCOUNT_COMPATIBILITY = "FALSE"
          # The Data Exports API injects this server-side; declaring it
          # explicitly stops Terraform seeing post-create drift.
          BILLING_VIEW_ARN = "arn:aws:billing::${data.aws_caller_identity.current.account_id}:billingview/primary"
        }
      }
    }

    destination_configurations {
      s3_destination {
        s3_bucket = aws_s3_bucket.cur_exports.bucket
        s3_prefix = "cur2"
        s3_region = "eu-west-1"

        s3_output_configurations {
          format      = "PARQUET"
          compression = "PARQUET"
          output_type = "CUSTOM"
          overwrite   = "OVERWRITE_REPORT"
        }
      }
    }

    refresh_cadence {
      frequency = "SYNCHRONOUS"
    }
  }

  tags = {
    component = "finops"
  }

  depends_on = [aws_s3_bucket_policy.cur_exports_policy]
}

# ---------------------------------------------------------------------------
# Athena setup: Glue database + workgroup with a dedicated results bucket
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "athena_results" {
  bucket        = "snaylor-meeting-transcriber-athena-results"
  force_destroy = true

  tags = {
    component = "finops"
  }
}

resource "aws_s3_bucket_public_access_block" "athena_results_block" {
  bucket                  = aws_s3_bucket.athena_results.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "athena_results_expiry" {
  bucket = aws_s3_bucket.athena_results.id

  rule {
    id     = "expire-query-results"
    status = "Enabled"

    filter {
      prefix = "results/"
    }

    expiration {
      days = 30
    }
  }
}

# Glue catalog databases do not support tags
resource "aws_glue_catalog_database" "cur" {
  name = "meeting_transcriber_cur"
}

resource "aws_athena_workgroup" "finops" {
  name = "meeting-transcriber-finops"

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = false

    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena_results.bucket}/results/"
    }
  }

  tags = {
    component = "finops"
  }
}

# ---------------------------------------------------------------------------
# Monthly cost budget: alert at 80% actual and 100% forecasted
# ---------------------------------------------------------------------------

resource "aws_budgets_budget" "monthly" {
  name         = "meeting-transcriber-monthly"
  budget_type  = "COST"
  limit_amount = var.monthly_budget_limit
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_alert_email]
  }

  tags = {
    component = "finops"
  }
}
