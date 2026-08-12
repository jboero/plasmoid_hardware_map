/*
 * A small rotor drawn with Canvas.
 *
 * Breeze ships no fan icon at any size, and the nearest stand-ins ("sensors",
 * "weather-windy") read as something else entirely. Drawing it keeps the shape
 * recognisable at the ~14px a connector rectangle allows, where a detailed
 * icon would turn to mush anyway.
 *
 * Rotation is opt-in via `spinning`. A permanently animating glyph in a status
 * panel pulls the eye away from whatever is actually wrong, which is the same
 * mistake the pulsing tray icon made.
 */
import QtQuick

Item {
    id: glyph

    property real size: 16
    property color color: "white"
    /** Measured RPM; only used to pick a plausible rotation period. */
    property real rpm: 0
    property bool spinning: false

    implicitWidth: size
    implicitHeight: size
    width: size
    height: size

    Canvas {
        id: canvas
        anchors.fill: parent
        rotation: 0
        antialiasing: true

        onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            var w = width, h = height
            var cx = w / 2, cy = h / 2
            var r = Math.min(w, h) / 2

            ctx.strokeStyle = glyph.color
            ctx.fillStyle = glyph.color
            ctx.lineWidth = Math.max(1, r * 0.13)
            ctx.lineCap = "round"

            // Three blades, each a teardrop swept from the hub. Three rather
            // than four so the shape stays asymmetric and reads as rotating
            // even when still.
            for (var i = 0; i < 3; ++i) {
                var a = (i * 2 * Math.PI / 3) - Math.PI / 2
                ctx.beginPath()
                ctx.moveTo(cx, cy)
                ctx.quadraticCurveTo(
                    cx + Math.cos(a - 0.55) * r * 1.02,
                    cy + Math.sin(a - 0.55) * r * 1.02,
                    cx + Math.cos(a + 0.30) * r * 0.86,
                    cy + Math.sin(a + 0.30) * r * 0.86)
                ctx.quadraticCurveTo(
                    cx + Math.cos(a + 0.20) * r * 0.42,
                    cy + Math.sin(a + 0.20) * r * 0.42,
                    cx, cy)
                ctx.fill()
            }

            // Hub, punched out so the blades stay legible when tiny.
            ctx.beginPath()
            ctx.arc(cx, cy, r * 0.22, 0, 2 * Math.PI)
            ctx.fillStyle = glyph.color
            ctx.fill()
        }

        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()

        RotationAnimator {
            target: canvas
            running: glyph.spinning
            from: 0
            to: 360
            // Real fan RPM would be a blur; this is a legible stand-in that
            // still moves faster for a faster fan. Clamped so a stopped or
            // absurd reading cannot produce a frozen or strobing glyph.
            duration: Math.max(600, Math.min(4000, 900000 / Math.max(200, glyph.rpm)))
            loops: Animation.Infinite
        }
    }

    onColorChanged: canvas.requestPaint()
}
