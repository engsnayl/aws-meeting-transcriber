# AWS Serverless Meeting Transcription Pipeline

This project implements a serverless pipeline on AWS that automatically transcribes meeting audio files, generates summaries using OpenAI's GPT-4, and emails the results.

## Architecture

![Architecture Diagram](https://placeholder-for-architecture-diagram.png)

The architecture consists of:

1. **S3 Bucket** - Storage for audio files, transcripts, and summaries
2. **Lambda Trigger** - Activates when new audio files are uploaded to S3
3. **ECS Fargate** - Runs Whisper for audio transcription
4. **Summary Lambda** - Processes transcripts with OpenAI and sends emails
5. **AWS SES** - Sends email notifications with summaries

## Prerequisites

- AWS Account with appropriate permissions
- Terraform installed
- Docker installed
- AWS CLI configured
- OpenAI API Key

## Directory Structure

```
meeting-transcriber-terraform/
├── main.tf                     # Terraform infrastructure definition
├── summary_lambda.py           # OpenAI processing Lambda function
├── build_and_deploy.sh         # Deployment script
├── requirements.txt            # Python dependencies
├── package_summary_lambda.sh   # Script to package the summary Lambda
└── lambda_container_build/     # Lambda trigger container files
    ├── lambda_function.py      # Lambda code to trigger ECS tasks
    ├── main.py                 # Whisper transcription script for ECS
    ├── Dockerfile              # Docker config for Lambda container
    └── Dockerfile.ecs          # Docker config for ECS container
```

## Deployment Instructions

1. **Clone the repository:**
   ```bash
   git clone [repository-url]
   cd meeting-transcriber-terraform
   ```

2. **Update the OpenAI API key:**
   Edit `main.tf` to specify your OpenAI API key in the `aws_secretsmanager_secret_version` resource, or plan to update it through the AWS console after deployment.

3. **Build and deploy:**
   ```bash
   chmod +x build_and_deploy.sh
   ./build_and_deploy.sh
   ```

4. **Verify the deployment:**
   ```bash
   terraform output
   ```

## Usage

1. **Upload an audio file:**
   ```bash
   aws s3 cp meeting-recording.mp3 s3://snaylor-meeting-recordings-bucket/uploads/
   ```

2. **Monitor processing:**
   Check CloudWatch logs for:
   - Lambda trigger: `/aws/lambda/trigger-whisper-container`
   - ECS task: `/ecs/whisper`
   - Summary Lambda: `/aws/lambda/whisper-summary`

3. **Check results:**
   - Transcript: `s3://snaylor-meeting-recordings-bucket/transcripts/`
   - Summaries: `s3://snaylor-meeting-recordings-bucket/summaries/`
   - Email: Check the email address configured in the Lambda function

## OpenAI API Configuration

The summary generation uses OpenAI's GPT-4-turbo model with three separate prompts:
1. General meeting summary (markdown format)
2. Action items extraction (bulleted list)
3. Detailed 100-point summary

The API key is stored in AWS Secrets Manager under the name `openai-api-key`.

## Customization

- **To change the email recipient:** Update the `RECIPIENT` variable in `summary_lambda.py`
- **To modify the summary format:** Adjust the prompt templates in the `generate_summary` function
- **To use a different Whisper model:** Change the model parameter in `main.py`

## Troubleshooting

See the [Testing Guide](TESTING.md) for detailed troubleshooting steps.

Common issues:
- **Lambda not triggering:** Check S3 event configuration and Lambda permissions
- **ECS task failing:** Verify task definition and check CloudWatch logs
- **OpenAI API errors:** Confirm API key is correctly stored in Secrets Manager
- **Email delivery issues:** Ensure SES sender identity is verified

## Security Considerations

- The S3 bucket is configured with public access blocked
- IAM roles follow the principle of least privilege
- API keys are stored in AWS Secrets Manager
- The ECS task uses networking configuration to access S3 securely

## Cleanup

To remove all resources:
```bash
terraform destroy
```

## License

This project is licensed under the MIT License - see the LICENSE file for details.