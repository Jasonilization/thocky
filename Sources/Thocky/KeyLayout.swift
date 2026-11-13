import CoreGraphics

/// The physical keyboard, as a map from key code to a position on the deck.
///
/// Three things need this: the stereo panning (a left-hand key should sound from
/// the left speaker), the distance falloff (back rows sit further away), and the
/// 2D keyboard view, which draws a faithful copy of the MacBook deck and lights
/// the key you just pressed by how hard the app measured the press.
///
/// Layout is a US MacBook. Positions are measured in key units: a normal key is
/// 1.0 wide, and the deck is 16.0 units across, which is what a real MacBook
/// keyboard is to an F1..F12 row plus the wide bottom row.
enum KeyLayout {
    /// Where a key sits: label, unit position, and width in key units.
    struct KeyPos {
        var x: Float       /* left edge, in key units, 0 = deck left */
        var y: Float       /* row depth, 0 = front row */
        var width: Float   /* in key units; 1 = a normal key */
        var label: String
    }

    /// Deck width in key units: a normal row is 15 keys wide and the bottom
    /// row (fn ctrl opt cmd space cmd arrows) is also about that, so 16 with the
    /// gutters is what the geometry wants.
    static let deckWidth: Float = 16.0
    static let rowHeight: Float = 1.0

    /// Row by row, left to right: (label, keyCode, width in key units).
    private static let rows: [[(String, CGKeyCode, Float)]] = [
        /* function row: keys are 0.6 wide on a real MacBook */
        [("esc", 53, 1.0), ("F1", 122, 0.6), ("F2", 120, 0.6), ("F3", 99, 0.6),
         ("F4", 118, 0.6), ("F5", 96, 0.6), ("F6", 97, 0.6), ("F7", 98, 0.6),
         ("F8", 100, 0.6), ("F9", 101, 0.6), ("F10", 109, 0.6), ("F11", 103, 0.6),
         ("F12", 111, 0.6), ("⏏", 127, 0.6)],

        [("~", 50, 1), ("1", 18, 1), ("2", 19, 1), ("3", 20, 1), ("4", 21, 1),
         ("5", 23, 1), ("6", 22, 1), ("7", 26, 1), ("8", 28, 1), ("9", 25, 1),
         ("0", 29, 1), ("-", 27, 1), ("=", 24, 1), ("⌫", 51, 1.55), ("home", 115, 1)],

        [("⇥", 48, 1.55), ("Q", 12, 1), ("W", 13, 1), ("E", 14, 1), ("R", 15, 1),
         ("T", 17, 1), ("Y", 16, 1), ("U", 32, 1), ("I", 34, 1), ("O", 31, 1),
         ("P", 35, 1), ("[", 33, 1), ("]", 30, 1), ("\\", 42, 1), ("↩", 36, 1.55)],

        [("⇪", 57, 1.85), ("A", 0, 1), ("S", 1, 1), ("D", 2, 1), ("F", 3, 1),
         ("G", 5, 1), ("H", 4, 1), ("J", 38, 1), ("K", 40, 1), ("L", 37, 1),
         (";", 41, 1), ("'", 39, 1), ("⏎", 36, 1.55), ("end", 119, 1)],

        [("⇧", 56, 2.4), ("Z", 6, 1), ("X", 7, 1), ("C", 8, 1), ("V", 9, 1),
         ("B", 11, 1), ("N", 45, 1), ("M", 46, 1), (",", 43, 1), (".", 47, 1),
         ("/", 44, 1), ("↑", 126, 0.5), ("⇧", 60, 2.4)],

        /* bottom row is centred on the real deck, so start it off the left edge */
        [("fn", 63, 1.15), ("⌃", 59, 1.15), ("⌥", 58, 1.15), ("⌘", 55, 1.15),
         ("␣", 49, 5.9), ("⌘", 54, 1.15), ("←", 123, 0.5), ("↓", 125, 0.5),
         ("→", 124, 0.5)]
    ]

    /// Left gutter per row, in key units (the real deck is not flush left).
    private static let rowOffsets: [Float] = [0.0, 0.5, 0.5, 1.15, 1.15, 1.55]
    /// Depth: the function row is furthest back, the space row closest.
    private static let rowDepths: [Float] = [5.0, 4.0, 3.0, 2.0, 1.0, 0.0]

    static func position(for keyCode: CGKeyCode) -> KeyPos? {
        for (r, row) in rows.enumerated() {
            var x = rowOffsets[r]
            for key in row {
                if key.1 == keyCode {
                    return KeyPos(x: x, y: rowDepths[r], width: key.2, label: key.0)
                }
                x += key.2
            }
        }
        return nil
    }

    /// Stereo pan (-1 = left .. +1 = right) from the key's centre on the deck.
    static func pan(for keyCode: CGKeyCode) -> Float {
        guard let p = position(for: keyCode) else { return 0 }
        let centre = (p.x + p.width * 0.5) / deckWidth
        return min(1.0, max(-1.0, centre * 2.0 - 1.0))
    }

    /// Distance 0..1: the front row is closest to your ears.
    static func distance(for keyCode: CGKeyCode) -> Float {
        guard let p = position(for: keyCode) else { return 0 }
        return min(1.0, max(0.0, 1.0 - p.y / 5.0))
    }

    /// Every key, first occurrence of each key code, for the 2D keyboard view.
    static var allKeys: [(code: CGKeyCode, pos: KeyPos)] {
        var out: [(code: CGKeyCode, pos: KeyPos)] = []
        var seen = Set<CGKeyCode>()
        for row in rows {
            for key in row where !seen.contains(key.1) {
                seen.insert(key.1)
                out.append((key.1, position(for: key.1)!))
            }
        }
        return out
    }
}