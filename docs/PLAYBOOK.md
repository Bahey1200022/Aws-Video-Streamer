# The Ansible playbook, play by play

This guide explains [`ansible/site.yml`](../ansible/site.yml): the playbook that sets up both servers once Terraform has created them. For the rest of the project, see [HOW-IT-WORKS.md](HOW-IT-WORKS.md); for the configuration files it writes, see [TEMPLATES.md](TEMPLATES.md).

## Contents

- [How the playbook is started](#how-the-playbook-is-started)
- [Ansible vocabulary](#ansible-vocabulary)
- [Settings used by every play](#settings-used-by-every-play)
- [Overview: the 5 plays](#overview-the-5-plays)
- [Play 1: package proxy on the frontend](#play-1-package-proxy-on-the-frontend)
- [Play 2: point the streamer's apt at the proxy](#play-2-point-the-streamers-apt-at-the-proxy)
- [Play 3: WireGuard keys on both servers](#play-3-wireguard-keys-on-both-servers)
- [Play 4: the Web Frontend](#play-4-the-web-frontend)
- [Play 5: the Video Streamer](#play-5-the-video-streamer)
- [Why the playbook can be re-run safely](#why-the-playbook-can-be-re-run-safely)
- [Security measures in the playbook](#security-measures-in-the-playbook)
- [Likely questions](#likely-questions)

---

## How the playbook is started

The playbook is not run by hand. `terraform apply` starts it ([`terraform/ansible.tf`](../terraform/ansible.tf)) in two steps:

1. **Terraform writes the inventory.** It fills in the blanks of [`inventory.yml.tftpl`](../terraform/inventory.yml.tftpl) with values only it knows, and saves the result as `ansible/inventory.yml`. The values are the server IPs, the SSH key file, the domain name and the stream key.
2. **Terraform runs Ansible.** A `local-exec` provisioner runs `ansible-playbook site.yml` **on the laptop**. It runs only after the firewalls, the servers and the DNS record are ready (`depends_on`). It runs again only when a server is replaced or an Ansible file changes (`triggers_replace`).

Ansible then logs into the servers over SSH:

```
laptop ──SSH──▶ Web Frontend (public IP)                        plays 1, 3, 4
laptop ──SSH──▶ Web Frontend ──SSH──▶ Video Streamer (private)   plays 2, 3, 5
```

The streamer has no public IP, so the inventory gives it a `ProxyCommand`. SSH hops through the frontend, which acts as a **jump host**.

---

## Ansible vocabulary

| Term | Meaning | Example in the playbook |
|---|---|---|
| **Playbook** | The file of setup instructions | `site.yml` |
| **Play** | "On **these servers**, do **these tasks**" | `hosts: frontend` |
| **Task** | One step, done by one **module** | `ansible.builtin.apt` installs packages |
| `become: true` | Run as root (sudo) | Every play |
| `gather_facts: false` | Skip collecting system information (it isn't needed, and skipping it is faster) | Every play |
| `template` | Copy a `.j2` file and **fill in its `{{ blanks }}`** | `nginx.conf.j2` → `/etc/nginx/nginx.conf` |
| `vars` | Values for the blanks, for one task only | `wg_address: "{{ wg_frontend_ip }}"` |
| `register` | Save a task's result in a variable | `register: cert` |
| `when` | Run the task only if a condition is true | `when: enable_tls \| bool` |
| `creates` | Skip the command if this file already exists | `creates: /etc/wireguard/private.key` |
| `notify` / **handler** | If the task **changed** something, run this handler **once, at the end of the play** | Config changed → restart nginx |
| `hostvars` | Read a variable that belongs to **another** server | `hostvars['video-streamer'].wg_public_key` |
| `delegate_to: localhost` | Run this task on the **laptop**, not on the server | Downloading the video |

---

## Settings used by every play

**[`ansible/ansible.cfg`](../ansible/ansible.cfg):**

| Setting | Why |
|---|---|
| `inventory = inventory.yml` | Use the inventory Terraform wrote |
| `host_key_checking = False` | The servers are new on every rebuild, so their SSH fingerprints are unknown |
| `timeout = 60` | Allow for the extra hop through the jump host |
| `force_handlers = True` | Run pending handlers even if a later task fails (for example, restart the stream after a key rotation) |
| `pipelining`, `ControlPersist` | Reuse SSH connections, so the playbook runs faster |

**[`ansible/group_vars/all.yml`](../ansible/group_vars/all.yml)**, values shared by every play:

| Variable | Value | Used for |
|---|---|---|
| `wg_port` | `51820` | WireGuard's UDP port |
| `wg_frontend_ip` / `wg_streamer_ip` | `10.99.0.1` / `10.99.0.2` | The two tunnel addresses |
| `video_title`, `video_file`, `video_url`, `video_dir` | Elephants Dream, `/videos` | The looped video |
| `cert_name` | `<fqdn>`, or `<fqdn>-staging` | The certificate's name, so staging and real certificates never mix |

**From the inventory** (written by Terraform): `fqdn`, `frontend_private_ip`, `enable_tls`, `acme_challenge`, `letsencrypt_staging`, `stream_key`.

---

## Overview: the 5 plays

| Play | Runs on | Purpose | Lines |
|---|---|---|---|
| 1 | Frontend | Start the **package proxy** (apt-cacher-ng) | [4-42](../ansible/site.yml#L4-L42) |
| 2 | Streamer | Tell the streamer's apt to **use that proxy** | [44-60](../ansible/site.yml#L44-L60) |
| 3 | Both | Install WireGuard, create each server's keys, share the public keys | [62-93](../ansible/site.yml#L62-L93) |
| 4 | Frontend | nginx + RTMP, HTTPS certificate, website, tunnel (listening end) | [95-378](../ansible/site.yml#L95-L378) |
| 5 | Streamer | Video, tunnel (calling end), ffmpeg loop service | [380-475](../ansible/site.yml#L380-L475) |

**The order matters:**

```
Play 1  frontend: proxy up ──────────┐  the streamer has no internet: it needs
Play 2  streamer: apt → proxy ◀──────┘  the proxy before it can install anything
Play 3  both:     WireGuard keys     ── each side needs the other's public key
Play 4  frontend: receiver ready     ── nginx must listen before ffmpeg pushes
Play 5  streamer: start streaming
```

**The result:**

```
ffmpeg (streamer) ──RTMP inside WireGuard──▶ nginx-rtmp (frontend)
                                               │ cuts HLS / DASH chunks
                                               ▼
                                     https://<fqdn>/ ──▶ viewers
```

---

## Play 1: package proxy on the frontend

**Runs on:** the frontend. **Lines** [4-42](../ansible/site.yml#L4-L42).

The streamer has no route to the internet. To still get Ubuntu packages and security updates, it uses a **caching forward proxy** on the frontend: a middleman that downloads packages on the streamer's behalf, and keeps a copy for next time.

| Task | What it does |
|---|---|
| Wait for SSH | Retries for up to 5 minutes: a new server may still be booting |
| Wait for cloud-init | Ubuntu's first-boot setup holds the apt lock; installing before it finishes would fail |
| Install apt-cacher-ng | The proxy software. It listens on TCP **3142**. |
| Bind the proxy to the private address | Sets `BindAddress: localhost <frontend_private_ip>` in `/etc/apt-cacher-ng/acng.conf`, so it **never listens on the public side**. Notifies the restart handler. |
| Start apt-cacher-ng | Running now (`started`) and at every boot (`enabled`) |

**Handler:** `Restart apt-cacher-ng`, if the bind address changed.

**Matching firewall rules** ([`security.tf`](../terraform/security.tf)):
- the frontend accepts TCP 3142 only from the private subnet;
- the streamer may send to TCP 3142 only toward the public subnet;
- the frontend may go out on 80/443, which is how the proxy reaches Ubuntu's servers.

---

## Play 2: point the streamer's apt at the proxy

**Runs on:** the streamer, through the jump host. **Lines** [44-60](../ansible/site.yml#L44-L60).

| Task | What it does |
|---|---|
| Wait for SSH (through the frontend) | Retries until the streamer answers, via the `ProxyCommand` hop |
| Use the frontend's package proxy | Creates `/etc/apt/apt.conf.d/01proxy` |

The file it creates on the streamer:

```
Acquire::http::Proxy "http://192.168.0.148:3142";
```

- `/etc/apt/apt.conf.d/` is apt's settings folder; apt reads every file in it.
- The line means: *"for every download, don't connect to the internet; go through 192.168.0.148, port 3142."*
- Mode `0644` (readable by all) is fine because the file holds no secret, just an IP address.
- **Plain http is safe here:** every Ubuntu package is **GPG-signed**, and apt rejects anything whose signature doesn't match. The traffic also stays inside the VPC.

**Without this play,** `apt install` on the streamer would try to reach Ubuntu directly, find no route, time out, and the playbook would fail at play 3.

---

## Play 3: WireGuard keys on both servers

**Runs on:** both servers (`hosts: all`). **Lines** [62-93](../ansible/site.yml#L62-L93).

| Task | What it does |
|---|---|
| Wait for SSH, wait for cloud-init | As in play 1 |
| Install WireGuard | `wireguard-tools` (on the streamer, through the proxy) |
| Generate private key | `umask 077 && wg genkey > /etc/wireguard/private.key`. `umask 077` makes the file **root-only** from the moment it's created. `creates:` means it's **generated once and never overwritten**. |
| Derive public key | `wg pubkey < private.key`, saved with `register` |
| Share public key | `set_fact: wg_public_key`, so the other server's play can read it through `hostvars` |

**Key point:** each **private key is created on its own server and never leaves it**: not on the laptop, not in Terraform, not in git. Only the **public** keys travel, through Ansible's memory. This play has to run before plays 4 and 5, because each server's tunnel config needs the **other** server's public key.

---

## Play 4: the Web Frontend

**Runs on:** the frontend. **Lines** [95-378](../ansible/site.yml#L95-L378). It has 6 parts.

### 4a. Packages, tunnel, folders (lines 100-138)

| Task | What it does |
|---|---|
| Install packages | `nginx` (web server), `libnginx-mod-rtmp` (lets nginx **receive** a live RTMP stream), `ffmpeg` |
| Configure WireGuard tunnel | Fills [`wg0.conf.j2`](../ansible/templates/wg0.conf.j2) → `/etc/wireguard/wg0.conf` (mode `0600`). The frontend's address is `10.99.0.1`, it **listens** on UDP 51820, and its only peer is the streamer (public key from play 3, allowed IP `10.99.0.2/32`). |
| Start WireGuard tunnel | `wg-quick@wg0`, started now and at every boot |
| Create stream folders | `/var/www/html/stream/hls` and `/dash`, owned by `www-data` (nginx's user), where the video chunks are written |

### 4b. HTTPS certificate (lines 140-194)

The certificate comes from **Let's Encrypt** using the **HTTP-01** challenge. (DNS-01 is blocked by the lab's IAM policy.)

```
Install certbot
 → create /var/www/html/.well-known/acme-challenge/
 → is there already a certificate?               (stat → cert_before)
 → if not, make sure nginx serves port 80        (Let's Encrypt must reach it)
 → certbot certonly --webroot -w /var/www/html -d <fqdn>
                                                 (creates: skipped if it exists)
 → install a renewal hook: restart nginx after each automatic renewal
 → check again: is the certificate there?         (stat → cert)
```

**How HTTP-01 works:**
1. certbot puts a one-time token file under `/.well-known/acme-challenge/`.
2. Let's Encrypt downloads it from `http://<fqdn>/.well-known/acme-challenge/...`.
3. If the file is there, you've proven you control the domain, and the certificate is issued.

**Renewal:** certbot's timer renews the certificate automatically before it expires (every 90 days). The hook restarts nginx so it loads the new one.

**Staging:** with `letsencrypt_staging = true`, certbot asks Let's Encrypt's test server instead (untrusted certificates, but no rate limits). The certificate gets its own name (`-staging`), so switching back really fetches a trusted one.

### 4c. nginx configuration (lines 196-231)

| Task | What it does |
|---|---|
| Configure nginx (main config) | [`nginx.conf.j2`](../ansible/templates/nginx.conf.j2) → `/etc/nginx/nginx.conf`. It's the **RTMP receiver**: port 1935, accepts publishing only from `127.0.0.1` and the tunnel address `10.99.0.2`, checks the **stream key** through `on_publish`, and cuts HLS (3 s) and DASH chunks. Mode `0600` because it **contains the stream key**. |
| Configure streamer site | [`streamer.site.j2`](../ansible/templates/streamer.site.j2) → `/etc/nginx/sites-available/streamer`. It's the **website**: HTTPS (TLS 1.2/1.3, HSTS), the HTTP→HTTPS redirect (except Let's Encrypt challenges), and serving `/hls` and `/dash`. |
| Enable streamer site | Symlink into `sites-enabled/` |
| Disable default site | Removes Ubuntu's default page, which would otherwise take port 80 |
| Validate nginx configuration | `nginx -t`. If the config is broken, the play **stops here**. |

`tls_active: "{{ cert.stat.exists }}"` turns on the HTTPS parts of the config **only if the certificate really exists**. Otherwise nginx would refuse to start, looking for a missing file.

### 4d. Player page (lines 233-240)

[`index.html.j2`](../ansible/templates/index.html.j2) → `/var/www/html/index.html`: the web page with the video player (HLS and DASH). Its external scripts are pinned with **SRI hashes**, so a tampered CDN file is refused by the browser.

### 4e. Cleanup of removed features (lines 242-340)

These tasks remove what **earlier versions** of the project installed on long-lived servers:

| Removed | Why it was there |
|---|---|
| The NAT service, the MASQUERADE rule, IP forwarding | The frontend used to be the streamer's internet router |
| The camera service and its files, the weather cache | The dropped live-camera and weather features |
| The Stream Studio service, its container and images, Docker | The dropped Studio experiment |

On a **fresh** `terraform apply`, these tasks find nothing and change nothing. `failed_when: false` lets "service not found" pass silently.

### 4f. Keep nginx correct (lines 342-378)

| Task | What it does |
|---|---|
| Ensure nginx is running | Started now and at every boot |
| Restart nginx if its running config is older than the files | **Safety net.** If a previous run wrote new config files but stopped before restarting nginx, nginx would still be running the old config. This compares file dates with nginx's start time, and restarts it (after `nginx -t`) if needed. |

**Handlers:**
- `Restart WireGuard`, when `wg0.conf` changes.
- `Reload nginx`, which actually runs `nginx -t && systemctl restart nginx`:
  - **restart, not reload:** a reload keeps the old listening sockets, so a moved listener silently keeps the old config;
  - **`nginx -t` first:** nginx only restarts if the new config is valid. A broken config never takes the site down, even when `force_handlers` runs the handler after a failure.

---

## Play 5: the Video Streamer

**Runs on:** the streamer, through the jump host. **Lines** [380-475](../ansible/site.yml#L380-L475).

| Task | What it does |
|---|---|
| Install packages | `ffmpeg`, through the proxy |
| Create video folder | `/videos` |
| Download video on the control machine | `delegate_to: localhost`: **the laptop** downloads the file into `ansible/files/`. Two reasons: the streamer has no internet, and download.blender.org refuses AWS IPs (403). `run_once` downloads it only once. |
| Upload video to the streamer | The laptop copies it over SSH, through the jump host. Notifies `Restart stream`. |
| Configure WireGuard tunnel | Fills `wg0.conf.j2` again, as the **calling** side: the streamer's address is `10.99.0.2`, it doesn't listen, and its peer is the frontend (`10.99.0.1`) with `Endpoint = <frontend_private_ip>:51820` and `PersistentKeepalive = 25`. |
| Start WireGuard tunnel | `wg-quick@wg0`, started now and at every boot |
| Install stream key (root-only) | [`ffmpeg-stream.env.j2`](../ansible/templates/ffmpeg-stream.env.j2) → `/etc/ffmpeg-stream.env` (`STREAM_KEY=...`, mode `0600`). The key lives in a root-only file, **never on a command line**, where `ps` or logs could show it. |
| Install streaming service | [`ffmpeg-stream.service.j2`](../ansible/templates/ffmpeg-stream.service.j2) → a **systemd service** that runs ffmpeg forever: it loops the video (`-stream_loop -1`), re-encodes it with `-preset veryfast`, and pushes it to `rtmp://10.99.0.1:1935/live/stream?key=$STREAM_KEY` **through the tunnel**. systemd restarts it if it stops. |
| Start streaming service | `daemon_reload` (re-read the service files), started now and at every boot |

**Handlers:**
- `Restart WireGuard`, when the tunnel config changes.
- `Restart stream`, when the video, the key, the tunnel or the service file changes. For example, after a stream-key rotation ffmpeg restarts with the new key.

---

## Why the playbook can be re-run safely

The playbook is **idempotent**: running it a second time changes nothing unless something needs fixing.

- Tasks describe a **desired state** (`state: started`, `state: absent`, `state: link`), not actions.
- `template` and `copy` rewrite a file only if its content differs.
- Commands that create something use `creates:`: the certificate, the WireGuard private key.
- Read-only checks use `changed_when: false`.
- Handlers fire only when something actually changed.

That's why `terraform apply` can run it again after any change, for example after the lab's nightly shutdown, or after an edit to a template.

---

## Security measures in the playbook

| Measure | Where |
|---|---|
| The streamer has no internet; packages come through a proxy bound to the private IP | Plays 1-2 |
| WireGuard private keys are generated on each server, are root-only, and never leave it | Play 3 |
| The stream travels inside an encrypted WireGuard tunnel | Plays 4-5 |
| Only `127.0.0.1` and `10.99.0.2` may publish, and only with the correct stream key | `nginx.conf.j2` |
| Files that hold secrets are mode `0600` (`nginx.conf`, `wg0.conf`, `ffmpeg-stream.env`) | Plays 4-5 |
| The stream key is never on a command line | Play 5 |
| HTTPS from Let's Encrypt, TLS 1.2/1.3, HSTS, HTTP→HTTPS redirect, automatic renewal | Play 4 |
| `nginx -t` before every restart: a bad config can't cause an outage | Play 4 |
| SRI hashes on the player's external scripts | `index.html.j2` |
| ansible-lint checks the playbook on every push | `.github/workflows/security.yml` |

---

## Likely questions

**What does the playbook do, in one sentence?**
It turns two blank Ubuntu servers into a streaming platform: a package proxy and an HTTPS streaming website on the frontend, and an ffmpeg video loop on the streamer, connected by a WireGuard tunnel.

**How does the streamer install software without internet?**
`/etc/apt/apt.conf.d/01proxy` points apt at the frontend's apt-cacher-ng (`<frontend_private_ip>:3142`), which downloads packages from Ubuntu on its behalf. apt verifies the GPG signature of every package.

**How do the two servers get each other's WireGuard keys?**
Each generates its own private key, which never leaves it. Ansible reads the public keys (`set_fact`) and gives each server the other's key through `hostvars`.

**How does Ansible reach the private streamer?**
Through the frontend as an SSH jump host (`ProxyCommand` in the inventory written by Terraform).

**Why is the video downloaded on the laptop?**
The streamer has no internet, and the video host blocks AWS IPs. The laptop downloads it (`delegate_to: localhost`) and pushes it over SSH.

**What happens if you run the playbook twice?**
Nothing changes: it is idempotent. Handlers only fire when a file or setting actually changed.

**Why restart nginx instead of reloading it, and why `nginx -t` first?**
A reload can silently keep the old listening sockets and the old config. Testing first means a broken config never stops a working nginx.
