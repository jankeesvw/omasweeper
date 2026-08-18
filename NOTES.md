# NOTES — Omasweeper (jankeesvw.omasweeper)

Working notes for this repo. Read before changing `Panel.qml`.

## Status

**1.0.0, untagged.** Playable. Installed here as a dev symlink
(`~/.config/omarchy/plugins/jankeesvw.omasweeper` → this repo), enabled in the
right bar section — so **no hot reload**: `omarchy restart shell` after every
QML edit.

Verified in the live shell: dealing, the safe first click, flood fill,
flagging, clearing around a number, losing on a mine, winning a full board
(including the best-time record), and a game in progress surviving a shell
restart. Shell log clean.

## Design

**The model is four flat arrays.** `mine`, `adj`, `shown` and `flag`, each one
entry per cell, where a cell is `col + row * cols`. Nothing stores a position;
the delegate works its own `x`/`y` out of its index.

**Mutations copy the array and assign it back.** A QML `var` property only
notifies on assignment, so mutating an array in place leaves the board showing
the previous move. Every change takes a `slice()`, edits the copy, and assigns
— which is also why the flood fill collects into one copy and assigns once
rather than per cell.

**Mines are laid after the first click**, avoiding that cell and its eight
neighbours, so the opening move always breaks the board open. If the level is
too dense for that (it is not, at the three sizes here) only the clicked cell
is spared.

**One MouseArea for the whole grid**, not one per cell. An expert board is 480
cells and the cell under the pointer is a division away. It also puts all
three buttons in one place.

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
  game got a test IPC channel instead of a synthetic-input harness — see the
  README. It turned out to be the better tool anyway: it plays through the
  same functions the pointer calls.
- **Sounds must be silent while closed.** `newGame()` runs during state
  restore at shell start, so a blip that does not check `opened` fires a
  chirp every time the shell restarts, and once per call during a scripted
  test run.
- **A chord is one sound.** `chordAt` sets `quietMoves` around its reveals,
  or a single chord plays four open-blips on top of each other.

## Plugin plumbing

- `panel` + `bar-widget`. `omarchy plugin enable` writes only the bar layout
  entry for a plugin with both kinds, so removing the bar icon also unhooks a
  keybinding to the panel. Quattrolitaire works around that by appending its
  own `plugins[]` entry on first open; this one does not, because it does not
  edit the user's `shell.json` for a case that only comes up if you remove the
  icon on purpose. Add `{"id": "jankeesvw.omasweeper"}` to `plugins[]` by hand
  if you want the keybinding without the icon.
- `keepLoaded: true` is load-bearing. Without it the host's Loader destroys
  the instance on hide and the game in progress goes with it.

## Ideas, not committed to

- Seeded boards ("board #1234") so a game can be replayed or shared.
- A "no guessing" generator: deal until the board is solvable by deduction.
- Question marks as a third flag state.
- A chord that flashes the cells it is about to open while the button is held.
