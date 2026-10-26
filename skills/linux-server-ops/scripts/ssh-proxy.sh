#!/usr/bin/env bash
# ssh-proxy.sh — Route SSH/SCP through a local proxy or VPN when one is active
# Run LOCALLY (not on server). Works on macOS and Linux, bash 3.2+.
#
# Usage (as a command):
#   bash ssh-proxy.sh detect                  # print socks5://… | http://… | (nothing)
#   bash ssh-proxy.sh ssh <ssh args…>         # ssh with auto proxy + retry on connect failure
#   bash ssh-proxy.sh scp <scp args…>         # scp with auto proxy
#   rsync -e "bash ssh-proxy.sh ssh" …        # rsync through the same logic
#
# Usage (as a library):
#   . ssh-proxy.sh
#   ssh_auto -i <key> -p <port> <user>@<host> '<cmd>'
#   set_proxy_opts; ssh "${SSH_PROXY_OPTS[@]}" …   # just get the -o options
#
# Detection order: env vars → macOS system proxy → proxy client configs → port probe.
# Non-standard port? export ALL_PROXY=socks5://127.0.0.1:<port>
#
# All diagnostics go to stderr so stdout stays clean for captured output.

_sp_log() { [ -n "${SSH_PROXY_QUIET:-}" ] || echo "[ssh-proxy] $*" >&2; }

# Ports probed when nothing else finds a proxy. Deliberately excludes 8080
# (local dev servers) and 9090 (Clash external-controller REST API, not a proxy).
SSH_PROXY_SCAN_PORTS="7890 7891 7892 7893 7897 1080 1081 1086 1087 1089 10808 10809 2080 6152 6153 8118 8888 20170 20171"

_port_open() { nc -z -w1 127.0.0.1 "$1" >/dev/null 2>&1; }

# probe_proxy_scheme <port> — decide which protocol a listening local port speaks.
# Prints "socks5", "http", or nothing if the port is not a usable proxy.
probe_proxy_scheme() {
  local port="$1" reply
  _port_open "$port" || return 0

  # SOCKS5 greeting (VER=5, 1 method, NO-AUTH); a SOCKS5 server answers 05 xx.
  # Mixed ports (Clash, sing-box) answer this too, and SOCKS5 is preferred.
  reply=$(printf '\005\001\000' | nc -w1 127.0.0.1 "$port" 2>/dev/null | head -c2 | od -An -tx1 | tr -d ' \n')
  case "$reply" in 05*) echo "socks5"; return ;; esac

  # HTTP CONNECT to a closed port. A proxy either opens the tunnel first
  # ("200 Connection established" — Clash, Privoxy, Squid) or reports the
  # upstream failure (502/503/504). An ordinary web server (Jupyter on 8888,
  # a dev server) rejects the method with 400/404/405/501, so it never matches.
  reply=$(printf 'CONNECT 127.0.0.1:1 HTTP/1.1\r\nHost: 127.0.0.1:1\r\n\r\n' \
    | nc -w1 127.0.0.1 "$port" 2>/dev/null | head -1)
  case "$reply" in
    "HTTP/1."?" 200 "[Cc]onnection*|"HTTP/1."?" 50"[234]*) echo "http" ;;
  esac
  return 0
}

_first_existing_value() {
  # _first_existing_value <jq-filter> <file>… — first non-empty jq result across files
  local filter="$1"; shift
  local f v
  for f in "$@"; do
    [ -f "$f" ] || continue
    v=$(jq -r "$filter" "$f" 2>/dev/null | head -1)
    [ -n "$v" ] && [ "$v" != "null" ] && { echo "$v"; return; }
  done
  return 0
}

detect_proxy() {
  # ── 1. Explicit env vars ────────────────────────────────────────────────
  local p="${ALL_PROXY:-${all_proxy:-${SOCKS5_PROXY:-${socks5_proxy:-${HTTPS_PROXY:-${https_proxy:-}}}}}}"
  [ -n "$p" ] && { echo "$p"; return; }

  # ── 2. macOS system proxy (System Proxy mode of Clash/V2Ray/Surge) ──────
  if command -v networksetup >/dev/null 2>&1; then
    local iface info
    while IFS= read -r iface; do
      [ -z "$iface" ] && continue
      info=$(networksetup -getsocksfirewallproxy "$iface" 2>/dev/null)
      if echo "$info" | grep '^Enabled: Yes' >/dev/null; then
        echo "socks5://$(echo "$info" | awk '/^Server:/{print $2}'):$(echo "$info" | awk '/^Port:/{print $2}')"
        return
      fi
      info=$(networksetup -getwebproxy "$iface" 2>/dev/null)
      if echo "$info" | grep '^Enabled: Yes' >/dev/null; then
        echo "http://$(echo "$info" | awk '/^Server:/{print $2}'):$(echo "$info" | awk '/^Port:/{print $2}')"
        return
      fi
    done < <(networksetup -listallnetworkservices 2>/dev/null | tail -n +2 | sed 's/^\*//')
  fi

  # ── 3. Proxy client config files ────────────────────────────────────────
  local port cfg
  # Clash / Clash Verge / ClashX — mixed-port speaks both SOCKS5 and HTTP
  for cfg in \
    "$HOME/.config/clash-verge/profiles"/*.yaml \
    "$HOME/.config/clash/config.yaml" \
    "$HOME/.config/mihomo/config.yaml" \
    "$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev"/*.yaml \
    "$HOME/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/profiles"/*.yaml \
    "$HOME/Library/Preferences/com.metacubex.ClashX-Pro/config.yaml"; do
    [ -f "$cfg" ] || continue
    port=$(grep -E '^(mixed-port|socks-port):' "$cfg" 2>/dev/null | head -1 | awk '{print $2}')
    [ -n "$port" ] && _port_open "$port" && { echo "socks5://127.0.0.1:${port}"; return; }
  done

  if command -v jq >/dev/null 2>&1; then
    # V2Ray / Xray
    port=$(_first_existing_value \
      '[.inbounds[]? | select(.protocol=="socks")] | .[0].port' \
      "$HOME/.config/v2ray/config.json" "$HOME/.config/xray/config.json" \
      /usr/local/etc/v2ray/config.json /usr/local/etc/xray/config.json)
    [ -n "$port" ] && _port_open "$port" && { echo "socks5://127.0.0.1:${port}"; return; }
    # sing-box
    port=$(_first_existing_value \
      '[.inbounds[]? | select(.type=="socks" or .type=="mixed")] | .[0].listen_port' \
      "$HOME/.config/sing-box/config.json" /usr/local/etc/sing-box/config.json)
    [ -n "$port" ] && _port_open "$port" && { echo "socks5://127.0.0.1:${port}"; return; }
  fi

  # ── 4. Probe well-known local proxy ports ───────────────────────────────
  local scheme
  for port in $SSH_PROXY_SCAN_PORTS; do
    scheme=$(probe_proxy_scheme "$port")
    [ -n "$scheme" ] && { echo "${scheme}://127.0.0.1:${port}"; return; }
  done
  return 0   # nothing found is not an error (keeps callers safe under set -e)
}

# TUN mode routes all TCP through the VPN, so plain SSH should work.
# utun0-2 are macOS built-ins; utun3+ / tun* / wg* usually mean a VPN.
# (grep without -q: an early exit would SIGPIPE ifconfig and fail under pipefail)
is_tun_active() {
  ifconfig 2>/dev/null | grep -E '^(utun[3-9]|utun[1-9][0-9]+|tun[0-9]|wg[0-9]|ipsec[0-9])' >/dev/null
}

# proxy_command <proxy-url> — ProxyCommand string for ssh -o
proxy_command() {
  local url="$1" addr flag
  addr="${url#*://}"; addr="${addr%/}"; addr="${addr##*@}"   # strip scheme, trailing /, creds
  case "$url" in
    http://*|https://*) flag="connect" ;;
    *)                  flag="5" ;;
  esac
  echo "nc -X ${flag} -x ${addr} %h %p"
}

# Fills the global array SSH_PROXY_OPTS with -o options for the current network.
set_proxy_opts() {
  local proxy
  proxy=$(detect_proxy)
  if [ -n "$proxy" ]; then
    if [[ "$(nc -h 2>&1)" != *"-X "* ]]; then
      _sp_log "proxy $proxy found, but this nc lacks -X (install openbsd netcat); connecting directly"
      SSH_PROXY_OPTS=(-o ConnectTimeout=15)
      return
    fi
    _sp_log "routing through proxy $proxy"
    SSH_PROXY_OPTS=(-o "ProxyCommand=$(proxy_command "$proxy")" -o ConnectTimeout=15)
  elif is_tun_active; then
    _sp_log "TUN/VPN interface active — direct connection"
    SSH_PROXY_OPTS=(-o ConnectTimeout=20)
  else
    SSH_PROXY_OPTS=(-o ConnectTimeout=10)
  fi
}

# _run_with_proxy <ssh|scp> <args…>
# Retries only on connection failure (ssh exit 255), never after a remote
# command has run — re-running non-idempotent commands would be unsafe.
_run_with_proxy() {
  local tool="$1"; shift
  local rc fail_rc=255
  [ "$tool" = "scp" ] && fail_rc=1

  set_proxy_opts
  "$tool" "${SSH_PROXY_OPTS[@]}" "$@"; rc=$?
  [ "$rc" -ne "$fail_rc" ] && return "$rc"

  case "${SSH_PROXY_OPTS[*]}" in
    *ProxyCommand=*)
      if is_tun_active; then
        _sp_log "proxy route failed; TUN active — retrying without proxy"
        "$tool" -o ProxyCommand=none -o ConnectTimeout=20 "$@"; rc=$?
      fi
      ;;
    *)
      # A proxy client may have finished starting since the first probe
      local before="${SSH_PROXY_OPTS[*]}"
      set_proxy_opts
      if [ "${SSH_PROXY_OPTS[*]}" != "$before" ]; then
        _sp_log "network state changed — retrying"
        "$tool" "${SSH_PROXY_OPTS[@]}" "$@"; rc=$?
      fi
      ;;
  esac
  return "$rc"
}

ssh_auto() { _run_with_proxy ssh "$@"; }
scp_auto() { _run_with_proxy scp "$@"; }

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    detect) detect_proxy ;;
    ssh)    shift; ssh_auto "$@" ;;
    scp)    shift; scp_auto "$@" ;;
    *)      sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
  esac
fi
