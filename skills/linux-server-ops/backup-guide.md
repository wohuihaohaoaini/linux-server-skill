# Backup, Restore & Rollback

Two different safety nets:

| | `backup.sh` | `release.sh` |
|---|---|---|
| Protects against | Disk failure, deleted server, ransomware, bad DB migration | A bad deploy |
| Scope | Whole server: apps, configs, certs, all databases | One app's files |
| Frequency | Daily (cron) | Before every deploy |
| Restore time | Minutes–hours | Seconds |
| Where | Local + offsite (rclone) | Local only |

Install both (plus `notify.sh` for failure alerts) into `/opt/server-tools/` — Step 2 in SKILL.md does this.

---

## Daily Backup

```bash
# First run by hand, check the result, then schedule it
ssh … 'sudo bash /opt/server-tools/backup.sh run'
ssh … 'sudo bash /opt/server-tools/backup.sh list'
ssh … 'sudo bash /opt/server-tools/backup.sh verify'

ssh … "echo '30 3 * * * root bash /opt/server-tools/backup.sh run >> /var/log/backup.log 2>&1' | sudo tee /etc/cron.d/server-backup"
```

What one run contains (`<BACKUP_DIR>/<YYYYmmdd-HHMMSS>/`):

| File | Contents |
|---|---|
| `apps.tar.gz` | `/var/www`, `/opt/{java,python,go,docker}-apps` — without `node_modules`, venvs, caches, `*.log` |
| `nginx.tar.gz`, `letsencrypt.tar.gz`, `systemd.tar.gz`, `cron.tar.gz` | Web server, certificates (incl. private keys), units, cron |
| `server-tools.tar.gz` | Scripts, `/etc/server-tools/*.conf`, server index + registry |
| `security.tar.gz` | sshd, fail2ban, ufw/firewalld config |
| `pm2.tar.gz` | PM2 process list (`pm2 resurrect` after restore) |
| `mysql-all.sql.gz` | `mysqldump --all-databases --single-transaction` (consistent for InnoDB, no lock) |
| `postgres-all.sql.gz` | `pg_dumpall` (databases + roles) |
| `redis.rdb.gz` | Live RDB snapshot via `redis-cli --rdb` |
| `MANIFEST`, `SHA256SUMS` | What was included; checksums for `verify` |

**Not included:** Docker named volumes. For Compose stacks with state, either bind-mount data under `/opt/docker-apps/<name>/` (then it is in `apps.tar.gz`) or add the volume's mountpoint (`docker volume inspect -f '{{.Mountpoint}}' <vol>`) to `EXTRA_PATHS`. Dump databases running *inside* containers with `docker exec <db> mysqldump …` from a cron job writing into `/opt/docker-apps/<name>/backup/`.

MySQL needs non-interactive root access: socket auth (Ubuntu/Debian default) or `/root/.my.cnf` with `chmod 600`. Otherwise the run reports an error instead of silently skipping.

---

## Offsite Copy (strongly recommended)

A backup on the same disk dies with the server. `backup.sh` pushes each run with [rclone](https://rclone.org), which supports Aliyun OSS, Tencent COS, Qiniu, S3, Backblaze B2, Cloudflare R2, SFTP, WebDAV and more.

```bash
# 1. Install rclone on the server
ssh … 'curl -fsSL https://rclone.org/install.sh | sudo bash'

# 2. Configure a remote interactively — the USER must run this in their own
#    terminal (it asks for access keys; never pass keys through chat)
ssh -t … 'sudo rclone config'
#    For extra safety, add a "crypt" remote on top so the bucket only holds
#    encrypted data — backups include TLS private keys and .env files.

# 3. Point backup.sh at it
ssh … 'sudo mkdir -p /etc/server-tools && sudo tee /etc/server-tools/backup.conf >/dev/null' <<'EOF'
RCLONE_REMOTE="oss:my-bucket/web-01"
KEEP_DAYS=7
KEEP_REMOTE_DAYS=30
EOF
ssh … 'sudo chmod 600 /etc/server-tools/backup.conf && sudo bash /opt/server-tools/backup.sh run'
ssh … 'sudo rclone lsd oss:my-bucket/web-01'
```

Use a bucket-scoped access key that can write but ideally not delete (object lock / versioning), so a compromised server cannot wipe its own offsite backups.

---

## Restore

**Rule: restore into a staging directory first, compare, then copy.** Never extract straight over live files.

```bash
ssh … 'sudo bash /opt/server-tools/backup.sh list'
ssh … 'sudo bash /opt/server-tools/backup.sh verify <id>'
ssh … 'sudo bash /opt/server-tools/backup.sh extract <id>'      # → /var/backups/restore-<id>/
```

The staging dir mirrors absolute paths: `restore-<id>/apps/var/www/<name>/…`, `restore-<id>/nginx/etc/nginx/…`.

### One app's files

```bash
ssh … 'sudo bash /opt/server-tools/release.sh snapshot <name>'   # safety copy of current state
ssh … 'sudo diff -rq /var/backups/restore-<id>/apps/var/www/<name> /var/www/<name> | head -50'
ssh … 'sudo rsync -a --delete /var/backups/restore-<id>/apps/var/www/<name>/ /var/www/<name>/'
# then reinstall deps (npm ci / pip install) and restart
ssh … 'sudo bash /opt/server-tools/service-control.sh restart <name>'
```

### One MySQL database (from the all-databases dump)

Confirm with the user first — this overwrites the database.

```bash
ssh … 'bash -s' <<'EOF'
ID=<id>; DB=<dbname>
sudo mysqldump --single-transaction "$DB" | gzip > "/var/backups/pre-restore-$DB-$(date +%s).sql.gz"
# Pull just this database's section out of the full dump
zcat "/var/backups/server/$ID/mysql-all.sql.gz" \
  | sed -n "/^-- Current Database: \`$DB\`/,/^-- Current Database: \`/p" \
  | sudo mysql
EOF
```

### PostgreSQL / Redis

```bash
# PostgreSQL: whole cluster (fresh server), or edit the dump to one DB first
zcat /var/backups/server/<id>/postgres-all.sql.gz | sudo -u postgres psql

# Redis: stop, replace the RDB, start
sudo systemctl stop redis-server        # or: redis
zcat /var/backups/server/<id>/redis.rdb.gz | sudo tee /var/lib/redis/dump.rdb >/dev/null
sudo chown redis:redis /var/lib/redis/dump.rdb && sudo systemctl start redis-server
```

### Whole server (new machine)

1. Bootstrap the new server (SKILL.md Step 1–2).
2. Fetch the backup: `rclone copy oss:my-bucket/web-01/<id> /var/backups/server/<id>`, then `backup.sh verify <id>` and `extract <id>`.
3. Copy back `nginx`, `letsencrypt`, `systemd`, `cron`, `server-tools`, then `apps`.
4. Install runtimes (Node/Java/Python/PHP) and databases, then load the SQL dumps and the Redis RDB.
5. Reinstall deps per app, `systemctl daemon-reload`, `pm2 resurrect`, `nginx -t && systemctl reload nginx`.
6. Point DNS at the new IP; run `generate-index.sh` and sync the local snapshot.

### Restore drill

Untested backups are hopes, not backups. Once a month (or after changing the setup): `verify` the latest backup, `extract` it, load one database dump into a scratch database (`CREATE DATABASE restore_test` → import → spot-check row counts → `DROP`), then delete the staging dir.

---

## Deploy Rollback (`release.sh`)

```bash
# BEFORE every deploy
ssh … 'sudo bash /opt/server-tools/release.sh snapshot <name>'

# Deploy… then health check fails?
ssh … 'sudo bash /opt/server-tools/release.sh diff <name>'       # what changed
ssh … 'sudo bash /opt/server-tools/release.sh rollback <name>'   # restore + restart
ssh … 'sudo bash /opt/server-tools/release.sh list <name>'       # older snapshots (keeps 5)
ssh … 'sudo bash /opt/server-tools/release.sh rollback <name> <id>'
```

- Snapshots use `rsync --link-dest`: unchanged files are hard links, so a snapshot costs only the bytes that changed. `node_modules`/venvs are included, so a rollback restores the exact dependency set too.
- A rollback first saves the current (broken) state as `<id>-pre-rollback`, so it can be undone.
- Rollback restores **files only**. If the deploy ran a database migration, roll that back with the framework's tool (`php artisan migrate:rollback`, `alembic downgrade -1`, …) or restore the DB from `backup.sh` — decide with the user.
- Docker Compose apps: roll back by pinning the previous image tag in `docker-compose.yml` and `docker compose up -d`; `release.sh` covers the compose files and bind-mounted data only.
