# NOTES: Omasweeper (jankeesvw.omasweeper)

Working notes for this repo. Read before changing `Panel.qml`.

## Status

**1.1.1, untagged.** Playable. Installed here as a dev symlink
(`~/.config/omarchy/plugins/jankeesvw.omasweeper` → this repo), so **no hot
reload**: `omarchy restart shell` after every QML edit.

Verified in the live shell: dealing, the safe first click, flood fill,
flagging, clearing around a number, losing on a mine, winning a full board
(including the best-time record), and a game in progress surviving a shell
restart. Shell log clean.

1.1.0 dropped the bar widget and `keepLoaded`, and added vim motions plus the
`?` sheet. The motions and the sheet were verified through the test channel
(`key`, `cursor`, `snap`) against a second Quickshell instance running this
same `Panel.qml`, so the live shell never had to be restarted to check them:

```
qs -p <scratch-config>          # shell.qml = ShellRoot { Panel { open() } }
qs -p <scratch-config> ipc call jankeesvw.omasweeper.test key "g g 0 space"
```

The scratch config is three files: a `shell.qml` that opens the panel, a
`Panel.qml` symlink into this repo, and a `Commons` symlink to
`/usr/share/omarchy/shell/Commons` so `import qs.Commons` resolves.

Run that instance with `HOME` pointed at a throwaway directory. The state path
comes from `Quickshell.env("HOME")`, so without it a scratch run writes over
the real `~/.local/state/omasweeper/state.json`, records and all.

1.1.1 closed the input race and the 1.0 bar entry it left in `shell.json`. The
same scratch instance verified the race both ways: the harness holds the Panel
object, so it can press keys in the turn before the `FileView` load lands and
read `stateLoaded`, `started`, `level` and the MouseAreas back out.

## Design

**The model is four flat arrays.** `mine`, `adj`, `shown` and `flag`, each one
entry per cell, where a cell is `col + row * cols`. Nothing stores a position;
the delegate works its own `x`/`y` out of its index.

**Mutations copy the array and assign it back.** A QML `var` property only
notifies on assignment, so mutating an array in place leaves the board showing
the previous move. Every change takes a `slice()`, edits the copy, and assigns,
which is also why the flood fill collects into one copy and assigns once
rather than per cell.

**Mines are laid after the first click**, avoiding that cell and its eight
neighbours, so the opening move always breaks the board open. If the level is
too dense for that (it is not, at the three sizes here) only the clicked cell
is spared.

**One MouseArea for the whole grid**, not one per cell. An expert board is 480
cells and the cell under the pointer is a division away. It also puts all
three buttons in one place.

**Motions are vim's, and they clamp.** `hjkl` was there from the start; `0`,
`$`, `gg`, `G`, `H`/`M`/`L` and `ctrl-d`/`ctrl-u` came later. They all go
through `seedCursor()`, which returns false the first time and only places the
cursor in the middle. Reaching for `k` on a board with no cursor should not
throw you into a corner. `M` is the middle row and `m` is mute, told apart by
the shift modifier rather than by giving mute a different letter.

**The key list and the key handler are one list.** `keymap` is the model the
`?` sheet renders, and the bindings in `handleKey` are meant to match it. That
does not make them impossible to drift apart, but it does mean the sheet is
never a second place to remember to edit.

**The key handler lives on `root`, not in `Keys.onPressed`.** The window's
handler is three lines that call `root.handleKey(key, shift, ctrl)`, and so
does the test channel's `key`. A scripted keyboard therefore presses the same
keys the fingers do.

**The window is a `FloatingWindow`**, i.e. a normal XDG toplevel, not a
`PanelWindow`. That is the whole difference between this and the usual shell
panel: Hyprland tiles it, it takes focus normally, and the desktop stays
usable while it is open. "Floating" in that type name means "not layer-shell",
not "floating in the WM".

**Cell size comes from the window, the window's initial size comes from a
preferred cell.** Those are two different numbers on purpose: reading the
window size to compute the size you are asking the window to be is a binding
loop.

## Gotchas hit while building this

- **A typed asterisk will not centre.** `*` sits on the cap line, and how far
  up depends on the font, so it floats in a grid of digits. The mine is three
  drawn bars through one centre instead. The flag is still `⚑`, which does
  behave, but it is the one glyph here that could land differently on someone
  else's font stack.
- **`hyprctl dispatch` wants Lua now.** `hyprctl dispatch setfloating
  address:0x…` is a syntax error; it is
  `hyprctl dispatch 'hl.dsp.window.float({ action = "toggle" })'`, and the Lua
  dispatchers act on the *focused* window, so focus first or you will float
  something else.
- **ydotool is useless here.** Both absolute and relative `mousemove` moved
  nothing (two ydotoold instances fighting over one socket). That is why the
  game got a test IPC channel instead of a synthetic-input harness, see the
  README. It turned out to be the better tool anyway: it plays through the
  same functions the pointer calls.
- **Sounds must be silent while closed.** `newGame()` runs during state
  restore at shell start, so a blip that does not check `opened` fires a
  chirp every time the shell restarts, and once per call during a scripted
  test run.
- **A chord is one sound.** `chordAt` sets `quietMoves` around its reveals,
  or a single chord plays four open-blips on top of each other.
- **`grabToImage` beats a screenshot tool.** It re-renders the scene into an
  FBO rather than reading the screen, so `test snap` gets the board even when
  the window sits on a workspace nobody is looking at. That is what makes it
  possible to check the drawing without taking over the desktop to do it.
- **`hyprctl keyword` is gone if your config is Lua.** It answers "keyword
  can't work with non-legacy parsers", so a temporary window rule to park a
  test window somewhere harmless is not available. Move the window instead:
  `hyprctl dispatch 'hl.dsp.window.move({ window = "address:0x…",
  workspace = "99", silent = true })'`.

## Plugin plumbing

- `panel` only. A plugin that declares a `bar-widget` gets its enable written
  as a bar layout entry and nothing else, which means removing the icon also
  unhooks the keybinding to the panel. Without the bar widget, `omarchy plugin
  enable` writes the ordinary `plugins[]` entry and the bar is left alone.
- **Updating from 1.0 leaves a bar entry behind.** 1.0 declared a bar widget,
  so its enable was written into `bar.layout`. Nothing in this version can
  answer to that entry, and while it sits there `findEntryLocation()` finds it
  before it looks at `plugins[]`, so `setEnabled(id, true)` sees the plugin as
  already placed and writes nothing at all. `install.sh` clears it with a
  disable before the enable, which drops whichever entry is there and then
  writes the panel one. It has to wait for the rescan first: `plugin add` and
  `plugin update` fire `rescanPlugins` without waiting for it, and an enable
  run while the registry still holds 1.0's manifest splices a *fresh* bar entry
  into `center` instead. Both were checked by driving the real
  `PluginRegistry.qml` in a scratch instance with a fake config provider.
- **Nothing puts a panel plugin in front of the user, and nothing can.** `omarchy plugin add` clones, validates and registers, and that is all: there is no install hook, and `omarchy-plugin-validate` even refuses symlinks inside the folder, so a plugin never runs anything of its own at install time. The launcher indexes `.desktop` files, and the Omarchy menu merges `~/.config/omarchy/extensions/omarchy-menu.jsonc` over its defaults; neither knows about `plugins[]`. So `install.sh` writes both. The menu row goes between markers, the way `hey setup omarchy` does it, so a second run replaces it instead of stacking a copy. Two things that file's parser allows and the row leans on: `stripJsonc` drops whole-line `//` comments and any comma before a closing brace, so markers are safe and the row can end in a comma wherever it lands. A JSONC row's `aliases` are not only search terms: `resolveRoute()` walks them, so every alias is also an `omarchy menu summon` name. App rows are deliberately skipped there, because their aliases carry `.desktop` Keywords and GenericName and htop shipping `Keywords=system;` would otherwise shadow the `system` route. So the broad words (game, puzzle) go in the desktop entry, where they are searched but never routed, and the row keeps only `minesweeper` and `mines`. Categories are no help either way: the menu's apps provider builds one flat list and reads `Categories` not at all. The row's icon is nf-fa-bomb rather than the ⚑ the board flags with: that column is drawn in the shell font, and JetBrainsMono Nerd Font has no U+2691 (`fc-list ':charset=2691'` lists Noto Sans Symbols and little else), so the flag would ride on a font fallback. It is written through the existing file rather than moved over it, because the menu watches the path with a `FileView` and a new inode under it can cost the live reload.

- **Nothing is kept loaded.** `keepLoaded: true` is gone: the host's Loader
  destroys the instance on hide, so a closed board costs the shell nothing.
  What used to make `keepLoaded` load-bearing, losing the game in progress,
  is handled by `writeState()`, which `close()` calls directly rather than
  leaving the 400ms debounce to a timer that is about to be destroyed.

## Ideas, not committed to

- Seeded boards ("board #1234") so a game can be replayed or shared.
- A "no guessing" generator: deal until the board is solvable by deduction.
- Question marks as a third flag state.
- A chord that flashes the cells it is about to open while the button is held.
