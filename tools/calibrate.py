#!/usr/bin/env python3
"""
calibrate.py - build a board profile by dragging boxes over a picture of a board.

Physical component geometry does not exist in SMBIOS, so there is no way to
derive where anything sits on a board. This tool is the manual step that closes
the gap: you supply a picture, drag a box over each component, and it writes a
profile the widget can use. Profiles are plain JSON and meant to be shared.

Usage:
    ./calibrate.py board.png [-o profile.json]

The component list is read live from /run/dimm-mce/state.json, so you can only
assign boxes to things this machine actually reports - DIMM slots, PCIe slots,
SATA ports, network ports, CPU sockets, fans and temperature sensors.

You do NOT have to box everything. Anything left unboxed still appears in the
widget's list view; the picture is a convenience, not a requirement.

Keys:
    drag            draw a box for the current component (then auto-advances)
    Tab / Down      next             Shift-Tab / Up   previous
    Delete          clear this component's box
    s               save             q   quit
"""

import argparse
import json
import os
import sys
import tkinter as tk
from tkinter import messagebox

STATE = "/run/dimm-mce/state.json"

PALETTE = ["#e6194b", "#3cb44b", "#4363d8", "#f58231", "#911eb4", "#42d4f4",
           "#f032e6", "#bfef45", "#fabed4", "#469990", "#dcbeff", "#9a6324",
           "#800000", "#aaffc3", "#808000", "#000075"]


def load_slots(path):
    try:
        with open(path) as fh:
            state = json.load(fh)
    except OSError as e:
        sys.exit(f"cannot read {path}: {e}\n"
                 f"run: sudo /usr/local/bin/dimm-mce-export")
    except json.JSONDecodeError as e:
        sys.exit(f"{path} is not valid JSON: {e}")

    slots = state.get("components") or state.get("slots") or []
    if not slots:
        sys.exit(f"{path} lists no components - is the collector running?")
    return state, slots


def comp_key(c):
    """Stable id used to join a rectangle to a component."""
    return c.get("id") or c.get("key")


def comp_name(c):
    return c.get("label") or comp_key(c)


class Calibrator:
    def __init__(self, root, image_path, out_path, state, slots):
        self.root = root
        self.image_path = image_path
        self.out_path = out_path
        self.state = state
        self.slots = slots
        self.index = 0
        self.rects = {}          # key -> (x0, y0, x1, y1) in image pixels
        self.canvas_items = {}
        self.drag_start = None
        self.temp_item = None

        self.img = tk.PhotoImage(file=image_path)
        self.iw, self.ih = self.img.width(), self.img.height()

        root.title(f"Calibrate - {os.path.basename(image_path)}")

        self.status = tk.Label(root, anchor="w", justify="left",
                               font=("TkDefaultFont", 11), padx=8, pady=6)
        self.status.pack(side="top", fill="x")

        self.canvas = tk.Canvas(root, width=self.iw, height=self.ih,
                                highlightthickness=0, cursor="crosshair")
        self.canvas.pack(side="top")
        self.canvas.create_image(0, 0, anchor="nw", image=self.img)

        hint = tk.Label(
            root, anchor="w", padx=8, pady=4, fg="#555",
            text="drag = set box   Tab/Down = next   Shift-Tab/Up = prev   "
                 "Delete = clear   s = save   q = quit")
        hint.pack(side="bottom", fill="x")

        # Load an existing profile so calibration can be resumed.
        if os.path.exists(out_path):
            try:
                with open(out_path) as fh:
                    prev = json.load(fh)
                for key, spec in (prev.get("slots") or {}).items():
                    x, y, w, h = spec["rect"]
                    self.rects[key] = (x * self.iw, y * self.ih,
                                       (x + w) * self.iw, (y + h) * self.ih)
                self.redraw()
            except (OSError, json.JSONDecodeError, KeyError, ValueError):
                pass

        canvas = self.canvas
        canvas.bind("<Button-1>", self.on_press)
        canvas.bind("<B1-Motion>", self.on_drag)
        canvas.bind("<ButtonRelease-1>", self.on_release)
        root.bind("<Tab>", lambda e: self.step(1))
        root.bind("<Down>", lambda e: self.step(1))
        root.bind("<Shift-Tab>", lambda e: self.step(-1))
        root.bind("<ISO_Left_Tab>", lambda e: self.step(-1))
        root.bind("<Up>", lambda e: self.step(-1))
        root.bind("<Delete>", lambda e: self.clear_current())
        root.bind("<BackSpace>", lambda e: self.clear_current())
        root.bind("s", lambda e: self.save())
        root.bind("q", lambda e: root.destroy())
        self.refresh_status()

    # ------------------------------------------------------------- interaction
    @property
    def current(self):
        return self.slots[self.index]

    def step(self, delta):
        self.index = (self.index + delta) % len(self.slots)
        self.refresh_status()
        self.redraw()
        return "break"

    def clear_current(self):
        self.rects.pop(comp_key(self.current), None)
        self.redraw()
        self.refresh_status()

    def on_press(self, event):
        self.drag_start = (event.x, event.y)

    def on_drag(self, event):
        if not self.drag_start:
            return
        if self.temp_item:
            self.canvas.delete(self.temp_item)
        x0, y0 = self.drag_start
        self.temp_item = self.canvas.create_rectangle(
            x0, y0, event.x, event.y,
            outline=PALETTE[self.index % len(PALETTE)], width=2)

    def on_release(self, event):
        if not self.drag_start:
            return
        x0, y0 = self.drag_start
        x1, y1 = event.x, event.y
        self.drag_start = None
        if self.temp_item:
            self.canvas.delete(self.temp_item)
            self.temp_item = None
        if abs(x1 - x0) < 4 or abs(y1 - y0) < 4:
            return  # ignore stray clicks
        box = (min(x0, x1), min(y0, y1), max(x0, x1), max(y0, y1))
        self.rects[comp_key(self.current)] = box
        self.redraw()
        # Advance automatically so a full board is one drag per slot.
        self.step(1)

    # ------------------------------------------------------------------ render
    def redraw(self):
        for item in self.canvas_items.values():
            for i in item:
                self.canvas.delete(i)
        self.canvas_items.clear()

        for i, slot in enumerate(self.slots):
            key = comp_key(slot)
            if key not in self.rects:
                continue
            x0, y0, x1, y1 = self.rects[key]
            colour = PALETTE[i % len(PALETTE)]
            width = 4 if i == self.index else 2
            rect = self.canvas.create_rectangle(x0, y0, x1, y1,
                                                outline=colour, width=width)
            text = self.canvas.create_text(
                x0 + 4, y0 + 2, anchor="nw", fill=colour,
                font=("TkDefaultFont", 8, "bold"),
                text=comp_name(slot)[:22])
            self.canvas_items[key] = (rect, text)

    def refresh_status(self):
        s = self.current
        done = len(self.rects)
        self.status.config(
            text=f"[{self.index + 1}/{len(self.slots)}]  "
                 f"{s.get('kind', '?')}  —  {comp_name(s)}"
                 f"      ({s.get('headline', '')})\n"
                 f"{comp_key(s)}"
                 f"      {done}/{len(self.slots)} components boxed",
            fg=PALETTE[self.index % len(PALETTE)])

    # ------------------------------------------------------------------- save
    def save(self):
        if not self.rects:
            messagebox.showwarning("Nothing to save", "No slots have boxes yet.")
            return

        board = self.state.get("board", {})
        profile = {
            "id": os.path.splitext(os.path.basename(self.out_path))[0],
            "name": board.get("product_name") or "Unknown board",
            "match": {
                "board_vendor": board.get("board_vendor", ""),
                "board_name": board.get("board_name", ""),
                "product_name": board.get("product_name", ""),
            },
            "image": os.path.basename(self.image_path),
            "imageSize": [self.iw, self.ih],
            "confidence": "user-calibrated",
            "notes": [
                "Created with tools/calibrate.py.",
                "Slot positions were placed by hand against a picture of this board.",
            ],
            "slots": {},
        }
        for key, (x0, y0, x1, y1) in self.rects.items():
            match = next((c for c in self.slots if comp_key(c) == key), None)
            profile["slots"][key] = {
                "rect": [round(x0 / self.iw, 4), round(y0 / self.ih, 4),
                         round((x1 - x0) / self.iw, 4),
                         round((y1 - y0) / self.ih, 4)],
                "label": comp_name(match) if match else key,
                "kind": (match or {}).get("kind", ""),
            }

        try:
            with open(self.out_path, "w") as fh:
                json.dump(profile, fh, indent=2)
                fh.write("\n")
        except OSError as e:
            messagebox.showerror("Save failed", str(e))
            return

        missing = len(self.slots) - len(self.rects)
        messagebox.showinfo(
            "Saved",
            f"Wrote {self.out_path}\n\n"
            f"{len(self.rects)} of {len(self.slots)} slots boxed"
            + (f"\n{missing} still unboxed" if missing else "")
            + f"\n\nCopy it and {os.path.basename(self.image_path)} into:\n"
              f"~/.local/share/dimm-mce-monitor/boards/")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("image", help="PNG or GIF picture of the board")
    ap.add_argument("-o", "--output", help="profile JSON to write")
    ap.add_argument("--state", default=STATE, help=f"state file (default {STATE})")
    args = ap.parse_args()

    if not os.path.exists(args.image):
        sys.exit(f"no such image: {args.image}")

    state, slots = load_slots(args.state)
    board = state.get("board", {})
    slug = "-".join(filter(None, [board.get("board_vendor", ""),
                                  board.get("board_name", "")])).lower()
    slug = "".join(c if c.isalnum() else "-" for c in slug).strip("-") or "board"
    out = args.output or os.path.join(os.path.dirname(args.image) or ".",
                                      f"{slug}.json")

    root = tk.Tk()
    try:
        Calibrator(root, args.image, out, state, slots)
    except tk.TclError as e:
        sys.exit(f"cannot load {args.image}: {e}\n"
                 f"tkinter reads PNG and GIF only - convert other formats first")
    root.mainloop()


if __name__ == "__main__":
    main()
