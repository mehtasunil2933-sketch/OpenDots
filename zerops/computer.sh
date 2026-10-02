#!/bin/sh
# OpenDots `computer` service (Zerops Docker VM): computer supervisor + one
# container per Dot, reachable from the `app` service over the private network.
# Usage: sh zerops/computer.sh start|backup|restore
set -eu
APP=$(cd "$(dirname "$0")/.." && pwd)
WORK="$APP/.vm"                    # start runs as the zerops user -> stay inside the deploy dir
NS=${COMPUTER_NAMESPACE:-opendots}
SUP_IMG=opendots-supervisor:b6932d3-remote
COMPUTER_IMG=opendots-computer:b6932d3
HELPER_IMG=node:24-bookworm-slim
RCLONE_IMG=rclone/rclone:1.68.2
BUCKET=${R2_BUCKET:-opendots-backup}

log() { echo "[computer] $*"; }
have_r2() { [ -n "${RCLONE_CONFIG_R2_SECRET_ACCESS_KEY:-}" ]; }

r2() {
  docker run --rm --network=host -v "$WORK/backup:/backup" \
    -e RCLONE_CONFIG_R2_TYPE=s3 -e RCLONE_CONFIG_R2_PROVIDER=Cloudflare \
    -e RCLONE_CONFIG_R2_REGION=auto -e RCLONE_CONFIG_R2_ACL=private \
    -e RCLONE_CONFIG_R2_ENDPOINT -e RCLONE_CONFIG_R2_ACCESS_KEY_ID -e RCLONE_CONFIG_R2_SECRET_ACCESS_KEY \
    "$RCLONE_IMG" "$@"
}

computer_volumes() {
  docker volume ls -q --filter "label=openbot.supervisor=true" --filter "label=openbot.namespace=$NS"
}

backup() {
  have_r2 || { log "R2 not configured - skipping backup"; return 0; }
  STAMP=$(date -u +%Y-%m-%dT%H%M)
  S="$WORK/backup/stage"
  rm -rf "$S"; mkdir -p "$S"
  : > "$S/volumes.txt"
  for v in $(computer_volumes); do
    b=$(docker volume inspect -f '{{index .Labels "openbot.bot-id"}}' "$v")
    echo "$v $b" >> "$S/volumes.txt"
    docker run --rm -v "$v:/v:ro" -v "$S:/out" "$HELPER_IMG" tar -czf "/out/$v.tgz" -C /v .
  done
  tar -cf "$WORK/backup/computers-$STAMP.tar" -C "$S" .
  r2 copyto "/backup/computers-$STAMP.tar" "r2:$BUCKET/computers/computers-$STAMP.tar"
  r2 copyto "/backup/computers-$STAMP.tar" "r2:$BUCKET/computers/latest.tar"
  r2 delete "r2:$BUCKET/computers/" --min-age 30d --include "computers-*.tar" || true
  ls -1t "$WORK"/backup/computers-*.tar 2>/dev/null | tail -n +3 | xargs -r rm -f
  rm -rf "$S"
  log "backup $STAMP uploaded"
}

restore() {
  have_r2 || { log "R2 not configured - fresh start"; return 0; }
  R="$WORK/backup/restore"
  rm -rf "$R"; mkdir -p "$R"
  # An R2 error must stop the start; only a truly empty bucket means "fresh start"
  found=$(r2 lsf "r2:$BUCKET/computers/" --include latest.tar) || { log "cannot reach R2 bucket $BUCKET"; return 1; }
  if [ -z "$found" ]; then
    log "no computer backup in R2 - fresh start"; rm -rf "$R"; return 0
  fi
  r2 copyto "r2:$BUCKET/computers/latest.tar" /backup/restore/latest.tar
  tar -xf "$R/latest.tar" -C "$R"
  while read -r v b; do
    [ -n "$v" ] || continue
    docker volume inspect "$v" >/dev/null 2>&1 || docker volume create \
      --label openbot.supervisor=true --label "openbot.namespace=$NS" --label "openbot.bot-id=$b" "$v" >/dev/null
    docker run --rm -v "$v:/v" -v "$R:/in:ro" "$HELPER_IMG" tar -xzpf "/in/$v.tgz" -C /v
  done < "$R/volumes.txt"
  rm -rf "$R"
  log "restored computer volumes from latest backup"
}

stop() {
  log "stopping - final backup"
  backup || log "final backup FAILED"
  docker stop -t 20 od-supervisor >/dev/null 2>&1 || true
  exit 0
}

start() {
  mkdir -p "$WORK/backup"

  # The VM's eth0 MTU (1450) is smaller than docker0's (1500): without clamping,
  # HTTPS from bridge containers (image build + Dot computers) stalls. Idempotent;
  # refuse to start without it, otherwise Dot computers silently cannot browse.
  sudo -n iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
    || sudo -n iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu \
    || { log "MSS CLAMP FAILED - container networking would be broken, refusing to start"; exit 1; }
  log "MSS clamp active"

  # No computer volumes = new VM or wiped disk -> restore first. Never start empty
  # over a failed restore, otherwise the next backup would overwrite good data in R2.
  if [ -z "$(computer_volumes)" ]; then
    restore || { log "RESTORE FAILED - refusing to start so R2 backups are not overwritten"; exit 1; }
  fi

  log "building images (first run takes several minutes)"
  docker build -t "$SUP_IMG" "$APP/zerops/build/supervisor"
  docker build -t "$COMPUTER_IMG" -f "$APP/openbot/agent-computer/Dockerfile" "$APP/openbot"
  log "images built"

  docker rm -f od-supervisor >/dev/null 2>&1 || true

  # The only container with the Docker socket. Computers are published on the
  # fixed private port pool (declared in zerops.yaml) and reported to the app as
  # http://$COMPUTER_PUBLIC_HOST:<port>.
  SUPERVISOR_TOKEN="$COMPUTER_SUPERVISOR_TOKEN" \
  docker run -d --name od-supervisor --network=host --restart unless-stopped --init \
    --memory 256m --security-opt no-new-privileges:true --cap-drop ALL \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -e PORT=4312 -e SUPERVISOR_TOKEN -e COMPUTER_TOKEN \
    -e COMPUTER_NAMESPACE="$NS" -e COMPUTER_IMAGE="$COMPUTER_IMG" \
    -e COMPUTER_BROWSER_MODE=headless -e COMPUTER_NETWORK= -e COMPUTER_MEMORY_BYTES \
    -e COMPUTER_PORT_POOL -e COMPUTER_PUBLISH_IP -e COMPUTER_PUBLIC_HOST \
    "$SUP_IMG"
  log "supervisor started on :4312"

  trap stop TERM INT
  ( while true; do sleep 21600; backup || log "backup FAILED"; done ) &
  docker logs -f od-supervisor &
  wait
}

case "${1:-start}" in
  start) start ;;
  backup) backup ;;
  restore) restore ;;
  *) echo "usage: sh zerops/computer.sh start|backup|restore"; exit 2 ;;
esac
