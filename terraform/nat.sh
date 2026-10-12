#!/bin/bash
# Turns the frontend into a NAT instance for the private subnet.
# Installed as a systemd unit so it survives the nightly stop/start.
set -e

cat > /usr/local/sbin/mss-nat.sh <<'SCRIPT'
#!/bin/bash
set -e
sysctl -w net.ipv4.ip_forward=1
IFACE=$(ip route show default | awk '{print $5; exit}')
iptables -t nat -C POSTROUTING -o "$IFACE" -s ${private_cidr} -j MASQUERADE 2>/dev/null \
  || iptables -t nat -A POSTROUTING -o "$IFACE" -s ${private_cidr} -j MASQUERADE
SCRIPT
chmod +x /usr/local/sbin/mss-nat.sh

cat > /etc/systemd/system/mss-nat.service <<'UNIT'
[Unit]
Description=NAT for the private subnet
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/mss-nat.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now mss-nat.service
