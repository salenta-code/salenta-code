import AgenticOSKit
import AppKit
import SwiftUI

// Erscheinungsbild: Salenta (Standard) oder ein Planet – je Planet eine Akzentfarbe, ein animierter Planet mit Sternen
// oben in der Seitenleiste und ein leichter Farbschimmer. Dazu Hell, Dunkel oder wie das System.

enum Planet: String, CaseIterable, Identifiable {
    case salenta, merkur, venus, erde, mars, jupiter, saturn, uranus, neptun
    var id: String { rawValue }

    var title: String {
        switch self {
        case .salenta: "Salenta"
        case .merkur: L("Merkur")
        case .venus: "Venus"
        case .erde: L("Erde")
        case .mars: "Mars"
        case .jupiter: "Jupiter"
        case .saturn: "Saturn"
        case .uranus: "Uranus"
        case .neptun: L("Neptun")
        }
    }

    /// Akzent für Knöpfe, Auswahl und Fortschritt – im Hellmodus dunkler, damit weiße Schrift darauf und
    /// farbige Schrift auf Weiß immer gut lesbar bleibt.
    var accent: Color {
        let (dark, light): (UInt32, UInt32) = {
            switch self {
            case .salenta: (0x0A84FF, 0x0066CC)
            case .merkur: (0xA8A29E, 0x57534E)
            case .venus: (0xE8B04B, 0x8F6210)
            case .erde: (0x2F9BFF, 0x0062C4)
            case .mars: (0xE5532D, 0xB0361A)
            case .jupiter: (0xD9A066, 0x8A5426)
            case .saturn: (0xE3C16F, 0x7D6219)
            case .uranus: (0x5ED6D6, 0x0F7272)
            case .neptun: (0x4B6BFF, 0x2D47CC)
            }
        }()
        return Color(nsColor: NSColor(name: nil) { a in
            a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }

    /// Farben der Planetenkugel (hell → dunkel) und Bänder
    var sphere: [Color] {
        switch self {
        case .salenta: [Color(white: 0.32), Color(white: 0.06)]
        case .merkur: [Color(hex: 0xC9C4BE), Color(hex: 0x6E6862), Color(hex: 0x2A2724)]
        case .venus: [Color(hex: 0xF6DDA0), Color(hex: 0xD99A3E), Color(hex: 0x5A3510)]
        case .erde: [Color(hex: 0x7CC4FF), Color(hex: 0x1F6FD1), Color(hex: 0x2E8B57), Color(hex: 0x0B2346)]
        case .mars: [Color(hex: 0xF4935F), Color(hex: 0xC2421C), Color(hex: 0x4A1308)]
        case .jupiter: [Color(hex: 0xF2D2A9), Color(hex: 0xC98B54), Color(hex: 0xE8C49A), Color(hex: 0x6B3E1E)]
        case .saturn: [Color(hex: 0xF7E3A6), Color(hex: 0xD3AE5B), Color(hex: 0x6E5524)]
        case .uranus: [Color(hex: 0xC6F4F4), Color(hex: 0x5ED6D6), Color(hex: 0x1D5E6B)]
        case .neptun: [Color(hex: 0x9BB0FF), Color(hex: 0x3C5BF0), Color(hex: 0x101C5C)]
        }
    }

    var banded: Bool { [.jupiter, .saturn, .erde].contains(self) }
    var ringed: Bool { [.saturn, .uranus].contains(self) }
}

enum Look {
    static var planet: Planet { Planet(rawValue: UserDefaults.standard.string(forKey: "theme.planet") ?? "") ?? .salenta }
}

/// Die Planetenkugel: Licht von links oben, langsam drehende Bänder, optional Ring.
struct PlanetSphere: View {
    let planet: Planet
    var size: CGFloat = 64
    // Standard: ruhend. Die Dauer-Drehung (18 s, endlos) ließ WindowServer ständig neu zeichnen – spürbar auf dem ganzen Mac.
    var animate = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var windowState
    @State private var turn = false

    private var moving: Bool { animate && !reduceMotion && windowState == .key && !Energy.saving }

    var body: some View {
        ZStack {
            if planet.ringed {
                Ellipse().stroke(planet.accent.opacity(0.55), lineWidth: size * 0.05)
                    .frame(width: size * 1.75, height: size * 0.42).rotationEffect(.degrees(-18))
            }
            Circle()
                .fill(RadialGradient(colors: planet.sphere, center: UnitPoint(x: 0.32, y: 0.28), startRadius: size * 0.02, endRadius: size * 0.75))
                .overlay(
                    // Bänder: ziehen langsam vorbei (eine einzige Core-Animation, kein Dauer-Neuzeichnen des Fensters)
                    Group {
                        if planet.banded {
                            LinearGradient(stops: (0..<9).map { i in .init(color: (i % 2 == 0 ? Color.white : Color.black).opacity(0.10), location: Double(i) / 8) },
                                           startPoint: .top, endPoint: .bottom)
                                .frame(width: size * 2.2)
                                .offset(x: turn ? -size * 0.6 : size * 0.6)
                        }
                    }
                    .clipShape(Circle())
                )
                .overlay(Circle().fill(RadialGradient(colors: [.clear, .black.opacity(0.55)], center: UnitPoint(x: 0.3, y: 0.25), startRadius: size * 0.3, endRadius: size * 0.7)))
                .frame(width: size, height: size)
                .shadow(color: planet.accent.opacity(0.45), radius: size * 0.35)
            if planet.ringed {
                // vorderer Teil des Rings über der Kugel
                Ellipse().trim(from: 0.0, to: 0.5).stroke(planet.accent.opacity(0.7), lineWidth: size * 0.05)
                    .frame(width: size * 1.75, height: size * 0.42).rotationEffect(.degrees(-18))
            }
            if planet == .salenta {
                SalentaPulse().stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: size * 0.045, lineCap: .round, lineJoin: .round))
                    .frame(width: size * 0.8, height: size * 0.8)
            }
        }
        .onAppear { if moving { withAnimation(.linear(duration: 18).repeatForever(autoreverses: true)) { turn = true } } }
    }
}

/// Sternenhimmel mit Planet – oben in der Seitenleiste (wie ein kleines Fenster ins All).
struct PlanetBackdrop: View {
    let planet: Planet
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack(alignment: .trailing) {
            LinearGradient(colors: scheme == .dark ? [planet.accent.opacity(0.28), .black.opacity(0.0)] : [planet.accent.opacity(0.22), .clear],
                           startPoint: .topTrailing, endPoint: .bottomLeading)
            Canvas { ctx, size in
                // feste Sterne (gleiches Muster bei jedem Zeichnen)
                var seed: UInt64 = 0x5A1E_17A
                func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(UInt32.max >> 1) }
                for _ in 0..<70 {
                    let p = CGPoint(x: rnd() * size.width, y: rnd() * size.height)
                    let r = 0.4 + rnd() * 1.1
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x, y: p.y, width: r, height: r)),
                             with: .color((scheme == .dark ? Color.white : planet.accent).opacity(0.25 + Double(rnd()) * 0.6)))
                }
            }
            PlanetSphere(planet: planet, size: 46)
                .offset(x: 6, y: -4)
        }
        .clipped()
        .allowsHitTesting(false)
    }
}

/// Auswahl: Planeten als Kugeln – antippen wechselt Akzent und Hintergrund.
struct PlanetPicker: View {
    @AppStorage("theme.planet") private var planetRaw = Planet.salenta.rawValue
    @AppStorage("theme.mode") private var mode = "system"

    var body: some View {
        VStack(alignment: .leading, spacing: Grid.m) {
            Text(L("Erscheinungsbild")).font(.headline)
            Picker("", selection: $mode) {
                Text(L("Wie System")).tag("system"); Text(L("Hell")).tag("light"); Text(L("Dunkel")).tag("dark"); Text(L("Schwarz")).tag("black")
            }.pickerStyle(.segmented).labelsHidden().frame(width: 360)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(78), spacing: 10), count: 5), spacing: 12) {
                ForEach(Planet.allCases) { p in
                    Button { withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) { planetRaw = p.rawValue } } label: {
                        VStack(spacing: 6) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black)
                                PlanetSphere(planet: p, size: 34, animate: false)
                            }
                            .frame(width: 70, height: 56)
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(planetRaw == p.rawValue ? p.accent : Color.white.opacity(0.08), lineWidth: planetRaw == p.rawValue ? 2 : 1))
                            .scaleEffect(planetRaw == p.rawValue ? 1.04 : 1)
                            Text(p.title).font(.caption).foregroundStyle(planetRaw == p.rawValue ? .primary : .secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Wendet Planet und Hell/Dunkel auf ein Fenster an.
struct PlanetLook: ViewModifier {
    @AppStorage("theme.planet") private var planetRaw = Planet.salenta.rawValue
    @AppStorage("theme.mode") private var mode = "system"
    func body(content: Content) -> some View {
        let p = Planet(rawValue: planetRaw) ?? .salenta
        content
            .tint(p.accent)
            // Hell/Dunkel über NSApp.appearance statt preferredColorScheme: nur so kehrt „Wie System“ sauber zurück,
            // ohne dass helle und dunkle Teile gemischt stehen bleiben.
            .onAppear { Self.apply(mode) }
            .onChange(of: mode) { _, m in Self.apply(m) }
            .environment(\.pureBlack, mode == "black")
            .animation(.easeInOut(duration: 0.35), value: planetRaw)
    }
}

extension PlanetLook {
    static func apply(_ mode: String) {
        let a: NSAppearance? = mode == "light" ? NSAppearance(named: .aqua) : (mode == "dark" || mode == "black") ? NSAppearance(named: .darkAqua) : nil
        guard NSApp.appearance != a else { return }
        NSApp.appearance = a
        for w in NSApp.windows { w.appearance = nil; w.invalidateShadow(); w.contentView?.needsDisplay = true }
    }
}

extension View {
    func planetLook() -> some View { modifier(PlanetLook()) }
}


/// Großer Kopfbereich (Übersicht): Karte mit Sternen und deinem Planeten, der rechts angeschnitten ins Bild ragt.
struct HeroBackdrop: View {
    @AppStorage("theme.planet") private var planetRaw = Planet.salenta.rawValue
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let p = Planet(rawValue: planetRaw) ?? .salenta
        ZStack(alignment: .trailing) {
            ModernCardBackground(tint: p.accent, radius: 20)
            PlanetBackdrop(planet: p).opacity(scheme == .dark ? 1 : 0.8)
            PlanetSphere(planet: p, size: 150)
                .offset(x: 60, y: 10)
                .opacity(0.9)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}


// „Schwarz“: echte schwarze Flächen wie auf salenta.ai (statt des grauen macOS-Dunkelmodus)
private struct PureBlackKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var pureBlack: Bool {
        get { self[PureBlackKey.self] }
        set { self[PureBlackKey.self] = newValue }
    }
}

struct PureBlackSurface: ViewModifier {
    @Environment(\.pureBlack) private var black
    var sidebar = false
    func body(content: Content) -> some View {
        if black {
            content.scrollContentBackground(.hidden).background(sidebar ? Color(white: 0.035) : Color.black)
        } else {
            content
        }
    }
}

extension View {
    func pureBlackSurface(sidebar: Bool = false) -> some View { modifier(PureBlackSurface(sidebar: sidebar)) }
}
