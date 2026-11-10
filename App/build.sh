#!/bin/zsh
# Baut Salenta Code und installiert es nach ~/Applications/Salenta Code.app.
# Build-Produkte liegen in ~/Library/Developer/AgenticOS, nicht im Projektordner.
#
#   ./build.sh            Release-Build, installieren
#   ./build.sh --debug    Debug-Build
#   ./build.sh --open     installieren, laufende Kopie beenden, neue öffnen
#   ./build.sh --check    nur bauen und Selbsttest (Prüfbefehl), nichts installieren
#   ./build.sh --release --out DIR   fertige App zum Veröffentlichen (Daten getrennt, Developer-ID-Signatur, gehärtete Laufzeit)
set -uo pipefail
here=${0:A:h}
name="SalentaOS"
# Anpassbar, z. B. für eine zweite Installation: AOS_APP_NAME="Salenta Code Dev" AOS_BUNDLE_ID=io.example.aos ./build.sh
# Deine Entwickler-Version heißt „Salenta Code Dev“ (eigene Kennung) – so verwechselst du sie nie mit der
# veröffentlichten App, die Nutzer (und du zum Testen) per .dmg installieren. Die fertige App bleibt „Salenta Code“.
if [[ " $* " == *" --release "* ]]; then
  display="${AOS_APP_NAME:-Salenta Code}"; bundle_id="${AOS_BUNDLE_ID:-ai.salenta.os}"
else
  display="${AOS_APP_NAME:-Salenta Code Dev}"; bundle_id="${AOS_BUNDLE_ID:-ai.salenta.os.dev}"
fi
root="${here:h}"
scratch="$HOME/Library/Developer/$bundle_id/build"
logdir="$here/../logs"
mkdir -p "$logdir"
log="$logdir/swift-build.log"
config=release
[[ " $* " == *" --debug "* ]] && config=debug
release=0; [[ " $* " == *" --release "* ]] && release=1
outdir=""
args=("$@"); for ((i=1; i<=${#args}; i++)); do [[ "${args[i]}" == "--out" ]] && outdir="${args[i+1]}"; done
version=$(cat "$root/VERSION" 2>/dev/null || echo 0.1.0)
update_repo="${UPDATE_REPO:-$(cat "$root/UPDATE_REPO" 2>/dev/null || echo "")}"

identity="${SIGN_IDENTITY:-}"
if [[ -z "$identity" && $release -eq 1 ]]; then
  identity=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 -o '"Developer ID Application: [^"]*"' | tr -d '"' || true)
  [[ -n "$identity" ]] || { echo "✗ Kein „Developer ID Application“-Zertifikat im Schlüsselbund – siehe Einstellungen › Updates"; exit 1; }
fi
if [[ -z "$identity" ]]; then
  identity=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 -o '"Apple Development: [^"]*"' | tr -d '"' || true)
fi
# Entwickler-Version: sonst mit dem vorhandenen Developer-ID-Zertifikat signieren. Eine feste Signatur sorgt dafür, dass macOS
# „Immer erlauben“ (Schlüsselbund, Ordnerzugriff) über Neubauten hinweg behält – ohne neue Rückfrage nach jedem Neubau.
if [[ -z "$identity" ]]; then
  identity=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 -o '"Developer ID Application: [^"]*"' | tr -d '"' || true)
fi
[[ -n "$identity" ]] || identity=-
# Developer ID: gehärtete Laufzeit (Pflicht für Apples Beglaubigung)
sign_opts=()
if [[ "$identity" == Developer\ ID* ]]; then
  sign_opts=(--options runtime)
  [[ $release -eq 1 ]] && sign_opts+=(--timestamp)   # Zeitstempel nur für die Veröffentlichung (braucht Internet)
fi

echo "→ swift build ($config) – erster Lauf lädt SwiftTerm und dauert 1–3 Minuten …"
mkdir -p "$scratch"; touch "$scratch/.build-start"
# Keine Pfade von deinem Mac (Benutzername, Ordner) in die App einbauen
prefix_map=()
prefix_map=(-Xswiftc -file-prefix-map -Xswiftc "$here=/salenta-code" -Xswiftc -file-prefix-map -Xswiftc "$HOME=/home")
if [[ $release -eq 1 ]]; then
  # Fertige App für alle Macs: Apple Silicon (M1–M5) und Intel – beide gebaut und zu einer Datei vereint
  code=0; : > "$log"
  for arch in arm64 x86_64; do
    echo "  · $arch"
    swift build -c $config --package-path "$here" --scratch-path "$scratch/$arch" --triple "$arch-apple-macosx14.0" "${prefix_map[@]}" >> "$log" 2>&1 || code=$?
  done
  if [[ $code -eq 0 ]]; then
    mkdir -p "$scratch/$config"
    for prod in SalentaOS SalentaWidgets; do
      # Swift selbst nach dem Ausgabeordner fragen – der heißt je nach Swift-Version „release“ oder „Products/Release“
      ad="$(swift build -c $config --package-path "$here" --scratch-path "$scratch/arm64" --triple arm64-apple-macosx14.0 --show-bin-path 2>/dev/null | tail -1)"
      xd="$(swift build -c $config --package-path "$here" --scratch-path "$scratch/x86_64" --triple x86_64-apple-macosx14.0 --show-bin-path 2>/dev/null | tail -1)"
      a=""; x=""
      [[ -n "$ad" && -f "$ad/$prod" ]] && a="$ad/$prod"
      [[ -n "$xd" && -f "$xd/$prod" ]] && x="$xd/$prod"
      # Rückfallweg: suchen (Groß-/Kleinschreibung egal, Symlinks folgen)
      [[ -z "$a" ]] && a="$(find -L "$scratch/arm64" -ipath "*/$config/$prod" -type f -perm -u+x 2>/dev/null | head -1)"
      [[ -z "$x" ]] && x="$(find -L "$scratch/x86_64" -ipath "*/$config/$prod" -type f -perm -u+x 2>/dev/null | head -1)"
      rm -f "$scratch/$config/$prod"
      if [[ -n "$a" && -n "$x" ]] && [[ "$(lipo -archs "$a" 2>/dev/null)" == *arm64* && "$(lipo -archs "$x" 2>/dev/null)" == *x86_64* ]]; then
        lipo -create "$a" "$x" -output "$scratch/$config/$prod" 2>>"$log" || { echo "  ✗ lipo $prod: $(tail -1 "$log")"; [[ $prod == SalentaOS ]] && code=1; }
      else
        # Klarer Hinweis statt stillem Abbruch: welche Datei fehlt oder hat die falsche Architektur
        echo "  ✗ $prod: arm64=${a:-fehlt} [$(lipo -archs "$a" 2>/dev/null)] · x86_64=${x:-fehlt} [$(lipo -archs "$x" 2>/dev/null)]"
        [[ $prod == SalentaOS ]] && code=1
      fi
    done
    abin="$(swift build -c $config --package-path "$here" --scratch-path "$scratch/arm64" --triple arm64-apple-macosx14.0 --show-bin-path 2>/dev/null | tail -1)"
    for b in "$abin"/*.bundle(N) "$scratch/arm64"/*/$config/*.bundle(N); do cp -R "$b" "$scratch/$config/"; done
    echo "  · vereint: $(lipo -archs "$scratch/$config/SalentaOS" 2>/dev/null)"
  fi
else
  swift build -c $config --package-path "$here" --scratch-path "$scratch" "${prefix_map[@]}" > "$log" 2>&1
  code=$?
fi
grep -E "error:|Build complete|Compiling|Fetching|Resolving" "$log" | grep -v "^\[" | tail -40
if [[ $code -ne 0 ]]; then
  echo "✗ Build fehlgeschlagen (Details: logs/swift-build.log)"
  exit 1
fi
bin="$scratch/$config/$name"
[[ -x "$bin" ]] || { echo "✗ Binary fehlt: $bin"; exit 1; }
# Während des Builds geänderte Dateien wären nicht enthalten → lieber abbrechen.
stale=$(find "$here/Sources" -name '*.swift' -newer "$scratch/.build-start" | head -1)
if [[ -n "$stale" ]]; then
  echo "✗ Build fehlgeschlagen: $stale wurde während des Builds geändert – bitte erneut bauen"
  exit 1
fi

# Selbsttest: nur installieren, wenn er grün ist – sonst bleibt die laufende Version unangetastet.
echo "→ Selbsttest …"
# Ohne Terminal-Bindung starten (eigene Sitzung): aus einem Terminal heraus würden interaktive Shells im Test sonst
# vom Terminal angehalten (SIGTTOU) und als „hängt“ gewertet. Gestartet aus der App gibt es kein Terminal – dort egal.
AOS_SRC="$root" /usr/bin/perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' "$bin" --selftest > "$logdir/selftest.log" 2>&1 </dev/null
st=$?
tail -1 "$logdir/selftest.log"
if [[ $st -ne 0 ]]; then
  grep "✗" "$logdir/selftest.log" | head -10
  echo "✗ Selbsttest rot – nicht installiert, die bisherige Version bleibt (Details: logs/selftest.log)"
  exit 1
fi
[[ " $* " == *" --check "* ]] && { echo "✓ Prüfung bestanden (--check: nichts installiert)"; exit 0; }

app="$HOME/Applications/$display.app"
[[ -n "$outdir" ]] && { mkdir -p "$outdir"; app="${outdir:A}/$display.app"; }
mkdir -p "$HOME/Applications"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/$name"
# SwiftPM-Ressourcenbündel (falls eine Abhängigkeit welche mitbringt)
for b in "$scratch/$config"/*.bundle(N); do cp -R "$b" "$app/Contents/Resources/"; done
# Fertige App: kein Quellcode-Ordner (Daten unter ~/Library/Application Support/Salenta Code), Version aus VERSION
rootkey="$root"; [[ $release -eq 1 ]] && rootkey=""
sed -e "s|__BUILD__|$(date +%Y%m%d%H%M)|" -e "s|__BUNDLE_ID__|$bundle_id|" -e "s|__DISPLAY__|$display|" -e "s|__ROOT__|$rootkey|" \
    -e "s|__VERSION__|$version|" -e "s|__UPDATE_REPO__|$update_repo|" \
    "$here/Info.plist.in" > "$app/Contents/Info.plist"
# Werkzeuge für die Agents mitliefern (die fertige App legt sie beim Start bereit)
mkdir -p "$app/Contents/Resources/bin"
cp "$root/bin/aos" "$root/bin/aos-mcp" "$root/bin/aos-live" "$root/bin/aos-setup" "$root/bin/timeout" "$root/bin/salenta-harness" "$root/bin/aos-ask" "$app/Contents/Resources/bin/" 2>/dev/null || true
rm -rf "$app/Contents/Resources/bin/harness"; cp -R "$root/bin/harness" "$app/Contents/Resources/bin/harness" 2>/dev/null || true; rm -rf "$app/Contents/Resources/bin/harness/test"
# Übersetzungen (en, de)
for l in "$here/Resources"/*.lproj(N); do cp -R "$l" "$app/Contents/Resources/"; done
[[ -f "$here/Resources/AppIcon.icns" ]] && cp "$here/Resources/AppIcon.icns" "$app/Contents/Resources/"
# Hilfe (eine Quelle für App und GitHub)
for h in HILFE HELP; do [[ -f "$root/docs/$h.md" ]] && cp "$root/docs/$h.md" "$app/Contents/Resources/"; done
# Mac-Widgets: als App-Erweiterung (.appex) einbetten – abgeschottet, liest nur den Widget-Ordner
wbin="$scratch/$config/SalentaWidgets"
if [[ -x "$wbin" ]]; then
  appex="$app/Contents/PlugIns/SalentaWidgets.appex"
  mkdir -p "$appex/Contents/MacOS"
  cp "$wbin" "$appex/Contents/MacOS/SalentaWidgets"
  sed -e "s|__BUILD__|$(date +%Y%m%d%H%M)|" -e "s|__BUNDLE_ID__|$bundle_id|" -e "s|__DISPLAY__|$display|" \
      "$here/Widgets/Info.plist.in" > "$appex/Contents/Info.plist"
fi
xattr -cr "$app"
# erst die Erweiterung (mit eigenen Rechten), dann die App – kein --deep, das würde die Rechte der Erweiterung überschreiben
[[ -d "$app/Contents/PlugIns/SalentaWidgets.appex" ]] && \
  codesign --force "${sign_opts[@]}" --sign "$identity" --entitlements "$here/Widgets/Widgets.entitlements" "$app/Contents/PlugIns/SalentaWidgets.appex" 2>&1 | grep -v "replacing existing signature" || true
for b in "$app/Contents/Resources/bin/"*(N); do codesign --force "${sign_opts[@]}" --sign "$identity" "$b" 2>/dev/null || true; done
codesign --force "${sign_opts[@]}" --sign "$identity" --entitlements "$here/App.entitlements" "$app" 2>&1 | grep -v "replacing existing signature" || true
if [[ $release -eq 1 ]]; then
  codesign --verify --deep --strict "$app" || { echo "✗ Signatur ungültig"; exit 1; }
  echo "✓ fertige App: $app ($version, signiert: $identity)"
  exit 0
fi
# alte Entwickler-Installationen unter früheren Namen (die .dmg-App liegt in /Applications – bleibt unberührt).
# Beendet und entfernt werden sie erst im Neustart-Schritt unten, damit dieser Build nicht mit abgebrochen wird.
cleanup=""
for old in "$HOME/Applications/Salenta OS.app" "$HOME/Applications/Salenta Code.app"; do
  [[ "$old" == "$app" || ! -d "$old" ]] && continue
  cleanup+="pkill -f '$old/Contents/MacOS/SalentaOS'; for i in {1..60}; do pgrep -fq '$old/Contents/MacOS/SalentaOS' || break; sleep 0.5; done; rm -rf '$old'; "
done
[[ " $* " != *" --open "* && -n "$cleanup" ]] && echo "  Hinweis: alte Version unter früherem Namen noch vorhanden – wird beim nächsten „neu bauen und starten“ entfernt"
# Widgets beim System anmelden (Ergebnis in logs/widgets.log)
if [[ -d "$app/Contents/PlugIns/SalentaWidgets.appex" ]]; then
  { date; /usr/bin/pluginkit -a "$app/Contents/PlugIns/SalentaWidgets.appex" 2>&1; /usr/bin/pluginkit -m -v -i "$bundle_id.widgets" 2>&1;
    /usr/bin/codesign -d --entitlements - "$app/Contents/PlugIns/SalentaWidgets.appex" 2>&1 | tail -5; } > "$logdir/widgets.log"
fi
echo "✓ installiert: $app (signiert: ${identity})"

if [[ " $* " == *" --open "* ]]; then
  # Neustart über launchd (einmalig, kein KeepAlive): läuft unabhängig von der App weiter und wartet,
  # bis die alte Kopie wirklich weg ist – auch wenn du „Agent läuft noch“ erst später bestätigst.
  logs="${0:A:h}/../logs"; mkdir -p "$logs"
  job="ai.salenta.os.restart"; plist="${TMPDIR:-/tmp}/$job.plist"
  script="${cleanup}for i in {1..600}; do pgrep -fq '$app/Contents/MacOS/SalentaOS' || break; sleep 0.5; done; for i in 1 2 3; do open '$app' && break; sleep 2; done; echo \"\$(date '+%F %T') neu gestartet\" >> '$logs/restart.log'"
  cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$job</string>
  <key>ProgramArguments</key><array><string>/bin/zsh</string><string>-c</string><string>${script//&/&amp;}</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
  <key>LaunchOnlyOnce</key><true/>
</dict></plist>
PLIST
  launchctl bootout "gui/$(id -u)/$job" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$plist" 2>/dev/null || { (for i in {1..30}; do pgrep -fq "$app/Contents/MacOS/SalentaOS" || break; sleep 0.5; done; open "$app") & }
  sleep 0.5
  osascript -e "quit app id \"$bundle_id\"" 2>/dev/null || true
fi
