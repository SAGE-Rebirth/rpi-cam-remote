# Setup Guide — RPi IMX500 Remote Camera Stream

A step-by-step beginner-friendly guide to get your Sony IMX500 camera streaming remotely over Tailscale. Follow each step in order.

---

## What You Need

- Raspberry Pi 4 or 5 with Raspberry Pi OS (64-bit) installed
- Sony IMX500 AI Camera Module connected to the Pi
- Your Mac (or any computer) on the same Wi-Fi as the Pi initially
- Internet connection on both devices

---

## Step 1 — Connect to the Pi via SSH

On your Mac, open Terminal and connect:

```bash
ssh test@<pi-local-ip>
```

> Replace `<pi-local-ip>` with your Pi's local IP. You can find it from your router, or if the Pi has a screen, run `hostname -I` on it.

---

## Step 2 — Download the Setup Files

On your Mac, download the zip from this project and copy it to the Pi:

```bash
scp rpi-cam-stream.zip test@<pi-local-ip>:~
```

Then SSH into the Pi and extract:

```bash
ssh test@<pi-local-ip>
unzip rpi-cam-stream.zip
```

---

## Step 3 — Run the Installer

```bash
sudo bash deploy.sh
```

This will automatically:
- Detect your Pi's architecture
- Install ffmpeg and dependencies
- Download and install MediaMTX
- Write all config files to their correct system locations
- Create and enable both systemd services
- Start the camera stream

When it finishes you should see:

```
MediaMTX        running
Camera stream   running
```

---

## Step 4 — Install Tailscale on the Pi

Tailscale is the VPN that lets you access the stream from anywhere without port forwarding.

**Install:**

```bash
curl -fsSL https://tailscale.com/install.sh | sh
```

**Connect:**

```bash
sudo tailscale up
```

You will see a URL printed in the terminal like this:

```
To authenticate, visit:

    https://login.tailscale.com/a/xxxxxxxxxxxxxxx
```

> **Important:** You cannot open a browser on the Pi. Copy this URL and open it on your Mac's browser instead.

**Authenticate:**

1. Copy the `https://login.tailscale.com/a/xxx...` URL from the Pi terminal
2. Paste it into your Mac's browser
3. Sign in or create a free Tailscale account
4. The Pi will automatically connect once you authenticate

**Verify it worked:**

```bash
cam-ctrl test
```

You should see:

```
✓ mediamtx is running
✓ camera-stream is running
✓ API is reachable
✓ Tailscale connected — IP: 100.x.x.x
```

Note down the Tailscale IP shown — you'll need it to connect from your Mac.

---

## Step 5 — Install Tailscale on Your Mac

Go to the official download page:

```
https://tailscale.com/download/macos
```

You can install it two ways:

**Option A — Mac App Store (easiest):**
- Click "Download from Mac App Store" on the page above
- Install and open it like any app

**Option B — Direct download:**
- Click the direct download link on the same page
- Open the `.pkg` file and follow the installer

**After installing:**

1. Click the Tailscale icon in your Mac's menu bar (top right)
2. Click **Log in**
3. Sign in with the **same account** you used on the Pi
4. Your Mac will join the same Tailscale network as the Pi

> Both devices must be signed into the **same Tailscale account**. That is the only requirement for them to see each other.

---

## Step 6 — Get the Stream URLs

SSH into the Pi and run:

```bash
cam-ctrl url
```

You will see output like:

```
Local network
  RTSP    →  rtsp://10.x.x.x:8554/cam
  HLS     →  http://10.x.x.x:8888/cam

Remote via Tailscale
  RTSP    →  rtsp://100.x.x.x:8554/cam
  HLS     →  http://100.x.x.x:8888/cam
  API     →  http://100.x.x.x:9997

Mac ffplay command
  ffplay -fflags nobuffer -flags low_delay -framedrop -vf setpts=0 rtsp://100.x.x.x:8554/cam
```

---

## Step 7 — Watch the Stream on Your Mac

**Option A — ffplay (lowest latency, recommended):**

```bash
ffplay -fflags nobuffer -flags low_delay -framedrop \
  -rtsp_transport tcp \
  -vf setpts=0 \
  rtsp://100.x.x.x:8554/cam
```

> Install ffplay with: `brew install ffmpeg`

**Option B — Browser (no install needed):**

Open Safari or Chrome and go to:

```
http://100.x.x.x:8888/cam
```

> Use the `100.x.x.x` Tailscale IP, not the local `10.x.x.x` IP. The Tailscale IP works from any network anywhere in the world.

---

## Step 8 — Managing the Stream Remotely

From now on, SSH into the Pi from anywhere using the Tailscale IP:

```bash
ssh test@100.x.x.x
```

Then use `cam-ctrl` to manage everything:

```bash
cam-ctrl status          # are both services running?
cam-ctrl test            # full health check
cam-ctrl url             # print all stream URLs
cam-ctrl watch           # follow live logs

sudo cam-ctrl restart        # restart camera stream
sudo cam-ctrl restart-all    # restart everything
sudo cam-ctrl stop           # stop all services
sudo cam-ctrl start          # start all services
```

---

## Everything is Automatic From Here

You never need to run `deploy.sh` again. The services are permanently installed and will:

- ✅ Start automatically every time the Pi boots
- ✅ Restart automatically if they crash
- ✅ Recover automatically after a power cut
- ✅ Reconnect Tailscale automatically when internet comes back

---

## Quick Troubleshooting

**Stream times out from Mac:**
- Make sure Tailscale is running on your Mac (check menu bar icon)
- Make sure you're signed into the same Tailscale account on both devices
- Run `cam-ctrl test` on the Pi to verify everything is up

**Dropped frames / choppy video:**

Add `-rtsp_transport tcp` to your ffplay command and lower the bitrate on the Pi:

```bash
sudo nano /usr/local/bin/camera-stream.sh
# Change --bitrate 5000000 to --bitrate 2000000
sudo cam-ctrl restart
```

**Camera stream keeps stopping:**

```bash
cam-ctrl logs    # read the error
sudo cam-ctrl restart
```

**Tailscale disconnected on Pi:**

```bash
sudo tailscale status
sudo tailscale up
```
