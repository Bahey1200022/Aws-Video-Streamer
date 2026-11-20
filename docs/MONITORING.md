# Monitoring: how it works

**Status:** phases M1 (monitoring server), M2 (metrics and dashboards) and M3 (logs) are built and verified live. Alerts (M4) and hardening (M5) are not built yet; see [MONITORING-PLAN.md](MONITORING-PLAN.md).

This guide explains, in simple terms:
- what Prometheus, node_exporter, Loki, Alloy and Grafana are;
- how every number and every log line on the dashboards is collected;
- where each step is in the code.

For setup and usage of the whole project, see the [README](../README.md).

## Contents

- [The big picture](#the-big-picture)
- [Prometheus in 4 ideas](#prometheus-in-4-ideas)
- [How node_exporter gives the numbers to Prometheus (4 steps)](#how-node_exporter-gives-the-numbers-to-prometheus-4-steps)
- [Where each number comes from](#where-each-number-comes-from)
- [The MSS - Platform dashboard, panel by panel](#the-mss---platform-dashboard-panel-by-panel)
- [The MSS - Stream dashboard](#the-mss---stream-dashboard)
- [How the website probe works](#how-the-website-probe-works)
- [Logs: Loki and Alloy](#logs-loki-and-alloy)
- [The MSS - Security dashboard](#the-mss---security-dashboard)
- [The stream key leak (found and fixed)](#the-stream-key-leak-found-and-fixed)
- [Opening Grafana](#opening-grafana)
- [Security of the monitoring](#security-of-the-monitoring)
- [Files that make up the monitoring](#files-that-make-up-the-monitoring)
- [Problems found during deployment](#problems-found-during-deployment)
- [Verification (live)](#verification-live)

---

## The big picture

A 3rd server, **mss-monitoring**, sits in the private subnet. It has no public IP and no internet access. It runs 4 programs:

| Program | Role | Listens on |
|---|---|---|
| **Prometheus** | Collects numbers every 15 s and keeps 15 days of history | `127.0.0.1:9090` |
| **blackbox_exporter** | Loads the website like a visitor and reports the result as numbers | `127.0.0.1:9115` |
| **Loki** | Stores the log lines pushed by the servers, 15 days | `192.168.1.25:3100` (private IP: the servers push to it) |
| **Grafana** | Draws the dashboards by asking Prometheus and Loki questions | `127.0.0.1:3000` |

Every server also runs 2 agents:
- **node_exporter** publishes the server's numbers on port 9100 (Prometheus pulls them);
- **Alloy** reads the server's logs and pushes them to Loki.

```
                 mss-monitoring (private, no internet)
      ┌──────────────────────────────────────────────────────┐
      │ Prometheus :9090 ── every 15 s scrapes ─┬─► node_exporter :9100 (itself)
      │      ▲                                  ├─► blackbox_exporter :9115
      │      │ PromQL                           │        └─► GET https://frontend/ and /hls/stream.m3u8
      │ Grafana :3000 ◄── SSH tunnel ── you     │
      └─────────────────────────────────────────┼────────────┘
                                                ├─► frontend  node_exporter :9100
                                                │      └ + file mss_stream.prom (written every 15 s
                                                │          by mss-stream-metrics, which reads nginx /stat
                                                │          and the HLS folder)
                                                └─► streamer  node_exporter :9100
```

**Prometheus pulls numbers.** The servers never send numbers on their own; Prometheus visits them. If a server stops answering, Prometheus notices right away.

**Logs are pushed.** Alloy on each server sends every new log line to Loki as soon as it's written (see [Logs: Loki and Alloy](#logs-loki-and-alloy)).

```
frontend   Alloy ──push :3100──►┐
streamer   Alloy ──push :3100──►├──► Loki (mss-monitoring) ◄── LogQL ── Grafana
monitoring Alloy ──push──────────┘
```

---

## Prometheus in 4 ideas

### 1. A metric is a name, some labels, and a number

```
node_memory_MemAvailable_bytes{server="web-frontend"}  576212992
└───────── name ─────────────┘└──── label ──────────┘  └ value ┘
```

Labels say which server, page or service a number belongs to.

### 2. An exporter is a program that shows numbers as a web page

node_exporter reads the system (CPU, RAM, disk, network, services…) and publishes it as plain text:

```
$ curl http://192.168.0.148:9100/metrics
node_cpu_seconds_total{cpu="0",mode="idle"} 8951.56
node_memory_MemAvailable_bytes 5.69905152e+08
node_systemd_unit_state{name="nginx.service",state="active"} 1
mss_rtmp_publishing 1
...                                    (about 1100 lines)
```

An exporter is just a page of `name value` lines.

### 3. Prometheus visits those pages every 15 s and keeps a history

Each visit is called a **scrape**. Every value is saved with a timestamp, so Prometheus can answer "what was the CPU over the last 24 h?". History is kept for **15 days**.

If a page doesn't answer, Prometheus records `up = 0`. That's how a dead server is detected: a dead server can't report that it's dead, but its silence shows it.

### 4. PromQL is the question language, and Grafana asks the questions

Every panel on a dashboard is one PromQL question. There are 2 kinds of numbers:

| Kind | Examples | How a panel uses it |
|---|---|---|
| **Snapshot**: the value right now | memory, disk, updates, reboot, services, `up` | shows it, or divides it (used ÷ total) |
| **Counter**: a total that only grows | CPU seconds, network bytes | `rate()`: how fast it grew per second |

---

## How node_exporter gives the numbers to Prometheus (4 steps)

```
STEP 1 Ansible installs node_exporter      STEP 3 the firewall lets only the monitoring server in
        on each server (site.yml)                  (security.tf + monitoring.tf)
               │                                              │
               ▼                                              ▼
   frontend: node_exporter  ◄────── GET :9100/metrics ────── Prometheus (monitoring server)
   publishes ~1100 lines                every 15 s                   │
   on 192.168.0.148:9100                                             ▼
               ▲                                         saves every line with a timestamp
STEP 2 Ansible tells it what to collect              STEP 4 prometheus.yml says which addresses
        and where to listen (site.yml)                      to visit (prometheus.yml.j2)
```

### Step 1: install node_exporter on every server

In [ansible/site.yml](../ansible/site.yml), play 7 "Monitoring agents (all servers)" runs on `hosts: all`:

```yaml
- name: Install node_exporter (and its apt / reboot-required collectors)
  ansible.builtin.apt:
    name: prometheus-node-exporter
```

This is the normal Ubuntu package. It runs as a service and reads Linux's own files (`/proc/stat`, `/proc/meminfo`, the disks, the network card).

### Step 2: tell it where to listen and what extra to collect

The same play builds the settings:

```yaml
node_exporter_args: >-
  --web.listen-address={{ node_exporter_address }}:9100      # address and port of the page
  --collector.systemd                                         # also report services...
  --collector.systemd.unit-include={{ monitored_units }}      # ...only these ones
  --collector.textfile.directory={{ textfile_dir }}           # ...and copy the *.prom files from this folder
```

They are written to `/etc/default/prometheus-node-exporter`, which the service reads at startup. On the frontend, the result is:

```
ARGS="--web.listen-address=192.168.0.148:9100 --collector.systemd ... --collector.textfile.directory=/var/lib/prometheus/node-exporter"
```

- **`node_exporter_address`** picks the address per server: the **private** IP on the frontend and the streamer, and `127.0.0.1` on the monitoring server (it only reads itself). The page is never on the internet-facing side.
- **`monitored_units`** (in [ansible/group_vars/all.yml](../ansible/group_vars/all.yml)) lists the services to report: nginx, WireGuard, apt-cacher-ng, ffmpeg-stream, and the monitoring services.
- **The textfile folder** is how our own numbers get in. Any `*.prom` file in `/var/lib/prometheus/node-exporter` is added to the page:
  - `apt.prom`: written every 15 minutes by a script that comes with the Ubuntu package (pending updates, reboot required);
  - `mss_stream.prom`: written every 15 s by our stream script (see [The MSS - Stream dashboard](#the-mss---stream-dashboard)).

### Step 3: open the firewall only for the monitoring server

On the frontend and streamer side, [terraform/security.tf](../terraform/security.tf):

```hcl
dynamic "ingress" {
  for_each = local.monitoring_sg_ids          # empty if monitoring is turned off
  content {
    description     = "node_exporter scraped by Prometheus (monitoring server)"
    from_port       = 9100
    to_port         = 9100
    protocol        = "tcp"
    security_groups = [ingress.value]         # only the monitoring server's group
  }
}
```

On the monitoring server's side, [terraform/monitoring.tf](../terraform/monitoring.tf) allows it to go **out** to port 9100 on both subnets.

The internet can't see these numbers, and the streamer can't read the frontend's. Only the monitoring server can.

`dynamic` means "add this rule only if monitoring is enabled". With `enable_monitoring = false`, the list is empty and the rules disappear.

### Step 4: tell Prometheus which pages to visit

[ansible/templates/prometheus.yml.j2](../ansible/templates/prometheus.yml.j2):

```yaml
global:
  scrape_interval: 15s                    # visit every 15 seconds

scrape_configs:
  - job_name: node
    static_configs:
      - targets: ["{{ frontend_private_ip }}:9100"]
        labels: { server: web-frontend }
      - targets: ["{{ hostvars['video-streamer'].ansible_host }}:9100"]
        labels: { server: video-streamer }
      - targets: ["127.0.0.1:9100"]
        labels: { server: monitoring }
```

For each target, Prometheus does `GET http://<target>/metrics` every 15 s and saves every line. It also adds the `server="…"` label, which is how Grafana shows numbers per server.

**In one sentence:** node_exporter turns Linux's numbers into a web page on port 9100, and Prometheus visits that page every 15 seconds and keeps every number. Ansible sets up both sides; Terraform makes sure only Prometheus can reach the page.

---

## Where each number comes from

| What you see | Who measures it | How |
|---|---|---|
| CPU, RAM, disk, network | node_exporter | reads Linux's `/proc` and `/sys` |
| Services running | node_exporter `systemd` collector | asks systemd for the state of the units in `monitored_units` |
| Pending updates, reboot required | the Ubuntu package's apt script | writes `apt.prom`, which node_exporter publishes |
| Stream on, bitrate, chunk age | our script `mss-stream-metrics` | reads nginx-rtmp's `/stat` page and the HLS folder, writes `mss_stream.prom` |
| Website up, response time, certificate | blackbox_exporter | loads the pages like a visitor would |
| Server down | Prometheus itself | the scrape fails, so `up = 0` |

---

## The MSS - Platform dashboard, panel by panel

Every panel follows the same chain:

```
Linux keeps a number  →  node_exporter shows it as a line  →  Prometheus saves it every 15 s  →  the panel does a little math on it
```

The raw values below were read from the frontend during verification.

### Servers (1 = up, 0 = down)

**Measured by:** Prometheus itself, not an exporter. If the page on port 9100 answers, it records `up = 1`; if not (server off, crashed, or firewall), `up = 0`.

**Query:** `up{job="node"}`

### Pending security updates

**Measured by:** the apt script that comes with the `prometheus-node-exporter` package. A timer (`prometheus-node-exporter-apt.timer`) runs it every 15 minutes; it asks apt what could be upgraded and writes the answer to `apt.prom`.

```
apt_upgrades_pending{arch="all",  origin="Ubuntu:22.04/jammy-updates"} 3
apt_upgrades_pending{arch="amd64",origin="Ubuntu:22.04/jammy-updates"} 12
```

That's 15 updates, but they come from `jammy-updates` (regular fixes), not from `jammy-security`.

**Query:** keep only the lines whose `origin` contains "security" and add them up per server. If there are none, it falls back to 0, so the panel shows **0** instead of "No data":

```
sum by (server) (apt_upgrades_pending{origin=~".*security.*"})
  or sum by (server) (apt_upgrades_pending) * 0
```

### Reboot required

**Measured by:** the same apt script. It checks whether `/var/run/reboot-required` exists; Ubuntu creates that file after a kernel or libc update.

**Query:** `node_reboot_required` (0 = no reboot needed).

### CPU use

**Where Linux keeps it:** `/proc/stat`. For each CPU core, Linux counts how long it spent in each state since boot, in hundredths of a second:

```
/proc/stat:      cpu0 13647 2463 5787 895156 ...
node_exporter:   node_cpu_seconds_total{cpu="0",mode="user"}    136.46
                 node_cpu_seconds_total{cpu="0",mode="system"}   57.87
                 node_cpu_seconds_total{cpu="0",mode="idle"}   8951.56
```

It's the same number, converted: 895156 hundredths = **8951.56 s idle**.

These are **counters**: they only grow. So the panel looks at **how fast "idle" grows**:
- if, over 1 second, "idle" grew by 0.95 s, the CPU did nothing 95% of the time: **5% used**;
- if it grew by only 0.20 s: **80% used**.

**Query:**

```
100 * (1 - avg by (server) (rate(node_cpu_seconds_total{job="node",mode="idle"}[2m])))
```

Read from the inside out:
1. `node_cpu_seconds_total{mode="idle"}`: seconds the CPU spent doing nothing;
2. `rate(…[2m])`: how fast that grew over the last 2 minutes (idle seconds per second, between 0 and 1);
3. `avg by (server)`: average the CPU cores of each server;
4. `100 * (1 - …)`: not idle means busy, so this gives the **% used**.

**CPU, 24 h average** is the same calculation averaged over a whole day. It's compared with **10%**, the free "baseline" of a t3 server. Both t3 servers run in *unlimited* mode: they never slow down, but a day above 10% is billed as surplus credits. The streamer sits close to it because ffmpeg re-encodes the video.

### Memory used

**Where Linux keeps it:** `/proc/meminfo`.

```
/proc/meminfo:   MemTotal:      935936 kB
                 MemAvailable:  531112 kB
node_exporter:   node_memory_MemTotal_bytes      958398464     (same, in bytes)
                 node_memory_MemAvailable_bytes  535838720
```

**Query:** `100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)`

That's 1 − 536 MB ÷ 958 MB = **about 44% used**.

It uses "Available", not "Free": Linux borrows unused RAM as cache and gives it back when a program needs it, and "Available" counts that cache as usable.

### Disk used (/)

**Where Linux keeps it:** the same numbers `df` shows.

```
df /:            size 8132173824   available 5000028160   (39%)
node_exporter:   node_filesystem_size_bytes{mountpoint="/"}   8.13e+09
                 node_filesystem_avail_bytes{mountpoint="/"}  5.00e+09
```

**Query:** `100 * (1 - node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"})`

That's 1 − 5.00 GB ÷ 8.13 GB = **about 38.5% used**, the same as `df` (which rounds up to 39%).

### Network

**Where Linux keeps it:** `/proc/net/dev`, which holds the total bytes received and sent by the network card (`ens5`) since boot.

```
node_network_receive_bytes_total{device="ens5"}   1344568003   (1.34 GB received since boot)
node_network_transmit_bytes_total{device="ens5"}   633575455   (0.63 GB sent)
```

These are counters again, so the panel uses `rate()` to get bytes per second over the last 2 minutes, × 8 to get **bits per second**:
- **received** is drawn above the zero line;
- **sent** is drawn below it (as a negative number), so both fit on one chart.

The WireGuard interface (`wg0`) is left out: its traffic already passes through `ens5` and would be counted twice.

### Services

**Measured by:** node_exporter's `systemd` collector. Each service gets one line per possible state, and the true state is 1:

```
node_systemd_unit_state{name="nginx.service",state="active"}   1   ← the true one
node_systemd_unit_state{name="nginx.service",state="failed"}   0
node_systemd_unit_state{name="nginx.service",state="inactive"} 0
```

**Query:** `max by (server, name) (node_systemd_unit_state{state="active"})`. The table shows **1 = running, 0 = not running**.

---

## The MSS - Stream dashboard

| Panel | What it shows | Healthy value |
|---|---|---|
| **Stream** | Is ffmpeg sending video to the frontend? | 1 |
| **Newest HLS chunk age** | Seconds since the newest video piece was written | under about 10 s; it keeps climbing if the stream stops |
| **Website** | Can a "visitor" load the page and the video playlist? | 1 for both |
| **Certificate expires in** | Days left on the HTTPS certificate | certbot renews it at about 30 days left |
| **Incoming stream bitrate** | Video bitrate arriving from the streamer | about 870 kbit/s, a flat line |
| **Website response time** | How long the page and playlist take to load | milliseconds |
| **Streamer CPU** | How hard ffmpeg works | about 11–14% |

The first 2 panels and the bitrate come from our script, [ansible/templates/mss-stream-metrics.py.j2](../ansible/templates/mss-stream-metrics.py.j2). It runs every 15 s on the frontend and:
1. finds the newest `.ts` chunk in `/var/www/html/stream/hls` and computes its age;
2. reads nginx-rtmp's statistics page, `http://127.0.0.1:8080/stat` (XML, localhost only), for the publisher, bitrate and clients;
3. writes the result to `mss_stream.prom.tmp`, then renames it to `mss_stream.prom`, so node_exporter never reads a half-written file.

It needs no open port: node_exporter publishes the file. The `/stat` page was added to [ansible/templates/nginx.conf.j2](../ansible/templates/nginx.conf.j2) on the localhost-only server, next to `/control`.

---

## How the website probe works

A website doesn't expose metrics, so blackbox_exporter turns "loading the page" into numbers.

The `website` job in [prometheus.yml.j2](../ansible/templates/prometheus.yml.j2) doesn't scrape the website directly. Its `relabel_configs` rewrite each scrape into a question to blackbox_exporter:

```
GET http://127.0.0.1:9115/probe?module=https_site&target=https://192.168.0.148/hls/stream.m3u8
```

blackbox_exporter loads the page and answers with numbers:

```
probe_success 1
probe_duration_seconds 0.012
probe_ssl_earliest_cert_expiry 1.7697e+09     (a date, as seconds since 1970)
```

The probe goes over the private network (the monitoring server has no internet). The module `https_site` in [blackbox.yml.j2](../ansible/templates/blackbox.yml.j2):
- sends the real domain name in the `Host` header;
- checks the certificate against that name (`tls_config.server_name`);
- fails if the page isn't HTTPS or doesn't answer 200.

So the certificate is really checked, even though the probe uses an IP address.

---

## Logs: Loki and Alloy

### Why push for logs

A number like "CPU = 12%" is a snapshot: Prometheus can afford to ask for it every 15 s. Log lines arrive one at a time, and a line written between 2 visits must not be lost. So the agent on each server **forwards every line as soon as it's written**.

```
                      every server                                     mss-monitoring
┌──────────────────────────────────────────────────┐
│ systemd journal ─┐                               │
│ (SSH, sudo,      │                               │
│  services...)    ├─► Alloy ─► drop our own   ─► hide key=… ─► push ──HTTP :3100──► Loki ──► Grafana
│ nginx logs ──────┘           monitoring noise                │                  (15 days)
│ (frontend only)                                  │
└──────────────────────────────────────────────────┘
```

### What is collected

| Source | Server | Labels in Loki | What it shows |
|---|---|---|---|
| systemd journal | all 3 | `job="journal"`, `unit` (e.g. `ssh.service`), `identifier` (e.g. `sshd`, `sudo`), `level` (`info`, `warning`, `error`...) | SSH logins, sudo commands, every service (ffmpeg, nginx, WireGuard, Grafana...), security updates |
| `/var/log/nginx/access.log` | frontend | `job="nginx"`, `log="access"` | Every request to the website (visitors and scanners) |
| `/var/log/nginx/error.log` | frontend | `log="error"` | nginx errors (files not found...) |
| `/var/log/nginx/publish-auth.log` | frontend | `log="publish-auth"` | Every publish attempt and the verdict (`result=200` or `403`) |
| `/var/log/nginx/rtmp-access.log` | frontend | `log="rtmp-access"` | Publisher sessions: address, bytes, duration |

Every line also gets `server` (`web-frontend`, `video-streamer`, `monitoring`), the same names as in Prometheus.

SSH and sudo are read from the journal, not from `/var/log/auth.log`: the same lines are in both, and reading both would store them twice.

### What Alloy changes before sending

| Rule | Why |
|---|---|
| Drops the website probes (`192.168.1.25 … Go-http-client`) and the stream collector's `GET /stat` from `127.0.0.1` | Our own monitoring makes 3 requests every 15 s (about 17,000 a day): they would bury real visitors and scanners |
| Replaces any `key=<letters/digits>` with `key=REDACTED` | Safety net: no stream key can reach Loki, even if a program prints one (see [the leak](#the-stream-key-leak-found-and-fixed)) |

### How it is set up (4 steps)

**Step 1: Loki on the monitoring server** (play 8 in [ansible/site.yml](../ansible/site.yml)), settings in [loki.yml.j2](../ansible/templates/loki.yml.j2):
- listens on the **private IP** port 3100 (the agents must reach it) and keeps its internal port (9096) on localhost;
- data on the local disk in `/var/lib/loki`, **15 days** retention (the compactor deletes older logs);
- usage reporting off.

The Loki package starts Loki **the moment it is installed**, with demo settings (all interfaces, debug logging, data in `/tmp`). So the playbook writes our settings and a systemd **drop-in** pointing to them **before** installing the package: Loki's very first start already uses them. The same drop-in sandboxes it (exposure score **1.7 OK**).

**Step 2: Alloy on every server** (play 9), settings in [alloy.config.j2](../ansible/templates/alloy.config.j2), one template with a frontend-only part for the nginx logs:
- the package adds the `alloy` user to the `adm` and `systemd-journal` groups, which can read the logs;
- its own web page stays on `127.0.0.1:12345`; usage reporting off;
- sandboxed (exposure score **2.0 OK**): read-only system except its data folder, **network allowed only to the monitoring server**, memory capped at 250 MB.

**Step 3: the firewall** (already in Terraform since M1): the frontend and streamer security groups allow **out** to port 3100 of the monitoring server, and the monitoring group allows **in** on 3100 from the 2 subnets.

**Step 4: Grafana** gets Loki as a second data source ([grafana-datasources.yml.j2](../ansible/templates/grafana-datasources.yml.j2)) and a third dashboard, **MSS - Security**.

Both packages are pinned, downloaded on the control machine, checked against their SHA-256, then uploaded (the monitoring server has no internet).

### LogQL in one example

Loki's question language looks like PromQL, but starts from log lines. The "Failed SSH logins" panel asks:

```
sum by (server) (count_over_time({identifier="sshd"} |~ "Failed password|Invalid user|..." [$__range]))
```

Read from the inside out:
1. `{identifier="sshd"}`: all the lines written by the SSH server;
2. `|~ "Failed password|Invalid user|..."`: keep only the lines that match;
3. `count_over_time(… [$__range])`: count them over the time range picked in Grafana;
4. `sum by (server)`: one number per server.

---

## The MSS - Security dashboard

| Panel | What it shows | Healthy value |
|---|---|---|
| **Failed SSH logins** | Failed or invalid SSH logins, per server | 0. SSH only accepts your IP, so any failure is worth a look |
| **Rejected stream keys** | Publish attempts refused by the stream-key check (`result=403`) | 0 |
| **Website 4xx responses** | Requests answered "not found" or similar | some is normal: the internet is full of scanners |
| **Errors in system logs** | Journal entries with priority error or worse | 0 or a few |
| **Failed SSH logins over time** | The same failures, as bars | empty |
| **Successful SSH logins** | Who logged in, from where (`ubuntu from 129.104.244.174 (publickey)`) | your IP, and the frontend's private IP (Ansible through the jump host) |
| **Stream-key checks** | Every publish attempt and its verdict. The key itself is never logged | `result=200` from `10.99.0.2` (the streamer through WireGuard) |
| **Publisher sessions (RTMP)** | Who published, bytes received, duration | `10.99.0.2` |
| **Website requests by status** | 2xx / 3xx / 4xx / 5xx over time | mostly 2xx |
| **Top IPs getting 4xx (scanners)** | The addresses with the most 4xx answers | |
| **Paths requested by scanners** | What they were looking for (`/composer.json`, `/wp-login.php`...) | |
| **nginx errors** | nginx's error log | |
| **Commands run with sudo** | Commands typed with sudo; Ansible's own sudo calls are hidden | |
| **ffmpeg (streamer)** | ffmpeg's warnings and errors | normally empty |
| **Errors from all servers** | Live view of every error-level journal entry | |

The first day already showed a real scanner: `136.70.149.115` got **322 "not found"** answers while looking for files like `composer.json` and `package.json`. Nothing was found: the site only serves the player page and the video.

---

## The stream key leak (found and fixed)

While planning log shipping, the logs were checked for secrets **before** sending them anywhere. The streamer's system log contained the **stream key** in 41 journal lines and in older syslog files:

```
rtmp://10.99.0.1:1935/live/stream?key=REDACTED: Connection refused         ← the real key was here
Error writing trailer of rtmp://10.99.0.1:1935/live/stream?key=REDACTED: Broken pipe
```

**Cause:** ffmpeg had the key inside its output URL, and it repeats that URL in its error messages: `Connection refused` while the frontend boots after the nightly restart, `Broken pipe` at shutdown. These are useful errors, so silencing them was not the answer.

**Fix, in 3 layers:**
1. **At the source** ([ffmpeg-stream.service.j2](../ansible/templates/ffmpeg-stream.service.j2)): the key moved out of the URL into `-rtmp_app live -rtmp_playpath stream?key=…`, with the URL `rtmp://10.99.0.1:1935`. nginx-rtmp receives exactly the same thing. Tested with a fake key:
   ```
   before:  rtmp://127.0.0.1:19999/live/stream?key=DUMMYKEY123: Connection refused
   after:   rtmp://127.0.0.1:19999: Connection refused
   ```
2. **The old lines** (play 5): if a real key is found in the journal or `/var/log/syslog*`, the journal is archived and deleted, and the key is replaced by `REDACTED` in the syslog files. This ran once; it does nothing now that the logs are clean.
3. **In Alloy:** any `key=…` is replaced by `key=REDACTED` before leaving the server.

**Result:** 0 real keys in the streamer's logs and 0 in Loki. During the wrong-key test, the fake key `WRONGKEY` appeared nowhere either.

**Still true:** systemd inserts the key into ffmpeg's command-line arguments, so `ps` on the streamer can show it to local processes. No other user works on that server; moving the key out of the arguments is listed for M5.

---

## Opening Grafana

Grafana listens on localhost only, so it is reached through an SSH tunnel via the frontend. **The deployment opens that tunnel for you**: the last play of the playbook runs on your laptop and starts it in the background.

1. After `terraform apply`, open **http://localhost:3000**.
2. Log in as `admin`. The password is the fixed one in `terraform/secrets.auto.tfvars` (git-ignored), or, if none is set there, a generated one: `terraform output -raw grafana_admin_password`.
3. The dashboards are under **Dashboards → MSS**.

**Reopening the tunnel** (after a laptop reboot, a network change, or the nightly restart, which gives the frontend a new IP). From `ansible/`:
```
ansible-playbook site.yml --tags grafana
```
It closes the old tunnel and opens a new one to the current IP. After the nightly restart, run `terraform apply` first, so the inventory has the frontend's new IP.

**How the play works** (play 11, `hosts: localhost`):
- closes the previous tunnel through its control socket (`ansible/.grafana-tunnel.sock`, git-ignored);
- opens a new one with `ssh -f -N -M -S <socket> … -L 127.0.0.1:3000:localhost:3000`: `-f` puts it in the background once connected, `-M -S` creates the socket the next run uses to close it, and the ProxyCommand hops through the frontend;
- checks that Grafana answers, and prints the address. If port 3000 is already taken, it says so but doesn't fail the deployment.
- Turn it off with `open_grafana_tunnel: false` (for example in `group_vars/all.yml`).

**The password:** a fixed password can be set in `terraform/secrets.auto.tfvars`:
```
grafana_admin_password = "..."
```
That file is git-ignored and only readable by you (`terraform.tfvars` is committed, so never put it there). Without it, Terraform generates a random password. A fixed, simple password is easier to remember but easier to guess; here it is still behind the SSH tunnel, which needs your IP and the SSH key.

**By hand**, if needed, the tunnel command is: `terraform output -raw grafana_tunnel`. It runs in the foreground: leave that terminal open.

**Tips:**
- Set the time range (top right) to **Last 1 hour** or **Last 24 hours**.
- **Explore** (compass icon) lets you try your own queries: pick Prometheus and type a metric name, such as `node_memory_MemAvailable_bytes`, or `rate(node_network_receive_bytes_total[2m])`.
- The dashboards are files in the repo ([ansible/dashboards/](../ansible/dashboards/)) and can't be edited in the UI. A redeploy recreates them exactly. To change a panel, change the JSON file.

---

## Security of the monitoring

| Rule | How |
|---|---|
| No internet on the monitoring server | Its security group only allows out: 9100 (scrapes), 443 (website probes), 3142 (package proxy) |
| Metrics not public | node_exporter listens on the private IP; port 9100 is open only to the monitoring server's security group |
| Monitoring tools not exposed | Prometheus, blackbox_exporter and Grafana listen on `127.0.0.1` only; Grafana is reached through SSH |
| Loki only reachable from the servers | It listens on the private IP; port 3100 is open only from the 2 subnets; its internal port 9096 is on localhost. No authentication yet (M5) |
| Agents can only talk to the monitoring server | Alloy's sandbox allows the network only to the monitoring server and localhost |
| No secrets in the logs | Key-free log formats; ffmpeg's key leak fixed at the source; Alloy replaces any `key=…` with `REDACTED` |
| SSH only through the frontend | The monitoring server accepts SSH (22) from the public subnet only |
| Password never stored in git or on a command line | Either a fixed password from the git-ignored `secrets.auto.tfvars` or one generated by Terraform (`random_password`); Ansible writes it to a root-only file (0600) and resets it with `no_log`, passed on stdin |
| No sign-up, no anonymous access, no phoning home | Settings in [grafana.env.j2](../ansible/templates/grafana.env.j2) |
| Packages are checked | Grafana, Loki and Alloy are downloaded on the control machine, checked against their pinned SHA-256, then uploaded |
| Services run sandboxed | The stream script (unprivileged, localhost only), Loki (exposure score 1.7) and Alloy (2.0, memory capped at 250 MB) |
| Disk encrypted, IMDSv2 only | Same as the other servers |

---

## Files that make up the monitoring

### Terraform

| File | What it does |
|---|---|
| [terraform/monitoring.tf](../terraform/monitoring.tf) | **New.** The monitoring security group, the server (t3.small, private subnet, 20 GB encrypted disk, IMDSv2), its restart after the nightly shutdown, and the generated Grafana password |
| [terraform/security.tf](../terraform/security.tf) | The frontend and streamer groups allow port 9100 in from the monitoring server, and port 3100 out to it (logs to Loki) |
| [terraform/variables.tf](../terraform/variables.tf) | `enable_monitoring` (default `true`) and `monitoring_instance_type` (default `t3.small`) |
| [terraform/outputs.tf](../terraform/outputs.tf) | `monitoring_private_ip`, `grafana_tunnel`, `grafana_admin_password` (sensitive) |
| [terraform/inventory.yml.tftpl](../terraform/inventory.yml.tftpl) | Adds a `monitoring` group, reached through the frontend |
| [terraform/ansible.tf](../terraform/ansible.tf) | Passes the monitoring IP and Grafana password to Ansible; the dashboard files also trigger a new Ansible run |

### Ansible

| File | What it does |
|---|---|
| [ansible/site.yml](../ansible/site.yml) | Play 2: the monitoring server uses the package proxy and refreshes its package lists. Play 6: security updates on all 3 servers. **Play 7:** node_exporter everywhere, plus the stream script on the frontend. **Play 8:** Prometheus, blackbox_exporter, Loki and Grafana on the monitoring server. **Play 9:** Alloy on all 3 servers. Play 5 also removes stream keys leaked into old logs |
| [ansible/group_vars/all.yml](../ansible/group_vars/all.yml) | Pinned versions and SHA-256 checksums (Grafana, Loki, Alloy), retention, `monitored_units` |
| [prometheus.yml.j2](../ansible/templates/prometheus.yml.j2) | What Prometheus scrapes |
| [blackbox.yml.j2](../ansible/templates/blackbox.yml.j2) | How the website is probed |
| [mss-stream-metrics.py.j2](../ansible/templates/mss-stream-metrics.py.j2) | The stream health script |
| [grafana.env.j2](../ansible/templates/grafana.env.j2) | Grafana settings |
| [loki.yml.j2](../ansible/templates/loki.yml.j2) | Loki's settings: private IP, local storage, 15 days retention |
| [alloy.config.j2](../ansible/templates/alloy.config.j2) | What Alloy reads, what it drops and hides, where it sends |
| [ffmpeg-stream.service.j2](../ansible/templates/ffmpeg-stream.service.j2) | The key moved to `-rtmp_playpath` so ffmpeg's errors don't show it |
| [grafana-datasources.yml.j2](../ansible/templates/grafana-datasources.yml.j2) | Tells Grafana where Prometheus and Loki are |
| [grafana-dashboards.yml.j2](../ansible/templates/grafana-dashboards.yml.j2) | Tells Grafana to load the dashboards from files, read-only |
| [nginx.conf.j2](../ansible/templates/nginx.conf.j2) | Adds the `/stat` page (localhost only) |
| [ansible/dashboards/](../ansible/dashboards/) | The 3 dashboards, as JSON |

---

## Problems found during deployment

| Problem | Cause | Fix |
|---|---|---|
| The monitoring server couldn't install any package | A new server has never downloaded its package lists: cloud-init tried the internet, which the private subnet doesn't have. The security-update step also had nothing to compare against | Play 2 refreshes the package lists through the proxy (`update_cache`) |
| The stream metrics were missing | The textfile folder is root-only, and the stream script runs as the unprivileged `prometheus` user | The folder's group is `prometheus` with write access (owner stays root) |
| The `grafana_tunnel` command didn't work | `ssh -J` doesn't use the `-i` key for the hop through the frontend | The output uses a `ProxyCommand` that passes the key to both hops |
| **The stream key was in the streamer's system log** (M3, found before shipping any log) | ffmpeg repeats its output URL, key included, in error messages | See [the stream key leak](#the-stream-key-leak-found-and-fixed) |
| The leak cleanup ran again on every deployment, emptying the streamer's journal each time | Its check, `key=` + a letter, also matched `key=REDACTED` | The check now ignores `key=REDACTED`; a rerun reports `clean` |
| A log file missing when Alloy starts would never be read | `loki.source.file` skips a file it can't open | `local.file_match` looks for the files again every few seconds (tested by creating a file after start) |

---

## Verification (live)

Checked after deployment:
- all 7 scrape targets are up: node_exporter on the 3 servers, Prometheus, blackbox_exporter, and the 2 website pages;
- the monitoring server can't reach the internet;
- node_exporter on the frontend listens on `192.168.0.148:9100` only; Prometheus, blackbox_exporter and Grafana on `127.0.0.1` only;
- stream metrics: a publisher is connected at about 870 kbit/s, and the newest chunk is fresh;
- both website probes succeed, and the certificate has about 83 days left;
- nginx, WireGuard, apt-cacher-ng and ffmpeg show as running;
- 0 security updates pending on every server;
- Grafana works through the tunnel, refuses a wrong password, and loads both dashboards;
- the two t3.micro servers still have about 550 MB of memory available each.

Logs (M3), checked after deployment:
- Loki, Alloy and Grafana running; Loki listens on `192.168.1.25:3100` and `127.0.0.1:9096`, Alloy's page on `127.0.0.1:12345`;
- all 3 servers send logs, and the 4 nginx logs arrive;
- **a publish with a wrong key** (fake key `WRONGKEY`, from the streamer) appeared within seconds: `addr=10.99.0.2 app=live name=stream result=403`; the fake key itself appears nowhere in Loki;
- **an SSH login with a user that doesn't exist** appeared: `Invalid user intruder from 129.104.244.174`;
- **0 real stream keys** in Loki and in the streamer's logs;
- 0 website-probe lines in Loki;
- the stream stayed live (`result=200` after the ffmpeg change);
- Grafana: 3 dashboards; its connection test to Loki succeeds;
- memory: Alloy uses about 36 MB per server (systemd's count). Available memory: frontend 504 MB (527 before), streamer 387 MB (500 before), monitoring 1160 MB;
- a second `terraform apply`: `changed=0` on all 3 servers;
- ansible-lint (production profile) passes.

Not tested yet: stopping ffmpeg to watch the "Stream" panel turn red and the chunk age climb (it cuts the stream for about 30 s).
