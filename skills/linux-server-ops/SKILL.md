---
name: linux-server-ops
description: Manage, deploy, and monitor Linux servers over SSH — an AI-driven alternative to BaoTa (宝塔) / 1Panel. Deploys static sites and Node.js/Java/Python/Go/PHP services, MySQL/PostgreSQL/Redis, Docker Compose stacks, Nginx vhosts, SSL (auto-issue + renew), WAF, firewall, cron, logs, users, monitoring and backups, with boot auto-start. Keeps a server-side index and local snapshots to resume across sessions, and routes SSH through Clash/V2Ray/VPN proxies automatically. Use when the user wants to deploy to, operate, troubleshoot, or resume work on a Linux server (部署、运维、服务器管理).
---

# Linux Server Operations

`<skill_dir>` below means the directory containing this SKILL.md (e.g. `~/.claude/skills/linux-server-ops`, `~/.cursor/skills/linux-server-ops`, or the plugin's `skills/linux-server-ops`). Resolve it once per session and use the absolute path.

---

## ⚠ SENSITIVE DATA — MANDATORY OUTPUT RULES

**These rules apply to EVERY response. No exceptions.**

| Never show in chat | Where it appears | Say instead |
|---|---|---|
| Server IP / hostname | snapshot `meta.public_ip`, `_connection.host` | Server ID only: `prod-web` |
| SSH key path or content | `_connection.key_path`, `servers.json`, `-----BEGIN … KEY-----` | `"configured key"` |
| SSH password | Runtime only, never stored | `"password auth configured"` |
| `.env` / config secrets | `*_PASS`, `*_KEY`, `*_SECRET`, `*_TOKEN`, `JWT_SECRET`, DB URLs with credentials | `KEY=***` (show key names, mask values) |

- Run real commands silently via the tool; when explaining a command in chat, use `<key>`, `<host>`, `<pass>` placeholders and prefix with the server ID: `# [prod-web] Running: systemctl restart my-api`.
- When showing config files, keep non-secret values (`DB_HOST=db.internal`, `DB_USER=myapp`) and mask secrets (`DB_PASS=***`).
- Never put a password on a command line (`mysql -p<pass>`, `sshpass -p`) — it is visible in `ps` and shell history. Use socket auth, `~/.my.cnf`, or env vars.
- Generate new secrets on the server (`openssl rand -base64 24`) and write them straight into the target file; never echo them back.

**Before every response:** no IP, no key path, no secret value, SSH examples use placeholders.

---

## Session Start — Read Context First

**Before doing anything**, check for local context in the workspace:

```
.server/
├── servers.json          ← SSH configs for all managed servers
└── snapshots/
    └── <server-id>.json  ← Latest server state snapshot
```

```bash
ls .server/servers.json 2>/dev/null && echo "Context found" || echo "No context — need SSH details"
```

- **Context exists** → read `.server/servers.json` and `.server/snapshots/<id>.json`. You now know every server, service, database, container, domain and cert. Skip discovery questions.
- **No context** → ask for SSH details (below), create `servers.json`, then run Step 1–2.
- **After significant changes** → run `bash <skill_dir>/scripts/sync-context.sh <server-id>` to refresh the snapshot.

### What you need from the user (first time)

`server_id` (short name, e.g. `prod-web`), `host`, `port` (default 22), `user` (ubuntu, root, ec2-user…), `key_path` (e.g. `~/.ssh/prod_key`), optional `label`. Or let the user run `bash <skill_dir>/scripts/sync-context.sh --add` to enter them interactively (supports password auth).

---

## SSH Command Pattern

**Always go through `ssh-proxy.sh`.** It detects Clash/V2Ray/sing-box/Surge proxies and TUN VPNs, routes SSH accordingly, and retries only on connection failure (exit 255) — never re-running a remote command.

```bash
SP="bash <skill_dir>/scripts/ssh-proxy.sh"

# Single command
$SP ssh -i <key> -p <port> <user>@<host> '<command>'

# Multi-line script
$SP ssh -i <key> -p <port> <user>@<host> 'bash -s' << 'EOF'
# commands here
EOF

# Upload / download
$SP scp -i <key> -P <port> <local_file> <user>@<host>:<remote_path>
$SP scp -i <key> -P <port> <user>@<host>:<remote_file> <local_path>

# Directory sync
rsync -avz -e "$SP ssh -i <key> -p <port>" <local_dir>/ <user>@<host>:<remote_dir>/
```

The examples in the rest of this file abbreviate this as `ssh … user@host '…'`; always expand it to the `$SP ssh` form above. Use `sudo` when the SSH user is not root.

**Connection still fails?** Run `$SP detect` to see what was found, then follow [ssh-proxy-guide.md](ssh-proxy-guide.md) (port table, TUN vs System Proxy, manual tests). If the user's proxy uses an unusual port, have them `export ALL_PROXY=socks5://127.0.0.1:<port>`.

---

## Step 1: Detect System

```bash
ssh … user@host 'bash -s' << 'EOF'
echo "=OS=" && grep -E "^ID=|^VERSION_ID=" /etc/os-release 2>/dev/null
echo "=ARCH=" && uname -m
echo "=INIT=" && ps -p 1 -o comm= 2>/dev/null
echo "=RAM=" && free -h | awk '/^Mem:/{print $2}'
echo "=DISK=" && df -h / | awk 'NR==2{print $2, $5}'
echo "=INSTALLED="
for t in nginx certbot mysql psql redis-cli docker node java python3 php pm2 git jq; do
  command -v $t &>/dev/null && echo "$t:yes" || echo "$t:missing"
done
EOF
```

Map distro → package manager and paths via [distro-guide.md](distro-guide.md).

---

## Step 2: Bootstrap Server (First Time)

```bash
TOOLS="service-registry.sh generate-index.sh service-control.sh backup.sh release.sh notify.sh"
for s in check-system.sh $TOOLS; do
  $SP scp -i <key> -P <port> <skill_dir>/scripts/$s user@host:/tmp/
done
ssh … user@host "sudo bash /tmp/check-system.sh && sudo mkdir -p /opt/server-tools /etc/server-tools && \
  cd /tmp && sudo mv $TOOLS /opt/server-tools/ && sudo chmod +x /opt/server-tools/*.sh"
```

Installs `nginx`, `certbot`, `fail2ban`, `ufw`/`firewalld`, `jq`, `rsync`, `htop`, `logrotate`, creates the standard directories, and initializes the server index. `sync-context.sh` also uploads any missing management scripts automatically.

Then, with the user: configure alerts (`notify.sh`, [monitoring-guide.md](monitoring-guide.md) → Alerting), schedule `backup.sh` with an offsite target ([backup-guide.md](backup-guide.md)), and add an external uptime monitor.

---

## Step 3: Server Index (Memory on Server)

Two files, one view:

- `/etc/server-registry.json` — **declared**: what you deployed and why (domain, git repo, env file, notes). Written only by `service-registry.sh set|remove`.
- `/etc/server-index.json` — **observed**: full scan of the live server by `generate-index.sh`, with registry entries merged into `services[]` (`registered: true`; `detected: false` if declared but not running). This is what snapshots contain. `service-registry.sh set|remove` regenerates it automatically.

Index top-level keys:

| Key | Contents |
|---|---|
| `meta` | hostname, public_ip, os, updated |
| `websites[]` | name, domain, type, root, nginx_conf, ssl, ssl_expires, git_repo |
| `services[]` | name, type (nodejs/java/python/go/php), domain, root, port, process_manager, env_file, log_dir, deployed_at |
| `databases[]` | engine, version, port, socket/config, databases[], data_dir |
| `docker.compose_projects[]` | name, dir, compose_file, services[] |
| `cron_jobs[]` | schedule, command, user |
| `firewall` | engine, open_ports[] |

```bash
ssh … user@host 'sudo bash /opt/server-tools/generate-index.sh'            # regenerate from live state
ssh … user@host 'sudo bash /opt/server-tools/service-registry.sh list'     # list everything
ssh … user@host 'sudo bash /opt/server-tools/service-registry.sh health'   # health check all
ssh … user@host 'sudo bash /opt/server-tools/service-registry.sh set <name> "{...}"'  # add/update entry
```

**Update the index after every deploy or removal** so the next session sees it.

---

## Local Context File (Memory in Workspace)

`.server/servers.json` lets any new session know every server without asking:

```json
{
  "default": "prod-web",
  "servers": {
    "prod-web": {
      "label": "Production Web Server",
      "host": "1.2.3.4",
      "port": 22,
      "user": "ubuntu",
      "auth_type": "key",
      "key_path": "~/.ssh/prod_key",
      "tags": ["production", "web"],
      "snapshot": ".server/snapshots/prod-web.json"
    }
  }
}
```

**Always** make sure `.server/` is git-ignored — it contains IPs, key paths and the full server layout:

```bash
grep -qxF '.server/' .gitignore 2>/dev/null || echo '.server/' >> .gitignore
```

```bash
bash <skill_dir>/scripts/sync-context.sh <server-id>   # pull state → .server/snapshots/<id>.json
bash <skill_dir>/scripts/sync-context.sh --all         # all servers
bash <skill_dir>/scripts/sync-context.sh --list        # list configured servers
```

---

## Step 4: Deploy a Service

Full per-type workflows: [deploy-guide.md](deploy-guide.md).

| Type    | Process Manager  | App Root                   | Default Port | Auto-Start |
|---------|------------------|----------------------------|--------------|------------|
| Static  | nginx            | /var/www/\<name\>          | 80/443       | `systemctl enable nginx` |
| Node.js | pm2              | /var/www/\<name\>          | as defined   | `pm2 startup` + `pm2 save` |
| Java    | systemd          | /opt/java-apps/\<name\>    | 8080         | `systemctl enable <name>` |
| Python  | systemd+gunicorn | /opt/python-apps/\<name\>  | 8000         | `systemctl enable <name>` |
| Go      | systemd          | /opt/go-apps/\<name\>      | 8080         | `systemctl enable <name>` |
| PHP     | php-fpm + nginx  | /var/www/\<name\>          | 80/443       | `systemctl enable php<v>-fpm` |
| Docker  | docker compose   | /opt/docker-apps/\<name\>  | as mapped    | `restart: unless-stopped` |

Standard directories: app roots above, `/etc/nginx/sites-available/` (+ `sites-enabled/` symlinks), `/etc/systemd/system/`, `/var/log/apps/<name>/`, `/opt/server-tools/`, `/var/backups/`.

**Every deploy of an existing app:**

1. **Before:** `release.sh snapshot <name>` (plus `backup.sh run` if the release migrates the database).
2. Deploy.
3. **Verify readiness, not just a 200:** `nginx -t` → service running and enabled for boot → `/readyz` (or a real DB-backed request) answers → public HTTPS URL contains an expected keyword → no new errors in the log. Script: [deploy-guide.md](deploy-guide.md) → Post-Deploy Verification.
4. **Any check fails → `release.sh rollback <name>` first, debug second.**
5. `service-registry.sh set <name> '{…}'` → sync the local snapshot.

---

## Step 5: Domain + SSL

```bash
# DNS must already point at the server — verify first
ssh … user@host 'dig +short <domain>'

ssh … user@host "sudo certbot --nginx -d <domain> -d www.<domain> \
  --non-interactive --agree-tos --email <admin-email> --redirect"

ssh … user@host 'sudo certbot renew --dry-run'      # test auto-renewal
ssh … user@host 'sudo certbot certificates'         # list certs + expiry
ssh … user@host 'sudo certbot renew --cert-name <domain> --force-renewal'
```

---

## Step 6: Database Operations

Details: [deploy-guide.md](deploy-guide.md) → Database Setup. Use socket auth (`sudo mysql`, `sudo -u postgres`) so no password touches the command line.

```bash
# MySQL / MariaDB: create DB + user with a generated password written to the app's .env
ssh … user@host 'bash -s' << 'EOF'
PASS=$(openssl rand -base64 24 | tr -d '/+=')
sudo mysql -e "CREATE DATABASE IF NOT EXISTS <dbname> CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
  CREATE USER IF NOT EXISTS '<dbuser>'@'localhost' IDENTIFIED BY '${PASS}';
  GRANT ALL PRIVILEGES ON <dbname>.* TO '<dbuser>'@'localhost'; FLUSH PRIVILEGES;"
echo "DB_PASS=${PASS}" | sudo tee -a <app_root>/.env >/dev/null && sudo chmod 600 <app_root>/.env
EOF

# PostgreSQL
ssh … user@host 'bash -s' << 'EOF'
PASS=$(openssl rand -base64 24 | tr -d '/+=')
sudo -u postgres psql -c "CREATE USER <dbuser> WITH ENCRYPTED PASSWORD '${PASS}';" \
                      -c "CREATE DATABASE <dbname> OWNER <dbuser>;"
echo "DB_PASS=${PASS}" | sudo tee -a <app_root>/.env >/dev/null && sudo chmod 600 <app_root>/.env
EOF

ssh … user@host 'sudo mysql -e "SHOW DATABASES;"'   # list MySQL DBs
ssh … user@host 'redis-cli ping'                    # Redis status
```

If MySQL root uses password auth instead of the socket, put credentials in `/root/.my.cnf` (`chmod 600`) — `mysql` reads it automatically.

---

## Step 7: Docker

Full workflows: [deploy-guide.md](deploy-guide.md) → Docker.

```bash
ssh … user@host 'docker ps'
ssh … user@host 'cd /opt/docker-apps/<name> && docker compose ps'
ssh … user@host 'cd /opt/docker-apps/<name> && docker compose pull && docker compose up -d'   # update
ssh … user@host 'cd /opt/docker-apps/<name> && docker compose logs --tail=100'
ssh … user@host 'docker system prune -f'   # ask before running: removes stopped containers + dangling images
```

Use `logs --tail=N`, not `logs -f` — a follow stream never returns through a non-interactive SSH call.

---

## Step 8: Service Control

`service-control.sh` auto-detects the type (PM2 / systemd / Docker Compose / Nginx) and runs the right command.

```bash
SC='sudo bash /opt/server-tools/service-control.sh'
ssh … user@host "$SC status"                 # all services + boot auto-start flag
ssh … user@host "$SC status <name>"
ssh … user@host "$SC start|stop|restart <name>"
ssh … user@host "$SC reload <name>"          # zero-downtime where supported
ssh … user@host "$SC boot-check"             # verify boot auto-start for everything
ssh … user@host "$SC boot-fix"               # enable auto-start for all detected services
ssh … user@host "$SC enable <name>"
ssh … user@host "$SC logs <name> 200"
```

| Type | `reload` | `restart` |
|------|---------|----------|
| PM2 (Node.js) | Graceful cluster reload — 0 downtime | Hard restart, brief gap |
| systemd (Java/Python/Go) | SIGHUP if supported, else restart | Full process restart |
| Nginx | Config reload — 0 downtime | Full restart |
| Docker Compose | Falls back to restart | Recreate containers |

---

## Step 9: Monitor & Maintain

Full setup: [monitoring-guide.md](monitoring-guide.md). Three layers, set up in this order:

1. **External uptime monitor** (UptimeRobot, Uptime Kuma on another host, 云拨测) on each domain's health endpoint — the only thing that notices when the whole server is down.
2. **Alerts via `notify.sh`** (企业微信 / 钉钉 / 飞书 / Telegram / Bark) from the watchdog, resource checks and backups. `mail` does not work on most VPSes (port 25 blocked).
3. **On-demand checks** below.

```bash
ssh … user@host 'sudo bash /opt/server-tools/service-registry.sh health'
ssh … user@host 'uptime && free -h && df -h /'
ssh … user@host 'pm2 status 2>/dev/null; systemctl list-units --type=service --state=running --no-pager | tail -20'
ssh … user@host 'sudo journalctl -p err --since "1h ago" --no-pager -n 30'
```

---

## Diagnosis Order

When something is wrong, go in this order and stop at the first finding — each step is cheap and rules out a whole class of causes:

1. **Running?** `service-control.sh status <name>`
2. **Logs?** `service-control.sh logs <name> 200`, `/var/log/nginx/error.log`, `journalctl -p err --since "1h ago"`
3. **Resources?** `df -h`, `df -i`, `free -h`, `uptime`, `dmesg | grep -i oom`
4. **Network?** `ss -tlnp`, `curl -v localhost:<port>/readyz`, `dig +short <domain>`, firewall
5. **Dependencies?** DB / Redis up and not full, external APIs, certificate expiry

If the cause is a recent deploy, roll back before investigating further. Symptom table and capacity decisions (when to optimize vs. scale up vs. add swap): [monitoring-guide.md](monitoring-guide.md).

---

## Backup & Rollback

Full guide: [backup-guide.md](backup-guide.md).

```bash
B='sudo bash /opt/server-tools/backup.sh'
ssh … "$B run"                 # apps, configs, certs, MySQL/PostgreSQL/Redis dumps (+ offsite via rclone if configured)
ssh … "$B list"
ssh … "$B verify [<id>]"       # checksums + archive integrity
ssh … "$B extract <id>"        # unpack into /var/backups/restore-<id>/ — never over live files

R='sudo bash /opt/server-tools/release.sh'
ssh … "$R snapshot <name>"     # before every deploy (cheap: hard-linked)
ssh … "$R rollback <name>"     # restore files + restart; current state kept as *-pre-rollback
```

- Ask the user to set up an **offsite** target (`RCLONE_REMOTE` in `/etc/server-tools/backup.conf`) — a local-only backup dies with the server. Cloud credentials are entered by the user via `ssh -t … 'sudo rclone config'`, never through chat.
- Restoring a database overwrites data: confirm with the user, and dump the current state first.

---

## Common Operations

| Task | Command |
|------|---------|
| Locate a service | Read the snapshot, or `ssh … 'sudo jq .services /etc/server-index.json'` |
| Update deployed app | `ssh … 'cd <root> && git pull && <build> && <reload>'` |
| Check Nginx config | `ssh … 'sudo nginx -t'` |
| Renew all SSL | `ssh … 'sudo certbot renew'` |
| View app logs | `ssh … 'tail -n 200 /var/log/apps/<name>/app.log'` |
| Open ports + process | `ssh … 'sudo ss -tlnp'` |
| Connections | `ssh … 'ss -s'` |
| Interfaces / routes | `ssh … 'ip addr show && ip route show'` |
| DNS + HTTPS check | `ssh … 'dig +short <domain> && curl -sI --max-time 5 https://<domain>'` |
| Bandwidth | `ssh … 'vnstat'` (if missing, ask before installing) |
| Sync local context | `bash <skill_dir>/scripts/sync-context.sh <server-id>` |

Never run interactive/full-screen tools over a non-interactive SSH call (`nano`, `vim`, `crontab -e`, `top`, `nload`, `tail -f`). Use `sed`/heredocs to edit, `top -bn1`, `tail -n`.

---

## WAF & Firewall

Full details: [waf-guide.md](waf-guide.md). Layers: Nginx rate limiting → security headers → ModSecurity + OWASP CRS → fail2ban → UFW/firewalld.

```bash
ssh … user@host 'sudo bash -s' << 'EOF'
echo "Nginx: $(systemctl is-active nginx)"
echo "fail2ban: $(systemctl is-active fail2ban)"
echo "UFW: $(ufw status 2>/dev/null | head -1)"
echo "ModSecurity: $(nginx -T 2>/dev/null | grep -c modsecurity) directives"
echo "Top 4xx/5xx sources (last 500 reqs):"
tail -500 /var/log/nginx/access.log 2>/dev/null | awk '$9~/^[45]/{print $1}' | sort | uniq -c | sort -rn | head -5
EOF
```

`ip-manager.sh` (block/unblock IPs) and `attack-monitor.sh` are defined in waf-guide.md — install them to `/opt/server-tools/` from there before use.

---

## Logs

Full details: [log-guide.md](log-guide.md) (defines `error-summary.sh` and `show-logs.sh`).

```bash
ssh … user@host "sudo awk '{print \$1}' /var/log/nginx/access.log | sort | uniq -c | sort -rn | head -10"   # top IPs
ssh … user@host "sudo awk '{print \$9}' /var/log/nginx/access.log | sort | uniq -c | sort -rn"             # status codes
ssh … user@host 'sudo du -sh /var/log/nginx/ /var/log/apps/ && sudo journalctl --disk-usage'
```

---

## Files, Users, Cron

- **Files** — browse, upload, permissions, archives, search: [file-ops-guide.md](file-ops-guide.md). Web permission baseline: dirs `755`, files `644`, `.env` `600`.
- **Users** — deploy users, sudo, SSH keys, SFTP chroot, session audit: [user-management-guide.md](user-management-guide.md).
- **Cron** — prefer files in `/etc/cron.d/` (one job per file, easy to remove):

```bash
ssh … user@host 'sudo bash /opt/server-tools/service-registry.sh cron'   # list all jobs
ssh … user@host "echo '30 3 * * * root bash /opt/server-tools/backup.sh run >> /var/log/backup.log 2>&1' | sudo tee /etc/cron.d/server-backup"
ssh … user@host 'sudo rm /etc/cron.d/<job-name>'
ssh … user@host 'systemctl list-timers --no-pager'                       # systemd timers
```

`watchdog.sh` and `resource-alert.sh` are defined in [monitoring-guide.md](monitoring-guide.md).

---

## Safety Rules for Changes

- **Confirm first** before anything destructive or hard to undo: deleting files/sites/databases, `DROP`, `docker system prune`, firewall changes, `sshd_config` edits, user deletion, package removal.
- **Back up before editing** a config: `cp file file.bak.$(date +%s)`.
- **Validate before reload**: `nginx -t`, `sshd -t`, `docker compose config`.
- **Never lock yourself out**: before enabling a firewall or changing SSH port/auth, make sure the current SSH port is allowed and test a second connection before closing the first.

---

## Security Checklist

Full details: [security-guide.md](security-guide.md) and [waf-guide.md](waf-guide.md).

- [ ] SSH: key-only auth, no root login, `sshd -t && systemctl reload sshd`
- [ ] Firewall: only 22/80/443 open
- [ ] fail2ban: sshd + nginx jails enabled
- [ ] ModSecurity + OWASP CRS active; Nginx rate limiting configured
- [ ] Security headers in `/etc/nginx/conf.d/security.conf`
- [ ] `.env` files `chmod 600`, never in git
- [ ] `/etc/server-index.json`: `chmod 600 && chown root:root`
- [ ] Automatic security updates (`unattended-upgrades` / `dnf-automatic`)
- [ ] SFTP chroot for web-only users
- [ ] Daily `backup.sh` with offsite copy; restore drill done in the last month
- [ ] External uptime monitor + `notify.sh` alerts working (`notify.sh --test`)

---

## Additional Resources

| File | Contents |
|------|---------|
| [backup-guide.md](backup-guide.md) | Backups, offsite copies, restore procedures, deploy rollback |
| [ssh-proxy-guide.md](ssh-proxy-guide.md) | SSH through Clash/V2Ray/VPN: detection, port table, troubleshooting |
| [distro-guide.md](distro-guide.md) | Per-distro package commands, Nginx paths, PHP-FPM sockets |
| [deploy-guide.md](deploy-guide.md) | Static, Node.js, Java, Python, PHP, Docker, database deployments |
| [waf-guide.md](waf-guide.md) | ModSecurity, OWASP CRS, rate limiting, IP blocking, DDoS mitigation |
| [monitoring-guide.md](monitoring-guide.md) | Webhook alerts, external uptime, health endpoints, diagnosis, scaling, swap |
| [log-guide.md](log-guide.md) | Log viewing, searching, rotation, GoAccess, Loki/Promtail |
| [file-ops-guide.md](file-ops-guide.md) | Browse, edit, permissions, compress, transfer, search |
| [security-guide.md](security-guide.md) | SSH hardening, auditd, intrusion detection, kernel tuning, backups |
| [user-management-guide.md](user-management-guide.md) | Users, sudo, SSH keys, SFTP chroot, session auditing |
| [scripts/ssh-proxy.sh](scripts/ssh-proxy.sh) | Local: proxy/VPN-aware `ssh`/`scp` wrapper |
| [scripts/sync-context.sh](scripts/sync-context.sh) | Local: manage `.server/servers.json`, pull snapshots |
| [scripts/check-system.sh](scripts/check-system.sh) | Server: bootstrap a new server |
| [scripts/generate-index.sh](scripts/generate-index.sh) | Server: full scan → `/etc/server-index.json` |
| [scripts/service-registry.sh](scripts/service-registry.sh) | Server: index management + health/db/docker/cron |
| [scripts/service-control.sh](scripts/service-control.sh) | Server: unified start/stop/restart/reload/boot-check |
| [scripts/backup.sh](scripts/backup.sh) | Server: full backup + DB dumps + offsite, verify, extract |
| [scripts/release.sh](scripts/release.sh) | Server: pre-deploy snapshots and rollback |
| [scripts/notify.sh](scripts/notify.sh) | Server: alerts to 企业微信/钉钉/飞书/Telegram/Bark/Slack |
