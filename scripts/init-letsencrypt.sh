#!/bin/bash
#
# Emite el certificado inicial de Let's Encrypt.
#
# Resuelve el huevo-y-gallina del arranque: nginx/conf.d/app-https.conf apunta a
# certificados que todavía no existen, así que nginx no arranca y certbot no
# puede validar por webroot. El script deja temporalmente sólo la config HTTP
# de nginx/bootstrap/, emite el certificado y restaura la config HTTPS.
#
# Es idempotente: si el certificado ya existe no hace nada (--force para
# reemitirlo igual).

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$ROOT_DIR"

COMPOSE="docker compose -f docker-compose.prod.yml"

CONF_D="nginx/conf.d"
HTTPS_CONF="$CONF_D/app-https.conf"
HTTP_CONF="$CONF_D/app-http.conf"
BOOTSTRAP_CONF="nginx/bootstrap/app-http.conf"
HELD_CONF="$ROOT_DIR/.app-https.conf.held"

FORCE=0
[ "$1" = "--force" ] && FORCE=1

set -a
source .env
set +a

if [ -z "$DOMAIN_NAME" ] || [ -z "$CERTBOT_EMAIL" ]; then
  echo "ERROR: faltan DOMAIN_NAME o CERTBOT_EMAIL en .env"
  exit 1
fi

mkdir -p certbot/www certbot/conf

# El directorio live/ lo escribe certbot como root, así que no se puede
# chequear desde el host sin sudo: se consulta desde adentro del contenedor.
cert_exists() {
  $COMPOSE run --rm --no-deps --entrypoint sh certbot \
    -c "test -d /etc/letsencrypt/live/$DOMAIN_NAME" >/dev/null 2>&1
}

if [ "$FORCE" -eq 0 ] && cert_exists; then
  echo "El certificado de $DOMAIN_NAME ya existe. No hay nada que hacer."
  echo "(usar '$0 --force' para reemitirlo)"
  exit 0
fi

# Pase lo que pase, dejar nginx/conf.d como estaba.
restore_conf() {
  rm -f "$HTTP_CONF"
  [ -f "$HELD_CONF" ] && mv "$HELD_CONF" "$HTTPS_CONF"
  return 0
}
trap restore_conf EXIT

echo "Swapping nginx to the bootstrap HTTP-only config..."
# Los dos .conf no pueden convivir en conf.d: declaran el mismo server_name en
# el puerto 80 y nginx se queda con el primero alfabéticamente.
[ -f "$HTTPS_CONF" ] && mv "$HTTPS_CONF" "$HELD_CONF"
cp "$BOOTSTRAP_CONF" "$HTTP_CONF"

echo "Starting nginx..."
$COMPOSE up -d --no-deps --force-recreate nginx

echo -n "Waiting for nginx to answer on port 80"
for i in $(seq 1 30); do
  if curl -fsS -m 3 http://127.0.0.1/ >/dev/null 2>&1; then
    echo " - ready"
    break
  fi
  echo -n "."
  sleep 1
  if [ "$i" -eq 30 ]; then
    echo ""
    echo "ERROR: nginx no respondió en el puerto 80."
    $COMPOSE logs --tail=20 nginx
    exit 1
  fi
done

echo "Requesting SSL certificates for $DOMAIN_NAME..."
$COMPOSE run --rm certbot certonly \
  --webroot \
  --webroot-path=/var/www/certbot \
  -d "$DOMAIN_NAME" \
  --email "$CERTBOT_EMAIL" \
  --agree-tos \
  --no-eff-email

echo "Restoring the HTTPS config..."
restore_conf
trap - EXIT

# nginx con la config HTTPS no arranca si frontend/backend no resuelven
# ("host not found in upstream"), así que se deja parado: lo levanta deploy.sh.
echo "Stopping nginx (deploy.sh lo levanta con el stack completo)..."
$COMPOSE stop nginx >/dev/null 2>&1 || true

echo ""
echo "SSL certificates generated!"
echo "Siguiente paso: ./scripts/deploy.sh"
