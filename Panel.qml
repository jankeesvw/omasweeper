import Quickshell
import Quickshell.Io
import QtQuick
import QtQuick.Shapes
import qs.Commons

// Omasweeper, Minesweeper for omarchy-shell. Summoned/toggled through the shell host:
//   omarchy-shell shell toggle jankeesvw.omasweeper
// The host calls open(payloadJson) / close() and reads `opened`; it also
// injects `shell` right after the Loader resolves (see onShellChanged).
//
// Nothing is bundled: the board, the numbers, the flags and the mines are all
// drawn here and coloured from the live theme, so the whole thing recolours
// with the desktop.
//
// The model is four flat arrays indexed by cell, where a cell is
// `col + row * cols`, plus a handful of counters. Every mutation copies the
// array it touches and assigns the copy back, because a QML `var` property
// only notifies on assignment: mutating in place would leave the board
// showing the previous move. That copy is also what makes undo-free
// restore-from-disk trivial, since a cell is never anything but its index.
//
// Nothing is kept loaded: closing the board lets the host's Loader destroy
// this instance, so a closed game costs the shell nothing. The board in
// progress lives on disk instead, written after every move and flushed on
// close, and the next open reads it back.
Item {
  id: root

  property bool opened: false

  readonly property string selfId: "jankeesvw.omasweeper"

  // Injected by the shell host after the Loader resolves. Used to keep the
  // host's open-flag honest on close(), and to self-restore if the host's
  // panel Instantiator rebuild destroys a visibly-open instance.
  property var shell: null
  onShellChanged: {
    if (!root.opened && root.shell && root.shell.openPanelIds
        && root.shell.openPanelIds[root.selfId] === true)
      root.open("{}")
  }

  // ------------------------------------------------------------------ theme
  //
  // Shares the [menu] surface tokens so a theme that styles the menu styles
  // this panel too. Everything on the board is derived from those tokens
  // rather than pinned, so the tiles stay readable on a light theme and a
  // dark one without a second palette to maintain.
  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color accent: Color.accent
  property color urgent: Color.urgent
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding

  function lum(c) { return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b }
  function mix(a, b, t) {
    return Qt.rgba(a.r + (b.r - a.r) * t,
                   a.g + (b.g - a.g) * t,
                   a.b + (b.b - a.b) * t, 1)
  }
  readonly property bool darkSurface: root.lum(root.background) < 0.5

  // A covered cell is a filled character cell, an opened one is bare board.
  // Everything else on the board is a hairline, so the contrast budget goes
  // almost entirely into that one difference.
  readonly property color boardBg: root.mix(root.background, root.foreground, 0.03)
  readonly property color coverFill: root.mix(root.background, root.foreground, root.darkSurface ? 0.15 : 0.12)
  readonly property color coverDot: root.mix(root.background, root.foreground, 0.32)
  readonly property color hoverFill: root.mix(root.background, root.accent, 0.24)
  readonly property color pressFill: root.mix(root.background, root.accent, 0.40)
  readonly property color gridLine: root.mix(root.background, root.foreground, 0.17)
  readonly property color dim: root.mix(root.background, root.foreground, 0.42)
  readonly property color segFill: root.mix(root.background, root.foreground, 0.10)
  readonly property color segValueFill: root.mix(root.background, root.foreground, 0.05)

  // The eight numbers are ANSI, not the Windows palette: this is a board drawn
  // in a terminal, and 3 should be the same red as an error line above it.
  readonly property var numberColors: root.darkSurface
    ? ["#7aa2f7", "#9ece6a", "#f7768e", "#bb9af7", "#e0af68", "#7dcfff", "#c0caf5", "#565f89"]
    : ["#2563eb", "#15803d", "#dc2626", "#7c3aed", "#b45309", "#0891b2", "#1f2937", "#6b7280"]

  // ------------------------------------------------------------- difficulty

  readonly property var levels: [
    { key: "beginner",     name: "Beginner",     cols: 9,  rows: 9,  mines: 10 },
    { key: "intermediate", name: "Intermediate", cols: 16, rows: 16, mines: 40 },
    { key: "expert",       name: "Expert",       cols: 30, rows: 16, mines: 99 }
  ]
  property int level: 0
  readonly property var levelSpec: root.levels[Math.max(0, Math.min(root.levels.length - 1, root.level))]
  readonly property int cols: root.levelSpec.cols
  readonly property int rows: root.levelSpec.rows
  readonly property int mineCount: root.levelSpec.mines
  readonly property int cellCount: root.cols * root.rows

  // ------------------------------------------------------------- game model

  property var mine: []        // booleans, one per cell
  property var adj: []         // 0-8, mines touching this cell
  property var shown: []       // booleans, revealed
  property var flag: []        // booleans, flagged
  property bool armed: false   // mines are laid, i.e. the first click happened
  property bool started: false
  property bool dead: false
  property bool won: false
  property int boom: -1        // the mine that went off, drawn hot
  property int shownCount: 0
  property int flagsUsed: 0
  property int seconds: 0
  property var stats: root.blankStats()

  readonly property bool finished: root.dead || root.won
  readonly property int minesLeft: root.mineCount - root.flagsUsed

  function blankStats() {
    return {
      beginner:     { played: 0, won: 0, best: 0 },
      intermediate: { played: 0, won: 0, best: 0 },
      expert:       { played: 0, won: 0, best: 0 }
    }
  }

  function levelStats() {
    var s = root.stats[root.levelSpec.key]
    return s ? s : { played: 0, won: 0, best: 0 }
  }

  function timeText(s) {
    var t = Math.max(0, Math.floor(s))
    var m = Math.floor(t / 60)
    var sec = t % 60
    return m + ":" + (sec < 10 ? "0" : "") + sec
  }

  // Eight neighbours, minus whatever falls off an edge. Column arithmetic
  // rather than a lookup table, so a difficulty switch needs no rebuild.
  function neighbours(i) {
    var out = []
    var c = i % root.cols
    var r = Math.floor(i / root.cols)
    for (var dr = -1; dr <= 1; dr++) {
      for (var dc = -1; dc <= 1; dc++) {
        if (dr === 0 && dc === 0) continue
        var nc = c + dc
        var nr = r + dr
        if (nc < 0 || nc >= root.cols || nr < 0 || nr >= root.rows) continue
        out.push(nc + nr * root.cols)
      }
    }
    return out
  }

  // --------------------------------------------------------------- new game

  function newGame() {
    var m = []
    var a = []
    var s = []
    var f = []
    for (var i = 0; i < root.cellCount; i++) {
      m.push(false)
      a.push(0)
      s.push(false)
      f.push(false)
    }
    root.mine = m
    root.adj = a
    root.shown = s
    root.flag = f
    root.armed = false
    root.started = false
    root.dead = false
    root.won = false
    root.boom = -1
    root.shownCount = 0
    root.flagsUsed = 0
    root.seconds = 0
    root.cursor = -1
    root.cursorShown = false
    root.hoverIndex = -1
    root.pressIndex = -1
    root.blip("deal")
    root.save()
  }

  function setLevel(index) {
    if (index < 0 || index >= root.levels.length) return
    if (index === root.level) return
    root.level = index
    root.newGame()
  }

  // The first click is always safe, and so is everything around it: mines are
  // laid after it, avoiding that cell and its neighbours, so the opening move
  // always breaks the board open instead of ending the game.
  function layMines(safe) {
    var blocked = {}
    blocked[safe] = true
    var around = root.neighbours(safe)
    var i
    for (i = 0; i < around.length; i++) blocked[around[i]] = true

    var pool = []
    for (i = 0; i < root.cellCount; i++) if (!blocked[i]) pool.push(i)

    // A tight board (9x9 with a lot of mines) can have fewer free cells than
    // mines to place; then only the clicked cell itself stays safe.
    if (pool.length < root.mineCount) {
      pool = []
      for (i = 0; i < root.cellCount; i++) if (i !== safe) pool.push(i)
    }

    // Fisher-Yates over the candidates, take the first mineCount of them.
    for (i = pool.length - 1; i > 0; i--) {
      var j = Math.floor(Math.random() * (i + 1))
      var tmp = pool[i]
      pool[i] = pool[j]
      pool[j] = tmp
    }

    var m = []
    for (i = 0; i < root.cellCount; i++) m.push(false)
    for (i = 0; i < root.mineCount && i < pool.length; i++) m[pool[i]] = true

    root.mine = m
    root.adj = root.countAdjacency(m)
    root.armed = true
  }

  function countAdjacency(m) {
    var a = []
    for (var i = 0; i < root.cellCount; i++) {
      if (m[i]) { a.push(0); continue }
      var nb = root.neighbours(i)
      var n = 0
      for (var k = 0; k < nb.length; k++) if (m[nb[k]]) n++
      a.push(n)
    }
    return a
  }

  // ------------------------------------------------------------------ play

  function revealAt(i) {
    if (root.finished) return
    if (i < 0 || i >= root.cellCount) return
    if (root.shown[i] === true || root.flag[i] === true) return

    if (!root.armed) root.layMines(i)
    root.started = true

    if (root.mine[i] === true) { root.explode(i); return }

    // Flood out of an empty cell, iteratively: a 30x16 expert board can open
    // most of itself in one click and recursion here is a stack you do not
    // need to spend. A flagged cell stops the flood, exactly as it should.
    var s = root.shown.slice()
    var count = root.shownCount
    var stack = [i]
    while (stack.length > 0) {
      var c = stack.pop()
      if (s[c] === true) continue
      s[c] = true
      count++
      if (root.adj[c] !== 0) continue
      var nb = root.neighbours(c)
      for (var k = 0; k < nb.length; k++) {
        var n = nb[k]
        if (s[n] !== true && root.flag[n] !== true) stack.push(n)
      }
    }
    root.shown = s
    root.shownCount = count
    if (!root.quietMoves) root.blip("open")
    root.checkWin()
    root.save()
  }

  function toggleFlag(i) {
    if (root.finished) return
    if (i < 0 || i >= root.cellCount) return
    if (root.shown[i] === true) return
    var f = root.flag.slice()
    f[i] = f[i] !== true
    root.flag = f
    root.flagsUsed += f[i] ? 1 : -1
    root.blip(f[i] ? "flag" : "unflag")
    root.save()
  }

  // Clearing around a satisfied number: the move that makes the endgame fast
  // and is also the only way to lose a game you had solved. Deliberately not
  // guarded any further than the count.
  function chordAt(i) {
    if (root.finished) return
    if (root.shown[i] !== true) return
    var n = root.adj[i] || 0
    if (n === 0) return
    var nb = root.neighbours(i)
    var flags = 0
    var k
    for (k = 0; k < nb.length; k++) if (root.flag[nb[k]] === true) flags++
    if (flags !== n) return
    // One chord is one sound, not one per cell it opens.
    root.blip("chord")
    root.quietMoves = true
    for (k = 0; k < nb.length; k++) {
      if (root.finished) break
      root.revealAt(nb[k])
    }
    root.quietMoves = false
  }

  // Left-click does the obvious thing for where it landed: open a covered
  // cell, clear around an opened number.
  function primaryAt(i) {
    if (i < 0 || i >= root.cellCount) return
    if (root.shown[i] === true) root.chordAt(i)
    else root.revealAt(i)
  }

  function explode(i) {
    root.dead = true
    root.boom = i
    var s = root.shown.slice()
    for (var c = 0; c < root.cellCount; c++) {
      if (root.mine[c] === true && root.flag[c] !== true) s[c] = true
    }
    root.shown = s
    root.blip("boom")
    root.recordEnd(false)
    root.save()
  }

  function checkWin() {
    if (root.shownCount !== root.cellCount - root.mineCount) return
    root.won = true
    // Flag whatever is left: a cleared board should look cleared rather than
    // leave the last few mines as covered cells the player has to trust.
    var f = root.flag.slice()
    var used = 0
    for (var c = 0; c < root.cellCount; c++) {
      f[c] = root.mine[c] === true
      if (f[c]) used++
    }
    root.flag = f
    root.flagsUsed = used
    root.blip("win")
    root.recordEnd(true)
  }

  property bool newBest: false

  // The caret on the verdict line. 530ms is the blink a terminal uses.
  property bool caretOn: true
  Timer {
    interval: 530
    repeat: true
    running: root.opened && root.finished
    onTriggered: root.caretOn = !root.caretOn
  }

  function recordEnd(victory) {
    var key = root.levelSpec.key
    var all = JSON.parse(JSON.stringify(root.stats))
    var s = all[key] ? all[key] : { played: 0, won: 0, best: 0 }
    s.played = (s.played || 0) + 1
    root.newBest = false
    if (victory) {
      s.won = (s.won || 0) + 1
      if (!s.best || root.seconds < s.best) {
        s.best = root.seconds
        root.newBest = true
      }
    }
    all[key] = s
    root.stats = all
  }

  // ------------------------------------------------------------------ clock

  // Runs while the board is open and the game is live. Closing the panel
  // stops it: the game is paused on the shelf, not running in the background.
  Timer {
    interval: 1000
    repeat: true
    running: root.opened && root.started && !root.finished
    onTriggered: {
      root.seconds++
      if (root.seconds % 10 === 0) root.save()
    }
  }

  // ------------------------------------------------------------------ sound
  //
  // Square waves from sounds/, played through a tiny shell script that picks
  // whichever player the machine has. Nothing is ever played while the window
  // is closed, which keeps a shell restart (and the test IPC) silent.

  property bool sound: true
  property bool quietMoves: false   // set while a chord fans out, so one chord is one sound

  readonly property string assetDir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "")

  function blip(name) {
    if (!root.sound || !root.opened) return
    // sh <script> rather than the script itself, so a checkout that lost its
    // executable bit still makes noise.
    Quickshell.execDetached(["sh", root.assetDir + "bin/omasweeper-play",
                             root.assetDir + "sounds/" + name + ".wav"])
  }

  // ------------------------------------------------------------- persistence

  readonly property string home: Quickshell.env("HOME")
  readonly property string stateDir: root.home + "/.local/state/omasweeper"
  readonly property string statePath: root.stateDir + "/state.json"
  property bool stateLoaded: false

  function save() {
    if (!root.stateLoaded) return
    saveTimer.restart()
  }

  // Debounced: a chord can fire several reveals in a row and each one would
  // otherwise be its own atomic file write.
  Timer {
    id: saveTimer
    interval: 400
    repeat: false
    onTriggered: root.writeState()
  }

  // The write itself. Closing the board calls this directly: the instance is
  // about to be destroyed, and a pending debounce would be destroyed with it.
  function writeState() {
    if (!root.stateLoaded) return
    saveTimer.stop()
    var live = root.started && !root.finished
    var payload = JSON.stringify({
      version: 1,
      level: root.levelSpec.key,
      sound: root.sound,
      stats: root.stats,
      game: live ? {
        armed: root.armed,
        seconds: root.seconds,
        mines: root.indicesWhere(root.mine),
        shown: root.indicesWhere(root.shown),
        flags: root.indicesWhere(root.flag)
      } : null
    }, null, 2) + "\n"
    stateFile.setText(payload)
  }

  // Piles of booleans compress to the indices that are true, which is both
  // smaller on disk and trivial to validate on the way back in.
  function indicesWhere(arr) {
    var out = []
    for (var i = 0; i < root.cellCount; i++) if (arr[i] === true) out.push(i)
    return out
  }

  function levelIndexOf(key) {
    for (var i = 0; i < root.levels.length; i++) if (root.levels[i].key === key) return i
    return -1
  }

  // A saved game is only restored if it still describes a board this
  // difficulty could have produced: the right number of mines, every index in
  // range and unique, and no opened cell sitting on a mine. Anything else
  // deals a fresh board rather than half of one.
  function restoreGame(g) {
    if (!g || typeof g !== "object") return false

    function claim(list, into) {
      if (!Array.isArray(list)) return false
      for (var i = 0; i < list.length; i++) {
        var v = list[i]
        if (typeof v !== "number" || v < 0 || v >= root.cellCount || into[v] === true) return false
        into[v] = true
      }
      return true
    }

    var m = []
    var s = []
    var f = []
    var i
    for (i = 0; i < root.cellCount; i++) { m.push(false); s.push(false); f.push(false) }

    if (!claim(g.mines, m) || !claim(g.shown, s) || !claim(g.flags, f)) return false
    if (g.mines.length !== root.mineCount) return false
    if (g.armed !== true && g.mines.length > 0) return false
    for (i = 0; i < root.cellCount; i++) {
      if (m[i] && s[i]) return false          // an opened mine is a finished game
      if (s[i] && f[i]) return false          // and a flag on it is nonsense
    }
    if (g.shown.length >= root.cellCount - root.mineCount) return false

    root.mine = m
    root.shown = s
    root.flag = f
    root.adj = root.countAdjacency(m)
    root.armed = true
    root.started = true
    root.dead = false
    root.won = false
    root.boom = -1
    root.shownCount = g.shown.length
    root.flagsUsed = g.flags.length
    root.seconds = Math.max(0, Number(g.seconds) || 0)
    return true
  }

  function applyState(raw) {
    var st = null
    try { st = JSON.parse(String(raw || "").trim()) } catch (e) {}

    if (st && typeof st === "object") {
      var idx = root.levelIndexOf(String(st.level || ""))
      if (idx >= 0) root.level = idx
      if (st.sound === false) root.sound = false
      if (st.stats && typeof st.stats === "object") {
        var all = root.blankStats()
        for (var key in all) {
          var s = st.stats[key]
          if (!s || typeof s !== "object") continue
          all[key] = {
            played: Math.max(0, Number(s.played) || 0),
            won: Math.max(0, Number(s.won) || 0),
            best: Math.max(0, Number(s.best) || 0)
          }
        }
        root.stats = all
      }
      if (root.restoreGame(st.game)) { root.stateLoaded = true; return }
    }

    root.stateLoaded = true
    root.newGame()
  }

  FileView {
    id: stateFile
    path: root.statePath
    atomicWrites: true
    printErrors: false
    onLoaded: root.applyState(text())
    onLoadFailed: function(err) { root.applyState("") }
  }

  // Make sure the state dir exists, then (re)load the state file.
  Process {
    id: mkStateDir
    command: ["mkdir", "-p", root.stateDir]
    onExited: stateFile.reload()
  }

  Component.onCompleted: mkStateDir.running = true

  // ------------------------------------------------------------- open/close

  function open(payloadJson) {
    root.opened = true
    if (root.stateLoaded && root.cellCount !== root.mine.length) root.newGame()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    if (!root.opened) return
    root.opened = false
    root.hoverIndex = -1
    root.pressIndex = -1
    root.helpOpen = false
    // A finished board is history the moment you look away: the next open
    // deals rather than greeting you with the result you already read.
    if (root.finished) root.newGame()
    root.writeState()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide(root.selfId)
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open("{}")
  }

  // ------------------------------------------------------------------ layout
  //
  // The board is a character grid: square cells on hairlines, with a gutter of
  // base-36 column and row labels around it, the way a hex dump numbers its
  // rows. One number, the cell, sizes the whole thing, and the gutter is one
  // cell wide on both axes so a label is always exactly one character.

  // Everything in the surface that is not board. Measured rather than guessed,
  // and none of it reads the surface size, so sizing the surface from it is
  // safe.
  readonly property int chromeHeight: header.height + Style.spacing.md * 4 + 2 + statusLine.height

  // Taken from the window rather than the screen, so a tiled or resized
  // window grows the board with it. The cap keeps a beginner board from
  // becoming a wall of dinner plates on a wide monitor.
  readonly property int cellSize: {
    var availW = win.width - root.frameInsetW
    var availH = win.height - root.frameInsetH
    return Math.max(Style.space(9),
                    Math.floor(Math.min(availW / (root.cols + 1),
                                        availH / (root.rows + 1),
                                        Style.space(64))))
  }
  readonly property int gridW: root.cols * root.cellSize
  readonly property int gridH: root.rows * root.cellSize
  readonly property int gutter: root.cellSize
  readonly property int boardW: root.gutter + root.gridW
  readonly property int boardH: root.gutter + root.gridH
  readonly property int cellFont: Math.max(8, Math.round(root.cellSize * 0.60))
  readonly property int labelFont: Math.max(7, Math.round(root.cellSize * 0.42))

  // Base 36, so the 30 columns of an expert board and the 16 rows still get
  // one character each: 0-9 then a-t.
  function label36(n) { return Number(n).toString(36) }

  // Three digits, the way the counter on a cabinet game reads.
  function pad3(n) {
    var v = Math.max(0, Math.min(999, Math.floor(n)))
    return (v < 10 ? "00" : v < 100 ? "0" : "") + v
  }

  // ---------------------------------------------------------------- keymap
  //
  // The single list of bindings: the `?` sheet renders it, and so does the
  // hint line in the status bar. A binding that ships therefore cannot go
  // missing from the help, which is the usual way help rots.
  //
  // The motions are vim's. hjkl was already here; the rest is what a hand
  // that types hjkl reaches for next. H and L land where gg and G do, because
  // the whole board is always on screen and there is nothing to scroll. They
  // are bound anyway, since a finger that expects them expects them.

  property bool helpOpen: false

  readonly property string widestKey: {
    var w = ""
    for (var i = 0; i < root.keymap.length; i++)
      for (var j = 0; j < root.keymap[i].keys.length; j++)
        if (root.keymap[i].keys[j].key.length > w.length) w = root.keymap[i].keys[j].key
    return w
  }

  readonly property var keymap: [
    {
      group: "motion",
      keys: [
        { key: "h j k l", what: "left, down, up, right" },
        { key: "arrows",  what: "the same, for the other hand" },
        { key: "0 ^",     what: "first cell of the row" },
        { key: "$",       what: "last cell of the row" },
        { key: "gg",      what: "top of the column" },
        { key: "G",       what: "bottom of the column" },
        { key: "H M L",   what: "top, middle, bottom row" },
        { key: "C-d C-u", what: "half a board down, up" }
      ]
    },
    {
      group: "play",
      keys: [
        { key: "space",   what: "open the cell" },
        { key: "enter",   what: "open, or deal again when finished" },
        { key: "f",       what: "flag or unflag" },
        { key: "n",       what: "new game" }
      ]
    },
    {
      group: "game",
      keys: [
        { key: "1 2 3",   what: "beginner, intermediate, expert" },
        { key: "m",       what: "mute" },
        { key: "?",       what: "these keys" },
        { key: "q esc",   what: "close" }
      ]
    }
  ]

  // ------------------------------------------------------------- pointer state

  property int hoverIndex: -1
  property int pressIndex: -1
  property int cursor: -1          // keyboard cursor, -1 until an arrow is used
  property bool cursorShown: false

  readonly property int activeIndex: root.cursorShown && root.cursor >= 0 ? root.cursor : root.hoverIndex
  readonly property int activeCol: root.activeIndex >= 0 ? root.activeIndex % root.cols : -1
  readonly property int activeRow: root.activeIndex >= 0 ? Math.floor(root.activeIndex / root.cols) : -1

  // Every motion goes through here, so the first key pressed on a board with
  // no cursor yet only places one, in the middle. There is nothing to move
  // relative to before that, and landing in a corner because you reached for
  // `k` is not a start.
  function seedCursor() {
    if (root.cursor >= 0) return true
    root.cursor = Math.floor(root.rows / 2) * root.cols + Math.floor(root.cols / 2)
    root.cursorShown = true
    return false
  }

  // Clamped rather than wrapped: a board has edges, and vim's motions stop at
  // them too.
  function placeCursor(c, r) {
    root.cursor = Math.max(0, Math.min(root.cols - 1, c))
                + Math.max(0, Math.min(root.rows - 1, r)) * root.cols
    root.cursorShown = true
  }

  function moveCursor(dc, dr) {
    if (!root.seedCursor()) return
    root.placeCursor((root.cursor % root.cols) + dc,
                     Math.floor(root.cursor / root.cols) + dr)
  }

  // Column-preserving and row-preserving jumps, the two halves of 0/$/gg/G.
  function jumpToCol(c) {
    if (!root.seedCursor()) return
    root.placeCursor(c, Math.floor(root.cursor / root.cols))
  }

  function jumpToRow(r) {
    if (!root.seedCursor()) return
    root.placeCursor(root.cursor % root.cols, r)
  }

  // -------------------------------------------------------------------- parts

  // A tab in the header, drawn the way a tmux window list draws one: the
  // selected entry is the colours inverted, not a box with a border.
  component TermTab: Item {
    id: tab
    property string label: ""
    property bool active: false
    property string tip: ""
    signal activated()

    implicitWidth: tabText.implicitWidth + Style.spacing.md * 2
    implicitHeight: tabText.implicitHeight + Style.spacing.xs * 2

    Rectangle {
      anchors.fill: parent
      color: tab.active ? root.accent
           : tabMouse.containsMouse ? root.segFill
           : "transparent"
    }
    Text {
      id: tabText
      anchors.centerIn: parent
      text: tab.label
      color: tab.active ? root.background : root.foreground
      opacity: tab.active || tabMouse.containsMouse ? 1 : 0.7
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }
    MouseArea {
      id: tabMouse
      anchors.fill: parent
      // Dead until the saved game is back, for the same reason handleKey and
      // the grid are: every tab here picks a level, deals, or writes a
      // setting, and the restore is about to overwrite all three.
      enabled: root.stateLoaded
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: tab.activated()
    }
  }

  // A mine, drawn rather than typed. The asterisk is the right character for
  // it, but no two fonts agree where its ink sits inside the line box, and a
  // mark that floats high in a grid of digits is the sort of thing you cannot
  // unsee. Three bars through one centre cannot be off centre.
  component MineMark: Item {
    id: mark
    property color tint: "#000000"

    Repeater {
      model: 3
      delegate: Rectangle {
        required property int index
        anchors.centerIn: parent
        width: mark.width
        height: Math.max(1, Math.round(mark.width * 0.22))
        radius: height / 2
        color: mark.tint
        rotation: index * 60
      }
    }
  }

  // One reading on the status line: a label block and its value block, butted
  // together with no gap, so the row reads as one bar rather than four boxes.
  component StatusSeg: Row {
    id: seg
    property string label: ""
    property string value: ""
    property bool hot: false
    spacing: 0

    Rectangle {
      width: segLabel.implicitWidth + Style.spacing.sm * 2
      height: segLabel.implicitHeight + Style.spacing.xxs * 2
      color: seg.hot ? root.accent : root.segFill
      Text {
        id: segLabel
        anchors.centerIn: parent
        text: seg.label
        color: seg.hot ? root.background : root.foreground
        opacity: seg.hot ? 1 : 0.75
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
    Rectangle {
      width: segValue.implicitWidth + Style.spacing.sm * 2
      height: segLabel.implicitHeight + Style.spacing.xxs * 2
      color: root.segValueFill
      Text {
        id: segValue
        anchors.centerIn: parent
        text: seg.value
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  // ------------------------------------------------------------------- keys
  //
  // One handler, called both by the window's Keys.onPressed and by the test
  // IPC, so a scripted keyboard and a real one cannot drift apart. Returns
  // whether the key was ours.
  //
  // `g` is the only prefix here, and it only ever leads to `gg`. It is
  // cleared by every other key rather than by a timeout, the way vim clears a
  // pending operator: g then j is a j, not a lost keystroke.

  property bool pendingG: false

  function handleKey(key, shift, ctrl) {
    // Nothing is playable until the saved game is back. The restore replaces
    // every cell, so a move made before it lands is a move undone, and save()
    // refuses to write one anyway. Closing stays live: a state file that is
    // slow to arrive must not lock you inside the window.
    if (!root.stateLoaded && key !== Qt.Key_Escape && !(key === Qt.Key_Q && !ctrl))
      return true

    var afterG = root.pendingG
    root.pendingG = false

    // The help sheet is a page you dismiss, not a layer you play through:
    // while it is up, every key closes it or does nothing at all.
    if (root.helpOpen) {
      if (key === Qt.Key_Question || key === Qt.Key_Escape || key === Qt.Key_Q
          || key === Qt.Key_Space || key === Qt.Key_Return || key === Qt.Key_Enter)
        root.helpOpen = false
      return true
    }

    if (key === Qt.Key_Question) {
      root.helpOpen = true
    } else if (key === Qt.Key_Escape || (key === Qt.Key_Q && !ctrl)) {
      root.close()
    } else if (key === Qt.Key_N && !ctrl) {
      root.newGame()
    } else if (key === Qt.Key_1) {
      root.setLevel(0)
    } else if (key === Qt.Key_2) {
      root.setLevel(1)
    } else if (key === Qt.Key_3) {
      root.setLevel(2)

    // ---- motion
    } else if (key === Qt.Key_Left || (key === Qt.Key_H && !shift)) {
      root.moveCursor(-1, 0)
    } else if (key === Qt.Key_Right || (key === Qt.Key_L && !shift)) {
      root.moveCursor(1, 0)
    } else if (key === Qt.Key_Up || (key === Qt.Key_K && !shift)) {
      root.moveCursor(0, -1)
    } else if (key === Qt.Key_Down || (key === Qt.Key_J && !shift)) {
      root.moveCursor(0, 1)
    } else if (key === Qt.Key_0 || key === Qt.Key_AsciiCircum) {
      root.jumpToCol(0)
    } else if (key === Qt.Key_Dollar) {
      root.jumpToCol(root.cols - 1)
    } else if (key === Qt.Key_G) {
      if (shift) root.jumpToRow(root.rows - 1)          // G
      else if (afterG) root.jumpToRow(0)                // gg
      else root.pendingG = true
    } else if (key === Qt.Key_H && shift) {
      root.jumpToRow(0)
    } else if (key === Qt.Key_M && shift) {
      root.jumpToRow(Math.floor((root.rows - 1) / 2))
    } else if (key === Qt.Key_L && shift) {
      root.jumpToRow(root.rows - 1)
    } else if (key === Qt.Key_D && ctrl) {
      root.moveCursor(0, Math.floor(root.rows / 2))
    } else if (key === Qt.Key_U && ctrl) {
      root.moveCursor(0, -Math.floor(root.rows / 2))

    // ---- play
    } else if (key === Qt.Key_Space || key === Qt.Key_Return || key === Qt.Key_Enter) {
      if (root.finished) root.newGame()
      else if (root.cursor >= 0) root.primaryAt(root.cursor)
      else root.seedCursor()
    } else if (key === Qt.Key_F && !ctrl) {
      if (root.cursor >= 0) root.toggleFlag(root.cursor)
      else root.seedCursor()
    } else if (key === Qt.Key_M) {
      root.sound = !root.sound
      root.save()
      if (root.sound) root.blip("flag")
    } else {
      return false
    }
    return true
  }

  // A key by the name you would call it: "h", "G", "gg" is two of these, "$",
  // "C-d", "space", "?". Anything else is a miss the caller hears about.
  function keyByName(name) {
    var ctrl = false
    var n = String(name)
    if (n.length > 2 && n.slice(0, 2).toUpperCase() === "C-") {
      ctrl = true
      n = n.slice(2)
    }
    var named = {
      "space": Qt.Key_Space, "enter": Qt.Key_Return, "return": Qt.Key_Return,
      "esc": Qt.Key_Escape, "escape": Qt.Key_Escape,
      "left": Qt.Key_Left, "right": Qt.Key_Right, "up": Qt.Key_Up, "down": Qt.Key_Down,
      "?": Qt.Key_Question, "$": Qt.Key_Dollar, "^": Qt.Key_AsciiCircum
    }
    var lower = n.toLowerCase()
    if (named[lower] !== undefined) return { key: named[lower], shift: false, ctrl: ctrl }
    if (n.length !== 1) return null
    if (n >= "0" && n <= "9") return { key: Qt.Key_0 + (n.charCodeAt(0) - 48), shift: false, ctrl: ctrl }
    if (lower >= "a" && lower <= "z")
      return { key: Qt.Key_A + (lower.charCodeAt(0) - 97), shift: n !== lower, ctrl: ctrl }
    return null
  }

  // -------------------------------------------------------------------- test

  // Lets the game be played without a hand on the mouse, which is the only way
  // to exercise it in a headless run. The channel is this instance, so it only
  // answers while the board is open -- a closed board is unloaded, and the
  // handler goes with it:
  //   omarchy-shell shell summon jankeesvw.omasweeper
  //   omarchy-shell jankeesvw.omasweeper.test deal
  //   omarchy-shell jankeesvw.omasweeper.test play 4 4
  //   omarchy-shell jankeesvw.omasweeper.test board
  // Every entry point goes through the same functions the pointer calls, so a
  // scripted game and a played one cannot drift apart.
  IpcHandler {
    target: "jankeesvw.omasweeper.test"

    function play(col: int, row: int): string {
      if (col < 0 || col >= root.cols || row < 0 || row >= root.rows) return "off the board"
      root.primaryAt(col + row * root.cols)
      return root.summary()
    }

    function flag(col: int, row: int): string {
      if (col < 0 || col >= root.cols || row < 0 || row >= root.rows) return "off the board"
      root.toggleFlag(col + row * root.cols)
      return root.summary()
    }

    function deal(): string {
      root.newGame()
      return root.summary()
    }

    function level(name: string): string {
      var i = root.levelIndexOf(name)
      if (i < 0) return "no level named " + name
      root.setLevel(i)
      return root.summary()
    }

    // The board as text: # covered, F flag, * mine, . opened and empty.
    function board(): string {
      var out = []
      for (var r = 0; r < root.rows; r++) {
        var line = ""
        for (var c = 0; c < root.cols; c++) {
          var i = c + r * root.cols
          if (root.flag[i] === true) line += "F"
          else if (root.shown[i] !== true) line += "#"
          else if (root.mine[i] === true) line += "*"
          else if ((root.adj[i] || 0) > 0) line += String(root.adj[i])
          else line += "."
        }
        out.push(line)
      }
      return out.join("\n")
    }

    function state(): string { return root.summary() }

    // Types keys the way fingers do, one name per press: "h", "G", "$",
    // "C-d", "space", "?". `gg` is "g g", which is also how you type it.
    function key(names: string): string {
      var list = String(names).trim().split(/\s+/)
      for (var i = 0; i < list.length; i++) {
        if (list[i] === "") continue
        var k = root.keyByName(list[i])
        if (!k) return "no key named " + list[i]
        root.handleKey(k.key, k.shift, k.ctrl)
      }
      return root.cursorSummary()
    }

    // Where the keyboard cursor is, and whether the help sheet is up.
    function cursor(): string { return root.cursorSummary() }

    // The window as a PNG. Renders the scene graph rather than reading the
    // screen, so a board on a workspace you are not looking at still comes
    // out, which is the only way to check the drawing without taking over
    // the desktop to do it.
    function snap(path: string): string {
      if (!root.opened) return "not open"
      var target = String(path)
      var ok = keyCatcher.grabToImage(function(result) { result.saveToFile(target) })
      return ok ? "ok " + target : "grab failed"
    }

    // Spoils the board on purpose: the mine map as "col,row" pairs, so a test
    // can flag correctly and play a game out to a win. Nothing in the UI can
    // reach this.
    function mines(): string {
      var out = []
      for (var i = 0; i < root.cellCount; i++) {
        if (root.mine[i] === true) out.push((i % root.cols) + "," + Math.floor(i / root.cols))
      }
      return out.join(" ")
    }
  }

  function cursorSummary() {
    return JSON.stringify({
      cursor: root.cursor,
      col: root.cursor >= 0 ? root.cursor % root.cols : -1,
      row: root.cursor >= 0 ? Math.floor(root.cursor / root.cols) : -1,
      shown: root.cursorShown,
      pendingG: root.pendingG,
      help: root.helpOpen
    })
  }

  function summary() {
    return JSON.stringify({
      // The channel is deliberately not behind the input gate the keyboard and
      // the pointer are: a harness that cannot touch a loading board cannot
      // test one. It does have to be able to see the gate, though, or a
      // scripted deal lands before the restore and is quietly undone.
      loaded: root.stateLoaded,
      level: root.levelSpec.key,
      cols: root.cols,
      rows: root.rows,
      mines: root.mineCount,
      minesLeft: root.minesLeft,
      opened: root.shownCount,
      flags: root.flagsUsed,
      seconds: root.seconds,
      armed: root.armed,
      started: root.started,
      dead: root.dead,
      won: root.won,
      stats: root.stats[root.levelSpec.key]
    })
  }


  // ------------------------------------------------------------------ window
  //
  // A normal toplevel window, not a layer-shell panel: Hyprland tiles it with
  // everything else, it takes focus the way any other window does, and the
  // rest of the desktop stays usable while it is open. The window is sized in
  // cells at first, then the board takes its cell size back from whatever the
  // window ends up being, so tiling it larger enlarges the board rather than
  // stranding it in a corner.

  readonly property int preferredCell: Style.space(30)
  readonly property int frameInsetW: root.contentMargin * 2
  readonly property int frameInsetH: root.contentMargin * 2 + root.chromeHeight
  readonly property int minChromeWidth: Math.max(
    title.implicitWidth + controls.implicitWidth + Style.spacing.xxl,
    statusSegments.implicitWidth + Style.spacing.xl)

  FloatingWindow {
    id: win
    visible: root.opened
    title: "omasweeper"
    color: root.background

    implicitWidth: Math.max((root.cols + 1) * root.preferredCell, root.minChromeWidth)
                   + root.frameInsetW
    implicitHeight: (root.rows + 1) * root.preferredCell + root.frameInsetH
    minimumSize: Qt.size(Math.max((root.cols + 1) * Style.space(13), root.minChromeWidth)
                         + root.frameInsetW,
                         (root.rows + 1) * Style.space(13) + root.frameInsetH)

    // Closing the window from the compositor is closing the game: the host
    // still thinks the panel is open otherwise, and the next toggle would do
    // nothing.
    onClosed: root.close()

    Item {
      id: keyCatcher
      anchors.fill: parent
      anchors.margins: root.contentMargin
      focus: true

      Keys.onPressed: function(event) {
        if (root.handleKey(event.key,
                           (event.modifiers & Qt.ShiftModifier) !== 0,
                           (event.modifiers & Qt.ControlModifier) !== 0))
          event.accepted = true
      }

      // ------------------------------------------------------------- header
      Item {
        id: header
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: Math.max(title.implicitHeight, controls.implicitHeight)

        Row {
          id: title
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.spacing.sm

          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(2, Math.round(Style.font.title * 0.25))
            height: Math.round(Style.font.title * 1.1)
            color: root.accent
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "omasweeper"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.cols + "×" + root.rows + "/" + root.mineCount
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Row {
          id: controls
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.spacing.xs

          Repeater {
            model: root.levels
            delegate: TermTab {
              required property var modelData
              required property int index
              label: modelData.key
              active: root.level === index
              onActivated: root.setLevel(index)
            }
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "│"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }
          TermTab {
            label: "new"
            onActivated: root.newGame()
          }
          TermTab {
            label: "snd"
            active: root.sound
            onActivated: {
              root.sound = !root.sound
              root.save()
              if (root.sound) root.blip("flag")
            }
          }
          TermTab {
            label: "?"
            active: root.helpOpen
            onActivated: root.helpOpen = !root.helpOpen
          }
        }
      }

      Rectangle {
        id: sepTop
        anchors.top: header.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.topMargin: Style.spacing.md
        height: 1
        color: root.gridLine
      }

      // ---------------------------------------------------------- status bar
      Item {
        id: statusLine
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        height: Math.max(statusSegments.implicitHeight, keyHints.implicitHeight)

        // The longest hint that fits, or none. Each variant is a fixed string
        // measuring itself, so the choice cannot feed back into the width it
        // is being measured against.
        readonly property real hintRoom:
          Math.max(0, statusLine.width - statusSegments.implicitWidth - Style.spacing.xl)

        Row {
          id: statusSegments
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.spacing.md

          StatusSeg {
            label: "mines"
            value: root.pad3(root.minesLeft)
            hot: true
          }
          StatusSeg {
            label: "time"
            value: root.pad3(root.seconds)
          }
          StatusSeg {
            label: "best"
            value: root.levelStats().best > 0 ? root.pad3(root.levelStats().best) : "---"
          }
          StatusSeg {
            label: "won"
            value: root.levelStats().won + "/" + root.levelStats().played
          }
        }

        Text {
          id: keyHints
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          visible: statusLine.hintRoom >= implicitWidth
          text: "hjkl move · space open · f flag · n new · ? keys · q quit"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
        Text {
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          visible: !keyHints.visible && statusLine.hintRoom >= implicitWidth
          text: "space open · f flag · ? keys"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      Rectangle {
        id: sepBottom
        anchors.bottom: statusLine.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottomMargin: Style.spacing.md
        height: 1
        color: root.gridLine
      }

      // --------------------------------------------------------------- help
      //
      // Over the board rather than beside it: the sheet is what you are
      // looking at while it is up, and the game is not going anywhere. Drawn
      // in the same hairlines and the same two type sizes as everything else,
      // so it reads as another pane of this window and not as a dialog that
      // wandered in.

      TextMetrics {
        id: keyColumn
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        text: root.widestKey
      }

      Rectangle {
        id: helpSheet
        z: 30
        visible: root.helpOpen
        anchors.centerIn: parent
        width: Math.min(parent.width, helpBody.implicitWidth + Style.spacing.xl * 2)
        height: Math.min(parent.height, helpBody.implicitHeight + Style.spacing.lg * 2)
        color: Qt.rgba(root.background.r, root.background.g, root.background.b, 0.97)
        border.width: 1
        border.color: root.accent

        // Nothing behind the sheet is clickable while it is up, and clicking
        // it puts it away, the same gesture as clicking the verdict card.
        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          onClicked: root.helpOpen = false
        }

        Column {
          id: helpBody
          anchors.centerIn: parent
          spacing: Style.spacing.md

          Item {
            width: helpTitle.implicitWidth + Style.spacing.xxl + helpDismiss.implicitWidth
            height: helpTitle.implicitHeight

            Text {
              id: helpTitle
              anchors.left: parent.left
              text: "keys"
              color: root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
            }
            Text {
              id: helpDismiss
              anchors.right: parent.right
              anchors.baseline: helpTitle.baseline
              text: "? or esc to close"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Rectangle {
            width: parent.width
            height: 1
            color: root.gridLine
          }

          Repeater {
            model: root.keymap
            delegate: Column {
              required property var modelData
              spacing: Style.spacing.xxs
              topPadding: Style.spacing.xs

              Text {
                text: modelData.group
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Repeater {
                model: modelData.keys
                delegate: Row {
                  required property var modelData
                  spacing: Style.spacing.md

                  Text {
                    width: keyColumn.width
                    horizontalAlignment: Text.AlignRight
                    text: modelData.key
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    text: modelData.what
                    color: root.foreground
                    opacity: 0.7
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }
                }
              }
            }
          }
        }
      }

      // -------------------------------------------------------------- board
      Item {
        id: boardSlot
        anchors.top: sepTop.bottom
        anchors.bottom: sepBottom.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.topMargin: Style.spacing.md
        anchors.bottomMargin: Style.spacing.md

        Item {
          id: boardArea
          anchors.centerIn: parent
          width: root.boardW
          height: root.boardH

          // Column and row labels, lit for whichever line the pointer or the
          // cursor is on. That is the whole reason they are here: on an expert
          // board, finding the cell you are about to click is otherwise a count.
          Repeater {
            model: root.cols
            delegate: Text {
              required property int index
              x: root.gutter + index * root.cellSize
              y: 0
              width: root.cellSize
              height: root.gutter
              horizontalAlignment: Text.AlignHCenter
              verticalAlignment: Text.AlignVCenter
              text: root.label36(index)
              color: root.activeCol === index ? root.accent : root.dim
              font.family: root.fontFamily
              font.pixelSize: root.labelFont
            }
          }
          Repeater {
            model: root.rows
            delegate: Text {
              required property int index
              x: 0
              y: root.gutter + index * root.cellSize
              width: root.gutter
              height: root.cellSize
              horizontalAlignment: Text.AlignHCenter
              verticalAlignment: Text.AlignVCenter
              text: root.label36(index)
              color: root.activeRow === index ? root.accent : root.dim
              font.family: root.fontFamily
              font.pixelSize: root.labelFont
            }
          }

          Rectangle {
            id: grid
            x: root.gutter
            y: root.gutter
            width: root.gridW
            height: root.gridH
            color: root.boardBg

            // The rule lines. Drawn once across the board rather than as a
            // border on every cell, so a cell is a fill and a character and
            // nothing else.
            Repeater {
              model: root.cols + 1
              delegate: Rectangle {
                required property int index
                x: Math.min(index * root.cellSize, root.gridW - 1)
                width: 1
                height: root.gridH
                color: root.gridLine
                z: 5
              }
            }
            Repeater {
              model: root.rows + 1
              delegate: Rectangle {
                required property int index
                y: Math.min(index * root.cellSize, root.gridH - 1)
                width: root.gridW
                height: 1
                color: root.gridLine
                z: 5
              }
            }

            Repeater {
              model: root.cellCount
              delegate: Item {
                id: cell

                required property int index
                readonly property bool isShown: root.shown[cell.index] === true
                readonly property bool isFlag: root.flag[cell.index] === true
                readonly property bool isMine: root.mine[cell.index] === true
                readonly property int n: root.adj[cell.index] || 0
                readonly property bool wrongFlag: root.dead && cell.isFlag && !cell.isMine
                readonly property bool onCursor: root.cursorShown && root.cursor === cell.index

                // What the cell reads as: a covered cell is a dot, an opened
                // one is its count or nothing at all, and the end of the game
                // turns every mine into an asterisk.
                readonly property string glyph: {
                  if (cell.wrongFlag) return "x"
                  if (cell.isFlag) return "⚑"
                  if (!cell.isShown) return "·"
                  if (cell.isMine) return ""            // drawn below, not typed
                  return cell.n > 0 ? String(cell.n) : ""
                }
                readonly property color glyphColor: {
                  if (cell.wrongFlag) return root.urgent
                  if (cell.isFlag) return root.urgent
                  if (!cell.isShown) return cell.onCursor ? root.accent : root.coverDot
                  if (cell.isMine) return cell.index === root.boom ? root.foreground : root.dim
                  return root.numberColors[Math.max(0, Math.min(7, cell.n - 1))]
                }

                x: (cell.index % root.cols) * root.cellSize
                y: Math.floor(cell.index / root.cols) * root.cellSize
                width: root.cellSize
                height: root.cellSize

                Rectangle {
                  anchors.fill: parent
                  anchors.margins: 1
                  color: {
                    if (cell.index === root.boom) return root.mix(root.background, root.urgent, 0.6)
                    if (cell.onCursor) return root.mix(root.background, root.accent, 0.28)
                    if (root.pressIndex === cell.index) return root.pressFill
                    if (root.hoverIndex === cell.index && !root.finished) return root.hoverFill
                    return cell.isShown ? "transparent" : root.coverFill
                  }
                  Behavior on color { ColorAnimation { duration: 70 } }
                }

                MineMark {
                  anchors.centerIn: parent
                  width: Math.round(root.cellSize * 0.46)
                  height: width
                  visible: cell.isShown && cell.isMine
                  tint: cell.index === root.boom ? root.foreground : root.dim
                }

                Text {
                  anchors.centerIn: parent
                  text: cell.glyph
                  color: cell.glyphColor
                  font.family: root.fontFamily
                  font.pixelSize: root.cellFont
                  font.bold: cell.isShown && !cell.isMine
                }
              }
            }

            // One MouseArea for the whole grid rather than one per cell: an
            // expert board is 480 cells, and the cell under the pointer is a
            // division away. It also puts every button in one place, which is
            // what makes chording on middle-click a two-line affair.
            MouseArea {
              anchors.fill: parent
              // Dead while the help sheet is up, hover included: a move made
              // by a pointer that is only on its way to the sheet is a move
              // you did not mean. Dead until the saved game is back, for the
              // same reason handleKey is.
              enabled: root.stateLoaded && !root.helpOpen
              hoverEnabled: root.stateLoaded && !root.helpOpen
              acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
              cursorShape: root.finished ? Qt.ArrowCursor : Qt.PointingHandCursor
              z: 10

              function cellAt(x, y) {
                if (x < 0 || y < 0 || x >= root.gridW || y >= root.gridH) return -1
                var c = Math.floor(x / root.cellSize)
                var r = Math.floor(y / root.cellSize)
                if (c < 0 || c >= root.cols || r < 0 || r >= root.rows) return -1
                return c + r * root.cols
              }

              onPositionChanged: function(mouse) {
                root.hoverIndex = cellAt(mouse.x, mouse.y)
                root.cursorShown = false
                if (root.pressIndex >= 0 && root.pressIndex !== root.hoverIndex)
                  root.pressIndex = -1
              }
              onExited: {
                root.hoverIndex = -1
                root.pressIndex = -1
              }
              onPressed: function(mouse) {
                var i = cellAt(mouse.x, mouse.y)
                if (mouse.button === Qt.LeftButton && !root.finished
                    && root.shown[i] !== true && root.flag[i] !== true)
                  root.pressIndex = i
              }
              onReleased: function(mouse) { root.pressIndex = -1 }
              onCanceled: root.pressIndex = -1
              onClicked: function(mouse) {
                var i = cellAt(mouse.x, mouse.y)
                if (i < 0) return
                if (mouse.button === Qt.RightButton) root.toggleFlag(i)
                else if (mouse.button === Qt.MiddleButton) root.chordAt(i)
                else root.primaryAt(i)
              }
            }

            // ------------------------------------------------------- verdict
            // Not a dialog: a line of output over the board, with a caret
            // still blinking after it.
            Rectangle {
              visible: root.finished
              z: 20
              anchors.centerIn: parent
              width: verdict.implicitWidth + Style.spacing.xl * 2
              height: verdict.implicitHeight + Style.spacing.md * 2
              color: Qt.rgba(root.background.r, root.background.g, root.background.b, 0.96)
              border.width: 1
              border.color: root.won ? root.accent : root.urgent

              Row {
                id: verdict
                anchors.centerIn: parent
                spacing: Style.spacing.sm

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.won ? "swept." : "boom."
                  color: root.won ? root.accent : root.urgent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                }
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.won
                    ? (root.levelSpec.key + " in " + root.pad3(root.seconds) + "s"
                       + (root.newBest ? " · new best" : ""))
                    : ("opened " + root.shownCount + "/" + (root.cellCount - root.mineCount))
                  color: root.foreground
                  opacity: 0.75
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "[enter] again"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
                Rectangle {
                  anchors.verticalCenter: parent.verticalCenter
                  width: Math.max(3, Math.round(Style.font.body * 0.55))
                  height: Math.round(Style.font.body * 1.1)
                  color: root.accent
                  opacity: root.caretOn ? 1 : 0
                }
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.newGame()
              }
            }
          }
        }
      }
    }
  }
}
