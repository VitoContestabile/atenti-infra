#!/bin/bash

docker compose run --rm certbot renew
docker compose restart nginx