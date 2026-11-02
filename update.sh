#!/bin/sh
# Space Link Router updater — wrapper around install.sh with FORCE_UPDATE.
set -eu

FORCE_UPDATE=1
export FORCE_UPDATE

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0" 2>/dev/null || echo .)" && pwd 2>/dev/null || echo /tmp)

if [ -z "${INSTALL_URL:-}" ] && [ -f "$SCRIPT_DIR/install.sh" ]; then
  exec sh "$SCRIPT_DIR/install.sh" "$@"
fi

# Piped over network — re-download install.sh
URL="${INSTALL_URL:-https://raw.githubusercontent.com/space-link-network/router/main/install.sh}"
if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$URL" | sh
else
  wget -qO- "$URL" | sh
fi
