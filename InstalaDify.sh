#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# InstalaDify.sh — Instalación completa y robusta de Dify
# Ubuntu 24.x • Nginx del sistema • Docker + Compose
# Uso:  ./InstalaDify.sh <dominio>   (ej. ./InstalaDify.sh dify.urmah.ai)
# Requisitos: Ejecutar como usuario normal con sudo habilitado.
# Certificados: este script DEBE vivir junto a fullchain.pem y privkey.pem.
# ============================================================

# ---------- Helpers ----------
_red()   { echo -e "\033[31m$*\033[0m"; }
_green() { echo -e "\033[32m$*\033[0m"; }
_yellow(){ echo -e "\033[33m$*\033[0m"; }

_need_cmd() { command -v "$1" >/dev/null 2>&1 || return 1; }

_asroot() {
  # Ejecuta un comando con sudo solo si no eres root
  if [ "$(id -u)" -eq 0 ]; then bash -c "$*"; else sudo bash -c "$*"; fi
}

_die() { _red "[ERROR] $*"; exit 1; }

# ---------- Parámetros ----------
if [ $# -lt 1 ]; then
  _die "Uso: $0 <dominio>   (ej: $0 dify.urmah.ai)"
fi
DOMAIN="$1"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_FULLCHAIN="${SCRIPT_DIR}/fullchain.pem"
SRC_PRIVKEY="${SCRIPT_DIR}/privkey.pem"

[ -f "$SRC_FULLCHAIN" ] || _die "No se encontró ${SRC_FULLCHAIN}"
[ -f "$SRC_PRIVKEY"  ] || _die "No se encontró ${SRC_PRIVKEY}"

INSTALL_DIR="/opt/dify/${DOMAIN}"
CERT_DST_DIR="/etc/ssl/certificados/${DOMAIN}"
DST_FULLCHAIN="${CERT_DST_DIR}/fullchain.pem"
DST_PRIVKEY="${CERT_DST_DIR}/privkey.pem"

# ---------- Preinstalación: paquetes base ----------
_green "🔧 Preparando sistema..."
_asroot "apt-get update -y"
# Nginx, ca-certs, curl, gnupg, git, openssl, jq para checks, ufw (si usas firewall)
_asroot "apt-get install -y nginx ca-certificates curl gnupg git openssl jq"

# ---------- Docker & Compose ----------
if ! _need_cmd docker; then
  _yellow "🐳 Instalando Docker Engine + Compose..."
  _asroot "install -m 0755 -d /etc/apt/keyrings"
  _asroot "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg"
  _asroot "chmod a+r /etc/apt/keyrings/docker.gpg"
  _asroot "sh -c 'echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \$(. /etc/os-release && echo \$VERSION_CODENAME) stable\" > /etc/apt/sources.list.d/docker.list'"
  _asroot "apt-get update -y"
  _asroot "apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
  _asroot "systemctl enable --now docker"
fi

# Asegurar que el usuario actual puede usar Docker (si no, usamos sudo docker)
DOCKER="docker"
if ! docker ps >/dev/null 2>&1; then
  _yellow "🔐 Añadiendo usuario '$(whoami)' al grupo docker..."
  _asroot "usermod -aG docker $(whoami) || true"
  # No podemos reabrir sesión aquí; como fallback usaremos sudo docker en esta corrida
  DOCKER="sudo docker"
fi

# Determinar Compose
if $DOCKER compose version >/dev/null 2>&1; then
  COMPOSE_CMD="$DOCKER compose"
elif _need_cmd docker-compose; then
  COMPOSE_CMD="$DOCKER-compose"
else
  _die "No se encontró docker compose ni docker-compose tras la instalación."
fi

# ---------- Nginx base ----------
_green "🕸️ Verificando Nginx..."
[ -d /etc/nginx/sites-available ] && [ -d /etc/nginx/sites-enabled ] || _die "Nginx no es la variante de Ubuntu (faltan sites-available/sites-enabled)."
_asroot "systemctl enable --now nginx"

# UFW (opcional): si está activo, permitir Nginx
if _need_cmd ufw && _asroot "ufw status | grep -q active"; then
  _yellow "🔓 UFW activo; abriendo Nginx Full..."
  _asroot "ufw allow 'Nginx Full' || true"
fi

# ---------- Instalar certificados ----------
_yellow "🔐 Instalando certificados en ${CERT_DST_DIR}..."
_asroot "mkdir -p '${CERT_DST_DIR}'"
_asroot "cp -f '${SRC_FULLCHAIN}' '${DST_FULLCHAIN}'"
_asroot "cp -f '${SRC_PRIVKEY}'  '${DST_PRIVKEY}'"
_asroot "chown root:root '${DST_FULLCHAIN}' '${DST_PRIVKEY}'"
_asroot "chmod 644 '${DST_FULLCHAIN}'"
_asroot "chmod 600 '${DST_PRIVKEY}'"
_green "✅ Certificados listos"

# ---------- Estructura de instalación ----------
_asroot "mkdir -p '${INSTALL_DIR}'"
_asroot "chown -R $(whoami):$(whoami) '${INSTALL_DIR}'"
cd "${INSTALL_DIR}"

# ---------- Clonar/actualizar Dify ----------
if [ ! -d "${INSTALL_DIR}/dify" ]; then
  _green "📥 Clonando Dify..."
  git clone --depth=1 https://github.com/langgenius/dify.git dify
else
  _green "🔄 Actualizando Dify..."
  (cd dify && git pull --ff-only)
fi

# Copiar compose base
cp -f "dify/docker/docker-compose.yaml" "${INSTALL_DIR}/docker-compose.yaml"

# ---------- .env ----------
if [ -f "dify/docker/.env.example" ]; then
  cp -f "dify/docker/.env.example" "${INSTALL_DIR}/.env"
else
  : > "${INSTALL_DIR}/.env"
fi

_upsert_env() {
  local k="$1" v="$2"
  if grep -qE "^${k}=" .env; then
    sed -i "s|^${k}=.*|${k}=${v}|" .env
  else
    echo "${k}=${v}" >> .env
  fi
}

POSTGRES_DB="dify"
POSTGRES_USER="dify"
POSTGRES_PASSWORD="$(openssl rand -hex 16)"
SECRET_KEY="$(openssl rand -hex 32)"
SESSION_SECRET="$(openssl rand -hex 32)"
DATABASE_URL="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@db:5432/${POSTGRES_DB}"
REDIS_URL="redis://redis:6379/0"

_upsert_env WEB_API_CORS_ALLOW_ORIGINS "https://${DOMAIN}"
_upsert_env CONSOLE_CORS_ALLOW_ORIGINS  "https://${DOMAIN}"
_upsert_env POSTGRES_DB     "${POSTGRES_DB}"
_upsert_env POSTGRES_USER   "${POSTGRES_USER}"
_upsert_env POSTGRES_PASSWORD "${POSTGRES_PASSWORD}"
_upsert_env DATABASE_URL    "${DATABASE_URL}"
_upsert_env REDIS_URL       "${REDIS_URL}"
_upsert_env SECRET_KEY      "${SECRET_KEY}"
_upsert_env SESSION_SECRET  "${SESSION_SECRET}"

# ---------- Persistencia e initdb ----------
mkdir -p "${INSTALL_DIR}/data/postgres" "${INSTALL_DIR}/data/redis" "${INSTALL_DIR}/initdb"

# Habilitar pgvector y crear DB del plugin de forma idempotente al primer init
cat > "${INSTALL_DIR}/initdb/01-pgvector.sql" <<'SQL'
CREATE EXTENSION IF NOT EXISTS vector;
SQL

cat > "${INSTALL_DIR}/initdb/02-create-plugin-db.sh" <<'BASH'
#!/usr/bin/env bash
set -e
# Este script se ejecuta SOLO en el primer init del cluster.
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres <<'SQL'
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_database WHERE datname = 'dify_plugin') THEN
    PERFORM dblink_connect('dbname=' || current_database());
    EXECUTE 'CREATE DATABASE dify_plugin OWNER ' || current_user;
  END IF;
END
$$;
SQL
BASH
chmod +x "${INSTALL_DIR}/initdb/02-create-plugin-db.sh"

# ---------- Override reforzado ----------
cat > "${INSTALL_DIR}/docker-compose.override.yaml" <<'YAML'
services:
  web:
    restart: unless-stopped
    ports:
      - "127.0.0.1:3000:3000"

  api:
    restart: unless-stopped
    ports:
      - "127.0.0.1:5001:5001"
    environment:
      WEB_API_CORS_ALLOW_ORIGINS: ${WEB_API_CORS_ALLOW_ORIGINS}
      CONSOLE_CORS_ALLOW_ORIGINS: ${CONSOLE_CORS_ALLOW_ORIGINS}
      DATABASE_URL: ${DATABASE_URL}
      REDIS_URL: ${REDIS_URL}
      SECRET_KEY: ${SECRET_KEY}

  worker:
    restart: unless-stopped
    environment:
      DATABASE_URL: ${DATABASE_URL}
      REDIS_URL: ${REDIS_URL}
      SECRET_KEY: ${SECRET_KEY}

  plugin_daemon:
    restart: unless-stopped
    depends_on:
      - redis
      - db
    ports:
      - "127.0.0.1:5002:5002"
    environment:
      REDIS_URL: ${REDIS_URL}
      # Forzar credenciales a Postgres para el plugin
      PGHOST: db
      PGUSER: ${POSTGRES_USER}
      PGPASSWORD: ${POSTGRES_PASSWORD}
      PGDATABASE: dify_plugin

  # Base de datos y Redis con imágenes explícitas y persistencia
  db:
    image: postgres:15
    restart: unless-stopped
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
      - ./initdb:/docker-entrypoint-initdb.d

  redis:
    image: redis:7
    restart: unless-stopped
    volumes:
      - ./data/redis:/data
YAML

# ---------- Nginx vhost ----------
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

    client_max_body_size 50m;

    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;

    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";

    location = / { proxy_pass http://127.0.0.1:3000; }
    location /explore { proxy_pass http://127.0.0.1:3000; }

    location /api { proxy_pass http://127.0.0.1:5001; }
    location /v1 { proxy_pass http://127.0.0.1:5001; }
    location /files { proxy_pass http://127.0.0.1:5001; }
    location /console/api { proxy_pass http://127.0.0.1:5001; }

    location /e/ { proxy_pass http://127.0.0.1:5002; }
}
NGINX

_asroot "mv '${TMP_CONF}' '${NGINX_CONF}'"
_asroot "ln -sf '${NGINX_CONF}' '/etc/nginx/sites-enabled/${DOMAIN}.conf'"
_asroot "nginx -t" || _die "Nginx config inválida"
_asroot "systemctl reload nginx"

# ---------- Levantar servicios ----------
_green "🐳 Levantando base de datos y redis..."
$COMPOSE_CMD -f docker-compose.yaml -f docker-compose.override.yaml up -d db redis

# Esperar a que DB esté healthy
_green "⏱️ Esperando a que DB esté lista..."
for i in {1..30}; do
  state="$($COMPOSE_CMD -f docker-compose.yaml -f docker-compose.override.yaml ps --format json | jq -r '.[] | select(.Service=="db") | .State')"
  [[ "$state" == "running" || "$state" == "healthy" ]] && break || true
  sleep 2
done

# Intento idempotente de crear DB del plugin por si el initdb no corrió (volumen ya existente)
_green "🗃️ Asegurando DB 'dify_plugin'..."
$DOCKER exec -i "$(basename "$(pwd)")-db-1" psql -U "${POSTGRES_USER}" -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname='dify_plugin';" | grep -q 1 || \
$DOCKER exec -i "$(basename "$(pwd)")-db-1" psql -U "${POSTGRES_USER}" -d postgres -c "CREATE DATABASE dify_plugin OWNER ${POSTGRES_USER};" || true

_green "🚀 Levantando API, Worker, Plugin y Web..."
$COMPOSE_CMD -f docker-compose.yaml -f docker-compose.override.yaml up -d api worker plugin_daemon web

# ---------- Esperas activas (puertos locales) ----------
_check_http() { curl -fsS "$1" >/dev/null 2>&1; }

_green "⏱️ Esperando puertos locales..."
for i in {1..60}; do _check_http "http://127.0.0.1:3000" && break || sleep 2; done
for i in {1..60}; do (_check_http "http://127.0.0.1:5001" || curl -fsSI "http://127.0.0.1:5001" >/dev/null 2>&1) && break || sleep 2; done
for i in {1..60}; do (_check_http "http://127.0.0.1:5002" || curl -fsSI "http://127.0.0.1:5002" >/dev/null 2>&1) && break || sleep 2; done

# ---------- Smoke tests ----------
_green "🧪 Pruebas locales:"
if _check_http "http://127.0.0.1:3000"; then _green "  Web OK (127.0.0.1:3000)"; else _yellow "  Web no responde (aún)"; fi
if curl -fsSI "http://127.0.0.1:5001" >/dev/null; then _green "  API OK (HEAD 5001)"; else _yellow "  API HEAD no concluyente"; fi
if curl -fsSI "http://127.0.0.1:5002" >/dev/null; then _green "  Plugin OK (HEAD 5002)"; else _yellow "  Plugin HEAD no concluyente"; fi

_green "🧪 Pruebas HTTPS:"
if curl -fsSI "https://${DOMAIN}/" >/dev/null; then _green "  https://${DOMAIN}/ OK"; else _yellow "  Raíz no responde (aún)"; fi
curl -fsSI -H "Origin: https://${DOMAIN}" "https://${DOMAIN}/api" >/dev/null || _yellow "  /api puede retornar 401/404; lo importante es que no sea 502."

echo
_green "🎉 Listo. Dify instalado."
echo "Ruta:        ${INSTALL_DIR}"
echo "Dominio:     https://${DOMAIN}"
echo "DB persist:  ${INSTALL_DIR}/data/postgres"
echo
echo "Comandos útiles:"
echo "  cd ${INSTALL_DIR}"
echo "  $COMPOSE_CMD -f docker-compose.yaml -f docker-compose.override.yaml ps"
echo "  $COMPOSE_CMD -f docker-compose.yaml -f docker-compose.override.yaml logs -f api"
echo "  $COMPOSE_CMD -f docker-compose.yaml -f docker-compose.override.yaml up -d"
echo "  $COMPOSE_CMD -f docker-compose.yaml -f docker-compose.override.yaml down"
