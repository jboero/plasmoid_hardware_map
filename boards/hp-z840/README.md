# HP Z840 Workstation

> **Image provenance — resolve before redistributing.**
> `board.webp` and `board-diagram.png` were supplied locally and their
> copyright status is **not established**. `board-diagram.png` in particular
> appears to derive from HP service documentation, which is HP's copyright and
> is *not* licensed for redistribution under this project's GPL.
>
> Before this profile ships in a public release or a KDE Store package, either
> replace both with a photograph you took yourself, or drop the imagery and keep
> the profile geometry only — the widget falls back to its list view when a
> profile has no usable image, so the profile stays useful either way.

Board `Hewlett-Packard` / `2129`, dual LGA2011-3, 16 DIMM slots, 7 PCIe slots.

`board.webp` is a straight-on photograph of a real Z840 board with the
background removed, 1358×1200. `board-diagram.png` plus
`profile-diagram.json.alt` are an earlier profile built against HP's "Figure 6 —
loading order for dual CPU configurations"; kept because the diagram is cleaner
for reading population order, but the photo profile is the active one.

## Verified

- **DIMM socket and slot number.** Taken from the silkscreen, which is legible
  in the photo (`CPU0-DIMM1..8`, `CPU1-DIMM1..8`).
- **Bank layout.** Labels are printed on the CPU-facing edge of each slot, and
  the banks mirror around their socket: `DIMM8,7,6,5 | CPU | DIMM4,3,2,1`
  reading top to bottom.
- **PCIe slot positions.** `SLOT0`–`SLOT7`, read off the silkscreen. Note HP
  prints slot labels in the *gaps* between connectors, one serving the slot
  above and one below, so the nearest label to a connector is not reliably its
  own.
- **All 14 storage connectors**, read off the silkscreen in `board.webp` at 8×
  zoom and cross-checked against HP's service diagram (callouts 13/14/15). Three
  blocks, every one numbered **right to left**:

  | Block | Connectors | Silkscreen | Driven by |
  |---|---|---|---|
  | SAS/SATA 6Gb/s (callout 13) | 8, cream | `SAS0`–`SAS7` | LSI SAS2308 HBA PHYs |
  | sSATA 6Gb/s (callout 15) | 4, grey | `sSATA0`–`sSATA3` | `00:11.4` (Intel sSATA function) |
  | SATA 6Gb/s (callout 14) | 2, black | `SATA0`–`SATA1` | `00:1f.2` (Intel SATA function) |

  The grouping agrees with Intel's function names — no inversion.

  Kernel `ata` numbering is global across both PCH controllers and 1-based,
  while the silkscreen restarts at 0 per block: `ata1..4` = `sSATA0..3`,
  `ata5..6` = `SATA0..1`.

  **Read the leading `s` carefully.** At `board.webp`'s resolution it is about
  one pixel wide, and losing it swaps the two group names — which files the
  optical drive under the wrong heading and makes it look absent. Zoom to 16×,
  or take the grouping from the service diagram's callouts 14/15, which is
  unambiguous.

## Inferred — treat with suspicion

- **Which EDAC channel each silkscreened DIMM belongs to.** Derived from HP's
  loading order (`CPU0-DIMMn` = population order `2n-1`, `CPU1-DIMMn` = `2n`)
  combined with the assumption that the first channel populated is channel A.
  Nothing in SMBIOS confirms this. If HP letters channels differently, the CPU
  and slot number are still right but the channel letter rotates within that CPU.
- **The two RJ45 assignments** (`eno1`, `enp12s0`) are a guess at which physical
  jack is which interface.

To settle the DIMM mapping properly: note a stick's serial from
`sudo dmidecode -t 17`, pull it, reboot, and see which serial disappears and
which EDAC key stops reporting.

## Not placed

Fan headers are deliberately absent — they are indistinguishable from the other
4-pin headers in this photo, and a confidently-wrong position is worse than
none. Fans still appear in the widget's component list.

Per-core temperature sensors (56 of them on a dual 22-core machine) are also
unplaced; they belong in the list, not on a picture.
