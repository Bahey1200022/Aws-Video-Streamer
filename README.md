# MSS Project: Automated Live Video Streaming on AWS

A live video streaming platform on AWS, deployed and configured end to end
with a single `terraform apply`.

A **Video Streamer** in a private subnet loops a video with ffmpeg and pushes it
over RTMP to a **Web Frontend** in the public subnet. The frontend, running nginx
with the RTMP module, repackages the stream as **HLS** and **DASH** and serves it
to browsers.

- **Terraform** builds the AWS infrastructure.
- **Ansible**, launched by Terraform, configures the software on both servers.

---

## Contents
- [Architecture](#architecture)
- [Features](#features)
- [Security features](#security-features)
- [Prerequisites](#prerequisites)
- [Usage](#usage)
- [Verifying the security features](#verifying-the-security-features)
- [Project structure](#project-structure)
- [Configuration](#configuration)
- [Known limitations](#known-limitations)
- [Troubleshooting](#troubleshooting)

---

## Architecture

```
                                Internet
                                   │
                          ┌────────┴────────┐
                          │ Internet Gateway│
                          └────────┬────────┘
┌─ VPC 192.168.0.0/16 ─────────────┼──────────────────────────────────────────┐
│                                  │                                          │
│  Public subnet 192.168.0.0/24    │ HTTP :80 (viewers) · SSH :22 (admin IP)  │
│  ┌───────────────────────────────┴───────────────────────┐                  │
│  │ Web Frontend (EC2, Ubuntu 22.04)                      │                  │
│  │  nginx + RTMP module   → /hls  /dash  (player page)   │◀── IAM role      │
│  │  WireGuard wg0 10.99.0.1  ·  NAT for private subnet   │    r53-devops    │
│  └───────────────────────────────▲───────────────────────┘    (certbot)     │
│                                  ║ WireGuard UDP 51820 (encrypted)          │
│                                  ║ carrying RTMP + stream key               │
│  Private subnet 192.168.1.0/24   ║                                          │
│  ┌───────────────────────────────╨───────────────────────┐                  │
│  │ Video Streamer (EC2, Ubuntu 22.04, no public IP)      │                  │
│  │  ffmpeg loop: BigBuckBunny → rtmp://10.99.0.1/live    │                  │
│  │  WireGuard wg0 10.99.0.2                              │                  │
│  └───────────────────────────────────────────────────────┘                  │
└─────────────────────────────────────────────────────────────────────────────┘
        Route 53: bahey.devops.gin-telecom.ovh → frontend public IP
```

**Data flow:** ffmpeg (streamer) → WireGuard tunnel → nginx-rtmp :1935 (frontend)
→ HLS 3s / DASH 15s chunks in `/var/www/html/stream` → browser over HTTP.

---

## Features

### Infrastructure (Terraform)
| Feature | Details |
|---|---|
| Reuses an existing VPC | VPC, subnets and Internet Gateway are looked up, not created |
| Two EC2 instances | Web Frontend (public subnet) and Video Streamer (private subnet), Ubuntu 22.04 |
| NAT instance | The frontend forwards the private subnet's internet traffic (`nat.sh` + a private route table), so no paid NAT gateway is needed |
| DNS record | `A` record in Route 53, kept pointing at the frontend's current public IP |
| Generated SSH key | ED25519 key created by Terraform, saved as `terraform/mss-key.pem`; nothing to set up by hand |
| Admin IP auto-detection | The SSH allow-list follows your current public IP on every apply |
| Survives the nightly lab shutdown | `aws_ec2_instance_state` starts stopped instances; the new public IP is read back and DNS and the inventory are updated |
| No accidental rebuilds | `ignore_changes` stops Terraform replacing a server just because it's stopped (no public IP) or because Canonical published a newer Ubuntu image |

### Configuration (Ansible, run automatically by Terraform)
| Feature | Details |
|---|---|
| One-command deploy | `terraform_data` + `local-exec` runs the playbook with a generated inventory |
| Re-runs only when needed | Triggered by instance changes, inventory changes, or edits to the playbook, templates or group vars |
| Jump host | The private streamer is reached through the frontend (SSH `ProxyCommand`) |
| Web Frontend | nginx, libnginx-mod-rtmp, ffmpeg; RTMP ingest; HLS + DASH output; CORS; HTML5 player (hls.js) |
| Video Streamer | ffmpeg as a systemd service (`Restart=always`) looping `BigBuckBunny_320x180.mp4` |
| Video download workaround | download.blender.org returns 403 to AWS IPs, so the file is fetched on the control machine and uploaded |
| Robustness | 60 s connection timeout for the jump host; `force_handlers` so restarts still run if a later task fails |
| Optional HTTPS | Let's Encrypt via certbot DNS-01 with Route 53; HTTP→HTTPS redirect (see [limitations](#known-limitations)) |

---

## Security features

### 1. Network segmentation
- The streamer is in a **private subnet with no public IP**, so it can't be reached from the internet.
- Only the frontend is exposed, and only on the ports it needs.

### 2. Least-privilege firewalls (security groups)
| Server | Allowed in | From |
|---|---|---|
| Frontend | TCP 80, 443 | Anywhere (viewers) |
| Frontend | TCP 22 | **Your current public IP only** (auto-detected) |
| Frontend | UDP 51820 | Private subnet only (WireGuard) |
| Frontend | TCP 80, 443 | Private subnet only (streamer traffic passing through the NAT) |
| Streamer | TCP 22 | Frontend security group only (jump host) |

RTMP (1935) and the RTMP control endpoint (8080) are **not reachable over the network**.

### 3. Authenticated publishing (stream key)
- The streamer must present a secret key to publish (`rtmp://…/live/stream?key=…`), the same model YouTube and Twitch use.
- **Where the key comes from:** Terraform's `random_password` (32 characters, about 190 bits of entropy) generates it. It's delivered by Ansible and never stored in git.
- **How it's checked:** nginx-rtmp's `on_publish` asks the Stream Studio on a **localhost-only** endpoint (`127.0.0.1:5000/studio/internal/publish-auth`). The Studio compares the key against the channel's key in its database, in constant time: `200` accepts, `403` rejects. The main stream is the Studio's protected **system channel** `stream`.
- **Logging:** every attempt is recorded in the Studio's audit log as `publish_ok` / `publish_denied` (address, app, channel), **never the key**.
- **The key is kept out of logs:** the RTMP access log uses a custom format without connection arguments (the default format would log the key).
- **Root-only storage:** `/etc/nginx/nginx.conf` and `/etc/ffmpeg-stream.env` are `0600`. The world-readable systemd unit only refers to `${STREAM_KEY}`.
- **Rotation with one command:** `terraform apply -replace=random_password.stream_key`.

### 4. Encrypted ingest (WireGuard tunnel)
- All RTMP traffic, video and stream key included, travels inside a **WireGuard** tunnel (`10.99.0.2 → 10.99.0.1`, UDP 51820).
- **Private keys never leave their host.** Each server generates its own key, and Ansible exchanges only the public keys. The private key isn't even in `wg0.conf`; it's loaded with `PostUp = wg set %i private-key …`.
- nginx accepts publishing **only from the tunnel address** `10.99.0.2` (plus localhost), so an unencrypted stream is rejected even with a valid key.
- **Protects against** eavesdropping inside the VPC, such as VPC Traffic Mirroring by anyone with EC2 access to the shared account.

**Measured before and after** (packet capture during a publisher reconnect):

| | Before | After |
|---|---|---|
| On the wire | RTMP, TCP 1935, plaintext | WireGuard, UDP 51820 |
| Stream key visible in capture | 4 times | **0** |
| Readable RTMP strings (URL, encoder) | Yes | **None** |
| Direct publish to `<frontend>:1935` with a valid key | Accepted | **Blocked** |

### 5. Encryption at rest (KMS)
- **Both servers' disks are encrypted** with a **customer-managed KMS key** (`alias/mss-ebs`, [kms.tf](terraform/kms.tf)). This covers the stream key, WireGuard keys and logs stored on them.
- **How it works:** envelope encryption. Each disk has its own data key, stored encrypted. At boot, EC2 asks KMS to decrypt that data key; IAM authorizes the request and CloudTrail logs it. The KMS key material never leaves AWS's hardware.
- **Settings:** automatic yearly key rotation, and a 7-day recovery window if the key is deleted.
- **Protects against** leaked snapshots, copied volumes and decommissioned hardware: without permission on the key, a disk copy is unreadable.
- **Doesn't protect** a running server, where the disk is transparently unlocked, or the Terraform state on the control machine.
- **Lab caveat:** the default key policy delegates to IAM, and every student shares the same `DevopsLab` role. A key policy restricted to a specific SSO session would be needed to keep classmates out.

### 6. Stream Studio (application security)
A Flask app ([studio/](studio/)) at `/studio/` where users log in and run their own live channels. It gives the platform real attack surface (accounts, user input, its own code), each piece with a matching control:

| Feature | Threat | Control |
|---|---|---|
| Accounts (admin, user) | Password theft, guessing | scrypt password hashes, 12+ characters, identical error for any failure |
| Login form | Brute force | **Lockout** after 5 failures in 15 min (per account) + nginx **rate limit** of 10/min per IP (`429`) |
| Every form | Cross-site request forgery | **CSRF token** on every POST |
| Sessions | Fixation, theft | New session at login; `HttpOnly`, `SameSite=Lax` cookies, scoped to `/studio`, 8 h lifetime |
| Channels (own stream key each) | Broken access control (OWASP A01), stream hijacking | Ownership checks (other users' channels return `404`); per-channel keys; key rotation |
| **Import video from URL** | **SSRF** (OWASP A10) | http(s) only, default ports only, no credentials in URLs; **every resolved IP must be public** (blocks `169.254.169.254`, `127.0.0.1`, the VPC…); re-checked on every redirect; 200 MB cap; file validated with ffprobe. IMDSv2 is the backstop. |
| **Private channels** | Unauthorized viewing, leaked links | 24 h **share links** (HMAC-SHA256, revocable); playback via `/private/<token>/<expiry>/…`, where nginx **`auth_request`** asks the Studio to verify an **HMAC-SHA256** token on every playlist and chunk. The raw `/stream/` folder is never served. |
| Admin page | Privilege escalation | Admin-only (`403` otherwise); every security event in an **audit log** |
| Browser | XSS, clickjacking | Strict **Content-Security-Policy** (no inline scripts), `X-Frame-Options: DENY`, `nosniff`, `Referrer-Policy`; CDN scripts pinned with **SRI** |
| Internal endpoints | Bypassing the checks | `/studio/internal/*` returns `404` through nginx; the app also rejects anything relayed by the proxy |
| Container | Damage after a compromise | Runs as uid 10001, **read-only** filesystem, **all capabilities dropped**, `no-new-privileges`, 400 MB memory and 256 process limits; listens on `127.0.0.1` only |
| Secrets | Leaks through git | Admin password, session/link secrets generated by Terraform; root-only `/etc/studio.env` |

- **Docker and the NAT:** Docker normally rewrites iptables and sets the forwarding policy to `DROP`, which would cut off the streamer. `/etc/docker/daemon.json` (`"iptables": false`) is written **before** Docker is installed, and the container uses host networking.
- **Tests:** [studio/tests/test_security.py](studio/tests/test_security.py) runs 34 security checks (authentication, CSRF, roles, SSRF, publish auth, signed URLs, lockout, no secrets in logs).

### 7. Credentials and secrets hygiene
- **No passwords on servers:** the frontend gets AWS permissions from an **IAM instance role** (`r53-devops`), not stored keys.
- **IMDSv2 required on both servers** (`metadata_options { http_tokens = "required" }`).
  - **Why:** the instance role's credentials can only be fetched with a session token obtained by a `PUT` request. An SSRF bug, which can usually only make plain `GET` requests, gets `401 Unauthorized` instead of the AWS keys.
  - **Verified:** a plain GET to `…/security-credentials/r53-devops` returns `401`, while the token-based IMDSv2 request still works for certbot and the AWS tools.
- **Generated, not hand-written:** the SSH key and stream key are generated by Terraform.
- **Git-ignored:** state, keys and the generated inventory are excluded (`*.tfstate`, `*.pem`, `inventory.yml`, `files/`).
- **Hidden in output:** `stream_key` is a sensitive output, hidden in plan and apply output.

### Security summary
| Threat | Mitigation |
|---|---|
| Direct attack on the streamer | Private subnet, no public IP, SSH only from the frontend |
| SSH brute force on the frontend | SSH allowed from one IP (yours); key-only login |
| Stream hijacking (someone else publishes) | Stream key + publish allowed only from the tunnel IP |
| Eavesdropping or theft of the stream key in the VPC | WireGuard encryption |
| Bypassing the tunnel | Firewall blocks 1935; nginx denies non-tunnel publishers |
| Takeover through the RTMP control API | Port 8080 not reachable from the network |
| Theft of instance-role credentials through SSRF | IMDSv2 required (plain GET → 401) |
| Leaked disk snapshot or copied volume | Disks encrypted with a customer-managed KMS key |
| Secrets leaking through git or logs | Git-ignored state and keys; key-free log formats; root-only files |
| Studio: brute-force login | Per-account lockout + per-IP rate limit |
| Studio: SSRF through "import from URL" | Public-address allow-list on every hop, plus IMDSv2 |
| Studio: viewing private channels without permission | Signed, expiring HMAC-SHA256 URLs checked by nginx `auth_request`; raw chunk folder never served |
| Studio: access to other users' channels or admin | Ownership and role checks; audit log |
| Studio: XSS / clickjacking | Strict CSP, security headers |
| Studio: container compromise | Non-root, read-only, no capabilities, resource limits |

---

## Prerequisites
- An AWS account with an existing VPC containing:
  - a public subnet, routed to an Internet Gateway;
  - a private subnet.
- **AWS CLI v2**, logged in: `aws sso login`.
- **Terraform** ≥ 1.5.
- **Ansible** (developed and tested with ansible-core 2.17).
- Optional: a Route 53 hosted zone, plus an instance profile allowed to write to it (for HTTPS).

## Usage

```bash
aws sso login                        # once per session (SSO tokens expire)
cd terraform
cp terraform.tfvars.example terraform.tfvars   # first time only, then edit
terraform init                       # first time only
terraform apply
```

After about 3–5 minutes:
```
frontend_fqdn      = "bahey.devops.gin-telecom.ovh"
frontend_public_ip = "x.x.x.x"
stream_url         = "http://bahey.devops.gin-telecom.ovh/"
ssh_frontend       = "ssh -i ./mss-key.pem ubuntu@x.x.x.x"
stream_key         = <sensitive>
studio_url         = "http://bahey.devops.gin-telecom.ovh/studio/"
studio_admin_password = <sensitive>
```

Open `stream_url` in a browser. The video autoplays muted.

| URL | Content |
|---|---|
| `/` | Player page |
| `/hls/stream.m3u8` | HLS playlist (also playable in VLC) |
| `/dash/stream.mpd` | DASH manifest |
| `/studio/` | Stream Studio: log in as `admin` with `terraform output -raw studio_admin_password` |

### Common commands
```bash
terraform output -raw stream_key                     # show the stream key
terraform output -raw studio_admin_password          # Studio admin password
terraform apply -replace=random_password.stream_key  # rotate the stream key
ssh -i mss-key.pem ubuntu@$(terraform output -raw frontend_public_ip)
terraform destroy                                    # delete everything
```

After the nightly lab shutdown, run `terraform apply` again. It restarts both
servers, updates DNS to the new IP, and re-runs Ansible.

---

## Verifying the security features

Run these on the frontend (`ssh -i mss-key.pem ubuntu@<frontend_public_ip>`).

**Stream key: a publish without the key is rejected**
```bash
ffmpeg -re -f lavfi -i testsrc -t 5 -c:v libx264 -f flv "rtmp://127.0.0.1:1935/live/stream?key=wrong"
# → ffmpeg fails; the Studio's Admin → Audit log shows "publish_denied"
```

**WireGuard: the tunnel is up and carrying traffic**
```bash
sudo wg show wg0                                  # recent handshake, growing transfer counters
```

**Encryption: the VPC only sees WireGuard**
```bash
# On the real network interface: only UDP 51820, nothing readable
sudo timeout 10 tcpdump -ni ens5 host <streamer_private_ip> and not port 22
# Inside the tunnel (on this server only): the RTMP stream
sudo timeout 10 tcpdump -ni wg0
```

**Studio: SSRF is blocked.** Create a channel, then import `http://169.254.169.254/latest/meta-data/`. The page shows *"Import blocked: destination address 169.254.169.254 is not a public address"*, and the audit log records `import_blocked`.

**Studio: private files need a token.**
```bash
curl -s -o /dev/null -w "%{http_code}\n" http://<frontend>/stream/private/<channel>.m3u8   # → 404
```

**Studio tests (local):**
```bash
python3 -m venv /tmp/v && /tmp/v/bin/pip install -r studio/requirements.txt
cd studio && /tmp/v/bin/python tests/test_security.py "$(mktemp -d)"
```

**Firewall: RTMP isn't reachable over the VPC.** Run this on the streamer:
```bash
nc -zv -w 5 <frontend_private_ip> 1935            # → timed out
```

---

## Project structure

```
mss-project/
├── README.md
├── terraform/                      Infrastructure + orchestration
│   ├── versions.tf                 Providers (aws, tls, local, http, random)
│   ├── variables.tf                Inputs
│   ├── terraform.tfvars            Your values (copy of .example)
│   ├── network.tf                  VPC/subnet lookups, private route via NAT, admin IP detection
│   ├── security.tf                 Security groups
│   ├── iam.tf                      Route 53 zone + lab instance profile lookups
│   ├── compute.tf                  SSH key, instances, auto-start, DNS record
│   ├── nat.sh                      Boot script: turns the frontend into a NAT (systemd unit)
│   ├── stream_key.tf               Stream key generation
│   ├── kms.tf                      Customer-managed KMS key for disk encryption
│   ├── studio.tf                   Studio secrets (admin password, session and link secrets)
│   ├── ansible.tf                  Generates the inventory and runs the playbook
│   ├── inventory.yml.tftpl         Inventory template
│   └── outputs.tf                  IPs, URLs, SSH command, stream key (sensitive)
├── studio/                         Stream Studio (Flask + SQLite, Docker)
│   ├── app.py                      Routes, auth, channels, SSRF-safe import, publish/playback auth
│   ├── Dockerfile                  python:3.12-slim + ffmpeg, non-root
│   ├── templates/, static/         UI (no inline scripts, CSP-compatible)
│   └── tests/test_security.py      Security tests
└── ansible/                        Server configuration
    ├── ansible.cfg
    ├── site.yml                    Plays: WireGuard keys → Web Frontend → Video Streamer
    ├── group_vars/all.yml          Tunnel addressing and port
    └── templates/
        ├── nginx.conf.j2           RTMP ingest (live + private apps), Studio publish auth, login rate-limit zone
        ├── streamer.site.j2        /hls, /dash, /studio proxy, signed /private playback (+ optional TLS)
        ├── studio_proxy.conf.j2    Reverse-proxy settings + security headers (CSP…)
        ├── studio.env.j2           Studio secrets (root-only)
        ├── studio.service.j2       Hardened docker run as a systemd unit
        ├── index.html.j2           Player page
        ├── wg0.conf.j2             WireGuard interface/peer
        ├── ffmpeg-stream.service.j2
        └── ffmpeg-stream.env.j2    Stream key (root-only)
```

## Configuration

| Variable | Default | Description |
|---|---|---|
| `vpc_id` | — (required) | Existing VPC |
| `aws_region` | `us-east-1` | Region |
| `public_subnet_name` / `private_subnet_name` | `bahey-subnet-public` / `bahey-subnet-private` | Subnets, by Name tag |
| `domain_name` | `null` | Route 53 hosted zone; `null` skips DNS and TLS |
| `frontend_hostname` | `devops` | Record name inside the zone |
| `admin_cidr` | auto-detected | CIDR allowed to SSH to the frontend |
| `instance_type` | `t3.micro` | Instance size for both servers |
| `frontend_instance_profile` | `r53-devops` | Existing instance profile with Route 53 permissions |
| `enable_tls` | `false` | Request a Let's Encrypt certificate and serve HTTPS |
| `letsencrypt_staging` | `false` | Use Let's Encrypt's staging CA (no rate limits, untrusted certificates) |

---

## Known limitations
- **HTTPS is blocked by a lab-side permission.**
  - **The problem:** the `r53-devops` role's policy (`Letsencrypt-devops.intuitivesoft.cloud`) only allows `route53:ChangeResourceRecordSets` on two hosted zones that no longer exist. A certbot dry run fails with `AccessDenied` on `Z0316326GXOE1JMI1YJX`.
  - **What's ready:** the TLS code path (certbot DNS-01, HTTPS server block, HTTP→HTTPS redirect) is implemented.
  - **To enable it:** once the policy includes the zone, set `enable_tls = true` and run `terraform apply`.
- **The lab account can't create IAM roles**, so the frontend uses the lab-provided instance profile.
- **The frontend is a single point of failure**: it's both the web server and the streamer's NAT, so if it's down, the streamer loses internet access too.
- **The public IP changes on every restart.** DNS uses a 60 s TTL and is updated on each `apply`.

## Troubleshooting
| Symptom | Fix |
|---|---|
| `No valid credential sources found` / `InvalidGrantException` | Your SSO session expired: run `aws sso login` |
| SSH to the frontend times out | Your public IP changed (common on campus networks): run `terraform apply` to update the allow-list |
| Player stays black | Wait about 10 s for the first HLS chunks, then refresh |
| Stream stopped | On the streamer: `sudo systemctl status ffmpeg-stream`; on the frontend: `sudo wg show` and `sudo tail /var/log/nginx/publish-auth.log` |
