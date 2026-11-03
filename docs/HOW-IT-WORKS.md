# How the project works

A file-by-file guide to the MSS live-streaming platform. It covers:
- how one `terraform apply` builds and configures everything;
- what each file does;
- what happens at runtime.

For setup and usage, see the [README](../README.md).

---

## Part 1: The big picture

There are two phases, both started by one command:

```
terraform apply
 │
 ├─ PHASE 1: Terraform builds the AWS infrastructure
 │    firewalls, 2 servers, encrypted disks, DNS record, SSH key, secrets
 │
 └─ PHASE 2: Terraform runs Ansible, which configures the servers
      installs nginx / ffmpeg / WireGuard, writes configs,
      gets the HTTPS certificate, starts the stream
```

At runtime, the video flows like this:

```
Video Streamer (private subnet) ──WireGuard (encrypted)──▶ Web Frontend (public subnet) ──HTTPS──▶ viewers
ffmpeg loops the film                                       nginx-rtmp → HLS/DASH chunks
```

---

## Part 2: Every file

### Repository root

| File | What it does |
|---|---|
| `README.md` | The project's documentation: architecture, features, security, usage, verification |
| `docs/HOW-IT-WORKS.md` | This guide |
| `.pre-commit-config.yaml` | Runs **gitleaks** on the developer's machine **before every commit**, so a secret never even enters git |
| `.github/workflows/security.yml` | The **security pipeline**: on every push and pull request, GitHub runs 4 jobs (Terraform fmt/validate, Checkov, gitleaks, ansible-lint). Any problem turns the run red. |

### `terraform/`: builds the infrastructure (phase 1)

Terraform reads **all** `.tf` files in the folder as one configuration and works out the order itself from the references between resources.

| File | What it does |
|---|---|
| `versions.tf` | Declares the plugins (providers): `aws`, `tls` (SSH key), `local` (writes files), `http` (detects the admin's IP), `random` (generates secrets). Sets the AWS region. |
| `variables.tf` | The **settings** that can be changed: VPC id, subnet names, domain, hostname, instance size, HTTPS options (`enable_tls`, `acme_challenge`, `letsencrypt_staging`) |
| `terraform.tfvars` | **The values** for those settings: the existing VPC, the `devops.gin-telecom.ovh` zone, the hostname `bahey`, HTTPS on via HTTP-01 |
| `terraform.tfvars.example` | A template showing which values to fill in |
| `network.tf` | **Looks up** the existing VPC and its two subnets (they aren't created here). Creates the **private route table** (`0.0.0.0/0 → frontend`), which is how the streamer reaches the internet through the NAT. Detects the **admin's public IP** for the SSH rule. |
| `security.tf` | The **two firewalls** (security groups), detailed below |
| `iam.tf` | Looks up the Route 53 hosted zone and the lab's **`r53-devops`** instance profile (the lab account can't create IAM roles) |
| `kms.tf` | Creates a **customer-managed KMS key** (yearly rotation, explicit key policy) used to **encrypt both servers' disks** |
| `stream_key.tf` | Generates the **32-character stream key** the streamer needs to publish |
| `compute.tf` | The core, detailed below |
| `nat.sh` | The frontend's **boot script**: turns on IP forwarding and **iptables MASQUERADE**, making the frontend a router (NAT) for the private subnet. Installed as a systemd service, so it survives restarts. |
| `inventory.yml.tftpl` | A **template** for Ansible's inventory: server IPs, the SSH key, the jump host used to reach the streamer, and variables (domain, stream key, HTTPS settings) |
| `ansible.tf` | **Phase 2:** fills the inventory template, writes `ansible/inventory.yml`, then **runs `ansible-playbook site.yml`**. It re-runs whenever a server, the inventory or any Ansible file changes. |
| `outputs.tf` | What's printed at the end: IPs, the domain, the SSH command, the site URL, the stream key (hidden, marked sensitive) |
| `.terraform.lock.hcl` | Pins the exact provider versions (supply-chain safety) |
| `.gitignore` | Keeps secrets out of git: state files, `.pem`, local secrets files |

**`security.tf`, the two firewalls:**
| Server | Allowed in | Allowed out |
|---|---|---|
| Frontend | 80/443 from anyone; 22 from the admin's IP only; WireGuard and the NAT'd 80/443 from the private subnet | 80/443 to the internet; SSH to the streamer |
| Streamer | SSH from the frontend only | WireGuard to the frontend; 80/443 (through the NAT) |

**`compute.tf` creates:**
- the **Ubuntu 22.04 image** lookup;
- the **SSH key**, saved as `mss-key.pem`;
- **both servers**, with encrypted disks, IMDSv2, the frontend's public IP, the NAT settings and the boot script;
- **auto-start** after the nightly shutdown;
- the current **public IP**;
- the **DNS record** `bahey.devops.gin-telecom.ovh`.

It also holds the documented Checkov skips.

Generated, and **never committed** (git-ignored):
- **`terraform.tfstate`**: Terraform's memory of what exists, including secrets;
- **`mss-key.pem`**: the SSH key.

### `ansible/`: configures the servers (phase 2)

| File | What it does |
|---|---|
| `ansible.cfg` | Ansible settings: the inventory location, a 60 s connection timeout (for the jump host), `force_handlers` |
| `.ansible-lint` | Lint rules (strictest "production" profile), used locally and by the pipeline |
| `group_vars/all.yml` | Shared values: WireGuard addresses (`10.99.0.1`/`10.99.0.2`, port 51820), the **video** to loop (Elephants Dream), the certificate name |
| `inventory.yml` | **Generated by Terraform**; never committed (it contains the stream key) |
| `site.yml` | **The playbook**: all the steps, in 3 plays (below) |

#### `site.yml`, the 3 plays

**Play 1: WireGuard keys (both servers)**
1. Wait for SSH, and for the boot script (NAT) to finish.
2. Install WireGuard.
3. **Generate a private key on each server.** It never leaves that server.
4. Share only the **public** keys between the two servers.

**Play 2: Web Frontend**
1. Install **nginx, nginx-rtmp and ffmpeg**.
2. Configure and start **WireGuard**, listening for the streamer.
3. Create the chunk folders (`/var/www/html/stream/hls` and `dash`).
4. **HTTPS:**
   - install certbot;
   - request the **Let's Encrypt** certificate (HTTP-01);
   - add a hook that restarts nginx after each renewal.
5. Write the **nginx configs**, enable the site, remove the default site, then **validate them with `nginx -t`**.
6. Install the **player page**.
7. Clean up leftovers from removed experiments (camera, weather, Stream Studio/Docker).
8. **Safety nets:**
   - nginx only restarts if its config is valid;
   - nginx is restarted if its running config is older than the config files.

**Play 3: Video Streamer**
1. Install ffmpeg.
2. **Download the film on the control machine** (Blender blocks AWS addresses) and upload it to the streamer.
3. Configure and start **WireGuard**, connecting to the frontend.
4. Install the **stream key** (root-only file) and the **ffmpeg service**, then start it.

**Handlers** are steps that only run when something changed: restarting WireGuard, nginx or the stream.

#### `ansible/templates/`: the config files written onto the servers

`.j2` files are **Jinja2 templates**: their `{{ variables }}` are filled in for each server.

| Template | Becomes | What it does |
|---|---|---|
| `nginx.conf.j2` | `/etc/nginx/nginx.conf` (frontend) | The RTMP server and the publish check, detailed below |
| `streamer.site.j2` | `/etc/nginx/sites-available/streamer` | The website, detailed below |
| `index.html.j2` | `/var/www/html/index.html` | The **player page**: LIVE badge, HLS/DASH switch, playback stats, auto-reconnect. hls.js and dash.js are pinned with **Subresource Integrity** hashes. |
| `wg0.conf.j2` | `/etc/wireguard/wg0.conf` (both servers) | The **WireGuard tunnel**: the server's own tunnel address, the listening port (frontend), and each peer's public key and address. The private key is loaded from a separate file and never written here. |
| `ffmpeg-stream.service.j2` | `/etc/systemd/system/ffmpeg-stream.service` (streamer) | Runs ffmpeg **forever**: loops the film, encodes H.264/AAC, and pushes to `rtmp://10.99.0.1:1935/live/stream?key=$STREAM_KEY` **through the tunnel**. Restarts if it stops. |
| `ffmpeg-stream.env.j2` | `/etc/ffmpeg-stream.env` (root-only) | Holds the **stream key**, so it isn't in the world-readable service file |

**`nginx.conf.j2`, the RTMP side:**
- **An RTMP server on port 1935** receives the stream.
- **It only accepts** a publisher on the WireGuard address `10.99.0.2`, **with the stream key**.
- The key is checked by an internal endpoint on `127.0.0.1:8081`, which logs every attempt **without the key**.
- **It cuts the video** into HLS (3 s) and DASH (15 s) chunks.
- **It logs without the key**, and its control page listens on localhost only.

**`streamer.site.j2`, the website:**
- **Port 80** redirects to **HTTPS**, except the Let's Encrypt challenge path.
- **Port 443** uses the certificate, with TLS 1.2/1.3 and HSTS.
- **It serves** the player page, `/hls` and `/dash`.
- **It blocks** the raw `/stream/` folder.

---

## Part 3: What happens at runtime

### A. The video's journey
1. **The Video Streamer:** ffmpeg reads the film in a loop, at real speed.
2. It pushes RTMP to `10.99.0.1:1935`. Because of the WireGuard tunnel, the packets cross the VPC **encrypted**, inside UDP port 51820.
3. **The Web Frontend:** nginx-rtmp receives the stream and checks two things:
   - is the sender `10.99.0.2` (the tunnel)?
   - is the stream key correct?

   Only then is the stream accepted.
4. nginx-rtmp continuously writes **chunk files** and a **playlist** (`stream.m3u8`) into `/var/www/html/stream/hls` (and the DASH equivalent).

### B. A viewer's journey
1. The browser looks up `bahey.devops.gin-telecom.ovh` → **Route 53** → the frontend's public IP.
2. `http://` → **301** → `https://`. The TLS certificate comes from **Let's Encrypt**.
3. The player page loads, then:
   - downloads `/hls/stream.m3u8`;
   - downloads and plays the chunks it lists;
   - checks the playlist again every few seconds.

   That's why it looks live, with a few seconds of latency.

### C. How the Video Streamer reaches the internet (NAT)
1. The streamer has no public IP. Its route table sends `0.0.0.0/0` to the **frontend's network interface**.
2. On the frontend, AWS's source/destination check is turned off (`source_dest_check = false`), so it may forward traffic that isn't addressed to itself.
3. Linux forwards the packet and **MASQUERADEs** it (`nat.sh`), replacing the streamer's private address with the frontend's.
4. The **Internet Gateway** maps the frontend to its public IP.
5. Replies come back the same way.

Nobody on the internet can open a connection to the streamer: NAT only lets replies back in. The streamer only uses the internet for package installs and updates.

**Proof, on the streamer:** `curl https://checkip.amazonaws.com` prints the **frontend's** public IP.

### D. The HTTPS certificate (HTTP-01)
1. certbot asks Let's Encrypt for a certificate for `bahey.devops.gin-telecom.ovh`.
2. It writes a token into `/var/www/html/.well-known/acme-challenge/`.
3. Let's Encrypt downloads that token over port 80, proving we control the site.
4. The certificate is issued. certbot's timer **renews it automatically** about every 60 days.

**DNS-01** (the lab diagram's method, proving ownership with a TXT record in Route 53) is implemented too (`acme_challenge = "dns"`). But the lab's `r53-devops` policy only allows two deleted hosted zones, so it gets `AccessDenied`. The certificate is identical either way.

### E. The nightly shutdown
The lab stops all servers at midnight. The next `terraform apply`:
- **starts** them (`aws_ec2_instance_state`);
- reads their **new public IP**;
- updates **DNS** and the **inventory**;
- re-runs Ansible.

### F. The security layers in one view

| Layer | Mechanism | Files |
|---|---|---|
| Network | Private subnet, NAT, firewalls in **and** out | `network.tf`, `security.tf`, `nat.sh` |
| Ingest encryption | WireGuard tunnel | `wg0.conf.j2`, `site.yml` (play 1) |
| Ingest identity | Tunnel-only publisher address + stream key | `nginx.conf.j2`, `stream_key.tf` |
| Viewer encryption | HTTPS, TLS 1.2+, HSTS | `streamer.site.j2`, `site.yml` |
| Credentials | IAM role (no stored AWS keys), IMDSv2 required | `compute.tf`, `iam.tf` |
| Data at rest | KMS-encrypted disks, customer-managed key | `kms.tf`, `compute.tf` |
| Secrets | Generated by Terraform, root-only files, git-ignored, kept out of logs | `stream_key.tf`, templates, `.gitignore` |
| Supply chain | Pinned versions, SRI hashes, checksum-verified downloads | `.terraform.lock.hcl`, `index.html.j2`, `security.yml` |
| Shift-left | Checkov, gitleaks, ansible-lint, pre-commit | `.github/workflows/security.yml`, `.pre-commit-config.yaml` |
