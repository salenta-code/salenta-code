#!/bin/zsh
# Build and install Salenta Code. Double-click in Finder is enough (first time: right-click › Open).
# Everything is logged to logs/install.log.
cd "${0:A:h}"
mkdir -p logs data
log="$PWD/logs/install.log"
exec > >(tee "$log") 2>&1

echo "== Salenta Code – install $(date '+%Y-%m-%d %H:%M')"
echo "macOS $(sw_vers -productVersion) · $(uname -m)"

if ! xcode-select -p >/dev/null 2>&1; then
  echo "✗ Apple Command Line Tools are missing. The installer opens now – run Install.command again afterwards."
  xcode-select --install
  exit 1
fi
echo "Toolchain: $(xcode-select -p)"
swift --version 2>&1 | head -2

chmod +x bin/aos bin/aos-mcp bin/aos-live App/build.sh 2>/dev/null
# make the `aos` command available to agents (Claude Code, Codex, Junie …)
mkdir -p "$HOME/.local/bin"
ln -sf "$PWD/bin/aos" "$HOME/.local/bin/aos"

cd App && ./build.sh --open
rc=$?
echo "== Done (status $rc) $(date '+%H:%M:%S')"
if [[ $rc -ne 0 ]]; then
  echo "Build failed – see logs/install.log and logs/swift-build.log."
fi
