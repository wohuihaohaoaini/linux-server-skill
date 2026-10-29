# Monitoring Guide

System and service monitoring setup for Linux servers.

---

## Quick Status Dashboard

Run this on any server for an instant health overview:

```bash
echo "========== SYSTEM =========="
uptime && free -h && df -h /
echo "========== PROCESSES ======="
ps aux --sort=-%cpu | head -10
echo "========== NETWORK =========="
ss -tlnp
echo "========== NGINX ============"
systemctl is-active nginx && nginx -t 2>&1
echo "========== PM2 =============="
pm2 status 2>/dev/null || echo "PM2 not running"
echo "========== SYSTEMD SERVICES ="
systemctl list-units --type=service --state=running --no-pager | grep -v systemd
echo "========== SSL CERTS ========"
certbot certificates 2>/dev/null | grep -E "Domains:|Expiry Date:"
echo "========== ERRORS (24h) ====="
journalctl -p err --since "24h ago" --no-pager -n 20
```

---

## Service Health Checks

### Nginx

```bash
# Status
systemctl status nginx --no-pager
nginx -t                           # config test
curl -I http://localhost           # HTTP response

# Access / error logs
tail -f /var/log/nginx/access.log
tail -f /var/log/nginx/error.log
tail -f /var/log/nginx/<name>-error.log

# Request rate per domain
awk '{print $7}' /var/log/nginx/access.log | sort | uniq -c | sort -rn | head -20
# Top IPs by request count
awk '{print $1}' /var/log/nginx/access.log | sort | uniq -c | sort -rn | head -20
# 5xx errors in last 1000 requests
tail -1000 /var/log/nginx/access.log | awk '$9 ~ /^5/'
```

### Node.js (PM2)

```bash
pm2 status                         # all apps
pm2 info <name>                    # detailed info
pm2 logs <name> --lines 100        # recent logs
pm2 logs <name> --err --lines 50   # errors only
pm2 monit                          # live dashboard (interactive)
pm2 describe <name>                # full metadata

# Metrics
pm2 reset <name>                   # reset restart counter
pm2 flush <name>                   # clear logs

# Memory / CPU over time
pm2 logs <name> | grep -E "memory|cpu"
```

### Systemd Services (Java / Python)

```bash
systemctl status <name> --no-pager -l
journalctl -u <name> -f --no-pager          # follow logs
journalctl -u <name> --since "1h ago" --no-pager
journalctl -u <name> -p err --no-pager       # errors only

# Restart count
systemctl show <name> --property=NRestarts
# Last failure
systemctl show <name> --property=Result
```

### PHP-FPM

```bash
systemctl status php8.2-fpm --no-pager
# FPM status page (if configured)
curl http://127.0.0.1/php-fpm-status 2>/dev/null
# Slow requests log
tail -f /var/log/php8.2-fpm.log
```

---

## Resource Monitoring

### Real-time

```bash
htop                               # interactive CPU/memory/process view
iotop                              # disk I/O per process
nethogs                            # network usage per process
watch -n 2 'free -h && df -h /'   # memory + disk every 2s
```

### CPU & Memory Snapshots

```bash
# CPU usage summary
mpstat 1 5 2>/dev/null || vmstat 1 5

# Memory details
free -h
cat /proc/meminfo | grep -E "MemTotal|MemFree|MemAvailable|SwapTotal|SwapFree"

# Top memory-consuming processes
ps aux --sort=-%mem | head -10

# OOM killer events
dmesg | grep -i "oom\|killed process" | tail -20
journalctl -k | grep -i "oom" | tail -20
```

### Disk

```bash
df -h                              # disk usage all mounts
df -h /                            # root partition
du -sh /var/www/*                  # web app sizes
du -sh /var/log/*                  # log sizes
du -sh /opt/*                      # opt dir sizes

# Find large files
find /var/log -name "*.log" -size +100M -ls 2>/dev/null
find /var/www -name "*.log" -size +50M -ls 2>/dev/null

# Disk I/O stats
iostat -xz 1 5 2>/dev/null || vmstat -d
```

### Network

```bash
ss -tlnp                           # listening ports
ss -s                              # socket summary
netstat -an | grep ESTABLISHED | wc -l   # active connections

# Bandwidth (if iftop/nload installed)
iftop -n 2>/dev/null
nload 2>/dev/null

# Install network tools
apt-get install -y iftop nload nethogs sysstat 2>/dev/null
```

---

## Log Management

### Logrotate Setup

Ensure `/etc/logrotate.d/apps` exists for app logs:

```bash
cat > /etc/logrotate.d/apps << 'LOGROTATE'
/var/log/apps/*/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    sharedscripts
    postrotate
        pm2 reloadLogs 2>/dev/null || true
    endscript
}

/var/log/nginx/*.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    sharedscripts
    postrotate
        nginx -s reopen 2>/dev/null || true
    endscript
}
LOGROTATE

# Test logrotate config
logrotate --debug /etc/logrotate.d/apps
```

### Clean up old logs manually

```bash
# Logs older than 30 days
find /var/log/apps -name "*.log*" -mtime +30 -delete
# Journald space usage
journalctl --disk-usage
journalctl --vacuum-size=500M    # keep only 500MB of journald logs
journalctl --vacuum-time=30d     # keep only last 30 days
```

---

## SSL Certificate Monitoring

```bash
# List all certs with expiry
certbot certificates

# Days until expiry for a domain
echo | openssl s_client -connect <domain>:443 -servername <domain> 2>/dev/null \
  | openssl x509 -noout -enddate

# Check all certs will renew (dry run)
certbot renew --dry-run

# Cert expiry check script (put in cron)
cat > /opt/server-tools/check-ssl.sh << 'SCRIPT'
#!/bin/bash
WARN_DAYS=30
for domain in $(certbot certificates 2>/dev/null | grep "Domains:" | awk '{print $2}'); do
  expiry=$(echo | openssl s_client -connect $domain:443 -servername $domain 2>/dev/null \
    | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
  if [ -n "$expiry" ]; then
    days_left=$(( ($(date -d "$expiry" +%s) - $(date +%s)) / 86400 ))
    echo "$domain: expires in $days_left days ($expiry)"
    if [ "$days_left" -lt "$WARN_DAYS" ]; then
      echo "WARNING: $domain cert expires in $days_left days!"
    fi
  fi
done
SCRIPT
chmod +x /opt/server-tools/check-ssl.sh
```

---

## Uptime & Process Auto-Restart

### PM2 auto-restart (Node.js)

PM2 restarts automatically on crash. Configure max restarts and memory:

```javascript
// ecosystem.config.js
{
  max_restarts: 10,
  min_uptime: "5s",         // don't count restart if dies within 5s
  max_memory_restart: "512M",
  restart_delay: 3000       // wait 3s before restart
}
```

### Systemd auto-restart (Java/Python)

Already set in the service unit with:

```ini
Restart=on-failure
RestartSec=10
StartLimitIntervalSec=60
StartLimitBurst=5           # max 5 restarts in 60s
```

### Watchdog cron (simple uptime check)

```bash
cat > /opt/server-tools/watchdog.sh << 'SCRIPT'
#!/bin/bash
# Simple watchdog — check and restart dead services
LOG="/var/log/watchdog.log"
timestamp() { date '+%Y-%m-%d %H:%M:%S'; }
notify() { bash /opt/server-tools/notify.sh "$@" >/dev/null 2>&1 || true; }

check_nginx() {
  if ! systemctl is-active --quiet nginx; then
    echo "$(timestamp) nginx DOWN - restarting" >> $LOG
    systemctl restart nginx
    notify "nginx was down — auto-restarted" "$(systemctl is-active nginx)" critical
  fi
}

check_pm2() {
  if ! pm2 status 2>/dev/null | grep -q "online"; then
    echo "$(timestamp) PM2 apps check failed" >> $LOG
    pm2 resurrect
    notify "PM2 apps were down — resurrected" "$(pm2 jlist 2>/dev/null | jq -r '.[] | .name + ": " + .pm2_env.status' 2>/dev/null)" critical
  fi
}

check_service() {
  local name=$1
  if ! systemctl is-active --quiet $name; then
    echo "$(timestamp) $name DOWN - restarting" >> $LOG
    systemctl restart $name
    notify "$name was down — auto-restarted" "now: $(systemctl is-active $name)" critical
  fi
}

check_nginx
check_pm2
# Add your services:
# check_service my-java-app
# check_service my-python-app
SCRIPT
chmod +x /opt/server-tools/watchdog.sh

# Run every 5 minutes
echo "*/5 * * * * root bash /opt/server-tools/watchdog.sh" > /etc/cron.d/watchdog
```

---

## Lightweight Monitoring Stack (Optional)

For production environments, install one of these:

### Option A: Netdata (real-time, beautiful UI)

```bash
curl https://my-netdata.io/kickstart.sh > /tmp/netdata-install.sh
bash /tmp/netdata-install.sh --non-interactive
# Access at http://<server-ip>:19999
# Secure with Nginx basic auth if public-facing
```

### Option B: Prometheus + Grafana

```bash
# Install Node Exporter (system metrics)
wget https://github.com/prometheus/node_exporter/releases/latest/download/node_exporter-*linux-amd64.tar.gz -O /tmp/node_exporter.tar.gz
tar -xzf /tmp/node_exporter.tar.gz -C /tmp/
cp /tmp/node_exporter-*/node_exporter /usr/local/bin/
# Create systemd unit for node_exporter (binds to 9100)

# Prometheus and Grafana best installed via Docker:
# See deploy-guide.md Docker section
```

### Option C: Uptime Kuma (self-hosted uptime monitor)

```bash
# Run via Docker
docker run -d --restart=unless-stopped \
  -p 3001:3001 \
  -v /opt/uptime-kuma:/app/data \
  --name uptime-kuma \
  louislam/uptime-kuma:1
# Access at http://<server-ip>:3001
```

---

## Alerting

Cloud VPS providers block outbound port 25 and most servers have no mail server, so `mail`-based alerts silently never arrive. Use `scripts/notify.sh` — it posts to a chat webhook.

### Set up notify.sh

| `NOTIFY_TYPE` | Where to get the URL |
|---|---|
| `wecom` (企业微信) | Group → Add group robot → webhook URL |
| `dingtalk` (钉钉) | Group settings → Smart assistant → Custom robot (security: IP allowlist with the server's public IP) |
| `feishu` (飞书) | Group settings → Bots → Custom bot → webhook URL |
| `telegram` | `@BotFather` token + your chat ID (`TELEGRAM_TOKEN`, `TELEGRAM_CHAT_ID`) |
| `bark` (iOS push) | Bark app → `https://api.day.app/<key>` |
| `slack` / `webhook` | Incoming webhook URL / any endpoint accepting JSON |

The webhook URL is a secret. Have the **user** write the config in their own terminal (`ssh -t … 'sudo nano /etc/server-tools/notify.conf'`), or pipe it over stdin — never echo it in chat:

```bash
ssh … 'sudo mkdir -p /etc/server-tools && sudo tee /etc/server-tools/notify.conf >/dev/null && sudo chmod 600 /etc/server-tools/notify.conf' <<'EOF'
NOTIFY_TYPE=wecom
NOTIFY_URL=<paste webhook URL>
NOTIFY_MIN_LEVEL=info
EOF
ssh … 'sudo bash /opt/server-tools/notify.sh --test'
```

### Severity levels

| Level | Meaning | Response | Examples |
|---|---|---|---|
| `critical` | Users are affected now | Act immediately | Site down, service crash-looping, disk >95%, backup failed |
| `warning` | Will become critical if ignored | Investigate today | Disk >85%, cert expires <14 days, memory >90% for 10 min |
| `info` | Good to know | Review daily | Backup OK, auto-restart succeeded, deploy finished |

Set `NOTIFY_MIN_LEVEL=warning` to silence routine `info` messages. An alert channel that fires constantly gets muted — only page for things that need a human.

### Resource alerts

```bash
ssh … 'sudo tee /opt/server-tools/resource-alert.sh >/dev/null' <<'SCRIPT'
#!/bin/bash
# Disk, memory and load checks → notify.sh. Run from cron every 10 minutes.
N=/opt/server-tools/notify.sh
STATE=/var/tmp/resource-alert.state; touch "$STATE"

# Alert once per problem, not every 10 minutes
alert_once() {  # key level title message
  grep -qxF "$1" "$STATE" && return
  echo "$1" >> "$STATE"; bash "$N" "$3" "$4" "$2"
}
clear_key() { sed -i "/^$1\$/d" "$STATE"; }

while read -r use mount; do
  use=${use%\%}; key="disk:$mount"
  if   [ "$use" -ge 95 ]; then alert_once "$key:crit" critical "Disk $mount at ${use}%" "$(du -xsh /var/log /var/lib/docker /var/backups 2>/dev/null)"
  elif [ "$use" -ge 85 ]; then alert_once "$key:warn" warning  "Disk $mount at ${use}%" "Clean logs/backups or grow the disk"
  else clear_key "$key:crit"; clear_key "$key:warn"; fi
done < <(df -P -x tmpfs -x devtmpfs -x overlay | awk 'NR>1{print $5, $6}')

mem=$(free | awk '/^Mem:/{printf "%d", ($2-$7)*100/$2}')
if [ "$mem" -ge 90 ]; then alert_once mem warning "Memory at ${mem}%" "$(ps aux --sort=-%mem | head -6)"
else clear_key mem; fi

load=$(cut -d' ' -f1 /proc/loadavg); cores=$(nproc)
if awk -v l="$load" -v c="$cores" 'BEGIN{exit !(l > c*2)}'; then
  alert_once load warning "Load $load on $cores cores" "$(ps aux --sort=-%cpu | head -6)"
else clear_key load; fi
SCRIPT
ssh … 'sudo chmod +x /opt/server-tools/resource-alert.sh && echo "*/10 * * * * root bash /opt/server-tools/resource-alert.sh" | sudo tee /etc/cron.d/resource-alert'
```

### External uptime monitoring (do this first)

Everything above runs **on the server**. When the server itself dies — kernel panic, provider outage, network cut, out of memory — those scripts die with it and nobody is told. The monitor must live somewhere else.

| Option | Cost | Notes |
|---|---|---|
| [UptimeRobot](https://uptimerobot.com) / Better Stack / Freshping | Free tier | 5-min HTTP/keyword checks, alerts to email, Telegram, webhooks |
| [Uptime Kuma](https://github.com/louislam/uptime-kuma) on a **different** server | Free, self-hosted | Rich UI, 企业微信/钉钉/飞书 built in |
| 阿里云云监控 / 腾讯云云拨测 | Free tier | Checks from multiple regions inside China |

Monitor the **health endpoint** (below) with a keyword check, not just the home page, and also add an SSL-expiry monitor per domain.

### Health endpoints: liveness vs readiness

A `200` from the home page does not prove the app works — Nginx can serve a cached page while the backend's database connection is dead. Give every service two endpoints:

| Endpoint | Answers | Checks | Used by |
|---|---|---|---|
| `/healthz` (liveness) | Is the process alive and not stuck? | Nothing external — just return `ok` | Process manager / watchdog: restart if this fails |
| `/readyz` (readiness) | Can it serve real requests? | DB query `SELECT 1`, Redis `PING`, required APIs — each with a short timeout (≤2 s) | Deploy verification, external uptime monitor |

- Do **not** fail liveness when a shared dependency (DB) is down — restarting the app won't fix the DB and causes restart storms.
- Return only `ok` / `fail` and a status code publicly; keep error details in logs. If the endpoint reveals internals, restrict it: `location /readyz { allow 127.0.0.1; deny all; proxy_pass …; }` and let the external monitor check a keyword on a public page instead.
- Static sites: check for a keyword that only appears in the real page (catches "default nginx page" and empty-deploy mistakes).

---

## Common Issues & Diagnosis

Work through problems in this order — each step is cheap and rules out a whole class of causes before you dig deeper (see "Diagnosis Order" in SKILL.md):

1. **Running?** `service-control.sh status <name>` · `pm2 status` · `systemctl status <name>`
2. **Logs?** `service-control.sh logs <name> 200` · `journalctl -u <name> -n 100` · `/var/log/nginx/error.log`
3. **Resources?** `df -h` · `df -i` · `free -h` · `uptime` · `dmesg | grep -i oom`
4. **Network?** `ss -tlnp | grep <port>` · `curl -v localhost:<port>/readyz` · `dig +short <domain>` · firewall rules
5. **Dependencies?** DB/Redis reachable and not full · external APIs · certificate validity

| Problem | Commands |
|---------|----------|
| High memory | `free -h`, `ps aux --sort=-%mem \| head -10` |
| High CPU | `top`, `ps aux --sort=-%cpu \| head -10` |
| Disk full | `df -h`, `du -sh /var/log/* /var/www/*` |
| App not responding | `curl -v http://localhost:<port>`, check service status |
| Nginx 502 | backend service down; `pm2 status` / `systemctl status <name>` |
| SSL expired | `certbot renew`, check `certbot.timer` |
| OOM kills | `dmesg \| grep -i oom`, increase server RAM or reduce app memory |
| Many TIME_WAIT | `ss -s`, tune `net.ipv4.tcp_fin_timeout` in `/etc/sysctl.conf` |
| Disk full but `du` finds nothing | Deleted files still held open: `lsof +L1`; restart the holder |
| `No space left` with free space | Inodes exhausted: `df -i`; find the dir: `find / -xdev -type f | cut -d/ -f2-3 | sort | uniq -c | sort -rn | head` |

---

## Scaling & Capacity Decisions

Measure before you scale — most "the server is too small" problems are a leak, a missing index or a bad config.

| Symptom | Check first | Then |
|---|---|---|
| CPU pegged | `ps aux --sort=-%cpu`; one runaway process? a crawler hammering one URL? | PM2 cluster mode (`-i max`), Nginx caching / rate limiting, then more cores |
| Memory climbing over days | Same process growing steadily → leak; fix it or schedule `pm2 reload` / `max_memory_restart` | — |
| OOM kills on a 1–2 GB VPS | Builds (`npm run build`, Maven) on the server? | Add swap (below); build in CI and ship artifacts |
| Slow responses, low CPU | DB slow query log, missing indexes, N+1 queries, upstream API latency | Fix the query; add Redis caching |
| Disk filling | Logs, Docker images (`docker system df`), old backups | logrotate, `docker image prune`, backups offsite |
| Steady growth near limits | All of the above already fine | Vertical first (bigger VPS — quick, no code change), horizontal (load balancer + 2 app servers + shared DB) when one box can't hold it or you need redundancy |

### Swap for small servers

```bash
ssh … 'bash -s' <<'EOF'
swapon --show | grep -q . && { echo "swap already on"; swapon --show; exit 0; }
sudo fallocate -l 2G /swapfile || sudo dd if=/dev/zero of=/swapfile bs=1M count=2048
sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile
grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-swappiness.conf && sudo sysctl -p /etc/sysctl.d/99-swappiness.conf
EOF
```

Swap is a safety net against OOM kills, not extra RAM — if the server is constantly swapping, it needs more memory.
