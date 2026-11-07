# Monitoring plan

**Status:** phases M1 (monitoring server) and M2 (metrics and dashboards) are built and verified; how they work is explained in [MONITORING.md](MONITORING.md). Phases M3 to M6 are not built yet. Kubernetes is deliberately left out for now.

This plan adds **monitoring, log collection and alerting** to the platform, on a **3rd server in the private subnet**. It follows the same rules as the rest of the project:
- built with Terraform + Ansible;
- deployed with one `terraform apply`;
- verified live;
- documented with evidence.

## Contents

- [Goals](#goals)
- [Constraints](#constraints)
- [Architecture](#architecture)
- [What will be monitored](#what-will-be-monitored)
- [Logs (SIEM-lite)](#logs-siem-lite)
- [Alerts](#alerts)
- [Security of the monitoring itself](#security-of-the-monitoring-itself)
- [Implementation phases](#implementation-phases)
- [Changes per file](#changes-per-file)
- [Cost](#cost)
- [Open decisions](#open-decisions)
- [Risks](#risks)
- [Later: chaos tests, load test, Kubernetes](#later-chaos-tests-load-test-kubernetes)

---

## Goals

1. **See the platform's health:** is the stream live, how loaded are the servers, when does the certificate expire.
2. **Collect the security logs in one place:** wrong stream keys, SSH logins, sudo, web scanners.
3. **Alert** when something is wrong, instead of finding out by chance.
4. **Make failures visible**, so that later chaos tests and load tests can be measured on graphs.
5. Close the **monitor → feedback** part of the DevSecOps loop.

---

## Constraints

| Constraint | Consequence |
|---|---|
| Frontend and streamer are **t3.micro** (~1 GB RAM, ~520 MB free) | The monitoring stack (~500 MB+) can't share them. It needs its own server, and the agents on the existing servers must be small. |
| t3.micro's CPU baseline is **10%**, with burst credits, in **unlimited** mode (never throttled; extra use is billed as "surplus credits") | Measured on 7 Nov: the streamer runs at **11–14% CPU** (ffmpeg re-encoding non-stop) and its credit balance was down to **17 of 288**. Once it reaches 0, AWS charges for the excess. Monitoring should track this **cost leak**. |
| **No internet in the private subnet** | The monitoring server installs Ubuntu packages through the frontend's package proxy. Software outside Ubuntu's repositories (Grafana, Loki, Alloy) is **downloaded on the laptop, checked against its published SHA-256 checksum, and uploaded**, like the video. |
| The lab **can't create IAM roles** | No CloudWatch exporter on the servers. The credit balance is read from the laptop with the AWS CLI; on the servers, CPU use is compared with the 10% baseline. |
| The lab **stops servers every night** | The monitoring server is stopped too. Graphs have gaps overnight; the data on disk is kept. |
| Alerts can't be sent out directly | The monitoring server has no internet, so email, Slack or Discord need a way out. See [open decisions](#open-decisions). |

---

## Architecture

```
                                 Internet
                                    │
┌─ VPC ─────────────────────────────┼────────────────────────────────────────┐
│ Public subnet 192.168.0.0/24      │                                        │
│  ┌────────────────────────────────┴───────────────────┐                    │
│  │ Web Frontend                                       │                    │
│  │  node_exporter :9100  ◀─── scraped ───────────────┐│                    │
│  │  stream-metrics (chunk age, publisher, viewers)   ││                    │
│  │  Alloy ── pushes logs ───────────────────────────┐││                    │
│  └──────────────────────────────────────────────────┼┼┘                    │
│                                                     ││                     │
│ Private subnet 192.168.1.0/24                       ││                     │
│  ┌────────────────────────┐   ┌─────────────────────▼▼──────────────────┐  │
│  │ Video Streamer         │   │ Monitoring (NEW, t3.small, no public IP) │  │
│  │  node_exporter :9100 ◀─┼───┤  Prometheus :9090  metrics, 15 days      │  │
│  │  Alloy ── logs ────────┼──▶│  Loki :3100        logs, 15 days         │  │
│  └────────────────────────┘   │  Grafana :3000     dashboards + alerts   │  │
│                               │  blackbox_exporter probes the site       │  │
│                               │  node_exporter (itself)                  │  │
│                               └──────────────────────▲───────────────────┘  │
└──────────────────────────────────────────────────────┼─────────────────────┘
                                                       │ SSH tunnel through the frontend
                                   laptop: http://localhost:3000 (Grafana)
```

| Choice | Why |
|---|---|
| **Separate server** | If the frontend crashes, monitoring still runs and can report it. Monitoring on the server it watches would go down with it. |
| **Private subnet, no public IP** | Grafana is never on the internet. You reach it through an SSH tunnel via the frontend (the same jump host Ansible uses). |
| **Pull for metrics** (Prometheus scrapes `node_exporter`) | The classic Prometheus model. A server that stops answering shows up as `up == 0`, which gives a "server down" alert for free. |
| **Push for logs** (Alloy → Loki) | Logs are streamed as they're written; the servers only need an **outbound** rule to Loki. |
| **Grafana Alloy** as the log agent | The successor to Promtail, which has reached end of life. |
| **"Monitoring as code"** | Data sources, dashboards and alert rules are provisioned from files in the repo, not clicked together in the Grafana UI. |

**How you'd open Grafana:**

```bash
ssh -i terraform/mss-key.pem -J ubuntu@<frontend_public_ip> \
    -L 3000:localhost:3000 ubuntu@<monitoring_private_ip>
# then open http://localhost:3000
```

Terraform will print this command as an output, like the existing `ssh_frontend` output.

---

## What will be monitored

### Server health (`node_exporter` on all 3 servers)

| Metric | Why it matters here |
|---|---|
| CPU use **compared with the 10% baseline** | Above 10% on average, a t3 spends credits, then (in unlimited mode) incurs surplus charges. The streamer is already slightly above it. |
| RAM, disk, network | The servers are small; disk fills with HLS chunks, logs and the package cache |
| Service states (`nginx`, `wg-quick@wg0`, `apt-cacher-ng`, `ffmpeg-stream`) | The systemd collector reports whether each one is running |
| Pending security updates, reboot required | Follows up on play 6 ([SECURITY-FIXES.md](SECURITY-FIXES.md)) |

### Stream health (a small collector on the frontend)

A short script, run every 15 s by a systemd timer, writes metrics to a file that `node_exporter` publishes (its **textfile collector**). This needs no extra open port and no third-party exporter.

| Metric | How |
|---|---|
| **Age of the newest HLS chunk** | Modification time of the newest file in `/var/www/html/stream/hls`. **The best "is the stream alive?" signal.** |
| Publisher connected, bitrate, number of viewers | nginx-rtmp's statistics page (`rtmp_stat`), read on **localhost only** |
| Wrong-key attempts | Count of `result=403` lines in `publish-auth.log` (also visible in Loki) |

### The website, from the outside (`blackbox_exporter` on the monitoring server)

| Probe | Checks |
|---|---|
| `https://<fqdn>/` over the private network, with the real server name | The site answers, TLS is valid, response time |
| `https://<fqdn>/hls/stream.m3u8` | The playlist is served |
| **Certificate expiry date** | Alert well before the Let's Encrypt certificate expires, in case renewal silently fails |

### CPU credits

Both servers are in **unlimited** credit mode (the t3 default): they are **never throttled**. Instead, sustained use above the 10% baseline is **billed** as surplus credits. So CPU "steal" time, the usual sign of throttling, stays at 0 and isn't a useful signal here.

The real credit balance only exists in CloudWatch, which the servers can't reach (no IAM permission, and the streamer has no internet). Plan:
- in Grafana: **average CPU over 24 h versus the 10% baseline**, the live signal;
- from the laptop, for the report: `aws cloudwatch get-metric-statistics` for `CPUCreditBalance` and `CPUSurplusCreditsCharged`.

**Measured on 7 Nov (last 3 h):**

| | CPU | Credit balance | Surplus charged |
|---|---|---|---|
| Streamer | 11–14% | 17 / 288 | 0 |
| Frontend | 5–9% | 288 / 288 | 0 |

Possible remedies, if it matters: stream the file without re-encoding (`-c copy`, if the source format allows it), lower the resolution or frame rate, or accept the small surplus cost.

---

## Logs (SIEM-lite)

**Alloy** on the frontend and the streamer ships these logs to **Loki**, labelled by server and source:

| Log | Server | What we look for |
|---|---|---|
| `/var/log/nginx/publish-auth.log` | Frontend | `result=403`: **wrong stream key** |
| `/var/log/auth.log` | Both | SSH logins (accepted and failed), `sudo` commands |
| `/var/log/nginx/access.log` | Frontend | Scanners: many 404s or odd paths from one IP |
| `/var/log/nginx/rtmp-access.log` | Frontend | Publisher connects and disconnects |
| systemd journal for `ffmpeg-stream` | Streamer | Crashes and restarts |
| `/var/log/unattended-upgrades/` | Both | Failed security updates |

**Secrets stay out:** the RTMP and auth logs already use key-free formats ([TEMPLATES.md](TEMPLATES.md)), so the stream key never reaches Loki.

**About fail2ban:** it isn't planned. SSH is already restricted to one IP by the security group, so internet brute force can't reach it. **Alerting** on any SSH failure is more useful here than banning.

---

## Alerts

Defined as code (Grafana alert rules provisioned from files):

| Alert | Condition | Severity |
|---|---|---|
| **Stream down** | Newest HLS chunk older than 30 s | Critical |
| **Server down** | `up == 0` for 1 minute | Critical |
| Service stopped | nginx, WireGuard, apt-cacher-ng or ffmpeg not active | Critical |
| **Wrong stream key** | ≥ 3 `result=403` in 5 minutes | Security |
| SSH login failure | Any failed SSH authentication | Security |
| SSH login | Any successful login (audit trail) | Info |
| Certificate expiring | Less than 14 days left | Warning |
| CPU above baseline | 24-hour average CPU > 10% (surplus credits likely) | Warning |
| Disk filling | Less than 15% free | Warning |
| Security updates failing | Pending security updates > 0 for 2 days | Warning |

**Where alerts go** is an [open decision](#open-decisions).

---

## Security of the monitoring itself

The monitoring server holds logs, so it's a target too. The same rules as the rest of the project apply:

| Measure | How |
|---|---|
| **Not public** | Private subnet, no public IP. Grafana only through the SSH tunnel. |
| **Least-privilege firewall** | A new `mss-monitoring` security group. Only the needed ports, between specific security groups (table below). |
| **No default passwords** | The Grafana admin password is a Terraform `random_password` (like the stream key), shown only as a sensitive output |
| **Encrypted disk** | The same KMS key (`alias/mss-ebs`), IMDSv2 required |
| **Verified downloads** | Grafana, Loki and Alloy are pinned to exact versions and checked against SHA-256 before installation (supply-chain protection) |
| **Sandboxed services** | Each service runs as its own unprivileged user with systemd hardening, as was done for ffmpeg |
| **Encrypted, authenticated agent traffic** | Phase M5: TLS and authentication for `node_exporter` and Loki, with a small private CA generated by Terraform's `tls` provider |
| **Scanned** | Checkov and ansible-lint cover the new code in the existing pipeline |

### New firewall rules

| Security group | Direction | Port | Peer | Why |
|---|---|---|---|---|
| `mss-monitoring` | in | TCP 22 | Frontend SG | Ansible and the Grafana tunnel, through the jump host |
| `mss-monitoring` | in | TCP 3100 | Frontend SG, streamer SG | Alloy pushes logs to Loki |
| `mss-monitoring` | out | TCP 9100 | Frontend SG, streamer SG | Prometheus scrapes `node_exporter` |
| `mss-monitoring` | out | TCP 443 | Frontend SG | blackbox probes of the site |
| `mss-monitoring` | out | TCP 3142 | Frontend SG | Package proxy |
| `mss-frontend` | in | TCP 9100, 443 | Monitoring SG | Scrape and probe (443 is already open to all) |
| `mss-frontend` | in | TCP 3142 | Monitoring SG | Package proxy for the new server |
| `mss-frontend` | out | TCP 3100 | Monitoring SG | Logs to Loki |
| `mss-streamer` | in | TCP 9100 | Monitoring SG | Scrape |
| `mss-streamer` | out | TCP 3100 | Monitoring SG | Logs to Loki |

The streamer's sandboxed ffmpeg stays limited to `10.99.0.1`. These rules are for the new agents only.

---

## Implementation phases

Each phase ends with **live verification** and a documentation update.

| Phase | Delivers | Verified by |
|---|---|---|
| **M1. Infrastructure** | Terraform: the instance, security group, rules, outputs (SSH and tunnel commands, Grafana password); the server added to the nightly restart (`aws_ec2_instance_state`). Ansible: a new play, the apt proxy, base packages. | SSH through the jump host works; the server has no internet; `terraform plan` clean; Checkov passes |
| **M2. Metrics** | `node_exporter` on all 3 servers; the stream-metrics collector; Prometheus; blackbox probes; Grafana with provisioned data sources and 2 dashboards (**Platform** and **Stream**) | All targets `up`; the dashboards show live data; stopping ffmpeg makes chunk age rise |
| **M3. Logs** | Alloy on the frontend and the streamer; Loki; a **Security** dashboard (wrong keys, SSH, sudo, scanners) | A test with a wrong key appears in Loki within seconds; an SSH login appears |
| **M4. Alerts** | The alert rules above, as code; the notification channel | Each critical and security alert is triggered on purpose and seen firing, then resolving |
| **M5. Hardening** | TLS + authentication between the agents and the servers; sandboxed services; `systemd-analyze security` scores | Unauthenticated scrapes and pushes are refused; exposure scores recorded |
| **M6. Documentation** | `docs/MONITORING.md` (how it works, with screenshots), README and guides updated | Review |

---

## Changes per file

| File | Change |
|---|---|
| `terraform/compute.tf` | `aws_instance.monitoring`, its `aws_ec2_instance_state` |
| `terraform/security.tf` | `aws_security_group.monitoring`, plus new rules on the frontend and streamer groups |
| `terraform/variables.tf` | `monitoring_instance_type` (default `t3.small`), `enable_monitoring` (on/off switch) |
| `terraform/outputs.tf` | Monitoring IP, SSH and Grafana-tunnel commands, Grafana password (sensitive) |
| `terraform/stream_key.tf` (or a new file) | `random_password.grafana_admin`; the private CA for M5 |
| `terraform/inventory.yml.tftpl`, `ansible.tf` | A `monitoring` group and host, through the jump host; new variables |
| `ansible/site.yml` | New plays: agents on the frontend and streamer, the monitoring server |
| `ansible/templates/` | `prometheus.yml.j2`, `loki.yml.j2`, `alloy.river.j2`, `blackbox.yml.j2`, Grafana provisioning files, `stream-metrics.sh.j2` + its timer, systemd units |
| `ansible/files/grafana/dashboards/` | Dashboard JSON files (Platform, Stream, Security) |
| `ansible/group_vars/all.yml` | Pinned versions and SHA-256 checksums of the downloaded software |
| `.github/workflows/security.yml` | Nothing new expected; the existing checks cover the new code |

---

## Cost

| Item | Approx. price (us-east-1) |
|---|---|
| t3.small, on demand | ~$0.021 / hour |
| 20 GB encrypted gp3 disk | ~$1.60 / month |
| A typical lab day (8 h running) | ~$0.17 |

The server is stopped every night with the others. `enable_monitoring = false` removes it entirely.

---

## Open decisions

1. **Where alerts are sent.** The monitoring server has no internet.

   | Option | Pros | Cons |
   |---|---|---|
   | **A. Grafana only** (alerts shown on the dashboard) | Nothing leaves the VPC; simplest | You only see alerts when you look |
   | **B. Discord or Slack webhook through a restricted proxy on the frontend** (allows one domain only) | Real notifications on your phone | One more component on the frontend; a narrow, controlled way out |
   | **C. Email through Amazon SES** | Standard | Probably blocked by the lab; needs credentials |

   **Recommendation:** start with A in phase M4, add B as an extension.

2. **Retention:** 15 days for metrics and logs (~a few GB). It could be longer with a bigger disk.

3. **Extra viewer analytics** (viewers over time, per country) from the nginx access logs: possible in M3, but not required.

---

## Risks

| Risk | Mitigation |
|---|---|
| The agents slow the t3.micro servers | `node_exporter` uses ~15 MB, Alloy ~60–100 MB; measured in M2/M3. If too heavy, fall back to a lighter log shipper. |
| Software downloads fail or change | Pinned versions and SHA-256 checks; a failed check stops the deploy |
| The streamer's ffmpeg sandbox interferes with the new agents | The agents are separate services; ffmpeg's network limits only apply to ffmpeg |
| Logs expose sensitive data | Key-free log formats are already in place; Loki is private and only reachable from the two servers |
| Monitoring itself fails silently | The "server down" alert covers the other servers; Grafana's own health shows on its dashboard |

---

## Later: chaos tests, load test, Kubernetes

Once monitoring exists:

- **Chaos tests:** kill ffmpeg, stop the tunnel, restart nginx, reboot the streamer, stop everything and re-apply. Measure the recovery time **on the Grafana graphs**.
- **Load test (k6):** simulate viewers against the frontend. Monitoring shows **where** it breaks (CPU, network, disk).
- **Kubernetes:** on hold. The load-test results would show whether it's worth it.
