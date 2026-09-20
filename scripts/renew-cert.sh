#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$ROOT_DIR"

echo "[$(date '+%F %T')] Renewing certificates..."
docker compose -f docker-compose.prod.yml run --rm certbot renew

echo "[$(date '+%F %T')] Reloading nginx..."
docker compose -f docker-compose.prod.yml restart nginx

echo "[$(date '+%F %T')] Done."
