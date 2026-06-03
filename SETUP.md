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

On your Mac, open Terminal. Most home networks resolve the Pi by its hostname over mDNS/Bonjour, so this usually works out of the box:

```bash
ssh test@pi.local
```

> `pi.local` is the default hostname on a fresh Raspberry Pi OS install. If you changed the hostname, swap it in (e.g., `test@mycam.local`).

If `.local` resolution doesn't work on your network, use the Pi's IP address instead:

```bash
ssh test@<pi-local-ip>
```

> To find the local IP: check your router's connected-devices page, or — if the Pi has a screen attached — run `hostname -I` on the Pi.

First connection will prompt `Are you sure you want to continue connecting?` — type `yes` to accept the host key.

---

## Step 2 — Copy the Setup Files to the Pi

From your Mac, in the directory that contains `rpi-cam-stream.zip`, copy the zip to the Pi:

```bash
scp rpi-cam-stream.zip test@pi.local:~/rpi-cam/
```

> If `pi.local` doesn't resolve, substitute the Pi's IP: `scp rpi-cam-stream.zip test@<pi-local-ip>:~`

Then SSH into the Pi and extract:

```bash
ssh test@pi.local
cd rpi-cam
unzip -o rpi-cam-stream.zip
```

> `unzip -o` overwrites existing files without prompting — useful when re-deploying.

---

## Step 2.5 — Pin your hotspot as the priority Wi-Fi (optional but recommended)

If the Pi connects to your phone hotspot, run this once so it always picks the hotspot quickly and never drops the link due to Wi-Fi power saving:

```bash
sudo bash wifi-priority.sh "OnePlus 12"
```

Replace `"OnePlus 12"` with your hotspot's SSID (use quotes if it has spaces). The script:
- Disables Wi-Fi power management (live + permanently via `/etc/NetworkManager/conf.d/wifi-powersave-off.conf`)
- Sets the matching profile(s) to `autoconnect yes`, priority `10`, retries `0` (forever)
- Prints a verification block, then reboots so everything comes back clean

If you've never connected the Pi to that hotspot before, connect once first:

```bash
sudo nmcli device wifi connect "OnePlus 12" --ask
```

then re-run `wifi-priority.sh`.

---

## Step 3 — Set Up Tailscale on the Pi (one command)

Tailscale is the VPN that lets you access the stream from anywhere without port forwarding. Do this **before** running the installer so the deploy step can verify the connection.

```bash
sudo bash tailscale-setup.sh
```

The script installs Tailscale, starts `tailscaled`, and runs `tailscale up`. You will see a URL printed in the terminal like this:

```
To authenticate, visit:

    https://login.tailscale.com/a/xxxxxxxxxxxxxxx
```

> **Important:** You cannot open a browser on the Pi. Copy this URL and open it on your Mac's browser to authenticate.

**Authenticate:**

1. Copy the `https://login.tailscale.com/a/xxx...` URL from the Pi terminal
2. Paste it into your Mac's browser
3. Sign in or create a free Tailscale account
4. The Pi joins your tailnet automatically once you authenticate

When the script finishes you should see:

```
[+] Tailscale is up.
[i] Hostname:     <your-pi-hostname>
[i] Tailnet IPv4: 100.x.x.x
[i] SSH access:   ssh test@100.x.x.x
[+] Next step: sudo bash deploy.sh
```

Note down the `100.x.x.x` Tailscale IP — you'll need it from your Mac.

**Optional — non-interactive setup** with a pre-generated [Tailscale auth key](https://login.tailscale.com/admin/settings/keys):

```bash
TS_AUTHKEY=tskey-auth-xxxxxxxxxxxx sudo -E bash tailscale-setup.sh
```

You can also override the tailnet hostname with `TS_HOSTNAME=rpi-cam`. The script is **idempotent** — safe to re-run; it will skip steps that are already done.

---

## Step 4 — Run the Installer

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

**Verify everything is up:**

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
  WebRTC  →  http://10.x.x.x:8889/cam

Remote via Tailscale
  RTSP    →  rtsp://100.x.x.x:8554/cam
  HLS     →  http://100.x.x.x:8888/cam
  WebRTC  →  http://100.x.x.x:8889/cam
  API     →  http://100.x.x.x:9997

Mac ffplay command
  ffplay -fflags nobuffer -flags low_delay -framedrop -vf setpts=0 rtsp://100.x.x.x:8554/cam
```

---

## Step 7 — Watch the Stream on Your Mac

**Option A — Browser via WebRTC (recommended, no install needed):**

Open Chrome, Safari, or Firefox and go to:

```
http://100.x.x.x:8889/cam
```

WebRTC gives sub-second latency (typically 200–350 ms end-to-end over Tailscale) and works from any device with a modern browser. No plugins, no app — MediaMTX serves a built-in player page.

**Option B — ffplay (also low latency, but requires install):**

```bash
ffplay -fflags nobuffer -flags low_delay -framedrop \
  -rtsp_transport tcp \
  -vf setpts=0 \
  rtsp://100.x.x.x:8554/cam
```

> Install ffplay with: `brew install ffmpeg`

**Option C — Browser via HLS (universal fallback):**

```
http://100.x.x.x:8888/cam
```

Plays in any browser including mobile. Higher latency than WebRTC (typically 1–2 s) — useful only if WebRTC is somehow blocked or unavailable.

> Use the `100.x.x.x` Tailscale IP, not the local `10.x.x.x` IP. The Tailscale IP works from any network, anywhere in the world.

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

**First port of call — run the full diagnostic report on the Pi:**

```bash
bash diagnose.sh
```

This walks through every layer (camera hardware, encoder, services, ports, MediaMTX API, Tailscale, local stream playback) and tells you exactly which step is failing. No sudo required.

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

If Tailscale was never installed (e.g., you skipped Step 3), just run the setup script again — it's idempotent:

```bash
sudo bash tailscale-setup.sh
```

---

## Uninstall (start over from scratch)

If you want to wipe everything this project installed — for example, to re-deploy cleanly or to repurpose the Pi:

```bash
sudo bash uninstall.sh
```

The script will:
- Stop and disable the `mediamtx` and `camera-stream` services
- Remove `/usr/local/bin/{mediamtx, camera-stream.sh, cam-ctrl}`
- Remove `/etc/mediamtx/`
- Ask **separately** whether to also remove Tailscale and ffmpeg (default: no, because you might use them for other things)

It will **not** touch:
- Your `rpi-cam` folder (the zip extract) — re-running `deploy.sh` from it gets you back up
- Your home directory or any other files

For a fully scripted uninstall with no prompts:

```bash
sudo bash uninstall.sh --yes --keep-tailscale --keep-ffmpeg
```

Flags: `--tailscale` / `--keep-tailscale` and `--ffmpeg` / `--keep-ffmpeg` decide each optional component upfront so the script can run unattended.
