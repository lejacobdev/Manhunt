#!/usr/bin/env bash
#
# bootstrap-apache.sh — installs Apache (if needed), enables the required
# modules, writes /etc/apache2/cloudflare-ips.conf and
# /etc/apache2/sites-available/api.lejacob.eu.conf from the templates in
# this repo, enables the site, and reloads Apache.
#
# Run as root (or with sudo) from anywhere inside the repo:
#   sudo ./deploy/bootstrap-apache.sh
#
# Idempotent — safe to re-run any time the repo's Apache templates change;
# it always overwrites the installed copies from deploy/apache/*.conf rather
# than leaving stale versions in place.
#
# Does NOT install the Cloudflare Origin CA certificate/key/chain — those
# are secrets that don't belong in a repeatable script or in git. Get them
# from the Cloudflare dashboard (SSL/TLS -> Origin Server -> Create
# Certificate) and place them at /etc/cloudflare/origin.pem,
# /etc/cloudflare/origin.key, and /etc/cloudflare/origin_ca_rsa_root.pem
# before (or after) running this — the script warns if they're missing but
# still proceeds, since `apache2ctl configtest` will catch it definitively.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APACHE_TEMPLATE_DIR="${SCRIPT_DIR}/apache"
DOMAIN="api.lejacob.eu"
CLOUDFLARE_CERT_DIR="/etc/cloudflare"

log() { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: run this as root (sudo ./deploy/bootstrap-apache.sh)." >&2
  exit 1
fi

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "ERROR: this script targets a Linux server running Apache (apt-based)." >&2
  exit 1
fi

# --- Resolve BACKEND_PORT from .env, falling back to the documented default ---
BACKEND_PORT="8420"
if [[ -f "${ROOT_DIR}/.env" ]]; then
  ENV_PORT="$(grep -E '^BACKEND_PORT=' "${ROOT_DIR}/.env" | tail -n1 | cut -d= -f2- || true)"
  if [[ -n "${ENV_PORT}" ]]; then
    BACKEND_PORT="${ENV_PORT}"
  fi
fi
log "Using BACKEND_PORT=${BACKEND_PORT} (from .env if present, else the default)"

# --- Install Apache if it's not already present ---
if ! command -v apache2ctl >/dev/null 2>&1; then
  log "Apache not found — installing..."
  apt update
  apt install -y apache2
else
  log "Apache already installed."
fi

log "Enabling required Apache modules..."
a2enmod proxy proxy_http proxy_wstunnel rewrite ssl headers authz_host >/dev/null

log "Installing ${DOMAIN} Cloudflare IP allowlist..."
cp "${APACHE_TEMPLATE_DIR}/cloudflare-ips.conf" /etc/apache2/cloudflare-ips.conf

log "Installing ${DOMAIN} vhost (BACKEND_PORT=${BACKEND_PORT})..."
sed "s/\${BACKEND_PORT}/${BACKEND_PORT}/g" "${APACHE_TEMPLATE_DIR}/api.lejacob.eu.conf" \
  > "/etc/apache2/sites-available/${DOMAIN}.conf"

log "Enabling the site..."
a2ensite "${DOMAIN}" >/dev/null

mkdir -p "${CLOUDFLARE_CERT_DIR}"
if [[ ! -f "${CLOUDFLARE_CERT_DIR}/origin.pem" || ! -f "${CLOUDFLARE_CERT_DIR}/origin.key" ]]; then
  warn "Cloudflare Origin CA cert/key not found at ${CLOUDFLARE_CERT_DIR}/."
  warn "Apache will fail to reload until they exist. Get them from the Cloudflare"
  warn "dashboard (SSL/TLS -> Origin Server -> Create Certificate) and place at:"
  warn "  ${CLOUDFLARE_CERT_DIR}/origin.pem"
  warn "  ${CLOUDFLARE_CERT_DIR}/origin.key"
  warn "  ${CLOUDFLARE_CERT_DIR}/origin_ca_rsa_root.pem"
  warn "Re-run this script (or just 'systemctl reload apache2') once they're in place."
  exit 0
fi

log "Validating Apache configuration..."
apache2ctl configtest

log "Reloading Apache..."
systemctl reload apache2

echo "=========================================================================="
echo "SUCCESS: https://${DOMAIN} is proxying to 127.0.0.1:${BACKEND_PORT}"
echo "Verify from your own machine (not this server): curl https://${DOMAIN}/health"
echo "=========================================================================="
