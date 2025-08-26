@echo off
setlocal ENABLEDELAYEDEXPANSION

REM ===== Load .env =====
for /f "usebackq tokens=1,2 delims==" %%A in (".env") do (
    set %%A=%%B
)

REM ===== Check tar file exists =====
if not exist "%DDN_ECR_IMG_TAR%" (
    echo [ERROR] TAR file not found: %DDN_ECR_IMG_TAR%
    exit /b 1
)

echo [INFO] Loading docker image from %DDN_ECR_IMG_TAR%
for /f "tokens=*" %%L in ('docker load -i "%DDN_ECR_IMG_TAR%"') do set LOAD_OUT=%%L
echo [INFO] docker load => %LOAD_OUT%

echo [DONE] Image loaded locally.
endlocal
