#!/usr/bin/env bash
# Vancord automated installer for Ubuntu
# Supports: local install or server install
# Usage:
#   sudo bash install_vancord.sh
# Optional environment variables (export before running):
#   DOMAIN - your domain (default: serecjany.duckdns.org)
#   GIT_REPO - git repo url of your vancord project (if provided, script will clone it)
#   ZIP_PATH - path to a vancord.zip on the machine (if provided, script will extract it)
#   MONGO_URI - if you want to use an external MongoDB (if not provided, script installs local MongoDB)
#   TURN_USER - TURN username (default: turnuser)
#   TURN_PASS - TURN password (default: turnpass)
#   NONINTERACTIVE - if set to "1" skips prompts and runs with defaults
set -euo pipefail
IFS=$'\n\t'

DOMAIN="${DOMAIN:-serecjany.duckdns.org}"
GIT_REPO="${GIT_REPO:-}"
ZIP_PATH="${ZIP_PATH:-/tmp/vancord.zip}"
MONGO_URI="${MONGO_URI:-}"
TURN_USER="${TURN_USER:-turnuser}"
TURN_PASS="${TURN_PASS:-turnpass}"
NODE_VERSION="${NODE_VERSION:-lts}"

echo "=== Vancord automated installer ==="
echo "Domain: $DOMAIN"
if [ -n "$GIT_REPO" ]; then
  echo "Will clone project from: $GIT_REPO"
else
  echo "Will look for project zip at: $ZIP_PATH (or you can set GIT_REPO env var)"
fi
if [ -n "$MONGO_URI" ]; then
  echo "Using external MongoDB URI: $MONGO_URI"
else
  echo "Will install local MongoDB server"
fi

# confirm
if [ "${NONINTERACTIVE:-0}" != "1" ]; then
  read -p "Continue? [Y/n] " ans || true
  if [[ "$ans" =~ ^[Nn] ]]; then
    echo "Aborting."
    exit 1
  fi
fi

export DEBIAN_FRONTEND=noninteractive

echo "1) Updating system packages..."
apt update -y && apt upgrade -y

echo "2) Installing base packages..."
apt install -y curl git build-essential unzip ca-certificates gnupg lsb-release apt-transport-https software-properties-common

echo "3) Installing Node.js (NodeSource $NODE_VERSION)..."
curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
apt install -y nodejs

echo "Node version: $(node -v)  npm: $(npm -v)"

if [ -z "$MONGO_URI" ]; then
  echo "4) Installing MongoDB Community edition..."
  wget -qO - https://www.mongodb.org/static/pgp/server-7.0.asc | gpg --dearmor -o /usr/share/keyrings/mongodb-server-7.0.gpg || true
  echo "deb [signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg] https://repo.mongodb.org/apt/ubuntu $(lsb_release -cs)/mongodb-org/7.0 multiverse" | tee /etc/apt/sources.list.d/mongodb-org-7.0.list
  apt update -y
  apt install -y mongodb-org
  systemctl enable --now mongod
  echo "Waiting for MongoDB to start..."
  sleep 5
  echo "MongoDB status:"
  systemctl status mongod --no-pager || true
  MONGO_URI="mongodb://127.0.0.1:27017/vancord"
fi

echo "5) Install Nginx, Certbot and pm2..."
apt install -y nginx
apt install -y certbot python3-certbot-nginx
npm install -g pm2@latest

echo "6) Install coturn (TURN server)"
apt install -y coturn

# Prepare project folder
WWW_ROOT="/var/www/vancord"
echo "7) Preparing project folder at $WWW_ROOT ..."
mkdir -p "$WWW_ROOT"
chown "$SUDO_USER":"$SUDO_USER" "$WWW_ROOT" || true

if [ -n "$GIT_REPO" ]; then
  echo "Cloning project from $GIT_REPO ..."
  rm -rf "$WWW_ROOT/*" || true
  git clone "$GIT_REPO" "$WWW_ROOT"
else
  if [ -f "$ZIP_PATH" ]; then
    echo "Extracting project zip from $ZIP_PATH ..."
    unzip -o "$ZIP_PATH" -d "$WWW_ROOT"
  else
    echo "ERROR: No source found. Set GIT_REPO or place vancord.zip at $ZIP_PATH and re-run."
    exit 1
  fi
fi

# Ensure backend & frontend exist
if [ ! -d "$WWW_ROOT/backend" ] || [ ! -d "$WWW_ROOT/frontend" ]; then
  echo "ERROR: expected backend/ and frontend/ folders in project root ($WWW_ROOT)."
  ls -la "$WWW_ROOT"
  exit 1
fi

echo "8) Creating uploads folder and setting permissions..."
mkdir -p "$WWW_ROOT/uploads"
chown -R "$SUDO_USER":"$SUDO_USER" "$WWW_ROOT/uploads"
chmod 2775 "$WWW_ROOT/uploads" || true

echo "9) Create .env in backend from example (or update if exists)"
BACKEND_ENV="$WWW_ROOT/backend/.env"
if [ ! -f "$BACKEND_ENV" ]; then
  if [ -f "$WWW_ROOT/backend/.env.example" ]; then
    cp "$WWW_ROOT/backend/.env.example" "$BACKEND_ENV"
  else
    touch "$BACKEND_ENV"
  fi
fi

# generate secrets if not set
rand_secret() {
  head -c 32 /dev/urandom | base64 | tr -d '\\n' || true
}

sed -i "/^PORT=/d" "$BACKEND_ENV" || true
sed -i "/^MONGO_URI=/d" "$BACKEND_ENV" || true
sed -i "/^JWT_SECRET=/d" "$BACKEND_ENV" || true
sed -i "/^JWT_REFRESH_SECRET=/d" "$BACKEND_ENV" || true
echo "PORT=3001" >> "$BACKEND_ENV"
echo "MONGO_URI=$MONGO_URI" >> "$BACKEND_ENV"
if ! grep -q '^JWT_SECRET=' "$BACKEND_ENV"; then
  echo "JWT_SECRET=$(rand_secret)" >> "$BACKEND_ENV"
fi
if ! grep -q '^JWT_REFRESH_SECRET=' "$BACKEND_ENV"; then
  echo "JWT_REFRESH_SECRET=$(rand_secret)" >> "$BACKEND_ENV"
fi

echo "10) Installing backend dependencies..."
cd "$WWW_ROOT/backend"
npm install --production || npm install

echo "11) Installing frontend dependencies and building..."
cd "$WWW_ROOT/frontend"
npm install --production || npm install
npm run build

# Move build to /var/www/vancord/frontend/build (nginx will serve this)
mkdir -p /var/www/vancord/frontend
cp -r build /var/www/vancord/frontend/

echo "12) Configure Nginx site for $DOMAIN ..."
NGINX_CONF="/etc/nginx/sites-available/vancord"
cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    server_name ${DOMAIN};

    root /var/www/vancord/frontend/build;
    index index.html index.htm;

    location / {
        try_files \$uri /index.html;
    }

    location /api/ {
        proxy_pass http://127.0.0.1:3001/api/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

    location /socket.io/ {
        proxy_pass http://127.0.0.1:3001/socket.io/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

    location /uploads/ {
        alias /var/www/vancord/uploads/;
    }
}
EOF

ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/vancord
nginx -t
systemctl reload nginx

echo "13) Obtain TLS certificate via Certbot (Let's Encrypt) for $DOMAIN ..."
if [ "${NONINTERACTIVE:-0}" = "1" ]; then
  certbot --nginx -d "$DOMAIN" --agree-tos --email admin@$DOMAIN --non-interactive || true
else
  certbot --nginx -d "$DOMAIN" || true
fi

echo "14) Configure coturn (basic single-user config) ..."
TURN_CONF="/etc/turnserver.conf"
# backup existing
if [ -f "$TURN_CONF" ]; then cp "$TURN_CONF" "$TURN_CONF.bak" || true; fi
cat > "$TURN_CONF" <<EOF
listening-port=3478
fingerprint
lt-cred-mech
user=${TURN_USER}:${TURN_PASS}
realm=${DOMAIN}
total-quota=100
bps-capacity=0
stale-nonce
no-stdout-log
log-file=/var/log/turnserver/turn.log
EOF
systemctl enable --now coturn || true

echo "15) Start backend with PM2..."
cd "$WWW_ROOT/backend"
# Use PM2 to start server.js and set ecosystem
pm2 start server.js --name vancord-backend --watch
pm2 save
pm2 startup systemd -u "$SUDO_USER" --hp "/home/$SUDO_USER" || true

echo "16) Final notes and output"
echo "================================================================================"
echo "Vancord should now be served at: https://${DOMAIN} (if DNS pointed correctly and certbot succeeded)"
echo "Backend running with PM2 as 'vancord-backend'"
echo "MongoDB URI in backend .env: $MONGO_URI"
echo "TURN credentials: user=${TURN_USER}, pass=${TURN_PASS} (set in /etc/turnserver.conf)"
echo "Uploads served from /var/www/vancord/uploads"
echo "To view PM2 logs: pm2 logs vancord-backend"
echo "To stop PM2 managed app: pm2 stop vancord-backend"
echo "================================================================================"
