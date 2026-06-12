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
aws-meeting-transcriber/
├── main.tf              # Terraform provider config
├── s3.tf                # S3 bucket, public access block, folder prefixes
├── iam.tf               # IAM roles and policies (ECS + Lambda)
├── cloudwatch.tf        # CloudWatch log group
├── lambda.tf            # Lambda functions, permissions, S3 notifications
├── secrets.tf           # Secrets Manager (OpenAI key) + SES identity
├── ecs.tf               # ECS cluster + Fargate task definition
├── finops.tf            # CUR 2.0 data export, Athena/Glue, cost budget
├── variables.tf         # Subnet IDs, security group ID, FinOps settings
├── summary_lambda.py    # OpenAI processing Lambda function
├── build_and_deploy.sh  # Builds containers, packages Lambda zip, deploys
└── requirements.txt     # Python dependencies for summary Lambda
```

## Deployment Instructions

1. **Clone the repository:**
   ```bash
   git clone [repository-url]
   cd meeting-transcriber-terraform
   ```

2. **Update the OpenAI API key:**
   Edit `secrets.tf` to specify your OpenAI API key in the `aws_secretsmanager_secret_version` resource, or update it through the AWS console after deployment.

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

## FinOps / Cost Visibility

`finops.tf` provisions a CUR 2.0 data export (hourly granularity, resource IDs, Parquet)
into `snaylor-meeting-transcriber-cur-exports`, a Glue database and Athena workgroup for
querying it, and a $20/month budget that emails at 80% actual and 100% forecasted spend.
All taggable resources carry `project`/`environment` (via provider `default_tags`) plus a
per-resource `component` tag (`ingest`, `transcribe`, `summarise`, `finops`, `shared`).

### Manual steps Terraform cannot do

- **Activate cost allocation tags.** After the first apply, the `project`, `environment`
  and `component` tag keys must be activated in the Billing console (Billing → Cost
  allocation tags). Tag keys only appear there up to 24 hours after they are first used
  on a resource, and spend is attributed only from the activation date forwards. (The
  `aws_ce_cost_allocation_tag` resource exists, but it fails until the keys have shown
  up in billing data, so activation is kept manual.)
- **First export delivery takes up to 24 hours**, and Data Exports does not backfill
  earlier months automatically — request a backfill via the console if needed.
- **Athena table creation.** Data Exports delivers Parquet files plus metadata, but does
  not create the Glue table. After the first delivery, either run a one-off Glue crawler
  over `s3://snaylor-meeting-transcriber-cur-exports/cur2/` targeting the
  `meeting_transcriber_cur` database, or create the table with DDL in the
  `meeting-transcriber-finops` workgroup.
- **SES is not taggable.** `aws_ses_email_identity` has no tags, so the notify
  component's SES spend cannot carry the `component` tag; SES costs show up under the
  account-level `project` tag only via other tagged resources. Attribute SES spend by
  service name in Athena instead.
- **Budget scope.** The budget covers the whole account, not just this project. Once the
  cost allocation tags are active you can narrow it with a `cost_filter` on
  `TagKeyValue` (`user:project$meeting-transcriber`).

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