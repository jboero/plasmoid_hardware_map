/*
 * DIMM Error Monitor - tray-first ECC/MCE watcher for Plasma 6.
 *
 * Reads the JSON snapshot produced by dimm-mce-export (running as root from a
 * systemd timer). The widget itself needs no privileges.
 */
import QtQuick
import QtQuick.Layouts
import QtCore
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.kirigami as Kirigami
import org.kde.notification

PlasmoidItem {
    id: root

    // Used to look for board profiles under the user's data dir. QtCore's
    // StandardPaths gives this portably; there is no $HOME in QML otherwise.
    readonly property string homeDir: {
        var u = String(StandardPaths.writableLocation(StandardPaths.HomeLocation))
        return u.replace(/^file:\/\//, "")
    }

    // ---------------------------------------------------------------- snapshot
    property var snapshot: null
    property string loadError: ""
    property bool everLoaded: false

    // Errors accrued since we last told the user about them. These keep
    // counting up across polls; the notification is what resets them.
    property int pendingCE: 0
    property int pendingUE: 0
    property var pendingSlots: ({})

    readonly property int ceTotal: snapshot && snapshot.totals ? (snapshot.totals.ce_total || 0) : 0
    readonly property int ueTotal: snapshot && snapshot.totals ? (snapshot.totals.ue_total || 0) : 0
    readonly property int badgeCount: {
        if (!snapshot || !snapshot.totals) return 0
        var w = cfgStr("badgeWindow", "ce_30d")
        return snapshot.totals[w] !== undefined ? snapshot.totals[w] : (snapshot.totals.ce_30d || 0)
    }

    readonly property var errorSlots: {
        if (!snapshot || !snapshot.slots) return []
        return snapshot.slots.filter(function (s) {
            return (s.ce_total || 0) > 0 || (s.ue_total || 0) > 0
        }).sort(function (a, b) {
            return (b.ce_30d || 0) - (a.ce_30d || 0) || (b.ce_total || 0) - (a.ce_total || 0)
        })
    }

    readonly property int errorCount:
        snapshot && snapshot.counts ? (snapshot.counts.error || 0) : 0
    readonly property int warnCount:
        snapshot && snapshot.counts ? (snapshot.counts.warn || 0) : 0

    // "severity" drives the icon tint, the tray status and notification
    // urgency. It now reflects the whole board, not memory alone.
    // 0 clean, 1 historical only, 2 something needs watching, 3 serious.
    readonly property int severity: {
        if (!snapshot) return 0
        if (ueTotal > 0) return 3
        if (errorCount > 0) return 3
        if (warnCount > 0) return 2
        if (!snapshot.totals) return 0
        if ((snapshot.totals.ce_30d || 0) > 0) return 2
        if (ceTotal > 0) return 1
        return 0
    }

    // Always the memory icon. Severity is conveyed by tint and the count badge
    // rather than by swapping glyph: a warning triangle in the tray says
    // "something is wrong" without saying *what*, and loses the widget's
    // identity at a glance. Notifications still use data-warning/data-error,
    // where the glyph is the only signal available.
    readonly property string statusIcon: "memory"

    // ------------------------------------------------------------ tray snapshot
    /*
     * NeedsAttentionStatus makes Plasma PULSE the tray icon continuously. That
     * is only appropriate for something the user has not seen yet and should
     * look at now — never for a standing condition.
     *
     * Tying it to severity was wrong: a machine with a degrading DIMM is
     * permanently at severity 3, so the icon pulsed forever. A tray item that
     * never stops demanding attention is just nagging, and gets tuned out —
     * the same failure mode as the ABRT popup storm this tool exists to avoid.
     *
     * So it is tied to *unacknowledged uncorrectable* errors only, which the
     * notification path clears as soon as it reports them.
     */
    Plasmoid.status: {
        if (pendingUE > 0) return PlasmaCore.Types.NeedsAttentionStatus
        if (severity >= 2) return PlasmaCore.Types.ActiveStatus
        if (severity === 1) return PlasmaCore.Types.PassiveStatus
        return cfgBool("hideWhenClean", true)
               ? PlasmaCore.Types.PassiveStatus
               : PlasmaCore.Types.ActiveStatus
    }

    Plasmoid.icon: statusIcon

    toolTipMainText: i18n("Board Health")
    toolTipSubText: {
        if (loadError) return loadError
        if (!snapshot) return i18n("Reading…")
        var lines = []
        if (ueTotal > 0)
            lines.push(i18np("%1 UNCORRECTABLE memory (ECC) error — data may be wrong",
                             "%1 UNCORRECTABLE memory (ECC) errors — data may be wrong",
                             ueTotal))
        else if ((snapshot.totals.ce_30d || 0) > 0)
            lines.push(i18n("%1 corrected memory (ECC) errors in the last 30 days",
                            snapshot.totals.ce_30d))
        else if (ceTotal > 0)
            lines.push(i18n("%1 corrected memory (ECC) errors, all historical", ceTotal))
        else
            lines.push(i18n("No memory (ECC) errors"))
        if (errorCount || warnCount)
            lines.push(i18n("%1 component(s) in error, %2 needing attention",
                            errorCount, warnCount))
        lines.push(i18n("%1 components monitored",
                        snapshot.counts ? snapshot.counts.components : 0))
        return lines.join("\n")
    }

    switchWidth: Kirigami.Units.gridUnit * 22
    switchHeight: Kirigami.Units.gridUnit * 16

    compactRepresentation: CompactRepresentation {}
    fullRepresentation: FullRepresentation {}

    /*
     * Plasmoid.configuration reads can return undefined before the applet's
     * config has finished loading. Feeding that into arithmetic yields NaN,
     * and a Timer with a NaN interval never fires again — which silently
     * disabled polling entirely. Every config read goes through these so a
     * not-yet-ready value degrades to the documented default instead.
     */
    function cfgNum(name, fallback) {
        var v = Plasmoid.configuration[name]
        return (typeof v === "number" && isFinite(v)) ? v : fallback
    }
    function cfgBool(name, fallback) {
        var v = Plasmoid.configuration[name]
        return (typeof v === "boolean") ? v : fallback
    }
    function cfgStr(name, fallback) {
        var v = Plasmoid.configuration[name]
        return (typeof v === "string" && v.length > 0) ? v : fallback
    }

    // ----------------------------------------------------------- data loading
    /*
     * What a user sees when only HALF the project is installed.
     *
     * The KDE Store (and "Get New Widgets") installs the applet alone, into
     * ~/.local/share/plasma/plasmoids. It cannot install the root collector
     * that produces the snapshot, so the very first thing a store user meets
     * is a missing file. Saying "Cannot read /run/dimm-mce/state.json" is
     * technically true and completely useless to them, so the message says
     * what to do instead.
     */
    readonly property string collectorHint:
        i18n("This widget reads a snapshot written by a small root helper, "
             + "which the KDE Store cannot install for you. Get it from "
             + "%1 and run ./install.sh", root.projectUrl)

    readonly property string projectUrl:
        "https://github.com/jboero/plasmoid-hardware-map"

    function reload() {
        var path = cfgStr("statePath", "/run/dimm-mce/state.json")
        var xhr = new XMLHttpRequest()
        xhr.onreadystatechange = function () {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            // A file:// XHR reports status 0 on success in Qt.
            if (xhr.status !== 200 && xhr.status !== 0) {
                root.loadError = i18n("Cannot read %1.", path)
                              + "  " + root.collectorHint
                return
            }
            if (!xhr.responseText) {
                root.loadError = i18n(
                    "%1 is empty. Check: systemctl status dimm-mce-export.timer",
                    path)
                return
            }
            try {
                var parsed = JSON.parse(xhr.responseText)
                root.applyState(parsed)
                root.loadError = ""
            } catch (e) {
                root.loadError = i18n("Malformed snapshot file: %1", e.toString())
            }
        }
        try {
            xhr.open("GET", "file://" + path)
            xhr.send()
        } catch (e) {
            root.loadError = i18n("Cannot open %1.", path)
                          + "  " + root.collectorHint
        }
    }

    /*
     * The in-memory baseline is the authority; the config entry is only a cache
     * of it so the "unseen" tally survives a restart.
     *
     * This split exists because Plasmoid.configuration is restored
     * asynchronously and reads back EMPTY for a while after the applet is
     * built. An earlier version treated that empty read as "fresh install" and
     * immediately overwrote the stored baseline with current totals — which
     * silently reset the tally on every start, so no notification could ever
     * fire again. Nothing here writes to config until we have a baseline we
     * actually trust, so a slow config load can no longer destroy state.
     */
    property var seenBaseline: null

    function applyState(next) {
        root.snapshot = next

        if (root.seenBaseline === null) {
            var stored = readLastSeen()
            if (stored && stored.__totals) {
                // Restored from a previous session; carry the tally forward.
                root.seenBaseline = stored
            } else {
                // Either a genuinely fresh applet or config that has not
                // arrived yet. Both are handled the same way: baseline against
                // what we can see right now, in memory only. Doing this without
                // writing means a late config load simply replaces it below.
                root.seenBaseline = snapshotToBaseline(next)
                root.everLoaded = true
                return          // never announce pre-existing history
            }
        } else if (!root.everLoaded) {
            root.everLoaded = true
        }

        root.accumulate(next)
    }

    function snapshotToBaseline(snap) {
        var seen = {}
        if (snap && snap.slots) {
            for (var i = 0; i < snap.slots.length; ++i) {
                var s = snap.slots[i]
                seen[s.key] = { ce: s.ce_total || 0, ue: s.ue_total || 0 }
            }
        }
        seen.__totals = {
            ce: snap && snap.totals ? (snap.totals.ce_total || 0) : 0,
            ue: snap && snap.totals ? (snap.totals.ue_total || 0) : 0
        }
        return seen
    }

    function readLastSeen() {
        try {
            var raw = Plasmoid.configuration.lastSeen
            return raw ? JSON.parse(raw) : null
        } catch (e) {
            return null
        }
    }

    function commitBaseline(snap) {
        root.seenBaseline = snapshotToBaseline(snap)
        // Safe to persist now: we are past startup and hold a real baseline.
        Plasmoid.configuration.lastSeen = JSON.stringify(root.seenBaseline)
        root.pendingCE = 0
        root.pendingUE = 0
        root.pendingSlots = ({})
    }

    /*
     * Fold this snapshot into the pending tally, then decide whether the user
     * has earned an interruption.
     *
     * The machine-wide delta comes from totals, not from summing slots: an
     * error the memory controller could not pin to one of two sticks is
     * recorded against BOTH, so per-slot figures intentionally double-count.
     * Per-slot deltas are used only to name which sticks moved.
     */
    function accumulate(snap) {
        if (!snap || !snap.totals) return
        var seen = root.seenBaseline || {}
        var base = seen.__totals || { ce: 0, ue: 0 }

        root.pendingCE = Math.max(0, (snap.totals.ce_total || 0) - (base.ce || 0))
        root.pendingUE = Math.max(0, (snap.totals.ue_total || 0) - (base.ue || 0))

        var moved = {}
        if (snap.slots) {
            for (var i = 0; i < snap.slots.length; ++i) {
                var s = snap.slots[i]
                var was = seen[s.key] || { ce: 0, ue: 0 }
                var dce = (s.ce_total || 0) - (was.ce || 0)
                var due = (s.ue_total || 0) - (was.ue || 0)
                if (dce > 0 || due > 0)
                    moved[s.key] = { ce: Math.max(0, dce), ue: Math.max(0, due),
                                     // The component label is the readable one
                                     // ("CPU0 channel A slot 0", or "mc1 dimm0"
                                     // where the driver exposes no vendor
                                     // label); edac_label may be empty.
                                     label: s.label || s.edac_label,
                                     ambiguous: !!s.attribution_ambiguous }
            }
        }
        root.pendingSlots = moved
        root.maybeNotify()
    }

    function slotShortName(key, rec) {
        var m = /^s(\d+)_ha(\d+)_ch(\d+)_d(\d+)$/.exec(key)
        // Keys only take this shape where the driver gave real socket/channel
        // coordinates. Anything else (a `mc1_dimm0` positional key) has no
        // channel letter to compute, so show the collector's own label rather
        // than a raw key.
        if (!m) return (rec && rec.label) ? rec.label : key
        var ch = String.fromCharCode(65 + parseInt(m[3]) + 2 * parseInt(m[2]))
        return i18n("CPU%1 ch%2 slot %3", m[1], ch, m[4])
    }

    function pendingSummary() {
        var names = []
        for (var k in root.pendingSlots) {
            var r = root.pendingSlots[k]
            names.push(slotShortName(k, r) + " (+" + (r.ue > 0 ? r.ue + " UE" : r.ce) + ")")
        }
        names.sort()
        if (names.length === 0) return ""
        if (names.length <= 4) return names.join(", ")
        return names.slice(0, 4).join(", ") + i18n(" and %1 more", names.length - 4)
    }

    /*
     * Anti-flood policy. Corrected errors arrive in bursts of thousands; the
     * only sane contract is "at most one notification per quiet period, saying
     * how much accumulated". Uncorrectable errors bypass the quiet period
     * because they mean data may already be wrong.
     */
    function maybeNotify() {
        if (!cfgBool("notifyEnabled", true)) return

        var now = Math.floor(Date.now() / 1000)
        var urgent = root.pendingUE > 0 && cfgBool("notifyUncorrectable", true)

        if (urgent) {
            uncorrectableNotification.title =
                i18n("Uncorrectable memory error")
            uncorrectableNotification.text =
                i18np("%1 uncorrectable error on %2. This memory is failing — back up and replace it.",
                      "%1 uncorrectable errors on %2. This memory is failing — back up and replace it.",
                      root.pendingUE, pendingSummary())
            uncorrectableNotification.sendEvent()
            root.commitBaseline(root.snapshot)
            Plasmoid.configuration.lastNotifyEpoch = now
            return
        }

        if (root.pendingCE < Math.max(1, cfgNum("notifyThreshold", 1))) return

        var quiet = Math.max(0, cfgNum("notifyQuietMinutes", 60)) * 60
        var since = now - cfgNum("lastNotifyEpoch", 0)
        if (cfgNum("lastNotifyEpoch", 0) > 0 && since < quiet) return

        correctedNotification.title =
            i18np("%1 new corrected memory error",
                  "%1 new corrected memory errors", root.pendingCE)
        correctedNotification.text = pendingSummary()
            ? i18n("%1 — corrected by ECC, no data lost. Click to see the board layout.",
                   pendingSummary())
            : i18n("Corrected by ECC, no data lost.")
        correctedNotification.sendEvent()
        root.commitBaseline(root.snapshot)
        Plasmoid.configuration.lastNotifyEpoch = now
    }

    Notification {
        id: correctedNotification
        componentName: "dimmmcemonitor"
        eventId: "correctederrors"
        iconName: "data-warning"
        urgency: Notification.NormalUrgency
        flags: Notification.CloseOnTimeout
    }

    Notification {
        id: uncorrectableNotification
        componentName: "dimmmcemonitor"
        eventId: "uncorrectableerror"
        iconName: "data-error"
        urgency: Notification.CriticalUrgency
        flags: Notification.Persistent
    }

    Timer {
        interval: Math.max(5, cfgNum("pollSeconds", 60)) * 1000
        running: true
        repeat: true
        // Deliberately NOT triggeredOnStart: that fires while the applet is
        // still being built, before Plasmoid.configuration is restored.
        triggeredOnStart: false
        onTriggered: root.reload()
    }

    // Plasmoid.configuration is restored asynchronously and is still empty
    // during Component.onCompleted. Measured on Plasma 6.7 it populates within
    // ~250 ms, so the first read is deferred past that. Reading too early made
    // the widget mistake a configured applet for a fresh one and silently
    // re-baseline, which stopped notifications from ever firing.
    Timer {
        id: startupTimer
        interval: 1000
        running: true
        repeat: false
        onTriggered: root.reload()
    }

    Plasmoid.contextualActions: [
        PlasmaCore.Action {
            text: i18n("Refresh now")
            icon.name: "view-refresh"
            onTriggered: root.reload()
        },
        PlasmaCore.Action {
            text: i18n("Mark all errors as seen")
            icon.name: "checkmark"
            onTriggered: root.commitBaseline(root.snapshot)
        }
    ]
}
