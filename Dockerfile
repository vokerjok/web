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
