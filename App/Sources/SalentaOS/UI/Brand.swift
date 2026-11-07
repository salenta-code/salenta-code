import AgenticOSKit
import AppKit
import SwiftUI

// Markenzeichen: die Salenta-Pulslinie, in Schwarz nachgebaut (Kachel schwarz, Linie weiß).

/// Die Pulslinie aus dem Salenta-Zeichen (Koordinaten im 512er Raster, skaliert auf das Rechteck).
struct SalentaPulse: Shape {
    static let points: [CGPoint] = [
        CGPoint(x: 118, y: 256), CGPoint(x: 208, y: 256), CGPoint(x: 236, y: 168),
        CGPoint(x: 276, y: 344), CGPoint(x: 316, y: 136), CGPoint(x: 348, y: 256), CGPoint(x: 394, y: 256),
    ]
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 512
        let ox = rect.midX - 256 * s, oy = rect.midY - 256 * s
        var p = Path()
        for (i, pt) in Self.points.enumerated() {
            let q = CGPoint(x: ox + pt.x * s, y: oy + pt.y * s)
            if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
        }
        return p
    }
}

/// Das Zeichen als Kachel (schwarz, weiße Linie mit Punkt).
struct SalentaMark: View {
    var size: CGFloat = 28
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.223, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.17), Color(white: 0.04)], startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: size * 0.223, style: .continuous)
                .strokeBorder(Color.white.opacity(0.09), lineWidth: max(0.5, size / 170))
            SalentaPulse()
                .stroke(Color.white, style: StrokeStyle(lineWidth: size * 28 / 512, lineCap: .round, lineJoin: .round))
            Circle().fill(Color.white)
                .frame(width: size * 36 / 512, height: size * 36 / 512)
                .offset(x: size * (394 - 256) / 512)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Salenta Code")
    }
}

/// Logo + Schriftzug für die Seitenleiste.
struct BrandHeader: View {
    var active = false
    @AppStorage("theme.planet") private var planetRaw = Planet.salenta.rawValue
    @State private var picking = false
    var body: some View {
        let planet = Planet(rawValue: planetRaw) ?? .salenta
        HStack(spacing: 8) {
            LiveMark(size: 22, active: active)
            HStack(spacing: 4) {
                Text("salenta").font(.system(size: 15, weight: .semibold, design: .rounded)).kerning(-0.3)
                Text("Code").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.4)))
                if Paths.isDevBuild {
                    Text("DEV").font(.system(size: 10, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.orange))
                        .help(L("Deine Entwickler-Version – hier testest du und veröffentlichst neue Versionen"))
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 6)
        .frame(height: 64, alignment: .center)
        // eigener Hintergrund: die Liste scrollt sonst sichtbar unter dem Logo durch – mit Sternen und deinem Planeten
        .background(ZStack { Rectangle().fill(.bar); PlanetBackdrop(planet: planet) })
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { picking = true }
        .contextMenu { Button(L("Planet wählen …")) { picking = true } }
        .popover(isPresented: $picking, arrowEdge: .trailing) { PlanetPicker().padding(Grid.l).frame(width: 470) }
        .help(L("Doppelklick: Planet und Hell/Dunkel wählen"))
    }
}

enum BrandImage {
    /// Menüleisten-Symbol: nur die Pulslinie als Vorlage (passt sich hell/dunkel an).
    static let menuBar: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: true) { r in
            let s = r.width / 512 * 1.25
            let ox = r.midX - 256 * s, oy = r.midY - 256 * s
            let p = NSBezierPath()
            for (i, pt) in SalentaPulse.points.enumerated() {
                let q = NSPoint(x: ox + pt.x * s, y: oy + pt.y * s)
                if i == 0 { p.move(to: q) } else { p.line(to: q) }
            }
            p.lineWidth = 1.9; p.lineCapStyle = .round; p.lineJoinStyle = .round
            NSColor.black.setStroke(); p.stroke()
            let d: CGFloat = 3.2
            let end = NSPoint(x: ox + 394 * s, y: oy + 256 * s)
            NSBezierPath(ovalIn: NSRect(x: end.x - d / 2, y: end.y - d / 2, width: d, height: d)).fill()
            return true
        }
        img.isTemplate = true
        return img
    }()
}

// MARK: - Salenta-Farben (wie auf salenta.ai): Schwarz/Weiß, Blau als Akzent, Grün = läuft, Orange = Achtung

enum SC {
    static let blue = Color(red: 10 / 255, green: 132 / 255, blue: 1)          // #0A84FF
    static let live = Color(red: 50 / 255, green: 215 / 255, blue: 75 / 255)    // #32D74B
    static let warn = Color(red: 1, green: 159 / 255, blue: 10 / 255)           // #FF9F0A
    static let red = Color(red: 1, green: 69 / 255, blue: 58 / 255)             // #FF453A
    static let ink = Color(red: 245 / 255, green: 245 / 255, blue: 247 / 255)   // #F5F5F7
    static let card = Color(red: 19 / 255, green: 19 / 255, blue: 23 / 255)     // #131317
    static let line = Color(red: 35 / 255, green: 35 / 255, blue: 41 / 255)     // #232329
    static let bg = Color(red: 9 / 255, green: 9 / 255, blue: 11 / 255)         // #09090B
}

/// Startbild: Weltraum mit Sternen und Nebel, Salenta als Planet – die Pulslinie zeichnet sich über die Kugel,
/// ein Mond zieht seine Bahn, dann blendet alles weich aus.
struct SplashOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draw: CGFloat = 0
    @State private var dot = false
    @State private var visible = true
    @State private var rise = false
    @State private var twinkle = false
    @State private var orbit = false
    private let size: CGFloat = 150

    var body: some View {
        if visible {
            ZStack {
                // Weltraum: fast schwarz, zwei Nebel, Sterne in zwei Ebenen (die vordere funkelt)
                Color.black.ignoresSafeArea()
                RadialGradient(colors: [SC.blue.opacity(0.28), .clear], center: UnitPoint(x: 0.72, y: 0.25), startRadius: 0, endRadius: 520)
                RadialGradient(colors: [Color(hex: 0x7B3FE4).opacity(0.22), .clear], center: UnitPoint(x: 0.2, y: 0.8), startRadius: 0, endRadius: 480)
                StarField(count: 220, seed: 7).opacity(0.7)
                StarField(count: 60, seed: 42, big: true).opacity(twinkle ? 1 : 0.35)
                VStack(spacing: 26) {
                    ZStack {
                        // Umlaufbahn mit Mond
                        Ellipse().stroke(Color.white.opacity(0.12), lineWidth: 1)
                            .frame(width: size * 1.9, height: size * 0.55).rotationEffect(.degrees(-14))
                        Circle().fill(Color.white).frame(width: 7, height: 7)
                            .shadow(color: .white, radius: 4)
                            .offset(x: orbit ? size * 0.95 : -size * 0.95)
                            .rotationEffect(.degrees(-14))
                        // Salenta als Planet
                        Circle()
                            .fill(RadialGradient(colors: [Color(white: 0.30), Color(white: 0.08), .black], center: UnitPoint(x: 0.32, y: 0.28),
                                                 startRadius: 2, endRadius: size * 0.75))
                            .overlay(Circle().strokeBorder(LinearGradient(colors: [SC.blue.opacity(0.9), .clear], startPoint: .topTrailing, endPoint: .bottomLeading), lineWidth: 2))
                            .shadow(color: SC.blue.opacity(dot ? 0.55 : 0.15), radius: 40)
                            .frame(width: size, height: size)
                        SalentaPulse()
                            .trim(from: 0, to: draw)
                            .stroke(Color.white, style: StrokeStyle(lineWidth: size * 26 / 512, lineCap: .round, lineJoin: .round))
                            .frame(width: size, height: size)
                        Circle().fill(Color.white)
                            .frame(width: size * 34 / 512, height: size * 34 / 512)
                            .scaleEffect(dot ? 1 : 0.01)
                            .offset(x: size * (394 - 256) / 512)
                    }
                    .frame(width: size * 2, height: size * 1.2)
                    .scaleEffect(rise ? 1 : 0.86)
                    .offset(y: rise ? 0 : 16)
                    HStack(spacing: 7) {
                        Text("salenta").font(.system(size: 30, weight: .semibold, design: .rounded)).kerning(-0.6)
                        Text("Code").font(.system(size: 16, weight: .bold, design: .rounded)).foregroundStyle(.white.opacity(0.6))
                    }
                    .foregroundStyle(SC.ink)
                    .opacity(dot ? 1 : 0)
                    .offset(y: dot ? 0 : 8)
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 1.04)))
            .onAppear {
                guard !reduceMotion else {
                    draw = 1; dot = true; rise = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { withAnimation(.easeOut(duration: 0.25)) { visible = false } }
                    return
                }
                withAnimation(.spring(response: 0.8, dampingFraction: 0.8)) { rise = true }
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { twinkle = true }
                withAnimation(.easeInOut(duration: 1.8)) { orbit = true }
                withAnimation(.easeInOut(duration: 0.8).delay(0.15)) { draw = 1 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) { dot = true } }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { withAnimation(.easeOut(duration: 0.45)) { visible = false } }
            }
        }
    }
}

/// Sterne (festes Muster je seed, gezeichnet in einem Durchgang)
struct StarField: View {
    var count: Int
    var seed: UInt64
    var big = false
    var body: some View {
        Canvas { ctx, size in
            var x = seed &* 0x9E3779B97F4A7C15
            func rnd() -> CGFloat { x = x &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(x >> 33) / CGFloat(UInt32.max >> 1) }
            for _ in 0..<count {
                let p = CGPoint(x: rnd() * size.width, y: rnd() * size.height)
                let r = big ? 1.2 + rnd() * 1.6 : 0.4 + rnd() * 0.9
                ctx.fill(Path(ellipseIn: CGRect(x: p.x, y: p.y, width: r, height: r)), with: .color(.white.opacity(0.3 + Double(rnd()) * 0.7)))
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Karten erscheinen weich (leicht von unten) – sparsam, ohne Daueranimation.
struct AppearIn: ViewModifier {
    var delay: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var on = false
    func body(content: Content) -> some View {
        content
            .opacity(on || reduceMotion ? 1 : 0)
            .offset(y: on || reduceMotion ? 0 : 8)
            .onAppear { withAnimation(.spring(response: 0.45, dampingFraction: 0.85).delay(delay)) { on = true } }
    }
}

extension View {
    func appearIn(_ delay: Double = 0) -> some View { modifier(AppearIn(delay: delay)) }
}
