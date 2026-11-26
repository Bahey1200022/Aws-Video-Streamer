# How to use the platform

The everyday steps: opening the monitoring, streaming from a phone in **real time** (WebRTC), and streaming from a phone over **WireGuard + RTMP**. For how each part works, see the links at the end of each section.

All commands run on the control machine (the laptop that ran `terraform apply`). `terraform output` commands run in the `terraform/` folder.

## Before anything: after the nightly shutdown

The lab stops every server at midnight. When they start again the frontend gets a **new public IP**, so run this first:

```bash
cd terraform && terraform apply
```

It starts the servers, points the DNS record at the new IP, re-runs Ansible and reopens the Grafana tunnel. It also updates the SSH allow-list if **your** IP changed (new Wi-Fi, home vs. university).

| What | Where |
|---|---|
| Website | https://bahey.devops.gin-telecom.ovh/ (`terraform output stream_url`) |
| Grafana (monitoring) | http://localhost:3000, on the control machine only |

---

## 1. Monitoring (Grafana)

Grafana runs on the monitoring server, which has no public IP. You reach it through an **SSH tunnel** via the frontend, and `terraform apply` opens that tunnel for you.

1. Open **http://localhost:3000** on the control machine.
2. Log in:
   - user: `admin`
   - password: `terraform output -raw grafana_admin_password`, or the one you set in `terraform/secrets.auto.tfvars`
3. Go to **Dashboards → MSS**:

| Dashboard | Shows |
|---|---|
| **MSS - Platform** | CPU, memory, disk and network of every server; services; pending updates |
| **MSS - Stream** | Publishers per channel (`stream`, `phone`), HLS chunk age, bitrate, website response time; the real-time phone (MediaMTX) |
| **MSS - Security** | Failed SSH logins, rejected stream keys, scanners (4xx), refused WebRTC logins, errors in logs |

### If localhost:3000 doesn't open

| Cause | Fix |
|---|---|
| Laptop rebooted, or you changed network | `cd ansible && ansible-playbook site.yml --tags grafana` (reopens the tunnel only) |
| Nightly restart (the frontend's IP changed) | `terraform apply` first, then the line above if needed |
| Port 3000 already used on the laptop | Close whatever uses it, then rerun `--tags grafana` |
| You want to do it by hand | `terraform output -raw grafana_tunnel`: run the printed command and keep that terminal open |

Details: [MONITORING.md](MONITORING.md#opening-grafana).

---

## 2. Phone in real time (WebRTC): under 1 second of delay

**Website button: Phone · real time**. It needs `enable_webrtc = true` (the default).

```
phone (MSS Camera app) ── WHIP over HTTPS + password ──► nginx ──► MediaMTX
                       ══ video, UDP 8189, encrypted ══►            │
browser ◄══ WebRTC (WHEP), frame by frame ═════════════════════════┘
```

**Use the MSS Camera app, not Larix.** Larix's WebRTC never sends any video to MediaMTX (see [WEBRTC.md](WEBRTC.md#why-not-larix)).

### Setup (once)

1. **Install MSS Camera** on the Android phone:
   - Phone: Settings → About phone → Software information → tap **Build number** 7 times → Developer options → **USB debugging** on. Plug in the phone and accept the prompt.
   - Laptop: `cd ~/phone-app && flutter run` (or `flutter build apk` and copy the `.apk` to the phone).
2. **Address** (WHIP URL): `terraform output -raw webrtc_whip_url`
   → `https://bahey.devops.gin-telecom.ovh/phone/whip`
3. **Password**: show it as a QR code on the laptop and scan it. Don't send it by message:
   ```bash
   terraform output -raw webrtc_password | qrencode -t ansiutf8
   ```
   The app keeps it in Android's encrypted storage.

### Each time

1. In MSS Camera, tap **Go live**.
2. On the website, click **Phone · real time**.

No WireGuard is needed: the password protects the publishing, and WebRTC encrypts the video.

### If it doesn't work

| Symptom | Likely cause |
|---|---|
| "The phone camera is not streaming right now" | The app isn't live yet, or it stopped. Tap **Go live**. |
| App says unauthorized (401) | Wrong password: scan the QR code again |
| Connects, then no picture | The network blocks UDP (some company or hotel Wi-Fi): try 4G |
| Worked yesterday, not today | Nightly restart: MediaMTX announces the IP from the last deployment. Run `terraform apply`. |

Details: [WEBRTC.md](WEBRTC.md).

---

## 3. Phone over WireGuard + RTMP: about 12–15 seconds of delay

**Website button: Phone · WireGuard**. It needs `enable_phone_camera = true` (the default).

```
phone: Larix ── rtmp://10.99.0.1:1935/live/phone?key=… ──┐
       WireGuard app (10.99.0.3) ══ UDP 51820, encrypted ═╪══► frontend 10.99.0.1
                                                          └─► nginx-rtmp → HLS/DASH → browser
```

More delay than WebRTC, but it's the same path as the video loop, and every HLS player (Safari, VLC, smart TVs) can watch it at `/hls/phone.m3u8`.

### Setup (once)

1. **Install two apps** on the phone (Android or iOS): **WireGuard** and **Larix Broadcaster**.
2. **WireGuard tunnel.** Every deployment writes the phone's tunnel settings to `ansible/phone/` on the laptop (git-ignored, readable only by you).
   - In the WireGuard app: **+** → **Scan from QR code** → scan `ansible/phone/mss-phone.png` on the laptop screen. Name it `mss`.
   - The QR code holds the phone's private key: **don't share a screenshot of it**.
3. **Larix connection.** Settings → Connections → **New connection**:

   | Field | Value |
   |---|---|
   | Name | `mss` |
   | URL | `rtmp://10.99.0.1:1935/live/phone?key=<phone key>` |

   Get the phone key with `terraform output -raw phone_stream_key`. Use `10.99.0.1` (the tunnel address), **not** the domain name.
4. **Recommended Larix settings** (for a steadier picture on 4G): 854×480, 800 kbit/s, 30 fps, keyframe every 1 s, **adaptive bitrate** on.

### Each time

1. Turn **on** the `mss` tunnel in the WireGuard app.
2. In Larix, press the record button.
3. On the website, click **Phone · WireGuard**. The picture appears after about 10 s, the time needed to build the first HLS chunks.

### If it doesn't work

| Symptom | Likely cause |
|---|---|
| WireGuard app shows no "latest handshake" | The frontend's IP changed (nightly restart): turn the tunnel off and on. Or the network blocks UDP: try 4G. |
| Handshake OK, Larix says "connection failed" | The URL must use `10.99.0.1:1935`, not the domain name |
| Larix connects, then is cut at once | Wrong key, or the stream name isn't `phone` (`result=403` in the **MSS - Security** dashboard) |
| "The phone camera is not streaming right now" | Larix isn't recording, or the first chunks aren't ready yet: wait 10 s |
| Always buffering, delay keeps growing | The phone's upload is too slow: lower the bitrate and resolution, turn on adaptive bitrate |

Details: [PHONE-CAMERA.md](PHONE-CAMERA.md).

---

## Which phone channel to use?

| | Phone · real time | Phone · WireGuard |
|---|---|---|
| Delay | **< 1 s** | ~12–15 s |
| Phone app | MSS Camera (Android) | Larix + WireGuard (Android or iOS) |
| Protected by | Password + WebRTC encryption | WireGuard key + stream key |
| Opens on the frontend | UDP 8189 | UDP 51820 |
| Watch outside the website | No | Yes: `/hls/phone.m3u8`, `/dash/phone.mpd` |
| Turn off | `enable_webrtc = false` | `enable_phone_camera = false` |

Both switches are in `terraform/terraform.tfvars`; run `terraform apply` after changing one.

## Keys and passwords at a glance

| Need | Command (in `terraform/`) |
|---|---|
| Grafana password | `terraform output -raw grafana_admin_password` |
| Real-time phone password | `terraform output -raw webrtc_password` |
| Phone RTMP key | `terraform output -raw phone_stream_key` |
| Phone WireGuard QR code | file `ansible/phone/mss-phone.png` |

To **revoke a lost phone**:
- Real time: `terraform apply -replace=random_password.webrtc_publish`
- WireGuard: delete `ansible/phone/private.key`, then `terraform apply -replace=random_password.phone_stream_key`. A new QR code is made.

More: [KEYS-AND-SECRETS.md](KEYS-AND-SECRETS.md).
