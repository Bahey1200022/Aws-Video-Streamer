#!/usr/bin/env bash
# Camera relay: pull an IP camera's RTSP stream on the local network and push it
# to the platform over RTMPS (TLS). The camera itself never touches the internet.
#
#   IP camera (RTSP, local only) --> this machine --> RTMPS :1936 --> /camera/
#
# Usage:   scripts/camera-relay.sh          (from the repository root)
# Needs:   Docker (ffmpeg runs in a pinned container), Terraform state in terraform/
#
# The camera password is asked for at start-up, kept in memory only, and never
# written to disk or sent to AWS. It does appear in the local ffmpeg process
# arguments (ffmpeg has no other way to take RTSP credentials), so run this on a
# machine you trust.
set -euo pipefail

# ffmpeg 7.1, pinned by digest (Ubuntu 22.04's ffmpeg 4.4 can't do TLS 1.3 RTMPS)
FFMPEG_IMAGE="jrottenberg/ffmpeg@sha256:292a972c60356abd651d9a4f9c808c13e7473f65ad400b7eb99215f4e571931d"
RETRY_SECONDS=5

cd "$(dirname "$0")/.."

PUB_URL="$(terraform -chdir=terraform output -raw camera_publish_url 2>/dev/null || true)"
if [[ "$PUB_URL" != rtmps://* ]]; then
  echo "No camera publish URL: set camera_enabled = true and run terraform apply first." >&2
  exit 1
fi
SITE="$(terraform -chdir=terraform output -raw camera_url 2>/dev/null || true)"

read -rp "Camera IP (shown in IP Webcam): " CAM_IP
read -rp "Port [8080]: " CAM_PORT
read -rp "RTSP path [/h264_aac.sdp]: " CAM_PATH
read -rp "Username: " CAM_USER
read -rsp "Password: " CAM_PASS; echo
CAM_PORT="${CAM_PORT:-8080}"
CAM_PATH="${CAM_PATH:-/h264_aac.sdp}"

# The camera must be on the local network: a public address would mean it is
# exposed to the internet (the Mirai / Shodan problem)
if ! python3 -c 'import ipaddress,sys; sys.exit(0 if ipaddress.ip_address(sys.argv[1]).is_private else 1)' "$CAM_IP" 2>/dev/null; then
  echo "Refusing $CAM_IP: the camera must have a private (local network) address." >&2
  exit 1
fi
[[ "$CAM_PORT" =~ ^[0-9]{1,5}$ ]] || { echo "Invalid port." >&2; exit 1; }
[[ "$CAM_PATH" == /* ]] || CAM_PATH="/$CAM_PATH"

# URL-encode the credentials so characters like @ or : can't break the URL
enc() { python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }
export CAM_URL="rtsp://$(enc "$CAM_USER"):$(enc "$CAM_PASS")@${CAM_IP}:${CAM_PORT}${CAM_PATH}"
export PUB_URL
unset CAM_PASS

# Values reach the container through the environment (-e NAME, no value on the
# docker command line); --network host lets it reach the camera on the LAN
run_ffmpeg() {
  docker run --rm --network host -e CAM_URL -e PUB_URL --entrypoint sh "$FFMPEG_IMAGE" -c "$1"
}

echo "Checking the camera..."
if ! INFO="$(run_ffmpeg 'ffprobe -v error -rtsp_transport tcp -timeout 10000000 -select_streams v:0 -show_entries stream=codec_name,width,height -of csv=p=0 "$CAM_URL"' 2>&1)"; then
  echo "Can't read the camera stream. Check that the IP Webcam server is running, the" >&2
  echo "login is right, and this machine is on the same network as the camera." >&2
  exit 1
fi
echo "✓ Camera found: ${INFO//,/ }"
echo "✓ Streaming to ${SITE:-the camera channel} (Ctrl+C to stop)"

trap 'echo; echo "Stopped."; exit 0' INT TERM
while true; do
  # Video is copied as-is (no CPU cost); audio is converted to AAC for RTMP
  run_ffmpeg 'ffmpeg -nostdin -loglevel warning -rtsp_transport tcp -timeout 10000000 \
      -i "$CAM_URL" -c:v copy -c:a aac -b:a 96k -f flv "$PUB_URL"' \
    2>&1 | sed -E 's#(rtsps?|rtmps?)://[^ ]*#\1://<hidden>#g' || true
  echo "Connection lost - reconnecting in ${RETRY_SECONDS}s..."
  sleep "$RETRY_SECONDS"
done
