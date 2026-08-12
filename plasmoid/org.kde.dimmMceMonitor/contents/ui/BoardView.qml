/*
 * Renders board components either over a picture of the board (when a profile
 * supplies one) or as an auto-generated list grouped by kind.
 *
 * The list path needs no configuration and works on any machine, because the
 * component inventory is always discoverable. Only the *picture* needs a
 * per-board profile, since physical geometry appears nowhere in SMBIOS.
 */
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami

Item {
    id: board

    property var components: []
    property var profile: null
    /** SMBIOS type-17 rows, keyed by silkscreen locator. See tip.dmiModule. */
    property var dmiSlots: []

    // Hover state only. There is deliberately no persistent selection: a
    // component left highlighted after the pointer moved away reads as "this
    // one is special", which on a fault display is actively misleading.
    property string hoveredKey: ""

    // Pointer position in this item's coordinates, for placing the tooltip.
    property point hoverPos: Qt.point(0, 0)

    // Belt and braces: if the board is hidden while something is hovered, no
    // onExited ever arrives and the highlight would still be there next time.
    onVisibleChanged: if (!visible) hoveredKey = ""

    readonly property bool haveImage:
        profile && profile.image && Plasmoid.configuration.showBoardImage

    // Profiles may key on a component's id OR any of its aliases. Aliases exist
    // because ids like an interface name or PCI address MOVE - a BIOS change
    // renumbered this machine's bus and turned enp12s0 into enp6s0, silently
    // unmapping it from the picture. `net:dev:<vendor>:<device>` survives that
    // and is portable to another machine with the same board.
    function byId(id) {
        for (var i = 0; i < components.length; ++i) {
            var c = components[i]
            if (c.id === id) return c
            var a = c.aliases
            if (a) for (var j = 0; j < a.length; ++j)
                if (a[j] === id) return c
        }
        return null
    }

    // Status colours are categories, not a gradient: they map to decisions
    // (ignore / watch / act), not to magnitudes.
    function heatColor(c) {
        if (!c) return Qt.rgba(0.5, 0.5, 0.5, 0.20)          // not detected
        switch (c.status) {
        case "error": return Qt.rgba(0.85, 0.10, 0.15, 0.66)
        case "warn":  return Qt.rgba(0.95, 0.55, 0.10, 0.58)
        case "empty": return Qt.rgba(0.45, 0.45, 0.50, 0.30)
        case "unknown": return Qt.rgba(0.30, 0.45, 0.85, 0.35)
        default:      return Qt.rgba(0.35, 0.75, 0.40, 0.34)
        }
    }

    function borderColor(c) {
        if (!c) return Kirigami.Theme.disabledTextColor
        switch (c.status) {
        case "error": return Kirigami.Theme.negativeTextColor
        case "warn":  return Kirigami.Theme.neutralTextColor
        case "empty": return Kirigami.Theme.disabledTextColor
        case "unknown": return Kirigami.Theme.highlightColor
        default:      return Kirigami.Theme.positiveTextColor
        }
    }

    // Fans are the one kind that is often NOT a board component - chassis and
    // memory fans sit elsewhere in the case and only their headers are on the
    // PCB. Drawn in blue with a rotor glyph so they read as "cooling", not as
    // one more anonymous connector. Status still wins: a failed fan must not be
    // calm blue, so the tint only applies while the fan is healthy.
    readonly property color fanTint: Qt.rgba(0.25, 0.55, 0.95, 0.38)
    readonly property color fanEdge: Qt.rgba(0.35, 0.65, 1.0, 1.0)

    function isFan(c) { return !!c && c.kind === "fan" }

    /** Numeric value of a named metric, or 0. Metrics are label/value pairs. */
    function metricNumber(c, label) {
        if (!c || !c.metrics) return 0
        for (var i = 0; i < c.metrics.length; ++i)
            if (c.metrics[i].label === label) {
                var v = parseFloat(c.metrics[i].value)
                return isNaN(v) ? 0 : v
            }
        return 0
    }

    function heatColorFor(c) {
        return (isFan(c) && (c.status === "ok" || c.status === "empty"))
               ? board.fanTint : board.heatColor(c)
    }

    function borderColorFor(c) {
        return (isFan(c) && (c.status === "ok" || c.status === "empty"))
               ? board.fanEdge : board.borderColor(c)
    }

    // ------------------------------------------------------------ image mode
    Item {
        anchors.fill: parent
        visible: board.haveImage

        // Picture and overlay must share one coordinate system, so both live
        // inside this letterboxed frame sized to the image aspect.
        Item {
            id: frame
            anchors.centerIn: parent
            readonly property real aspect: {
                if (profile && profile.imageSize && profile.imageSize.length === 2
                    && profile.imageSize[1] > 0)
                    return profile.imageSize[0] / profile.imageSize[1]
                return boardImage.implicitHeight > 0
                     ? boardImage.implicitWidth / boardImage.implicitHeight : 1.25
            }
            width: Math.min(parent.width, parent.height * aspect)
            height: width / aspect

            Image {
                id: boardImage
                anchors.fill: parent
                source: profile && profile.image ? profile.image : ""
                fillMode: Image.PreserveAspectFit
                opacity: Plasmoid.configuration.imageOpacity
                smooth: true
                asynchronous: true
            }

            // Carrier cards, drawn above the slot rectangles so their bays are
            // never occluded by a neighbouring slot's fill.
            Repeater {
                model: profile && profile.slots ? Object.keys(profile.slots) : []

                delegate: SlotCard {
                    required property string modelData
                    readonly property var spec: profile.slots[modelData]
                    readonly property var comp: board.byId(modelData)

                    anchors.fill: parent
                    z: 5
                    view: board
                    drives: comp && comp.drives ? comp.drives : []
                    hoveredKey: board.hoveredKey
                    extend: (profile && profile.cardExtends) || "right"
                    slotRect: Qt.rect(spec.rect[0] * frame.width,
                                      spec.rect[1] * frame.height,
                                      spec.rect[2] * frame.width,
                                      spec.rect[3] * frame.height)
                    onBayEntered: function (id, pos) {
                        board.hoveredKey = id
                        board.hoverPos = pos
                    }
                    onBayExited: function (id) {
                        if (board.hoveredKey === id) board.hoveredKey = ""
                    }
                }
            }

            Repeater {
                model: profile && profile.slots ? Object.keys(profile.slots) : []

                delegate: Rectangle {
                    required property string modelData
                    readonly property var spec: profile.slots[modelData]
                    readonly property var comp: board.byId(modelData)
                    readonly property bool sel: board.hoveredKey === modelData

                    x: spec.rect[0] * frame.width
                    y: spec.rect[1] * frame.height
                    width: spec.rect[2] * frame.width
                    height: spec.rect[3] * frame.height

                    color: board.heatColorFor(comp)
                    border.color: sel ? Kirigami.Theme.highlightColor
                                      : board.borderColorFor(comp)
                    border.width: sel ? 3 : 2
                    radius: board.isFan(comp) ? Math.min(width, height) / 2 : 2

                    // A component the profile places but the machine does not
                    // report is drawn hollow, so "not detected" never reads as
                    // "healthy".
                    Rectangle {
                        anchors.fill: parent
                        visible: !comp
                        color: "transparent"
                        border.color: Kirigami.Theme.disabledTextColor
                        border.width: 1
                        opacity: 0.6
                    }

                    FanGlyph {
                        anchors.centerIn: parent
                        visible: board.isFan(comp)
                        size: Math.min(parent.width, parent.height) * 0.78
                        color: board.borderColorFor(comp)
                        // Spinning constantly in a status panel is a
                        // distraction, so it only turns while pointed at.
                        spinning: sel
                        rpm: comp && comp.metrics ? board.metricNumber(comp, "Speed") : 0
                    }

                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        onEntered: {
                            board.hoveredKey = modelData
                            board.hoverPos = mapToItem(board, mouseX, mouseY)
                        }
                        onPositionChanged: function (mouse) {
                            board.hoverPos = mapToItem(board, mouse.x, mouse.y)
                        }
                        // Guarded: if the pointer moves straight onto the next
                        // component, that one's onEntered may run before this
                        // onExited, and an unguarded clear would wipe it.
                        onExited: if (board.hoveredKey === modelData)
                                      board.hoveredKey = ""
                    }
                }
            }
        }
    }

    // --------------------------------------------------------------- list mode
    // Grouped by kind. No board knowledge required, so this works anywhere.
    QQC2.ScrollView {
        id: listView
        anchors.fill: parent
        visible: !board.haveImage
        contentWidth: availableWidth
        clip: true

        ColumnLayout {
            width: listView.availableWidth
            spacing: Kirigami.Units.smallSpacing

            Repeater {
                model: {
                    var order = ["dimm", "cpu", "pcie", "disk", "sata", "sas",
                                 "net", "fan", "temp"]
                    var seen = {}
                    for (var i = 0; i < board.components.length; ++i)
                        seen[board.components[i].kind] = true
                    var out = []
                    for (var j = 0; j < order.length; ++j)
                        if (seen[order[j]]) out.push(order[j])
                    for (var k in seen)
                        if (order.indexOf(k) < 0) out.push(k)
                    return out
                }

                delegate: ColumnLayout {
                    id: kindGroup
                    required property string modelData
                    Layout.fillWidth: true
                    spacing: 1

                    readonly property var kindItems: board.components.filter(
                        function (c) { return c.kind === kindGroup.modelData })

                    PlasmaComponents.Label {
                        text: {
                            var names = {
                                dimm: i18n("Memory — ECC errors"),
                                cpu: i18n("Processors"), pcie: i18n("PCIe slots"),
                                disk: i18n("Drives"), sata: i18n("SATA ports"),
                                sas: i18n("SAS ports"), net: i18n("Network ports"),
                                fan: i18n("Fans — speed vs siblings"),
                                temp: i18n("Temperatures")
                            }
                            return (names[kindGroup.modelData] || kindGroup.modelData)
                                   + "  (" + kindGroup.kindItems.length + ")"
                        }
                        font.bold: true
                        opacity: 0.85
                        Layout.topMargin: Kirigami.Units.smallSpacing
                    }

                    Repeater {
                        model: kindGroup.kindItems

                        delegate: Rectangle {
                            required property var modelData
                            readonly property bool sel:
                                board.hoveredKey === modelData.id

                            Layout.fillWidth: true
                            Layout.preferredHeight: Kirigami.Units.gridUnit * 1.6
                            radius: 3
                            color: board.heatColorFor(modelData)
                            border.color: sel ? Kirigami.Theme.highlightColor
                                              : board.borderColorFor(modelData)
                            border.width: sel ? 2 : 1

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: Kirigami.Units.smallSpacing
                                anchors.rightMargin: Kirigami.Units.smallSpacing
                                spacing: Kirigami.Units.smallSpacing

                                FanGlyph {
                                    visible: board.isFan(modelData)
                                    size: Kirigami.Units.iconSizes.small
                                    color: board.borderColorFor(modelData)
                                    spinning: sel
                                    rpm: board.metricNumber(modelData, "Speed")
                                    Layout.preferredWidth: visible ? size : 0
                                    Layout.preferredHeight: size
                                }

                                PlasmaComponents.Label {
                                    text: modelData.label
                                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                                    elide: Text.ElideRight
                                    Layout.preferredWidth: parent.width * 0.45
                                }
                                PlasmaComponents.Label {
                                    text: modelData.headline
                                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                                    font.bold: modelData.status === "error"
                                               || modelData.status === "warn"
                                    horizontalAlignment: Text.AlignRight
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                hoverEnabled: true
                                onEntered: {
                                    board.hoveredKey = modelData.id
                                    board.hoverPos = mapToItem(board, mouseX, mouseY)
                                }
                                onPositionChanged: function (mouse) {
                                    board.hoverPos = mapToItem(board, mouse.x, mouse.y)
                                }
                                onExited: if (board.hoveredKey === modelData.id)
                                              board.hoveredKey = ""
                            }
                        }
                    }
                }
            }
        }
    }

    // ----------------------------------------------------------------- tooltip
    //
    // Floats above everything and is NOT part of any layout. That is the whole
    // point: an inline details panel grows when its content is taller, which
    // shrinks the board, which slides the component out from under a stationary
    // cursor - so it un-hovers, the panel collapses, and it flickers forever.
    // Nothing here can resize the board.
    //
    // It carries no MouseArea, so it never steals the hover it is describing,
    // and it is nudged away from the pointer and clamped inside the view.
    Item {
        id: tip
        visible: hoveredComp !== null
        z: 999

        readonly property var hoveredComp: board.hoveredKey
                                           ? board.byId(board.hoveredKey) : null
        readonly property var spec: (board.profile && board.profile.slots)
                                    ? board.profile.slots[board.hoveredKey] : null

        /*
         * Module identity for a memory slot, joined in at display time.
         *
         * The collector cannot do this join: it knows EDAC keys, and SMBIOS
         * knows silkscreen locators, and NOTHING in firmware connects the two.
         * The board profile is the only place that mapping exists, and only the
         * widget has both halves. Any profile that labels its DIMM rectangles
         * with the DMI locator gets part and serial for free, on any board.
         *
         * Consequence worth respecting: the serial is only as trustworthy as
         * that mapping. On a `derived` profile it is an inference, so it is
         * labelled as one rather than presented as fact.
         */
        readonly property var dmiModule: {
            if (!hoveredComp || hoveredComp.kind !== "dimm") return null
            if (!spec || !spec.label) return null
            var rows = board.dmiSlots || []
            for (var i = 0; i < rows.length; ++i)
                if (rows[i].locator === spec.label) return rows[i]
            return null
        }

        readonly property var extraMetrics: {
            var m = []
            var d = dmiModule
            if (!d) return m
            if (d.manufacturer) m.push({label: "Manufacturer", value: d.manufacturer, unit: ""})
            if (d.part) m.push({label: "Part number", value: d.part, unit: ""})
            var inferred = board.profile && board.profile.confidence === "derived"
            m.push({label: inferred ? "Serial (via inferred slot mapping)" : "Serial",
                    value: d.serial || "unknown", unit: ""})
            if (d.rank) m.push({label: "Ranks", value: d.rank, unit: ""})
            return m
        }

        readonly property int pad: Kirigami.Units.smallSpacing
        readonly property int offset: Kirigami.Units.gridUnit

        // Widest the tooltip may get. Sizing used to run bg.width -> col.width
        // -> col.implicitWidth -> bg.width, a loop Qt breaks by leaving the
        // column at its full unwrapped width - so wrapMode never engaged and
        // long text painted straight through the border. Flow is now strictly
        // one-way: content -> column (capped here) -> background.
        readonly property real maxWidth:
            Math.max(Kirigami.Units.gridUnit * 14,
                     Math.min(board.width * 0.72, Kirigami.Units.gridUnit * 30))

        width: bg.width
        height: bg.height

        // Prefer below-right of the cursor; flip when that would overflow.
        x: {
            var wanted = board.hoverPos.x + offset
            if (wanted + width > board.width)
                wanted = board.hoverPos.x - width - offset
            return Math.max(0, Math.min(wanted, board.width - width))
        }
        y: {
            var wanted = board.hoverPos.y + offset
            if (wanted + height > board.height)
                wanted = board.hoverPos.y - height - offset
            return Math.max(0, Math.min(wanted, board.height - height))
        }

        Rectangle {
            id: bg
            width: col.width + tip.pad * 2
            height: col.implicitHeight + tip.pad * 2
            radius: 4
            color: Kirigami.Theme.backgroundColor
            opacity: 0.97
            border.width: 1
            border.color: tip.hoveredComp
                          ? board.borderColor(tip.hoveredComp)
                          : Kirigami.Theme.disabledTextColor

            ColumnLayout {
                id: col
                x: tip.pad
                y: tip.pad
                // implicitWidth of a wrapping Label is its longest unwrapped
                // line and does NOT depend on the width assigned to it, so
                // this reads content size without re-entering the binding.
                width: Math.min(implicitWidth, tip.maxWidth - tip.pad * 2)
                spacing: 1

                PlasmaComponents.Label {
                    Layout.fillWidth: true
                    font.bold: true
                    wrapMode: Text.WordWrap
                    text: {
                        var c = tip.hoveredComp
                        if (!c) return ""
                        // The silkscreen name is what you read off the board.
                        return (tip.spec && tip.spec.label)
                               ? tip.spec.label + "  —  " + c.label : c.label
                    }
                }

                PlasmaComponents.Label {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    font.bold: true
                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                    color: {
                        var c = tip.hoveredComp
                        if (!c) return Kirigami.Theme.textColor
                        if (c.status === "error") return Kirigami.Theme.negativeTextColor
                        if (c.status === "warn") return Kirigami.Theme.neutralTextColor
                        if (c.status === "empty") return Kirigami.Theme.disabledTextColor
                        return Kirigami.Theme.positiveTextColor
                    }
                    text: tip.hoveredComp ? tip.hoveredComp.headline : ""
                }

                // Every metric is spelled out. A bare number on a hardware
                // display is useless if you do not already know what it counts.
                Repeater {
                    model: {
                        var c = tip.hoveredComp
                        if (!c) return []
                        var all = (c.metrics || []).concat(tip.extraMetrics)
                        return all.filter(function (m) {
                            return String(m.value) !== String(c.headline)
                        })
                    }
                    delegate: RowLayout {
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: Kirigami.Units.largeSpacing
                        PlasmaComponents.Label {
                            text: modelData.label
                            font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                            opacity: 0.8
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                            Layout.minimumWidth: 0
                            Layout.maximumWidth: col.width * 0.5
                        }
                        PlasmaComponents.Label {
                            text: modelData.value + (modelData.unit
                                  ? " " + modelData.unit : "")
                            font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                            font.bold: true
                            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                            horizontalAlignment: Text.AlignRight
                            Layout.fillWidth: true
                            Layout.minimumWidth: 0
                        }
                    }
                }

                PlasmaComponents.Label {
                    Layout.fillWidth: true
                    visible: tip.hoveredComp && tip.hoveredComp.note
                    wrapMode: Text.WordWrap
                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                    color: Kirigami.Theme.neutralTextColor
                    text: (tip.hoveredComp && tip.hoveredComp.note)
                          ? tip.hoveredComp.note : ""
                }
            }
        }
    }
}
