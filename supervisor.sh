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
