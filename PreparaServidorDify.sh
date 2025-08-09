#!/usr/bin/env bash
# PreparaServidorDify.sh
# Deja el sistema listo para ejecutar InstalaDif.sh (Docker, Nginx, utilidades, locales, permisos, firewall)
# Ubuntu 20.04/22.04/24.04

set -euo pipefail

log() { printf "\n\033[1;32m[OK]\033[0m %s\n" "$*"; }
info(){ printf "\n\033[1;34m[INFO]\033[0m %s\n" "$*"; }
warn(){ printf "\n\033[1;33m[WARN]\033[0m %s\n" "$*"; }
err() { printf "\n\033[1;31m[ERR]\033[0m %s\n" "$*"; }

#--- Re-ejecutar con sudo si no somos root ---
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then
    info "Elevando permisos con sudo..."
    exec sudo -E bash "$0" "$@"
  else
    err "Se requiere root o sudo. Instala sudo o ejecuta: su -c '$0'"
    exit 1
  fi
fi

export DEBIAN_FRONTEND=noninteractive

# Detectar usuario real que invocó (para agregar a grupo docker)
CALLER="${SUDO_USER:-$(logname 2>/dev/null || echo "${USER}")}"
if id "$CALLER" >/dev/null 2>&1; then
  TARGET_USER="$CALLER"
else
  TARGET_USER="${USER}"
fi
info "Usuario objetivo para permisos de Docker: $TARGET_USER"

#--- Comprobaciones básicas de distro ---
if ! command -v lsb_release >/dev/null 2>&1; then apt-get update -y && apt-get install -y lsb-release; fi
DISTRO="$(lsb_release -is 2>/dev/null || echo Ubuntu)"
RELEASE="$(lsb_release -rs 2>/dev/null || true)"
if [ "$DISTRO" != "Ubuntu" ]; then
  warn "Distribución detectada: $DISTRO. Este script está pensado para Ubuntu; intentaré continuar."
fi

#--- Paquetes base y utilidades ---
info "Instalando utilidades base..."
apt-get update -y
apt-get install -y \
  ca-certificates gnupg apt-transport-https software-properties-common \
  curl wget jq git unzip tar xz-utils \
  gettext-base \
  locales tzdata \
  ufw \
  apt-transport-https

# Locales (evita warnings de LC_ALL en contenedores)
if ! locale -a | grep -qi "en_US.utf8"; then
  info "Generando locale en_US.UTF-8..."
  sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen || true
  locale-gen en_US.UTF-8
fi
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
log "Locale configurado: en_US.UTF-8"

#--- Docker Engine + docker compose plugin (repos oficiales) ---
if ! command -v docker >/dev/null 2>&1; then
  info "Instalando Docker Engine y plugin docker compose..."
  install -m 0755 -d /etc/apt/keyrings
  if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
  fi
  ARCH="$(dpkg --print-architecture)"
  CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  echo \
"deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${CODENAME} stable" \
  >/etc/apt/sources.list.d/docker.list

  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
  log "Docker instalado y en ejecución."
else
  log "Docker ya está instalado."
  systemctl enable --now docker || true
fi

# Probar Docker (pull rápido de hello-world si no está)
if ! docker info >/dev/null 2>&1; then
  warn "Docker necesita permisos para el usuario actual; ajustando permisos temporales del socket..."
fi

#--- Añadir usuario al grupo docker e intentar habilitar en esta sesión ---
if ! id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx docker; then
  info "Agregando $TARGET_USER al grupo docker..."
  usermod -aG docker "$TARGET_USER"
  ADDED_TO_GROUP=1
else
  ADDED_TO_GROUP=0
fi

# Permiso inmediato de socket para no exigir relogin (temporal, no inseguro si sólo para snapshot)
if [ -S /var/run/docker.sock ]; then
  chgrp docker /var/run/docker.sock || true
  chmod g+rw /var/run/docker.sock || true
fi

# Probar comando docker con sg para el usuario objetivo (sin relogin)
if command -v sg >/dev/null 2>&1; then
  info "Verificando acceso a Docker para $TARGET_USER..."
  if ! sudo -u "$TARGET_USER" sg docker -c "docker ps >/dev/null 2>&1"; then
    warn "Es posible que necesites cerrar sesión y volver a entrar para aplicar el grupo docker."
  else
    log "Acceso a Docker OK para $TARGET_USER."
  fi
else
  warn "Comando 'sg' no disponible; puede requerir relogin para aplicar grupo docker."
fi

#--- Nginx + Certbot (opcional, útil para snapshot) ---
if ! command -v nginx >/dev/null 2>&1; then
  info "Instalando Nginx..."
  apt-get install -y nginx
  systemctl enable --now nginx
  log "Nginx instalado y ejecutándose."
else
  log "Nginx ya está instalado."
  systemctl enable --now nginx || true
fi

# Certbot (por si quieres emitir/renovar después)
if ! command -v certbot >/dev/null 2>&1; then
  info "Instalando Certbot y plugin Nginx..."
  apt-get install -y certbot python3-certbot-nginx
  log "Certbot instalado."
else
  log "Certbot ya está instalado."
fi

#--- Firewall UFW (si está presente) ---
if command -v ufw >/dev/null 2>&1; then
  if ufw status | grep -q "inactive"; then
    warn "UFW está inactivo; NO lo activar é automáticamente para no romper accesos SSH."
    info "Abriendo reglas por si activas UFW en el futuro..."
    ufw allow OpenSSH >/dev/null 2>&1 || true
    ufw allow 'Nginx Full' >/dev/null 2>&1 || true
  else
    info "UFW activo: abriendo puertos 80/443 y asegurando SSH..."
    ufw allow OpenSSH || true
    ufw allow 'Nginx Full' || true
  fi
fi

#--- Directorios base para Dify (sólo estructura, sin descargar imágenes) ---
BASE="/opt/dify/dify.urmah.ai"
info "Creando estructura base en $BASE ..."
mkdir -p \
  "$BASE" \
  "$BASE/data/postgres" \
  "$BASE/data/redis" \
  "$BASE/volumes/app/storage" \
  "$BASE/volumes/plugin_daemon" \
  "$BASE/volumes/weaviate" \
  "$BASE/volumes/sandbox/conf" \
  "$BASE/volumes/sandbox/dependencies" \
  "$BASE/nginx/conf.d" \
  "$BASE/nginx/ssl" \
  "$BASE/ssrf_proxy"

# Dar permisos útiles al usuario objetivo sobre /opt/dify
chown -R "$TARGET_USER":"$TARGET_USER" /opt/dify || true
log "Estructura /opt/dify preparada."

#--- Pequeño test de Docker/Compose (sin dejar nada corriendo) ---
info "Probando Docker y docker compose..."
docker --version || true
docker compose version || true
docker run --rm hello-world >/dev/null 2>&1 && log "Prueba 'hello-world' OK." || warn "No se pudo ejecutar 'hello-world' (posible relogin requerido)."

#--- Resumen final ---
log "Instalación base completada."
echo "
Resumen:
  - Docker + docker compose plugin: INSTALADO y habilitado
  - Nginx: INSTALADO y habilitado
  - Certbot: INSTALADO
  - Utilidades: curl, jq, git, unzip, gettext, locales
  - Locale: en_US.UTF-8
  - Directorios Dify en: $BASE
  - Usuario en grupo docker: $TARGET_USER $( [ $ADDED_TO_GROUP -eq 1 ] && echo '(recién agregado)' || echo '(ya estaba)' )

Siguiente paso:
  1) Si 'docker ps' falla para tu usuario, cierra sesión y vuelve a entrar.
  2) Ejecuta tu script:  ./InstalaDif.sh
"
