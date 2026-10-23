#!/usr/bin/env bash
# Restores the Hunting Game database from a backup.
#
#   ./deploy/restore-db.sh              list the backups available (on this server and on MEGA)
#   ./deploy/restore-db.sh <name>       restore one — a local manhunt-….sql.gz, or a MEGA ….sql.gz.gpg
#
# Before touching anything it saves the current database as a safety backup, so a restore can
# itself be undone. The game is offline for the minute or two the restore takes.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
RCLONE=/usr/local/bin/rclone
LOCAL=/root/backups/manhunt
REMOTE="mega-backup:HuntingGame-Backups"
KEY=/root/backups/.offsite-passphrase

if [ $# -eq 0 ]; then
  echo "On this server ($LOCAL):"
  ls -1t "$LOCAL"/manhunt-*.sql.gz 2>/dev/null | xargs -r -n1 basename | sed 's/^/  /' || true
  echo "On MEGA ($REMOTE):"
  $RCLONE lsf "$REMOTE" 2>/dev/null | sort -r | sed 's/^/  /' || echo "  (MEGA not reachable)"
  echo; echo "Restore one with: $0 <name>"
  exit 0
fi

NAME="$1"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
if [ -f "$LOCAL/$NAME" ]; then
  cp "$LOCAL/$NAME" "$WORK/restore.sql.gz"
elif [[ "$NAME" == *.gpg ]]; then
  echo "Downloading $NAME from MEGA..."
  $RCLONE copyto "$REMOTE/$NAME" "$WORK/restore.gpg"
  gpg --batch --quiet --pinentry-mode loopback --passphrase-file "$KEY" -d -o "$WORK/restore.sql.gz" "$WORK/restore.gpg"
else
  echo "No backup called $NAME. Run $0 without arguments to list them." >&2; exit 1
fi
gunzip -c "$WORK/restore.sql.gz" | tail -6 | grep -q "dump complete" || { echo "That backup is incomplete — not restoring it." >&2; exit 1; }

echo "This replaces the ENTIRE live database with $NAME."
read -rp "Type RESTORE to continue: " OK
[ "$OK" = "RESTORE" ] || { echo "Cancelled."; exit 1; }

echo "Saving the current database first..."
SAFETY="$LOCAL/manhunt-before-restore-$(date -u +%Y%m%d-%H%M%S).sql.gz"
docker compose exec -T postgres pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner | gzip -9 > "$SAFETY"
echo "  saved as $(basename "$SAFETY")"

echo "Stopping the game server and restoring..."
docker compose stop backend
docker compose exec -T postgres psql -q -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"
gunzip -c "$WORK/restore.sql.gz" | docker compose exec -T postgres psql -q -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null
docker compose start backend
sleep 8
curl -fsS http://127.0.0.1:"${BACKEND_PORT}"/health >/dev/null && echo "Done — the game server is back up." || echo "Restored, but the game server isn't answering yet: check 'docker compose logs backend'."
