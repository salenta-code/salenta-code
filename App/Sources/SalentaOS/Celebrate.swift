import AgenticOSKit
import AppKit
import SwiftUI

// Kleine Erfolgsmomente: Wenn etwas geschafft ist (Auftrag grün, übernommen, gemergt, Aufgabe erledigt),
// ploppt oben eine Karte auf – Haken zeichnet sich, ein paar Funken fliegen, nach 2,6 s ist sie weg.
// Respektiert „Bewegung reduzieren“ (dann nur ein sanftes Einblenden) und lässt sich abschalten.

final class Celebration: ObservableObject {
    static let shared = Celebration()

    struct Moment: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let subtitle: String
        let symbol: String
        let tint: Color
    }

    @Published private(set) var current: Moment?
    private var queue: [Moment] = []
    private var lastFired: [String: Date] = [:]

    var enabled: Bool { UserDefaults.standard.object(forKey: "celebrate.on") as? Bool ?? true }

    /// Gleiche Nachricht höchstens einmal in 10 s; mehrere hintereinander werden nacheinander gezeigt.
    func fire(_ title: String, _ subtitle: String = "", symbol: String = "checkmark", tint: Color = .green) {
        DispatchQueue.main.async { [self] in
            guard enabled else { return }
            let key = title + subtitle
            if let t = lastFired[key], Date().timeIntervalSince(t) < 10 { return }
            lastFired[key] = Date()
            queue.append(Moment(title: title, subtitle: subtitle, symbol: symbol, tint: tint))
            if current == nil { next() }
        }
    }

    private func next() {
        guard !queue.isEmpty else { current = nil; return }
        current = queue.removeFirst()
        if UserDefaults.standard.object(forKey: "celebrate.sound") as? Bool ?? true, NSApp.isActive {
            NSSound(named: "Glass")?.play()
        }
        let id = current?.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6) { [self] in
            guard current?.id == id else { return }
            current = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.next() }
        }
    }

    func dismiss() { current = nil; DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.next() } }
}

struct CelebrationOverlay: View {
    @ObservedObject private var c = Celebration.shared

    var body: some View {
        ZStack {
            if let m = c.current {
                CelebrationCard(moment: m)
                    .id(m.id)
                    .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.92)),
                                            removal: .opacity.combined(with: .scale(scale: 0.96))))
                    .onTapGesture { c.dismiss() }
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: c.current)
        .padding(.top, 14)
        .allowsHitTesting(c.current != nil)
    }
}

private struct CelebrationCard: View {
    let moment: Celebration.Moment
    @Environment(\.accessibilityReduceMotion) private var reduce
    @State private var drawn: CGFloat = 0
    @State private var burst = false
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(moment.tint.opacity(0.18)).frame(width: 34, height: 34)
                    .scaleEffect(pulse ? 1.25 : 1).opacity(pulse ? 0 : 1)
                Circle().fill(moment.tint).frame(width: 30, height: 30)
                if moment.symbol == "checkmark" {
                    CheckShape().trim(from: 0, to: drawn)
                        .stroke(.white, style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
                        .frame(width: 13, height: 10)
                } else {
                    Image(systemName: moment.symbol).font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                        .scaleEffect(drawn == 0 ? 0.4 : 1)
                }
                if !reduce { Sparks(tint: moment.tint, go: burst) }
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(moment.title).font(.callout.weight(.semibold)).lineLimit(1)
                if !moment.subtitle.isEmpty {
                    Text(moment.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: 360, alignment: .leading)
        }
        .padding(.leading, 10).padding(.trailing, 18).padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(moment.tint.opacity(0.35)))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        .onAppear {
            if reduce { drawn = 1; return }
            withAnimation(.easeOut(duration: 0.38).delay(0.12)) { drawn = 1 }
            withAnimation(.easeOut(duration: 0.7).delay(0.15)) { burst = true }
            withAnimation(.easeOut(duration: 0.9).delay(0.1)) { pulse = true }
        }
        .help(L("Klicken zum Schließen"))
        .accessibilityElement(children: .combine)
    }
}

/// Haken als Linie – wird per trim „gezeichnet“.
private struct CheckShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.midY + r.height * 0.05))
        p.addLine(to: CGPoint(x: r.minX + r.width * 0.36, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        return p
    }
}

/// Acht kleine Funken, die vom Haken wegfliegen und verblassen.
private struct Sparks: View {
    let tint: Color
    let go: Bool
    var body: some View {
        ZStack {
            ForEach(0..<8, id: \.self) { i in
                let a = Double(i) / 8 * 2 * .pi
                Capsule()
                    .fill(i.isMultiple(of: 2) ? tint : Color.yellow)
                    .frame(width: 3, height: 7)
                    .rotationEffect(.radians(a + .pi / 2))
                    .offset(x: go ? cos(a) * 26 : cos(a) * 10, y: go ? sin(a) * 26 : sin(a) * 10)
                    .opacity(go ? 0 : 1)
                    .scaleEffect(go ? 0.5 : 1)
            }
        }
        .allowsHitTesting(false)
    }
}
