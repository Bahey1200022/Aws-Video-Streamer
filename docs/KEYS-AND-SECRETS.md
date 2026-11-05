# Keys and secrets

Every key and secret used by the MSS streaming platform: what each one is for, where it's created and stored, how it's protected, how to rotate it, and what happens if it leaks.

See also: [HOW-IT-WORKS.md](HOW-IT-WORKS.md) · [README](../README.md)

---

## Summary

| Key | Purpose | In KMS? | Where it lives |
|---|---|---|---|
| **KMS key `alias/mss-ebs`** | Encrypts both EBS disks (frontend + backend) | ✅ Yes, the only one | Inside AWS KMS; never leaves it |
| **SSH key (`mss-key.pem`)** | Admin and Ansible login to the servers | ❌ | Private half: control machine + `terraform.tfstate`. Public half: the servers. |
| **Stream key** | Authorizes publishing the live stream | ❌ | `terraform.tfstate`, `ansible/inventory.yml`, root-only files on both servers |
| **WireGuard keys** | Encrypt and authenticate the backend → frontend tunnel | ❌ | Each server's `/etc/wireguard/private.key` (root-only) |
| **HTTPS private key** | Encrypts viewers' connections (TLS) | ❌ | Frontend, `/etc/letsencrypt/` (root-only) |
| **Let's Encrypt account key** | certbot's identity for issuing and renewing certificates | ❌ | Frontend, `/etc/letsencrypt/accounts/` (root-only) |

**In short:**
- **Only the disk-encryption key is in KMS.**
- **The other secrets** are generated where they're used, root-only, git-ignored, and kept out of logs.
- **At rest**, everything stored on the servers is covered by the KMS-encrypted disks.

---

## 1. KMS key `alias/mss-ebs`: disk encryption

| | |
|---|---|
| **Purpose** | Encrypts the root disk (EBS volume) of **both** servers **at rest** |
| **Type** | AWS KMS **customer-managed** symmetric key |
| **Created by** | Terraform, in [`terraform/kms.tf`](../terraform/kms.tf) |
| **Used in** | [`terraform/compute.tf`](../terraform/compute.tf): `root_block_device { encrypted = true, kms_key_id = aws_kms_key.ebs.arn }` |
| **Stored** | Inside AWS KMS (`us-east-1`). The key material **never leaves** KMS's hardware. |
| **Rotation** | Automatic, **yearly** (`enable_key_rotation = true`) |
| **Deletion** | 7-day waiting period (`deletion_window_in_days = 7`) |

### How it works: envelope encryption
1. Each disk has its own **data key**, stored **encrypted** alongside the disk.
2. At boot, the server's **Nitro storage card** asks KMS to decrypt that data key. **IAM** authorizes the request and **CloudTrail** logs it.
3. The card encrypts and decrypts every disk block on the fly. Ubuntu just sees a normal disk.

### Why it exists
- The disks hold sensitive files: the stream key, the HTTPS and WireGuard private keys, logs with viewers' IPs.
- **A leaked snapshot or copied volume is unreadable** without permission on the key.
- **It's a customer-managed key, not AWS's default `aws/ebs`.** That gives you:
  - control over its **key policy**;
  - **automatic yearly rotation**;
  - a **kill switch**: disabling the key makes every disk using it unreadable at once;
  - an **audit trail** of every use.
- **It meets the course** ("Ruggedized IaC", slide 26) and Checkov **`CKV_AWS_8`**, which both servers pass.

### Limits
- **It doesn't protect a running server.** While it's on, the disk is transparently unlocked; root on the server can read everything.
- **It doesn't protect the control machine's `terraform.tfstate`.**
- **Lab caveat:** the key policy trusts the whole AWS account through IAM. Every student shares the same `DevopsLab` role, so classmates could likely use the key too. A policy restricted to one SSO session would close that.

---

## 2. SSH key (`mss-key.pem`): server administration

| | |
|---|---|
| **Purpose** | Logging into the servers, for the administrator and for **Ansible** |
| **Type** | Ed25519 **key pair** |
| **Created by** | Terraform (`tls_private_key.ssh` in [`terraform/compute.tf`](../terraform/compute.tf)) |
| **Private half** | `terraform/mss-key.pem` (`0600`, git-ignored) and `terraform.tfstate` on the control machine |
| **Public half** | Registered in AWS as the key pair `mss-key`, then installed in `~ubuntu/.ssh/authorized_keys` on both servers at first boot |
| **Sent over the network?** | ❌ Never. SSH proves possession of the key with a signature. |

### Protections
- **Key-only login:** no passwords to guess or brute-force.
- **The frontend accepts SSH only from the administrator's current public IP** (security group).
- **The backend accepts SSH only from the frontend** (the jump-host / bastion pattern).

### Rotation
```bash
terraform apply -replace=tls_private_key.ssh \
                -replace=aws_instance.frontend -replace=aws_instance.streamer
```
- **The servers must be replaced in the same apply.** AWS only installs the public key at a server's first boot.
- ⚠️ **Never replace the key alone.** The key pair keeps the same name (`mss-key`), so Terraform wouldn't rebuild the servers. They'd keep the **old** public key, while the control machine has the **new** private key, which locks out SSH and Ansible.

### If it leaks
An attacker would **also** need to connect from the administrator's IP to reach port 22. Rotate the key, which rebuilds the servers.

---

## 3. Stream key: who may publish the stream

| | |
|---|---|
| **Purpose** | Authorizes the Video Streamer to **publish** the live stream (application-level authentication) |
| **Type** | **Shared secret** (password): 32 random alphanumeric characters (about 190 bits) |
| **Created by** | Terraform (`random_password.stream_key` in [`terraform/stream_key.tf`](../terraform/stream_key.tf)) |
| **Stored** | See the table below |
| **Sent over the network?** | ✅ Yes, in the RTMP URL (`rtmp://10.99.0.1:1935/live/stream?key=…`), but **only inside the WireGuard tunnel** |

**Where it's stored:**
| Location | Notes |
|---|---|
| `terraform.tfstate` and `ansible/inventory.yml` | Control machine, git-ignored |
| `/etc/nginx/nginx.conf` | Frontend, `0600` |
| `/etc/ffmpeg-stream.env` | Backend, `0600`. The world-readable systemd unit only refers to `${STREAM_KEY}`. |

### Protections
- **nginx-rtmp checks every publish attempt** against the key, through a **localhost-only** auth endpoint.
- **Every attempt is logged** (`/var/log/nginx/publish-auth.log`), **never with the key**. The RTMP access log uses a key-free format.
- **Only the stream name `stream`** with the right key is accepted.
- **Publishing is also restricted to the WireGuard address** `10.99.0.2`.

### Rotation
```bash
terraform apply -replace=random_password.stream_key
```
Ansible installs the new key on both servers and restarts the stream. The old key stops working immediately.

### If it leaks
An attacker would **also** need to be inside the WireGuard tunnel to reach the RTMP server. Rotate it with one command.

---

## 4. WireGuard keys: the encrypted ingest tunnel

| | |
|---|---|
| **Purpose** | **Encrypt** the backend → frontend stream, and **authenticate** each end of the tunnel |
| **Type** | Curve25519 **key pair per server** (private + public) |
| **Created by** | **Each server itself**, in Ansible play "WireGuard keys" (`wg genkey`, `umask 077`) |
| **Private key** | `/etc/wireguard/private.key` on each server (root-only). It **never leaves** the server, isn't in `wg0.conf`, and isn't in any Ansible variable. |
| **Public key** | Shared with the other server through Ansible, written into its `wg0.conf` as `[Peer] PublicKey` |
| **Sent over the network?** | ❌ Never. Only used to compute the encryption. |

### Protections
- **Only the holder of a registered private key** can use the tunnel, so nobody can impersonate either server.
- **Packet captures show only encrypted UDP 51820.** Before WireGuard, the stream key was visible 4 times in a capture; with WireGuard, 0 times.

### Rotation
1. Delete `/etc/wireguard/private.key` on a server.
2. Run `terraform apply`. Ansible generates a new key and updates the peer's config.

### If it leaks
An attacker could pose as that server **inside the tunnel**, but would still need the stream key to publish. Rotate the key.

---

## 5. HTTPS certificate private key: viewers' encryption

| | |
|---|---|
| **Purpose** | Encrypts connections between viewers' browsers and the site (TLS 1.2/1.3), and proves the server's identity |
| **Type** | The private key of the **Let's Encrypt certificate** for `bahey.devops.gin-telecom.ovh` |
| **Created by** | **certbot** on the frontend, when requesting or renewing the certificate (HTTP-01 challenge) |
| **Stored** | `/etc/letsencrypt/live/<name>/privkey.pem` on the frontend (root-only); loaded by nginx |
| **Sent over the network?** | ❌ Never. Only the certificate (the public part) is sent to browsers. |

### Rotation
Automatic. certbot renews the certificate about every 60 days, with a **new private key** at each renewal, and a deploy hook restarts nginx.

### If it leaks
An attacker could impersonate the site to visitors whose traffic they intercept. Revoke the certificate with `certbot revoke`, and request a new one.

---

## 6. Let's Encrypt account key: certbot's identity

| | |
|---|---|
| **Purpose** | Identifies the frontend's certbot to Let's Encrypt when issuing, renewing or revoking certificates |
| **Type** | Key pair, created on first registration (`--register-unsafely-without-email`) |
| **Stored** | `/etc/letsencrypt/accounts/` on the frontend (root-only) |
| **Sent over the network?** | ❌ Never. Requests to Let's Encrypt are **signed** with it. |

### If it leaks
An attacker could manage certificates **under this account**, but issuing a certificate for the domain would **still** require passing the domain challenge.

---

## Stream key vs. WireGuard keys

They protect two different layers of the same stream:

| | Stream key | WireGuard keys |
|---|---|---|
| **Kind** | One **shared password** | A **key pair** per server |
| **Question it answers** | "May this publisher **publish**?" | "Is this packet **really from the other server**, and can anyone else read it?" |
| **Layer** | Application (nginx-rtmp) | Network (the tunnel) |
| **Who knows it** | **Both** servers know the same value | Each server knows **only its own** private key |
| **Created** | On the control machine (Terraform) | **On each server** |
| **Travels on the network** | Yes, **inside** the tunnel | Never |

**Defense in depth:** nginx accepts the stream only if **both** checks pass. It must arrive through the tunnel (`allow publish 10.99.0.2`) **and** carry the right key (`on_publish`).

| An attacker has… | Can they publish? |
|---|---|
| Only the stream key | ❌ They can't enter the tunnel |
| Only the backend's WireGuard key | ❌ nginx rejects them without the stream key |
| Both | ✅ So both would have to leak, from different places |

---

## Where secrets are deliberately kept out

| Place | How |
|---|---|
| **git** | `.gitignore` (`*.tfstate`, `*.pem`, `inventory.yml`, `secrets.auto.tfvars`), plus **gitleaks** in the pre-commit hook and in the CI pipeline (no leaks in the history) |
| **Logs** | Key-free nginx log formats; the publish-auth log records the address, app, channel and result only |
| **World-readable files** | Secrets in `0600` root-only files; systemd units only reference variables |
| **Terraform output** | Sensitive outputs (`stream_key`) are hidden in plan and apply output |
| **Process lists / command lines** | Keys are read from files or environment variables, not passed as visible arguments where avoidable |

## Remaining exposure
- **`terraform.tfstate` on the control machine** holds the SSH private key and the stream key **in plain text**.
- **Mitigations today:** it's git-ignored, and the laptop's disk should be encrypted.
- **Better:** remote state in an **S3 bucket encrypted with a KMS key**, with locking and versioning.

---

## Slide version

- **KMS key `alias/mss-ebs`**
  - Encrypts both EBS disks (frontend + backend)
  - Lives in AWS KMS and never leaves it; yearly rotation
- **SSH key (`mss-key.pem`)**
  - Admin and Ansible login to the servers
  - Generated by Terraform; private half on the laptop, public half on the servers
- **Stream key**
  - Authorizes publishing the live stream
  - Generated by Terraform; root-only files on both servers
- **WireGuard keys**
  - Encrypt and authenticate the backend → frontend tunnel
  - Generated on each server; the private key never leaves it
- **HTTPS private key**
  - Encrypts viewers' connections (TLS)
  - Issued with the Let's Encrypt certificate; root-only on the frontend
- **Let's Encrypt account key**
  - certbot's identity for issuing and renewing the certificate
  - Root-only on the frontend
- **Takeaways**
  - Only the disk-encryption key is in KMS
  - Other secrets: generated where used, root-only, git-ignored, kept out of logs
  - At rest, everything on the servers is covered by the KMS-encrypted disks
