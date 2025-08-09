#!/usr/bin/env bash
set -euo pipefail

# =========================
# Instalador Dify (Self-host) para Ubuntu 24.x
# Modo: Nginx del sistema + Docker Compose
# Uso:  ./InstalaDify.sh dify.urmah.ai
# Requisitos previos:
#   - Nginx instalado y corriendo (config por defecto de Ubuntu)
#   - Docker y Docker Compose instalados
#   - Este script y los certificados (fullchain.pem, privkey.pem) están en la MISMA carpeta
# Notas de seguridad:
#   - Los .pem se COPIAN a /etc/ssl/certificados/<dominio>/ con permisos 644/600 y root:root
#   - Postgres persistente en /opt/dify/<dominio>/data/postgres
# =========================

# --------- Helpers ---------
red()   { echo -e "\033[31m$*\033[0m"; }
green() { echo -e "\033[32m$*\033[0m"; }
yellow(){ echo -e "\033[33m$*\033[0m"; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { red "[ERROR] Falta comando: $1"; exit 1; }
}

# --------- Parámetros ---------
if [ $# -lt 1 ]; then
  red "Uso: $0 <dominio>   (ej: $0 dify.urmah.ai)"
  exit 1
fi

DOMAIN="$1"

# Directorio donde se ejecuta el script (donde están los .pem)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_FULLCHAIN="${SCRIPT_DIR}/fullchain.pem"
SRC_PRIVKEY="${SCRIPT_DIR}/privkey.pem"

# Destino estándar para Nginx
CERT_DST_DIR="/etc/ssl/certificados/${DOMAIN}"
DST_FULLCHAIN="${CERT_DST_DIR}/fullchain.pem"
DST_PRIVKEY="${CERT_DST_DIR}/privkey.pem"

INSTALL_DIR="/opt/dify/${DOMAIN}"

# --------- Requisitos mínimos ---------
need_cmd git
need_cmd curl
need_cmd openssl
need_cmd nginx
need_cmd docker

if docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_CMD="docker-compose"
else
  red "[ERROR] No se encontró 'docker compose' ni 'docker-compose'. Instálalo y reintenta."
  exit 1
fi

# Verifica estructura Nginx estilo Ubuntu
if [ ! -d /etc/nginx/sites-available ] || [ ! -d /etc/nginx/sites-enabled ]; then
  red "[ERROR] Esta instalación espera Nginx estilo Ubuntu (sites-available/sites-enabled)."
  exit 1
fi

# --------- Validación de certificados en el mismo folder del script ---------
if [ ! -f "${SRC_FULLCHAIN}" ] || [ ! -f "${SRC_PRIVKEY}" ]; then
  red "[ERROR] No se encontraron certificados Junto al script:"
  red "  ${SRC_FULLCHAIN}"
  red "  ${SRC_PRIVKEY}"
  exit 1
fi

# --------- Instalar certificados en ruta estándar y asegurar permisos ---------
yellow "🔐 Instalando certificados en ${CERT_DST_DIR} ..."
sudo mkdir -p "${CERT_DST_DIR}"
# Copia con permisos temporales; luego ajustamos ownership/permissions
sudo cp -f "${SRC_FULLCHAIN}" "${DST_FULLCHAIN}"
sudo cp -f "${SRC_PRIVKEY}"  "${DST_PRIVKEY}"

# Propiedad root:root y permisos seguros
sudo chown root:root "${DST_FULLCHAIN}" "${DST_PRIVKEY}"
sudo chmod 644 "${DST_FULLCHAIN}"
sudo chmod 600 "${DST_PRIVKEY}"

green "✅ Certificados instalados:"
echo "  ${DST_FULLCHAIN} (644, root:root)"
echo "  ${DST_PRIVKEY} (600, root:root)"

# --------- Preparación de estructura ---------
sudo mkdir -p "${INSTALL_DIR}"
sudo chown -R "${USER}:${USER}" "${INSTALL_DIR}"
cd "${INSTALL_DIR}"

green "📁 Carpeta de instalación: ${INSTALL_DIR}"

# --------- Clonar/actualizar Dify ---------
if [ ! -d "${INSTALL_DIR}/dify" ]; then
  green "📥 Clonando Dify..."
  git clone --depth=1 https://github.com/langgenius/dify.git dify
else
  green "🔄 Actualizando repo Dify..."
  (cd dify && git pull --ff-only)
fi

# Copiar compose base oficial
cp -f "dify/docker/docker-compose.yaml" "${INSTALL_DIR}/docker-compose.yaml"

# --------- .env de esta instancia ---------
if [ -f "dify/docker/.env.example" ]; then
  cp -f "dify/docker/.env.example" "${INSTALL_DIR}/.env"
else
  touch "${INSTALL_DIR}/.env"
fi

upsert_env() {
  local key="$1"; shift
  local val="$1"; shift
  if grep -qE "^${key}=" .env; then
    sed -i "s|^${key}=.*|${key}=${val}|" .env
  else
    echo "${key}=${val}" >> .env
  fi
}

# Secretos/valores por defecto
POSTGRES_DB="dify"
POSTGRES_USER="dify"
POSTGRES_PASSWORD="$(openssl rand -hex 16)"
SECRET_KEY="$(openssl rand -hex 32)"
SESSION_SECRET="$(openssl rand -hex 32)"
DATABASE_URL="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB}"
REDIS_URL="redis://redis:6379/0"

# CORS: solo el propio dominio
upsert_env WEB_API_CORS_ALLOW_ORIGINS "https://${DOMAIN}"
upsert_env CONSOLE_CORS_ALLOW_ORIGINS "https://${DOMAIN}"

# DB/Redis y secretos
upsert_env POSTGRES_DB "${POSTGRES_DB}"
upsert_env POSTGRES_USER "${POSTGRES_USER}"
upsert_env POSTGRES_PASSWORD "${POSTGRES_PASSWORD}"
upsert_env DATABASE_URL "${DATABASE_URL}"
upsert_env REDIS_URL "${REDIS_URL}"
upsert_env SECRET_KEY "${SECRET_KEY}"
upsert_env SESSION_SECRET "${SESSION_SECRET}"

# --------- Persistencia y override de puertos ---------
mkdir -p "${INSTALL_DIR}/data/postgres" "${INSTALL_DIR}/data/redis" "${INSTALL_DIR}/initdb"

# Habilitar pgvector
cat > "${INSTALL_DIR}/initdb/01-pgvector.sql" <<'SQL'
CREATE EXTENSION IF NOT EXISTS vector;
SQL

# Override mínimo: publicar puertos a localhost, persistencias y vars críticas.
cat > "${INSTALL_DIR}/docker-compose.override.yaml" <<'YAML'
version: '3.8'
services:
  web:
    # Dify web UI
    ports:
      - "127.0.0.1:3000:3000"

  api:
    # API pública detrás de Nginx del sistema
    ports:
      - "127.0.0.1:5001:5001"
    environment:
      WEB_API_CORS_ALLOW_ORIGINS: ${WEB_API_CORS_ALLOW_ORIGINS}
      CONSOLE_CORS_ALLOW_ORIGINS: ${CONSOLE_CORS_ALLOW_ORIGINS}
      DATABASE_URL: ${DATABASE_URL}
      REDIS_URL: ${REDIS_URL}
      SECRET_KEY: ${SECRET_KEY}

  worker:
    environment:
      DATABASE_URL: ${DATABASE_URL}
      REDIS_URL: ${REDIS_URL}
      SECRET_KEY: ${SECRET_KEY}

  plugin_daemon:
    # Endpoints de extensiones
    ports:
      - "127.0.0.1:5002:5002"
    environment:
      REDIS_URL: ${REDIS_URL}

  postgres:
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
      - ./initdb:/docker-entrypoint-initdb.d

  redis:
    volumes:
      - ./data/redis:/data
YAML

# --------- Nginx vhost ---------
NGINX_CONF="/etc/nginx/sites-available/${DOMAIN}.conf"
TMP_CONF="$(mktemp)"

cat > "${TMP_CONF}" <<NGINX
# Dify - ${DOMAIN}
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN};

    ssl_certificate     ${DST_FULLCHAIN};
    ssl_certificate_key ${DST_PRIVKEY};
    ssl_session_timeout 1d;
    ssl_session_cache shared:MozSSL:10m;
    ssl_protocols TLSv1.2 TLSv1.3;

    # Tamaños y cabeceras comunes
    client_max_body_size 50m;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;

    # WebSocket
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";

    # Frontend (web)
    location = / {
        proxy_pass http://127.0.0.1:3000;
    }
    location /explore {
        proxy_pass http://127.0.0.1:3000;
    }

    # API
    location /api {
        proxy_pass http://127.0.0.1:5001;
    }
    location /v1 {
        proxy_pass http://127.0.0.1:5001;
    }
    location /files {
        proxy_pass http://127.0.0.1:5001;
    }
    location /console/api {
        proxy_pass http://127.0.0.1:5001;
    }

    # Plugin daemon
    location /e/ {
        proxy_pass http://127.0.0.1:5002;
    }
}
NGINX

echo "📝 Escribiendo vhost Nginx: ${NGINX_CONF}"
sudo mv "${TMP_CONF}" "${NGINX_CONF}"
sudo ln -sf "${NGINX_CONF}" "/etc/nginx/sites-enabled/${DOMAIN}.conf"

# --------- Validar Nginx ---------
yellow "🔎 Validando Nginx..."
sudo nginx -t
green "✅ Nginx OK"

# --------- Levantar contenedores ---------
yellow "🐳 Iniciando Dify (puede tardar la primera vez, imágenes grandes)..."
cd "${INSTALL_DIR}"

${COMPOSE_CMD} -f docker-compose.yaml -f docker-compose.override.yaml up -d postgres redis
sleep 3
${COMPOSE_CMD} -f docker-compose.yaml -f docker-compose.override.yaml up -d web api worker plugin_daemon

# --------- Recargar Nginx ---------
yellow "🔁 Recargando Nginx..."
sudo systemctl reload nginx

# --------- Smoke tests ---------
green "🧪 Verificando servicios locales..."
curl -fsS "http://127.0.0.1:3000" >/dev/null && green "  Web (127.0.0.1:3000) OK" || { red "  Web no responde"; exit 1; }
curl -fsSI "http://127.0.0.1:5001" >/dev/null && green "  API (127.0.0.1:5001) OK" || { yellow "  API HEAD no concluyente (puede ser 404)."; }
curl -fsSI "http://127.0.0.1:5002" >/dev/null && green "  Plugin (127.0.0.1:5002) OK" || { yellow "  Plugin HEAD no concluyente."; }

green "🧪 Verificando por HTTPS..."
curl -fsSI "https://${DOMAIN}/" >/dev/null && green "  https://${DOMAIN}/ OK" || { red "  HTTPS raíz no responde"; exit 1; }
curl -fsSI -H "Origin: https://${DOMAIN}" "https://${DOMAIN}/api" >/dev/null || yellow "  /api puede dar 404 (normal), pero host responde."

green "🎉 Instalación completada."
echo
echo "Ruta:        ${INSTALL_DIR}"
echo "Dominio:     https://${DOMAIN}"
echo "DB (persist): ${INSTALL_DIR}/data/postgres"
echo
echo "Comandos útiles:"
echo "  cd ${INSTALL_DIR}"
echo "  ${COMPOSE_CMD} -f docker-compose.yaml -f docker-compose.override.yaml ps"
echo "  ${COMPOSE_CMD} -f docker-compose.yaml -f docker-compose.override.yaml logs -f api"
echo "  ${COMPOSE_CMD} -f docker-compose.yaml -f docker-compose.override.yaml up -d"
echo "  ${COMPOSE_CMD} -f docker-compose.yaml -f docker-compose.override.yaml down"
