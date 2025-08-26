@echo off

REM ===== Load .env =====
for /f "usebackq tokens=1,2 delims==" %%A in (".env") do (
    set %%A=%%B
)

REM ===== Docker login =====
for /f "usebackq tokens=*" %%P in (`aws ecr get-login-password --region %AWS_REGION%`) do (
    echo %%P | docker login --username AWS --password-stdin %ACCOUNT_ID%.dkr.ecr.%AWS_REGION%.amazonaws.com
)
if errorlevel 1 (
    echo [ERROR] Docker login failed
    exit /b 1
)


REM ===== Image URI =====
set IMAGE_URI_BASE=%ACCOUNT_ID%.dkr.ecr.%AWS_REGION%.amazonaws.com/%DDN_ECR_REPO%
set IMAGE_URI_TAG=%IMAGE_URI_BASE%:%DDN_ECR_TAG%
set IMAGE_URI_LATEST=%IMAGE_URI_BASE%:latest

REM ===== Tagging =====
docker image inspect %DDN_LOCAL_IMG%:%DDN_ECR_TAG% >nul 2>&1
if %errorlevel%==0 (
    set SRC_REF=%DDN_LOCAL_IMG%:%DDN_ECR_TAG%
) else (
    for /f "tokens=*" %%I in ('docker images -q ^| head -n 1') do set SRC_REF=%%I
)

echo [INFO] Tagging %SRC_REF% -> %IMAGE_URI_TAG% and :latest
docker tag %SRC_REF% %IMAGE_URI_TAG%
docker tag %SRC_REF% %IMAGE_URI_LATEST%

echo [INFO] Pushing %IMAGE_URI_TAG%
docker push %IMAGE_URI_TAG%

echo [INFO] Pushing %IMAGE_URI_LATEST%
docker push %IMAGE_URI_LATEST%

echo [DONE] Pushed to ECR.
endlocal
