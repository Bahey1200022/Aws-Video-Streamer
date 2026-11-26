# Phone camera

A phone can stream **live video** to the website, next to the video loop. The page then has two channels, **Video loop** and **Phone camera**.

The phone connects to the frontend **the same way the streamer does**: through an encrypted **WireGuard** tunnel, then RTMP with its own stream key.

## The picture

```
 PHONE (4G or Wi-Fi, anywhere)                    WEB FRONTEND
┌─────────────────────────────┐                ┌──────────────────────────────┐
│ Larix Broadcaster (camera)  │                │ nginx-rtmp (port 1935)       │
│  rtmp://10.99.0.1:1935/     │                │  checks: address 10.99.0.3?  │
│       live/phone?key=...    │                │          key of "phone"?     │
│        │                    │                │        ▲                     │
│        ▼                    │   internet     │        │                     │
│ WireGuard app (10.99.0.3) ══╪════════════════╪══► WireGuard (10.99.0.1)     │
│  encrypts                   │ UDP 51820 🔒   │     decrypts; the phone may  │
└─────────────────────────────┘                │     only reach port 1935     │
                                               │        │                     │
                                               │        ▼                     │
                                               │  HLS/DASH: /hls/phone.m3u8   │──► viewers
                                               └──────────────────────────────┘
```

| | Video loop | Phone camera |
|---|---|---|
| Source | ffmpeg on the Video Streamer | Larix Broadcaster on the phone |
| Tunnel address | `10.99.0.2` | `10.99.0.3` |
| Reaches the frontend from | The private subnet | Anywhere on the internet |
| Channel (stream name) | `stream` | `phone` |
| Stream key | `terraform output -raw stream_key` | `terraform output -raw phone_stream_key` |
| On the website | `/hls/stream.m3u8` | `/hls/phone.m3u8` |

## Why WireGuard, and not RTMP straight to the frontend?

RTMP is **not encrypted**. Sent over 4G or Wi-Fi, the stream key would be readable by anyone on the way, and they could broadcast on your site.

| | RTMP straight to the frontend | **WireGuard (what we do)** | RTMPS (RTMP over TLS) |
|---|---|---|---|
| Key readable on the network? | ❌ Yes | ✅ No | ✅ No |
| Who can talk to nginx? | Anyone | **Only the phone** (needs its WireGuard key) | Anyone |
| What a scanner sees | An open RTMP port | **Nothing**: WireGuard never answers an unknown key | An open TLS port |
| Same design as the streamer? | | ✅ Yes | ❌ No |

## Setting up the phone (once)

You need two free apps: **WireGuard** and **Larix Broadcaster** (Android and iOS).

**1. Deploy.** `terraform apply` (or `ansible-playbook site.yml`) writes two files on the control machine, in `ansible/phone/` (git-ignored, owner-only):

| File | What it is |
|---|---|
| `mss-phone.png` | **QR code** of the phone's tunnel settings |
| `mss-phone.conf` | The same settings as text |
| `private.key` | The phone's WireGuard private key (also inside the two files above) |

**2. WireGuard app.** Tap **+** → **Scan from QR code** → scan `mss-phone.png` on your laptop screen. Name it `mss`. Turn it on.

**3. Larix Broadcaster.** Settings → Connections → **New connection**:

| Field | Value |
|---|---|
| Name | `mss` |
| URL | `rtmp://10.99.0.1:1935/live/phone?key=<phone key>` |

Get the phone key with `terraform output -raw phone_stream_key` (in the `terraform` folder). Keep the default encoder (H.264 + AAC): browsers can play it.

**4. Stream.** With the WireGuard tunnel **on**, press the record button in Larix. On the website, click **Phone camera**. The picture appears after about 10 s, which is the time to build the first HLS chunks.

> ⚠️ The QR code and `mss-phone.conf` contain the phone's **private key**. Anyone who has them, plus the phone stream key, can broadcast. Don't post a screenshot of the QR code.

## The 4 locks

| # | Lock | Where | Stops |
|---|---|---|---|
| 1 | **WireGuard key**: only the phone's key is accepted for `10.99.0.3` | `wg0.conf` on the frontend | Anyone else on the internet. They get no answer at all. |
| 2 | **Port filter inside the tunnel**: from `10.99.0.3`, only TCP 1935 is accepted; SSH, the package proxy and the monitoring ports are dropped | `PostUp` iptables rules in [`wg0.conf.j2`](../ansible/templates/wg0.conf.j2) | A stolen phone being used to explore the frontend |
| 3 | **Publish address**: nginx accepts publishers only from `127.0.0.1`, `10.99.0.2` and `10.99.0.3` | `allow publish` in [`nginx.conf.j2`](../ansible/templates/nginx.conf.j2) | Anything that doesn't come through the tunnel |
| 4 | **Stream key**: the phone's own key, valid only for the channel `phone` | `map` in [`nginx.conf.j2`](../ansible/templates/nginx.conf.j2) | Someone inside the tunnel without the key |

Lock 2 exists because the security group can't see **inside** the tunnel (see [SECURITY-FIXES.md](SECURITY-FIXES.md)). The streamer is our own server; the phone is a device that can be lost, so it gets less access.

**Separate keys** for the streamer and the phone mean you can revoke the phone without touching the video loop, and the logs say which camera published (`name=phone` in `publish-auth.log`, visible in the **MSS - Security** dashboard).

## What changed in the code

| File | Change |
|---|---|
| [`terraform/variables.tf`](../terraform/variables.tf) | `enable_phone_camera` (default `true`) |
| [`terraform/security.tf`](../terraform/security.tf) | Frontend: UDP 51820 open to the internet when the phone is enabled |
| [`terraform/stream_key.tf`](../terraform/stream_key.tf) | `random_password.phone_stream_key` |
| [`terraform/outputs.tf`](../terraform/outputs.tf) | `phone_stream_key` (sensitive) |
| [`ansible/site.yml`](../ansible/site.yml), play 4 | Phone key pair made **on the control machine**; phone added as a WireGuard peer; config and QR code written |
| [`ansible/templates/phone-wg.conf.j2`](../ansible/templates/phone-wg.conf.j2) | The phone's tunnel settings (everything but its private key) |
| [`ansible/templates/wg0.conf.j2`](../ansible/templates/wg0.conf.j2) | Port filter for peers with `only_tcp_port` |
| [`ansible/templates/nginx.conf.j2`](../ansible/templates/nginx.conf.j2) | Publish address `10.99.0.3` and the `phone` key |
| [`ansible/templates/index.html.j2`](../ansible/templates/index.html.j2) | Channel selector: Video loop / Phone camera |
| [`ansible/templates/mss-stream-metrics.py.j2`](../ansible/templates/mss-stream-metrics.py.j2) | Every stream metric gets a `channel` label (`stream` or `phone`) |
| [`ansible/dashboards/stream.json`](../ansible/dashboards/stream.json) | Publishers panel shows both channels (phone OFF is blue, not red); bitrate and chunk age per channel |

### Why the phone's key is made on the laptop

The servers' WireGuard keys are made **on each server** and never leave it. The phone's key has to end up **on the phone**, so it's made on the control machine, next to the QR code. It is read by the shell when the config is assembled, so it never becomes an Ansible variable and can't appear in Ansible's or Terraform's output.

## Turning it off

Set `enable_phone_camera = false` in `terraform/terraform.tfvars` and apply. UDP 51820 is closed to the internet again, the phone peer and its key are removed from nginx, and the page shows only the video loop.

To **revoke** a lost phone but keep the feature: delete `ansible/phone/private.key` (a new key and QR code are made on the next deployment) and replace the phone stream key with `terraform apply -replace=random_password.phone_stream_key`.

## Delay and buffering

Measured on the first test (4G, Larix at 720p): the loop made a 2 s chunk every 2 s, while the phone's chunks were 3, 3, **7**, 3, 3, **9** s long and arrived in bursts, with 4 reconnections in 7 minutes. The phone's **upload** couldn't carry about 2.5 Mbit/s, so the player kept running dry.

| Setting | Where | Why |
|---|---|---|
| 2 s HLS chunks | `hls_fragment 2` in nginx | Lower delay (was 3 s) |
| Keyframe every 2 s (loop) / 1 s (phone) | ffmpeg `-force_key_frames`; Larix → Video → Keyframe frequency | nginx can only cut a chunk at a keyframe |
| Loop: player 2 chunks (≈4 s) behind live | hls.js `liveSyncDurationCount: 2` | Steady source: a small cushion is enough |
| Phone: player **10 s** behind live | hls.js `liveSyncDuration: 10` (`buffer: 10` in `site.yml`) | A phone's upload comes in bursts: a bigger cushion stops the buffering |
| `drop_idle_publisher 10s` | nginx | A phone that vanishes is released after 10 s, so its reconnection isn't refused (`already publishing`) |

**Recommended Larix settings:** 854×480, 800 kbit/s, 30 fps, keyframe 1 s, **adaptive bitrate** on (Connections → `mss`). The upload should be at least twice the bitrate.

Expected delay: about **5–7 s** on the loop, about **12–15 s** on the phone. Lower than that needs LL-HLS or WebRTC, which nginx-rtmp doesn't support.

## If it doesn't work

| Symptom | Likely cause |
|---|---|
| WireGuard app: no "latest handshake" | The network blocks UDP (some Wi-Fi, some carriers): try 4G or another Wi-Fi. Or the frontend's IP changed since the tunnel was turned on: turn it off and on again. |
| Handshake OK, Larix "connection failed" | Wrong URL: it must be `10.99.0.1:1935`, not the domain name |
| Larix connects, then is cut immediately | Wrong key, or stream name not `phone`. `publish-auth.log` shows `result=403`. |
| Page says "The phone camera is not streaming right now" | Larix isn't recording, or the first chunks aren't written yet (wait 10 s) |
| Always buffering, delay keeps growing | The phone's upload is too slow: lower Larix's bitrate and resolution, turn on adaptive bitrate (see above) |
| Picture plays but sideways | Larix's orientation setting; it's sent as recorded |
