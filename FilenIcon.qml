import QtQuick
import qs.Commons

// The Filen mark drawn natively — a rounded square with the stylised "f"
// cutout, plus an optional state dot. Drawn rather than shipped as an image
// so it inherits the theme foreground and stays crisp at any bar size, the
// same approach the first-party Tailscale/Dropbox icons take.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground
  property color badgeColor: Color.urgent
  property bool warning: false
  property bool busy: false

  implicitWidth: iconSize
  implicitHeight: iconSize

  Canvas {
    id: canvas
    anchors.fill: parent
    antialiasing: true

    // Repaint whenever anything visual changes — Canvas does not track
    // property bindings on its own.
    Connections {
      target: root
      function onColorChanged() { canvas.requestPaint() }
      function onIconSizeChanged() { canvas.requestPaint() }
    }

    onPaint: {
      var ctx = getContext("2d")
      var w = width, h = height
      ctx.reset()
      ctx.clearRect(0, 0, w, h)

      var s = Math.min(w, h)
      var pad = s * 0.06
      var box = s - pad * 2
      var r = box * 0.22

      // Rounded square outline
      ctx.strokeStyle = root.color
      ctx.lineWidth = Math.max(1, s * 0.085)
      ctx.beginPath()
      ctx.moveTo(pad + r, pad)
      ctx.lineTo(pad + box - r, pad)
      ctx.quadraticCurveTo(pad + box, pad, pad + box, pad + r)
      ctx.lineTo(pad + box, pad + box - r)
      ctx.quadraticCurveTo(pad + box, pad + box, pad + box - r, pad + box)
      ctx.lineTo(pad + r, pad + box)
      ctx.quadraticCurveTo(pad, pad + box, pad, pad + box - r)
      ctx.lineTo(pad, pad + r)
      ctx.quadraticCurveTo(pad, pad, pad + r, pad)
      ctx.closePath()
      ctx.stroke()

      // The "f": vertical stem with a hook at the top and a crossbar.
      var cx = pad + box * 0.52
      var top = pad + box * 0.27
      var bot = pad + box * 0.75
      ctx.lineWidth = Math.max(1, s * 0.085)
      ctx.lineCap = "round"

      ctx.beginPath()
      // hook
      ctx.moveTo(cx + box * 0.14, top)
      ctx.quadraticCurveTo(cx - box * 0.06, top - box * 0.02, cx - box * 0.06, top + box * 0.14)
      // stem
      ctx.lineTo(cx - box * 0.06, bot)
      ctx.stroke()

      // crossbar
      ctx.beginPath()
      ctx.moveTo(cx - box * 0.20, pad + box * 0.47)
      ctx.lineTo(cx + box * 0.14, pad + box * 0.47)
      ctx.stroke()
    }
  }

  // Attention dot, same visual language as the passpage plugin's badge.
  Rectangle {
    visible: root.warning
    width: Math.max(5, root.iconSize * 0.34)
    height: width
    radius: width / 2
    color: root.badgeColor
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.rightMargin: -width * 0.18
    anchors.bottomMargin: -width * 0.06
  }
}
