# KDE Store listing — paste-ready

Upload at <https://store.kde.org/> → *Add Product*.

| Field | Value |
|---|---|
| Category | **Plasma 6 → Plasma Widgets** (not Plasma 5 — this needs Qt 6) |
| Title | Board Health Monitor |
| Version | 1.0.0 |
| License | GPL-2.0-or-later |
| Source / homepage | https://github.com/jboero/plasmoid-hardware-map |
| File | `dist/plasmoid_hardware_map-1.0.0.plasmoid` |
| Tags | plasma6, systemtray, hardware, monitor, smart, ecc, sensors, pcie, nvme |

Screenshots to attach, in this order — `doc/board-view.png` first, because the
board picture is the whole point and it has to be the thumbnail:

1. `doc/board-view.png` — "Component health drawn on the real board"
2. `doc/board-detail.png` — "Hover anything for what the numbers mean"

---

## Summary (one line)

Hardware health — ECC errors, SMART, temperatures, fans, PCIe and storage ports
— shown on a picture of your actual motherboard.

---

## Description

**Requires a companion collector that the KDE Store cannot install.** The widget
reads a snapshot written by a small root service; installing the widget alone
will show you a message telling you exactly this. Get both from
https://github.com/jboero/plasmoid-hardware-map and run `./install.sh`.

---

Most hardware monitors give you a number. A number is useless if you do not
already know what it counts, and worse than useless if it cannot tell you which
physical part to go and touch.

This one shows you the part. Hover a DIMM slot and it names the module by its
silkscreen label and serial. Hover a PCIe slot and it tells you whether the card
trained at full width — and if not, whether that is the board's wiring, so
moving the card is the only fix, or a physical-layer problem, so reseating it
might help. Hover a storage connector and you get the drive's SMART counters,
and whether any of them have *moved* since the drive was first seen.

**What it watches**

- **Memory** — per-DIMM corrected and uncorrectable ECC errors over 24 h, 7 d
  and 30 d, separating errors proven to one module from errors merely shared
  with its channel neighbour.
- **PCIe slots** — current versus maximum link width and speed, plus the drives
  behind carrier cards and HBAs.
- **Drives** — SMART health, reallocated / pending / uncorrectable / CRC
  counters, NVMe endurance and media errors. It alarms on counters that are
  *growing*, not on old static scars, so an elderly disk does not sit
  permanently in warning.
- **Storage connectors** — one entry per physical port, inheriting the health of
  whatever is plugged into it.
- **Fans and temperatures**, with each fan graded against its siblings, so a fan
  lagging its pair is visible.
- **Network ports** — link state and speed.

**It works on any machine.** The board picture is a convenience layer. Without a
profile for your board it falls back to a grouped list of everything it found.
Adding your own board means supplying a picture and dragging a box over each
component; the repository ships a calibration tool and a guide written for
coding assistants, since most of the work is reading silkscreen at high zoom.

**It is honest about what it does not know.** Physical geometry appears nowhere
in SMBIOS, and nothing in firmware connects a silkscreened DIMM label to an EDAC
channel. Board profiles therefore declare a confidence level, and anything
inferred is labelled as inferred in the interface rather than presented as fact.
A confidently wrong mapping sends someone to pull a healthy module, which is the
one failure mode this project most wants to avoid. For the same reason, a
machine whose chipset cannot detect memory errors at all reports its memory as
*unknown* rather than green.

**Requirements:** Plasma 6 / Qt 6, `smartmontools`, `dmidecode`, and
`rasdaemon` for ECC history that survives a reboot.

---

## Changelog field

First release. Full notes: https://github.com/jboero/plasmoid-hardware-map/blob/main/CHANGELOG.md

---

## Before you upload

```sh
./tools/package.sh          # syncs boards, validates, builds dist/*.plasmoid
```

The script fails the build if a board profile's `imageSize` disagrees with its
picture or a rectangle is not normalised, because both mistakes look plausible
in JSON and only show up when you render the overlay.

**Check the screenshots for private data before attaching them.** Network port
tooltips show MAC addresses and drive tooltips show serial numbers. Nothing is
transmitted anywhere, but they are visible on screen and a screenshot is public.
