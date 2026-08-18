#!/usr/bin/env bash
#
# Omasweeper installer for the Omarchy shell.
#
# Run it from a clone of the repo:  ./install.sh
#
# What it does:
#   1. Registers the plugin (omarchy plugin add, never a file copy, or
#      `omarchy plugin update` could never fast-forward it later).
#   2. Enables it and places the bar icon on the right.
#
# There is nothing else to install: the board is drawn in QML and the game
# needs nothing beyond what Omarchy already has, so `omarchy plugin add` on
# its own works fine too.
#
# Overrides:
#   OMASWEEPER_REPO=user/repo                 register from a different repo
#   OMASWEEPER_SECTION=left|center|right      where the bar icon lands
set -euo pipefail

REPO="${OMASWEEPER_REPO:-jankeesvw/omasweeper}"
SECTION="${OMASWEEPER_SECTION:-right}"
PLUGIN_ID="jankeesvw.omasweeper"

say() { printf '%s\n' "$*"; }

if ! command -v omarchy >/dev/null 2>&1; then
  say "This needs Omarchy 4 (the omarchy CLI is not on PATH)."
  exit 1
fi

# Already installed? Then this is an update, not an install.
if omarchy plugin list 2>/dev/null | grep -q "^${PLUGIN_ID}[[:space:]]"; then
  say "==> ${PLUGIN_ID} is already installed; updating"
  omarchy plugin update "$PLUGIN_ID"
else
  say "==> Registering ${PLUGIN_ID} from ${REPO}"
  # --yes only when there is no terminal to prompt on: with a TTY the user
  # gets the placement prompt a bare `plugin add` would give them.
  if [ -t 0 ] && [ -t 1 ]; then
    omarchy plugin add "https://github.com/${REPO}"
  else
    omarchy plugin add "https://github.com/${REPO}" --yes
  fi
fi

say "==> Enabling and placing the bar icon (${SECTION})"
omarchy plugin enable "$PLUGIN_ID" --section "$SECTION" || true
# A fresh unattended add can race the registry's rescan and land the widget in
# center regardless of defaultSection, so place it explicitly afterwards.
omarchy bar move "$PLUGIN_ID" --section "$SECTION" >/dev/null 2>&1 || true

say ""
say "Done. Click the ⚑ in the bar, or bind a key to:"
say "  omarchy-shell shell toggle ${PLUGIN_ID}"
