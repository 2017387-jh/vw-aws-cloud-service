# 1-1. Create IAM Role (Assume Policy)
aws iam create-role \
  --role-name AmazonSageMaker-ExecutionRole \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Principal": { "Service": "sagemaker.amazonaws.com" },
        "Action": "sts:AssumeRole"
      }
    ]
  }'

# 1-2. Apply IAM role (ECR, S3, CloudWatch)
aws iam attach-role-policy \
  --role-name AmazonSageMaker-ExecutionRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonSageMakerFullAccess

aws iam attach-role-policy \
  --role-name AmazonSageMaker-ExecutionRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess

aws iam attach-role-policy \
  --role-name AmazonSageMaker-ExecutionRole \
  --policy-arn arn:aws:iam::aws:policy/CloudWatchFullAccess

aws iam get-role --role-name AmazonSageMaker-ExecutionRole \
  --query "Role.Arn" --output text