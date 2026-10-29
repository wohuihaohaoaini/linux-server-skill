#!/bin/bash
# release.sh — Snapshot an app before each deploy, roll back in seconds if it breaks
# Install on server at: /opt/server-tools/release.sh   (run as root)
#
# Usage:
#   bash release.sh snapshot <name> [app_root]   # call BEFORE every deploy
#   bash release.sh list     <name>
#   bash release.sh rollback <name> [<id>]       # default: newest snapshot
#   bash release.sh diff     <name> [<id>]       # what changed since the snapshot
#
# Works with the existing layout (/var/www/<name>, /opt/*-apps/<name>): snapshots
# live in /var/backups/releases/<name>/<id>/ and use rsync --link-dest, so
# unchanged files are hard links and each snapshot costs only the changed bytes.
# The app root is taken from the argument, else /etc/server-index.json, else
# /etc/server-registry.json.
#
# Env: RELEASE_KEEP=5 (snapshots kept per app)

set -euo pipefail

RELEASES_DIR="${RELEASES_DIR:-/var/backups/releases}"
RELEASE_KEEP="${RELEASE_KEEP:-5}"
TOOLS_DIR="$(cd "$(dirname "$0")" && pwd)"

die() { echo "[release] $*" >&2; exit 1; }
log() { echo "[release] $*"; }

resolve_root() {
  local name="$1" root="${2:-}"
  if [ -z "$root" ] && [ -f /etc/server-index.json ]; then
    root=$(jq -r --arg n "$name" \
      '[(.services // [])[], (.websites // [])[]] | map(select(.name == $n and (.root // "") != "")) | .[0].root // empty' \
      /etc/server-index.json 2>/dev/null || true)
  fi
  if [ -z "$root" ] && [ -f /etc/server-registry.json ]; then
    root=$(jq -r --arg n "$name" '.services[$n].root // empty' /etc/server-registry.json 2>/dev/null || true)
  fi
  [ -n "$root" ] || die "cannot find app root for '$name' — pass it: release.sh snapshot $name /var/www/$name"
  [ -d "$root" ] || die "app root does not exist: $root"
  # Refuse obviously dangerous roots: rollback runs rsync --delete into this path.
  # Check the path as given AND resolved (symlinks, trailing slashes, /private/etc on macOS).
  local p
  for p in "${root%/}" "$(cd "$root" && pwd -P)"; do
    case "$p" in
      ""|/|/etc|/usr|/var|/opt|/home|/root|/var/www|/srv|/boot|/private/etc|/private/var)
        die "refusing unsafe app root: $root" ;;
    esac
  done
  echo "$root"
}

snapshot_ids() {
  ls -1 "$RELEASES_DIR/$1" 2>/dev/null | grep -E '^[0-9]{8}-[0-9]{6}' | sort || true
}

cmd_snapshot() {
  local name="${1:?usage: release.sh snapshot <name> [app_root]}"
  local root; root=$(resolve_root "$name" "${2:-}")
  local base="$RELEASES_DIR/$name"
  mkdir -p "$base" && chmod 700 "$RELEASES_DIR" "$base"

  local id prev
  id=$(date +%Y%m%d-%H%M%S)
  prev=$(snapshot_ids "$name" | tail -1)

  # ${arr[@]+…} form: an empty array under `set -u` is an error before bash 4.4
  # (CentOS 7 ships 4.2, macOS 3.2)
  local link=()
  [ -n "$prev" ] && link=(--link-dest="$base/$prev/files")
  rsync -a --delete ${link[@]+"${link[@]}"} "$root/" "$base/$id/files/"

  {
    echo "name=$name"
    echo "root=$root"
    echo "created=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [ -d "$root/.git" ]; then
      echo "git_commit=$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo unknown)"
      echo "git_branch=$(git -C "$root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
    fi
  } > "$base/$id/META"

  # Retention: newest $RELEASE_KEEP snapshots stay
  # (count-based, since `head -n -N` is GNU-only)
  local old total
  total=$(snapshot_ids "$name" | wc -l)
  if [ "$total" -gt "$RELEASE_KEEP" ]; then
    for old in $(snapshot_ids "$name" | head -n "$((total - RELEASE_KEEP))"); do
      rm -rf "${base:?}/$old"
    done
  fi

  log "snapshot $name@$id ($(du -sh "$base/$id" | awk '{print $1}') new data)"
  echo "$id"
}

cmd_list() {
  local name="${1:?usage: release.sh list <name>}" id
  for id in $(snapshot_ids "$name"); do
    printf '%s  %s\n' "$id" \
      "$(grep -E '^git_commit=' "$RELEASES_DIR/$name/$id/META" 2>/dev/null | cut -d= -f2 || true)"
  done
}

pick_id() {
  local name="$1" id="${2:-}"
  [ -n "$id" ] || id=$(snapshot_ids "$name" | grep -v -- '-pre-rollback$' | tail -1)
  [ -n "$id" ] && [ -d "$RELEASES_DIR/$name/$id/files" ] || die "no snapshot '${id:-}' for $name (see: release.sh list $name)"
  echo "$id"
}

cmd_diff() {
  local name="${1:?usage: release.sh diff <name> [<id>]}"
  local id; id=$(pick_id "$name" "${2:-}")
  local root; root=$(grep '^root=' "$RELEASES_DIR/$name/$id/META" | cut -d= -f2-)
  rsync -an --delete --itemize-changes --exclude=node_modules --exclude=.venv \
    "$RELEASES_DIR/$name/$id/files/" "$root/" | head -100
}

cmd_rollback() {
  local name="${1:?usage: release.sh rollback <name> [<id>]}"
  local id; id=$(pick_id "$name" "${2:-}")
  local root; root=$(grep '^root=' "$RELEASES_DIR/$name/$id/META" | cut -d= -f2-)
  [ -n "$root" ] && [ -d "$root" ] || die "snapshot META has no valid root"
  resolve_root "$name" "$root" >/dev/null   # re-run the safety checks

  # Keep the broken state too, so a rollback can itself be undone
  local safety; safety="$(date +%Y%m%d-%H%M%S)-pre-rollback"
  rsync -a --link-dest="$RELEASES_DIR/$name/$id/files" "$root/" "$RELEASES_DIR/$name/$safety/files/"
  printf 'name=%s\nroot=%s\ncreated=%s\nnote=state before rollback to %s\n' \
    "$name" "$root" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$id" > "$RELEASES_DIR/$name/$safety/META"

  rsync -a --delete "$RELEASES_DIR/$name/$id/files/" "$root/"
  log "restored $name to $id (previous state saved as $safety)"

  if [ -f "$TOOLS_DIR/service-control.sh" ]; then
    bash "$TOOLS_DIR/service-control.sh" restart "$name" || log "restart failed — check: service-control.sh status $name"
  else
    log "restart the service manually"
  fi
}

case "${1:-}" in
  snapshot) shift; cmd_snapshot "$@" ;;
  list)     shift; cmd_list "$@" ;;
  diff)     shift; cmd_diff "$@" ;;
  rollback) shift; cmd_rollback "$@" ;;
  *)        sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
