# Monitoring: how it works

**Status:** phases M1 (monitoring server) and M2 (metrics and dashboards) are built and verified live. Logs (Loki, phase M3) and alerts (M4) are not built yet; see [MONITORING-PLAN.md](MONITORING-PLAN.md).

This guide explains, in simple terms:
- what Prometheus, node_exporter and Grafana are;
- how every number on the dashboards is collected;
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
- [Opening Grafana](#opening-grafana)
- [Security of the monitoring](#security-of-the-monitoring)
- [Files that make up the monitoring](#files-that-make-up-the-monitoring)
- [Problems found during the first deployment](#problems-found-during-the-first-deployment)
- [Verification (live)](#verification-live)

---

## The big picture

A 3rd server, **mss-monitoring**, sits in the private subnet. It has no public IP and no internet access. It runs 3 programs:

| Program | Role | Listens on |
|---|---|---|
| **Prometheus** | Collects numbers every 15 s and keeps 15 days of history | `127.0.0.1:9090` |
| **blackbox_exporter** | Loads the website like a visitor and reports the result as numbers | `127.0.0.1:9115` |
| **Grafana** | Draws the dashboards by asking Prometheus questions | `127.0.0.1:3000` |

Every server also runs **node_exporter**, a small agent that publishes the server's numbers on port 9100.

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

**Prometheus pulls.** The servers never send anything on their own; Prometheus visits them. If a server stops answering, Prometheus notices right away. Logs (phase M3) will work the other way round: an agent will **push** each log line to Loki.

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

## Opening Grafana

Grafana listens on localhost only, so you reach it through an SSH tunnel via the frontend. From the `terraform/` folder:

1. Get the tunnel command and run it. **Leave that terminal open**; it shows nothing and looks stuck, which is normal (`-N` means "no shell, just the tunnel"):
   ```
   terraform output -raw grafana_tunnel
   ```
   It prints a command like:
   ```
   ssh -i ./mss-key.pem -o ProxyCommand="ssh -i ./mss-key.pem -W %h:%p ubuntu@<frontend public IP>" -N -L 3000:localhost:3000 ubuntu@<monitoring private IP>
   ```
   The frontend's public IP changes after the nightly restart, so get a fresh command each day.
2. In a second terminal, get the password:
   ```
   terraform output -raw grafana_admin_password
   ```
3. Open **http://localhost:3000** and log in as `admin`. The dashboards are under **Dashboards → MSS**.

**What the command does:**
- `ProxyCommand="ssh … -W %h:%p ubuntu@<frontend>"`: connect to the frontend first (the only server with a public IP) and use it as a relay into the private subnet;
- `ubuntu@<monitoring private IP>`: the final destination;
- `-L 3000:localhost:3000`: anything sent to port 3000 on your laptop goes through both hops and arrives at Grafana.

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
| SSH only through the frontend | The monitoring server accepts SSH (22) from the public subnet only |
| Password never typed or stored in git | Terraform generates it (`random_password`); Ansible writes it to a root-only file (0600) and resets it with `no_log`, never on a command line |
| No sign-up, no anonymous access, no phoning home | Settings in [grafana.env.j2](../ansible/templates/grafana.env.j2) |
| Grafana's package is checked | Downloaded on the control machine, checked against its pinned SHA-256, then uploaded |
| The stream script runs sandboxed | Unprivileged `prometheus` user, read-only system, only localhost reachable, no capabilities |
| Disk encrypted, IMDSv2 only | Same as the other servers |

---

## Files that make up the monitoring

### Terraform

| File | What it does |
|---|---|
| [terraform/monitoring.tf](../terraform/monitoring.tf) | **New.** The monitoring security group, the server (t3.small, private subnet, 20 GB encrypted disk, IMDSv2), its restart after the nightly shutdown, and the generated Grafana password |
| [terraform/security.tf](../terraform/security.tf) | The frontend and streamer groups allow port 9100 in from the monitoring server, and port 3100 out to it (for Loki, phase M3) |
| [terraform/variables.tf](../terraform/variables.tf) | `enable_monitoring` (default `true`) and `monitoring_instance_type` (default `t3.small`) |
| [terraform/outputs.tf](../terraform/outputs.tf) | `monitoring_private_ip`, `grafana_tunnel`, `grafana_admin_password` (sensitive) |
| [terraform/inventory.yml.tftpl](../terraform/inventory.yml.tftpl) | Adds a `monitoring` group, reached through the frontend |
| [terraform/ansible.tf](../terraform/ansible.tf) | Passes the monitoring IP and Grafana password to Ansible; the dashboard files also trigger a new Ansible run |

### Ansible

| File | What it does |
|---|---|
| [ansible/site.yml](../ansible/site.yml) | Play 2: the monitoring server uses the package proxy and refreshes its package lists. Play 6: security updates on all 3 servers. **Play 7:** node_exporter everywhere, plus the stream script on the frontend. **Play 8:** Prometheus, blackbox_exporter and Grafana on the monitoring server |
| [ansible/group_vars/all.yml](../ansible/group_vars/all.yml) | Pinned versions and SHA-256 checksums (Grafana, and Loki and Alloy for phase M3), retention, `monitored_units` |
| [prometheus.yml.j2](../ansible/templates/prometheus.yml.j2) | What Prometheus scrapes |
| [blackbox.yml.j2](../ansible/templates/blackbox.yml.j2) | How the website is probed |
| [mss-stream-metrics.py.j2](../ansible/templates/mss-stream-metrics.py.j2) | The stream health script |
| [grafana.env.j2](../ansible/templates/grafana.env.j2) | Grafana settings |
| [grafana-datasources.yml.j2](../ansible/templates/grafana-datasources.yml.j2) | Tells Grafana where Prometheus is |
| [grafana-dashboards.yml.j2](../ansible/templates/grafana-dashboards.yml.j2) | Tells Grafana to load the dashboards from files, read-only |
| [nginx.conf.j2](../ansible/templates/nginx.conf.j2) | Adds the `/stat` page (localhost only) |
| [ansible/dashboards/](../ansible/dashboards/) | The 2 dashboards, as JSON |

---

## Problems found during the first deployment

| Problem | Cause | Fix |
|---|---|---|
| The monitoring server couldn't install any package | A new server has never downloaded its package lists: cloud-init tried the internet, which the private subnet doesn't have. The security-update step also had nothing to compare against | Play 2 refreshes the package lists through the proxy (`update_cache`) |
| The stream metrics were missing | The textfile folder is root-only, and the stream script runs as the unprivileged `prometheus` user | The folder's group is `prometheus` with write access (owner stays root) |
| The `grafana_tunnel` command didn't work | `ssh -J` doesn't use the `-i` key for the hop through the frontend | The output uses a `ProxyCommand` that passes the key to both hops |

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

Not tested yet: stopping ffmpeg to watch the "Stream" panel turn red and the chunk age climb (it cuts the stream for about 30 s).
