import boto3
import os
import json
import base64
import time
import urllib.parse
from botocore.exceptions import ClientError
import openai
import markdown

# AWS Clients
s3 = boto3.client('s3')
secretsmanager = boto3.client('secretsmanager')
ses = boto3.client('ses')

def get_secret():
    """Get OpenAI API key from Secrets Manager"""
    try:
        secret_name = os.environ['OPENAI_SECRET_NAME']
        response = secretsmanager.get_secret_value(SecretId=secret_name)
        secret = response.get('SecretString') or base64.b64decode(response['SecretBinary']).decode('utf-8')
        return json.loads(secret)
    except Exception as e:
        print(f"Error getting secret: {str(e)}")
        raise

def get_transcript(bucket, key):
    """Download transcript from S3"""
    try:
        decoded_key = urllib.parse.unquote_plus(key)
        print(f"Attempting to download transcript with decoded key: {decoded_key}")
        response = s3.get_object(Bucket=bucket, Key=decoded_key)
        transcript = response['Body'].read().decode('utf-8')
        print(f"Downloaded transcript from s3://{bucket}/{decoded_key}")
        return transcript, decoded_key
    except Exception as e:
        print(f"Error downloading transcript: {str(e)}")
        raise

def generate_summary(transcript, api_key):
    openai.api_key = api_key

    # Truncate transcript if it's too long (15,000 chars as requested)
    if len(transcript) > 15000:
        print(f"Truncating transcript from {len(transcript)} to 15000 chars")
        transcript = transcript[:15000] + "\n\n[TRUNCATED FOR LENGTH]"

    def ask(prompt, system):
        for attempt in range(3):
            try:
                response = openai.ChatCompletion.create(
                    model="gpt-3.5-turbo",
                    messages=[
                        {"role": "system", "content": system},
                        {"role": "user", "content": prompt}
                    ]
                )
                return response.choices[0].message.content
            except Exception as e:
                if "rate limit" in str(e).lower():
                    wait = (2 ** attempt)
                    print(f"Rate limited. Retrying in {wait}s...")
                    time.sleep(wait)
                else:
                    raise

    return {
        "summary": ask(
            f"Summarise this transcript in markdown format:\n\n{transcript}",
            "You are a professional summariser of meetings."
        ),
        "action_items": ask(
            f"Extract action items from this transcript as a bulleted list with owners and deadlines if possible:\n\n{transcript}",
            "You are an expert in identifying action items and follow-ups from business meetings."
        ),
        "detailed_summary": ask(
            f"Write a 50-point detailed summary of this transcript with numbered bullet points:\n\n{transcript}",
            "You are a business analyst writing detailed technical summaries."
        )
    }

def save_to_s3(bucket, prefix, filename, content):
    key = f"{prefix}/{filename}"
    try:
        s3.put_object(
            Bucket=bucket,
            Key=key,
            Body=content.encode('utf-8'),
            ContentType="text/plain"
        )
        print(f"Saved to s3://{bucket}/{key}")
        return key
    except Exception as e:
        print(f"Error saving {filename}: {str(e)}")
        raise

def create_presigned_url(bucket, key, expires=604800):
    """Create a properly formatted presigned URL for S3 objects"""
    try:
        # Ensure the key is properly URL encoded for the presigned URL
        # But in a way that works with S3's requirements
        key = key.replace('+', ' ')  # Replace any + with spaces first
        url = s3.generate_presigned_url(
            'get_object',
            Params={'Bucket': bucket, 'Key': key},
            ExpiresIn=expires
        )
        print(f"Created presigned URL for s3://{bucket}/{key}")
        return url
    except Exception as e:
        print(f"Error creating presigned URL: {str(e)}")
        raise

def send_email(recipient, filename, summary, action_items, transcript_url, detailed_summary_url):
    try:
        sender = "no-reply@engsnayl.com"
        subject = f"Meeting Summary: {filename}"

        # Convert markdown to HTML for better email formatting
        html_summary = markdown.markdown(summary)
        html_actions = markdown.markdown(action_items)

        body_html = f"""
        <html>
        <body style="font-family: Arial, sans-serif;">
          <h1>Meeting Summary</h1>
          {html_summary}
          
          <h2>Action Items</h2>
          {html_actions}
          
          <h2>Resources</h2>
          <p><a href="{transcript_url}">Full Transcript</a></p>
          <p><a href="{detailed_summary_url}">Detailed Summary</a></p>
        </body>
        </html>
        """

        body_text = f"""
        MEETING SUMMARY: {filename}

        {summary}

        ACTION ITEMS

        {action_items}

        RESOURCES

        Full Transcript: {transcript_url}
        Detailed Summary: {detailed_summary_url}
        """

        response = ses.send_email(
            Source=sender,
            Destination={'ToAddresses': [recipient]},
            Message={
                'Subject': {'Data': subject},
                'Body': {
                    'Text': {'Data': body_text},
                    'Html': {'Data': body_html}
                }
            }
        )
        print(f"Email sent. Message ID: {response['MessageId']}")
        return response['MessageId']
    except ClientError as e:
        print(f"SES error: {str(e)}")
        raise

def lambda_handler(event, context):
    try:
        record = event['Records'][0]['s3']
        bucket = record['bucket']['name']
        key = record['object']['key']

        print(f"Processing transcript: s3://{bucket}/{key}")
        base_name = urllib.parse.unquote_plus(key).split('/')[-1].rsplit('.', 1)[0]

        secret = get_secret()
        api_key = secret.get("api-key")

        transcript_text, decoded_key = get_transcript(bucket, key)
        summaries = generate_summary(transcript_text, api_key)

        summary_prefix = "summaries"
        summary_key = save_to_s3(bucket, summary_prefix, f"{base_name}_summary.md", summaries["summary"])
        action_key = save_to_s3(bucket, summary_prefix, f"{base_name}_actions.md", summaries["action_items"])
        detailed_key = save_to_s3(bucket, summary_prefix, f"{base_name}_detailed.md", summaries["detailed_summary"])

        # Create presigned URLs with proper handling of special characters
        full_transcript_url = create_presigned_url(bucket, decoded_key)
        detailed_summary_url = create_presigned_url(bucket, detailed_key)

        send_email(
            "engsnayl@gmail.com",
            base_name,
            summaries["summary"],
            summaries["action_items"],
            full_transcript_url,
            detailed_summary_url
        )

        return {
            'statusCode': 200,
            'body': json.dumps({'message': 'Summary and email successfully sent'})
        }

    except Exception as e:
        print(f"Error processing: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps({'error': str(e)})
        }