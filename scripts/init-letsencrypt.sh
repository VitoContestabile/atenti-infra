#!/bin/bash

set -e

set -a
source .env
set +a

echo "Starting nginx..."
docker compose -f docker-compose.prod.yml up -d nginx

echo "Requesting SSL certificates..."

docker compose -f docker-compose.prod.yml run --rm certbot certonly \
  --webroot \
  --webroot-path=/var/www/certbot \
  -d $DOMAIN_NAME \
  --email $CERTBOT_EMAIL \
  --agree-tos \
  --no-eff-email

echo "Restarting nginx..."
docker compose -f docker-compose.prod.yml restart nginx

echo "SSL certificates generated!"