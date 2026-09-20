# Runbook — Deploy de Atenti

Cómo levantar este stack en una VM limpia de AWS, de cero.

Escrito el 2026-09-20 al migrar de la VM vieja (`ip-172-31-47-253`, 911 MB RAM)
a la nueva (`ip-172-31-34-125`, Ubuntu 26.04 "resolute", 3.7 GB RAM).

## Resumen

Con la VM ya provista (disco de 20 GB, Docker instalado, puertos 80/443 abiertos
y el DNS apuntando a la IP), levantar el stack son tres pasos:

```bash
git clone https://github.com/VitoContestabile/atenti-infra.git ~/atenti-infra
cd ~/atenti-infra
cp /ruta/a/tu/.env .              # el único archivo que no está en git
./scripts/init-letsencrypt.sh     # certificado (idempotente)
./scripts/deploy.sh               # migra la base y levanta todo
```

Opcional, sólo para tener datos con los que entrar:

```bash
docker compose -f docker-compose.prod.yml exec -T backend node dist/prisma/seed.js
```

La renovación del certificado es automática (vive en el compose, sección 9).
El resto del documento explica cada paso y las trampas de cada uno.

---

## 0. Requisitos de la VM

| Recurso | Mínimo real | Por qué |
|---|---|---|
| RAM | 2 GB | Con 911 MB (VM vieja) el stack no entraba. 3.7 GB va holgado. |
| **Disco** | **20 GB** | **8 GB NO alcanza.** Ver el desglose abajo. Esta VM corre con 20 GB: usa 8.8 GB, libres 9.5 GB. |
| Puertos | 80, 443 abiertos en el security group | Certbot valida por HTTP en el 80. |

### Por qué 20 GB y no 8

Tamaño real en disco de las imágenes del stack:

| Imagen | En disco |
|---|---|
| `postgres:15-alpine` | 417 MB |
| `certbot/certbot` | 293 MB |
| `nginx:latest` | 242 MB |
| `quay.io/minio/minio` | 241 MB |
| `atenti-backend` | ~700 MB (273 MB comprimido) |
| `atenti-frontend` | ~1.1 GB (440 MB comprimido) |
| **Total imágenes** | **~3 GB** |

Más el SO (~4.5 GB), el swap (1 GB), los volúmenes de datos y el espacio
temporal que Docker necesita durante la extracción de cada capa.

Con un EBS de 8 GB el deploy **falla** con
`no space left on device` al extraer las capas del backend/frontend.

---

## 1. Expandir el disco (si el EBS es menor a 20 GB)

En la consola de AWS: **EC2 → Volumes → seleccionar el volumen → Actions →
Modify volume → Size = 20 GB**. Después, en la VM:

```bash
sudo growpart /dev/nvme0n1 1     # expande la partición
sudo resize2fs /dev/nvme0n1p1    # expande el filesystem
df -h /                          # verificar
```

La instancia no necesita reiniciarse.

---

## 2. Docker

Los paquetes de `apt` dan versiones viejas. Usar el repositorio oficial de Docker.
Reemplazar `resolute` por el codename de la distro (`. /etc/os-release; echo $VERSION_CODENAME`).

```bash
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu resolute stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

sudo usermod -aG docker ubuntu
sudo systemctl enable --now docker
```

El grupo `docker` recién aplica al volver a loguearse. Para usarlo en la misma
sesión: `newgrp docker` (o prefijar los comandos con `sg docker -c "..."`).

Versiones instaladas en esta VM: Docker **29.8.1**, Compose **v5.5.1**.

> El binario manual en `~/.docker/cli-plugins/` de la VM vieja **ya no hace falta**:
> el plugin viene con `docker-compose-plugin`.

---

## 3. Swap

La VM viene sin swap. 2 GB con un disco de 20 GB (con el EBS de 8 GB había que
bajarlo a 1 GB porque el swapfile sale del mismo disco).

```bash
sudo fallocate -l 2G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

---

## 4. Repo y secretos

```bash
git clone https://github.com/VitoContestabile/atenti-infra.git ~/atenti-infra
cd ~/atenti-infra
# Los scripts ya vienen ejecutables (git guarda el modo 100755).
# Si por algún motivo no lo están: chmod +x scripts/*.sh
```

Copiar a mano el **`.env` real** (no está en git). `.env.example` tiene las 26
claves que hacen falta, en el mismo orden, con notas de formato. Contiene:

- `POSTGRES_*`, `MINIO_*` — credenciales de la base y el storage
- `GHCR_USER` / `GHCR_PAT` — token de GitHub para bajar las imágenes privadas
- `AUTH_PQ_PRIVATE_KEY` / `AUTH_PQ_PUBLIC_KEY` — claves de firma de tokens
- `DOMAIN_NAME=atenzia.duckdns.org`, `CERTBOT_EMAIL`
- `MAIL_*`, `AUTH_TOKEN_TTL`

> **Trampa:** los valores con `<`, `>`, espacios o `#` tienen que ir **entre
> comillas dobles**. `deploy.sh` hace `source .env` con `set -e`, y un
> `MAIL_FROM=Atenzia <no-reply@atenzia.local>` sin comillas es una redirección
> de bash: rompe el script entero. Correcto:
> `MAIL_FROM="Atenzia <no-reply@atenzia.local>"`
>
> Verificar siempre con: `( set -a; source .env; set +a; echo ok )`

`.gitignore` ignora `.env`, `certbot/` y `.idea/`. **No commitear el `.env`:**
tiene el PAT y la clave privada.

---

## 5. DNS

Apuntar `atenzia.duckdns.org` a la IP pública de la VM nueva en
[duckdns.org](https://duckdns.org). Verificar antes de pedir el certificado
(si el DNS apunta a otro lado, certbot falla):

```bash
getent hosts atenzia.duckdns.org
curl -s http://169.254.169.254/latest/meta-data/public-ipv4   # IP de esta VM
```

Las dos tienen que coincidir.

---

## 6. Certificado (primera vez)

```bash
cd ~/atenti-infra
./scripts/init-letsencrypt.sh
```

El script se encarga de todo el huevo-y-gallina: `nginx/conf.d/app-https.conf`
apunta a certificados que todavía no existen, así que nginx no arranca y certbot
no puede validar por webroot. Entonces el script deja temporalmente sólo la
config HTTP de `nginx/bootstrap/`, levanta nginx, espera a que responda en el 80,
pide el certificado y restaura la config HTTPS. Si algo falla en el medio, un
`trap` restaura `conf.d/` igual.

Es **idempotente**: si el certificado ya existe no hace nada. Para reemitirlo,
`./scripts/init-letsencrypt.sh --force`.

Al terminar deja nginx **parado** a propósito: con la config HTTPS puesta, nginx
no arranca hasta que existan `frontend` y `backend` (ver la nota de la sección 7).
Lo levanta `deploy.sh`.

> **Nunca poner los dos `.conf` juntos en `conf.d/`.** Los dos declaran un
> `server` en el puerto 80 con el mismo `server_name`: nginx carga el primero
> alfabéticamente (`app-http.conf`), el redirect a HTTPS nunca ocurre y el sitio
> responde `HTTP OK` en texto plano. Por eso el de bootstrap vive fuera de
> `conf.d/` y el script lo copia y lo borra.

Certificado actual: emitido 2026-09-20, **vence 2026-12-19**.

---

## 7. Deploy

```bash
cd ~/atenti-infra && ./scripts/deploy.sh
```

En orden: login a GHCR, `pull`, `down --remove-orphans`, levanta **sólo la base**
y espera a que esté *healthy*, corre **`prisma migrate deploy`**, recién ahí
levanta el resto del stack, y al final `docker image prune -f`.

Verificar:

```bash
docker compose -f docker-compose.prod.yml ps
curl -sI https://atenzia.duckdns.org/                       # 200, frontend
curl -s  https://atenzia.duckdns.org/backend/notifications  # 200, API
```

Estado esperado de los contenedores:

| Servicio | Estado |
|---|---|
| `database` | Up (healthy) |
| `backend`, `frontend`, `minio`, `nginx` | Up |
| `certbot-renew` | **Up** — es el loop de renovación |
| `certbot` | `Exited (1)` — **normal**, sólo corre cuando se lo invoca |

`/backend/` a secas devuelve `404`: el backend no tiene ruta raíz. No es el proxy;
para probar el proxy usar una ruta real como `/backend/notifications`.

> **nginx no arranca si falta el frontend o el backend.** nginx resuelve los
> upstreams de `proxy_pass` al iniciar; si `frontend` no está levantado falla con
> `[emerg] host not found in upstream "frontend"` y queda en crash loop.
> Por eso hay que levantar el stack completo con `deploy.sh`, no servicio por
> servicio. Si nginx quedó reiniciándose, levantar frontend y backend y después
> `docker compose -f docker-compose.prod.yml restart nginx`.

---

## 8. Datos iniciales (seed)

**Las migraciones ya no son un paso manual**: `deploy.sh` levanta la base, espera
a que esté *healthy* y corre `prisma migrate deploy` **antes** de arrancar el
backend. Es idempotente — si no hay migraciones pendientes no hace nada.

El orden importa: si el backend arranca contra una base sin migrar, levanta
igual —Nest mapea todas las rutas y parece sano— pero cada request muere con
`500` / `PrismaClientKnownRequestError` y los jobs programados fallan cada
minuto. Por eso se migra antes y no en paralelo.

Verificar (deben ser ~68 tablas):

```bash
docker compose -f docker-compose.prod.yml exec -T database \
  psql -U postgres -d app -c "select count(*) from information_schema.tables where table_schema='public'"
```

### Seed (manual, sólo datos de prueba)

El seed **no** corre en el deploy: son datos de prueba, no algo que quieras
recrear en cada release. Sin él la base queda con el esquema pero sin usuarios,
así que no se puede iniciar sesión.

**`npx prisma db seed` NO funciona** en la imagen de producción: el comando
configurado es `tsx prisma/seed.ts` y `tsx` es una devDependency que no está
instalada (`spawn tsx ENOENT`). Instalar `tsx` al vuelo con `npx -y tsx` tampoco
alcanza: `prisma/seed.ts` importa 7 módulos de `../src/`, y la imagen de
producción sólo trae `dist/`.

El seed **ya viene compilado**. Correr directamente:

```bash
docker compose -f docker-compose.prod.yml exec -T backend node dist/prisma/seed.js
```

Termina con `Seed operativo ejecutado correctamente`. Deja 1 institución,
4 pacientes y 4 usuarios de prueba:

| Email | Rol |
|---|---|
| `sofia.admin@atenti.test` | ADMIN |
| `carla.medica@atenti.test` | DOCTOR |
| `ana.enfermera@atenti.test` | NURSE |
| `juan.enfermero@atenti.test` | NURSE |

Las contraseñas están en `prisma/seed.ts` del repo del backend. Los avisos
`Sin imagen para ...` durante el seed son normales (faltan los archivos en
`seed-images/`, no rompen nada).

---

## 9. Renovación automática del certificado

**No hay que configurar nada**: la renovación vive en el `docker-compose.prod.yml`
y arranca con el stack. No depende de un cron de la VM (que había que acordarse
de crear, y que fallaba en silencio si el script tenía un problema).

- **`certbot-renew`** — `restart: always`, corre `certbot renew` cada 12 h.
  Certbot no hace nada hasta que falten 30 días para el vencimiento, así que
  repetirlo es barato. Debe aparecer como **`Up`**, no `Exited`.
- **`nginx`** — recarga cada 6 h. Hace falta porque nginx lee los certificados
  una sola vez al arrancar: sin ese reload seguiría sirviendo el viejo.

Verificar que está andando:

```bash
docker compose -f docker-compose.prod.yml ps certbot-renew      # -> Up
docker compose -f docker-compose.prod.yml logs certbot-renew    # -> "Certificate not yet due for renewal"
```

El servicio **`certbot`** (sin `-renew`) es otra cosa: no corre solo, es el que
usan los scripts para invocaciones puntuales. Están separados a propósito — si el
loop fuera el entrypoint de `certbot`, los `docker compose run --rm certbot
certonly ...` de `init-letsencrypt.sh` caerían adentro del loop en vez de emitir
el certificado.

Para forzar una renovación a mano:

```bash
./scripts/renew-cert.sh
```

---

## Cambios respecto de la VM vieja

1. **`minio/minio` → `quay.io/minio/minio`.** El repo `minio/minio` **ya no
   existe en Docker Hub** (la API devuelve `object not found`). En la VM vieja
   andaba porque la imagen estaba cacheada localmente; en una VM limpia el pull
   falla con `pull access denied`. El registry oficial de MinIO es quay.io.
2. **`MAIL_FROM` entre comillas** en el `.env` — ver sección 4.
3. **`app-http.conf` movido a `nginx/bootstrap/`** — ver sección 6.
4. **`.gitignore`** — estaba vacío, ahora protege `.env`, `certbot/` y `.idea/`.
5. **Compose oficial vía apt**, no el binario manual en `~/.docker/cli-plugins/`.
   Ojo: el `~/.docker/config.json` de la VM vieja no se migra — hay que rehacer
   el `docker login ghcr.io` (lo hace `deploy.sh` solo).
6. **nginx del sistema**: en Ubuntu 26.04 no viene instalado, no hay nada que
   deshabilitar. Si estuviera: `sudo systemctl disable --now nginx`.
7. **`renew-cert.sh` arreglado.** Corría `docker compose` **sin** `-f
   docker-compose.prod.yml`, y como el archivo no se llama `docker-compose.yml`
   fallaba con `no configuration file provided: not found`. Desde el cron eso
   fallaba en silencio (a un log que nadie mira) y **el certificado hubiera
   expirado**. Ahora usa `-f` y hace `cd` a la raíz del repo por su cuenta.
8. **Disco de 20 GB**, ver sección 0.
9. **`deploy.sh` corre las migraciones de Prisma** antes de arrancar el backend.
   Era el paso manual más fácil de olvidarse, porque no falla ruidosamente: el
   backend levanta "sano" y todo responde 500.
10. **`init-letsencrypt.sh` hace solo el swap de configs de nginx** y es
    idempotente. Antes eran cinco pasos manuales de mover archivos.
11. **Renovación automática en el compose** (`certbot-renew` + reload de nginx),
    en vez de un cron en la VM. Viaja con el repo: una VM nueva la tiene sin que
    nadie configure nada.

## Pendiente / a revisar

- `BACKEND_URL=https://atenzia.duckdns.org/api` en el `.env`, pero nginx proxea
  `/backend/` y el frontend usa `NEXT_PUBLIC_API_BASE_URL=.../backend`. La ruta
  `/api` no existe en la config de nginx. Revisar para qué usa el backend esa
  variable — puede ser un link roto en los mails.
- `MAIL_HOST=localhost` / `MAIL_PORT=1025` apunta a un mailhog que no está en el
  compose. Con `MAIL_ENABLED=true` el envío de mails va a fallar.
- Las imágenes usan tag `latest`. Para que el deploy sea reproducible convendría
  pinear versiones.

## Datos

Esta VM arrancó **limpia** (sin migrar datos de la vieja). Para migrar
`database-data` y `minio-data` en el futuro:

```bash
# en la VM origen
docker run --rm -v atenti-infra_database-data:/v -v $PWD:/b alpine tar czf /b/db.tgz -C /v .
docker run --rm -v atenti-infra_minio-data:/v -v $PWD:/b alpine tar czf /b/minio.tgz -C /v .
# copiar por scp, y en la VM destino (con el stack parado)
docker run --rm -v atenti-infra_database-data:/v -v $PWD:/b alpine tar xzf /b/db.tgz -C /v
```

Para la base, un `pg_dump` es más portable que copiar el volumen crudo.
