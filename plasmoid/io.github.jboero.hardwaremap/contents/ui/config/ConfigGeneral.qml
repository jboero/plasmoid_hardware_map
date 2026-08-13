import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

KCM.SimpleKCM {
    property alias cfg_statePath: statePath.text
    property alias cfg_pollSeconds: pollSeconds.value
    property alias cfg_notifyEnabled: notifyEnabled.checked
    property alias cfg_notifyQuietMinutes: quietMinutes.value
    property alias cfg_notifyThreshold: threshold.value
    property alias cfg_notifyUncorrectable: notifyUE.checked
    property alias cfg_hideWhenClean: hideWhenClean.checked
    property alias cfg_showBoardImage: showImage.checked
    property alias cfg_imageOpacity: imageOpacity.value
    property alias cfg_boardProfilePath: profilePath.text
    property string cfg_badgeWindow

    Kirigami.FormLayout {

        QQC2.TextField {
            id: statePath
            Kirigami.FormData.label: i18n("State file:")
            Layout.minimumWidth: Kirigami.Units.gridUnit * 20
        }

        QQC2.SpinBox {
            id: pollSeconds
            Kirigami.FormData.label: i18n("Check every:")
            from: 5
            to: 3600
            stepSize: 5
            textFromValue: function (v) { return i18n("%1 seconds", v) }
            valueFromText: function (t) { return parseInt(t) || 60 }
        }

        Item { Kirigami.FormData.isSection: true
               Kirigami.FormData.label: i18n("Notifications") }

        QQC2.CheckBox {
            id: notifyEnabled
            text: i18n("Notify when new corrected errors appear")
        }

        QQC2.SpinBox {
            id: quietMinutes
            enabled: notifyEnabled.checked
            Kirigami.FormData.label: i18n("At most one notification every:")
            from: 0
            to: 1440
            stepSize: 15
            textFromValue: function (v) {
                return v === 0 ? i18n("no limit (not recommended)")
                               : i18n("%1 minutes", v)
            }
            valueFromText: function (t) { return parseInt(t) || 60 }
        }

        QQC2.SpinBox {
            id: threshold
            enabled: notifyEnabled.checked
            Kirigami.FormData.label: i18n("Only once this many accumulate:")
            from: 1
            to: 100000
            stepSize: 10
        }

        QQC2.Label {
            Layout.maximumWidth: Kirigami.Units.gridUnit * 22
            wrapMode: Text.WordWrap
            font: Kirigami.Theme.smallFont
            opacity: 0.75
            text: i18n("A failing DIMM can log thousands of corrected errors per hour. New errors are tallied up between notifications and reported as a single summary, so the count you see is everything since the last one — never one popup per error.")
        }

        QQC2.CheckBox {
            id: notifyUE
            text: i18n("Always notify immediately on uncorrectable errors")
        }

        QQC2.Label {
            Layout.maximumWidth: Kirigami.Units.gridUnit * 22
            wrapMode: Text.WordWrap
            font: Kirigami.Theme.smallFont
            opacity: 0.75
            text: i18n("Uncorrectable errors mean ECC could not repair the data. These ignore the quiet period.")
        }

        Item { Kirigami.FormData.isSection: true
               Kirigami.FormData.label: i18n("Tray") }

        QQC2.CheckBox {
            id: hideWhenClean
            text: i18n("Hide the icon while no errors are recorded")
        }

        QQC2.ComboBox {
            id: badgeWindow
            Kirigami.FormData.label: i18n("Badge shows:")
            textRole: "text"
            valueRole: "value"
            model: [
                { text: i18n("Errors in last 24 hours"), value: "ce_24h" },
                { text: i18n("Errors in last 7 days"),   value: "ce_7d" },
                { text: i18n("Errors in last 30 days"),  value: "ce_30d" },
                { text: i18n("Lifetime total"),          value: "ce_total" }
            ]
            onActivated: cfg_badgeWindow = currentValue
            Component.onCompleted: {
                for (var i = 0; i < model.length; ++i)
                    if (model[i].value === cfg_badgeWindow) { currentIndex = i; break }
            }
        }

        Item { Kirigami.FormData.isSection: true
               Kirigami.FormData.label: i18n("Board picture") }

        QQC2.CheckBox {
            id: showImage
            text: i18n("Show the board photo behind the slots")
        }

        QQC2.Slider {
            id: imageOpacity
            enabled: showImage.checked
            Kirigami.FormData.label: i18n("Photo opacity:")
            from: 0.1
            to: 1.0
            stepSize: 0.05
            Layout.minimumWidth: Kirigami.Units.gridUnit * 14
        }

        QQC2.TextField {
            id: profilePath
            Kirigami.FormData.label: i18n("Board profile:")
            placeholderText: i18n("auto-detect from DMI")
            Layout.minimumWidth: Kirigami.Units.gridUnit * 20
        }

        QQC2.Label {
            Layout.maximumWidth: Kirigami.Units.gridUnit * 22
            wrapMode: Text.WordWrap
            font: Kirigami.Theme.smallFont
            opacity: 0.75
            text: i18n("Without a profile the slots are drawn as a schematic grouped by CPU and channel, which works on any machine. A profile adds a picture of your actual board — see tools/calibrate.py to make one.")
        }
    }
}
