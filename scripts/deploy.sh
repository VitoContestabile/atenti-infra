#!/bin/bash

set -e

echo "========================================"
echo "Starting production deployment..."
echo "========================================"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$ROOT_DIR"

COMPOSE="docker compose -f docker-compose.prod.yml"

echo "Loading environment..."
set -a
source .env
set +a

echo "Logging into GHCR..."
echo "$GHCR_PAT" | docker login ghcr.io -u "$GHCR_USER" --password-stdin

echo "Pulling latest images..."
$COMPOSE pull

echo "Stopping existing containers..."
$COMPOSE down --remove-orphans

# La base tiene que estar migrada ANTES de que arranque el backend: si no,
# el backend levanta contra un esquema viejo (o vacío en una VM nueva) y
# cada request muere con 500 / PrismaClientKnownRequestError.
echo "Starting database..."
$COMPOSE up -d --wait database

echo "Applying database migrations..."
$COMPOSE run --rm --no-deps backend npx prisma migrate deploy

echo "Starting containers..."
$COMPOSE up -d

echo "Cleaning unused images..."
docker image prune -f

echo ""
echo "Deployment completed!"
