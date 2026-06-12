resource "aws_s3_bucket" "recordings" {
  bucket         = "snaylor-meeting-recordings-bucket"
  force_destroy  = true

  tags = {
    component = "ingest"
  }
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
