import QtQuick
import qs.Commons
import qs.Ui

// Bar icon for the Omasweeper board. Clicking runs the exact same IPC route a
// keybinding would use (omarchy-shell shell toggle …), mirroring how the
// first-party omarchy.menu bar widget summons its panel. Static icon only —
// nothing runs while the board is closed.
BarWidget {
  id: root
  moduleName: "jankeesvw.omasweeper"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "⚑"
    tooltipText: "Omasweeper"
    foreground: Color.accent
    fixedWidth: root.bar && root.bar.vertical ? -1 : Style.space(27)
    fixedHeight: root.bar && root.bar.vertical ? Style.space(26) : -1
    onPressed: function(b) {
      if (!root.bar) return
      root.bar.run("omarchy-shell shell toggle jankeesvw.omasweeper")
    }
  }
}
