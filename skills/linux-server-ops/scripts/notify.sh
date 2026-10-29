#!/bin/bash
# notify.sh — Send an alert to a chat webhook (no mail server needed)
# Install on server at: /opt/server-tools/notify.sh
#
# Usage:
#   bash notify.sh "<title>" "<message>" [critical|warning|info]
#   bash notify.sh --test
#
# Config: /etc/server-tools/notify.conf  (chmod 600 — webhook URLs are secrets)
#   NOTIFY_TYPE=wecom|dingtalk|feishu|telegram|bark|slack|webhook
#   NOTIFY_URL=https://...            # webhook URL (all types except telegram)
#   TELEGRAM_TOKEN=...                # telegram only
#   TELEGRAM_CHAT_ID=...              # telegram only
#   NOTIFY_MIN_LEVEL=warning          # drop messages below this level (default: info)
#
# Exit codes: 0 sent (or filtered by level), 1 send failed, 2 not configured.

set -uo pipefail

CONF="${NOTIFY_CONF:-/etc/server-tools/notify.conf}"

level_num() {
  case "$1" in
    critical) echo 3 ;;
    warning)  echo 2 ;;
    *)        echo 1 ;;
  esac
}

main() {
  local title="${1:-}" message="${2:-}" level="${3:-warning}"

  if [ "$title" = "--test" ]; then
    title="Test alert"
    message="notify.sh is configured correctly on $(hostname)"
    level="info"
  fi
  if [ -z "$title" ]; then
    sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
  fi

  if [ ! -f "$CONF" ]; then
    echo "[notify] not configured ($CONF missing) — message dropped: $title" >&2
    exit 2
  fi
  # shellcheck disable=SC1090
  . "$CONF"

  local min="${NOTIFY_MIN_LEVEL:-info}"
  if [ "$(level_num "$level")" -lt "$(level_num "$min")" ]; then
    exit 0
  fi

  local icon
  case "$level" in
    critical) icon="🔴" ;;
    warning)  icon="🟠" ;;
    *)        icon="🔵" ;;
  esac
  local text="${icon} [$(hostname)] ${title}
${message}
$(date '+%Y-%m-%d %H:%M:%S %Z')"

  # Build the payload with jq so quotes/newlines in messages can't break the JSON
  local url="${NOTIFY_URL:-}" payload
  case "${NOTIFY_TYPE:-}" in
    wecom)    payload=$(jq -cn --arg t "$text" '{msgtype:"text", text:{content:$t}}') ;;
    dingtalk) payload=$(jq -cn --arg t "$text" '{msgtype:"text", text:{content:$t}}') ;;
    feishu)   payload=$(jq -cn --arg t "$text" '{msg_type:"text", content:{text:$t}}') ;;
    slack)    payload=$(jq -cn --arg t "$text" '{text:$t}') ;;
    webhook)  payload=$(jq -cn --arg t "$title" --arg m "$message" --arg l "$level" --arg h "$(hostname)" \
                '{title:$t, message:$m, level:$l, host:$h}') ;;
    telegram)
      url="https://api.telegram.org/bot${TELEGRAM_TOKEN:-}/sendMessage"
      payload=$(jq -cn --arg c "${TELEGRAM_CHAT_ID:-}" --arg t "$text" '{chat_id:$c, text:$t}') ;;
    bark)
      # NOTIFY_URL is the device URL, e.g. https://api.day.app/<key>
      payload=$(jq -cn --arg t "[$(hostname)] $title" --arg b "$message" \
        --arg l "$([ "$level" = critical ] && echo critical || echo active)" '{title:$t, body:$b, level:$l}') ;;
    *)
      echo "[notify] unknown NOTIFY_TYPE='${NOTIFY_TYPE:-}' in $CONF" >&2
      exit 2 ;;
  esac

  if [ -z "$url" ]; then
    echo "[notify] NOTIFY_URL is empty in $CONF" >&2
    exit 2
  fi

  local resp
  if resp=$(curl -fsS --max-time 10 -H 'Content-Type: application/json' -d "$payload" "$url" 2>&1); then
    exit 0
  fi
  # Never print the URL: it embeds the webhook secret
  echo "[notify] send failed (${NOTIFY_TYPE}): ${resp:0:200}" >&2
  exit 1
}

main "$@"
