#!/usr/bin/env bash
set -euo pipefail

# === config ===
PROJECT_DIR="${HOME}/discord-like"
NODE_LTS_ALIASED="lts"   # fnm alias
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

# --- helpers ---
log() { printf "\n\033[1;32m▶ %s\033[0m\n" "$*"; }
warn() { printf "\n\033[1;33m! %s\033[0m\n" "$*"; }
die() { printf "\n\033[1;31m✖ %s\033[0m\n" "$*"; exit 1; }

# --- sanity checks ---
[[ "$(id -u)" -eq 0 ]] && warn "Running as root is not required. Continuing anyway."

if ! grep -qi "Ubuntu" /etc/os-release || ! grep -qE '^VERSION_ID="24\.04"' /etc/os-release; then
  warn "This script is tuned for Ubuntu 24.04 LTS. Proceeding anyway..."
fi

# --- update & essentials ---
log "Updating system & installing base packages"
sudo apt update
sudo apt -y upgrade
sudo apt -y install git curl build-essential ca-certificates jq apt-transport-https software-properties-common

# --- Docker Engine + Compose plugin ---
if ! command -v docker >/dev/null 2>&1; then
  log "Installing Docker Engine + Compose"
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/trusted.gpg.d/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture)] https://download.docker.com/linux/ubuntu noble stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt update
  sudo apt -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo usermod -aG docker "$USER" || true
  # try to apply group without logout
  if command -v newgrp >/dev/null 2>&1; then
    newgrp docker <<'EOF'
true
EOF
  fi
else
  log "Docker already installed — skipping"
fi

# --- FFmpeg & Electron runtime libs (Ubuntu 24.04 names) ---
log "Installing FFmpeg + Electron runtime libraries"
sudo apt -y install ffmpeg libnss3 libasound2t64 libxss1 libgtk-3-0 libatk1.0-0 libdrm2 libgbm1

# --- Node LTS via fnm + pnpm ---
if ! command -v fnm >/dev/null 2>&1; then
  log "Installing fnm (Fast Node Manager)"
  curl -fsSL https://fnm.vercel.app/install | bash
fi
# shell hooks for current session
export PATH="$HOME/.fnm:$PATH"
eval "$(fnm env --use-on-cd)"

log "Installing Node.js LTS and pnpm"
fnm install --lts
fnm default "$(fnm current)"
corepack enable || true
npm i -g pnpm

# --- project scaffold ---
log "Creating project at: $PROJECT_DIR"
mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"

# .env
cat > .env <<EOF
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_USER=${POSTGRES_USER}
POSTGRES_DB=${POSTGRES_DB}
POSTGRES_PORT=${PG_PORT}
REDIS_PORT=${REDIS_PORT}
MEILI_PORT=${MEILI_PORT}
MINIO_ROOT_USER=minioadmin
MINIO_ROOT_PASSWORD=minioadmin
MINIO_PORT=${MINIO_PORT}
MINIO_CONSOLE_PORT=${MINIO_CONSOLE_PORT}
LIVEKIT_KEYS=devkey:secret
LIVEKIT_HTTP_PORT=${LIVEKIT_HTTP_PORT}
LIVEKIT_WS_PORT=${LIVEKIT_WS_PORT}

SERVER_PORT=${APP_PORT_API}
NEXT_PUBLIC_API_URL=http://localhost:${APP_PORT_API}
NEXT_PUBLIC_WS_URL=ws://localhost:${APP_PORT_API}
NEXT_PUBLIC_MEILI_URL=http://localhost:${MEILI_PORT}
NEXT_PUBLIC_LIVEKIT_URL=ws://localhost:${LIVEKIT_HTTP_PORT}
EOF

# docker-compose.yml
cat > docker-compose.yml <<'EOF'
version: "3.9"
services:
  postgres:
    image: postgres:16
    container_name: pg
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
    ports:
      - "${POSTGRES_PORT}:5432"
    volumes:
      - pg_data:/var/lib/postgresql/data

  redis:
    image: redis:7
    container_name: redis
    restart: unless-stopped
    ports:
      - "${REDIS_PORT}:6379"

  meilisearch:
    image: getmeili/meilisearch:latest
    container_name: meili
    restart: unless-stopped
    environment:
      MEILI_NO_ANALYTICS: "true"
    ports:
      - "${MEILI_PORT}:7700"
    volumes:
      - meili_data:/meili_data

  minio:
    image: quay.io/minio/minio
    container_name: minio
    command: server /data --console-address ":${MINIO_CONSOLE_PORT}"
    restart: unless-stopped
    environment:
      MINIO_ROOT_USER: ${MINIO_ROOT_USER}
      MINIO_ROOT_PASSWORD: ${MINIO_ROOT_PASSWORD}
    ports:
      - "${MINIO_PORT}:9000"
      - "${MINIO_CONSOLE_PORT}:9001"
    volumes:
      - minio_data:/data

  livekit:
    image: livekit/livekit-server
    container_name: livekit
    command: --dev --bind 0.0.0.0
    restart: unless-stopped
    environment:
      LIVEKIT_KEYS: ${LIVEKIT_KEYS}
    ports:
      - "${LIVEKIT_HTTP_PORT}:7880"
      - "${LIVEKIT_WS_PORT}:7881"

volumes:
  pg_data: {}
  meili_data: {}
  minio_data: {}
EOF

# workspace package.json
mkdir -p apps/desktop apps/web server
cat > package.json <<'EOF'
{
  "name": "discord-like-pc-starter",
  "private": true,
  "workspaces": ["apps/*", "server"],
  "scripts": {
    "dev:infra": "docker compose --env-file .env up -d",
    "dev:server": "pnpm -C server dev",
    "dev:web": "pnpm -C apps/web dev",
    "dev:desktop": "pnpm -C apps/desktop dev",
    "build": "pnpm -C server build && pnpm -C apps/web build && pnpm -C apps/desktop build"
  }
}
EOF

# --- Electron desktop ---
cat > apps/desktop/package.json <<'EOF'
{
  "name": "desktop",
  "private": true,
  "version": "0.1.0",
  "main": "electron/main.js",
  "type": "module",
  "scripts": {
    "dev": "concurrently \"pnpm -C ../web dev\" \"tsc -w -p .\" \"wait-on tcp:3000 && electron .\"",
    "build": "tsc -p . && pnpm -C ../web build",
    "start": "electron ."
  },
  "devDependencies": {
    "@types/node": "^20.0.0",
    "concurrently": "^8.0.0",
    "electron": "^31.0.0",
    "typescript": "^5.4.0",
    "wait-on": "^7.0.0"
  },
  "dependencies": {}
}
EOF

cat > apps/desktop/tsconfig.json <<'EOF'
{
  "compilerOptions": {
    "target": "ES2021",
    "module": "ESNext",
    "moduleResolution": "Bundler",
    "outDir": "./",
    "rootDir": "./",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true
  },
  "include": ["electron/**/*"]
}
EOF

mkdir -p apps/desktop/electron
cat > apps/desktop/electron/main.ts <<'EOF'
import { app, BrowserWindow, ipcMain, Notification } from 'electron';
import path from 'node:path';

const isDev = !app.isPackaged;

async function createWindow() {
  const win = new BrowserWindow({
    width: 1200,
    height: 800,
    webPreferences: {
      preload: path.join(__dirname, 'electron', 'preload.js'),
      nodeIntegration: false,
      contextIsolation: true
    }
  });

  const devURL = 'http://localhost:3000';
  const prodURL = new URL(path.join(__dirname, 'renderer', 'index.html'), 'file:').toString();

  await win.loadURL(isDev ? devURL : prodURL);
}

app.whenReady().then(createWindow);

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});

ipcMain.handle('notify', (_evt, title: string, body: string) => {
  new Notification({ title, body }).show();
});
EOF

cat > apps/desktop/electron/preload.ts <<'EOF'
import { contextBridge, ipcRenderer } from 'electron';
contextBridge.exposeInMainWorld('desktop', {
  notify: (title: string, body: string) => ipcRenderer.invoke('notify', title, body)
});
EOF

# --- Next.js web UI ---
cat > apps/web/package.json <<'EOF'
{
  "name": "web",
  "private": true,
  "version": "0.1.0",
  "type": "module",
  "scripts": {
    "dev": "next dev -p 3000",
    "build": "next build && next export",
    "start": "next start -p 3000"
  },
  "dependencies": {
    "@tanstack/react-query": "^5.50.0",
    "next": "^14.2.4",
    "react": "^18.2.0",
    "react-dom": "^18.2.0",
    "socket.io-client": "^4.7.5"
  },
  "devDependencies": {
    "autoprefixer": "^10.4.19",
    "postcss": "^8.4.38",
    "tailwindcss": "^3.4.4",
    "typescript": "^5.4.0"
  }
}
EOF

cat > apps/web/next.config.mjs <<'EOF'
/** @type {import('next').NextConfig} */
const nextConfig = { output: 'export' };
export default nextConfig;
EOF

cat > apps/web/postcss.config.mjs <<'EOF'
export default { plugins: { tailwindcss: {}, autoprefixer: {} } };
EOF

cat > apps/web/tailwind.config.ts <<'EOF'
import type { Config } from 'tailwindcss'
export default {
  content: ['./src/**/*.{ts,tsx}'],
  theme: { extend: {} },
  plugins: [],
} satisfies Config
EOF

mkdir -p apps/web/src/app apps/web/src/styles
cat > apps/web/src/styles/globals.css <<'EOF'
@tailwind base;
@tailwind components;
@tailwind utilities;
:root { color-scheme: dark; }
body { @apply bg-zinc-900 text-zinc-100; }
EOF

cat > apps/web/src/app/layout.tsx <<'EOF'
export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
EOF

cat > apps/web/src/app/page.tsx <<'EOF'
'use client';
import { useEffect, useState } from 'react';
import io from 'socket.io-client';
const socket = io(process.env.NEXT_PUBLIC_WS_URL ?? 'ws://localhost:4000', { transports: ['websocket'] });

export default function Home() {
  const [messages, setMessages] = useState<string[]>([]);
  const [input, setInput] = useState('');

  useEffect(() => {
    socket.on('chat:message', (msg: string) => setMessages(m => [...m, msg]));
    return () => { socket.off('chat:message'); };
  }, []);

  const send = () => {
    if (!input.trim()) return;
    socket.emit('chat:send', input.trim());
    setInput('');
    (window as any).desktop?.notify?.('Message sent', 'Your message was sent');
  };

  return (
    <main className="p-6 max-w-2xl mx-auto">
      <h1 className="text-2xl font-semibold mb-4">Discord-like Starter (Desktop)</h1>
      <div className="space-y-2 mb-4">
        {messages.map((m, i) => (<div key={i} className="p-2 rounded bg-zinc-800">{m}</div>))}
      </div>
      <div className="flex gap-2">
        <input
          className="flex-1 bg-zinc-800 rounded px-3 py-2 outline-none"
          value={input}
          onChange={e => setInput(e.target.value)}
          placeholder="Type a message..."
        />
        <button onClick={send} className="px-4 py-2 rounded bg-zinc-700 hover:bg-zinc-600">Send</button>
      </div>
    </main>
  );
}
EOF

# --- NestJS server (minimal) ---
cat > server/package.json <<'EOF'
{
  "name": "server",
  "private": true,
  "version": "0.1.0",
  "scripts": {
    "dev": "nest start --watch",
    "start": "node dist/main.js",
    "build": "nest build",
    "prisma:generate": "prisma generate",
    "prisma:migrate": "prisma migrate dev --name init"
  },
  "dependencies": {
    "@nestjs/common": "^10.0.0",
    "@nestjs/core": "^10.0.0",
    "@nestjs/jwt": "^10.2.0",
    "@nestjs/platform-express": "^10.0.0",
    "@nestjs/platform-socket.io": "^10.0.0",
    "@nestjs/websockets": "^10.0.0",
    "@prisma/client": "^5.16.0",
    "@socket.io/redis-adapter": "^8.2.1",
    "class-transformer": "^0.5.1",
    "class-validator": "^0.14.0",
    "ioredis": "^5.4.2",
    "meilisearch": "^0.40.0",
    "reflect-metadata": "^0.1.13",
    "rimraf": "^5.0.5",
    "rxjs": "^7.8.0",
    "socket.io": "^4.7.5"
  },
  "devDependencies": {
    "@nestjs/cli": "^10.3.0",
    "@nestjs/schematics": "^10.0.0",
    "@nestjs/testing": "^10.0.0",
    "@types/node": "^20.0.0",
    "prisma": "^5.16.0",
    "ts-node": "^10.9.2",
    "tsconfig-paths": "^4.2.0",
    "typescript": "^5.4.0"
  }
}
EOF

cat > server/tsconfig.json <<'EOF'
{
  "compilerOptions": {
    "module": "commonjs",
    "declaration": true,
    "removeComments": true,
    "emitDecoratorMetadata": true,
    "experimentalDecorators": true,
    "allowSyntheticDefaultImports": true,
    "target": "es2017",
    "sourceMap": true,
    "outDir": "./dist",
    "baseUrl": "./",
    "incremental": true
  }
}
EOF

mkdir -p server/prisma server/src/{chat,config,health}
cat > server/prisma/schema.prisma <<'EOF'
generator client {
  provider = "prisma-client-js"
}
datasource db {
  provider = "postgresql"
  url      = env("DATABASE_URL")
}
model User {
  id        String   @id @default(cuid())
  email     String   @unique
  name      String?
  createdAt DateTime @default(now())
  messages  Message[]
}
model Message {
  id        String   @id @default(cuid())
  content   String
  createdAt DateTime @default(now())
  user      User     @relation(fields: [userId], references: [id])
  userId    String
}
EOF

cat > server/src/main.ts <<'EOF'
import 'reflect-metadata';
import { NestFactory } from '@nestjs/core';
import { AppModule } from './app.module';
import { IoAdapter } from '@nestjs/platform-socket.io';
import { ValidationPipe } from '@nestjs/common';

async function bootstrap() {
  const app = await NestFactory.create(AppModule, { cors: true });
  app.useGlobalPipes(new ValidationPipe({ whitelist: true }));
  app.useWebSocketAdapter(new IoAdapter(app));
  const port = process.env.SERVER_PORT ? Number(process.env.SERVER_PORT) : 4000;
  await app.listen(port);
  console.log(`Server listening on http://localhost:${port}`);
}
bootstrap();
EOF

cat > server/src/app.module.ts <<'EOF'
import { Module } from '@nestjs/common';
import { ChatModule } from './chat/chat.module';
import { HealthController } from './health/health.controller';

@Module({
  imports: [ChatModule],
  controllers: [HealthController],
})
export class AppModule {}
EOF

cat > server/src/health/health.controller.ts <<'EOF'
import { Controller, Get } from '@nestjs/common';
@Controller('health')
export class HealthController {
  @Get()
  ok() { return { ok: true }; }
}
EOF

cat > server/src/chat/chat.module.ts <<'EOF'
import { Module } from '@nestjs/common';
import { ChatGateway } from './chat.gateway';
@Module({ providers: [ChatGateway] })
export class ChatModule {}
EOF

cat > server/src/chat/chat.gateway.ts <<'EOF'
import { OnGatewayConnection, OnGatewayDisconnect, SubscribeMessage, WebSocketGateway, WebSocketServer } from '@nestjs/websockets';
import { Server, Socket } from 'socket.io';

@WebSocketGateway({ cors: { origin: '*' } })
export class ChatGateway implements OnGatewayConnection, OnGatewayDisconnect {
  @WebSocketServer() server: Server;
  handleConnection(client: Socket) { console.log('Client connected', client.id); }
  handleDisconnect(client: Socket) { console.log('Client disconnected', client.id); }
  @SubscribeMessage('chat:send')
  onChat(client: Socket, message: string) { this.server.emit('chat:message', message); }
}
EOF

# --- install deps ---
log "Installing workspace dependencies (this can take a few minutes)"
pnpm i -w

# --- infra up ---
log "Starting Docker infrastructure (Postgres, Redis, Meilisearch, MinIO, LiveKit)"
docker compose --env-file .env up -d

# --- prisma init ---
log "Initializing Prisma (database URL from .env)"
export DATABASE_URL="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@localhost:${PG_PORT}/${POSTGRES_DB}"
pnpm -C server prisma:generate
pnpm -C server prisma:migrate

# --- run server & desktop hints ---
log "All set! Next steps:"
echo "  1) Terminal A:  pnpm -C server dev"
echo "  2) Terminal B:  pnpm -C apps/desktop dev"
echo
echo "Backend:   http://localhost:${APP_PORT_API}"
echo "Web UI:    http://localhost:${APP_PORT_WEB}  (Electron will open to this)"
echo
warn "If 'docker: permission denied', log out & back in (docker group), then rerun: docker compose up -d"
