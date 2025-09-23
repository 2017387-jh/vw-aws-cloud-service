# vw-aws-cloud-service

## install python packages

pip install -r requirements.txt

## CloudShell	
- Clone
  - git clone https://github.com/2017387-jh/vw-aws-cloud-service.git
- Pull
  - git pull origin main
- 권한 부여
  - chmod +x (file name)

## AWS CLI Login
```
aws configure
AWS Access Key ID: 
Secret access key: 
Default region name: ap-northeast-2
Default output format: json
```

## Upload Docker Image & Create Sagemaker endpoint
생성한 Docker Image를 ECR에 업로드하고, Sagemaker의 Endpoint를 만드는 과정

1. Docker Image 생성
   1. 

```
vw-aws-cloud-service
├─ .env.sample
├─ README.md
└─ script
   ├─ .env
   ├─ s3_create_bucket.sh
   ├─ s3_delete_bucket.sh
   ├─ s3_download_file.sh
   └─ s3_upload_file.sh
```