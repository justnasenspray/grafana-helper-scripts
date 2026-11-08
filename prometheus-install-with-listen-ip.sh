#!/usr/bin/env bash
#
# Installiert den Prometheus node-exporter und bindet ihn nur an eine IP.
#
# Aufruf:
#   sudo bash install-node-exporter.sh 10.10.62.41
#   sudo bash install-node-exporter.sh 10.10.62.41 10.10.76.165   # optional: nur Monitoring-IP in ufw erlauben
#
# Ohne Argument wird die IP interaktiv abgefragt.
# Unterstützt: Debian / Ubuntu (apt)

set -euo pipefail

PORT="9100"
LISTEN_IP="${1:-}"
MONITORING_IP="${2:-}"

info() { echo -e "\e[32m[+]\e[0m $*"; }
warn() { echo -e "\e[33m[!]\e[0m $*"; }
fail() { echo -e "\e[31m[x]\e[0m $*" >&2; exit 1; }

valid_ip() {
  local ip="$1" o
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -ra octets <<< "$ip"
  for o in "${octets[@]}"; do
    (( o >= 0 && o <= 255 )) || return 1
  done
}

# --- Root-Check ---------------------------------------------------------
[[ $EUID -eq 0 ]] || fail "Bitte als root ausführen: sudo bash $0 <IP>"

# --- IP abfragen / prüfen ----------------------------------------------
if [[ -z "$LISTEN_IP" ]]; then
  read -rp "IP, auf der der node-exporter lauschen soll (z. B. NetBird-IP): " LISTEN_IP
fi
valid_ip "$LISTEN_IP" || fail "Ungültige IP-Adresse: $LISTEN_IP"
if [[ -n "$MONITORING_IP" ]]; then
  valid_ip "$MONITORING_IP" || fail "Ungültige Monitoring-IP: $MONITORING_IP"
fi

if ! ip -4 addr | grep -qw "$LISTEN_IP"; then
  warn "Die IP $LISTEN_IP liegt auf keinem Interface dieses Servers."
  warn "Der Dienst startet dann nicht. Läuft NetBird (netbird status)?"
  read -rp "Trotzdem fortfahren? [j/N] " ans
  [[ "$ans" =~ ^[jJyY]$ ]] || exit 1
fi

# --- Installation ------------------------------------------------------
command -v apt-get >/dev/null 2>&1 || fail "Dieses Skript unterstützt nur Debian/Ubuntu (apt)."

info "Installiere prometheus-node-exporter ..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq prometheus-node-exporter curl >/dev/null

# --- Listen-Adresse setzen ---------------------------------------------
CONF="/etc/default/prometheus-node-exporter"
info "Setze Listen-Adresse auf ${LISTEN_IP}:${PORT} ..."
touch "$CONF"
cp -a "$CONF" "${CONF}.bak.$(date +%s)"
sed -i '/^ARGS=/d' "$CONF"
echo "ARGS=\"--web.listen-address=${LISTEN_IP}:${PORT}\"" >> "$CONF"

# --- Autostart-Abhängigkeit zu NetBird ---------------------------------
# Damit der Dienst nach dem Booten erst startet, wenn das VPN-Interface da ist,
# und sich bei Fehlschlag selbst neu startet.
info "Richte Autostart nach NetBird ein ..."
DROPIN_DIR="/etc/systemd/system/prometheus-node-exporter.service.d"
mkdir -p "$DROPIN_DIR"
cat > "${DROPIN_DIR}/override.conf" <<EOF
[Unit]
After=network-online.target netbird.service
Wants=network-online.target

[Service]
Restart=always
RestartSec=5
EOF

systemctl daemon-reload
systemctl enable prometheus-node-exporter >/dev/null 2>&1
systemctl restart prometheus-node-exporter

# --- Optional: ufw -----------------------------------------------------
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  if [[ -n "$MONITORING_IP" ]]; then
    info "ufw: erlaube ${MONITORING_IP} -> ${LISTEN_IP}:${PORT}"
    ufw allow from "$MONITORING_IP" to "$LISTEN_IP" port "$PORT" proto tcp >/dev/null
  else
    warn "ufw ist aktiv. Erlaube Port ${PORT} für den Monitoring-Server, z. B.:"
    warn "  ufw allow from <MONITORING-IP> to ${LISTEN_IP} port ${PORT} proto tcp"
  fi
fi

# --- Prüfen ------------------------------------------------------------
sleep 2
if systemctl is-active --quiet prometheus-node-exporter; then
  info "Dienst läuft."
else
  warn "Dienst läuft nicht. Logs: journalctl -u prometheus-node-exporter -n 30"
  exit 1
fi

if curl -fs --max-time 5 "http://${LISTEN_IP}:${PORT}/metrics" | head -n 1 | grep -q .; then
  info "Metriken erreichbar unter http://${LISTEN_IP}:${PORT}/metrics"
else
  warn "Metriken sind nicht abrufbar. Prüfe: ss -tlnp | grep ${PORT}"
fi

echo
info "Fertig. Trage dieses Target in deine prometheus.yml ein:"
echo
echo "  - job_name: servers"
echo "    static_configs:"
echo "      - targets: [\"${LISTEN_IP}:${PORT}\"]"
echo "        labels:"
echo "          env: prod"
echo "          host: $(hostname)"
echo
