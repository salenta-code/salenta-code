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
                Image(systemName: symbol).foregroundStyle(.secondary)
                Text(title).font(.headline)
                Spacer()
                if let trailing { trailing }
            }
            content()
        }
        .padding(Grid.l)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.background.secondary))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6)))
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

    var body: some View {
        HStack(spacing: Grid.m) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(.title2.weight(.semibold)).monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy, value: value)
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(Grid.m)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.background.secondary))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }
}

extension Date {
    var timeString: String { formatted(date: .omitted, time: .shortened) }
}
