import SwiftUI

/// Ersetzt SwiftUIs HSplitView in der ganzen App.
/// Das System-HSplitView beachtet die Werkzeugleiste nicht: Listen rutschten oben darunter und die ersten
/// Einträge waren abgeschnitten (besonders im Vollbild). Diese Version ist reines SwiftUI und hält den Abstand ein.
/// Spalten vor der letzten bekommen ihre ideale Breite (idealWidth) und lassen sich am Trenner ziehen,
/// die letzte Spalte nimmt den Rest.
struct HSplitView<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        _VariadicView.Tree(SplitRoot()) { content }
    }
}

private struct SplitRoot: _VariadicView_MultiViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        let lastID = children.last?.id
        HStack(spacing: 0) {
            ForEach(children) { child in
                if child.id == lastID {
                    child.frame(maxWidth: .infinity, maxHeight: .infinity).layoutPriority(1)
                } else {
                    SplitColumn { child }
                }
            }
        }
    }
}

/// Eine Spalte mit ziehbarem Trenner rechts daneben.
private struct SplitColumn<C: View>: View {
    @ViewBuilder var content: () -> C
    @State private var width: CGFloat?
    @State private var start: CGFloat?
    @State private var natural: CGFloat = 0

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if let width {
                    content().frame(width: width)
                } else {
                    content().fixedSize(horizontal: true, vertical: false)
                }
            }
            .frame(maxHeight: .infinity)
            .background(GeometryReader { g in Color.clear.onAppear { natural = g.size.width } })
            Divider()
                .overlay {
                    Color.clear.frame(width: 8).contentShape(Rectangle())
                        .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                        .gesture(DragGesture(minimumDistance: 1).onChanged { v in
                            if start == nil { start = width ?? natural }
                            width = min(max(160, (start ?? 0) + v.translation.width), 640)
                        }.onEnded { _ in start = nil })
                }
        }
    }
}
