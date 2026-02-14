#!/usr/bin/env bash
set -euo pipefail

# ================== CONFIG (ubah kalau perlu) ==================
APP_DIR="${APP_DIR:-$HOME/headless-supervisor}"
IMAGE="${IMAGE:-headless-supervisor:latest}"
CONTAINER="${CONTAINER:-headless-supervisor}"
AUTO_URL="${AUTO_URL:-https://juuk.store}"
AUTO_BROWSER="${AUTO_BROWSER:-firefox}"          # firefox|chromium
AUTO_RESTART_DELAY="${AUTO_RESTART_DELAY:-2}"   # detik
# ===============================================================

SUDO=""
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    echo "ERROR: butuh sudo untuk install docker. Install sudo dulu atau jalankan sebagai root."
    exit 1
  fi
fi

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: butuh command: $1"; exit 1; }
}

install_docker_if_needed() {
  if command -v docker >/dev/null 2>&1; then
    echo "[OK] Docker sudah terinstall."
    return
  fi

  echo "[INFO] Docker belum ada. Install Docker..."
  $SUDO apt-get update -y
  $SUDO apt-get install -y ca-certificates curl gnupg lsb-release

  $SUDO install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg | $SUDO gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  $SUDO chmod a+r /etc/apt/keyrings/docker.gpg

  $SUDO bash -lc 'echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list'

  $SUDO apt-get update -y
  $SUDO apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  $SUDO systemctl enable --now docker
  echo "[OK] Docker terinstall & aktif."
}

ensure_user_can_run_docker() {
  # biar user non-root bisa docker tanpa sudo
  if groups "$USER" | grep -q "\bdocker\b"; then
    echo "[OK] User $USER sudah ada di group docker."
  else
    echo "[INFO] Tambah user $USER ke group docker..."
    $SUDO groupadd -f docker
    $SUDO usermod -aG docker "$USER"
    echo "[OK] Ditambahkan. Catatan: kamu harus logout/login ulang agar group docker aktif."
  fi

  # cek akses socket docker (kalau belum logout/login, bisa belum aktif)
  if ! docker info >/dev/null 2>&1; then
    echo "[WARN] Saat ini user belum bisa akses docker (biasanya karena belum re-login)."
    echo "       Solusi cepat: logout/login ulang, atau jalankan: newgrp docker"
  else
    echo "[OK] Akses docker dari user sudah jalan."
  fi
}

write_files() {
  mkdir -p "$APP_DIR/data"
  cd "$APP_DIR"

  cat > Dockerfile <<'DOCKERFILE'
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Singapore

# Install browser + dependency minimal buat headless
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates bash curl tzdata \
    firefox-esr chromium \
    fonts-liberation fonts-noto-color-emoji \
    libgtk-3-0 libnss3 libxss1 libasound2 libgbm1 libx11-xcb1 \
    && rm -rf /var/lib/apt/lists/*

# User non-root (lebih aman)
RUN useradd -m -u 1000 worker \
  && mkdir -p /app /data \
  && chown -R worker:worker /app /data

WORKDIR /app

COPY --chown=worker:worker supervisor.sh /app/supervisor.sh
RUN chmod +x /app/supervisor.sh

USER worker

ENV AUTO_URL="https://juuk.store" \
    AUTO_RESTART_DELAY="2" \
    AUTO_LOG="/data/headless_url.log" \
    AUTO_BROWSER="firefox"

VOLUME ["/data"]
ENTRYPOINT ["/app/supervisor.sh"]
DOCKERFILE

  cat > supervisor.sh <<'SUPERVISOR'
#!/usr/bin/env bash
set -euo pipefail

# ================== CONFIG ==================
URL="${1:-${AUTO_URL:-https://juuk.store}}"
DELAY="${AUTO_RESTART_DELAY:-2}"                 # detik
LOG_FILE="${AUTO_LOG:-/data/headless_url.log}"   # file log
BROWSER_PREF="${AUTO_BROWSER:-firefox}"          # firefox|chromium|chrome (opsional)

ts(){ date +"%Y-%m-%d %H:%M:%S"; }
log(){ echo "[$(ts)] $*" | tee -a "$LOG_FILE"; }

pick_browser() {
  if [[ "$BROWSER_PREF" == "firefox" ]] && command -v firefox >/dev/null 2>&1; then echo firefox; return; fi
  if [[ "$BROWSER_PREF" == "chromium" ]] && command -v chromium >/dev/null 2>&1; then echo chromium; return; fi
  if [[ "$BROWSER_PREF" == "chromium" ]] && command -v chromium-browser >/dev/null 2>&1; then echo chromium-browser; return; fi
  if [[ "$BROWSER_PREF" == "chrome" ]] && command -v google-chrome >/dev/null 2>&1; then echo google-chrome; return; fi
  if [[ "$BROWSER_PREF" == "chrome" ]] && command -v chrome >/dev/null 2>&1; then echo chrome; return; fi

  if command -v firefox >/dev/null 2>&1; then echo firefox; return; fi
  if command -v chromium >/dev/null 2>&1; then echo chromium; return; fi
  if command -v chromium-browser >/dev/null 2>&1; then echo chromium-browser; return; fi
  if command -v google-chrome >/dev/null 2>&1; then echo google-chrome; return; fi
  if command -v chrome >/dev/null 2>&1; then echo chrome; return; fi

  echo ""
}

child_pid=""

cleanup() {
  log "STOP signal. Killing child if running..."
  if [[ -n "${child_pid:-}" ]] && kill -0 "$child_pid" 2>/dev/null; then
    kill "$child_pid" 2>/dev/null || true
    sleep 1 || true
    kill -9 "$child_pid" 2>/dev/null || true
  fi
  exit 0
}
trap cleanup INT TERM

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

BROWSER="$(pick_browser)"
if [[ -z "${BROWSER:-}" ]]; then
  echo "ERROR: Browser tidak ditemukan. Install firefox/chromium/chrome dulu."
  exit 1
fi

log "Supervisor START | browser=$BROWSER | url=$URL | delay=${DELAY}s"
log "Log file: $LOG_FILE"

while true; do
  log "Launching: $BROWSER (headless) -> $URL"

  set +e
  case "$BROWSER" in
    firefox)
      firefox --headless --no-remote --new-instance "$URL" >>"$LOG_FILE" 2>&1 &
      ;;
    chromium|chromium-browser|google-chrome|chrome)
      "$BROWSER" \
        --headless=new \
        --disable-gpu \
        --no-sandbox \
        --disable-dev-shm-usage \
        --no-first-run \
        --no-default-browser-check \
        "$URL" >>"$LOG_FILE" 2>&1 &
      ;;
    *)
      log "ERROR: Unsupported browser: $BROWSER"
      exit 1
      ;;
  esac

  child_pid="$!"
  wait "$child_pid"
  code="$?"
  child_pid=""
  set -e

  log "Browser EXIT (code=$code). Restart in ${DELAY}s..."
  sleep "$DELAY"
done
SUPERVISOR

  chmod +x supervisor.sh

  cat > run.sh <<'RUNSH'
#!/usr/bin/env bash
set -euo pipefail

APP_DIR="${APP_DIR:-$HOME/headless-supervisor}"
IMAGE="${IMAGE:-headless-supervisor:latest}"
CONTAINER="${CONTAINER:-headless-supervisor}"

AUTO_URL="${AUTO_URL:-https://juuk.store}"
AUTO_BROWSER="${AUTO_BROWSER:-firefox}"
AUTO_RESTART_DELAY="${AUTO_RESTART_DELAY:-2}"

cd "$APP_DIR"

echo "[INFO] Build image: $IMAGE"
docker build -t "$IMAGE" .

echo "[INFO] Stop/remove container lama (kalau ada): $CONTAINER"
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true

echo "[INFO] Run container (auto restart on reboot): $CONTAINER"
docker run -d \
  --name "$CONTAINER" \
  --restart unless-stopped \
  -e AUTO_URL="$AUTO_URL" \
  -e AUTO_BROWSER="$AUTO_BROWSER" \
  -e AUTO_RESTART_DELAY="$AUTO_RESTART_DELAY" \
  -e AUTO_LOG="/data/headless_url.log" \
  -v "$APP_DIR/data:/data" \
  "$IMAGE" >/dev/null

echo "[OK] Running: $CONTAINER"
echo "Logs: docker logs -f $CONTAINER"
echo "File log: tail -f $APP_DIR/data/headless_url.log"
RUNSH
  chmod +x run.sh

  cat > stop.sh <<'STOPSH'
#!/usr/bin/env bash
set -euo pipefail
CONTAINER="${CONTAINER:-headless-supervisor}"
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
echo "[OK] Stopped/removed: $CONTAINER"
STOPSH
  chmod +x stop.sh
}

build_and_run() {
  cd "$APP_DIR"
  ./run.sh
}

main() {
  need_cmd curl
  install_docker_if_needed
  ensure_user_can_run_docker
  write_files
  build_and_run

  echo
  echo "==================== DONE ===================="
  echo "Folder: $APP_DIR"
  echo "Start ulang kapanpun (non-root): $APP_DIR/run.sh"
  echo "Stop (non-root): $APP_DIR/stop.sh"
  echo
  echo "AUTO RUN saat reboot:"
  echo " - Sudah aktif via: --restart unless-stopped"
  echo " - Pastikan service docker auto-start (sudah di-enable)."
  echo "=============================================="
}

main "$@"
