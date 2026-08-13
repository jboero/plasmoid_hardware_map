#!/usr/bin/env bash
# Build the .plasmoid archive for KDE Store upload.
#
# A .plasmoid is just a zip of the package directory with metadata.json at its
# root. Note this ships the APPLET ONLY - the root collector cannot be
# installed by the store, so the listing must link back to the repository.
#
# The archive is built from boards/ as the single source of truth. An earlier
# release shipped a package copy that had drifted from boards/ and mislabelled
# four storage connectors - rectangles reading SATA0-3 that were wired to the
# sSATA ports. Syncing and validating here is what stops that recurring.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG="$SRC/plasmoid/io.github.jboero.hardwaremap"
VER="$(python3 -c "import json;print(json.load(open('$PKG/metadata.json'))['KPlugin']['Version'])")"
OUT="$SRC/dist/plasmoid_hardware_map-$VER.plasmoid"

# ------------------------------------------------------------------ boards
# Regenerate the registry, then mirror boards/ into the package. --delete
# matters: a board removed from boards/ must not linger in the archive.
echo "==> Syncing board modules"
python3 "$SRC/tools/make-index.py"
rsync -a --delete "$SRC/boards/" "$PKG/contents/boards/"

# The GPL travels with the binary. Store users get this archive and never see
# the repository, so the licence has to be inside it. $PKG/LICENSE is a symlink
# to the top-level one; zip follows it and stores the real content, so there is
# no second copy of the GPL text in git.
[ -r "$PKG/LICENSE" ] || { echo "  FAIL $PKG/LICENSE does not resolve"; exit 1; }

# ---------------------------------------------------------------- validate
echo "==> Validating package"
python3 - "$PKG" <<'PY'
import json, os, struct, sys

pkg = sys.argv[1]
fail = []

meta = json.load(open(os.path.join(pkg, "metadata.json")))
kp = meta["KPlugin"]
for field in ("Id", "Name", "Description", "Version", "License", "Icon",
              "Authors", "Website"):
    if not kp.get(field):
        fail.append(f"metadata.json: KPlugin.{field} is missing or empty")

main = meta.get("X-Plasma-MainScript", "")
if not os.path.exists(os.path.join(pkg, "contents", main)):
    fail.append(f"X-Plasma-MainScript points at a missing file: contents/{main}")


def image_size(path):
    """Pixel dimensions of a PNG or WebP, without pulling in a dependency."""
    d = open(path, "rb").read()
    if d[:8] == b"\x89PNG\r\n\x1a\n":
        return struct.unpack(">II", d[16:24])
    if d[:4] == b"RIFF" and d[8:12] == b"WEBP":
        # Every branch is offset from the chunk PAYLOAD, which starts 8 bytes
        # past the fourcc at d[12] - i.e. at d[20], not d[24].
        c, b = d[12:16], d[20:]
        if c == b"VP8X":                      # extended: 24-bit canvas - 1
            return ((b[4] | b[5] << 8 | b[6] << 16) + 1,
                    (b[7] | b[8] << 8 | b[9] << 16) + 1)
        if c == b"VP8 ":                      # lossy: 14-bit dims after the
            return ((b[6] | b[7] << 8) & 0x3FFF,   # 3-byte frame tag and the
                    (b[8] | b[9] << 8) & 0x3FFF)   # 3-byte start code
        if c == b"VP8L":                      # lossless: packed 14-bit - 1
            n = int.from_bytes(b[1:5], "little")
            return (n & 0x3FFF) + 1, ((n >> 14) & 0x3FFF) + 1
    return None


boards = os.path.join(pkg, "contents", "boards")
index = json.load(open(os.path.join(boards, "index.json")))
dirs = {e["dir"] for e in index["boards"]}

for name in sorted(os.listdir(boards)):
    bdir = os.path.join(boards, name)
    if not os.path.isdir(bdir):
        continue
    if name not in dirs:
        fail.append(f"board '{name}' is on disk but absent from index.json")
    p = json.load(open(os.path.join(bdir, "profile.json")))

    img = p.get("image", "")
    ipath = os.path.join(bdir, img)
    if not img or not os.path.exists(ipath):
        fail.append(f"board '{name}': image '{img}' is missing")
        continue

    # A wrong imageSize offsets or rescales every rectangle on the board, and
    # it looks plausible until you render it. Cheap to check, so check it.
    real, declared = image_size(ipath), tuple(p.get("imageSize") or ())
    if real and declared and real != declared:
        fail.append(f"board '{name}': imageSize {list(declared)} does not "
                    f"match {img}, which is {real[0]}x{real[1]}")

    for key, slot in (p.get("slots") or {}).items():
        r = slot.get("rect") or []
        if len(r) != 4 or not all(isinstance(v, (int, float)) for v in r):
            fail.append(f"board '{name}': slot '{key}' has a malformed rect")
        elif not (0 <= r[0] <= 1 and 0 <= r[1] <= 1
                  and 0 < r[2] <= 1 and 0 < r[3] <= 1):
            fail.append(f"board '{name}': slot '{key}' rect {r} is not "
                        f"normalised 0..1")

for entry in index["boards"]:
    if entry["dir"] not in os.listdir(boards):
        fail.append(f"index.json lists '{entry['dir']}', which is not on disk")

if fail:
    for f in fail:
        print(f"  FAIL {f}")
    sys.exit(1)
print(f"  OK   metadata, {len(dirs)} board module(s), all rects normalised")
PY

# ------------------------------------------------------------------- build
mkdir -p "$SRC/dist"
rm -f "$OUT"
( cd "$PKG" && zip -qr "$OUT" . -x '*~' '*.bak' '.*' )

echo "==> Built $OUT"
unzip -l "$OUT" | tail -3
echo
echo "Sanity check - metadata.json must be at the archive root:"
unzip -l "$OUT" | grep -q ' metadata.json$' && echo "  OK" || { echo "  MISSING"; exit 1; }
