#!/usr/bin/env bash
# rhel.sh — action backend for the arifahmed19.rhel Omarchy plugin.
# Subcommands: state | open <name> | run | start <name> | stop <name> | rm <name> | rebuild
#
# Interactive subcommands run inside a terminal. On failure they print a clear
# WHAT / WHY / FIX message and hold the window open until a keypress, so nothing
# ever "does nothing" silently.
set -u

IMAGE="${RHEL_IMAGE:-rhel10-cli}"
BASE="${RHEL_BASE:-registry.access.redhat.com/ubi10/ubi:latest}"
CACHE="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy-rhel10"

USE_NEWGRP=0

# --- user-facing diagnostics (interactive terminal actions) ---
_red()  { [ -t 2 ] && printf '\033[1;31m%s\033[0m\n' "$1" >&2 || printf '%s\n' "$1" >&2; }
_dim()  { [ -t 2 ] && printf '\033[0;90m%s\033[0m\n' "$1" >&2 || printf '%s\n' "$1" >&2; }
_hold() { printf '\nPress any key to close…\n' >&2; [ -t 0 ] && read -n 1 -s; }

# die WHAT  FIX1 [FIX2 ...]
die() {
  local what="$1"; shift
  printf '\n' >&2
  _red "✗ $what"
  for fix in "$@"; do _dim "  ↳ $fix"; done
  _hold
  exit 1
}

# Prefer the docker group; fall back to newgrp for sessions that predate a
# 'usermod -aG docker' (until the user logs out and back in).
ensure_docker() {
  if docker info >/dev/null 2>&1; then return 0; fi
  if command -v newgrp >/dev/null 2>&1 && newgrp docker -c "docker info" >/dev/null 2>&1; then
    USE_NEWGRP=1
    return 0
  fi
  return 1
}

d() {
  if [ "$USE_NEWGRP" = 1 ]; then
    newgrp docker -c "docker $(printf '%q ' "$@")"
  else
    docker "$@"
  fi
}

need_docker() {
  ensure_docker && return 0
  die "Can't reach the Docker daemon." \
      "Install and start it, then add yourself to the group:" \
      "  sudo dnf install -y docker && sudo systemctl enable --now docker" \
      "  sudo usermod -aG docker \$USER   # then log out and back in" \
      "If it's already installed, check the service:  systemctl status docker"
}

# make sure our CLI image exists before anything tries to use it
need_image() {
  d image inspect "$IMAGE" >/dev/null 2>&1 && return 0
  die "The RHEL image '$IMAGE' isn't built yet." \
      "Click 'Rebuild Image' in this popup to build it once (takes ~a minute)," \
      "then click '+ New Shell' again." \
      "It builds from the free public base: $BASE"
}

state() {
  if ensure_docker; then
    echo 'dockerReady<|>1'
  else
    echo 'dockerReady<|>0'
    return
  fi
  if d image inspect "$IMAGE" >/dev/null 2>&1; then
    echo 'imageReady<|>1'
  else
    echo 'imageReady<|>0'
    return
  fi
  mkdir -p "$CACHE"
  if [ ! -s "$CACHE/release" ]; then
    d run --rm "$IMAGE" cat /etc/redhat-release >"$CACHE/release" 2>/dev/null || rm -f "$CACHE/release"
  fi
  [ -s "$CACHE/release" ] && echo "release<|>$(head -c 120 "$CACHE/release" | tr -d '\n')"
  d ps -a --filter "ancestor=$IMAGE" --format 'C<|>{{.Names}}<|>{{.State}}<|>{{.Status}}'
}

open() {
  local name="${1:-}"
  [ -n "$name" ] || die "No container name was given to open." \
      "This is a plugin bug — use '+ New Shell' to start a fresh container."
  need_docker
  need_image
  if ! d inspect "$name" >/dev/null 2>&1; then
    die "Container '$name' no longer exists." \
        "It was probably removed. Click '+ New Shell' to start a fresh one."
  fi
  d start "$name" >/dev/null 2>&1 || true
  d exec -it -e TERM=xterm-256color "$name" bash || \
    die "Couldn't open a shell in '$name'." \
        "The container may be stopped or unhealthy. Try Start, or '+ New Shell'."
}

run() {
  need_docker
  need_image
  if [ "${RHEL_PIN:-1}" = "1" ]; then
    # Pinned: detached, persistent container; this terminal just execs into it,
    # so closing the shell only detaches — the container stays in the widget.
    local name="rhel10-$(date +%H%M%S)"
    if ! d run -d --name "$name" --label omarchy.rhel.pinned=1 \
              -e TERM=xterm-256color --hostname rhel10 "$IMAGE" sleep infinity >/dev/null; then
      die "Failed to start pinned container '$name' (see the Docker error above)." \
          "A container with that name may already exist — Remove it, then try again." \
          "Or toggle Pin off to '+ New Shell' as a throwaway instead."
    fi
    printf '\n\033[1;32m✓ Pinned\033[0m container \033[1m%s\033[0m is running.\n' "$name"
    printf 'It stays in the widget after you close this window (close = detach, not delete).\n\n'
    d exec -it -e TERM=xterm-256color "$name" bash || true
  else
    # Throwaway: --rm so it disappears when you exit.
    d run -it --rm -e TERM=xterm-256color --hostname rhel10 "$IMAGE" \
      || die "Failed to start a '$IMAGE' container (see the Docker error above)." \
             "Missing image? Click 'Rebuild Image' in the popup." \
             "Permission denied on the docker socket? Run  newgrp docker  here," \
             "or log out and back in so the docker group takes effect."
  fi
}

start() {
  local name="${1:-}" err
  [ -n "$name" ] || exit 2
  need_docker || exit 1
  if ! err=$(d start "$name" 2>&1); then
    die "Could not start '$name'." \
        "If it no longer exists, click '+ New Shell' to create a fresh one." \
        "If it won't start, click 'Remove' then recreate.  Docker: $err"
  fi
}

stop() {
  local name="${1:-}" err
  [ -n "$name" ] || exit 2
  need_docker || exit 1
  if ! err=$(d stop -t 5 "$name" 2>&1); then
    # Stopping an already-stopped container is not an error.
    [ "$(d inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" = "true" ] \
      || return 0
    die "Could not stop '$name'." \
        "It may be wedged — try again, or 'Remove' to force-delete it.  Docker: $err"
  fi
}

rm_() {
  local name="${1:-}" err
  [ -n "$name" ] || exit 2
  need_docker || exit 1
  if ! err=$(d rm -f "$name" 2>&1); then
    die "Could not remove '$name'." \
        "It may already be gone — the list refreshes itself.  Docker: $err"
  fi
}

rebuild() {
  need_docker
  tmp=$(mktemp -d) || die "Could not create a temp build directory."
  trap 'rm -rf "$tmp"' EXIT
  cat >"$tmp/Dockerfile" <<EOF
FROM $BASE
RUN dnf install -y ncurses vim-minimal less && dnf clean all
EOF
  printf 'Pulling %s…\n' "$BASE"
  if ! d pull "$BASE"; then
    _dim "  ↳ pull failed — building from the cached base instead."
  fi
  printf 'Building %s…\n' "$IMAGE"
  if ! d build -t "$IMAGE" "$tmp"; then
    die "Image build failed (see the Docker output above)." \
        "Check your network / registry access to $BASE." \
        "Docker must be running:  systemctl status docker"
  fi
  rm -f "$CACHE/release"
  printf '\n✓ Built %s — you can now open a shell.\n' "$IMAGE"
  _hold
}

case "${1:-state}" in
  state) state ;;
  open) shift; open "$@" ;;
  run) shift; run ;;
  start) shift; start "${1:-}" ;;
  stop) shift; stop "${1:-}" ;;
  rm) shift; rm_ "${1:-}" ;;
  rebuild) shift; rebuild ;;
  *) echo "unknown subcommand: $1" >&2; exit 2 ;;
esac
