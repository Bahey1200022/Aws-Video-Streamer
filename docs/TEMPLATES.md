# The Ansible templates, file by file

This guide explains the 6 files in [`ansible/templates/`](../ansible/templates/): the configuration files Ansible writes onto the servers. For the playbook that uses them, see [PLAYBOOK.md](PLAYBOOK.md). For the whole project, see [HOW-IT-WORKS.md](HOW-IT-WORKS.md).

## Contents

- [What a template is](#what-a-template-is)
- [The 6 templates at a glance](#the-6-templates-at-a-glance)
- [How they fit together](#how-they-fit-together)
- [nginx.conf.j2: the video receiver](#nginxconfj2-the-video-receiver)
- [streamer.site.j2: the HTTPS website](#streamersitej2-the-https-website)
- [index.html.j2: the player page](#indexhtmlj2-the-player-page)
- [wg0.conf.j2: the WireGuard tunnel](#wg0confj2-the-wireguard-tunnel)
- [ffmpeg-stream.service.j2: the streaming service](#ffmpeg-streamservicej2-the-streaming-service)
- [ffmpeg-stream.env.j2: the stream key file](#ffmpeg-streamenvj2-the-stream-key-file)
- [Security measures in the templates](#security-measures-in-the-templates)
- [Likely questions](#likely-questions)

---

## What a template is

A template is a **configuration file with blanks**. Ansible fills in the blanks and copies the finished file onto a server.

- The files end in **`.j2`**, for **Jinja2**, the template language Ansible uses.
- `{{ name }}` is a **blank**, replaced by the value of a variable.
- `{% if ... %}` / `{% for ... %}` add **simple logic**: include a block only in some cases, or repeat it for each item in a list.
- `{{ ansible_managed }}` at the top becomes a comment saying the file is managed by Ansible, so nobody edits it by hand.

**Example.** One line of [`wg0.conf.j2`](../ansible/templates/wg0.conf.j2):

```ini
Address = {{ wg_address }}/32
```

becomes `Address = 10.99.0.1/32` on the frontend and `Address = 10.99.0.2/32` on the streamer.

**Why templates are needed:** the real values (IPs, the domain name, the stream key, the WireGuard public keys) only exist **after Terraform has run**. The config files can't be written in advance; they are filled in at deploy time.

### Where the values come from

| Source | Examples | Set by |
|---|---|---|
| The inventory (`ansible/inventory.yml`) | `fqdn`, `stream_key`, `frontend_private_ip`, `letsencrypt_staging` | Terraform writes it |
| [`group_vars/all.yml`](../ansible/group_vars/all.yml) | `wg_port`, `wg_frontend_ip`, `wg_streamer_ip`, `video_file`, `video_dir`, `cert_name` | Fixed project settings |
| The task's `vars:` in [`site.yml`](../ansible/site.yml) | `wg_address`, `wg_listen`, `wg_peers`, `tls_active`, `page_channel`, `page_title` | That one task |

### How `site.yml` uses a template

```yaml
- name: Configure nginx (main config with RTMP ingest)
  ansible.builtin.template:
    src: nginx.conf.j2           # the template, looked up in ansible/templates/
    dest: /etc/nginx/nginx.conf  # where the filled-in file goes on the server
    mode: "0600"                 # file permissions
  notify: Reload nginx           # if the file changed, restart nginx at the end
```

Ansible only rewrites the file (and only triggers the restart) if the filled-in content **differs** from what's already on the server.

---

## The 6 templates at a glance

| Template | Written to | Server | Used in `site.yml` | Permissions | What it configures |
|---|---|---|---|---|---|
| [`nginx.conf.j2`](../ansible/templates/nginx.conf.j2) | `/etc/nginx/nginx.conf` | Frontend | [line 198](../ansible/site.yml#L198) | `0600` (contains the stream key) | The **RTMP receiver**: accepts the stream, checks the key, cuts it into HLS/DASH chunks |
| [`streamer.site.j2`](../ansible/templates/streamer.site.j2) | `/etc/nginx/sites-available/streamer` | Frontend | [line 209](../ansible/site.yml#L209) | `0644` | The **website**: HTTPS, the redirect, serving the chunks |
| [`index.html.j2`](../ansible/templates/index.html.j2) | `/var/www/html/index.html` | Frontend | [line 235](../ansible/site.yml#L235) | `0644` | The **player page** viewers open |
| [`wg0.conf.j2`](../ansible/templates/wg0.conf.j2) | `/etc/wireguard/wg0.conf` | **Both** | [lines 108](../ansible/site.yml#L108) and [419](../ansible/site.yml#L419) | `0600` | The **encrypted tunnel** between the two servers |
| [`ffmpeg-stream.service.j2`](../ansible/templates/ffmpeg-stream.service.j2) | `/etc/systemd/system/ffmpeg-stream.service` | Streamer | [line 453](../ansible/site.yml#L453) | `0644` | The **streaming program**: ffmpeg looping the video forever |
| [`ffmpeg-stream.env.j2`](../ansible/templates/ffmpeg-stream.env.j2) | `/etc/ffmpeg-stream.env` | Streamer | [line 444](../ansible/site.yml#L444) | `0600` | The **stream key**, in a root-only file |

---

## How they fit together

The video's path, and the template responsible for each step:

```
VIDEO STREAMER (private subnet, 192.168.1.210)
  ffmpeg-stream.env       STREAM_KEY=...  (root-only)
  ffmpeg-stream.service   ffmpeg loops /videos/<file>, re-encodes it, and pushes
                          rtmp://10.99.0.1:1935/live/stream?key=$STREAM_KEY
        │
        │  wg0.conf (both sides): encrypted WireGuard tunnel, UDP 51820
        │  10.99.0.2  ═══════════════════════════════▶  10.99.0.1
        ▼
WEB FRONTEND (public subnet, 192.168.0.148)
  nginx.conf      RTMP on port 1935:
                    1. only 127.0.0.1 or 10.99.0.2 may publish
                    2. asks 127.0.0.1:8081/auth/publish: is the key right?
                    3. writes chunks to /var/www/html/stream/hls and /dash
        │
  streamer.site   HTTPS on 443 (HTTP 80 → redirect)
                    /          → index.html
                    /hls/...   → the HLS playlist and chunks
                    /dash/...  → the DASH manifest and chunks
        │
  index.html      the player in the viewer's browser (hls.js / dash.js)
        ▼
VIEWER  https://bahey.devops.gin-telecom.ovh/
```

---

## nginx.conf.j2: the video receiver

**Becomes:** `/etc/nginx/nginx.conf` on the frontend, mode `0600` (root-only, because it contains the stream key).
**The most important template:** it turns nginx into a live-video server.

The file has 3 parts: general settings, an `http` block, and an `rtmp` block.

### General settings (lines 1-10)

```nginx
user www-data;                                  # nginx's worker processes run as an unprivileged user
worker_processes  1;
include /etc/nginx/modules-enabled/*.conf;      # loads the RTMP module (from libnginx-mod-rtmp)
events { worker_connections 1024; }
```

The `include` line matters: without it, nginx wouldn't understand the `rtmp { }` block at all.

### The `http` block (lines 12-61)

**Standard web settings, and the website** (lines 13-22):

```nginx
sendfile on; tcp_nopush on; tcp_nodelay on;     # efficient file sending
include /etc/nginx/mime.types;                  # file extension → content type
include /etc/nginx/sites-enabled/*;             # ← loads the website (streamer.site.j2)
```

**The stream-key check** (lines 24-51). It works in 3 pieces.

**1. A lookup table** (`map`):

```nginx
map "$arg_name:$arg_key" $publish_allowed {
    default                     0;
    "stream:{{ stream_key }}"   1;
}
```

It joins the stream name and the key from the request into `"name:key"`. Only the exact pair `stream:<the real key>` gives `1` (allowed); anything else gives `0`.

**2. A small private check server**, only on `127.0.0.1:8081`, so it is unreachable from outside the machine:

```nginx
server {
    listen 127.0.0.1:8081;
    location = /auth/publish {
        if ($publish_allowed) { return 200; }   # 200 = OK, accept the stream
        return 403;                             # 403 = refused
    }
    location / { return 404; }                  # nothing else exists here
}
```

**3. A log without secrets:**

```nginx
log_format publish_auth '$time_iso8601 addr=$arg_addr app=$arg_app name=$arg_name result=$status';
```

It records **who** tried to publish and the **verdict** (200 or 403), but **never the key**. A failed attempt shows up in `/var/log/nginx/publish-auth.log` as `result=403`.

**The RTMP control server** (lines 53-60):

```nginx
server {
    listen 8080;
    location /control { rtmp_control all; }
}
```

nginx-rtmp's control interface, used to list or drop publishers. **Note:** `listen 8080` listens on every interface. The security groups don't allow port 8080 in from the internet or the VPC. But traffic arriving **inside the WireGuard tunnel** (from `10.99.0.2`) isn't filtered by the security group, so the streamer could reach it. Binding it to `127.0.0.1:8080` would close that gap.

### The `rtmp` block (lines 63-100)

**The log** (lines 64-68):

```nginx
log_format rtmp_nokey '$remote_addr [$time_local] $command "$app" "$name" ...';
access_log /var/log/nginx/rtmp-access.log rtmp_nokey;
```

nginx-rtmp's **default** log records the full connection arguments, **including `?key=...`**. This custom format logs everything **except** those arguments, so the stream key never lands in a log file.

**The RTMP server** (lines 70-99):

```nginx
server {
    listen 1935;                       # standard RTMP port
    application live {                 # the "live" in rtmp://.../live/stream
        live on;                       # live streaming (not on-demand files)
        record off;                    # don't save the stream to disk
```

**Security layer 1, the network** (lines 78-82): who may **send** a stream.

```nginx
allow publish 127.0.0.1;               # the frontend itself (for tests)
allow publish {{ wg_streamer_ip }};    # 10.99.0.2: the streamer, through the tunnel
deny publish all;                      # everyone else is refused
```

Because the streamer's only allowed address is its **tunnel** address, a stream that didn't come through the encrypted tunnel is refused.

**Security layer 2, identity** (lines 84-88): the stream key.

```nginx
notify_method get;
on_publish http://127.0.0.1:8081/auth/publish;
```

Before accepting a stream, nginx-rtmp asks the check server:

```
GET http://127.0.0.1:8081/auth/publish?app=live&name=stream&key=<what ffmpeg sent>&addr=10.99.0.2
  → 200: the stream is accepted
  → 403: the connection is dropped
```

`notify_method get` puts the RTMP arguments in the URL, so the `map` can read them as `$arg_name` and `$arg_key`.

**The output: HLS and DASH** (lines 90-97):

```nginx
hls on;
hls_path /var/www/html/stream/hls;     # where HLS files are written
hls_fragment 3;                        # 3-second chunks (low delay)
hls_playlist_length 60;                # the playlist covers the last 60 seconds

dash on;
dash_path /var/www/html/stream/dash;   # where DASH files are written
dash_fragment 15s;                     # 15-second chunks
```

| | HLS | DASH |
|---|---|---|
| Made by | Apple | MPEG (an open standard) |
| Playlist file | `stream.m3u8` | `stream.mpd` |
| Chunks here | 3 s `.ts` files | 15 s `.m4v` / `.m4a` files |
| Plays in | Safari natively; elsewhere with hls.js | Browsers with dash.js |

nginx **writes new chunks continuously** and deletes old ones, so the folders always hold only the last minute or so of video.

---

## streamer.site.j2: the HTTPS website

**Becomes:** `/etc/nginx/sites-available/streamer` (enabled by a symlink in `sites-enabled/`). It's loaded by the `include` in `nginx.conf`.

The template has **2 versions** in one file, chosen by `tls_active` (*"does the certificate exist yet?"*):

```
{% if tls_active %}   → server on 80 (redirect + challenges) + server on 443 (HTTPS)
{% else %}            → a single server on 80 (plain HTTP, used before the first certificate)
```

This avoids a chicken-and-egg problem: nginx can't start with HTTPS settings that point to a certificate that doesn't exist yet, and the certificate can't be issued without nginx running on port 80.

### The port 80 server (lines 3-17, HTTPS mode only)

```nginx
server {
    listen 80;
    server_name {{ fqdn }};

    location ^~ /.well-known/acme-challenge/ {    # Let's Encrypt's checks stay on HTTP
        root /var/www/html;
        default_type text/plain;
    }

    location / {
        return 301 https://$host$request_uri;      # everything else → HTTPS
    }
}
```

- **Challenges stay on HTTP:** Let's Encrypt's HTTP-01 check (for the first issue and every renewal) always arrives over plain HTTP on port 80.
- **`301`** is a permanent redirect. A visitor typing `http://...` is sent to the `https://` address.
- **`^~`** means "if the path starts with this, use this block and stop looking."

### The main server (lines 20-79)

**HTTPS settings** (lines 21-32):

```nginx
listen 443 ssl;
ssl_certificate     /etc/letsencrypt/live/{{ cert_name }}/fullchain.pem;   # the certificate
ssl_certificate_key /etc/letsencrypt/live/{{ cert_name }}/privkey.pem;     # its private key
ssl_protocols TLSv1.2 TLSv1.3;                                             # modern versions only
ssl_prefer_server_ciphers off;                                             # TLS 1.3 good practice
add_header Strict-Transport-Security "max-age=86400" always;               # HSTS
```

| Setting | Why |
|---|---|
| `fullchain.pem` / `privkey.pem` | The certificate and its private key from Let's Encrypt. The `cert_name` blank keeps staging and real certificates apart. |
| `TLSv1.2 TLSv1.3` only | Old versions (SSL 3, TLS 1.0/1.1) have known weaknesses and are refused |
| **HSTS** | Tells browsers: *"for the next 24 hours, only ever use HTTPS for this site,"* even if someone types `http://`. This blocks downgrade attacks. It's kept to one day so a failed certificate renewal can't lock visitors out for a year. It's only sent with a real certificate (not staging). |

**The player page** (lines 38-40):

```nginx
root /var/www/html;          # files are served from here
index index.html;            # "/" shows index.html
```

**Hiding the raw folders** (lines 42-46):

```nginx
location ^~ /stream/ { return 404; }
```

The chunks physically live in `/var/www/html/stream/...`, inside the web root. This makes sure they're only reachable through the `/hls` and `/dash` paths below, never by browsing the folders directly.

**The HLS chunks** (lines 48-51):

```nginx
location /hls {
    add_header Access-Control-Allow-Origin *;     # CORS: other sites' players may load it
    root /var/www/html/stream;                    # /hls/stream.m3u8 → /var/www/html/stream/hls/stream.m3u8
}
```

**The DASH chunks** (lines 55-78):

```nginx
location /dash {
    add_header 'Cache-Control' 'no-cache';                     # always fetch the latest manifest
    add_header 'Access-Control-Allow-Origin' '*' always;       # CORS
    if ($request_method = 'OPTIONS') { ... return 204; }       # answer CORS preflight checks
    types { application/dash+xml mpd; video/mp4 mp4; }         # correct content types
    root /var/www/html/stream;                                 # /dash/... → /var/www/html/stream/dash/...
}
```

- **CORS** (Cross-Origin Resource Sharing) lets a player on another website load this stream. Without it, browsers would block that.
- **`no-cache`**: a live manifest changes every few seconds, so it must never be served from a stale cache.

---

## index.html.j2: the player page

**Becomes:** `/var/www/html/index.html` on the frontend: the page at `https://<fqdn>/`.

Most of the file is ordinary HTML, CSS and JavaScript. Only a few blanks come from Ansible:

| Blank | Value | Shows up as |
|---|---|---|
| `{{ page_title }}` | `video_title`, "Elephants Dream" | The heading: *"Elephants Dream, live"* |
| `{{ fqdn }}` | `bahey.devops.gin-telecom.ovh` | Under the heading |
| `{{ page_channel }}` | `stream` | The stream URLs: `/hls/stream.m3u8`, `/dash/stream.mpd` |

The JavaScript is wrapped in `{% raw %} ... {% endraw %}`, which tells Jinja2 not to touch it. JavaScript uses `{` and `}` too, and Jinja2 would otherwise try to read them as template code.

### What the page does

- **A video player** with **HLS / DASH buttons** to switch between the two formats.
- **HLS:** plays with **hls.js** (Safari plays HLS natively).
- **DASH:** loads **dash.js** only when that button is clicked.
- **Status badge:** CONNECTING / LIVE / OFFLINE, and **retries automatically** if the stream isn't available yet.
- **"Go live" button:** jumps to the newest part of the stream.
- **Playback panel:** format, status, resolution, **latency** (delay behind live), buffer, dropped frames.
- **Pipeline panel:** a short summary of the path (ffmpeg → RTMP in WireGuard → nginx-rtmp → HLS/DASH → browser).

### Security: Subresource Integrity (SRI)

The two players are loaded from a public CDN (jsDelivr), with a **pinned version** and a **hash**:

```html
<script src="https://cdn.jsdelivr.net/npm/hls.js@1.5.13/dist/hls.min.js"
        integrity="sha384-w6Gb3fXH..." crossorigin="anonymous"></script>
```

The browser computes the downloaded file's hash and **refuses to run it if it doesn't match**. If the CDN were hacked and the file swapped for malicious code, viewers' browsers would simply not run it. dash.js gets the same protection when it's loaded.

---

## wg0.conf.j2: the WireGuard tunnel

**Becomes:** `/etc/wireguard/wg0.conf` on **both** servers, mode `0600`. Started by the `wg-quick@wg0` service.

The template is **used twice**, with different `vars:` from `site.yml`:

```ini
# {{ ansible_managed }}
[Interface]
Address = {{ wg_address }}/32
{% if wg_listen %}
ListenPort = {{ wg_port }}
{% endif %}
PostUp = wg set %i private-key /etc/wireguard/private.key
{% for peer in wg_peers %}

# {{ peer.name }}
[Peer]
PublicKey = {{ peer.public_key }}
AllowedIPs = {{ peer.ip }}/32
{% if peer.endpoint | default('') %}
Endpoint = {{ peer.endpoint }}
PersistentKeepalive = 25
{% endif %}
{% endfor %}
```

### Line by line

| Line | Meaning |
|---|---|
| `[Interface]` | Settings for **this** server |
| `Address = .../32` | This server's **tunnel address**: `10.99.0.1` (frontend) or `10.99.0.2` (streamer) |
| `ListenPort = 51820` | **Frontend only** (`wg_listen: true`): wait for connections on UDP 51820 |
| `PostUp = wg set %i private-key ...` | Once the tunnel is up, **load this server's private key from its own file**. The key is never written into this config, an Ansible variable, or the laptop. |
| `[Peer]` | The **other** server. The `{% for %}` loop writes one block per peer; there's one here. |
| `PublicKey` | The other server's **public key**, from play 3 through `hostvars` |
| `AllowedIPs = .../32` | The **only** address that peer may use inside the tunnel. Packets from it claiming any other address are dropped. |
| `Endpoint` | **Streamer only:** where to reach the frontend, `192.168.0.148:51820`. The streamer calls; the frontend answers. |
| `PersistentKeepalive = 25` | **Streamer only:** send a tiny packet every 25 s, so the security groups' connection tracking keeps the path open |

### The two files it produces

```ini
# FRONTEND                                   # STREAMER
[Interface]                                  [Interface]
Address = 10.99.0.1/32                       Address = 10.99.0.2/32
ListenPort = 51820                           PostUp = wg set %i private-key ...
PostUp = wg set %i private-key ...
                                             # Web Frontend
# Video Streamer                             [Peer]
[Peer]                                       PublicKey = <frontend's public key>
PublicKey = <streamer's public key>          AllowedIPs = 10.99.0.1/32
AllowedIPs = 10.99.0.2/32                    Endpoint = 192.168.0.148:51820
                                             PersistentKeepalive = 25
```

See [KEYS-AND-SECRETS.md](KEYS-AND-SECRETS.md) for the keys themselves.

---

## ffmpeg-stream.service.j2: the streaming service

**Becomes:** `/etc/systemd/system/ffmpeg-stream.service` on the streamer. It's a **systemd unit**: it tells Linux how to run ffmpeg as a permanent background service.

```ini
[Unit]
Description=Stream {{ video_file }} in a loop to the frontend RTMP server
After=network-online.target wg-quick@wg0.service
Wants=network-online.target wg-quick@wg0.service

[Service]
EnvironmentFile=/etc/ffmpeg-stream.env
ExecStart=/usr/bin/ffmpeg -nostdin -loglevel warning \
  -stream_loop -1 \
  -re \
  -i {{ video_dir }}/{{ video_file }} \
  -c:v libx264 -preset veryfast \
  -c:a aac \
  -f flv \
  rtmp://{{ wg_frontend_ip }}:1935/live/stream?key=${STREAM_KEY}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

### `[Unit]`: when to start

| Line | Meaning |
|---|---|
| `After=` / `Wants=` `network-online.target wg-quick@wg0.service` | Start **after** the network and the **WireGuard tunnel** are up. The stream is sent to the tunnel address, so the tunnel must exist first. |

### `[Service]`: what to run

| Line | Meaning |
|---|---|
| `EnvironmentFile=/etc/ffmpeg-stream.env` | Read `STREAM_KEY` from the root-only file. This unit file is readable by everyone, so the key isn't written in it. |
| `-nostdin -loglevel warning` | Don't wait for keyboard input; only log warnings and errors |
| `-stream_loop -1` | **Loop the video forever** (`-1` = infinite) |
| `-re` | Read the file at **real-time speed**. Without it, ffmpeg would send the whole film in seconds. |
| `-i /videos/<file>` | The input: the video Ansible uploaded |
| `-c:v libx264 -preset veryfast` | Re-encode the video as **H.264** (what HLS/DASH players expect). `veryfast` uses little CPU, which suits a small t3 instance. |
| `-c:a aac` | Encode the sound as **AAC** |
| `-f flv` | Package it as **FLV**, the format RTMP carries |
| `rtmp://10.99.0.1:1935/live/stream?key=${STREAM_KEY}` | Send it to the frontend's **tunnel address** (so it travels encrypted), to the `live` application, as the stream named `stream`, with the key. systemd fills in `${STREAM_KEY}` from the env file. |
| `Restart=always`, `RestartSec=5` | If ffmpeg stops for any reason (a network blip, the frontend restarting), **start it again after 5 seconds** |

### `[Install]`: start at boot

`WantedBy=multi-user.target` means the stream starts automatically every time the server boots, for example after the lab's nightly shutdown.

### Useful commands on the streamer

```bash
systemctl status ffmpeg-stream          # is it running?
journalctl -u ffmpeg-stream -f          # its live log
```

---

## ffmpeg-stream.env.j2: the stream key file

**Becomes:** `/etc/ffmpeg-stream.env` on the streamer, owner root, mode `0600`.

```ini
# {{ ansible_managed }}
STREAM_KEY={{ stream_key }}
```

`{{ stream_key }}` is the 32-character random password Terraform generates (`random_password` in [`stream_key.tf`](../terraform/stream_key.tf)), passed through the inventory.

**Why a separate file?**
- **The unit file must stay readable by everyone** (systemd and tools read it). The key goes in a separate **root-only** file, loaded with `EnvironmentFile=`.
- **The key isn't typed on a command line by an admin**, where it could end up in shell history or logs.

The same key is also in `nginx.conf` (mode `0600`) on the frontend, which compares the two.

---

## Security measures in the templates

| Measure | Template |
|---|---|
| Only `127.0.0.1` and the tunnel address `10.99.0.2` may publish a stream | `nginx.conf.j2` |
| Every stream must present the correct key, checked by a localhost-only endpoint | `nginx.conf.j2` |
| The stream key is never written to a log (custom RTMP and auth log formats) | `nginx.conf.j2` |
| Files holding secrets are root-only (`0600`) | `nginx.conf.j2`, `wg0.conf.j2`, `ffmpeg-stream.env.j2` |
| HTTPS only: HTTP → HTTPS redirect, TLS 1.2/1.3, HSTS | `streamer.site.j2` |
| Raw chunk folders are never served directly | `streamer.site.j2` |
| Third-party scripts are pinned and checked with SRI hashes | `index.html.j2` |
| The stream travels inside an encrypted, authenticated tunnel | `wg0.conf.j2`, `ffmpeg-stream.service.j2` |
| WireGuard private keys are loaded from disk and never appear in a config file or variable | `wg0.conf.j2` |
| Each tunnel peer may only use its one address (`AllowedIPs /32`) | `wg0.conf.j2` |

---

## Likely questions

**What is a template, and why use one?**
A config file with blanks (`{{ }}`) that Ansible fills in. The values (IPs, keys, the domain) only exist after Terraform runs, so the files are generated at deploy time.

**How does nginx know the stream key is right?**
Before accepting a stream, nginx-rtmp asks a small server on `127.0.0.1:8081`. A `map` compares the name and key sent by ffmpeg with `stream:<key>` and answers 200 (accept) or 403 (refuse).

**What stops someone else from publishing a stream?**
Two layers. The network: only `127.0.0.1` and the tunnel address `10.99.0.2` may publish, and that address is only reachable through WireGuard. And identity: the stream key.

**What's the difference between HLS and DASH?**
Both cut the video into small files plus a playlist that the player keeps re-reading. HLS is Apple's format (`.m3u8`, 3 s chunks here); DASH is the open MPEG standard (`.mpd`, 15 s chunks here).

**Why does ffmpeg use `-re` and `-stream_loop -1`?**
`-re` sends the video at real speed, like a live camera. `-stream_loop -1` restarts it endlessly, so the stream never ends.

**What happens if ffmpeg crashes?**
systemd restarts it after 5 seconds (`Restart=always`). It also starts on every boot.

**What is SRI?**
Subresource Integrity: the page lists the expected hash of each external script, and the browser refuses to run a file that doesn't match.

**What is HSTS?**
A header telling browsers to use only HTTPS for the site for a set time (one day here). This prevents downgrade attacks to plain HTTP.
