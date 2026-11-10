import Foundation

// Eingebauter Gestaltungs-Leitfaden für Oberflächen-Aufträge.
// Läuft mit jedem Coding-Agent (nicht nur mit installierten Design-Plugins) und sorgt dafür,
// dass sichtbare Ergebnisse eigenständig, ruhig und sauber gebaut sind statt nach KI-Vorlage auszusehen.

enum DesignGuide {
    /// Kleine, gezielte Änderung (Text, Farbe, ein Element) statt Neugestaltung?
    static func isSmallTweak(_ lower: String) -> Bool {
        let big = ["redesign", "neu gestalten", "neugestalt", "von grund auf", "komplett neu", "new design", "from scratch", "neue richtung"]
        if big.contains(where: { lower.contains($0) }) { return false }
        let tweak = ["farbe", "color", "colour", "text ändern", "text von", "beschriftung", "label", "schrift größer", "schrift kleiner",
                     "abstand", "padding", "margin", "icon", "tippfehler", "typo", "umbenennen", "rename", "nur den", "nur die", "nur das"]
        return tweak.contains { lower.contains($0) }
    }

    /// Regeln für die Umsetzen-Phase. `tweak`: nur das Verlangte ändern.
    static func rules(tweak: Bool, de: Bool = Profile.languageCode == "de") -> String {
        de ? german(tweak) : english(tweak)
    }

    private static func german(_ tweak: Bool) -> String {
        var r: [String] = []
        if tweak {
            r.append("Kleine Änderung: ändere nur genau das Verlangte. Layout, Abstände, Schriften, Größen, Farben und Inhalte drumherum bleiben unverändert. Ideen für mehr am Ende nur vorschlagen.")
        } else {
            r.append("Erst die vorhandene Bildsprache lesen (Farben, Schriften, Abstände, Schatten, Zustände, Tonfall der Texte) und ihr folgen. Gibt es keine, eine klare eigene Richtung festlegen und konsequent durchziehen.")
        }
        r += [
            "Farben aus Marke oder Design-System. Fehlt etwas, passende Töne in oklch ableiten (Akzente mit gleicher Helligkeit und Sättigung, nur der Farbton variiert) statt neue Farben zu erfinden. Weiß und Schwarz leicht getönt.",
            "Höchstens zwei Schriften, eine bewusste Paarung. Keine Allerwelts-Standardschrift als einzige Wahl, keine schwer lesbaren Zierschriften.",
            "Weniger ist mehr: kein Füllmaterial, keine Platzhalter-Abschnitte, keine Deko-Zahlen oder -Icons, keine Emojis (außer die Marke nutzt sie). Wirkt ein Bereich leer, ist das ein Layout-Problem.",
            "Typische KI-Optik vermeiden: grelle Verläufe als Hintergrund, Karten mit farbigem Randstreifen links, überall gleiche abgerundete Kästen.",
            "Lesbarkeit: Text mindestens 4,5:1 Kontrast (große Überschriften 3:1), Klickflächen auf Mobil mindestens 44 px, Linkfarben (normal und Hover) immer festlegen.",
            "Fließend bauen: max-width statt fester Breiten, Flex/Grid mit gap (Spalten mit minmax(0,1fr)), nichts, was bei 390 px überläuft oder umbricht, wo es nicht soll. text-wrap: pretty für Fließtext.",
            "Vom Nutzer gelieferte Texte wörtlich übernehmen. Eigene Texte klar und sachlich, ohne Werbefloskeln.",
            "Bilder nicht als aufwendiges SVG zeichnen: schlichte Platzhalter mit kurzer Beschriftung, was dort hingehört.",
            "Bei Varianten mehrere echte Entwürfe nebeneinander zeigen und benennen (A, B, C), statt nur eine Lösung zu beschreiben.",
        ]
        return r.map { "   – " + $0 }.joined(separator: "\n")
    }

    private static func english(_ tweak: Bool) -> String {
        var r: [String] = []
        if tweak {
            r.append("Small change: change exactly what was asked. Layout, spacing, fonts, sizes, colours and surrounding content stay as they are. Suggest anything more at the end instead of doing it.")
        } else {
            r.append("First read the existing visual language (colours, type, spacing, shadows, states, tone of copy) and follow it. If there is none, commit to one clear direction and apply it consistently.")
        }
        r += [
            "Colours come from the brand or design system. If something is missing, derive matching tones in oklch (accents share lightness and chroma, only the hue changes) instead of inventing new colours. Use slightly tinted whites and blacks.",
            "At most two typefaces, chosen as a deliberate pair. No generic default font as the only choice, no hard-to-read display fonts.",
            "Less is more: no filler, no placeholder sections, no decorative numbers or icons, no emoji unless the brand uses them. An empty-feeling area is a layout problem.",
            "Avoid the typical AI look: loud gradient backgrounds, cards with a coloured left border, identical rounded boxes everywhere.",
            "Legibility: text contrast at least 4.5:1 (3:1 for large headlines), mobile tap targets at least 44 px, always define link colours (default and hover).",
            "Build fluid: max-width instead of fixed widths, flex/grid with gap (columns with minmax(0,1fr)), nothing that overflows or wraps unexpectedly at 390 px. Use text-wrap: pretty for body copy.",
            "Keep text the user supplied word for word. Write your own copy plainly, without marketing filler.",
            "Don't draw imagery as elaborate SVG: use simple placeholders with a short label saying what belongs there.",
            "For variations, show several real drafts side by side and label them (A, B, C) instead of describing one solution.",
        ]
        return r.map { "   – " + $0 }.joined(separator: "\n")
    }
}
