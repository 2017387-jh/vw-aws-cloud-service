#!/bin/bash
set -e

echo "======================================"
echo "   Docker Cleanup Start..."
echo "   (Containers, Images, Networks, Volumes)"
echo "======================================"

# Stop running containers
echo "[1/5] Stopping running containers..."
docker ps -q | xargs -r docker stop

# Remove all containers
echo "[2/5] Removing all containers..."
docker ps -aq | xargs -r docker rm -f

# Remove all images
echo "[3/5] Removing all images..."
docker images -q | xargs -r docker rmi -f

# Remove unused networks
echo "[4/5] Removing unused networks..."
docker network prune -f

# Remove unused volumes
echo "[5/5] Removing unused volumes..."
docker volume prune -f

# Final system prune
echo "--------------------------------------"
echo "Additional system cleanup..."
docker system prune -a -f --volumes

echo "======================================"
echo "   Docker Cleanup Done!"
echo "======================================"
