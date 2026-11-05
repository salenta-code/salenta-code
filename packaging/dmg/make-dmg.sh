#!/bin/zsh
# Baut das Installations-Image (.dmg) wie bei Mac-Apps üblich:
# Fenster mit Hintergrund, links die App, rechts der Ordner „Programme“ – reinziehen, fertig.
#
#   packaging/dmg/make-dmg.sh "dist/0.3.0/Salenta Code.app" "dist/0.3.0/Salenta-Code-0.3.0.dmg"
#
# Signieren und Beglaubigen des Images macht scripts/release.sh.
set -euo pipefail
app="${1:?Pfad zur .app}"
out="${2:?Ziel .dmg}"
here="${0:A:h}"
vol="Salenta Code"

work=$(mktemp -d)
trap 'hdiutil detach "/Volumes/$vol" -quiet 2>/dev/null || true; rm -rf "$work"' EXIT

stage="$work/stage"
mkdir -p "$stage/.background"
ditto "$app" "$stage/Salenta Code.app"
ln -s /Applications "$stage/Programme"
# Hintergrund in Normal- und Retina-Auflösung (eine TIFF-Datei mit beiden Größen)
if [[ -f "$here/background@2x.png" ]] && command -v tiffutil >/dev/null; then
  tiffutil -cathidpicheck "$here/background.png" "$here/background@2x.png" -out "$stage/.background/background.tiff" >/dev/null
  bg="background.tiff"
else
  cp "$here/background.png" "$stage/.background/background.png"
  bg="background.png"
fi

size=$(( $(du -sm "$stage" | cut -f1) + 40 ))
hdiutil detach "/Volumes/$vol" -quiet 2>/dev/null || true
hdiutil create -quiet -volname "$vol" -srcfolder "$stage" -fs HFS+ -format UDRW -size "${size}m" "$work/rw.dmg"
hdiutil attach -quiet -readwrite -noverify -noautoopen "$work/rw.dmg"

# Fensterlayout setzen (braucht einen angemeldeten Finder – in CI ohne Bildschirm wird es übersprungen)
osascript <<APPLESCRIPT || echo "  (Fensterlayout übersprungen – Image funktioniert trotzdem)"
tell application "Finder"
  tell disk "$vol"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 560}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 13
    set background picture of opts to file ".background:$bg"
    set position of item "Salenta Code.app" of container window to {165, 215}
    set position of item "Programme" of container window to {495, 215}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT

sync
hdiutil detach -quiet "/Volumes/$vol"
rm -f "$out"
hdiutil convert -quiet "$work/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$out"
echo "✓ Image: $out ($(du -h "$out" | cut -f1))"
