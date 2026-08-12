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
APPLET_ID="org.kde.dimmMceMonitor"
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

say "Installing board profiles to $BOARDS_DIR"
mkdir -p "$BOARDS_DIR"
cp -f "$SRC"/boards/* "$BOARDS_DIR/" 2>/dev/null || true

# Profiles also ship inside the package so auto-detect finds them with no
# further configuration.
PKG_BOARDS="$SRC/plasmoid/$APPLET_ID/contents/boards"
mkdir -p "$PKG_BOARDS"
cp -f "$SRC"/boards/* "$PKG_BOARDS/" 2>/dev/null || true

say "Installing notification definitions"
install -Dm644 "$SRC/plasmoid/$APPLET_ID/contents/dimmmcemonitor.notifyrc" \
    "${XDG_DATA_HOME:-$HOME/.local/share}/knotifications6/dimmmcemonitor.notifyrc"

say "Installing the Plasma applet"
if kpackagetool6 --type Plasma/Applet --list 2>/dev/null | grep -qx "$APPLET_ID"; then
    kpackagetool6 --type Plasma/Applet --upgrade "$SRC/plasmoid/$APPLET_ID"
else
    kpackagetool6 --type Plasma/Applet --install "$SRC/plasmoid/$APPLET_ID"
fi

cat <<EOF

$(say "Done.")

To put YOUR motherboard picture behind the components, see:
  $SRC/AGENTS.md   (also installed to ${XDG_DATA_HOME:-$HOME/.local/share}/dimm-mce-monitor/)

Add it from the system tray:
  right-click the panel -> Configure System Tray -> Entries
  set "Board Health Monitor" to Shown or Auto

The icon hides itself while no errors are recorded (configurable). Verify the
collector with:
  systemctl status dimm-mce-export.timer
  sudo /usr/local/bin/dimm-mce-export --verbose

If the applet does not appear, restart the shell:
  systemctl --user restart plasma-plasmashell
EOF
