# Changelog

## 1.0.0 — 2026-08-13

First release.

A Plasma 6 system-tray widget that draws your machine's hardware health on a
picture of your actual motherboard, and falls back to a grouped component list
on any machine without a board profile.

### Monitors

- **Memory** — per-DIMM corrected and uncorrectable ECC from rasdaemon and EDAC,
  windowed over 24 h / 7 d / 30 d, separating errors *proven* to one module from
  errors merely *shared* with its channel neighbour. On machines with no ECC at
  all, memory inventory comes from SMBIOS and is reported as `unknown` rather
  than green — absence of reported errors is not health when nothing is looking.
- **PCIe slots** — current versus maximum link width and speed, distinguishing
  board wiring from a degraded link, plus AER counters. Drives behind carrier
  cards and HBAs are reported on the slot and drawn as bays extending from it.
- **Drives** — SMART health, reallocated / pending / uncorrectable / CRC
  counters, NVMe endurance and media errors. Alarms on counter *growth* against
  a per-serial baseline, not on old static scars.
- **Storage connectors** — one component per physical ATA port and SAS PHY, each
  inheriting the health of whatever is plugged into it.
- **Fans and temperatures** — from hwmon, each fan graded against its siblings.
- **Network ports** — link state and speed per physical interface.

### Design

- Two halves: a root **collector** on a systemd timer writes a world-readable
  snapshot to `/run/dimm-mce/state.json`; the widget only ever reads that file.
  It needs no sudo rule, no polkit action, and no privileges of its own.
- Every reading states what it counts. There are no bare integers.
- Board profiles declare a `confidence`, and anything inferred — notably which
  silkscreened DIMM maps to which EDAC channel, which nothing in firmware
  records — is labelled as inferred rather than presented as fact.

### Notes for this release

- The applet ID is `io.github.jboero.hardwaremap`. Pre-release builds used
  `org.kde.dimmMceMonitor`; that namespace is reserved for projects hosted by
  KDE itself. `install.sh` removes the old package so it does not linger as a
  second tray entry.
- Installing from the KDE Store gets you **the widget only**. The collector
  cannot be installed by the store — clone the repository and run `./install.sh`.
- The bundled HP Z840 profile is marked `derived`: its rectangles are traced
  against a real photograph, but the DIMM locator↔EDAC-channel mapping is
  inferred from HP's documented loading order and has not been proven by
  pulling a module.
