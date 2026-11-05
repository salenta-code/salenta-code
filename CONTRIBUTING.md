# Contributing

Thanks for helping! Salenta Code is a native SwiftUI app (macOS 14+) plus a few Python helpers.

- Build: `cd App && ./build.sh --open` (log: `logs/swift-build.log`). Tests: `swift test --package-path App` (needs Xcode – the Command Line Tools alone ship neither XCTest nor Swift Testing).
- UI texts are written in German in the source; English lives in `App/Resources/en.lproj/Localizable.strings`
  (key = German text). Add both when you add a string.
- Keep it simple and native: SF Symbols, system colors, spacing from `Grid`.
- No personal data, tokens or API keys in commits. `data/` and `logs/` are ignored on purpose.
- New integrations should be MCP servers (add to `data/mcp-catalog.json`) rather than hard-coded code paths.
