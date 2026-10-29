#!/bin/bash
# backup.sh — Full server backup: app files, configs, databases, optional offsite copy
# Install on server at: /opt/server-tools/backup.sh   (run as root)
#
# Usage:
#   bash backup.sh run                  # create a backup now (default)
#   bash backup.sh list                 # list local backups
#   bash backup.sh verify [<id>]        # check checksums + archive integrity (default: latest)
#   bash backup.sh extract <id> [dir]   # unpack a backup into a staging dir (never touches live files)
#
# Config (optional): /etc/server-tools/backup.conf
#   BACKUP_DIR=/var/backups/server      # local destination
#   KEEP_DAYS=7                         # local retention
#   RCLONE_REMOTE=                      # e.g. "oss:my-bucket/web-01" — empty disables offsite
#   KEEP_REMOTE_DAYS=30                 # offsite retention
#   EXTRA_PATHS="/srv/data /home/deploy/uploads"
#
# Each run writes <BACKUP_DIR>/<id>/ with *.tar.gz, *.sql.gz, MANIFEST and SHA256SUMS.
# Failures are reported through notify.sh (if configured) and a non-zero exit code.

set -uo pipefail

CONF="/etc/server-tools/backup.conf"
[ -f "$CONF" ] && . "$CONF"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/server}"
KEEP_DAYS="${KEEP_DAYS:-7}"
RCLONE_REMOTE="${RCLONE_REMOTE:-}"
KEEP_REMOTE_DAYS="${KEEP_REMOTE_DAYS:-30}"
EXTRA_PATHS="${EXTRA_PATHS:-}"
TOOLS_DIR="$(cd "$(dirname "$0")" && pwd)"

# Rebuildable dependency dirs: excluded to keep backups small
EXCLUDES=(--exclude=node_modules --exclude=.venv --exclude=venv --exclude=__pycache__
          --exclude=.cache --exclude=.next/cache --exclude='*.log')

FAILURES=()
log()  { echo "[backup] $*"; }
fail() { echo "[backup] ERROR: $*" >&2; FAILURES+=("$*"); }

notify() {
  [ -f "$TOOLS_DIR/notify.sh" ] || return 0
  bash "$TOOLS_DIR/notify.sh" "$@" >/dev/null 2>&1 || true
}

latest_id() { ls -1 "$BACKUP_DIR" 2>/dev/null | grep -E '^[0-9]{8}-[0-9]{6}$' | sort | tail -1; }

# archive <name> <path>… — tar existing paths only; skip silently when none exist
archive() {
  local name="$1"; shift
  local p existing=()
  for p in "$@"; do [ -e "$p" ] && existing+=("$p"); done
  [ ${#existing[@]} -eq 0 ] && return 0
  if tar -czf "$DEST/$name.tar.gz" "${EXCLUDES[@]}" "${existing[@]}" 2>"$DEST/.tar-$name.err"; then
    rm -f "$DEST/.tar-$name.err"
    echo "files  $name.tar.gz  ${existing[*]}" >> "$DEST/MANIFEST"
  else
    # GNU tar exit 1 = "file changed as we read it": archive is still usable
    if [ $? -eq 1 ] && [ -s "$DEST/$name.tar.gz" ]; then
      echo "files  $name.tar.gz  ${existing[*]}  (some files changed during read)" >> "$DEST/MANIFEST"
    else
      fail "archive $name: $(tail -1 "$DEST/.tar-$name.err" 2>/dev/null)"
    fi
    rm -f "$DEST/.tar-$name.err"
  fi
}

backup_databases() {
  # MySQL / MariaDB — socket auth as root, or credentials from /root/.my.cnf
  if command -v mysqldump >/dev/null 2>&1 && mysql -e 'SELECT 1' >/dev/null 2>&1; then
    if mysqldump --all-databases --single-transaction --quick --routines --events --triggers \
         2>"$DEST/.mysql.err" | gzip > "$DEST/mysql-all.sql.gz" && [ "${PIPESTATUS[0]}" -eq 0 ]; then
      echo "db     mysql-all.sql.gz  all databases" >> "$DEST/MANIFEST"
    else
      fail "mysqldump: $(tail -1 "$DEST/.mysql.err")"
    fi
    rm -f "$DEST/.mysql.err"
  elif command -v mysql >/dev/null 2>&1; then
    fail "MySQL present but root cannot log in non-interactively (use socket auth or /root/.my.cnf)"
  fi

  # PostgreSQL
  if command -v pg_dumpall >/dev/null 2>&1 && id postgres >/dev/null 2>&1; then
    if su -s /bin/sh postgres -c 'cd /tmp && pg_dumpall' 2>"$DEST/.pg.err" | gzip > "$DEST/postgres-all.sql.gz" \
         && [ "${PIPESTATUS[0]}" -eq 0 ]; then
      echo "db     postgres-all.sql.gz  all databases + roles" >> "$DEST/MANIFEST"
    else
      fail "pg_dumpall: $(tail -1 "$DEST/.pg.err")"
    fi
    rm -f "$DEST/.pg.err"
  fi

  # Redis — consistent RDB snapshot over the replication protocol
  if command -v redis-cli >/dev/null 2>&1 && redis-cli ping >/dev/null 2>&1; then
    if redis-cli --rdb "$DEST/redis.rdb" >/dev/null 2>&1 && gzip "$DEST/redis.rdb"; then
      echo "db     redis.rdb.gz  RDB snapshot" >> "$DEST/MANIFEST"
    else
      fail "redis-cli --rdb failed"
    fi
  fi
}

cmd_run() {
  [ "$(id -u)" -eq 0 ] || { echo "Run as root" >&2; exit 1; }
  mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR"

  # One run at a time (cron + manual run could otherwise collide)
  exec 9>"$BACKUP_DIR/.lock"
  if command -v flock >/dev/null 2>&1 && ! flock -n 9; then
    echo "[backup] another backup is running" >&2; exit 1
  fi

  ID=$(date +%Y%m%d-%H%M%S)
  DEST="$BACKUP_DIR/$ID"
  mkdir -p "$DEST" && chmod 700 "$DEST"
  log "→ $DEST"
  {
    echo "# backup $ID on $(hostname) — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# kind   file  contents"
  } > "$DEST/MANIFEST"

  # Docker named volumes are NOT included — see backup-guide.md
  archive apps /var/www /opt/java-apps /opt/python-apps /opt/go-apps /opt/docker-apps
  archive nginx /etc/nginx
  archive letsencrypt /etc/letsencrypt
  archive systemd /etc/systemd/system
  archive cron /etc/cron.d /var/spool/cron
  archive server-tools /opt/server-tools /etc/server-tools /etc/server-index.json /etc/server-registry.json
  archive security /etc/ssh/sshd_config /etc/ssh/sshd_config.d /etc/fail2ban /etc/ufw /etc/firewalld
  # shellcheck disable=SC2086
  [ -n "$EXTRA_PATHS" ] && archive extra $EXTRA_PATHS
  # PM2 process list (lets `pm2 resurrect` rebuild processes after a restore)
  archive pm2 /root/.pm2/dump.pm2 /home/*/.pm2/dump.pm2

  backup_databases

  (cd "$DEST" && sha256sum -- *.gz > SHA256SUMS 2>/dev/null)
  local size; size=$(du -sh "$DEST" | awk '{print $1}')
  log "local backup done: $size"

  # Offsite copy — a backup on the same disk dies with the server
  if [ -n "$RCLONE_REMOTE" ]; then
    if ! command -v rclone >/dev/null 2>&1; then
      fail "RCLONE_REMOTE is set but rclone is not installed"
    elif rclone copy "$DEST" "$RCLONE_REMOTE/$ID" --transfers 2 2>"$BACKUP_DIR/.rclone.err"; then
      log "offsite copy → $RCLONE_REMOTE/$ID"
      rclone delete "$RCLONE_REMOTE" --min-age "${KEEP_REMOTE_DAYS}d" 2>/dev/null || true
      rclone rmdirs "$RCLONE_REMOTE" --leave-root 2>/dev/null || true
    else
      fail "rclone copy: $(tail -1 "$BACKUP_DIR/.rclone.err")"
    fi
    rm -f "$BACKUP_DIR/.rclone.err"
  else
    log "offsite: disabled (set RCLONE_REMOTE in $CONF)"
  fi

  # Local retention — only touch our own timestamped dirs
  # (-name glob instead of -regex: busybox find on Alpine has no -regextype)
  find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d \
    -name '[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]' \
    -mtime +"$KEEP_DAYS" -exec rm -rf {} + 2>/dev/null

  if [ ${#FAILURES[@]} -gt 0 ]; then
    notify "Backup finished with ${#FAILURES[@]} error(s)" "$(printf '%s\n' "${FAILURES[@]}")" critical
    exit 1
  fi
  notify "Backup OK" "$ID — $size${RCLONE_REMOTE:+ (offsite ✓)}" info
  log "OK"
}

cmd_list() {
  local id
  for id in $(ls -1 "$BACKUP_DIR" 2>/dev/null | grep -E '^[0-9]{8}-[0-9]{6}$' | sort); do
    printf '%s  %6s  %s\n' "$id" "$(du -sh "$BACKUP_DIR/$id" | awk '{print $1}')" \
      "$(grep -v '^#' "$BACKUP_DIR/$id/MANIFEST" 2>/dev/null | awk '{print $2}' | tr '\n' ' ')"
  done
}

cmd_verify() {
  local id="${1:-$(latest_id)}"
  [ -n "$id" ] && [ -d "$BACKUP_DIR/$id" ] || { echo "No backup '$id'" >&2; exit 1; }
  cd "$BACKUP_DIR/$id" || exit 1
  local ok=true f
  sha256sum -c SHA256SUMS >/dev/null || ok=false
  for f in *.gz; do gzip -t "$f" 2>/dev/null || { echo "corrupt: $f" >&2; ok=false; }; done
  $ok && echo "[backup] $id verified" || { echo "[backup] $id FAILED verification" >&2; exit 1; }
}

cmd_extract() {
  local id="${1:-}" dir="${2:-}"
  [ -n "$id" ] && [ -d "$BACKUP_DIR/$id" ] || { echo "Usage: backup.sh extract <id> [dir]" >&2; exit 1; }
  dir="${dir:-/var/backups/restore-$id}"
  mkdir -p "$dir" && chmod 700 "$dir"
  local f
  for f in "$BACKUP_DIR/$id"/*.tar.gz; do
    [ -f "$f" ] || continue
    mkdir -p "$dir/$(basename "$f" .tar.gz)"
    tar -xzf "$f" -C "$dir/$(basename "$f" .tar.gz)"
  done
  cp "$BACKUP_DIR/$id"/*.sql.gz "$BACKUP_DIR/$id"/*.rdb.gz "$dir/" 2>/dev/null || true
  echo "[backup] extracted to $dir — compare with live files before copying anything back"
}

case "${1:-run}" in
  run)     cmd_run ;;
  list)    cmd_list ;;
  verify)  shift; cmd_verify "$@" ;;
  extract) shift; cmd_extract "$@" ;;
  *)       sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
