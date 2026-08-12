#!/usr/bin/env python3
"""
Regenerate boards/index.json from the board modules present on disk.

Each board lives in its own directory under boards/ and is self-contained:

    boards/<board-id>/
        profile.json     component id -> rectangle, plus `match` criteria
        board.<ext>      the picture, referenced relatively from profile.json
        README.md        provenance: where the picture came from, what is
                         verified vs inferred, who to blame

The index exists because QML cannot list a directory. The widget fetches
index.json, picks the entry whose `match` fits this machine's DMI, then loads
that board's profile. Run this after adding or editing a board.
"""

import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
BOARDS = os.path.normpath(os.path.join(HERE, "..", "boards"))


def main():
    entries = []
    for name in sorted(os.listdir(BOARDS)):
        bdir = os.path.join(BOARDS, name)
        profile = os.path.join(bdir, "profile.json")
        if not os.path.isdir(bdir) or not os.path.exists(profile):
            continue
        try:
            with open(profile) as fh:
                p = json.load(fh)
        except (OSError, json.JSONDecodeError) as e:
            print(f"  SKIP {name}: {e}", file=sys.stderr)
            continue

        match = p.get("match") or {}
        if not match:
            print(f"  SKIP {name}: profile.json has no 'match' block, so it "
                  f"could never be auto-detected", file=sys.stderr)
            continue

        img = p.get("image", "")
        if img and not os.path.exists(os.path.join(bdir, img)):
            print(f"  WARN {name}: image '{img}' is missing", file=sys.stderr)

        entries.append({
            "dir": name,
            "name": p.get("name", name),
            "match": match,
            "confidence": p.get("confidence", "unknown"),
            "components": len(p.get("slots") or {}),
        })
        print(f"  {name:24} {p.get('name','')}  "
              f"({len(p.get('slots') or {})} components, {p.get('confidence')})")

    out = os.path.join(BOARDS, "index.json")
    with open(out, "w") as fh:
        json.dump({"boards": entries}, fh, indent=2)
        fh.write("\n")
    print(f"wrote {out}: {len(entries)} board(s)")


if __name__ == "__main__":
    main()
