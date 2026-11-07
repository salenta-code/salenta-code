import AgenticOSKit
import AppKit
import SwiftUI

// Native Mac-Optik: Systemfarben, eine Akzentfarbe, 4-pt-Raster.
// Firmenfarben nur als Kennzeichnung (Chips, Punkte), nie als Fläche.

enum Grid {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

extension Color {
    init(hex: UInt32) { self.init(nsColor: NSColor(hex: hex)) }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

extension Company {
    var color: Color { Color(hex: hex) }
}

/// Eine Kachel im Cockpit.
struct Card<Content: View>: View {
    let title: String
    let symbol: String
    var trailing: AnyView? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Grid.m) {
            HStack(spacing: Grid.s) {
                Image(systemName: symbol).foregroundStyle(Color.accentColor)
                Text(title).font(.headline)
                Spacer()
                if let trailing { trailing }
            }
            content()
        }
        .padding(Grid.l)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(ModernCardBackground())
        .appearIn()
    }
}

struct CompanyChip: View {
    let company: Company
    var compact = false

    var body: some View {
        HStack(spacing: Grid.xs) {
            Circle().fill(company.color).frame(width: 7, height: 7)
            if !compact { Text(company.title).font(.caption) }
        }
        .padding(.horizontal, compact ? 0 : 6)
        .padding(.vertical, compact ? 0 : 2)
        .background(compact ? Color.clear : company.color.opacity(0.12), in: Capsule())
    }
}

struct StatTile: View {
    let value: String
    let label: String
    let symbol: String
    var tint: Color = .accentColor
    @State private var hover = false

    var body: some View {
        HStack(spacing: Grid.m) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.14)))
            VStack(alignment: .leading, spacing: 1) {
                Text(value).font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy, value: value)
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(Grid.m)
        .background(ModernCardBackground(tint: tint, radius: 14))
        .scaleEffect(hover ? 1.015 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: hover)
        .onHover { hover = $0 }
    }
}

/// Karten-Hintergrund im Stil der Website: ruhige Fläche, feine Kante, ein Hauch Akzent oben.
struct ModernCardBackground: View {
    var tint: Color = .accentColor
    var radius: CGFloat = 16
    var accent = true
    @Environment(\.colorScheme) private var scheme
    @Environment(\.pureBlack) private var black
    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(black ? SC.card : scheme == .dark ? Color(nsColor: .underPageBackgroundColor) : Color.white)
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(LinearGradient(colors: [tint.opacity(accent ? (scheme == .dark ? 0.10 : 0.06) : 0), .clear], startPoint: .top, endPoint: .center))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [accent ? tint.opacity(0.35) : (scheme == .dark ? SC.line : Color.black.opacity(0.08)), (scheme == .dark ? SC.line : Color.black.opacity(0.08))],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 1)
            )
    }
}

extension Date {
    var timeString: String { formatted(date: .omitted, time: .shortened) }
}
