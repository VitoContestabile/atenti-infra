#!/bin/bash

set -e

echo "========================================"
echo "Starting production deployment..."
echo "========================================"

set -a
source ../.env
set +a

echo "Logging into GHCR..."

echo "$GHCR_PAT" | docker login ghcr.io -u "$GHCR_USER" --password-stdin

echo "Pulling latest images..."
docker-compose -f ../docker-compose.prod.yml pull

echo "Starting containers..."
docker-compose -f ../docker-compose.prod.yml up -d --remove-orphans

echo "Cleaning unused images..."
docker image prune -f

echo ""
echo "Deployment completed!"