#!/usr/bin/env bash
# Copies the newest database backup to MEGA, encrypted on this server first (AES-256, gpg) so
# MEGA — or anyone with the MEGA login — only ever holds unreadable files. Keeps 30 days there.
# Runs at the end of backup-db.sh. Needs the rclone remote "mega-backup" (see the setup command
# in the comments of backup-db.sh) and the key in /root/backups/.offsite-passphrase — keep a copy
# of that key somewhere other than this server, or the off-site copies can't be decrypted.
#
# Restore:  rclone copy mega-backup:HuntingGame-Backups/<file>.gpg . &&
#           gpg --batch --passphrase-file KEYFILE -d <file>.gpg | gunzip | psql ...
set -euo pipefail
RCLONE=/usr/local/bin/rclone
REMOTE="mega-backup:HuntingGame-Backups"
KEY=/root/backups/.offsite-passphrase
$RCLONE listremotes | grep -q '^mega-backup:$' || { echo "$(date -u) offsite skipped: rclone remote mega-backup not configured"; exit 0; }
LATEST=$(ls -1t /root/backups/manhunt/manhunt-*.sql.gz | head -1)
ENC="/root/backups/manhunt/.$(basename "$LATEST").gpg"
gpg --batch --yes --pinentry-mode loopback --passphrase-file "$KEY" --symmetric --cipher-algo AES256 -o "$ENC" "$LATEST"
$RCLONE copyto "$ENC" "$REMOTE/$(basename "$LATEST").gpg"
rm -f "$ENC"
$RCLONE delete --min-age 30d "$REMOTE" 2>/dev/null || true
echo "$(date -u) offsite ok $(basename "$LATEST").gpg -> MEGA"
