#!/bin/bash
# Renders Iconery.svg into Resources/Assets.xcassets/AppIcon.appiconset. Run it after changing the
# artwork; build.sh compiles the catalog with actool.
#
# An asset catalog rather than a bare .icns: macOS 27 drew the bare .icns shrunk inside a grey tile
# (measured on this app), while FinderPlus's catalog icon on the same grid shows as itself.
#
# Rendered by headless Chrome rather than AppKit or Quick Look, each measured on this artwork:
# AppKit's SVG renderer skips the drop-shadow filters entirely, and Quick Look keeps them but draws
# onto an opaque white square, which would cost the icon its transparent corners.
set -euo pipefail

cd "$(dirname "$0")"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
if [[ ! -x "$CHROME" ]]; then
    echo "Google Chrome is needed to render the icon" >&2
    exit 1
fi
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A throwaway profile, so the render never touches the real one. Chrome 154 writes the screenshot and
# then never exits (measured), so it runs in the background and is stopped once the file is there.
"$CHROME" --headless=new --disable-gpu --hide-scrollbars --no-first-run \
    --user-data-dir="$WORK/profile" --default-background-color=00000000 \
    --window-size=1024,1024 --screenshot="$WORK/master.png" "file://$PWD/Iconery.svg" \
    >/dev/null 2>&1 &
CHROME_PID=$!
for _ in $(seq 1 300); do
    [[ -s "$WORK/master.png" ]] && break
    sleep 0.1
done
sleep 0.5  # the file appears before Chrome has finished writing it
kill "$CHROME_PID" 2>/dev/null || true
wait "$CHROME_PID" 2>/dev/null || true
if [[ ! -s "$WORK/master.png" ]]; then
    echo "Chrome did not render Iconery.svg" >&2
    exit 1
fi

# The file names Contents.json lists beside it.
SET="../Assets.xcassets/AppIcon.appiconset"
for size in 16 32 128 256 512; do
    double=$((size * 2))
    sips -z "$size" "$size" "$WORK/master.png" --out "$SET/icon_${size}x${size}.png" >/dev/null
    sips -z "$double" "$double" "$WORK/master.png" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done
echo "Wrote $SET"
