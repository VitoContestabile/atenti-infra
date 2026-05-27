#!/bin/bash

set -e

echo "========================================"
echo "Starting production deployment..."
echo "========================================"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$ROOT_DIR"

echo "Loading environment..."
set -a
source .env
set +a

echo "Logging into GHCR..."
echo "$GHCR_PAT" | docker login ghcr.io -u "$GHCR_USER" --password-stdin

echo "Pulling latest images..."
docker compose -f docker-compose.prod.yml pull

echo "Stopping existing containers..."
docker compose -f docker-compose.prod.yml down --remove-orphans

echo "Starting containers..."
docker compose -f docker-compose.prod.yml up -d

echo "Cleaning unused images..."
docker image prune -f

echo ""
echo "Deployment completed!"