# AWS Meeting Transcriber - A Cloud Engineering Learning Guide

This document walks through the entire architecture of the AWS Meeting Transcriber
project. It's written for someone with basic IT knowledge who wants to understand
how real cloud systems are built, why specific AWS services are chosen, and how
Terraform ties it all together.

Read this alongside the source code. Every claim here maps to a specific line in
a specific file.

---

## Table of Contents

1. [The Problem This Solves](#1-the-problem-this-solves)
2. [Architecture Overview](#2-architecture-overview)
3. [How Each AWS Service Fits Together](#3-how-each-aws-service-fits-together)
4. [Why Fargate Instead of Lambda](#4-why-fargate-instead-of-lambda)
5. [Reading the Terraform](#5-reading-the-terraform)
6. [End-to-End Walkthrough: MP3 to Email](#6-end-to-end-walkthrough-mp3-to-email)
7. [Security Decisions and What Could Be Improved](#7-security-decisions-and-what-could-be-improved)
8. [Cost Model: When Do I Pay and For What](#8-cost-model-when-do-i-pay-and-for-what)
9. [Common Mistakes and Gotchas](#9-common-mistakes-and-gotchas)

---

## 1. The Problem This Solves

You have meeting recordings (MP3 files). You want to:

1. Upload the recording somewhere
2. Have it automatically transcribed to text
3. Get an AI-generated summary with action items
4. Receive the results by email

Doing this manually means opening a transcription tool, waiting, copying the text
into ChatGPT, formatting the output, and emailing it around. That's 15-30 minutes
of tedious work per meeting.

This system automates the entire pipeline. You upload an MP3 to an S3 bucket and
walk away. A few minutes later, an email arrives in your inbox with a summary,
action items, and links to the full transcript.

### Why build it this way?

- **Serverless** -- you don't manage any servers. No EC2 instances to patch, no
  uptime to worry about. Resources spin up when needed and disappear when done.
- **Event-driven** -- each step triggers the next automatically. S3 upload triggers
  transcription, transcription output triggers summarisation.
- **Cost-efficient** -- you pay nothing when the system is idle. Costs only accrue
  when you're actively processing a recording.

---

## 2. Architecture Overview

Here's the full data flow:

```
                        AWS CLOUD (eu-west-1)
  +------------------------------------------------------------------+
  |                                                                  |
  |   +------------------+                                           |
  |   |   S3 BUCKET      |                                           |
  |   |                  |                                           |
  |   |  uploads/        | <-- You drop an MP3 here                  |
  |   |  transcripts/    | <-- Whisper writes .txt here              |
  |   |  summaries/      | <-- OpenAI summaries land here            |
  |   +--------+---------+                                           |
  |            |                                                     |
  |            | S3 Event: "new file in uploads/"                     |
  |            v                                                     |
  |   +------------------+         +-------------------------+       |
  |   | LAMBDA           |  runs   | ECS FARGATE             |       |
  |   | trigger-whisper  | ------> | whisper-container       |       |
  |   | -container       | task    |                         |       |
  |   +------------------+         | 1. Downloads MP3 from S3|       |
  |                                | 2. Runs Whisper model   |       |
  |                                | 3. Uploads .txt to S3   |       |
  |                                | 4. Exits (task stops)   |       |
  |                                +-------------------------+       |
  |                                                                  |
  |            | S3 Event: "new .txt in transcripts/"                 |
  |            v                                                     |
  |   +------------------+         +------------------+              |
  |   | LAMBDA           |  calls  | OPENAI API       |              |
  |   | whisper-summary  | ------> | GPT-3.5-turbo    |              |
  |   |                  |         +------------------+              |
  |   |                  |                                           |
  |   |                  | ----> Saves 3 .md files to S3             |
  |   |                  | ----> Sends email via SES                 |
  |   +------------------+                                           |
  |                                                                  |
  +------------------------------------------------------------------+
```

There are **7 AWS services** involved:

| Service            | Role in This Project                        |
|--------------------|---------------------------------------------|
| S3                 | File storage (input, intermediate, output)   |
| Lambda             | Lightweight event handlers (trigger + summary)|
| ECS Fargate        | Heavy compute (runs the Whisper AI model)    |
| ECR                | Stores the Docker images                     |
| Secrets Manager    | Stores the OpenAI API key securely           |
| SES                | Sends the result email                       |
| CloudWatch Logs    | Captures logs from Lambda and Fargate        |

---

## 3. How Each AWS Service Fits Together

### S3 (Simple Storage Service)

S3 is the backbone. It stores every artefact and acts as the glue between pipeline
stages by firing **event notifications** when objects are created.

The bucket `snaylor-meeting-recordings-bucket` has three "folders" (prefixes):

```
snaylor-meeting-recordings-bucket/
  uploads/         <-- Input: raw MP3 files
  transcripts/     <-- Intermediate: plain text from Whisper
  summaries/       <-- Output: markdown summaries from OpenAI
```

**Why S3?** It's the standard place to store files in AWS. It's cheap (fractions
of a penny per GB/month), durable (99.999999999% -- eleven 9s), and natively
integrates with Lambda through event notifications. You don't need a database for
this workload because the data is files, not records.

### Lambda

Two Lambda functions handle the lightweight orchestration:

1. **trigger-whisper-container** -- Receives the S3 event when an MP3 is uploaded,
   extracts the file path, and tells ECS Fargate to start a container. This function
   does almost no work itself -- it's a dispatcher. (See `lambda_function.py`)

2. **whisper-summary** -- Receives the S3 event when a transcript .txt appears,
   downloads it, sends it to the OpenAI API three times (for three different
   summary styles), saves the results back to S3, and emails you. (See
   `summary_lambda.py`)

**Why Lambda?** Both of these tasks are short-lived and lightweight. The trigger
Lambda runs in under a second. The summary Lambda takes a few minutes at most
(mostly waiting on the OpenAI API). Lambda is ideal for this: you pay per
invocation, there's no infrastructure to manage, and it scales automatically.

### ECS Fargate

This is where the heavy lifting happens. Fargate runs a Docker container that:

1. Downloads the MP3 from S3
2. Loads the OpenAI Whisper speech-to-text model
3. Transcribes the audio
4. Uploads the resulting text back to S3

**Why Fargate specifically?** See [Section 4](#4-why-fargate-instead-of-lambda)
below -- this deserves its own section.

### ECR (Elastic Container Registry)

ECR is AWS's Docker image registry. Two images are stored here:

- `whisper-lambda:latest` -- The trigger Lambda's container image
- `whisper-ecs:v1` -- The Fargate transcription container

Think of ECR like Docker Hub, but private and inside your AWS account. When Fargate
needs to start a container, it pulls the image from ECR.

### Secrets Manager

The OpenAI API key is stored in Secrets Manager rather than being hardcoded in the
Lambda function or Terraform code. The summary Lambda retrieves it at runtime:

```python
secret_name = os.environ['OPENAI_SECRET_NAME']
response = secretsmanager.get_secret_value(SecretId=secret_name)
```

**Why not just an environment variable?** Environment variables are visible in the
AWS Console and in Terraform state files. Secrets Manager encrypts the value,
provides audit logging, and supports rotation. For API keys, this is the standard
approach.

### SES (Simple Email Service)

SES sends the final summary email from `no-reply@engsnayl.com`. It's configured
with a verified email identity (`secrets.tf:12-14`).

**Why SES over SNS?** SNS sends basic text notifications. SES sends formatted HTML
emails with links, which is what you want for a meeting summary with clickable
presigned URLs.

### CloudWatch Logs

Every component writes logs to CloudWatch:

- Fargate logs go to `/ecs/whisper` (3-day retention)
- Lambda logs go to `/aws/lambda/<function-name>` (auto-created by AWS)

The 3-day retention on Fargate logs (`cloudwatch.tf:1-4`) is a deliberate cost
decision. Storing logs indefinitely gets expensive. Three days is enough to debug
a failed run.

---

## 4. Why Fargate Instead of Lambda

This is the most important architectural decision in the project. Here's why
Whisper transcription runs on Fargate instead of Lambda:

### Lambda's Hard Limits

| Constraint              | Lambda Limit     | This Project Needs     |
|-------------------------|------------------|------------------------|
| Max execution time      | 15 minutes       | Varies (could exceed)  |
| Max container image     | 10 GB            | Whisper + PyTorch ~4GB |
| Max memory              | 10 GB            | Needs room for model   |
| Max ephemeral storage   | 10 GB            | Audio files can be big |
| vCPUs                   | Up to 6          | More is better for ML  |

Whisper transcription is a **compute-heavy, variable-duration** workload. A 2-hour
meeting recording could take longer than Lambda's 15-minute ceiling. The Whisper
model plus PyTorch and FFmpeg create a large container image. Lambda *might* work
for short recordings, but you'd be fighting its constraints constantly.

### What Fargate Gives You

Fargate removes those constraints:

- **No time limit** -- the task runs until the script finishes, whether that's
  2 minutes or 2 hours
- **Configurable resources** -- this project uses 1 vCPU and 2 GB RAM
  (`ecs.tf:9-10`), but you could scale up to 4 vCPUs and 30 GB RAM
- **Full container environment** -- install anything you want (FFmpeg, PyTorch,
  system libraries) without worrying about Lambda's runtime restrictions
- **No cold-start pressure** -- Lambda cold starts affect user-facing latency;
  Fargate's 30-60 second startup is fine for a batch job

### The Tradeoff

Fargate's downside is **cold start time**. When Lambda triggers `ecs.run_task()`,
AWS needs to:

1. Find capacity in the Fargate fleet
2. Provision an ENI (network interface) in your VPC
3. Pull the Docker image from ECR
4. Start the container

This takes 30-60 seconds before your code even starts running. For a batch
transcription job, that's acceptable. For a user-facing API, it would not be.

### The Pattern: Lambda as Orchestrator, Fargate as Worker

This is a common serverless pattern:

```
  Lambda (fast, cheap, event-driven)
    |
    | "Hey Fargate, process this file"
    |
    v
  Fargate (powerful, flexible, runs to completion)
```

Lambda handles the event routing because it starts instantly and costs almost
nothing per invocation. Fargate handles the heavy computation because it has the
resources and time. Each service does what it's best at.

---

## 5. Reading the Terraform

Infrastructure is split across multiple `.tf` files by concern. This section
explains how to read them.

### What Terraform Does

Terraform is an Infrastructure as Code (IaC) tool. Instead of clicking through
the AWS Console to create resources, you describe what you want in `.tf` files
and run `terraform apply`. Terraform figures out what exists, what needs to change,
and makes the API calls for you.

The key benefit: your infrastructure is **version-controlled, repeatable, and
reviewable**. You can destroy everything with `terraform destroy` and recreate it
identically with `terraform apply`.

### The File Structure

The Terraform configuration is split by concern into separate files:

```
main.tf          -- Provider config ("I'm deploying to AWS in eu-west-1")
s3.tf            -- S3 bucket, public access block, folder prefixes
iam.tf           -- All IAM roles and policies (ECS + Lambda)
cloudwatch.tf    -- CloudWatch log group
lambda.tf        -- Lambda functions, permissions, S3 event notifications
secrets.tf       -- Secrets Manager (OpenAI key) + SES email identity
ecs.tf           -- ECS cluster + Fargate task definition
variables.tf     -- Subnet IDs, security group ID
```

Terraform automatically merges all `.tf` files in a directory, so the split
is purely for human readability -- it changes nothing about how `terraform plan`
or `terraform apply` works.

### How to Read a Terraform Resource Block

Every resource follows the same pattern:

```hcl
resource "<provider>_<resource_type>" "<local_name>" {
  <argument> = <value>
}
```

For example:

```hcl
resource "aws_s3_bucket" "recordings" {
  bucket        = "snaylor-meeting-recordings-bucket"
  force_destroy = true
}
```

Breaking this down:

| Part                  | Meaning                                         |
|-----------------------|-------------------------------------------------|
| `aws_s3_bucket`       | AWS provider, S3 bucket resource type            |
| `"recordings"`        | Local name (used to reference this elsewhere)    |
| `bucket = "snaylor…"` | The actual bucket name in AWS                    |
| `force_destroy = true`| Allow `terraform destroy` even if bucket has files|

### How Resources Reference Each Other

Terraform resources refer to each other using the syntax
`<resource_type>.<local_name>.<attribute>`. For example:

```hcl
resource "aws_iam_role_policy" "s3_access" {
  role = aws_iam_role.ecs_task_exec.id    # <-- references the ECS role
  ...
  Resource = ["${aws_s3_bucket.recordings.arn}/*"]   # <-- references the bucket
}
```

This creates an implicit dependency. Terraform knows it must create the S3 bucket
and the IAM role *before* it can create this policy. You don't need to specify
ordering manually -- Terraform infers it from the references.

### The `depends_on` Exception

Sometimes Terraform can't infer dependencies from references. The S3 notification
block uses an explicit `depends_on`:

```hcl
resource "aws_s3_bucket_notification" "bucket_notification" {
  ...
  depends_on = [
    aws_lambda_permission.allow_s3_invoke,
    aws_lambda_permission.allow_s3_invoke_summary
  ]
}
```

Why? The notification resource doesn't directly reference the permission resources
in its arguments, but AWS will reject the API call if the permissions don't exist
yet. `depends_on` forces Terraform to create the permissions first.

### Variables and Hardcoded Values

The project uses `variable` blocks for subnet IDs and security group:

```hcl
variable "subnet_ids" {
  default = [
    "subnet-030551a0fa3803efd",
    "subnet-030f3ac073b44b1a3",
    "subnet-02f26d4804c9e4a17"
  ]
}
```

These have hardcoded defaults pointing to an existing VPC. In a more mature setup,
you'd pass these in via a `.tfvars` file or look them up dynamically with a
`data` source. For a personal project, hardcoded defaults are fine -- just know
they'd be the first thing to change if you moved this to a different AWS account.

---

## 6. End-to-End Walkthrough: MP3 to Email

Here's exactly what happens, step by step, when you upload a meeting recording.

### Step 1: Upload the MP3

You upload a file to S3:

```
aws s3 cp meeting.mp3 s3://snaylor-meeting-recordings-bucket/uploads/meeting.mp3
```

Or you drag it into the S3 Console. Either way, S3 now has a new object at the
key `uploads/meeting.mp3`.

### Step 2: S3 Fires an Event Notification

The bucket has an event notification configured (`lambda.tf:54-58`):

```hcl
lambda_function {
  lambda_function_arn = aws_lambda_function.trigger_whisper.arn
  events              = ["s3:ObjectCreated:*"]
  filter_prefix       = "uploads/"
}
```

This says: "whenever any object is created under `uploads/`, invoke the
`trigger-whisper-container` Lambda function."

S3 sends an event payload to Lambda that looks roughly like:

```json
{
  "Records": [{
    "s3": {
      "bucket": { "name": "snaylor-meeting-recordings-bucket" },
      "object": { "key": "uploads/meeting.mp3" }
    }
  }]
}
```

### Step 3: Lambda Extracts the File Info and Calls ECS

The trigger Lambda (`lambda_function.py`) parses that event:

```python
bucket = event['Records'][0]['s3']['bucket']['name']
key = event['Records'][0]['s3']['object']['key']
```

Then it calls `ecs.run_task()` to launch a Fargate container:

```python
response = ecs.run_task(
    cluster=os.environ["ECS_CLUSTER"],       # "whisper-ecs-cluster-v2"
    launchType="FARGATE",
    taskDefinition=os.environ["ECS_TASK_DEF"], # "whisper-transcribe"
    count=1,
    networkConfiguration={
        'awsvpcConfiguration': {
            'subnets': [os.environ["SUBNET_1"]],
            'securityGroups': [os.environ["SECURITY_GROUP"]],
            'assignPublicIp': 'ENABLED'
        }
    },
    overrides={
        'containerOverrides': [{
            'name': 'whisper-container',
            'environment': [
                {'name': 'S3_BUCKET', 'value': bucket},
                {'name': 'S3_KEY', 'value': key}
            ]
        }]
    }
)
```

The critical detail is `overrides.containerOverrides`. The task definition has
`S3_KEY` set to `"PLACEHOLDER"` (`ecs.tf:25-27`). At runtime, the Lambda
**overrides** that with the actual file key (`uploads/meeting.mp3`). This is how
a generic task definition gets parameterised for each specific file.

The Lambda finishes here. It doesn't wait for the Fargate task to complete -- it
fires and forgets. Total Lambda execution: under 1 second.

### Step 4: Fargate Provisions the Task

When `run_task()` is called, ECS does the following behind the scenes:

```
  ecs.run_task() called
       |
       v
  ECS Scheduler finds capacity in the Fargate fleet
       |
       v
  AWS provisions an ENI (Elastic Network Interface)
  in your subnet with a public IP
       |
       v
  Fargate pulls the Docker image from ECR:
  340752829546.dkr.ecr.eu-west-1.amazonaws.com/whisper-ecs:v1
       |
       v
  Container starts with injected environment variables:
    S3_BUCKET = "snaylor-meeting-recordings-bucket"
    S3_KEY    = "uploads/meeting.mp3"
       |
       v
  CMD ["python", "main.py"] runs
```

The public IP (`assignPublicIp: ENABLED`) is needed because the container must
reach S3 and ECR over the internet. Without it, you'd need a NAT Gateway (which
costs ~$30/month). For a personal project, a public IP is the simpler and cheaper
option.

This provisioning phase takes roughly 30-60 seconds.

### Step 5: The Container Transcribes the Audio

Inside the container, `main.py` runs four steps:

```python
# 1. Read environment variables
bucket = os.environ["S3_BUCKET"]
key    = os.environ["S3_KEY"]

# 2. Download the MP3 from S3
filename = key.split("/")[-1]                 # "meeting.mp3"
s3.download_file(bucket, key, "/tmp/meeting.mp3")

# 3. Load Whisper and transcribe
model = whisper.load_model("base")
result = model.transcribe("/tmp/meeting.mp3")
with open("/tmp/meeting.mp3.txt", "w", encoding="utf-8") as f:
    f.write(result["text"])

# 4. Upload the transcript to S3
s3.upload_file("/tmp/meeting.mp3.txt", bucket, "transcripts/meeting.mp3.txt")
```

The Whisper "base" model is a good balance of speed and accuracy. Larger models
(small, medium, large) are more accurate but need more memory and time.

All print statements in the container go to CloudWatch Logs at `/ecs/whisper`,
which is how you debug if something goes wrong.

### Step 6: The Container Exits and Fargate Stops

When `main.py` finishes (the `main()` function returns), the Python process exits,
the container stops, and ECS marks the task as `STOPPED`. AWS releases the compute
resources and the ENI.

This is the key property of a **task** vs a **service** in ECS:

- A **task** runs once and stops (like a batch job). This is what we use.
- A **service** keeps N copies running forever (like a web server).

Because we use `run_task()` (not a service), there's nothing to keep running when
the work is done. You only pay for the seconds the container was active.

### Step 7: S3 Fires the Second Event Notification

The transcript upload to `transcripts/meeting.mp3.txt` matches the second
notification rule (`lambda.tf:60-65`):

```hcl
lambda_function {
  lambda_function_arn = aws_lambda_function.summary_lambda.arn
  events              = ["s3:ObjectCreated:*"]
  filter_prefix       = "transcripts/"
  filter_suffix       = ".txt"
}
```

This triggers the `whisper-summary` Lambda.

### Step 8: The Summary Lambda Calls OpenAI

The summary Lambda (`summary_lambda.py`) does the following:

1. **Gets the OpenAI API key** from Secrets Manager
2. **Downloads the transcript** from S3
3. **Truncates to 15,000 characters** if needed (GPT-3.5-turbo has token limits)
4. **Calls OpenAI three times** with different prompts:
   - A general meeting summary
   - Extracted action items with owners and deadlines
   - A detailed 50-point summary
5. **Saves three markdown files** to `summaries/`:
   - `meeting.mp3_summary.md`
   - `meeting.mp3_actions.md`
   - `meeting.mp3_detailed.md`
6. **Generates presigned URLs** (temporary download links, valid for 7 days)
7. **Sends an HTML email via SES** with the summary, action items, and links

### Step 9: You Get an Email

An email arrives at `engsnayl@gmail.com` from `no-reply@engsnayl.com` with:

- The meeting summary rendered in HTML
- Action items as a bulleted list
- Clickable links to the full transcript and detailed summary

**Total elapsed time from upload to email: roughly 3-8 minutes**, depending on
the audio length. Most of that time is Whisper transcription.

---

## 7. Security Decisions and What Could Be Improved

### What's Done Well

**S3 public access is fully blocked** (`s3.tf:6-12`):

```hcl
resource "aws_s3_bucket_public_access_block" "block" {
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
```

This is a critical baseline. Without it, a misconfigured bucket policy could
accidentally expose your recordings to the internet.

**The OpenAI API key is in Secrets Manager**, not hardcoded in code or environment
variables. The Lambda retrieves it at runtime.

**IAM policies use specific resource ARNs** where possible. The ECS S3 policy
(`iam.tf:21-40`) is scoped to the recordings bucket, not `"*"`.

**CloudWatch logging is enabled** for Fargate with short retention (3 days),
balancing debuggability with cost.

### What Could Be Improved

**1. The ECS `ecs:RunTask` permission uses `Resource: "*"`** (`iam.tf:72`):

```hcl
{
  Effect = "Allow",
  Action = ["ecs:RunTask"],
  Resource = "*"
}
```

This allows the Lambda to run *any* task definition in the account. It should be
scoped to the specific task definition ARN:

```hcl
Resource = aws_ecs_task_definition.whisper_task.arn
```

**2. The SES permission uses `Resource: "*"`** (`iam.tf:115`):

This allows the Lambda to send email as *any* verified identity. It should be
scoped to the specific SES identity ARN.

**3. The task execution role and task role are the same** (`ecs.tf:11-12`):

```hcl
execution_role_arn = aws_iam_role.ecs_task_exec.arn
task_role_arn      = aws_iam_role.ecs_task_exec.arn
```

These serve different purposes:
- **Execution role**: Used by the ECS agent to pull images and write logs
- **Task role**: Used by the application code inside the container

Sharing them means the container has permissions it doesn't need (like pulling
images from ECR). Best practice is two separate roles.

**4. The Secrets Manager secret has a placeholder value in Terraform**
(`secrets.tf:7-9`):

```hcl
secret_string = jsonencode({
  apiKey = "REPLACE_ME_WITH_YOUR_KEY"
})
```

If you ever accidentally commit a real key here, it's in your Terraform state
file (which is stored locally). Better to create the secret in Terraform but set
the value manually through the AWS Console or CLI, outside of Terraform's
management.

**5. No encryption at rest on S3**:

The bucket doesn't specify server-side encryption. S3 now encrypts with SSE-S3
by default (since January 2023), so this is fine in practice, but explicitly
declaring it is clearer:

```hcl
resource "aws_s3_bucket_server_side_encryption_configuration" "enc" {
  bucket = aws_s3_bucket.recordings.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}
```

**6. No VPC flow logs or network isolation**:

The Fargate task runs in a subnet with a public IP. For a personal project this is
fine. In a production environment, you'd use private subnets with a NAT Gateway
and VPC endpoints for S3 and ECR to keep traffic off the public internet.

---

## 8. Cost Model: When Do I Pay and For What

One of the main advantages of this architecture is that **idle cost is nearly
zero**. Here's a breakdown of what each service charges.

### When the System is Idle (No Uploads)

| Service          | Idle Cost                     |
|------------------|-------------------------------|
| S3               | Pennies/month for stored files |
| Lambda           | $0 (no invocations)           |
| ECS Fargate      | $0 (no tasks running)         |
| ECR              | ~$0.10/GB/month for images    |
| Secrets Manager  | $0.40/month per secret        |
| SES              | $0                            |
| CloudWatch Logs  | Pennies for stored logs        |

**Total idle cost: roughly $1-2/month**, almost entirely from Secrets Manager
and ECR image storage.

### When You Process a Recording

Each upload triggers costs across the pipeline:

**Lambda (trigger)**:
- ~1 second execution, 512 MB memory
- Cost: effectively $0 (Lambda free tier includes 1M requests/month)

**ECS Fargate (transcription)**:
- 1 vCPU, 2 GB RAM
- Duration depends on recording length (say 5 minutes for a 30-min meeting)
- Cost: ~$0.05 per vCPU-hour + ~$0.005 per GB-hour
- **Roughly $0.005 - $0.02 per transcription**

**Lambda (summary)**:
- Up to 5 minutes, 1024 MB memory
- Cost: ~$0.001 per invocation

**OpenAI API**:
- 3 calls to GPT-3.5-turbo
- Cost depends on transcript length, roughly $0.01-0.05 per run

**SES**:
- $0.10 per 1,000 emails (effectively free at this scale)

**Total cost per recording: roughly $0.02 - $0.10**, depending on audio length
and transcript size. You could process hundreds of meetings per month for a few
dollars.

### What Would Get Expensive

- **Storing many large MP3 files** in S3 long-term (consider lifecycle rules to
  delete uploads after 30 days)
- **Using a larger Whisper model** (medium/large) with more Fargate CPU/memory
- **Leaving CloudWatch log retention at unlimited** instead of 3 days
- **A NAT Gateway** if you moved to private subnets ($30+/month just to exist)

---

## 9. Common Mistakes and Gotchas

### Gotcha 1: The S3 Event Notification Ordering Problem

The S3 notification (`lambda.tf:51-71`) has a `depends_on` that references Lambda
permissions:

```hcl
depends_on = [
  aws_lambda_permission.allow_s3_invoke,
  aws_lambda_permission.allow_s3_invoke_summary
]
```

If you remove this, `terraform apply` will intermittently fail. The reason: AWS
requires that Lambda permission policies exist *before* S3 tries to configure the
notification. Terraform doesn't know this from the resource arguments alone, so
you must tell it explicitly.

**Lesson**: When Terraform fails intermittently but works if you just run it again,
you probably have a missing `depends_on`.

### Gotcha 2: Fargate Needs Internet Access

The Fargate task has `assignPublicIp: ENABLED`. If you set this to `DISABLED`, the
task will start but then hang trying to pull the Docker image from ECR (or fail
trying to reach S3).

Fargate tasks in the `awsvpc` network mode get their own ENI. Without a public IP,
they need a NAT Gateway or VPC endpoints to reach AWS services. This is a common
source of "my Fargate task starts but immediately fails" debugging sessions.

### Gotcha 3: The PLACEHOLDER Environment Variable Pattern

The task definition has `S3_KEY = "PLACEHOLDER"` (`ecs.tf:25-27`). This looks like
a mistake but it's intentional. The Lambda overrides it at runtime via
`containerOverrides`. If you forget the override, the container will try to
download a file literally called "PLACEHOLDER" from S3 and fail.

If you're debugging a failed transcription, check CloudWatch logs for the actual
`S3_KEY` value -- it should be a real file path like `uploads/meeting.mp3`.

### Gotcha 4: The Summary Lambda's 15,000 Character Truncation

In `summary_lambda.py:44-46`:

```python
if len(transcript) > 15000:
    transcript = transcript[:15000] + "\n\n[TRUNCATED FOR LENGTH]"
```

GPT-3.5-turbo has a context window limit. If the transcript is too long, it gets
cut off. For very long meetings (2+ hours), the summary will only cover the first
portion. Moving to GPT-4-turbo (128k context) or chunking the transcript would
fix this, but would cost more per API call.

### Gotcha 5: Terraform State is Local

There's no remote backend configured. The state file (`terraform.tfstate`) lives
on your local machine. If you lose it, Terraform loses track of what it created,
and you'll have to import resources manually or recreate everything.

For a personal project this is acceptable, but in a team setting you'd use an S3
backend with DynamoDB locking:

```hcl
terraform {
  backend "s3" {
    bucket         = "my-terraform-state"
    key            = "meeting-transcriber/terraform.tfstate"
    region         = "eu-west-1"
    dynamodb_table = "terraform-locks"
  }
}
```

### Gotcha 6: Splitting Terraform Files

Terraform merges all `.tf` files in a directory automatically. This project splits
resources by concern (`main.tf`, `s3.tf`, `iam.tf`, `cloudwatch.tf`, `lambda.tf`,
`secrets.tf`, `ecs.tf`, `variables.tf`). The split is purely for human readability
-- it changes nothing about how `terraform plan` or `terraform apply` works.

If you ever need to reorganise, just move resource blocks between files. As long
as everything stays in the same directory, Terraform treats it identically.

### Gotcha 7: Docker Image Versioning

The ECS image uses a fixed tag (`whisper-ecs:v1`). If you rebuild and push a new
image with the same tag, existing Fargate tasks will still use the cached version.
You need to either:

- Use a new tag (`v2`, `v3`, etc.) and update the task definition
- Or force a new deployment after pushing

The Lambda image uses `latest`, which has the same problem but worse -- `latest`
is mutable by convention, so you never know which version is running without
checking the image digest.

### Gotcha 8: The Build Script Lives Outside the Repo

The Docker build context (`lambda_function.py`, `main.py`, `Dockerfile.ecs`) lives
in `C:\Users\naylo\Documents\lambda_container_build\`, which is separate from the
Terraform repo. This means:

- The application code isn't version-controlled with the infrastructure
- Someone cloning the repo can't build without those files
- The `build_and_deploy.sh` script uses an absolute path to that directory

Ideally, the container code would live inside this repo (e.g., in a `containers/`
directory) so everything is tracked together.

---

## Further Reading

If you want to go deeper on any of these topics:

- **Terraform**: Start with the official tutorials at https://developer.hashicorp.com/terraform/tutorials
- **ECS Fargate**: AWS docs on task definitions and networking: https://docs.aws.amazon.com/AmazonECS/latest/developerguide/AWS_Fargate.html
- **S3 Event Notifications**: https://docs.aws.amazon.com/AmazonS3/latest/userguide/EventNotifications.html
- **IAM Best Practices**: https://docs.aws.amazon.com/IAM/latest/UserGuide/best-practices.html
- **OpenAI Whisper**: https://github.com/openai/whisper
