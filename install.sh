#!/usr/bin/env bash
#
# Omasweeper installer for the Omarchy shell.
#
# Run it from a clone of the repo:  ./install.sh
#
# What it does:
#   1. Registers the plugin (omarchy plugin add, never a file copy, or
#      `omarchy plugin update` could never fast-forward it later).
#   2. Enables it, which for a panel-only plugin means one entry in
#      shell.json's plugins[] and nothing in the bar.
#   3. Drops a launcher entry, since a shell plugin is not an app and
#      nothing else would put it in the launcher.
#
# There is nothing else to install: the board is drawn in QML and the game
# needs nothing beyond what Omarchy already has, so `omarchy plugin add` on
# its own works fine too.
#
# Overrides:
#   OMASWEEPER_REPO=user/repo    register from a different repo
set -euo pipefail

REPO="${OMASWEEPER_REPO:-jankeesvw/omasweeper}"
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
  # gets the prompt a bare `plugin add` would give them.
  if [ -t 0 ] && [ -t 1 ]; then
    omarchy plugin add "https://github.com/${REPO}"
  else
    omarchy plugin add "https://github.com/${REPO}" --yes
  fi
fi

say "==> Enabling"
omarchy plugin enable "$PLUGIN_ID" || true

# A shell plugin is not an app, so nothing puts it in the launcher. This does:
# a desktop entry whose Exec is the toggle a keybinding would run.
PLUGIN_DIR="$HOME/.config/omarchy/plugins/${PLUGIN_ID}"
APPS_DIR="$HOME/.local/share/applications"
say "==> Adding the launcher entry"
mkdir -p "$APPS_DIR"
cat > "$APPS_DIR/omasweeper.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Omasweeper
Comment=Minesweeper for the Omarchy shell
Exec=omarchy-shell shell toggle ${PLUGIN_ID}
Icon=${PLUGIN_DIR}/icon.svg
Terminal=false
Categories=Game;LogicGame;
StartupNotify=false
DESKTOP
command -v update-desktop-database >/dev/null 2>&1 &&
  update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true

say ""
say "Done. Search for Omasweeper in the launcher, or bind a key to:"
say "  omarchy-shell shell toggle ${PLUGIN_ID}"
say ""
say "Closing the board unloads it again, so nothing of it runs while you are"
say "not playing. Press ? in the game for the keys."
