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
    var body: some View {
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
        // eigener Hintergrund: die Liste scrollt sonst sichtbar unter dem Logo durch
        .background(.bar)
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
