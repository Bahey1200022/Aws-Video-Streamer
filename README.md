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
- [Security pipeline (shift-left)](#security-pipeline-shift-left)
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
│  │  ffmpeg loop: Elephants Dream → rtmp://10.99.0.1/live │                  │
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
| Video Streamer | ffmpeg as a systemd service (`Restart=always`) looping the video set in `group_vars/all.yml` (default: *Elephants Dream*, 480p) |
| Video download workaround | download.blender.org returns 403 to AWS IPs, so the file is fetched on the control machine and uploaded |
| Robustness | 60 s connection timeout for the jump host; `force_handlers` so restarts still run if a later task fails |
| HTTPS | Let's Encrypt via certbot, through **DNS-01** (Route 53, the lab design) or **HTTP-01** (port 80); HTTP→HTTPS redirect; automatic renewal |

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

**Outbound traffic is restricted too**, so a compromised process can't "phone home" on arbitrary ports:

| Server | Allowed out | To |
|---|---|---|
| Frontend | TCP 80, 443 | Internet (apt, Let's Encrypt, and the streamer's NAT traffic) |
| Frontend | TCP 22 | Private subnet (Ansible jump to the streamer) |
| Streamer | UDP 51820 | Public subnet (WireGuard to the frontend) |
| Streamer | TCP 80, 443 | Internet, through the frontend NAT (apt) |

Amazon DNS, NTP and the metadata service aren't filtered by security groups. **Verified:** apt, DNS, NTP, the tunnel and the stream work, while outbound ports 25, 8080 and 6667 are blocked from both servers.

RTMP (1935) and the RTMP control endpoint (8080) are **not reachable over the network**.

### 3. Authenticated publishing (stream key)
- The streamer must present a secret key to publish (`rtmp://…/live/stream?key=…`), the same model YouTube and Twitch use.
- **Where the key comes from:** Terraform's `random_password` (32 characters, about 190 bits of entropy) generates it. It's delivered by Ansible and never stored in git.
- **How it's checked:** nginx-rtmp's `on_publish` asks a **localhost-only** endpoint (`127.0.0.1:8081/auth/publish`). Only the stream name `stream` with the correct key gets `200`; everything else gets `403`.
- **Logging:** every attempt is recorded in `/var/log/nginx/publish-auth.log` (address, app, name, result), **never the key**.
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
- **Key policy written in code** ([kms.tf](terraform/kms.tf)): the account administers the key, and IAM decides who may use it. That's the same access as AWS's default, but visible and reviewable.
- **Lab caveat:** this policy delegates to IAM, and every student shares the same `DevopsLab` role. A key policy restricted to a specific SSO session would be needed to keep classmates out.

### 6. Encryption to viewers (HTTPS)
- **Live:** `https://bahey.devops.gin-telecom.ovh/` uses a **trusted Let's Encrypt certificate**. `http://` redirects (301) to HTTPS.
- **TLS 1.2 and 1.3 only**: TLS 1.1 and older are refused.
- **HSTS** (`Strict-Transport-Security: max-age=86400`) tells browsers to use HTTPS only. It's kept to one day so a failed certificate after a lab rebuild can't lock visitors out for a year.
- **Two ways to prove domain ownership**, selected with `acme_challenge`:

  | | `dns` (DNS-01, the lab design) | `http` (HTTP-01, **in use**) |
  |---|---|---|
  | Proof | TXT record `_acme-challenge.<fqdn>` written to Route 53 through the `r53-devops` role | Token file served by nginx at `http://<fqdn>/.well-known/acme-challenge/…` |
  | Needs | IAM permission on the hosted zone | Port 80 reachable |
  | Status | Implemented, **blocked**: the lab's policy only covers two deleted zones (`AccessDenied` on `Z0316326GXOE1JMI1YJX`) | ✅ Working |

  The resulting certificate and encryption are identical; only the ownership proof differs.
- **Renewal:** certbot's systemd timer renews automatically, using the same method. A deploy hook restarts nginx to load the new certificate. Port 80 keeps serving `/.well-known/acme-challenge/` unredirected so renewals work. **Verified** with `certbot renew --dry-run`.
- **Staging first:** `letsencrypt_staging = true` uses Let's Encrypt's test CA (untrusted, no rate limits). Staging and production certificates have different names, so turning staging off really requests a trusted one.

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
| Eavesdropping or tampering between viewers and the site | HTTPS (trusted Let's Encrypt certificate), TLS 1.2+, HSTS, HTTP→HTTPS redirect |
| Leaked disk snapshot or copied volume | Disks encrypted with a customer-managed KMS key |
| Secrets leaking through git or logs | Git-ignored state and keys; key-free log formats; root-only files; gitleaks in CI + pre-commit |
| Malware calling out on arbitrary ports | Outbound security-group rules limited to 80/443 (+ SSH/WireGuard inside the VPC) |
| Insecure infrastructure changes slipping in | Checkov + Terraform validation on every push |

---

## Security pipeline (shift-left)

Every push and pull request runs [.github/workflows/security.yml](.github/workflows/security.yml) on GitHub Actions. It only **reads** the code: no AWS credentials, and the workflow token is read-only.

```
git push ─┬─▶ Terraform    fmt -check + validate       (well-formed?)
          ├─▶ Checkov      terraform/ + the workflow   (insecure cloud config?)
          ├─▶ gitleaks     every commit in history     (secrets ever committed?)
          └─▶ ansible-lint production profile          (risky playbook patterns?)
                → ✅ green, or ❌ red with the exact file and line
```

**The pipeline is hardened as well:**
- **Read-only token:** `permissions: contents: read`.
- **Actions pinned to commit SHAs**, not tags. A tag can be moved to different code; a SHA can't.
- **Tool versions pinned**, each at least two weeks old when chosen: Terraform 1.16.6, Checkov 3.3.29, ansible-lint 26.10.1, gitleaks 8.18.4.
- **The gitleaks download is checksum-verified** before it runs.
- **Checkov also scans the workflow itself:** 88/88 checks passed.

**Further left, on your laptop:** [.pre-commit-config.yaml](.pre-commit-config.yaml) runs gitleaks on staged changes before a commit is even created. Setup, once:
```bash
pip install pre-commit && pre-commit install
```

### Baseline and triage
| Tool | Before | After |
|---|---|---|
| gitleaks | 7 commits, **no leaks** | Unchanged |
| ansible-lint | 1 finding (`run-once`) | **Passes** the `production` profile |
| Checkov (Terraform) | 25 passed, **13 failed** | **30 passed, 0 failed**, 8 skipped with reasons |

**Fixed:**
| Check | Fix |
|---|---|
| `CKV_AWS_382` ×2: egress to anywhere on any port | Outbound limited to the ports listed above, a new security control |
| `CKV_AWS_23` ×2: security-group rules without descriptions | Descriptions added |
| `CKV2_AWS_64`: KMS key policy not defined | Explicit key policy in `kms.tf` |

**Accepted** (skipped inline next to the resource, with the reason):
| Check | Resource | Reason |
|---|---|---|
| `CKV_AWS_260` | Frontend SG | Port 80 must stay open: it redirects to HTTPS and serves Let's Encrypt HTTP-01 challenges |
| `CKV_AWS_88` | Frontend | It's the public web server, so it needs a public IP |
| `CKV2_AWS_41` | Streamer | It needs no AWS access; a role would *add* privilege |
| `CKV_AWS_126` ×2 | Both servers | Detailed monitoring is a paid feature not needed here |
| `CKV_AWS_135` ×2 | Both servers | t3 is EBS-optimized by default; setting the flag forces a stop/start |
| `CKV2_AWS_23` | DNS record | False positive: the IP comes from a data source Checkov can't follow |
| ansible-lint `run-once` | Video download | Safe with the default `linear` strategy; downloading once is the intent |

### How the checks turn green or red
GitHub runs any workflow in `.github/workflows/` automatically; nothing needs configuring on the website.
1. **Each job gets a fresh Ubuntu machine** (a "runner"). The 4 jobs run in parallel, and each machine is discarded afterwards.
2. **Each job is a list of steps:**
   - `uses:` runs a ready-made action, pinned to a commit SHA;
   - `run:` runs a shell command.
3. **Each command's exit code decides the outcome:** `0` is ✅, anything else is ❌ and stops the job. The scanners are built for this:

| Command | Exits non-zero when |
|---|---|
| `checkov` | any check fails |
| `gitleaks detect` | any secret is found |
| `ansible-lint` | any rule is violated |
| `terraform fmt -check` / `validate` | the code is badly formatted or invalid |
| `sha256sum --check` | the downloaded gitleaks binary doesn't match its checksum |

The result is attached to the commit as a **status check**: ✅/❌ next to the commit, the full logs in the **Actions** tab, and "All checks have passed" (or not) on pull requests.

### Proof: the pipeline catches a misconfiguration
On a throwaway branch, the admin SSH rule in `security.tf` was changed from "my IP only" to `0.0.0.0/0`, a realistic debugging mistake, and pushed:

| Job | Result |
|---|---|
| Terraform fmt + validate | ✅ (the code is valid, just insecure) |
| **Checkov** | ❌ `CKV_AWS_24: "Ensure no security groups allow ingress from 0.0.0.0:0 to port 22"` FAILED for `aws_security_group.frontend` (`security.tf`) |
| gitleaks | ✅ |
| ansible-lint | ✅ |

The **pre-commit hook** also ran on that commit (`Detect hardcoded secrets … Passed`), showing the local check before anything reached GitHub. The branch was then deleted; the change was never applied to AWS.

### Making the checks mandatory (recommended)
A red check is only a warning unless GitHub enforces it. To **block merging into `main` unless all 4 jobs pass**: GitHub → **Settings** → **Rules → Rulesets** (or **Branches**) → new rule for `main` → **Require status checks to pass** → select the 4 jobs. This is the "CD gate" from shift-left practice: a misconfiguration like the demo above can't reach `main`.

### Running the scanners locally
```bash
checkov -d terraform --framework terraform --compact
(cd ansible && ansible-lint --offline site.yml)
gitleaks detect --source . --redact
```

---

## Prerequisites
- An AWS account with an existing VPC containing:
  - a public subnet, routed to an Internet Gateway;
  - a private subnet.
- **AWS CLI v2**, logged in: `aws sso login`.
- **Terraform** ≥ 1.5.
- **Ansible** (developed and tested with ansible-core 2.17).
- For HTTPS: a Route 53 hosted zone. HTTP-01 needs nothing else; DNS-01 also needs an instance profile allowed to write to the zone.

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
stream_url         = "https://bahey.devops.gin-telecom.ovh/"
ssh_frontend       = "ssh -i ./mss-key.pem ubuntu@x.x.x.x"
stream_key         = <sensitive>
```

Open `stream_url` in a browser. The video autoplays muted.

| URL | Content |
|---|---|
| `/` | Player page |
| `/hls/stream.m3u8` | HLS playlist (also playable in VLC) |
| `/dash/stream.mpd` | DASH manifest |

### Common commands
```bash
terraform output -raw stream_key                     # show the stream key
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
sudo tail -3 /var/log/nginx/publish-auth.log      # → result=403
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

**HTTPS: trusted certificate, redirect, TLS versions, renewal.** Run these from your laptop, except the last:
```bash
H=bahey.devops.gin-telecom.ovh
echo | openssl s_client -connect $H:443 -servername $H 2>/dev/null | openssl x509 -noout -issuer -enddate
#   → issuer: Let's Encrypt; the expiry date
curl -s -o /dev/null -w "%{http_code} verify=%{ssl_verify_result}\n" https://$H/   # → 200 verify=0 (trusted)
curl -s -o /dev/null -w "%{http_code} %{redirect_url}\n" http://$H/              # → 301 https://…
curl -sI https://$H/ | grep -i strict-transport                                   # → max-age=86400
echo | openssl s_client -connect $H:443 -tls1_1 2>&1 | grep -q "BEGIN CERT" && echo "TLS 1.1 accepted" || echo "TLS 1.1 refused"
# on the frontend:
sudo certbot renew --dry-run                      # → "all simulated renewals succeeded"
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
├── .github/workflows/security.yml  Security pipeline (Terraform, Checkov, gitleaks, ansible-lint)
├── .pre-commit-config.yaml         gitleaks before each local commit
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
│   ├── ansible.tf                  Generates the inventory and runs the playbook
│   ├── inventory.yml.tftpl         Inventory template
│   └── outputs.tf                  IPs, URLs, SSH command, stream key (sensitive)
└── ansible/                        Server configuration
    ├── ansible.cfg
    ├── .ansible-lint               ansible-lint settings (production profile)
    ├── site.yml                    Plays: WireGuard keys → Web Frontend → Video Streamer
    ├── group_vars/all.yml          Tunnel addressing and port
    └── templates/
        ├── nginx.conf.j2           RTMP ingest, publish auth, key-free logging
        ├── streamer.site.j2        /hls and /dash locations (+ optional TLS)
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
| `enable_tls` | `false` | Request a Let's Encrypt certificate and serve HTTPS (`true` in this deployment) |
| `acme_challenge` | `"dns"` | Ownership proof: `"dns"` (DNS-01 via Route 53) or `"http"` (HTTP-01 via port 80; used here) |
| `letsencrypt_staging` | `false` | Use Let's Encrypt's staging CA (no rate limits, untrusted certificates) |

---

## Known limitations
- **DNS-01 is blocked by a lab-side permission, so HTTPS uses HTTP-01.**
  - **The problem:** the `r53-devops` role's policy (`Letsencrypt-devops.intuitivesoft.cloud`, still v3) only allows `route53:ChangeResourceRecordSets` on two hosted zones that no longer exist. A certbot dry run fails with `AccessDenied` on `Z0316326GXOE1JMI1YJX`.
  - **Workaround in use:** `acme_challenge = "http"` (HTTP-01). It needs no AWS permissions, and the certificate is the same.
  - **To switch to the lab design:** once the policy includes the zone, set `acme_challenge = "dns"` and run `terraform apply`.
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
