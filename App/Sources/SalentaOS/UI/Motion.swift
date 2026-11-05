import SwiftUI

// Bewegung: dezent, schnell, nur wo sie etwas bedeutet (läuft gerade, neu dazugekommen, Zahl hat sich geändert).
// Mit „Bewegung reduzieren“ (Bedienungshilfen) bleibt alles ruhig.

/// Das Salenta-Zeichen, das „lebt“, solange Agents arbeiten: die Pulslinie läuft wie ein Herzschlag durch.
struct LiveMark: View {
    var size: CGFloat = 28
    var active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var run = false

    // Gemessen: die frühere Fassung zeichnete 30× pro Sekunde neu (TimelineView + Schatten) – je Zeichen, auch in der
    // Seitenleiste. Jetzt eine einzige Core-Animation, die das System selbst abspielt: kein Neuberechnen des Fensters.
    var body: some View {
        if active && !reduceMotion {
            if size < 18 {
                SalentaMark(size: size)
                    .opacity(run ? 0.45 : 1)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: run)
                    .onAppear { run = true }
            } else {
                SalentaMark(size: size)
                    .overlay(
                        SalentaPulse()
                            .trim(from: run ? 0.78 : 0, to: run ? 1 : 0.22)
                            .stroke(Color.white.opacity(0.9), style: StrokeStyle(lineWidth: size * 34 / 512, lineCap: .round, lineJoin: .round))
                            .frame(width: size, height: size)
                            .animation(.linear(duration: 1.6).repeatForever(autoreverses: false), value: run)
                    )
                    .onAppear { run = true }
            }
        } else {
            SalentaMark(size: size)
        }
    }
}

/// Ring für Verbrauch/Fortschritt, füllt sich animiert.
struct ProgressRing: View {
    var value: Double          // 0…1
    var color: Color
    var lineWidth: CGFloat = 8
    @State private var shown: Double = 0

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.18), lineWidth: lineWidth)
            Circle().trim(from: 0, to: shown)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .onAppear { withAnimation(.spring(response: 0.9, dampingFraction: 0.85)) { shown = min(max(value, 0), 1) } }
        .onChange(of: value) { _, v in withAnimation(.spring(response: 0.7, dampingFraction: 0.85)) { shown = min(max(v, 0), 1) } }
    }
}

extension View {
    /// Karten erscheinen weich (leicht von unten, eingeblendet), einmal beim ersten Anzeigen.
    func appearSoftly(delay: Double = 0) -> some View { modifier(AppearSoftly(delay: delay)) }
}

private struct AppearSoftly: ViewModifier {
    let delay: Double
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .opacity(shown || reduceMotion ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 10)
            .onAppear { withAnimation(.spring(response: 0.5, dampingFraction: 0.9).delay(delay)) { shown = true } }
    }
}

/// ScrollView, die nur so hoch ist wie ihr Inhalt – aber höchstens einen Anteil des Fensters.
/// Verhindert, dass hohe Karten (viele Dateien, viele Vorschläge) das Fenster-Layout sprengen.
struct BoundedScroll<Content: View>: View {
    var maxFraction: CGFloat = 0.45
    @ViewBuilder var content: () -> Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        let limit = max(220, (NSApp.keyWindow?.contentLayoutRect.height ?? NSScreen.main?.visibleFrame.height ?? 800) * maxFraction)
        ScrollView(.vertical) {
            content()
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { contentHeight = g.size.height }
                        .onChange(of: g.size.height) { _, h in contentHeight = h }
                })
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(max(contentHeight, 1), limit))
        .layoutPriority(-1)
    }
}
