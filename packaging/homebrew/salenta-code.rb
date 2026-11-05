# Homebrew-Cask für Salenta Code (liegt im Tap salenta-code/homebrew-tap unter Casks/salenta-code.rb)
#   brew install --cask salenta-code/tap/salenta-code
# scripts/release.sh gibt Version und sha256 aus – hier eintragen.
cask "salenta-code" do
  version "0.2.0"
  sha256 "REPLACE_WITH_SHA256_FROM_latest.json"

  url "https://github.com/salenta-code/salenta-code/releases/download/v#{version}/Salenta-Code-#{version}.zip"
  name "Salenta Code"
  desc "One window for all your AI coding agents on the Mac"
  homepage "https://github.com/salenta-code/salenta-code"

  depends_on macos: ">= :sonoma"
  auto_updates true

  app "Salenta Code.app"

  caveats <<~EOS
    Signed with Developer ID and notarized by Apple. Updates install themselves.
    Recommended: brew install tmux gh node
  EOS
end
