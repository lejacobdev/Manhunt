#!/usr/bin/env bash
#
# publish-site.sh — publishes site/ (the lejacob.dev marketing site: home page,
# privacy policy, legal notice) to /var/www/lejacob-dev, then installs and reloads its
# Apache vhost if it isn't already set up.
#
# Run as root (or with sudo) from anywhere inside the repo:
#   sudo ./deploy/publish-site.sh
#
# Idempotent — safe to re-run any time site/ or deploy/apache/lejacob.dev.conf changes;
# it always mirrors the current repo content into place rather than leaving stale files.
#
# Does NOT install the Cloudflare Origin CA certificate — that's shared with
# api.lejacob.dev (see bootstrap-apache.sh) and already covers `lejacob.dev` /
# `*.lejacob.dev` if it's in place for the API vhost; nothing extra to fetch here.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APACHE_TEMPLATE_DIR="${SCRIPT_DIR}/apache"
DOMAIN="lejacob.dev"
WEB_ROOT="/var/www/lejacob-dev"

log() { echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: run this as root (sudo ./deploy/publish-site.sh)." >&2
  exit 1
fi

log "Publishing site/ -> ${WEB_ROOT}..."
mkdir -p "${WEB_ROOT}"
rsync -a --delete "${ROOT_DIR}/site/" "${WEB_ROOT}/"
chown -R www-data:www-data "${WEB_ROOT}"

if ! command -v apache2ctl >/dev/null 2>&1; then
  warn "Apache not found — site files are published to ${WEB_ROOT}, but nothing is serving them yet."
  exit 0
fi

log "Enabling required Apache modules..."
a2enmod rewrite ssl headers authz_host >/dev/null

log "Installing ${DOMAIN} vhost..."
cp "${APACHE_TEMPLATE_DIR}/${DOMAIN}.conf" "/etc/apache2/sites-available/${DOMAIN}.conf"
a2ensite "${DOMAIN}" >/dev/null

if [[ ! -f /etc/cloudflare/origindev.pem || ! -f /etc/cloudflare/origindev.key ]]; then
  warn "Cloudflare Origin CA cert/key not found at /etc/cloudflare/origindev.{pem,key}."
  warn "Apache will fail to reload until they exist (see README's Apache/Cloudflare section)."
  exit 0
fi

log "Validating Apache configuration..."
apache2ctl configtest

log "Reloading Apache..."
systemctl reload apache2

echo "=========================================================================="
echo "SUCCESS: https://${DOMAIN} is serving ${WEB_ROOT}"
echo "Verify from your own machine (not this server): curl -I https://${DOMAIN}"
echo "=========================================================================="
