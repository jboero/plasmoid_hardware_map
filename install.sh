#!/usr/bin/env bash
# Installer for the DIMM Error Monitor.
#
# Two halves:
#   - a root collector (systemd timer) that snapshots ECC state to
#     /run/dimm-mce/state.json, world-readable
#   - a Plasma 6 applet, installed per-user, that only ever reads that file
#
# The split exists so the widget needs no sudo rule and no polkit action.

set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLET_ID="io.github.jboero.hardwaremap"

# Renamed before the first KDE Store release: org.kde.* is reserved for
# projects hosted by KDE itself. Left in place, the old package keeps showing up
# as a second, stale tray entry alongside the new one.
LEGACY_APPLET_ID="org.kde.dimmMceMonitor"
BOARDS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/dimm-mce-monitor/boards"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m warning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m error:\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] && die "run this as your normal user; it will call sudo only where needed"

# ---------------------------------------------------------------- collector
say "Installing collector to /usr/local/bin/dimm-mce-export"
sudo install -Dm755 "$SRC/collector/dimm-mce-export.py" /usr/local/bin/dimm-mce-export

say "Installing systemd units"
sudo install -Dm644 "$SRC/collector/dimm-mce-export.service" \
    /etc/systemd/system/dimm-mce-export.service
sudo install -Dm644 "$SRC/collector/dimm-mce-export.timer" \
    /etc/systemd/system/dimm-mce-export.timer
sudo systemctl daemon-reload
sudo systemctl enable --now dimm-mce-export.timer

say "Priming the state file"
sudo systemctl start dimm-mce-export.service
if [[ ! -r /run/dimm-mce/state.json ]]; then
    die "/run/dimm-mce/state.json was not created - check: systemctl status dimm-mce-export"
fi

# rasdaemon is where the persistent history lives. Without it the widget still
# works but only sees counters since boot, which reset on every reboot and are
# unreliable on some boards.
if ! systemctl is-enabled --quiet rasdaemon 2>/dev/null; then
    warn "rasdaemon is not enabled - error history will not survive reboots."
    warn "  sudo dnf install rasdaemon && sudo systemctl enable --now rasdaemon"
fi

# ------------------------------------------------------------------- applet
say "Installing docs"
install -Dm644 "$SRC/AGENTS.md" "$BOARDS_DIR/../AGENTS.md"

# Board modules live in boards/ and are copied INTO the package, which is the
# only place shipped profiles belong. They are deliberately NOT copied to
# $BOARDS_DIR: the user directory is searched *first*, so a copy there would
# permanently shadow the packaged one and a later upgrade could never correct a
# bad profile. That directory is for boards the user adds themselves.
#
# Note the trailing '/.' - board modules are directories, so a plain
# `cp -f boards/*` copies index.json and silently omits every board.
say "Syncing board modules into the package"
PKG_BOARDS="$SRC/plasmoid/$APPLET_ID/contents/boards"
mkdir -p "$PKG_BOARDS"
cp -a "$SRC/boards/." "$PKG_BOARDS/"

say "Creating $BOARDS_DIR for your own board profiles"
mkdir -p "$BOARDS_DIR"

say "Installing notification definitions"
install -Dm644 "$SRC/plasmoid/$APPLET_ID/contents/dimmmcemonitor.notifyrc" \
    "${XDG_DATA_HOME:-$HOME/.local/share}/knotifications6/dimmmcemonitor.notifyrc"

INSTALLED="$(kpackagetool6 --type Plasma/Applet --list 2>/dev/null || true)"

if grep -qx "$LEGACY_APPLET_ID" <<<"$INSTALLED"; then
    say "Removing the old $LEGACY_APPLET_ID package"
    kpackagetool6 --type Plasma/Applet --remove "$LEGACY_APPLET_ID" || \
        warn "could not remove $LEGACY_APPLET_ID - remove it by hand if a duplicate entry appears in the tray"
fi

say "Installing the Plasma applet"
if grep -qx "$APPLET_ID" <<<"$INSTALLED"; then
    kpackagetool6 --type Plasma/Applet --upgrade "$SRC/plasmoid/$APPLET_ID"
else
    kpackagetool6 --type Plasma/Applet --install "$SRC/plasmoid/$APPLET_ID"
fi

cat <<EOF

$(say "Done.")

To put YOUR motherboard picture behind the components, see:
  $SRC/AGENTS.md   (also installed to ${XDG_DATA_HOME:-$HOME/.local/share}/dimm-mce-monitor/)

RESTART THE SHELL, or the widget will not appear at all:
  systemctl --user restart plasma-plasmashell

The tray only discovers new entries at startup. On restart this one enables
itself (metadata sets EnabledByDefault), so no clicking is needed. If you would
rather place it by hand:
  right-click the panel -> Configure System Tray -> Entries
  set "Board Health Monitor" to Shown or Auto
Note that "Always display all entries" does NOT enable a disabled entry - it
only controls where enabled ones are drawn.

The icon hides itself while no errors are recorded, so on a healthy machine it
sits in the collapsed drawer rather than the visible row. Untick "Keep the tray
icon hidden while no errors are recorded" in the widget's settings if you want it
always visible. Verify the collector with:
  systemctl status dimm-mce-export.timer
  sudo /usr/local/bin/dimm-mce-export --verbose

If the applet does not appear, restart the shell:
  systemctl --user restart plasma-plasmashell
EOF
