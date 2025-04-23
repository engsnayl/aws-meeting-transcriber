#!/bin/bash
set -e

echo "Packaging Summary Lambda function..."

# Create a temporary directory for dependencies
mkdir -p package/
cd package/

# Install dependencies
pip install -r requirements.txt -t .

# Copy lambda function code
cp ../summary_lambda.py .

# Create zip package
zip -r ../summary_lambda.zip .

# Clean up
cd ..
rm -rf package/

echo "Created summary_lambda.zip successfully!"