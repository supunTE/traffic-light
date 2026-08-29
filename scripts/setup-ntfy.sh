#!/bin/sh
# Point Traffic Light at an ntfy server you control, so notifications reach
# your phone without passing through anyone else's machine.
#
#   sh scripts/setup-ntfy.sh
#   sh scripts/setup-ntfy.sh uninstall
#
# Safe to re-run. Run it again after installing Tailscale and it picks up the
# tailnet hostname automatically.
#
# Why Docker: ntfy's server is Linux-only. Neither `brew install ntfy` nor the
# official macOS tarball includes `serve` — both are client-only builds, and
# both fail with "No help topic for 'serve'". Docker is the only supported way
# to run the server on a Mac.
set -e

port=2586
container=traffic-light-ntfy
tl_config="$HOME/Library/Application Support/traffic-light/config.json"
data="$HOME/Library/Application Support/traffic-light/ntfy"

if [ "${1:-}" = "uninstall" ]; then
    docker rm -f "$container" >/dev/null 2>&1 || true
    echo "Stopped and removed $container. Data left in $data"
    exit 0
fi

command -v docker >/dev/null 2>&1 || { echo "Docker is required: ntfy's server does not run natively on macOS." >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "Docker is installed but not running. Start Docker Desktop and re-run." >&2; exit 1; }
[ -f "$tl_config" ] || { echo "Run the daemon once first so config.json exists." >&2; exit 1; }

# How the phone reaches this Mac, best available first. A tailnet address works
# from anywhere; a LAN address only while you are on the same WiFi.
host=""
if command -v tailscale >/dev/null 2>&1; then
    host=$(tailscale status --json 2>/dev/null | sed -n 's/.*"DNSName": *"\([^"]*\)\..*/\1/p' | head -1)
    [ -n "$host" ] && echo "Using tailnet host: $host"
fi
if [ -z "$host" ]; then
    host=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)
    [ -n "$host" ] || { echo "No usable network address found." >&2; exit 1; }
    echo "Tailscale not found — using the LAN address $host."
    echo "Push will work only while the phone is on the same WiFi. Install"
    echo "Tailscale and re-run this script to make it work from anywhere."
fi

mkdir -p "$data/cache" "$data/etc"
cat > "$data/etc/server.yml" <<YAML
# Written by traffic-light/scripts/setup-ntfy.sh
base-url: "http://$host:$port"
listen-http: ":80"
cache-file: "/var/cache/ntfy/cache.db"
cache-duration: "12h"

# iOS allows background delivery only through APNs, so a self-hosted server
# cannot wake an iPhone by itself. This forwards a CONTENTLESS poll request
# via ntfy.sh; the phone then fetches the real message from this Mac, so no
# message content reaches ntfy.sh. Android holds a direct connection and
# ignores this entirely. Delete the line if you never use an iPhone.
upstream-base-url: "https://ntfy.sh"
YAML

docker rm -f "$container" >/dev/null 2>&1 || true
docker run -d --name "$container" --restart unless-stopped \
    -p "$port:80" \
    -v "$data/cache:/var/cache/ntfy" \
    -v "$data/etc/server.yml:/etc/ntfy/server.yml:ro" \
    binwiederhier/ntfy serve >/dev/null

i=0
while [ $i -lt 40 ]; do
    curl -fsS -m 1 "http://127.0.0.1:$port/v1/health" >/dev/null 2>&1 && break
    i=$((i + 1)); sleep 0.25
done
curl -fsS -m 2 "http://127.0.0.1:$port/v1/health" >/dev/null 2>&1 || {
    echo "ntfy did not come up. Logs:" >&2; docker logs --tail 20 "$container" >&2; exit 1; }
echo "ntfy running at http://$host:$port"

# Deliberately does not touch config.json. The daemon is the only thing that
# writes that file — Settings edits it in-process — and a shell script editing
# it behind the daemon's back is the same lost-update bug from the other side.
cat <<NEXT

Server is up. Point Traffic Light at it:

  Set "server" in ~/Library/Application Support/traffic-light/config.json
  Server:  http://$host:$port

Then subscribe your phone from Settings -> Notifications: scan the QR on
Android, or type the server and topic by hand on iPhone.
NEXT
