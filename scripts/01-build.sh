#!/usr/bin/env bash
# 构建 ardinals-mvp 镜像
set -euo pipefail
cd "$(dirname "$0")/.."
IMAGE_NAME="${IMAGE_NAME:-ardinals-mvp:latest}"
echo "Building $IMAGE_NAME ..."
docker build -t "$IMAGE_NAME" -f docker/Dockerfile docker/
docker images "$IMAGE_NAME"
