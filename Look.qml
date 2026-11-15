import QtQuick
import qs.Commons as Commons

// The dock's surface recipe, taken from the desktop widgets (WidgetCard.qml)
// and bound to the live theme, so a theme switch restyles the dock at once.
// Widgets hard-code these values; each one is mapped to its nearest token.
QtObject {
  function tone(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  // Card: background, much more see-through than the widgets (about 50
  // percent, `cardOpacity`), with the widgets' 1 px muted border at 80 percent.
  property real cardOpacity: 0.5
  readonly property color card: tone(Commons.Color.background, cardOpacity)
  readonly property color cardBorder: tone(Commons.Color.muted, 0.80)
  // Resting tile: foreground at about 6 percent over the card.
  readonly property color tile: tone(Commons.Color.foreground, 0.06)
  // Hover highlight: the widgets' active row, accent at 10 percent.
  readonly property color highlight: tone(Commons.Color.accent, 0.10)
  // Widgets use hairlines at 60 percent of the muted border.
  readonly property color separator: tone(Commons.Color.muted, 0.60)
  // The widgets' dark_foreground has no shell token: foreground, dimmed.
  readonly property color dim: tone(Commons.Color.foreground, 0.55)
  readonly property color accent: Commons.Color.accent
  readonly property color urgent: Commons.Color.urgent
  readonly property color foreground: Commons.Color.foreground
}
