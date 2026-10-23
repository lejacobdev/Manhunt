#!/usr/bin/env bash
# Daily backup of the Hunting Game database: a compressed pg_dump from the postgres container,
# kept for 14 days. Run from root's crontab:
#   40 3 * * * /root/manhunt/deploy/backup-db.sh >> /var/log/manhunt-backup.log 2>&1
# Then copies it, encrypted, to MEGA (backup-offsite.sh) once the rclone remote exists. One-time
# setup, typed by the account owner in an SSH session so the password never lands anywhere else:
#   read -rp "MEGA email: " E; read -rsp "MEGA password: " P; echo
#   /usr/local/bin/rclone config create mega-backup mega user "$E" pass "$(/usr/local/bin/rclone obscure "$P")"; unset P
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
DIR=/root/backups/manhunt
mkdir -p "$DIR"; chmod 700 "$DIR"
OUT="$DIR/manhunt-$(date -u +%Y%m%d-%H%M%S).sql.gz"
docker compose exec -T postgres pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner | gzip -9 > "$OUT.part"
# A dump that doesn't end with the completion marker is incomplete; don't keep it as a backup.
gunzip -c "$OUT.part" | tail -5 | grep -q "PostgreSQL database dump complete" || { echo "$(date -u) backup INCOMPLETE"; rm -f "$OUT.part"; exit 1; }
mv "$OUT.part" "$OUT"; chmod 600 "$OUT"
find "$DIR" -name 'manhunt-*.sql.gz' -mtime +14 -delete
echo "$(date -u) backup ok $(du -h "$OUT" | cut -f1) $OUT"
"$(dirname "$0")/backup-offsite.sh" || echo "$(date -u) offsite FAILED (the local backup above is fine)"
