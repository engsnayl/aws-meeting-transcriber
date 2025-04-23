# Testing Guide: AWS Serverless Meeting Transcription Pipeline

This guide will help you verify that all components of the meeting transcription pipeline are working correctly.

## Prerequisites

1. AWS CLI configured with appropriate permissions
2. Terraform successfully applied
3. Docker images built and pushed to ECR
4. OpenAI API key set in AWS Secrets Manager

## Test 1: Upload an Audio File

First, let's verify the S3 upload and Whisper transcription process:

```bash
# Upload a test audio file to the S3 bucket
aws s3 cp test-meeting.mp3 s3://snaylor-meeting-recordings-bucket/uploads/test-meeting.mp3
```

Expected behavior:
- Lambda function should be triggered by the S3 upload
- Lambda should launch an ECS Fargate task
- Fargate task should download the audio file, transcribe it using Whisper, and upload the transcript to S3

## Test 2: Monitor the Process

```bash
# Check CloudWatch logs for the Lambda function
aws logs get-log-events --log-group-name /aws/lambda/trigger-whisper-container --log-stream-name $(aws logs describe-log-streams --log-group-name /aws/lambda/trigger-whisper-container --query "logStreams[0].logStreamName" --output text)

# Check CloudWatch logs for the ECS task
aws logs get-log-events --log-group-name /ecs/whisper --log-stream-name $(aws logs describe-log-streams --log-group-name /ecs/whisper --query "logStreams[0].logStreamName" --output text)
```

Expected output:
- Lambda logs should show successful invocation and ECS task launch
- ECS logs should show:
  - Audio file download from S3
  - Whisper model loading and transcription
  - Transcript upload back to S3

## Test 3: Verify Transcript Creation

```bash
# Check if transcript was created in S3
aws s3 ls s3://snaylor-meeting-recordings-bucket/transcripts/

# Download the transcript to check its content
aws s3 cp s3://snaylor-meeting-recordings-bucket/transcripts/test-meeting.mp3.txt ./transcribed-output.txt
```

Expected result:
- The transcript file should exist in the transcripts/ folder
- The downloaded transcript should contain text content from the audio

## Test 4: Check Summarization and Email

After the transcript is uploaded to S3, the summary Lambda should automatically:
1. Generate summaries using OpenAI
2. Store them in S3
3. Send an email

Verify this process:

```bash
# Check if summary files were created
aws s3 ls s3://snaylor-meeting-recordings-bucket/summaries/

# Check CloudWatch logs for the summary Lambda
aws logs get-log-events --log-group-name /aws/lambda/whisper-summary --log-stream-name $(aws logs describe-log-streams --log-group-name /aws/lambda/whisper-summary --query "logStreams[0].logStreamName" --output text)
```

Expected results:
- Three summary files should exist in S3:
  - `test-meeting_summary.md`
  - `test-meeting_actions.md`
  - `test-meeting_detailed.md`
- Lambda logs should show successful OpenAI API calls and SES email sending
- You should receive an email at the configured address with the meeting summary

## Troubleshooting

### Lambda Triggers Not Working

If S3 events aren't triggering the Lambda functions:
1. Check S3 bucket notification configuration
2. Verify Lambda permissions and execution role
3. Make sure the file path matches the expected prefix (uploads/ or transcripts/)

### ECS Task Failures

If the ECS task fails:
1. Check task IAM role permissions
2. Verify ECS task definition and container configuration
3. Examine CloudWatch logs for error messages

### OpenAI API Issues

If OpenAI summarization isn't working:
1. Verify the correct API key format in Secrets Manager (`api-key` key)
2. Check OpenAI usage quota and limits
3. Examine Lambda CloudWatch logs for API error responses

### Email Delivery Problems

If emails aren't being received:
1. Verify SES sender identity is verified
2. Check SES sending limits and sandbox status
3. Examine CloudWatch logs for SES error messages