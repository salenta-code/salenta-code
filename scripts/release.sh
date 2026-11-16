#!/bin/zsh
# Veröffentlicht eine neue Version von Salenta Code – so bekommen alle Nutzer das Update.
#
#   scripts/release.sh 0.3.0            stabile Version
#   scripts/release.sh 0.3.0-beta.1     Beta (nur wer „Beta-Updates“ eingeschaltet hat)
#
# Ablauf: VERSION setzen → bauen + Selbsttest → mit deiner Developer ID signieren → von Apple beglaubigen lassen
# (Notarisierung) → Zip + latest.json → GitHub-Release. Die Apps der Nutzer finden es dann von selbst.
#
# Einmalig nötig (Einstellungen › Updates zeigt den Stand):
#   • Zertifikat „Developer ID Application“ im Schlüsselbund
#   • Notar-Zugang:  xcrun notarytool store-credentials salenta-notary --apple-id DEINE@ID --team-id TEAMID
#   • UPDATE_REPO-Datei im Projektordner, z. B. „salenta-code/salenta-code“, und `gh auth login`
# In GitHub Actions kommen Zertifikat und Notar-Schlüssel aus den Secrets (siehe .github/workflows/release.yml).
set -euo pipefail
version="${1:?Version angeben, z. B. scripts/release.sh 0.3.0}"
here="${0:A:h:h}"
repo="${UPDATE_REPO:-$(cat "$here/UPDATE_REPO" 2>/dev/null || true)}"
[[ -n "$repo" ]] || { echo "✗ UPDATE_REPO fehlt (z. B. echo salenta-code/salenta-code > UPDATE_REPO)"; exit 1; }
profile="${NOTARY_PROFILE:-salenta-notary}"
prerelease=""; [[ "$version" == *-* ]] && prerelease="--prerelease"

echo "→ Datenschutz-Prüfung (keine Schlüssel, keine persönlichen Daten)"
"$here/scripts/privacy-check.sh"
echo "→ Oberflächen-Prüfung (jeder Symbol-Knopf hat einen Hinweis) – dieselbe wie in der CI"
(cd "$here" && python3 scripts/check-tooltips.py)

echo "$version" > "$here/VERSION"
dist="$here/dist/$version"; rm -rf "$dist"; mkdir -p "$dist"

# Quellcode und Version gehören zusammen: erst den Code auf GitHub bringen, dann die fertige App
if [[ -z "${GITHUB_ACTIONS:-}" ]] && git -C "$here" rev-parse --git-dir >/dev/null 2>&1; then
  echo "→ Quellcode auf GitHub (Commit + Push)"
  git -C "$here" add -A
  git -C "$here" diff --cached --quiet || git -C "$here" commit -q -m "Salenta Code $version"
  git -C "$here" push -q origin HEAD
  git -C "$here" tag -f "v$version" && git -C "$here" push -q -f origin "v$version"
fi

echo "→ Bauen, Selbsttest, signieren"
UPDATE_REPO="$repo" "$here/App/build.sh" --release --out "$dist"
app="$dist/Salenta Code.app"
"$here/scripts/privacy-check.sh" "$app"
zip="$dist/Salenta-Code-$version.zip"

echo "→ Von Apple beglaubigen lassen (dauert meist 2–10 Minuten)"
ditto -c -k --keepParent "$app" "$zip"
if [[ -n "${NOTARY_KEY_ID:-}" ]]; then
  xcrun notarytool submit "$zip" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" --wait
else
  xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait
fi
xcrun stapler staple "$app"
rm -f "$zip"; ditto -c -k --keepParent "$app" "$zip"
spctl --assess --type execute -v "$app"   # so sieht es Gatekeeper beim Nutzer

echo "→ Installations-Image (.dmg) – App in „Programme“ ziehen, wie bei Mac-Apps üblich"
dmg="$dist/Salenta-Code-$version.dmg"
"$here/packaging/dmg/make-dmg.sh" "$app" "$dmg"
identity=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' | head -1)
[[ -n "$identity" ]] && codesign --force --timestamp --sign "$identity" "$dmg"
if [[ -n "${NOTARY_KEY_ID:-}" ]]; then
  xcrun notarytool submit "$dmg" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID" --wait
else
  xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait
fi
xcrun stapler staple "$dmg"
spctl --assess --type open --context context:primary-signature -v "$dmg"
# fester Name, damit „…/releases/latest/download/Salenta-Code.dmg“ immer die neueste Version liefert
cp "$dmg" "$dist/Salenta-Code.dmg"

sha=$(shasum -a 256 "$zip" | cut -d' ' -f1)
# Ohne RELEASE_NOTES: die vorbereitete Datei dist/<Version>-notes.md, sonst die Commit-Liste
[ -z "${RELEASE_NOTES:-}" ] && [ -f "$here/dist/$version-notes.md" ] && RELEASE_NOTES="$(cat "$here/dist/$version-notes.md")"
notes="${RELEASE_NOTES:-$(git -C "$here" log -20 --pretty='- %s' "$(git -C "$here" describe --tags --abbrev=0 "v$version^" 2>/dev/null || echo HEAD~20)"..HEAD 2>/dev/null || echo "- Verbesserungen und Fehlerbehebungen")}"
cat > "$dist/latest.json" <<JSON
{
  "version": "$version",
  "url": "https://github.com/$repo/releases/download/v$version/Salenta-Code-$version.zip",
  "sha256": "$sha",
  "minimumSystemVersion": "14.0",
  "published": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "notes": $(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$notes")
}
JSON

echo "→ GitHub-Release v$version"
gh release create "v$version" "$dist/Salenta-Code.dmg" "$dmg" "$zip" "$dist/latest.json" --repo "$repo" --title "Salenta Code $version" --notes "$notes" $prerelease
echo "✓ Veröffentlicht. Die Apps der Nutzer finden das Update innerhalb eines Tages (oder sofort über „Nach Updates suchen“)."
