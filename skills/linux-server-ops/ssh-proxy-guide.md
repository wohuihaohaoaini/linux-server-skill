# SSH Through VPN / Proxy

> **Core principle**: the server may only be reachable *through* the local proxy/VPN. When a proxy is active, SSH must go through it — never blindly bypass it.

All logic lives in [scripts/ssh-proxy.sh](scripts/ssh-proxy.sh). This guide explains what it does and how to debug it by hand.

## Why SSH fails even when the proxy is running

| Scenario | What happens | Fix (automatic in `ssh-proxy.sh`) |
|---|---|---|
| Clash/V2Ray in **System Proxy** mode | Only HTTP/HTTPS apps use the proxy; SSH (raw TCP) goes direct and gets blocked | `ProxyCommand=nc -X 5 -x 127.0.0.1:<port> %h %p` |
| Clash/V2Ray in **TUN** mode | All TCP is routed via the VPN; plain SSH should work | Direct SSH, longer timeout. If it still fails: DNS / routing loop → use the IP |
| Proxy process started but not listening yet | Port closed | Re-probe once, then retry |
| No proxy / VPN | Direct is the only option | Direct SSH |

## Decision tree

```
ssh-proxy.sh ssh …
│
├─ detect_proxy() finds a proxy?
│   └─ YES → ssh -o ProxyCommand="nc -X 5|connect -x <proxy> %h %p"
│            exit 255 and TUN active? → retry once with ProxyCommand=none
│
├─ TUN interface (utun3+, tun*, wg*) up?
│   └─ YES → plain ssh, ConnectTimeout=20
│
└─ Neither → plain ssh, ConnectTimeout=10
             exit 255? → re-probe once (proxy may have just started)
```

Retries happen **only** on connection failure (ssh exit code 255). If the remote command itself fails, it is never re-run.

## Detection order

1. Env vars: `ALL_PROXY`, `SOCKS5_PROXY`, `HTTPS_PROXY` (and lowercase)
2. macOS system proxy via `networksetup` (SOCKS first, then HTTP)
3. Client configs: Clash / Clash Verge / mihomo / ClashX (`mixed-port`, `socks-port`), V2Ray/Xray (`inbounds[].port`), sing-box (`inbounds[].listen_port`)
4. Probe of well-known local ports (list in `SSH_PROXY_SCAN_PORTS`)

`http://` proxies use `nc -X connect`; everything else uses SOCKS5 (`nc -X 5`). This needs the BSD/OpenBSD `nc` (default on macOS; `netcat-openbsd` on Debian/Ubuntu). `ncat` and GNU netcat do not support `-X`.

## Common proxy ports

| Tool | SOCKS5 | HTTP | Notes |
|---|---|---|---|
| Clash Verge / Clash Meta / ClashX Pro | 7890, 7891, 7897 | 7890 | `mixed-port` speaks both |
| V2Ray / Xray | 10808 | 10809 | `inbounds[].port` |
| v2rayN / v2rayA | 20170 | 20171 | |
| sing-box | 1080, 2080 | 1080 | `type: mixed` / `socks` |
| Shadowsocks (macOS) | 1086 | 1087 | |
| Surge | 6153 | 6152 | |
| Proxifier | 8888 | — | |
| Privoxy | — | 8118 | HTTP only |
| WireGuard / OpenVPN | — | — | TUN mode, no local port |

Ports **not** probed on purpose: `8080` (usually a local dev server) and `9090` (Clash's REST controller, not a proxy).

**Non-standard port?** Add to your shell profile: `export ALL_PROXY=socks5://127.0.0.1:<port>` — detection step 1 picks it up.

## Manual troubleshooting

```bash
# What did the script detect?
bash <skill_dir>/scripts/ssh-proxy.sh detect

# Which proxy client is running, and what is it listening on?
pgrep -fl "clash|mihomo|v2ray|xray|sing-box|shadowsocks|surge|proxifier"
lsof -nP -iTCP -sTCP:LISTEN | grep -iE "clash|mihomo|v2ray|xray|sing|shadow|surge"

# macOS system proxy settings
networksetup -getsocksfirewallproxy Wi-Fi
networksetup -getwebproxy Wi-Fi

# Env vars and TUN interfaces
env | grep -iE 'proxy|socks'
ifconfig | grep -E '^utun|^tun|^wg'

# Test one port by hand
ssh -o "ProxyCommand=nc -X 5 -x 127.0.0.1:7890 %h %p" -o ConnectTimeout=10 \
    -i <key> -p <port> <user>@<host> 'echo OK'
```
