#!/bin/sh
# 一键部署：先构建带国内镜像源的基础镜像，再启动全部服务
set -e
cd "$(dirname "$0")/.."

echo "=== 1/3 构建基础镜像 ll-base（apt/pip 走清华源） ==="
docker build -t ll-base:latest -f server/Dockerfile.base server/

echo "=== 2/3 构建并启动服务 ==="
docker compose up -d --build

echo "=== 3/3 状态 ==="
docker compose ps
echo
echo "访问：http://<服务器IP>/"
