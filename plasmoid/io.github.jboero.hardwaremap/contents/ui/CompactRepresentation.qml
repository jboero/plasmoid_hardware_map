/*
 * Tray icon. Stays deliberately quiet: a plain flash-memory glyph when nothing
 * is wrong, tinted plus a count badge once errors exist.
 */
import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PlasmaComponents
import org.kde.kirigami as Kirigami

MouseArea {
    id: compact

    readonly property int sev: root.severity
    readonly property int badge: root.badgeCount

    Layout.minimumWidth: Kirigami.Units.iconSizes.small
    Layout.minimumHeight: Kirigami.Units.iconSizes.small

    acceptedButtons: Qt.LeftButton | Qt.MiddleButton
    onClicked: function (mouse) {
        if (mouse.button === Qt.MiddleButton)
            root.reload()
        else
            root.expanded = !root.expanded
    }

    Kirigami.Icon {
        id: icon
        anchors.fill: parent
        source: root.statusIcon
        active: compact.containsMouse
        // Kirigami recolours symbolic icons; the negative/neutral tints read
        // correctly against both light and dark panels.
        // Breeze ships memory.svg only at 64px and with no symbolic variant, so
        // it is drawn in full colour rather than masked - masking reduces it to
        // an unrecognisable pair of bars. Severity is carried by the badge.
        isMask: false
    }

    // Count badge, bottom-right, only once there is something to report and
    // only when the icon is big enough for it to be legible.
    Rectangle {
        visible: badge > 0 && compact.height >= Kirigami.Units.iconSizes.smallMedium
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        // Sized FROM the label, so the label's font must not be sized from
        // this rectangle - that was a binding loop. Both derive from the
        // panel-imposed height of `compact` instead, which is a fixed input.
        width: Math.min(compact.width, label.implicitWidth + Kirigami.Units.smallSpacing)
        height: Math.min(compact.height * 0.62, label.implicitHeight + 2)
        radius: height / 2
        color: sev >= 3 ? Kirigami.Theme.negativeBackgroundColor
                        : Kirigami.Theme.neutralBackgroundColor
        border.width: 1
        border.color: sev >= 3 ? Kirigami.Theme.negativeTextColor
                               : Kirigami.Theme.neutralTextColor

        PlasmaComponents.Label {
            id: label
            anchors.centerIn: parent
            text: badge > 999 ? "999+" : badge
            font.pixelSize: Math.max(7, Math.round(compact.height * 0.42))
            font.bold: true
            color: sev >= 3 ? Kirigami.Theme.negativeTextColor
                            : Kirigami.Theme.neutralTextColor
        }
    }

    hoverEnabled: true
}
