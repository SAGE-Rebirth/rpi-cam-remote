#!/bin/bash
# ─────────────────────────────────────────────────────────────
#  camera-stream.sh — IMX500 capture pipeline
#  rpicam-vid → pipe → ffmpeg → RTSP push → MediaMTX
#  Location: /usr/local/bin/camera-stream.sh
#  Called by camera-stream.service — do not run directly.
# ─────────────────────────────────────────────────────────────

# On SIGTERM/SIGINT (from systemd stop/restart), kill BOTH sides
# of the pipe — rpicam-vid and ffmpeg — before exiting.
trap 'kill 0' SIGTERM SIGINT SIGQUIT

echo "[camera-stream] Starting IMX500 capture pipeline..."

rpicam-vid \
    -t 0 \
    --nopreview \
    --codec h264 \
    --libav-format h264 \
    --profile baseline \
    --intra 15 \
    --inline \
    --width 640 \
    --height 480 \
    --framerate 15 \
    --bitrate 1500000 \
    --post-process-file /usr/share/rpi-camera-assets/imx500_mobilenet_ssd.json \
    -o - | \
ffmpeg \
    -hide_banner \
    -loglevel warning \
    -fflags nobuffer \
    -f h264 \
    -i pipe:0 \
    -c:v copy \
    -f rtsp \
    -rtsp_transport tcp \
    rtsp://127.0.0.1:8554/cam

# Wait for both child processes before systemd cleans up the cgroup
wait
