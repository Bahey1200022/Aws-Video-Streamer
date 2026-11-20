# Real-time phone camera (WebRTC)

A phone streams **live video to the website with less than a second of delay**. The page gets a second channel, **Phone · real time**, next to the video loop.

The video loop keeps using HLS, which runs a few seconds behind but scales to any number of viewers. The phone channel uses **WebRTC**, the technology behind video calls.

## WebRTC in 5 ideas

1. **Built into every browser and phone.** No plugin. Video arrives **frame by frame over UDP**: no files, no chunks, so there's nothing to wait for.
2. **It starts with a handshake over HTTPS.** Each side describes what it can send or receive in a small text called **SDP** ("H.264 or VP8 video, Opus audio, here are my addresses").
   - **WHIP** = the handshake to **publish** (the phone).
   - **WHEP** = the handshake to **watch** (the browser).
3. **Then the media goes straight to the address the server announced** (this step is called **ICE**). On AWS, the server must announce its **public IP**; its own network card only knows the private one.
4. **It is always encrypted** (DTLS-SRTP, keys agreed during the handshake), so no WireGuard is needed.
5. **Audio must be Opus.** Browsers don't accept AAC over WebRTC. Phone apps that publish with WHIP send Opus.

## Why a server in the middle (MediaMTX)

WebRTC can connect two devices directly, as in a 1-to-1 call. For a live stream that breaks: the phone would upload **one copy per viewer**, and viewers can't reach a phone hidden behind a mobile network. So the phone sends **one** stream to a media server, which copies it to every viewer. Zoom and Meet do the same with more than 2 people.

nginx-rtmp can't speak WebRTC, so we add **MediaMTX**: one free program, one config file, with WHIP and WHEP built in.

## The picture

```
                        ① WHIP handshake (HTTPS 443, password)
 PHONE (Larix) ─────────────────► nginx ──► MediaMTX (127.0.0.1:8889)
      │                                         ▲          │
      └──── ② video + audio, UDP 8189 🔒 ───────┘          │
                                                           │ copies the stream
                        ③ WHEP handshake (HTTPS 443)       ▼
 BROWSER ───────────────────────► nginx ──► MediaMTX ─── ④ UDP 8189 🔒 ──► BROWSER
 ("Phone · real time")
```

| Step | Protocol | Port | Who can do it |
|---|---|---|---|
| ① Phone asks to publish | WHIP over HTTPS | TCP 443 (nginx) | Only with the password (user `phone`) |
| ② Phone sends media | SRTP over UDP, encrypted | UDP 8189 | Only after ① succeeded |
| ③ Browser asks to watch | WHEP over HTTPS | TCP 443 (nginx) | Anyone (it's the public website) |
| ④ Browser receives media | SRTP over UDP, encrypted | UDP 8189 | Only after ③ succeeded |

## The phone app: MSS Camera (our own)

### Why not Larix

Larix Broadcaster was tried first. Its handshake reached MediaMTX and the password was accepted (`POST /phone/whip` → **201**), but the video never started: `closed: deadline exceeded while waiting connection`, on 4G and on Wi-Fi alike. A packet capture on the frontend showed **zero packets** on UDP 8189 in either direction, and MediaMTX's debug log showed why. Larix's offer says:

```
a=ice-lite        ← "I only answer connectivity checks, I never send any"
(no a=candidate)  ← "...and here is no address to check"
```

MediaMTX is a full ICE agent with no ICE-lite option: it announces its address and waits for checks, or for an address to check. Neither side starts, so nothing flows. Our test client and browsers are full ICE agents (they send the checks themselves), which is why they work.

### MSS Camera

So we wrote a small Android app, `~/phone-app` (kept outside this repository, on the control machine), in **Flutter** with the `flutter_webrtc` package (Google's libwebrtc, the same WebRTC engine as Chrome, full ICE). Its code is one file, `~/phone-app/lib/main.dart`: the 5 WHIP steps, a camera preview, a front/back camera button and **Go live / Stop**.

| | |
|---|---|
| Flutter | 3.47.9 (stable), Dart 3.13.7 |
| Packages | `flutter_webrtc` 1.6.3, `http` 1.6.0, `flutter_secure_storage` 11.2.0 (versions out for at least 2 weeks) |
| Password | Typed once, kept in Android's **encrypted storage** (Keystore), never in the code |
| Address | `https://` only (the password travels in the request) |
| Credentials sent as | `Authorization: Bearer phone:<password>` (accepted by MediaMTX) |
| Ending a session | `DELETE` on the session address MediaMTX returned, so it closes at once |

**Install it on the phone (once):**
1. Phone: Settings → About phone → Software information → tap **Build number** 7 times → Developer options → **USB debugging** on. Plug it in and accept the prompt.
2. Laptop: `cd ~/phone-app && flutter run` (or `flutter build apk` and copy the `.apk`).
3. In the app: password = `terraform output -raw webrtc_password` (show it as a QR code on the laptop rather than sending it by message: `terraform output -raw webrtc_password | qrencode -t ansiutf8`).
4. **Go live**, then on the website click **Phone · real time**.

> Don't send the password through a messaging app. The first attempt pasted it into WhatsApp, and the link preview put it in the access log, so the password was replaced.

## Security: what protects what

| # | Lock | Where | Stops |
|---|---|---|---|
| 1 | **Publish password**, user `phone`, only on the path `phone` | `authInternalUsers` in [`mediamtx.yml.j2`](../ansible/templates/mediamtx.yml.j2) | Anyone else publishing (tested: wrong or missing password → **401**) |
| 2 | **Only the password's SHA-256 is on the server** | Terraform computes `base64sha256(password)`; Ansible only ever sees the hash | A stolen config or `inventory.yml` doesn't reveal the password |
| 3 | **Handshakes only through nginx (HTTPS)**; MediaMTX listens on `127.0.0.1:8889` | `webrtcAddress`, and the `location ~ ^/phone/(whip\|whep)` block in [`streamer.site.j2`](../ansible/templates/streamer.site.j2) | Plain-HTTP handshakes, and MediaMTX's own web pages (tested: `/phone/` → 404) |
| 4 | **Media encrypted** (DTLS-SRTP) | Built into WebRTC | Anyone reading or changing the video on the network |
| 5 | **Everything else turned off**: RTSP, RTMP, HLS, SRT, MoQ, API, playback | [`mediamtx.yml.j2`](../ansible/templates/mediamtx.yml.j2) | Extra open ports. MediaMTX's RTMP would also have taken nginx's port 1935 |
| 6 | **Only the public IP announced** (`webrtcIPsFromInterfaces: false`) | [`mediamtx.yml.j2`](../ansible/templates/mediamtx.yml.j2) | Leaking the private VPC address to every viewer (tested: the answer only lists `<public IP> 8189`) |
| 7 | **Sandboxed service**: throwaway user, nothing writable, 300 MB memory cap | `mediamtx.service` in [`site.yml`](../ansible/site.yml), play 10 | A bug in MediaMTX turning into a server takeover (`systemd-analyze security`: **1.3**, lower is better) |
| 8 | **Metrics on the private IP**, readable only by the monitoring server | `metricsAddress`, and a user limited to `monitoring_private_ip` | The public reading MediaMTX's statistics |

**What's open to the internet:** TCP 443 (already open for the website) and **UDP 8189**. UDP 8189 only carries encrypted media, and only after a successful handshake.

## What changed in the code

| File | Change |
|---|---|
| [`terraform/variables.tf`](../terraform/variables.tf) | `enable_webrtc` (default `true`) |
| [`terraform/security.tf`](../terraform/security.tf) | Frontend: UDP 8189 from anywhere; TCP 9998 from the monitoring server |
| [`terraform/monitoring.tf`](../terraform/monitoring.tf) | Monitoring server may reach 9998 on the frontend |
| [`terraform/stream_key.tf`](../terraform/stream_key.tf) | `random_password.webrtc_publish` |
| [`terraform/ansible.tf`](../terraform/ansible.tf) | Passes `webrtc_password_hash` (the hash, not the password) |
| [`terraform/outputs.tf`](../terraform/outputs.tf) | `webrtc_whip_url`, `webrtc_password` (sensitive) |
| [`ansible/group_vars/all.yml`](../ansible/group_vars/all.yml) | MediaMTX version 1.21.3, download URL, pinned SHA-256 |
| [`ansible/templates/mediamtx.yml.j2`](../ansible/templates/mediamtx.yml.j2) | **New:** MediaMTX settings |
| [`ansible/site.yml`](../ansible/site.yml), play 10 | **New play:** download (checksum checked), unpack, settings, sandboxed service |
| [`ansible/templates/streamer.site.j2`](../ansible/templates/streamer.site.j2) | nginx forwards `/phone/whip` and `/phone/whep` to MediaMTX |
| [`ansible/templates/index.html.j2`](../ansible/templates/index.html.j2) | Channel buttons; a WHEP player (the browser's own `RTCPeerConnection`, no library) |
| [`ansible/templates/prometheus.yml.j2`](../ansible/templates/prometheus.yml.j2) | Scrape job `mediamtx` |
| [`ansible/dashboards/stream.json`](../ansible/dashboards/stream.json) | Row "Phone camera · real time": LIVE/OFF, viewers, lost packets, bitrate |
| [`ansible/dashboards/security.json`](../ansible/dashboards/security.json) | Refused WebRTC logins; MediaMTX's log (every session with its IP) |

### The player on the page, in 5 steps

1. `new RTCPeerConnection()`, and ask to **receive** one video and one audio track.
2. `createOffer()`: the browser writes its SDP.
3. `fetch('/phone/whep', { method: 'POST', body: sdp })`: send it to MediaMTX through nginx.
4. `setRemoteDescription(answer)`: MediaMTX's SDP comes back, with its public IP and port 8189.
5. The browser connects over UDP and the video plays in the `<video>` element. A `404` means "nobody is publishing", and the page retries every 4 s.

## Tested

| Test | Result |
|---|---|
| Publish with a wrong password, over the internet | **401**, and logged: `failed to authenticate` |
| Publish with the right password (test client), over the internet | **201**, `is publishing to path 'phone'` |
| Watch over the internet (test client) | **201**, 107 video + 224 audio frames in 5 s |
| What the server announces | Only `34.232.64.150 8189` (public IP), no private address |
| MediaMTX's own pages through nginx | 404 |
| Ports MediaMTX opens | UDP 8189, TCP 127.0.0.1:8889, TCP 192.168.0.148:9998, and nothing on 1935 |
| Prometheus `up{job="mediamtx"}` | 1 |
| Loki: refused logins | Counted |
| Larix (ICE-lite WHIP client) | ❌ handshake 201, then no packets: incompatible with MediaMTX (see above) |
| Real phone, delay (MSS Camera) | *To measure: film a stopwatch shown on the laptop, and read both clocks in one photo* |

The test client is [aiortc](https://github.com/aiortc/aiortc), a Python WebRTC library, playing the phone and a viewer.

## Limits

| Limit | Why | What happens |
|---|---|---|
| A network that blocks UDP | Some company or hotel Wi-Fi does | No real-time picture; the video loop still works |
| Viewers behind very strict firewalls | They would need a **TURN** relay server (not built) | Same |
| Each viewer is a live connection to MediaMTX | That's how WebRTC works | Fine for a class; for thousands, HLS and a CDN |
| The public IP changes when the frontend is stopped and started | MediaMTX announces the IP written at deployment | Run `terraform apply` (or the playbook) after a restart |
| No HLS copy of the phone | Chosen to keep it simple | Phone = real time only |

## Turning it off

Set `enable_webrtc = false` in `terraform/terraform.tfvars` and apply. UDP 8189 closes, MediaMTX stops, and the page only shows the video loop.

To **change the password**: `terraform apply -replace=random_password.webrtc_publish`, then update Larix.

## If it doesn't work

| Symptom | Likely cause |
|---|---|
| App: "Wrong password" | Copy it again from `terraform output -raw webrtc_password` |
| App: "Connection lost" right after "Connecting" | UDP 8189 is blocked on the phone's network: try another network |
| Larix: "connection timed out" | Expected: Larix's ICE-lite client can't connect to MediaMTX. Use MSS Camera |
| Page stuck on "Connecting" | Your network blocks UDP 8189: try another network |
| Worked yesterday, not today | The frontend's public IP changed: run `terraform apply` |
| Security dashboard: many refused logins | Someone is guessing the password. It's 32 random characters, but check the IPs in the MediaMTX log |
