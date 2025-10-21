#!/usr/bin/env bash
set -euo pipefail

# === Config ===
PROJECT_DIR="${HOME}/discord-like"
APP_PORT_API="4000"
APP_PORT_WEB="3000"
PG_PORT="5432"
REDIS_PORT="6379"
MEILI_PORT="7700"
MINIO_PORT="9000"
MINIO_CONSOLE_PORT="9001"
LIVEKIT_HTTP_PORT="7880"
LIVEKIT_WS_PORT="7881"
POSTGRES_DB="discord_like"
POSTGRES_USER="postgres"
POSTGRES_PASSWORD="postgres"

log()  { printf "\n\033[1;32m▶ %s\033[0m\n" "$*"; }
warn() { printf "\n\033[1;33m! %s\033[0m\n" "$*"; }

# --- sanity note ---
if [[ "$(id -u)" -eq 0 ]]; then
  warn "You’re running as root. It’s safer to run this as a normal user (sudo will be used when needed)."
fi

# --- 1) System update & essentials ---
log "Updating system & installing essentials"
sudo apt update
sudo apt -y upgrade
sudo apt -y install git curl build-essential ca-certificates jq apt-transport-https software-properties-common

# --- 2) Docker Engine + Compose plugin ---
if ! command -v docker >/dev/null 2>&1; then
  log "Installing Docker Engine + Compose"
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture)] https://download.docker.com/linux/ubuntu noble stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt update
  sudo apt -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo usermod -aG docker "$USER" || true
else
  log "Docker already installed — skipping"
fi

# --- 3) Node.js 22 LTS via NodeSource (no fnm/nvm) ---
if ! command -v node >/dev/null 2>&1; then
  log "Installing Node.js 22 LTS from NodeSource"
  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
  sudo apt -y install nodejs
else
  log "Node already installed — $(node -v)"
fi

# Ensure clean old pnpm/pnpx symlinks (avoid EEXIST)
sudo rm -f /usr/local/bin/pnpm /usr/local/bin/pnpx || true

log "Installing pnpm globally"
curl
