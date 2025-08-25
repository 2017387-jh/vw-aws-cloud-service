@echo off
echo ======================================
echo   Docker Cleanup Start...
echo   (Containers, Images, Networks, Volumes)
echo ======================================

REM Stop running containers
echo [1/5] Stopping running containers...
docker stop (docker ps -q) >nul 2>&1

REM Remove all containers
echo [2/5] Removing all containers...
docker rm -f (docker ps -aq) >nul 2>&1

REM Remove all images
echo [3/5] Removing all images...
docker rmi -f (docker images -q) >nul 2>&1

REM Remove unused networks
echo [4/5] Removing unused networks...
docker network prune -f

REM Remove unused volumes
echo [5/5] Removing unused volumes...
docker volume prune -f

REM Final system prune
echo --------------------------------------
echo Additional system cleanup...
docker system prune -a -f --volumes

echo ======================================
echo   Docker Cleanup Done!
echo ======================================
pause
