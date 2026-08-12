/*
 * The card sticking out of a PCIe slot, with one bay per drive it carries.
 *
 * Why not a count badge: a badge tells you "2" and stops. Drives on a carrier
 * card are exactly the components a board picture cannot place - they are not
 * on the board - so the honest thing is to draw them where they physically
 * are, which is *on a card, extending out of the slot*. That is discoverable
 * at a glance, keeps per-drive status visible instead of collapsing it to a
 * total, and gives the pointer something to land on so a single sick drive can
 * be identified without hovering the slot and reading a list.
 *
 * The card is drawn deliberately faint and outside the slot rectangle, so it
 * never competes with real board components or implies the drives are soldered
 * to the motherboard.
 *
 * Direction: cards extend away from the rear I/O bracket. `extend` lets a
 * profile say which way that is for its picture; the default suits the common
 * case of a board photographed with its I/O edge on the left.
 */
import QtQuick
import org.kde.kirigami as Kirigami

Item {
    id: card

    /**
     * The BoardView. Passed explicitly because this component's parent is the
     * letterboxed image frame, not the view, so it cannot reach the shared
     * status-colour functions or the tooltip's coordinate space by scope.
     */
    property var view: null

    /** Slot rectangle this card plugs into, in parent coordinates. */
    property rect slotRect: Qt.rect(0, 0, 0, 0)
    /** Structured drive list from the pcie component. */
    property var drives: []
    /** "right" or "left". */
    property string extend: "right"
    /** Set by the parent so hovering a bay reports through the usual path. */
    property string hoveredKey: ""

    signal bayEntered(string id, point pos)
    signal bayExited(string id)

    readonly property int count: drives ? drives.length : 0
    readonly property real bayH: Math.max(3, slotRect.height * 0.80)
    readonly property real bayW: Math.max(5, slotRect.height * 1.55)
    readonly property real gap: Math.max(1, slotRect.height * 0.18)
    readonly property real stemLen: Math.max(3, slotRect.height * 0.7)

    visible: count > 0

    // Thin stem from the slot edge to the first bay, so the card reads as
    // plugged in rather than floating next to the slot.
    Rectangle {
        visible: card.count > 0
        height: Math.max(1, card.slotRect.height * 0.16)
        width: card.stemLen
        y: card.slotRect.y + card.slotRect.height / 2 - height / 2
        x: card.extend === "left"
           ? card.slotRect.x - card.stemLen
           : card.slotRect.x + card.slotRect.width
        color: Kirigami.Theme.disabledTextColor
        opacity: 0.55
    }

    Repeater {
        model: card.drives

        delegate: Rectangle {
            required property var modelData
            required property int index

            readonly property bool sel: card.hoveredKey === modelData.id

            width: card.bayW
            height: card.bayH
            radius: 2
            y: card.slotRect.y + card.slotRect.height / 2 - height / 2
            x: {
                var run = index * (card.bayW + card.gap)
                return card.extend === "left"
                    ? card.slotRect.x - card.stemLen - card.bayW - run
                    : card.slotRect.x + card.slotRect.width + card.stemLen + run
            }

            color: card.view ? card.view.heatColor({status: modelData.status})
                             : "transparent"
            border.width: sel ? 2 : 1
            border.color: sel ? Kirigami.Theme.highlightColor
                              : (card.view
                                 ? card.view.borderColor({status: modelData.status})
                                 : Kirigami.Theme.disabledTextColor)
            // Faint until pointed at: this is context, not a board component.
            opacity: sel ? 1.0 : 0.72

            // Platter/chip hint - two stacked lines. Enough to read as storage
            // at this size without pretending to be an icon.
            Column {
                anchors.centerIn: parent
                spacing: Math.max(1, parent.height * 0.14)
                Repeater {
                    model: 2
                    Rectangle {
                        width: card.bayW * 0.52
                        height: Math.max(1, card.bayH * 0.13)
                        radius: height / 2
                        color: Kirigami.Theme.textColor
                        opacity: 0.45
                    }
                }
            }

            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                onEntered: card.bayEntered(modelData.id,
                                           mapToItem(card.view, mouseX, mouseY))
                onPositionChanged: function (mouse) {
                    card.bayEntered(modelData.id,
                                    mapToItem(card.view, mouse.x, mouse.y))
                }
                onExited: card.bayExited(modelData.id)
            }
        }
    }
}
