#!/usr/bin/env bash
#
# Omasweeper installer for the Omarchy shell.
#
# Run it from a clone of the repo:  ./install.sh
#
# What it does:
#   1. Registers the plugin (omarchy plugin add, never a file copy, or
#      `omarchy plugin update` could never fast-forward it later).
#   2. Clears the bar entry 1.0 left behind, if there is one.
#   3. Enables it, which for a panel-only plugin means one entry in
#      shell.json's plugins[] and nothing in the bar.
#   4. Drops a launcher entry, since a shell plugin is not an app and
#      nothing else would put it in the launcher.
#   5. Adds a row to the Omarchy menu, which builds its rows from a user
#      extension and so never sees that launcher entry.
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

# `plugin add` and `plugin update` ask the shell to rescan and do not wait for
# it, while everything below reads the manifest the shell's registry holds
# rather than the one on disk. Wait for this version's manifest to land: an
# enable run against 1.0's would splice a *new* bar entry into the layout, which
# is the opposite of the cleanup that follows.
registry_kinds() {
  omarchy plugin list --json 2>/dev/null |
    jq -r --arg id "$PLUGIN_ID" \
      'map(select(.id == $id))[0].kinds // [] | join(" ")' 2>/dev/null || true
}

kinds=""
for ((attempt = 0; attempt < 40; attempt++)); do
  kinds=" $(registry_kinds) "
  if [[ $kinds == *" panel "* && $kinds != *" bar-widget "* ]]; then break; fi
  sleep 0.1
done

# 1.0 shipped a bar icon, so the enable it wrote was a bar layout entry. This
# version has no bar widget, so nothing in the bar can answer to that entry any
# more. Worse, while it sits there PluginRegistry still counts the plugin as
# placed, so the enable below writes nothing at all and shell.json never gains
# the plugins[] entry a panel is supposed to have. Disabling drops whichever
# entry is there, and the enable that follows writes the panel one.
#
# Layout entries are `{"id": ...}` or the bare id string, and one string
# anywhere in the layout is enough to make a `.id` on every entry fail, so the
# match has to allow for both shapes.
SHELL_JSON="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/shell.json"
if [[ $kinds != *" panel "* || $kinds == *" bar-widget "* ]]; then
  say "==> The shell has not read this manifest yet; leaving shell.json alone"
elif [ -f "$SHELL_JSON" ] && jq -e --arg id "$PLUGIN_ID" '
    [ .bar? | objects | .layout? | objects | .[] | arrays | .[]
      | if type == "object" then .id else . end ]
    | index($id) != null
  ' "$SHELL_JSON" >/dev/null 2>&1; then
  say "==> Removing the 1.0 bar entry"
  omarchy plugin disable "$PLUGIN_ID" || true
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
Keywords=game;games;minesweeper;mines;puzzle;
StartupNotify=false
DESKTOP
command -v update-desktop-database >/dev/null 2>&1 &&
  update-desktop-database "$APPS_DIR" >/dev/null 2>&1 || true

# The Omarchy menu is the other place someone looks for this, and it builds its
# rows from a JSONC extension rather than from .desktop files, so the launcher
# entry above does nothing for it. Markers keep this row ours: a second run
# replaces what is between them instead of appending a copy, and an uninstall
# is those three lines.
MENU_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/extensions/omarchy-menu.jsonc"
MENU_BEGIN="  // >>> ${PLUGIN_ID}: managed by omasweeper's install.sh, do not edit between the markers"
MENU_END="  // <<< ${PLUGIN_ID}"
# The icon is nf-fa-bomb, not the board's own ⚑: the menu draws this column
# in the shell font, which is a Nerd Font and has the first but not the second.
# Only specific aliases here: a JSONC row's aliases are also `omarchy menu
# summon` routes, so claiming "game" would take a global name for one toy.
# The broad words ride in the .desktop's Keywords, which the menu searches
# but never routes.
# `when` hides the row once the plugin folder is gone, so a removal that never
# touches this file leaves a hidden row rather than one that toggles nothing.
MENU_ROW="  \"omasweeper\": {\"icon\":\"\",\"label\":\"Omasweeper\",\"description\":\"Minesweeper, drawn like a TUI\",\"aliases\":[\"minesweeper\",\"mines\"],\"action\":\"omarchy-shell shell toggle ${PLUGIN_ID}\",\"when\":\"test -d \$HOME/.config/omarchy/plugins/${PLUGIN_ID}\"},"

say "==> Adding the menu entry"
mkdir -p "$(dirname "$MENU_FILE")"
menu_tmp=$(mktemp)
if [ ! -s "$MENU_FILE" ]; then
  printf '%s\n%s\n%s\n%s\n%s\n' '{' "$MENU_BEGIN" "$MENU_ROW" "$MENU_END" '}' >"$menu_tmp"
elif grep -qF ">>> ${PLUGIN_ID}" "$MENU_FILE"; then
  awk -v begin="$MENU_BEGIN" -v row="$MENU_ROW" -v end="$MENU_END" \
    -v opener=">>> ${PLUGIN_ID}" -v closer="<<< ${PLUGIN_ID}" '
      index($0, opener) { print begin; print row; print end; drop = 1; next }
      drop { if (index($0, closer)) drop = 0; next }
      { print }
    ' "$MENU_FILE" >"$menu_tmp"
elif ! awk -v begin="$MENU_BEGIN" -v row="$MENU_ROW" -v end="$MENU_END" '
    !placed && /^[[:space:]]*\{[[:space:]]*$/ {
      print; print begin; print row; print end; placed = 1; next
    }
    { print }
    END { exit placed ? 0 : 3 }
  ' "$MENU_FILE" >"$menu_tmp"; then
  # Someone reshaped the file (all on one line, say). Better no row than a
  # broken menu for every other plugin that wrote one.
  say "    could not find the line that opens $MENU_FILE; skipping the menu row"
  rm -f "$menu_tmp"
  menu_tmp=""
fi

if [ -n "$menu_tmp" ]; then
  # Written through the existing file rather than moved over it: the shell
  # watches this path for live edits, and a fresh inode under it can cost the
  # watcher, and with it the reload that makes the row appear straight away.
  cat "$menu_tmp" >"$MENU_FILE"
  rm -f "$menu_tmp"
fi

say ""
say "Done. Search for Omasweeper in the launcher or the Omarchy menu, or bind"
say "a key to:"
say "  omarchy-shell shell toggle ${PLUGIN_ID}"
say ""
say "Closing the board unloads it again, so nothing of it runs while you are"
say "not playing. Press ? in the game for the keys."
