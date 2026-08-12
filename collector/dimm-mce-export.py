#!/usr/bin/env python3
"""
Board health exporter - snapshot the state of every discoverable board component
to a world-readable JSON file.

Runs as root from a systemd timer. The Plasma widget only ever reads the JSON,
so the widget itself needs no privileges, no sudo rule and no polkit action.

Component kinds emitted: dimm, cpu, pcie, sata, disk, net, temp, fan.
Every component carries a stable `id`, a `status`, and a `headline` that states
what its number MEANS - a bare integer on a board diagram is useless.

Physical board geometry is deliberately NOT attempted here: it does not exist in
SMBIOS. This emits *logical* inventory; mapping it onto a picture of a board is
the widget's job, via an optional board profile. See AGENTS.md.

The file name is historical - this began life as a DIMM-only ECC monitor.
"""

import json
import os
import re
import sqlite3
import subprocess
import sys
import tempfile
from collections import defaultdict
from datetime import datetime, timedelta

RAS_DB = "/var/lib/rasdaemon/ras-mc_event.db"
EDAC_ROOT = "/sys/devices/system/edac/mc"
OUT_DIR = "/run/dimm-mce"
OUT_FILE = os.path.join(OUT_DIR, "state.json")

SCHEMA_VERSION = 2

LABEL_RE = re.compile(
    r"CPU_SrcID#(?P<socket>\d+)_Ha#(?P<ha>\d+)_Chan#(?P<chan>\d+)_DIMM#(?P<slot>\d+)"
)

# Interfaces that are not physical ports on this board.
VIRTUAL_NET_RE = re.compile(r"^(lo|docker|br-|veth|virbr|tap|tun|bond|dummy|vmnet)")

OK, WARN, ERROR, EMPTY, UNKNOWN = "ok", "warn", "error", "empty", "unknown"


def read(path, default=""):
    try:
        with open(path) as fh:
            return fh.read().strip()
    except OSError:
        return default


def read_int(path, default=None):
    v = read(path)
    try:
        return int(v)
    except (TypeError, ValueError):
        return default


def comp(cid, kind, label, status, headline, metrics=None, note=None,
         present=True, aliases=None):
    """
    `aliases` are alternative stable identifiers a board profile may key on.

    Interface names and PCI addresses both MOVE - changing BIOS bifurcation on
    this machine renumbered the bus and turned enp12s0 into enp6s0, silently
    unmapping it from the board picture. A profile should be able to key on
    something that survives that, such as the PCI vendor:device pair, which is
    also portable to another machine with the same board.
    """
    return {
        "id": cid, "kind": kind, "label": label, "status": status,
        "headline": headline, "metrics": metrics or [], "note": note,
        "present": present, "aliases": aliases or [],
    }


def metric(label, value, unit=""):
    return {"label": label, "value": value, "unit": unit}


# ============================================================ memory (ECC/MCE)

def slot_key(socket, ha, chan, slot):
    return f"s{socket}_ha{ha}_ch{chan}_d{slot}"


def parse_labels(label):
    """
    Every slot a rasdaemon label refers to.

    sb_edac cannot always resolve which of two DIMMs on a channel erred and
    emits 'A or B'. Attributing such an event to one stick would be a lie, so
    both are returned and the caller marks attribution ambiguous.
    """
    return [m.groupdict() for m in LABEL_RE.finditer(label or "")]


def read_edac():
    slots = {}
    if not os.path.isdir(EDAC_ROOT):
        return slots
    for mc in sorted(os.listdir(EDAC_ROOT)):
        mc_path = os.path.join(EDAC_ROOT, mc)
        if not mc.startswith("mc") or not os.path.isdir(mc_path):
            continue
        for dimm in sorted(os.listdir(mc_path)):
            if not dimm.startswith("dimm"):
                continue
            d = os.path.join(mc_path, dimm)
            label = read(os.path.join(d, "dimm_label"))
            parsed = parse_labels(label)
            if not parsed:
                continue
            p = parsed[0]
            key = slot_key(p["socket"], p["ha"], p["chan"], p["slot"])
            slots[key] = {
                "key": key,
                "socket": int(p["socket"]), "ha": int(p["ha"]),
                "channel": int(p["chan"]), "slot": int(p["slot"]),
                "edac_label": label, "edac_mc": mc, "edac_dimm": dimm,
                "mem_type": read(os.path.join(d, "dimm_mem_type")),
                "edac_mode": read(os.path.join(d, "dimm_edac_mode")),
                "size_mb": read_int(os.path.join(d, "size")),
                "ce_sysfs": read_int(os.path.join(d, "dimm_ce_count"), 0) or 0,
                "ue_sysfs": read_int(os.path.join(d, "dimm_ue_count"), 0) or 0,
            }
    return slots


def read_rasdaemon(now):
    """Aggregate the persistent DB into per-slot windowed ECC counts."""
    if not os.path.exists(RAS_DB):
        return None, "rasdaemon database not present - ECC history will not survive reboots"
    try:
        con = sqlite3.connect(f"file:{RAS_DB}?mode=ro", uri=True, timeout=5)
    except sqlite3.Error as e:
        return None, f"cannot open rasdaemon database: {e}"

    def iso(dt):
        return dt.strftime("%Y-%m-%d %H:%M:%S")

    windows = {
        "ce_24h": iso(now - timedelta(days=1)),
        "ce_7d": iso(now - timedelta(days=7)),
        "ce_30d": iso(now - timedelta(days=30)),
    }
    per_slot = defaultdict(lambda: {
        "ce_total": 0, "ue_total": 0, "ce_24h": 0, "ce_7d": 0, "ce_30d": 0,
        "last_error": None, "ambiguous_events": 0, "exact_events": 0,
        # Split by whether the controller named this stick ALONE. A slot with
        # zero proven errors is only implicated because it shares a channel
        # with the real culprit - showing it as faulty invents a second bad
        # module out of nothing.
        "ce_proven": 0, "ce_shared": 0,
    })
    daily = defaultdict(int)
    # Event-based totals: an ambiguous event is added to BOTH slots, so summing
    # per-slot figures would double-count. These count each event exactly once.
    true_totals = {"ce": 0, "ue": 0, "ce_24h": 0, "ce_7d": 0, "ce_30d": 0}
    try:
        for ts, count, err_type, label in con.execute(
                "SELECT timestamp, err_count, err_type, label FROM mc_event"):
            count = count or 0
            targets = parse_labels(label)
            corrected = (err_type or "").lower().startswith("corrected")
            if ts:
                daily[ts[:10]] += count
            if corrected:
                true_totals["ce"] += count
                for w, cut in windows.items():
                    if ts and ts >= cut:
                        true_totals[w] += count
            else:
                true_totals["ue"] += count
            for t in targets:
                rec = per_slot[slot_key(t["socket"], t["ha"], t["chan"], t["slot"])]
                if corrected:
                    rec["ce_total"] += count
                    for w, cut in windows.items():
                        if ts and ts >= cut:
                            rec[w] += count
                else:
                    rec["ue_total"] += count
                if len(targets) > 1:
                    rec["ambiguous_events"] += 1
                    if corrected:
                        rec["ce_shared"] += count
                else:
                    rec["exact_events"] += 1
                    if corrected:
                        rec["ce_proven"] += count
                if ts and (rec["last_error"] is None or ts > rec["last_error"]):
                    rec["last_error"] = ts
    except sqlite3.Error as e:
        con.close()
        return None, f"rasdaemon query failed: {e}"
    con.close()
    return {
        "per_slot": dict(per_slot),
        "history": [{"day": d, "ce": c} for d, c in sorted(daily.items())][-90:],
        "true_totals": true_totals,
    }, None


def neighbour_name(edac, me):
    """The other module on the same channel, which shares its ambiguous errors."""
    for o in edac.values():
        if (o["socket"] == me["socket"] and o["ha"] == me["ha"]
                and o["channel"] == me["channel"] and o["slot"] != me["slot"]):
            ch = chr(ord("A") + o["channel"] + 2 * o["ha"])
            return f"CPU{o['socket']} channel {ch} slot {o['slot']}"
    return None


def dimm_components(edac, ras):
    out = []
    for key, s in sorted(edac.items(), key=lambda kv: (
            kv[1]["socket"], kv[1]["ha"], kv[1]["channel"], kv[1]["slot"])):
        r = (ras or {}).get("per_slot", {}).get(key, {})
        ce_total = r.get("ce_total", s["ce_sysfs"])
        ue_total = r.get("ue_total", s["ue_sysfs"])
        ce_30d, ce_24h = r.get("ce_30d", 0), r.get("ce_24h", 0)
        ambiguous = r.get("exact_events", 0) == 0 and r.get("ambiguous_events", 0) > 0

        gb = round(s["size_mb"] / 1024) if s["size_mb"] else None
        ch = chr(ord("A") + s["channel"] + 2 * s["ha"])
        label = f"CPU{s['socket']} channel {ch} slot {s['slot']}"

        proven = r.get("ce_proven", 0)
        shared = r.get("ce_shared", 0)
        neighbour = neighbour_name(edac, s)

        if ue_total:
            status, headline = ERROR, f"{ue_total} UNCORRECTABLE ECC errors"
        elif proven == 0 and shared > 0:
            # Implicated only by association. Deliberately NOT warn/error: a
            # colour that says "faulty" here would manufacture a second bad
            # DIMM per channel and send someone to replace a healthy stick.
            status = UNKNOWN
            headline = "no errors of its own"
        elif ce_30d > 100:
            status, headline = ERROR, f"{ce_30d} ECC errors (30 days)"
        elif ce_30d > 0:
            status, headline = WARN, f"{ce_30d} ECC errors (30 days)"
        elif ce_total > 0:
            status, headline = OK, f"{ce_total} ECC errors (all historical)"
        else:
            status, headline = OK, "No ECC errors"

        metrics = [
            metric("ECC errors proven to be THIS module", proven),
            metric("ECC errors shared with its channel neighbour", shared),
            metric("Corrected ECC errors, last 24h", ce_24h),
            metric("Corrected ECC errors, last 30 days", ce_30d),
            metric("Uncorrectable ECC errors", ue_total),
        ]
        if gb:
            metrics.insert(0, metric("Module", f"{gb} GB {s['mem_type']}"))
        if r.get("last_error"):
            metrics.append(metric("Most recent error", r["last_error"]))

        note = None
        if proven == 0 and shared > 0:
            note = (f"This module has NEVER been named on its own. All {shared} "
                    f"errors were logged as \"this module or its neighbour\", "
                    f"because the memory controller cannot tell the two modules "
                    f"on a channel apart.")
            if neighbour:
                note += (f" {neighbour} shares this channel and HAS been named "
                         f"individually, so the evidence points at that one, "
                         f"not this one. Replacing this module would most "
                         f"likely change nothing.")
        elif proven and shared:
            note = (f"{proven} errors name this module specifically; a further "
                    f"{shared} could not be told apart from its channel "
                    f"neighbour. The proven count is what implicates it.")

        c = comp(f"dimm:{key}", "dimm", label, status, headline, metrics, note)
        c.update({
            "socket": s["socket"], "ha": s["ha"], "channel": s["channel"],
            "slot": s["slot"], "edac_label": s["edac_label"],
            "ce_total": ce_total, "ue_total": ue_total,
            "ce_30d": ce_30d, "ce_24h": ce_24h,
            "ce_7d": r.get("ce_7d", 0),
            "last_error": r.get("last_error"),
            "attribution_ambiguous": ambiguous,
            "size_mb": s["size_mb"],
        })
        out.append(c)
    return out


# ================================================================ hwmon: temp/fan

def hwmon_components():
    temps, fans = [], []
    root = "/sys/class/hwmon"
    if not os.path.isdir(root):
        return temps, fans
    for h in sorted(os.listdir(root)):
        base = os.path.join(root, h)
        chip = read(os.path.join(base, "name")) or h
        try:
            entries = os.listdir(base)
        except OSError:
            continue

        for f in sorted(entries):
            m = re.fullmatch(r"temp(\d+)_input", f)
            if m:
                n = m.group(1)
                raw = read_int(os.path.join(base, f))
                if raw is None:
                    continue
                c = raw / 1000.0
                name = read(os.path.join(base, f"temp{n}_label")) or f"{chip} temp {n}"
                crit = read_int(os.path.join(base, f"temp{n}_crit"))
                mx = read_int(os.path.join(base, f"temp{n}_max"))
                crit_c = crit / 1000.0 if crit else None
                max_c = mx / 1000.0 if mx else None

                status = OK
                if crit_c and c >= crit_c:
                    status = ERROR
                elif crit_c and c >= crit_c - 5:
                    status = WARN
                elif max_c and c >= max_c:
                    status = WARN

                mets = [metric("Temperature", f"{c:.0f}", "°C")]
                if max_c:
                    mets.append(metric("High threshold", f"{max_c:.0f}", "°C"))
                if crit_c:
                    mets.append(metric("Critical threshold", f"{crit_c:.0f}", "°C"))
                temps.append(comp(f"temp:{chip}:{n}", "temp", name, status,
                                  f"{c:.0f} °C", mets))
                continue

            m = re.fullmatch(r"fan(\d+)_input", f)
            if m:
                n = m.group(1)
                rpm = read_int(os.path.join(base, f))
                if rpm is None:
                    continue
                name = read(os.path.join(base, f"fan{n}_label")) or f"{chip} fan {n}"
                # Peer comparison happens after the walk, once every fan is
                # known - a single RPM number in isolation says nothing about
                # health, but "half the speed of its four siblings" does.
                fans.append(comp(f"fan:{chip}:{n}", "fan", name, OK,
                                 f"{rpm} RPM",
                                 [metric("Speed", rpm, "RPM")]))
                fans[-1]["_rpm"] = rpm
    return temps, grade_fans(fans)


def fan_peer_group(label):
    """
    Fans that should behave alike, e.g. 'Memory Fan0'..'Memory Fan3' -> 'Memory Fan'
    and 'CPU0 Fan'/'CPU1 Fan' -> 'CPU Fan'.

    Digits are stripped wherever they appear, not just at the end: HP puts the
    index in the middle ('CPU0 Fan'), so a trailing-only rule left every CPU fan
    in a group of one and silently disabled the comparison for exactly the fans
    most worth comparing.
    """
    return re.sub(r"\s+", " ", re.sub(r"\d+", "", label or "")).strip() or "fan"


def grade_fans(fans):
    """
    Judge each fan against its own siblings rather than an absolute threshold.

    Absolute RPM limits are useless across boards - 700 RPM is healthy for a
    memory fan and alarming for a 40mm chassis fan. But a fan running at a
    fraction of what its identical siblings manage is worth flagging on any
    machine, and it is exactly how a seizing bearing first shows up.
    """
    groups = defaultdict(list)
    for f in fans:
        groups[fan_peer_group(f["label"])].append(f)

    for gname, members in groups.items():
        speeds = [m["_rpm"] for m in members]
        peak = max(speeds) if speeds else 0
        spinning = [v for v in speeds if v > 0]
        for m in members:
            rpm = m.pop("_rpm")
            if rpm == 0:
                m["status"] = WARN
                m["headline"] = "not spinning"
                m["note"] = ("Reads 0 RPM. Either nothing is plugged into this "
                             "header, or the fan has stopped - the sensor "
                             "cannot tell those apart.")
                continue
            if len(members) > 1:
                m["metrics"].append(metric(f"Fastest '{gname}'", peak, "RPM"))
                m["metrics"].append(
                    metric("Share of fastest sibling", f"{rpm * 100 // peak}%"))
            # Only flag against siblings that are actually turning, and only
            # when the group is genuinely spinning, so an all-idle bank of fans
            # never lights up.
            if len(spinning) > 1 and peak > 300 and rpm < peak * 0.5:
                m["status"] = WARN
                m["headline"] = f"{rpm} RPM — about half its siblings"
                m["note"] = (f"This fan is running at {rpm * 100 // peak}% of "
                             f"the fastest '{gname}' ({peak} RPM). Fans in one "
                             f"group normally track each other, so a persistent "
                             f"gap suggests a failing bearing, a blocked intake, "
                             f"or a fan the firmware has stopped driving.")
    return fans


def cpu_components(temps):
    """One entry per physical socket, carrying its package temperature."""
    out = []
    sockets = {}
    for line in read("/proc/cpuinfo").splitlines():
        if line.startswith("physical id"):
            sockets.setdefault(line.split(":")[1].strip(), 0)
        if line.startswith("processor"):
            pass
    counts = defaultdict(int)
    cur = None
    for line in read("/proc/cpuinfo").splitlines():
        if line.startswith("physical id"):
            cur = line.split(":")[1].strip()
        elif line.startswith("core id") and cur is not None:
            counts[cur] += 1
    model = ""
    for line in read("/proc/cpuinfo").splitlines():
        if line.startswith("model name"):
            model = line.split(":", 1)[1].strip()
            break

    for sock in sorted(sockets or {"0": 0}):
        pkg = next((t for t in temps
                    if t["label"].lower() in (f"package id {sock}",
                                              f"cpu{sock} temperature")), None)
        status = pkg["status"] if pkg else UNKNOWN
        headline = pkg["headline"] if pkg else "present"
        mets = [metric("Model", model)] if model else []
        mets.append(metric("Threads", counts.get(sock, 0)))
        if pkg:
            mets.extend(pkg["metrics"])
        out.append(comp(f"cpu:{sock}", "cpu", f"CPU socket {sock}",
                        status, headline, mets))
    return out


# ========================================================================= PCIe

def lspci_names():
    names = {}
    try:
        out = subprocess.run(["lspci", "-mm"], capture_output=True, text=True,
                             timeout=15, check=True).stdout
    except (subprocess.SubprocessError, FileNotFoundError, OSError):
        return names
    for line in out.splitlines():
        parts = re.findall(r'"([^"]*)"|(\S+)', line)
        flat = [a or b for a, b in parts]
        if len(flat) >= 4:
            names["0000:" + flat[0]] = f"{flat[2]} {flat[3]}".strip()
    return names


def aer_counts(dev_path):
    """Correctable and fatal/non-fatal AER totals for one device."""
    cor = fat = nonfat = 0
    for fname, acc in (("aer_dev_correctable", "cor"),
                       ("aer_dev_fatal", "fat"),
                       ("aer_dev_nonfatal", "nonfat")):
        txt = read(os.path.join(dev_path, fname))
        total = 0
        for line in txt.splitlines():
            bits = line.split()
            if len(bits) == 2 and bits[1].isdigit():
                total += int(bits[1])
        if acc == "cor":
            cor = total
        elif acc == "fat":
            fat = total
        else:
            nonfat = total
    return cor, fat, nonfat


def pcie_components(names, disks=None):
    """
    One component per PHYSICAL slot.

    Firmware exposes a physical connector as a base entry (`6`) plus sub-entries
    (`6-1`, `6-2`...) for devices behind a bridge on the card. The base address
    frequently has no device of its own - on this board SLOT6 reads empty at
    0000:03:00 while the Quadro GV100 actually sits at 0000:04:00 = slot `6-1`.
    Reporting the base alone therefore showed occupied slots as empty. So group
    by base number and take the first sub-entry that has a real device.
    """
    out = []
    slots_root = "/sys/bus/pci/slots"
    if not os.path.isdir(slots_root):
        return out

    groups = defaultdict(list)
    for name in os.listdir(slots_root):
        groups[name.split("-")[0]].append(name)

    def sort_key(base):
        return (0, int(base)) if base.isdigit() else (1, base)

    for base in sorted(groups, key=sort_key):
        # Base entry first, then sub-entries in order.
        members = sorted(groups[base],
                         key=lambda n: (len(n), n))
        member_addrs = [a for a in
                        (read(os.path.join(slots_root, n, "address")) for n in members)
                        if a]
        dev = dpath = None
        for addr in member_addrs:
            cand = f"{addr}.0"
            cpath = f"/sys/bus/pci/devices/{cand}"
            if os.path.isdir(cpath):
                dev, dpath = cand, cpath
                break
        slot = base
        if dpath is None:
            out.append(comp(f"pcie:{slot}", "pcie", f"PCIe slot {slot}",
                            EMPTY, "empty", [], None, present=False))
            continue

        # The parent root port's capability is what distinguishes "the platform
        # only gave this slot N lanes" (bifurcation / board wiring — reseating
        # cannot help) from "both ends can do more but the link trained low"
        # (physical layer: seating, contacts, a riser).
        parent = os.path.dirname(os.path.realpath(dpath))
        parent_max_w = read_int(os.path.join(parent, "max_link_width"))

        cur_speed = read(os.path.join(dpath, "current_link_speed"))
        cur_width = read(os.path.join(dpath, "current_link_width"))
        max_speed = read(os.path.join(dpath, "max_link_speed"))
        max_width = read(os.path.join(dpath, "max_link_width"))
        name = names.get(dev, read(os.path.join(dpath, "class")) or "device")
        cor, fat, nonfat = aer_counts(dpath)

        mets = [metric("Device", name),
                metric("Address", dev),
                metric("Link speed", f"{cur_speed} (max {max_speed})"),
                metric("Link width", f"x{cur_width} (max x{max_width})")]
        if cor or fat or nonfat:
            mets.append(metric("PCIe corrected errors", cor))
            mets.append(metric("PCIe uncorrectable errors", fat + nonfat))

        status, headline, note = OK, name, None
        if fat + nonfat:
            status = ERROR
            headline = f"{fat + nonfat} uncorrectable PCIe errors"
        elif cor > 1000:
            status = WARN
            headline = f"{cor} corrected PCIe errors"
        elif (cur_width.isdigit() and max_width.isdigit()
              and int(cur_width) < int(max_width)):
            status = WARN
            headline = f"running at x{cur_width} of x{max_width}"
            if parent_max_w and parent_max_w < int(max_width):
                mets.append(metric("Lanes offered by the slot", f"x{parent_max_w}"))
                note = (f"The card can do x{max_width} but this slot only "
                        f"offers x{parent_max_w}. That is set by board wiring "
                        f"or BIOS lane bifurcation, so reseating will not "
                        f"change it — move the card to a wider slot or fix the "
                        f"bifurcation setting.")
            else:
                note = (f"Both the card and the slot support x{max_width}, yet "
                        f"the link trained at x{cur_width}. That is a physical "
                        f"layer problem, not a configuration one: reseat the "
                        f"card firmly, check for dirty contacts or a riser. "
                        f"Note some GPUs narrow the link while idle — confirm "
                        f"it persists under load before opening the case.")

        # Anything storage-shaped sitting behind this slot. Keeps NVMe carrier
        # cards, HBAs and RAID controllers from being an opaque rectangle: the
        # slot reports the drives it is responsible for, and goes yellow if one
        # of them is sick. Entirely generic - no board profile needed.
        behind = disks_behind(disks, member_addrs)
        for d in behind:
            # Short label: the row can elide, and "Drive on this card:
            # /dev/nvme0n1" elides to "Drive on thi..." - hiding the one part
            # that identifies which drive the following rows describe.
            mets.append(metric(f"Drive {d['label'].replace('/dev/', '')}",
                               d["headline"]))
            mets += [m for m in (d.get("_detail") or [])
                     if m["label"] in ("Serial", "SMART self-assessment")]
        # Structured too, so a UI can draw one marker per drive and let the
        # pointer reach the individual drive rather than only the slot total.
        slot_drives = [{"id": d["id"], "label": d["label"],
                        "status": d["status"], "headline": d["headline"]}
                       for d in behind]
        worst = worst_status([d["status"] for d in behind])
        if worst in (WARN, ERROR) and status == OK:
            status = worst
            sick = [d for d in behind if d["status"] == worst]
            headline = f"{name}: {sick[0]['headline']}" if sick else name

        c = comp(f"pcie:{slot}", "pcie", f"PCIe slot {slot}",
                 status, headline, mets, note)
        c["drives"] = slot_drives
        out.append(c)
    return out


def disks_behind(disks, addrs):
    """Disk components whose sysfs path passes through any of `addrs`."""
    if not disks or not addrs:
        return []
    want = set(addrs)
    hits = []
    for d in disks.values():
        if d.get("_has_connector"):
            continue
        for a in d.get("_pci_path") or []:
            if a in want or a.rsplit(".", 1)[0] in want:
                hits.append(d)
                break
    return sorted(hits, key=lambda d: d["label"])


def worst_status(states):
    for s in (ERROR, WARN, UNKNOWN):
        if s in states:
            return s
    return OK


# ================================================================ SATA and disks

def block_by_ata():
    """Map ataN -> list of (block device, model, size)."""
    out = defaultdict(list)
    for blk in sorted(os.listdir("/sys/block")):
        dev = f"/sys/block/{blk}/device"
        if not os.path.exists(dev):
            continue
        real = os.path.realpath(dev)
        m = re.search(r"/ata(\d+)/", real)
        if not m:
            continue
        size = read_int(f"/sys/block/{blk}/size", 0) or 0
        out[m.group(1)].append({
            "name": blk,
            "model": read(f"/sys/block/{blk}/device/model"),
            "gb": round(size * 512 / 1e9),
        })
    return out



# ---------------------------------------------------------------- storage ports
#
# A board has PHYSICALLY DISTINCT connector blocks, and conflating them was the
# bug this replaced. On the HP Z840 the blocks are, per the service diagram:
#
#   callout 13  SAS/SATA 6Gb/s   8 connectors, driven by the LSI SAS HBA
#   callout 15  sSATA 6Gb/s      4 grey connectors,  silkscreened sSATA0..sSATA3
#   callout 14  SATA 6Gb/s       2 black connectors, silkscreened SATA0..SATA1
#
# The grouping matches Intel's function names: the C610 exposes a 4-port sSATA
# function (00:11.4) and a 6-port SATA function (00:1f.2) of which HP wires 2.
#
# Two traps remain:
#
#  1. Kernel ata port numbers are global across both controllers and start at 1,
#     while silkscreen numbers restart at 0 within each block: ata1..ata4 are
#     sSATA0..3, ata5..ata6 are SATA0..1. Never print the kernel number as a
#     connector name.
#  2. The silkscreen numbers run RIGHT TO LEFT in the board photo, so sSATA0 is
#     the rightmost of its block. That ordering lives in the profile rectangles.
#
# The silkscreen 's' prefix is one pixel wide at this photo's resolution and is
# easy to lose: reading it wrong swaps the two group names and puts the optical
# drive under the wrong heading. Zoom to 16x before trusting it, or take the
# grouping from the service diagram's callouts.
#
# A board without an entry here falls back to the lspci wording, which is the
# best guess available when nobody has read the silkscreen.

# PCI function -> (group id, silkscreen prefix)
SATA_CONTROLLERS = {
    "0000:00:11.4": ("ssata", "sSATA"),   # 4 grey connectors
    "0000:00:1f.2": ("sata", "SATA"),     # 2 black connectors
}


def ahci_port_masks():
    """
    PCI address -> bitmask of AHCI ports the BOARD actually wired.

    libata fabricates a dummy ata_port for every unimplemented port, so
    /sys/class/ata_port over-reports: this machine's PCH SATA function offers 6
    ports, HP wired 2, and sysfs shows 4. Those phantoms rendered as empty
    connectors that do not physically exist, which is worse than showing
    nothing - someone goes looking for a port that was never on the board.

    The Ports Implemented register lives in MMIO (BAR5+0x0C), not config space,
    so it is not reachable through setpci. The kernel prints it at probe time,
    which is the cheapest reliable source. If the message has aged out of the
    ring buffer we fall back to emitting everything, i.e. the old behaviour.
    """
    masks = {}
    try:
        r = subprocess.run(["dmesg"], capture_output=True, text=True, timeout=10)
        text = r.stdout
    except (subprocess.SubprocessError, FileNotFoundError, OSError):
        return masks
    for m in re.finditer(
            r"ahci (0000:[0-9a-f]{2}:[0-9a-f]{2}\.\d): .*?port mask (0x[0-9a-f]+)",
            text):
        masks[m.group(1)] = int(m.group(2), 16)
    return masks


def ata_controller(port):
    """PCI address of the controller behind an ata port, via its sysfs path."""
    real = os.path.realpath(f"/sys/class/ata_port/{port}")
    found = ""
    for part in real.split("/"):
        if re.fullmatch(r"0000:[0-9a-f]{2}:[0-9a-f]{2}\.\d", part):
            found = part
    return found


def sata_components(disks=None):
    """
    One component per PCH connector, grouped and numbered the way the board is
    labelled rather than the way the kernel enumerates.
    """
    out = []
    root = "/sys/class/ata_port"
    if not os.path.isdir(root):
        return out
    mapping = block_by_ata()

    # Bucket ports by controller, preserving kernel order within each.
    buckets = {}
    for port in sorted(os.listdir(root),
                       key=lambda s: int(re.sub(r"\D", "", s) or 0)):
        pci = ata_controller(port)
        group, name = SATA_CONTROLLERS.get(pci, ("sata", "SATA"))
        buckets.setdefault((group, name), []).append(port)

    masks = ahci_port_masks()
    for (group, name), ports in buckets.items():
        mask = masks.get(ata_controller(ports[0])) if ports else None
        for idx, port in enumerate(ports):
            # Skip connectors the board never wired - see ahci_port_masks().
            if mask is not None and not (mask >> idx) & 1:
                continue
            n = re.sub(r"\D", "", port)
            cid = f"{group}:{idx}"
            label = f"{name}{idx}"
            # Old profiles keyed on the kernel port; keep them working.
            aliases = [f"sata:{port}"]
            spd = read(f"/sys/class/ata_link/link{n}/sata_spd")
            devs = mapping.get(n, [])

            mets = [metric("Connector", label),
                    metric("Controller", f"{name} ({ata_controller(port)})"),
                    metric("Kernel ATA port", port)]
            if spd and spd != "<unknown>":
                mets.append(metric("Link speed", spd))

            if not devs:
                # No link is the normal state for an unused connector; it is
                # NOT an error, and it does not prove the cable is absent - the
                # kernel can only see a negotiated link, never a plugged cable.
                out.append(comp(cid, "sata", f"{name} port {idx}",
                                EMPTY, "no device attached", mets,
                                "The connector may still have a cable in it. "
                                "Only a drive that answers shows up here.",
                                present=False, aliases=aliases))
                continue

            d = devs[0]
            mets = [metric("Device", f"/dev/{d['name']}"),
                    metric("Model", d["model"]),
                    metric("Capacity", d["gb"], "GB")] + mets
            st, head, dnote = inherit_disk(disks, d["name"],
                                           d["model"] or d["name"])
            mets = disk_detail(disks, d["name"],
                               skip=("Model", "Capacity")) + mets
            out.append(comp(cid, "sata", f"{name} port {idx}",
                            st, head, mets, dnote, aliases=aliases))
    return out


def disk_detail(disks, blk, skip=()):
    """
    SMART/identity metrics of the attached drive, for a port to repeat.

    `skip` drops labels the caller already prints, so a connector does not show
    Model twice.
    """
    d = (disks or {}).get(blk)
    if not d:
        return []
    return [m for m in (d.get("_detail") or []) if m["label"] not in skip]


def inherit_disk(disks, blk, default_headline):
    """
    A connector reports the health of whatever is plugged into it.

    Without this a drive failing SMART showed as a red entry nobody could see -
    drives have no rectangle on the board picture - while the connector it sits
    on stayed green, because "a device is attached" was the only thing the port
    looked at. The board map contradicted the tray icon.
    """
    d = (disks or {}).get(blk)
    if not d or d["status"] == OK:
        return OK, default_headline, None
    return d["status"], d["headline"], d.get("note")


def sasport_components(disks=None):
    """
    One component per PHY on a SAS HBA - these are the wide-connector ports the
    board silkscreens SAS0..7.

    A SAS PHY is strictly better evidence than a block device: it reports a
    negotiated link rate whether or not the attached device is a disk, so an
    unpopulated connector is distinguishable from a populated one that failed
    to enumerate.
    """
    out = []
    root = "/sys/class/sas_phy"
    if not os.path.isdir(root):
        return out

    # end_device-H:P -> block device name, so a PHY can name its disk.
    by_phy = {}
    for blk in os.listdir("/sys/block"):
        real = os.path.realpath(f"/sys/block/{blk}/device")
        m = re.search(r"/end_device-(\d+):(\d+)/", real)
        if m:
            by_phy[(m.group(1), m.group(2))] = blk

    for phy in sorted(os.listdir(root),
                      key=lambda s: [int(x) for x in re.findall(r"\d+", s)]):
        m = re.match(r"phy-(\d+):(\d+)$", phy)
        if not m:
            continue
        host, num = m.group(1), m.group(2)
        rate = read(f"{root}/{phy}/negotiated_linkrate")
        enabled = read(f"{root}/{phy}/enable") == "1"
        blk = by_phy.get((host, num))

        mets = [metric("Connector", f"SAS{num}"),
                metric("PHY", phy),
                metric("Enabled", "yes" if enabled else "no"),
                metric("Negotiated link rate", rate or "unknown")]

        linked = bool(rate) and rate.lower() not in ("unknown", "failed",
                                                     "disabled", "phy reset problem")
        if blk:
            sectors = read_int(f"/sys/block/{blk}/size", 0) or 0
            model = read(f"/sys/block/{blk}/device/model") or blk
            mets = [metric("Device", f"/dev/{blk}"),
                    metric("Model", model),
                    metric("Capacity", round(sectors * 512 / 1e9), "GB")] + mets
            st, head, dnote = inherit_disk(disks, blk, model)
            mets = disk_detail(disks, blk, skip=("Model", "Capacity")) + mets
            out.append(comp(f"sasport:{num}", "sata", f"SAS port {num}",
                            st, head, mets, dnote,
                            aliases=[f"sasport:phy:{phy}"]))
        elif linked:
            # Link is up but nothing enumerated - that IS worth flagging.
            out.append(comp(f"sasport:{num}", "sata", f"SAS port {num}",
                            WARN, f"link up at {rate}, no device",
                            mets, "The PHY negotiated a link but no block "
                                  "device appeared. Suspect the drive, not the "
                                  "cable.",
                            aliases=[f"sasport:phy:{phy}"]))
        else:
            out.append(comp(f"sasport:{num}", "sata", f"SAS port {num}",
                            EMPTY, "no link", mets,
                            "No PHY link. A cable may still be plugged in with "
                            "nothing powered on the far end - the HBA cannot "
                            "tell those apart.",
                            present=False, aliases=[f"sasport:phy:{phy}"]))
    return out



# ========================================================================= disks

SMART_STATE = "/var/lib/dimm-mce/smart-baseline.json"

# ATA attribute id -> internal key. Only counters worth acting on; a full dump
# would be noise. 197/198/187 are the ones that mean "data is at risk NOW".
ATA_ATTRS = {
    5:   "reallocated",
    187: "reported_uncorrect",
    197: "pending",
    198: "offline_uncorrectable",
    199: "crc",
    177: "wear_leveling",
    233: "ssd_life_left",
}


def parse_smart(txt):
    """
    Pull the health verdict and the counters worth watching out of one
    `smartctl -H -A -i` run, for both ATA and NVMe output shapes.
    """
    out = {"health": None, "serial": None, "attrs": {}}
    if "STANDBY" in txt.upper() or "device is in" in txt.lower():
        out["health"] = "standby"
        return out

    for line in txt.splitlines():
        low = line.lower().strip()

        if "self-assessment test result" in low or "smart health status" in low:
            out["health"] = line.split(":")[-1].strip() or None
        elif low.startswith("serial number"):
            out["serial"] = line.split(":")[-1].strip()

        # NVMe health log. Values carry a '%' or thousands separators.
        elif low.startswith("percentage used"):
            out["attrs"]["nvme_used_pct"] = int_or_none(line.split(":")[-1])
        elif low.startswith("available spare:"):
            out["attrs"]["nvme_spare_pct"] = int_or_none(line.split(":")[-1])
        elif low.startswith("available spare threshold"):
            out["attrs"]["nvme_spare_min"] = int_or_none(line.split(":")[-1])
        elif low.startswith("media and data integrity errors"):
            out["attrs"]["nvme_media_errors"] = int_or_none(line.split(":")[-1])
        elif low.startswith("critical warning"):
            v = line.split(":")[-1].strip()
            try:
                out["attrs"]["nvme_critical"] = int(v, 16 if "x" in v else 10)
            except ValueError:
                pass

        else:
            # ATA attribute table row. RAW_VALUE is the last field and may be a
            # composite like "0/182412741" (Seagate rate counters), where only
            # the part before the slash is the event count.
            m = re.match(r"^\s*(\d+)\s+\S+\s+0x[0-9a-f]{4}\s+.*?(\S+)\s*$", line)
            if not m:
                continue
            aid = int(m.group(1))
            if aid not in ATA_ATTRS:
                continue
            raw = m.group(2).split("/")[0].replace(",", "")
            try:
                out["attrs"][ATA_ATTRS[aid]] = int(raw)
            except ValueError:
                pass
    return out


def int_or_none(s):
    m = re.search(r"-?\d[\d,]*", s or "")
    return int(m.group(0).replace(",", "")) if m else None


def smart_probe(dev):
    """
    One smartctl call per drive for verdict, identity and counters.

    `-n standby` is important: without it this would spin up every idle drive
    once a minute, which is both slow and actively bad for the disks. Combining
    -H/-A/-i into a single invocation matters for the same reason - three calls
    would be three chances to wake a sleeping disk.
    """
    try:
        r = subprocess.run(
            ["smartctl", "-H", "-A", "-i", "-n", "standby", f"/dev/{dev}"],
            capture_output=True, text=True, timeout=15)
    except (subprocess.SubprocessError, FileNotFoundError, OSError):
        return {"health": None, "serial": None, "attrs": {}}
    return parse_smart(r.stdout)


def load_baseline():
    try:
        with open(SMART_STATE) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def save_baseline(data):
    try:
        os.makedirs(os.path.dirname(SMART_STATE), exist_ok=True)
        tmp = SMART_STATE + ".tmp"
        with open(tmp, "w") as fh:
            json.dump(data, fh)
        os.replace(tmp, SMART_STATE)
    except OSError:
        pass          # Read-only /var/lib just means no growth detection.


def smart_verdict(attrs, base, rotational):
    """
    Turn counters into a status, a headline and the metrics behind them.

    The distinction that matters: a counter that has been static for years is
    a scar, while the same counter moving this week is an active fault. Both
    are reported, but only movement raises an alarm - otherwise every older
    drive sits permanently in warning and the display becomes noise.
    """
    status, reasons, mets = OK, [], []
    grew = {}
    for k, v in attrs.items():
        b = (base or {}).get(k)
        if isinstance(b, int) and isinstance(v, int) and v > b:
            grew[k] = v - b

    def note(label, key, unit=""):
        if attrs.get(key) is not None:
            d = grew.get(key)
            mets.append(metric(label + (f"  (+{d} since first seen)" if d else ""),
                               attrs[key], unit))

    # Unambiguously bad right now, whether or not they moved.
    if attrs.get("pending"):
        status = WARN
        reasons.append(f"{attrs['pending']} sectors pending reallocation")
    if attrs.get("offline_uncorrectable"):
        status = WARN
        reasons.append(f"{attrs['offline_uncorrectable']} uncorrectable sectors")
    if attrs.get("reported_uncorrect"):
        status = WARN
        reasons.append(f"{attrs['reported_uncorrect']} uncorrectable errors reported")

    # Movement since the first time this drive was seen.
    if grew.get("reallocated"):
        status = WARN
        reasons.append(f"{grew['reallocated']} new reallocated sectors")
    if grew.get("crc"):
        status = WARN
        reasons.append(f"{grew['crc']} new interface CRC errors (suspect the cable)")
    if grew.get("nvme_media_errors"):
        status = WARN
        reasons.append(f"{grew['nvme_media_errors']} new media integrity errors")

    # NVMe wear and controller-declared trouble.
    if attrs.get("nvme_critical"):
        status = ERROR
        reasons.append(f"NVMe critical warning flags 0x{attrs['nvme_critical']:02x}")
    if attrs.get("nvme_media_errors") and not grew.get("nvme_media_errors"):
        status = WARN if status == OK else status
        reasons.append(f"{attrs['nvme_media_errors']} media integrity errors")
    used = attrs.get("nvme_used_pct")
    if used is not None and used >= 90:
        status = WARN if status == OK else status
        reasons.append(f"NVMe endurance {used}% used")
    spare, spare_min = attrs.get("nvme_spare_pct"), attrs.get("nvme_spare_min")
    if spare is not None and spare_min is not None and spare <= spare_min:
        status = ERROR
        reasons.append(f"NVMe spare blocks {spare}% at/below the {spare_min}% floor")

    note("Reallocated sectors", "reallocated")
    note("Sectors pending reallocation", "pending")
    note("Offline uncorrectable sectors", "offline_uncorrectable")
    note("Reported uncorrectable errors", "reported_uncorrect")
    note("Interface CRC errors", "crc")
    note("NVMe endurance used", "nvme_used_pct", "%")
    note("NVMe spare blocks", "nvme_spare_pct", "%")
    note("NVMe media integrity errors", "nvme_media_errors")
    return status, reasons, mets


def disk_components(now_iso):
    """
    Every block device, whatever bus it hangs off.

    Walking /sys/class/ata_port only ever finds chipset SATA - drives behind a
    SAS HBA and NVMe devices have no ata port at all, so they were invisible.

    Returns (components, by_block) where by_block maps sdX -> its component, so
    the connector it sits on can inherit its health.
    """
    out, by_block = [], {}
    baseline = load_baseline()
    root = "/sys/block"
    if not os.path.isdir(root):
        return out, by_block
    for blk in sorted(os.listdir(root)):
        if blk.startswith(("zram", "loop", "dm-", "md")):
            continue
        base = os.path.join(root, blk)
        devlink = os.path.join(base, "device")
        if not os.path.exists(devlink):
            continue
        real = os.path.realpath(devlink)

        rotational = read(os.path.join(base, "queue", "rotational")) == "1"
        removable = read(os.path.join(base, "removable")) == "1"

        sectors = read_int(os.path.join(base, "size"), 0) or 0
        # An optical drive with an empty tray reports the sr driver's sentinel
        # capacity of 0x1FFFFF sectors, which rounds to a confident-looking
        # "1 GB". Showing that is worse than showing nothing: it claims a disc
        # is present. Treat the sentinel as no media.
        if removable and sectors == 0x1FFFFF:
            sectors = 0
        gb = round(sectors * 512 / 1e9, 1)
        model = (read(os.path.join(devlink, "model"))
                 or read(os.path.join(devlink, "device", "model"))
                 or read(os.path.join(base, "device", "modelname")) or blk)

        if "nvme" in blk:
            transport = "NVMe"
        elif re.search(r"/ata\d+/", real):
            transport = "SATA"
        else:
            transport = "SAS"

        m = re.search(r"/(ata\d+)/", real)
        ata = m.group(1) if m else None
        pci = ""
        pci_path = []
        for part in real.split("/"):
            if re.fullmatch(r"0000:[0-9a-f]{2}:[0-9a-f]{2}\.\d", part):
                pci = part
                pci_path.append(part)

        probe = smart_probe(blk) if not removable else {"health": None,
                                                        "serial": None,
                                                        "attrs": {}}
        health = probe["health"]
        attrs = probe["attrs"]

        # Baselines are keyed on serial, not on sdX: device letters shuffle
        # between boots (one appeared on this machine mid-investigation), and
        # comparing sdd's counters against what sdc reported last week would
        # invent growth that never happened.
        bkey = probe.get("serial") or f"dev:{blk}"
        prev = baseline.get(bkey) or {}
        first_attrs = prev.get("attrs") or attrs
        if attrs:
            baseline[bkey] = {"attrs": first_attrs,
                              "first_seen": prev.get("first_seen") or now_iso,
                              "last": attrs, "last_seen": now_iso}

        status, extra = OK, None
        if health and health.lower() not in ("passed", "ok", "standby"):
            status = ERROR
            extra = f"SMART self-assessment: {health}"
        elif gb == 0 and removable:
            status = EMPTY

        smart_status, smart_reasons, smart_mets = smart_verdict(
            attrs, first_attrs if prev else None, rotational)
        if status not in (ERROR,) and smart_status != OK:
            status = smart_status
            if smart_reasons and not extra:
                extra = "; ".join(smart_reasons)

        mets = [metric("Device", f"/dev/{blk}"),
                metric("Model", model),
                metric("Transport", transport)]
        # Serial is the only drive identifier that survives a reboot: sdX
        # letters shuffle, and on this machine they did. It is what you match
        # against the label on the drive when you pull it.
        serial = probe.get("serial") or read(os.path.join(devlink, "serial"))
        if serial:
            mets.append(metric("Serial", serial))
        if gb:
            mets.append(metric("Capacity", gb, "GB"))
        mets.append(metric("Type", "spinning disk" if rotational else "solid state"))
        if health:
            mets.append(metric("SMART self-assessment", health))
        mets += smart_mets
        if ata:
            mets.append(metric("Kernel ATA port", ata))
        if pci:
            mets.append(metric("Controller", pci))

        if removable and not gb:
            headline = f"{model} (no media)"
        else:
            headline = f"{model}" + (f" · {gb:.0f} GB" if gb else "")
        if extra:
            headline = extra

        note = None
        if smart_reasons and status != OK:
            note = ("SMART counters that have been static for years are old "
                    "scars; the alarm here is for counters that have MOVED "
                    "since this drive was first seen"
                    + (f" on {prev.get('first_seen', now_iso)[:10]}" if prev else "")
                    + ". Back up before troubleshooting.")

        aliases = [f"disk:{transport.lower()}:{blk}"]
        if ata:
            aliases.append(f"sata:{ata}")     # so old ata-keyed profiles still match
        c = comp(f"disk:{blk}", "disk", f"/dev/{blk}", status, headline,
                 mets, note, aliases=aliases)
        # What a connector should repeat when you hover it: identity and the
        # health counters, not the plumbing.
        c["_pci_path"] = pci_path
        # Does this drive already have a physical home on the board picture?
        # ATA ports and SAS PHYs are drawn as their own connector rectangles,
        # so a drive reachable through one is already placed. Only drives with
        # no connector of their own - NVMe on a carrier card being the usual
        # case - need to be drawn as bays on their slot. Without this the SAS
        # disks appeared twice: once at their cable connector and again on the
        # HBA's slot, which reads as eight drives when there are four.
        c["_has_connector"] = bool(ata) or "/end_device-" in real
        c["_detail"] = ([metric("Model", model)]
                        + ([metric("Serial", serial)] if serial else [])
                        + ([metric("Capacity", gb, "GB")] if gb else [])
                        + ([metric("SMART self-assessment", health)] if health else [])
                        + smart_mets)
        out.append(c)
        by_block[blk] = c

    save_baseline(baseline)
    return out, by_block


# ===================================================================== network

def net_components():
    out = []
    root = "/sys/class/net"
    if not os.path.isdir(root):
        return out
    for ifc in sorted(os.listdir(root)):
        if VIRTUAL_NET_RE.match(ifc):
            continue
        base = os.path.join(root, ifc)
        # Only physical devices have a device symlink.
        if not os.path.exists(os.path.join(base, "device")):
            continue
        oper = read(os.path.join(base, "operstate"))
        speed = read_int(os.path.join(base, "speed"))
        mets = [metric("MAC address", read(os.path.join(base, "address"))),
                metric("State", oper)]
        if speed and speed > 0:
            mets.append(metric("Link speed", speed, "Mb/s"))
        for stat, lbl in (("rx_errors", "Receive errors"),
                          ("tx_errors", "Transmit errors"),
                          ("rx_crc_errors", "CRC errors")):
            v = read_int(os.path.join(base, "statistics", stat))
            if v:
                mets.append(metric(lbl, v))

        errs = sum(read_int(os.path.join(base, "statistics", s), 0) or 0
                   for s in ("rx_errors", "tx_errors", "rx_crc_errors"))
        if oper == "up":
            status = WARN if errs else OK
            headline = f"up, {speed} Mb/s" if speed and speed > 0 else "up"
            if errs:
                headline += f", {errs} link errors"
        else:
            status, headline = EMPTY, "no link"
        dev = os.path.realpath(os.path.join(base, "device"))
        pci = os.path.basename(dev) if "/pci" in dev else ""
        vend = read(os.path.join(dev, "vendor")).replace("0x", "")
        prod = read(os.path.join(dev, "device")).replace("0x", "")
        mac = read(os.path.join(base, "address"))
        aliases = []
        if vend and prod:
            aliases.append(f"net:dev:{vend}:{prod}")   # portable across machines
        if pci:
            aliases.append(f"net:pci:{pci}")
        if mac:
            aliases.append(f"net:mac:{mac}")
        if pci:
            mets.insert(0, metric("PCI address", pci))
        out.append(comp(f"net:{ifc}", "net", ifc, status, headline, mets,
                        aliases=aliases))
    return out


# ========================================================================== DMI

def read_dmi_slots():
    try:
        out = subprocess.run(["dmidecode", "-t", "17"], capture_output=True,
                             text=True, timeout=15, check=True).stdout
    except (subprocess.SubprocessError, FileNotFoundError, OSError) as e:
        print(f"warning: dmidecode unavailable ({e})", file=sys.stderr)
        return []
    slots, cur = [], None
    for line in out.splitlines():
        if line.startswith("Memory Device"):
            if cur:
                slots.append(cur)
            cur = {}
            continue
        if cur is None or ":" not in line or not line.strip():
            continue
        k, _, v = line.strip().partition(":")
        cur[k.strip()] = v.strip()
    if cur:
        slots.append(cur)

    res = []
    for s in slots:
        size = s.get("Size", "No Module Installed")
        populated = "No Module Installed" not in size and size != "Unknown"
        gb = None
        if populated:
            m = re.match(r"(\d+)\s*(GB|GiB|MB|MiB)", size)
            if m:
                gb = int(m.group(1))
                if m.group(2).startswith("M"):
                    gb = round(gb / 1024, 2)
        res.append({
            "locator": s.get("Locator", ""), "populated": populated,
            "size_gb": gb, "type": s.get("Type", ""),
            "speed": s.get("Configured Memory Speed", s.get("Speed", "")),
            "manufacturer": s.get("Manufacturer", ""),
            "part": s.get("Part Number", ""), "serial": s.get("Serial Number", ""),
            "rank": s.get("Rank", ""),
        })
    return res


def read_board():
    return {k: read(f"/sys/class/dmi/id/{k}") for k in
            ("board_vendor", "board_name", "product_name", "sys_vendor",
             "bios_version")}


# ======================================================================= output

def build_state():
    now = datetime.now()
    warnings = []

    edac = read_edac()
    ras, ras_err = read_rasdaemon(now)
    if ras_err:
        warnings.append(ras_err)
    if not edac:
        warnings.append("EDAC exposes no memory controllers - no ECC monitoring "
                        "is possible. Is an edac driver loaded?")

    temps, fans = hwmon_components()
    components = []
    components += dimm_components(edac, ras)
    components += cpu_components(temps)
    now_iso = now.astimezone().isoformat(timespec="seconds")
    # Disks are built FIRST: connectors inherit the health of the drive plugged
    # into them, and PCIe slots report the drives behind a carrier card. Both
    # need the disk inventory to already exist. This ordering is load-bearing.
    disks, by_block = disk_components(now_iso)
    components += pcie_components(lspci_names(), by_block)
    components += sata_components(by_block)
    components += sasport_components(by_block)
    components += disks
    components += net_components()
    components += temps
    components += fans

    tt = (ras or {}).get("true_totals")
    dimms = [c for c in components if c["kind"] == "dimm"]
    if tt:
        mem_totals = {"ce_total": tt["ce"], "ue_total": tt["ue"],
                      "ce_24h": tt["ce_24h"], "ce_7d": tt["ce_7d"],
                      "ce_30d": tt["ce_30d"]}
    else:
        mem_totals = {"ce_total": sum(c["ce_total"] for c in dimms),
                      "ue_total": sum(c["ue_total"] for c in dimms),
                      "ce_24h": 0, "ce_7d": 0, "ce_30d": 0}
    mem_totals["slots"] = len(dimms)
    mem_totals["slots_with_errors"] = sum(
        1 for c in dimms if c["ce_total"] or c["ue_total"])

    # Internal scratch fields used to join disks onto ports and slots; they are
    # not part of the published schema.
    for c in components:
        c.pop("_detail", None)
        c.pop("_pci_path", None)
        c.pop("_has_connector", None)

    by_status = defaultdict(int)
    for c in components:
        by_status[c["status"]] += 1

    return {
        "schema": SCHEMA_VERSION,
        "generated": now.astimezone().isoformat(timespec="seconds"),
        "generated_epoch": int(now.timestamp()),
        "board": read_board(),
        "components": components,
        # Retained for the memory-specific views and notification logic.
        "slots": dimms,
        "totals": mem_totals,
        "counts": {
            "components": len(components),
            "error": by_status[ERROR], "warn": by_status[WARN],
            "ok": by_status[OK], "empty": by_status[EMPTY],
        },
        "dmi_slots": read_dmi_slots(),
        "history": (ras or {}).get("history", []),
        "warnings": warnings,
    }


def main():
    state = build_state()
    os.makedirs(OUT_DIR, exist_ok=True)
    os.chmod(OUT_DIR, 0o755)
    fd, tmp = tempfile.mkstemp(dir=OUT_DIR, prefix=".state-", suffix=".json")
    try:
        with os.fdopen(fd, "w") as fh:
            json.dump(state, fh, indent=1)
            fh.write("\n")
        os.chmod(tmp, 0o644)
        os.replace(tmp, OUT_FILE)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise

    if "--verbose" in sys.argv or "-v" in sys.argv:
        c, t = state["counts"], state["totals"]
        print(f"{OUT_FILE}: {c['components']} components "
              f"({c['error']} error, {c['warn']} warn, {c['empty']} empty)")
        print(f"  memory: {t['ce_total']} ECC corrected lifetime, "
              f"{t['ce_30d']} in 30d, {t['ue_total']} uncorrectable")
        for w in state["warnings"]:
            print(f"  warning: {w}")
        kinds = defaultdict(int)
        for comp_ in state["components"]:
            kinds[comp_["kind"]] += 1
        print("  kinds: " + ", ".join(f"{k}={v}" for k, v in sorted(kinds.items())))


if __name__ == "__main__":
    main()
