#!/bin/bash
# Prüft, dass nichts Persönliches oder Geheimes veröffentlicht wird.
#
#   scripts/privacy-check.sh                 prüft alle Dateien, die ins Repo kommen
#   scripts/privacy-check.sh "Salenta Code.app"   prüft zusätzlich die fertige App
#
# Eigene Wörter (Name, Mail, Telefon, Firmen, IDs …) stehen in .private-words – eine pro Zeile.
# Diese Datei bleibt auf deinem Mac (.gitignore) und wird nie veröffentlicht.
# Bricht mit Fehler ab, sobald etwas gefunden wird – dann wird nichts veröffentlicht.
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
cd "$here"
fail=0

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  files=$(git ls-files -co --exclude-standard)
else
  files=$(find . -type f -not -path "./data/*" -not -path "./logs/*" -not -path "./dist/*" -not -path "./App/.build/*" \
          -not -path "./App/.swiftpm/*" -not -path "./.git/*" -not -name ".DS_Store" -not -name "*.pyc" -not -name ".private-words" | sed 's#^\./##'; \
          [[ -f data/mcp-catalog.json ]] && echo data/mcp-catalog.json)
fi
files=$(echo "$files" | grep -v '^\.private-words$' | grep -v '^scripts/privacy-check.sh$')

secrets='(sk-ant-[A-Za-z0-9_-]{16,}|sk-proj-[A-Za-z0-9_-]{16,}|sk-or-v1-[a-f0-9]{16,}|\bsk-[A-Za-z0-9]{32,}|ghp_[A-Za-z0-9]{30,}|gho_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{20,}|xox[abposr]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|eyJhbGciOi[A-Za-z0-9_-]{30,}\.[A-Za-z0-9_-]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|shp(at|ss|ca)_[a-f0-9]{20,}|whsec_[A-Za-z0-9]{20,}|sbp_[a-f0-9]{30,}|hf_[A-Za-z0-9]{30,}|r8_[A-Za-z0-9]{30,})'

check() { # $1 = Beschreibung, Rest = grep-Argumente
  local what="$1"; shift
  local hits
  hits=$(echo "$files" | tr '\n' '\0' | xargs -0 grep -nIE "$@" 2>/dev/null | cut -c1-160)
  if [[ -n "$hits" ]]; then echo "✗ $what:"; echo "$hits" | head -20; fail=1; fi
}

check "Schlüssel/Tokens gefunden" "$secrets"
check "Pfad mit Benutzername gefunden" '/Users/[A-Za-z0-9._-]{3,}/' 

words=()
if [[ -f .private-words ]]; then
  while IFS= read -r w; do [[ -n "$w" && "$w" != \#* ]] && words+=("$w"); done < .private-words
fi
# Impressum und Datenschutz müssen die Anbieter-Anschrift zeigen (gesetzlich vorgeschrieben):
# Wörter, die in website/impressum.json stehen, sind nur auf diesen drei Seiten erlaubt – überall sonst nicht.
legal='^website/(impressum\.html|datenschutz\.html|impressum\.json)$'
for w in ${words[@]+"${words[@]}"}; do
  scope="$files"
  if [[ -f website/impressum.json ]] && grep -qiF -- "$w" website/impressum.json; then scope=$(echo "$files" | grep -vE "$legal"); fi
  hits=$(echo "$scope" | tr '\n' '\0' | xargs -0 grep -nIiF -- "$w" 2>/dev/null | cut -c1-160)
  [[ -n "$hits" ]] && { echo "✗ Persönliches Wort „$w“:"; echo "$hits" | head -10; fail=1; }
done

# Fertige App: auch eingebaute Texte und Pfade prüfen
if [[ $# -ge 1 && -d "$1" ]]; then
  app="$1"
  blob=$(find "$app" -type f \( -perm -u+x -o -name "*.strings" -o -name "*.plist" -o -name "*.json" \) -print0 | xargs -0 strings -a 2>/dev/null)
  echo "$blob" | grep -qE "$secrets" && { echo "✗ Schlüssel in der App"; fail=1; }
  user=$(id -un)
  echo "$blob" | grep -qF "/Users/$user" && { echo "✗ Pfad /Users/$user ist in die App eingebaut"; echo "$blob" | grep -F "/Users/$user" | head -3; fail=1; }
  for w in ${words[@]+"${words[@]}"}; do echo "$blob" | grep -qiF -- "$w" && { echo "✗ „$w“ steckt in der App"; fail=1; }; done
  [[ -d "$app/Contents/Resources/data" ]] && { echo "✗ data/ ist in die App gepackt"; fail=1; }
fi

if [[ $fail -eq 0 ]]; then echo "✓ Datenschutz-Prüfung: nichts Persönliches oder Geheimes gefunden"; fi
exit $fail
