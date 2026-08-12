# AGENTS.md — adding your own motherboard

This file is for whoever (human or AI assistant) is adapting this widget to a
new machine. `CLAUDE.md` is a symlink to it.

The widget already works on any machine with **zero configuration** — it falls
back to a grouped list of every component it can discover. A board picture is
purely a convenience layer on top. Read *Why there is no automatic layout*
before assuming a step can be skipped.

---

## If you are a human reading this

You do not have to do this by hand. This file is written for coding assistants,
and `CLAUDE.md` is symlinked to it so [Claude Code](https://claude.com/claude-code)
loads it automatically. Clone the repo, put a photo of your board somewhere, and
ask for a profile.

The work is mostly *reading* — silkscreen labels at 16× zoom, `dmidecode` output,
sysfs component IDs — and then measuring rectangles and checking them by
rendering the overlay back onto the picture. That is a good fit for an assistant
and a tedious afternoon for a person.

Two things to insist on, whoever does it:

1. **Render the overlay and look at it.** Not the JSON — the picture. Every
   rectangle must visibly land on the part it names.
2. **Mark inference as inference.** See *Confidence* below. A confidently wrong
   locator↔channel mapping sends someone to pull a healthy DIMM, which is the
   worst thing this project can do.

## Quick version

```sh
# 1. Make sure the collector has run, so a component list exists
sudo /usr/local/bin/dimm-mce-export --verbose

# 2. Get a picture of your board, PNG or GIF (see "Picture requirements")
#    then drag a box over each component you care about
./tools/calibrate.py ~/Desktop/my-board.png

# 3. Drop the profile + picture where the widget looks
mkdir -p ~/.local/share/dimm-mce-monitor/boards
cp my-board.png hewlett-packard-1234.json ~/.local/share/dimm-mce-monitor/boards/

# 4. Reload the widget (or just re-open the popup)
```

The profile filename must match your board's DMI identity — see *Naming*.

---

## Why there is no automatic layout

**Physical geometry is not in SMBIOS, at all.** There is no field for "where
this slot sits on the board". Specifically:

| What you want | Where it lives | Available? |
|---|---|---|
| Which DIMM slots / PCIe slots / ports exist | EDAC sysfs, `/sys/bus/pci/slots`, `/sys/class/*` | **Yes**, always |
| Slot names as silkscreened (`CPU0-DIMM1`) | SMBIOS type 17 `Locator` | Usually, but vendor-invented |
| Size / part / serial / link speed / temps | SMBIOS type 17, sysfs, hwmon | **Yes** |
| **X,Y position on the board** | *nowhere* | **No** |

SMBIOS type 20 (Memory Device Mapped Address) maps *address ranges* to devices,
not coordinates — and plenty of vendors emit none at all (the HP Z840 this was
written on emits **zero** type 20 structures).

There is also **no standard mapping from a DMI `Locator` to an EDAC channel**.
Anything that claims to know which silkscreened DIMM is "channel A" is guessing.
A wrong guess sends someone to pull the wrong stick, so guesses must be labelled
as such — see *Confidence*.

Hence: inventory is automatic, geometry is manual and shareable.

---

## Picture requirements

- **PNG or GIF** for `calibrate.py` (Tk reads only these). The *widget* also
  accepts WebP and JPEG, so you can convert after calibrating, as long as you
  keep `imageSize` correct.
- **Transparent background is ideal** — the widget draws it at reduced opacity
  over the panel background.
- **Straight-on shot.** A photo taken at an angle will have varying pitch
  between identical slots and every rectangle will be slightly wrong.
- Any resolution. Coordinates are stored normalised (0..1), so the picture can
  be rescaled later without redoing the profile — just update `imageSize`.
- Vendor service-manual diagrams work as well as photos, and are often
  *better*, because they are drawn orthographically and are already labelled.

---

## Naming

The widget auto-detects a profile from DMI identity. It tries, in order:

```
<package>/contents/boards/<slug>.json
~/.local/share/dimm-mce-monitor/boards/<slug>.json
```

...first with `<board_vendor>-<board_name>`, then with `<product_name>`. The
slug is lowercased with every run of non-alphanumerics collapsed to `-`.

Find yours:

```sh
cat /sys/class/dmi/id/board_vendor /sys/class/dmi/id/board_name /sys/class/dmi/id/product_name
```

`Hewlett-Packard` + `2129` → `hewlett-packard-2129.json`.

These are world-readable, so no root needed.

---

## Component IDs

A profile maps **component ID → rectangle**. IDs come from the collector; get
the real list for your machine with:

```sh
python3 -c "import json;[print(f\"{c['kind']:6} {c['id']:28} {c['label']}\") \
  for c in json.load(open('/run/dimm-mce/state.json'))['components']]"
```

| Kind | ID format | Notes |
|---|---|---|
| `dimm` | `dimm:s<socket>_ha<agent>_ch<channel>_d<slot>` | From EDAC. `ha` is the home agent; channel letter shown in the UI is `ch + 2*ha`. |
| `cpu` | `cpu:<socket>` | Carries package temperature. |
| `pcie` | `pcie:<slot>` | From `/sys/bus/pci/slots`. Base numbers usually match the silkscreen `SLOTn`; suffixed ones like `2-1` are downstream ports of a bridge **on** a card and are rarely worth placing. |
| `sata` | `sata:ata<n>` | Kernel ata port numbering **need not follow the silkscreen**. Verify before trusting. |
| `net` | `net:<ifname>` | Only physical interfaces; bridges/veths are filtered out. |
| `fan` | `fan:<chip>:<n>` | |
| `temp` | `temp:<chip>:<n>` | There are usually dozens (one per core). Placing them all is rarely useful. |

**You do not have to place everything.** Anything without a rectangle still
appears in the list view. Place what you would physically go and touch: memory
slots, expansion slots, ports, sockets.

---

## Profile format

```jsonc
{
  "id": "hewlett-packard-2129-photo",
  "name": "HP Z840 Workstation (photo)",
  "match": {                      // informational; matching is by filename
    "board_vendor": "Hewlett-Packard",
    "board_name": "2129",
    "product_name": "HP Z840 Workstation"
  },
  "image": "hewlett-packard-2129.webp",   // relative to the profile file
  "imageSize": [1358, 1200],              // MUST match the real pixel size
  "confidence": "derived",                // see below
  "notes": ["free text shown to whoever reads the profile"],

  "slots": {
    "dimm:s0_ha0_ch1_d0": {
      "rect": [0.5744, 0.4917, 0.3203, 0.0217],  // [x, y, w, h] normalised 0..1
      "label": "CPU0-DIMM2",                     // silkscreen name, shown on hover
      "kind": "dimm"
    }
  }
}
```

`rect` is normalised against `imageSize`, origin top-left. `label` should be
what is *printed on the board*, because that is what someone reads while
holding a screwdriver.

### Confidence

| Value | Meaning |
|---|---|
| `user-calibrated` | Placed by hand against a real picture. What `calibrate.py` writes. |
| `derived` | Positions or identities partly inferred. **The widget shows a visible caveat in the popup.** |

Use `derived` honestly. If you inferred which silkscreened DIMM maps to which
EDAC channel, that is `derived`, even if the rectangles are pixel-perfect.

---

## Verifying a profile

Rectangles being pretty is not the same as being *right*. Two checks worth doing:

1. **Render the overlay and look at it.** Draw every rect on the picture and
   confirm each lands on the component it names. Mis-set `imageSize` shows up
   immediately as a uniform offset or scale error.

2. **Pull one part and watch what changes.** Note a DIMM's serial from
   `sudo dmidecode -t 17`, remove it, reboot, and see which serial disappears
   and which EDAC key stops reporting. This is the only way to *prove* a
   locator↔channel mapping rather than infer it.

For memory specifically, there is a free discriminator: some ECC events name a
single DIMM exactly while others say `DIMM#0 or DIMM#1`. If one slot on a
channel has exact attributions and its neighbour only ever appears in ambiguous
pairs, the one with exact hits is your real suspect:

```sh
sudo sqlite3 /var/lib/rasdaemon/ras-mc_event.db \
  "select label, sum(err_count) from mc_event group by label order by 2 desc;"
```

---

## Adding a new component kind

If your hardware exposes something not covered (NVMe namespaces, GPUs, PSUs,
backplanes), add a producer in `collector/dimm-mce-export.py`:

1. Write a `*_components()` function returning `comp(...)` records.
2. Append it in `build_state()`.
3. Give it a stable, prefixed `id` (`psu:0`, not `0`).
4. Set `status` to one of `ok` / `warn` / `error` / `empty` / `unknown`.
5. Make `headline` **state what the number is**. `"3"` is useless; `"3 CRC
   errors"` is not. This is the single most important rule here — a hardware
   display that shows unlabelled integers trains people to ignore it.

The UI needs no changes: unknown kinds render generically and are grouped under
their raw kind name in the list.

---

## Drive health (SMART)

One `smartctl -H -A -i -n standby` call per drive per cycle. Three things are
deliberate:

- **`-n standby`.** Without it, polling wakes every idle disk once a minute,
  which is slow and bad for the drives. It also means a sleeping drive reports
  `standby` and no counters — that is *not* an error.
- **One call, not three.** Each invocation is another chance to wake a disk, so
  health, attributes and identity come from a single run.
- **Growth, not absolutes.** A counter static for years is an old scar; the same
  counter moving is an active fault. Baselines live in
  `/var/lib/dimm-mce/smart-baseline.json` (hence `StateDirectory=dimm-mce` in
  the unit — `ProtectSystem=strict` makes the rest of `/var/lib` read-only) and
  are keyed on **drive serial, never on `sdX`**. Device letters shuffle between
  boots; comparing `sdd`'s counters against what `sdc` reported last week would
  invent growth that never happened.

Alarms fire on: any pending / offline-uncorrectable / reported-uncorrectable
sector, *growth* in reallocated or interface-CRC counts, NVMe critical-warning
flags, NVMe spare at or below its floor, and endurance ≥ 90 % used. A drive with
old static counters stays `ok` with the numbers visible as metrics — otherwise
every older disk sits permanently in warning and the display becomes noise.

**PCIe slots report the drives behind them** (`disks_behind`). Any block device
whose sysfs path passes through a slot's PCI address is republished on that
slot, with serial and SMART verdict, and a sick drive pushes the slot to warn.
This makes NVMe carrier cards, HBAs and RAID controllers useful rather than an
opaque rectangle, and needs no board profile — it works from `/sys/bus/pci/slots`
alone. All addresses in a slot group are collected, so a bifurcated carrier
reports every drive on it, not just the one behind its first function.

Drives with no connector of their own are **drawn as bays on a card extending
out of their slot** (`SlotCard.qml`), each bay individually hoverable and
coloured by that drive's status. A drive that already has a connector rectangle
— anything reachable through an ATA port or a SAS PHY — is excluded, or the same
disk appears twice: once at its cable connector and again on the HBA's slot.
That test is `_has_connector` in `disk_components()`.

Set `"cardExtends": "left"` in a profile if the board is photographed with its
rear I/O edge on the right; the default is `"right"`.

**Connectors inherit the health of what is plugged into them** (`inherit_disk`).
Drives have no rectangle on a board picture, and the list view is hidden
whenever a board image exists, so without this a failing drive was invisible
while its port stayed green — the board map contradicting the tray icon. This is
why `disk_components()` is built *before* `sata_components()` /
`sasport_components()` in `build_state()`; that ordering is load-bearing.

## Module serial numbers

Drives carry their serial directly (from the same `smartctl` call).

**DIMMs cannot**, and the reason is structural: the collector knows EDAC keys,
SMBIOS knows silkscreen locators, and *nothing in firmware connects the two*.
The board profile is the only place that mapping exists. So the join happens in
the widget, which has both halves — `dmi_slots` from the snapshot and
`slots[key].label` from the profile. Any profile that labels its DIMM rectangles
with the DMI locator gets manufacturer, part, serial and rank for free, on any
board, with no collector change.

The consequence is honest labelling: on a `derived` profile the serial is only
as good as the inferred locator↔channel mapping, so it is shown as
"Serial (via inferred slot mapping)" rather than as fact. Do not remove that
qualifier without first *proving* the mapping by pulling a stick — see
*Verifying a profile*.

## Gotchas

- The paths and the applet ID still say `dimm-mce` / `dimmMceMonitor`. That is
  historical — this began as a DIMM-only ECC monitor. Renaming would orphan
  existing tray entries, so the names stayed.
- `Item` in QML already defines `state` **and** `baseline` as properties.
  Declaring your own with those names shadows or hard-fails with
  `Cannot override FINAL property`, which kills the whole applet silently.
- `Plasmoid.configuration` reads return `undefined` for ~250 ms after the applet
  is built. `Math.max(5, undefined)` is `NaN`, and a `Timer` with a `NaN`
  interval never fires again. Use the `cfgNum` / `cfgBool` / `cfgStr` helpers.
- QML `console.log` is swallowed unless `QT_ASSUME_STDERR_HAS_CONSOLE=1`.
- `plasmoidviewer` rewrites and sometimes deletes applet config sections. Do not
  trust it for testing anything config-dependent; use the real tray.
- `qml` on `PATH` may be Qt 5. The Qt 6 one is `/usr/lib64/qt6/bin/qml`.
- `RuntimeDirectory=` is deleted the instant a `oneshot` service exits. The unit
  needs `RuntimeDirectoryPreserve=yes` or the snapshot vanishes with it.
