cat > ~/dify_oneclick.sh <<'BASH'
#!/usr/bin/env bash
set -euo pipefail

# ---------- Config mínima ----------
DOMAIN="${1:-}"
COMPOSE_DIR="/opt/dify/dify.urmah.ai"
DB_USER="dify"
DB_PASS="555b9fc5be6492eec1f79e0049ad711c"
DB_NAME="dify"
API_PORT="5001"
WEB_PORT="3000"
PLUGIN_PORT="5002"

if [[ -z "$DOMAIN" ]]; then
  echo "Uso: $0 <dominio>   Ej: $0 dify.urmah.ai" >&2
  exit 1
fi

# ---------- Helpers ----------
log(){ echo -e "[$(date +'%H:%M:%S')] $*"; }

# Detectar docker (con sudo si hace falta)
if docker info >/dev/null 2>&1; then
  DOCKER="docker"
elif sudo -n docker info >/dev/null 2>&1; then
  DOCKER="sudo docker"
else
  # Último intento: si docker requiere sudo, pedimos sudo una vez
  if sudo docker info >/dev/null 2>&1; then
    DOCKER="sudo docker"
  else
    echo "No puedo usar Docker. Asegúrate de tener Docker instalado y permisos (o sudo)." >&2
    exit 1
  fi
fi

DC="$DOCKER compose -f $COMPOSE_DIR/docker-compose.yaml -f $COMPOSE_DIR/docker-compose.override.yaml"

# ---------- Crear override de DB para todos los servicios relevantes ----------
log "Escribiendo override de DB…"
mkdir -p "$COMPOSE_DIR"
cat > "$COMPOSE_DIR/docker-compose.dbfix.yaml" <<YAML
services:
  api:
    environment:
      DB_HOST: db
      DB_PORT: "5432"
      DB_USERNAME: ${DB_USER}
      DB_PASSWORD: ${DB_PASS}
      DB_DATABASE: ${DB_NAME}
      DATABASE_URL: postgresql://${DB_USER}:${DB_PASS}@db:5432/${DB_NAME}

  worker:
    environment:
      DB_HOST: db
      DB_PORT: "5432"
      DB_USERNAME: ${DB_USER}
      DB_PASSWORD: ${DB_PASS}
      DB_DATABASE: ${DB_NAME}
      DATABASE_URL: postgresql://${DB_USER}:${DB_PASS}@db:5432/${DB_NAME}

  worker_beat:
    environment:
      DB_HOST: db
      DB_PORT: "5432"
      DB_USERNAME: ${DB_USER}
      DB_PASSWORD: ${DB_PASS}
      DB_DATABASE: ${DB_NAME}
      DATABASE_URL: postgresql://${DB_USER}:${DB_PASS}@db:5432/${DB_NAME}

  plugin_daemon:
    environment:
      DB_HOST: db
      DB_PORT: "5432"
      DB_USERNAME: ${DB_USER}
      DB_PASSWORD: ${DB_PASS}
      DB_DATABASE: dify_plugin
YAML

DC_ALL="$DC -f $COMPOSE_DIR/docker-compose.dbfix.yaml"

# ---------- Subir DB y Redis primero ----------
log "Levantando DB y Redis…"
$DC up -d db redis
sleep 2

# Esperar a que Postgres esté listo (con usuario dify)
log "Esperando a Postgres (db=${DB_NAME}, user=${DB_USER})…"
for i in {1..60}; do
  if $DC exec -T db pg_isready -h db -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>&1; then
    log "Postgres listo."
    break
  fi
  sleep 1
  [[ $i -eq 60 ]] && { echo "Postgres no estuvo listo a tiempo." >&2; exit 1; }
done

# ---------- Subir API/Worker/Web/Plugin ----------
log "Levantando api, worker, web, plugin_daemon…"
$DC_ALL up -d api worker web plugin_daemon
sleep 3

# ---------- Parche de Nginx vhost ----------
log "Parcheando vhost Nginx para ${DOMAIN}…"
VHOST="/etc/nginx/sites-available/${DOMAIN}.conf"
BACKUP="${VHOST}.bak.$(date +%Y%m%d_%H%M%S)"
if [[ -f "$VHOST" ]]; then sudo cp -a "$VHOST" "$BACKUP"; fi

sudo tee "$VHOST" >/dev/null <<NGINX
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

    # Certs (ajusta si usas otra ruta)
    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    # Básicos
    client_max_body_size 100M;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;

    # Cabeceras proxy comunes
    set \$upstream_http_x_forwarded_proto https;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;

    # Web (Next.js)
    location / {
        proxy_pass http://127.0.0.1:${WEB_PORT};
    }
    location /apps {
        proxy_pass http://127.0.0.1:${WEB_PORT};
    }

    # API (console y pública)
    location /console/api/ {
        proxy_pass http://127.0.0.1:${API_PORT}/console/api/;
    }
    location /api/ {
        proxy_pass http://127.0.0.1:${API_PORT}/api/;
    }

    # Plugin daemon (si decides exponer endpoints /e/)
    location /e/ {
        proxy_pass http://127.0.0.1:${PLUGIN_PORT}/;
    }
}
NGINX

# Enable y reload
if [[ ! -f "/etc/nginx/sites-enabled/${DOMAIN}.conf" ]]; then
  sudo ln -sf "$VHOST" "/etc/nginx/sites-enabled/${DOMAIN}.conf"
fi
sudo nginx -t
sudo systemctl reload nginx
log "Nginx recargado. (respaldo: $BACKUP)"

# ---------- Comprobaciones locales ----------
fail=false

log "Check WEB local http://127.0.0.1:${WEB_PORT}/"
if ! curl -fsS "http://127.0.0.1:${WEB_PORT}/" >/dev/null; then
  echo "❌ Web local no responde en :${WEB_PORT}" >&2; fail=true
else
  echo "✅ Web local OK"
fi

log "Check API local http://127.0.0.1:${API_PORT}/ (esperable 404, pero que responda)"
if curl -fsSI "http://127.0.0.1:${API_PORT}/" >/dev/null; then
  echo "✅ API local OK (endpoint base responde)"
else
  echo "❌ API local no responde en :${API_PORT}" >&2; fail=true
fi

# ---------- Comprobaciones vía HTTPS/Nginx ----------
log "Check HTTPS https://${DOMAIN}/"
if ! curl -fsSI "https://${DOMAIN}/" >/dev/null; then
  echo "❌ HTTPS / no responde" >&2; fail=true
else
  echo "✅ HTTPS / OK"
fi

log "Check HTTPS apps https://${DOMAIN}/apps"
if ! curl -fsSI "https://${DOMAIN}/apps" >/dev/null; then
  echo "❌ HTTPS /apps no responde" >&2; fail=true
else
  echo "✅ HTTPS /apps OK"
fi

# Estas rutas pueden devolver 401/404, lo importante es NO 502
log "Check HTTPS /api (no 502)"
if curl -sSI "https://${DOMAIN}/api" | grep -q "502 Bad Gateway"; then
  echo "❌ HTTPS /api devuelve 502" >&2; fail=true
else
  echo "✅ HTTPS /api sin 502"
fi

log "Check HTTPS /console/api (no 502)"
if curl -sSI "https://${DOMAIN}/console/api" | grep -q "502 Bad Gateway"; then
  echo "❌ HTTPS /console/api devuelve 502" >&2; fail=true
else
  echo "✅ HTTPS /console/api sin 502"
fi

# ---------- Estado final ----------
log "Estado de contenedores:"
$DC_ALL ps || true

if [[ "$fail" == "true" ]]; then
  echo
  echo "⚠️  Hay checks fallidos. Revisa:"
  echo " - Logs API:    $DC_ALL logs -n 120 api"
  echo " - Logs WEB:    $DC_ALL logs -n 120 web"
  echo " - Logs PLUGIN: $DC_ALL logs -n 120 plugin_daemon"
  exit 2
fi

echo
echo "🎉 Listo. Accede a https://${DOMAIN}/apps"
BASH

chmod +x ~/dify_oneclick.sh
