# Security fixes from a self-audit

None of the automated scanners flagged these 3 weaknesses. Checkov only reads the Terraform code, and ansible-lint checks the playbook's style, not what the deployed programs are allowed to do. They were found by **reviewing the running system by hand**, then fixed in code, deployed with `terraform apply`, and verified live.

Date: 7 November 2026.

## Contents

- [Summary](#summary)
- [The plan](#the-plan)
- [Fix 1: ffmpeg ran as root](#fix-1-ffmpeg-ran-as-root)
- [Fix 2: the RTMP admin interface listened on every interface](#fix-2-the-rtmp-admin-interface-listened-on-every-interface)
- [Fix 3: security updates depended on servers being up at the right time](#fix-3-security-updates-depended-on-servers-being-up-at-the-right-time)
- [Deployment](#deployment)
- [How to check it yourself](#how-to-check-it-yourself)
- [What's left](#whats-left)

---

## Summary

| # | Problem | Risk | Fix | Principle | Verified result |
|---|---|---|---|---|---|
| 1 | ffmpeg ran as **root** with no restrictions | Medium | systemd sandbox: unprivileged temporary user, read-only system, system-call filter, network limited to one address | **Least privilege** | Exposure score **9.6 UNSAFE → 1.2 OK**; the stream key and WireGuard key are unreadable to ffmpeg; only `10.99.0.1` is reachable |
| 2 | The RTMP admin interface (no password) listened on **every interface** | Low | `listen 127.0.0.1:8080` | **Defence in depth**, minimal exposure | `0.0.0.0:8080 → 127.0.0.1:8080`; refused from the streamer through the tunnel |
| 3 | Security updates **3 days behind**: the daily timer rarely runs on servers stopped every night | Medium | Daily updates declared in code, **plus patching on every deployment**, plus a reboot when required | **Patch management** | Pending security updates: **10 → 0** on both servers |

---

## The plan

1. **Bring the servers back** after the nightly lab shutdown (`terraform apply`).
2. **Record the "before" state live**, rather than relying on reading the code.
3. **Fix each problem in code** (templates and playbook), and lint it with the pipeline's `ansible-lint` version (`production` profile).
4. **Deploy** with `terraform apply`. It notices the changed Ansible files and re-runs the playbook.
5. **Verify each fix live**, including **negative tests**: show that what should be blocked really is blocked.
6. **Update the documentation**: this file, [TEMPLATES.md](TEMPLATES.md), [PLAYBOOK.md](PLAYBOOK.md), [HOW-IT-WORKS.md](HOW-IT-WORKS.md) and the [README](../README.md).

---

## Fix 1: ffmpeg ran as root

### The problem

[`ffmpeg-stream.service.j2`](../ansible/templates/ffmpeg-stream.service.j2) had no `User=` line, so systemd ran ffmpeg as **root**.

ffmpeg parses complex media formats, and it regularly has security bugs (CVEs) in that code. A crafted media file exploiting such a bug would give an attacker **root on the streamer**. From there, they could:
- read the stream key;
- read the WireGuard private key, and impersonate the streamer;
- install anything.

The video is our own file, so the likelihood is low. But ffmpeg only needs to **read one file and send it to one address**. Anything more is unnecessary privilege.

### Before (live)

```
$ ps -o user=,comm= -C ffmpeg
root     ffmpeg

$ systemd-analyze security ffmpeg-stream.service
→ Overall exposure level for ffmpeg-stream.service: 9.6 UNSAFE 😨
```

### The fix

The `[Service]` section of the template now has a sandbox (each line is commented in the template):

| Setting | Effect |
|---|---|
| `DynamicUser=yes` | A **temporary unprivileged user**, created for this service only |
| `NoNewPrivileges=yes`, `CapabilityBoundingSet=` | Can never gain privileges, and holds no capabilities |
| `ProtectSystem=strict`, `ProtectHome=yes`, `PrivateTmp=yes`, `PrivateDevices=yes` | Read-only filesystem; no `/home`, no shared `/tmp`, no devices |
| `ProtectKernel*`, `ProtectControlGroups`, `ProtectClock`, `ProtectHostname`, `ProtectProc=invisible` | No kernel settings, modules or logs; can't see other processes |
| `RestrictNamespaces`, `RestrictRealtime`, `RestrictSUIDSGID`, `LockPersonality`, `MemoryDenyWriteExecute` | Blocks common exploit techniques |
| `SystemCallFilter=@system-service ~@privileged @resources` | Only the system calls a normal service needs |
| `RestrictAddressFamilies=AF_INET AF_UNIX` | IPv4 and local sockets only |
| `IPAddressDeny=any` + `IPAddressAllow=10.99.0.1` | **Can only connect to the frontend's tunnel address** |

**The stream key still works:** systemd reads the root-only `/etc/ffmpeg-stream.env` **before** dropping privileges, and passes the key to ffmpeg. ffmpeg itself can't read the file.

### After (live)

```
$ ps -o user=,comm= -C ffmpeg
ffmpeg-stream   ffmpeg                       ← a temporary user (uid 61444), not root

$ systemd-analyze security ffmpeg-stream.service
→ Overall exposure level for ffmpeg-stream.service: 1.2 OK 🙂
```

**Negative tests**, run as ffmpeg's user (uid 61444):

| Test | Result |
|---|---|
| Read `/etc/ffmpeg-stream.env` (the stream key) | **Permission denied** ✅ |
| Read `/etc/wireguard/private.key` | **Permission denied** ✅ |
| Connect to `10.99.0.1:1935` (the frontend's RTMP, through the tunnel) | Reachable ✅ (needed for the stream) |
| Connect to `192.168.0.148:3142` (the package proxy) | **Blocked** ✅ |
| Connect to `1.1.1.1:443` (the internet) | **Blocked** ✅ |

The network tests ran in a test unit with the same `DynamicUser` / `IPAddressDeny` / `IPAddressAllow` settings. `systemctl show` confirms the real unit has them: `IPAddressAllow=10.99.0.1/32`, `IPAddressDeny=0.0.0.0/0 ::/0`.

**The stream kept working:** the playlist at `https://bahey.devops.gin-telecom.ovh/hls/stream.m3u8` kept advancing (`stream-111.ts`, then `stream-125.ts`, then `stream-128.ts`), and the service has had 0 restarts since the change.

---

## Fix 2: the RTMP admin interface listened on every interface

### The problem

In [`nginx.conf.j2`](../ansible/templates/nginx.conf.j2), nginx-rtmp's control interface (`/control`: list streams, drop clients, **no password**) was declared with `listen 8080`, which means **every interface**.

| From | Before |
|---|---|
| The internet | Blocked by the security group ✅ |
| The VPC | Blocked by the security group ✅ |
| **Inside the WireGuard tunnel** (the streamer) | **Reachable** ⚠️ The security group only sees the encrypted UDP 51820 packets, not the traffic inside them. |

**The risk is low:** the streamer already sends the stream, so a compromised streamer could disrupt it anyway. But a password-less admin interface was protected by **a single layer**. One wrong security-group change would have exposed it to the internet. The README also stated it was "not reachable over the network", which wasn't accurate.

### Before (live)

```
web-frontend$ ss -ltn | grep 8080
LISTEN 0  511  0.0.0.0:8080  0.0.0.0:*
```

### The fix

```nginx
listen 127.0.0.1:8080;
```

nginx is **restarted**, not reloaded, so the listener really moves (a reload keeps the old sockets).

### After (live)

```
web-frontend$ ss -ltn | grep 8080
LISTEN 0  511  127.0.0.1:8080  0.0.0.0:*
```

| Test | Result |
|---|---|
| From the streamer: `10.99.0.1:8080` through the tunnel | **Refused** ✅ |
| From the streamer: `10.99.0.1:1935` (the stream) | Reachable ✅ |
| From the frontend itself: `http://127.0.0.1:8080/control/` | Answers ✅ (still usable by an admin logged in to the frontend) |

---

## Fix 3: security updates depended on servers being up at the right time

### The problem

Ubuntu installs security updates with a **daily timer** (`apt-daily-upgrade.timer`), and `unattended-upgrades` was on by default. **But the lab stops the servers every night**, and they're only up while someone works on them, so the timer rarely fires.

Two more weaknesses:
- **Nothing in our code declared it.** We relied on an Ubuntu default without saying so, and nobody would notice if it were off.
- **The streamer has no internet.** Whether its updates really worked through the package proxy had never been tested.

### Before (live)

```
apt-daily-upgrade.timer    LAST: Tue 2026-11-03 10:53   (3 days ago)

pending security updates, both servers:
  apt, apt-utils, libapt-pkg6.0, bind9-dnsutils, bind9-host, bind9-libs,
  ca-certificates, libmspack0, libpcre2-8-0, python3-twisted
```

`unattended-upgrade --dry-run` on the streamer **did** download packages through the proxy. So the mechanism worked; it just wasn't running often enough.

### The fix

A new **play 6, "Security updates (both hosts)"**, at the end of [`site.yml`](../ansible/site.yml):

| Task | Why |
|---|---|
| Install `unattended-upgrades` | Make sure the tool is there |
| Write `/etc/apt/apt.conf.d/20auto-upgrades` | **Declare** daily updates in code, instead of relying on the default |
| Run `unattended-upgrade --verbose` | **Patch on every deployment**, not only when the timer happens to fire. Retries for up to 5 minutes if another apt run holds the lock. |
| If `/var/run/reboot-required` exists, reboot | Kernel and core-library updates only take effect after a reboot. Every service is enabled at boot, so the platform comes back by itself. |

### After (live)

```
pending security updates:   web-frontend 0   video-streamer 0
reboot required:            no (on both)
20auto-upgrades:            Update-Package-Lists "1"; Unattended-Upgrade "1"; AutocleanInterval "7"
```

**Something real happened during the first deployment:** Ubuntu's own daily timer fired on the streamer at the same moment, and started installing the same 10 updates. Our task found apt **locked**, retried every 30 seconds, and succeeded as soon as Ubuntu's run finished ("All upgrades installed", about 2.5 minutes). Since that was right at the edge of the original 5×30 s window, the retry window was widened to 10×30 s (5 minutes).

**The streamer's updates came through the package proxy**, which confirms that the no-internet design still gets patched.

---

## Deployment

```
terraform apply
  → Ansible re-ran because the playbook and templates changed
  → PLAY RECAP: video-streamer  ok=22 changed=3 failed=0
                web-frontend    ok=41 changed=5 failed=0
  → Apply complete!
```

`ansible-lint` (the pipeline's pinned version, `production` profile): **0 failures, 0 warnings**.

**Changed files:**

| File | Change |
|---|---|
| [`ansible/templates/ffmpeg-stream.service.j2`](../ansible/templates/ffmpeg-stream.service.j2) | Sandbox (fix 1) |
| [`ansible/templates/nginx.conf.j2`](../ansible/templates/nginx.conf.j2) | `listen 127.0.0.1:8080` (fix 2) |
| [`ansible/site.yml`](../ansible/site.yml) | New play 6 (fix 3) |
| [`README.md`](../README.md), [`TEMPLATES.md`](TEMPLATES.md), [`PLAYBOOK.md`](PLAYBOOK.md), [`HOW-IT-WORKS.md`](HOW-IT-WORKS.md) | Updated; corrected the inaccurate "8080 not reachable" claim |

---

## How to check it yourself

```bash
cd ansible

# Fix 1: who runs ffmpeg, and its exposure score
ansible video-streamer -b -m shell -a 'ps -o user=,comm= -C ffmpeg; systemd-analyze security ffmpeg-stream.service | tail -1'

# Fix 2: where the admin interface listens
ansible web-frontend -b -m shell -a 'ss -ltn | grep 8080'

# Fix 3: pending security updates, and whether a reboot is needed
ansible all -b -m shell -a 'apt list --upgradable 2>/dev/null | grep -c security; ls /var/run/reboot-required 2>/dev/null || echo no reboot needed'
```

---

## What's left

- **Automatic reboots** only happen during a deployment. A kernel update installed by the daily timer waits for the next deployment, or for the nightly stop/start, which also loads it.
- **The other services** (nginx, apt-cacher-ng, WireGuard) use Ubuntu's own service settings. nginx's workers already run as the unprivileged `www-data` user. Sandboxing these further would be the next step.
- **Monitoring:** nothing alerts if updates start failing. That belongs with the monitoring and SIEM work.
