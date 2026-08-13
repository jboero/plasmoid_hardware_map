/*
 * Popup shown when the tray icon is clicked. Summary strip, board view, and a
 * detail pane for whichever slot is selected.
 */
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.plasma.plasmoid
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.extras as PlasmaExtras
import org.kde.kirigami as Kirigami

PlasmaExtras.Representation {
    id: full

    Layout.minimumWidth: Kirigami.Units.gridUnit * 26
    Layout.minimumHeight: Kirigami.Units.gridUnit * 22
    Layout.preferredWidth: Kirigami.Units.gridUnit * 34
    Layout.preferredHeight: Kirigami.Units.gridUnit * 28

    property var profile: null

    // ---------------------------------------------------- board profile load
    //
    // Boards are self-contained modules: boards/<id>/profile.json plus its
    // picture. QML cannot list a directory, so boards/index.json is a registry
    // mapping DMI identity -> board directory. Community boards drop in as a
    // new directory plus one index entry; nothing here is board-specific.
    //
    // Search order, first hit wins:
    //   1. an explicit path from configuration
    //   2. the registry, in the user data dir then inside the package
    //   3. legacy flat boards/<slug>.json (pre-module layout)
    property string profileDiag: ""
    property var tryPaths: []
    property int tryIndex: 0

    readonly property var searchRoots: [
        "file://" + root.homeDir + "/.local/share/dimm-mce-monitor/boards/",
        String(Qt.resolvedUrl("../boards/"))
    ]

    function slugify(s) {
        return (s || "").toLowerCase()
                        .replace(/[^a-z0-9]+/g, "-")
                        .replace(/^-+|-+$/g, "")
    }

    function dmiMatches(match) {
        if (!match || !root.snapshot || !root.snapshot.board) return false
        var b = root.snapshot.board
        for (var k in match) {
            var want = String(match[k] || "").toLowerCase().trim()
            var have = String(b[k] || "").toLowerCase().trim()
            if (!want) continue
            if (want !== have) return false
        }
        return true
    }

    function loadProfile() {
        full.profileDiag = ""
        var explicit = Plasmoid.configuration.boardProfilePath
        if (explicit) {
            fetchProfile(explicit.indexOf("file:") === 0
                         ? explicit : "file://" + explicit, null)
            return
        }
        if (!root.snapshot || !root.snapshot.board) return
        indexRootIndex = 0
        tryIndexRegistry()
    }

    property int indexRootIndex: 0

    function tryIndexRegistry() {
        if (indexRootIndex >= searchRoots.length) {
            legacyLookup()
            return
        }
        var base = searchRoots[indexRootIndex++]
        fetchJson(base + "index.json", function (idx) {
            var boards = (idx && idx.boards) ? idx.boards : []
            for (var i = 0; i < boards.length; ++i) {
                if (dmiMatches(boards[i].match)) {
                    fetchProfile(base + boards[i].dir + "/profile.json",
                                 tryIndexRegistry)
                    return
                }
            }
            tryIndexRegistry()          // registry present but no match here
        }, tryIndexRegistry)
    }

    function legacyLookup() {
        var b = root.snapshot.board
        var slugs = []
        var s1 = slugify(b.board_vendor + "-" + b.board_name)
        var s2 = slugify(b.product_name)
        if (s1) slugs.push(s1)
        if (s2 && s2 !== s1) slugs.push(s2)
        var cands = []
        for (var r = 0; r < searchRoots.length; ++r)
            for (var i = 0; i < slugs.length; ++i)
                cands.push(searchRoots[r] + slugs[i] + ".json")
        full.tryPaths = cands
        full.tryIndex = 0
        tryNext()
    }

    function tryNext() {
        if (full.tryIndex >= full.tryPaths.length) {
            full.profileDiag = i18n("No board profile for this machine — showing the component list. See AGENTS.md to add one.")
            return
        }
        fetchProfile(full.tryPaths[full.tryIndex++], tryNext)
    }

    function fetchJson(url, onOk, onFail) {
        var xhr = new XMLHttpRequest()
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            if ((xhr.status === 200 || xhr.status === 0) && xhr.responseText) {
                try { onOk(JSON.parse(xhr.responseText)); return }
                catch (e) { /* fall through to onFail */ }
            }
            if (onFail) onFail()
        }
        try { xhr.open("GET", String(url)); xhr.send() }
        catch (e) { if (onFail) onFail() }
    }

    function fetchProfile(url, onFail) {
        fetchJson(url, function (p) {
            // Resolve the picture relative to the profile, so a board module
            // stays relocatable and self-contained.
            if (p.image && p.image.indexOf("/") !== 0
                && p.image.indexOf("file:") !== 0)
                p.image = String(url).replace(/[^\/]*$/, "") + p.image
            full.profile = p
            full.profileDiag = ""
        }, onFail)
    }

    Component.onCompleted: loadProfile()
    Connections {
        target: root
        function onSnapshotChanged() { if (!full.profile) full.loadProfile() }
        // Collapsing the popup with the pointer still over a slot leaves that
        // slot hovered, so it would reappear highlighted on the next open.
        function onExpandedChanged() {
            if (!root.expanded) boardView.hoveredKey = ""
        }
    }

    // --------------------------------------------------------------- content
    header: PlasmaExtras.PlasmoidHeading {
        RowLayout {
            anchors.fill: parent
            spacing: Kirigami.Units.smallSpacing

            Kirigami.Icon {
                source: root.statusIcon
                Layout.preferredWidth: Kirigami.Units.iconSizes.medium
                Layout.preferredHeight: Kirigami.Units.iconSizes.medium
                // Rendered unmasked: the Breeze memory icon is a recognisable
                // DIMM, and masking flattens it to an anonymous silhouette.
                // Severity reads from the badge and the coloured summary line.
                isMask: false
            }

            ColumnLayout {
                spacing: 0
                Layout.fillWidth: true
                PlasmaComponents.Label {
                    text: root.snapshot && root.snapshot.board
                          ? (root.snapshot.board.product_name || i18n("Memory"))
                          : i18n("DIMM Error Monitor")
                    font.bold: true
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }
                PlasmaComponents.Label {
                    text: {
                        if (root.loadError) return root.loadError
                        if (!root.snapshot) return i18n("Reading…")
                        var t = root.snapshot.totals
                        var c = root.snapshot.counts || {}
                        // Always name the quantity. "489" on its own tells a
                        // user nothing about what was counted.
                        var mem
                        if (t.ue_total > 0)
                            mem = i18n("%1 UNCORRECTABLE ECC errors", t.ue_total)
                        else if (t.ce_30d > 0)
                            mem = i18n("%1 ECC errors in 30 days", t.ce_30d)
                        else if (t.ce_total > 0)
                            mem = i18n("%1 ECC errors (historical)", t.ce_total)
                        else
                            mem = i18n("no ECC errors")
                        return i18n("Memory: %1  ·  %2 components, %3 need attention",
                                    mem, c.components || 0,
                                    (c.error || 0) + (c.warn || 0))
                    }
                    opacity: 0.75
                    font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }
            }

            PlasmaComponents.ToolButton {
                icon.name: "view-refresh"
                display: QQC2.AbstractButton.IconOnly
                onClicked: root.reload()
                PlasmaComponents.ToolTip.text: i18n("Refresh now")
                PlasmaComponents.ToolTip.visible: hovered
                PlasmaComponents.ToolTip.delay: 500
            }
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: Kirigami.Units.smallSpacing

        // Warning strip: attribution caveats and collector problems.
        PlasmaComponents.Label {
            Layout.fillWidth: true
            visible: text !== ""
            wrapMode: Text.WordWrap
            font.pixelSize: Kirigami.Theme.smallFont.pixelSize
            color: Kirigami.Theme.neutralTextColor
            text: {
                if (root.loadError) return root.loadError
                if (!root.snapshot) return ""
                var w = (root.snapshot.warnings || []).slice()
                if (full.profileDiag) w.push(full.profileDiag)
                if (full.profile && full.profile.confidence === "derived")
                    w.push(i18n("Slot positions in this board profile are inferred, not vendor-confirmed."))
                return w.join("  ")
            }
        }

        // Takes every remaining pixel. Details are shown by a floating tooltip
        // inside BoardView rather than an inline panel, so hovering can never
        // change this item's size - see the comment on BoardView's tooltip.
        BoardView {
            id: boardView
            Layout.fillWidth: true
            Layout.fillHeight: true
            components: root.snapshot && root.snapshot.components
                        ? root.snapshot.components : []
            dmiSlots: root.snapshot && root.snapshot.dmi_slots
                      ? root.snapshot.dmi_slots : []
            profile: full.profile

        }

    }
}
