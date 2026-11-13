import SwiftUI

/// A 2D copy of the MacBook deck that lights the key you just pressed, by how
/// hard the app measured the press.
///
/// This exists to make the app explainable: you press a key, the key you see is
/// the one that lights, and the light shows the force the accelerometer actually
/// read rather than a number you have to trust. A predicted press (no sensor
/// reading available) lights grey, so a soft sound you cannot explain is still a
/// soft press you can see.
struct KeyboardView: View {
    @ObservedObject var state: AppState

    /// Live pressure per key: score 0..1, plus the tier it mapped to.
    @State private var pressed: [CGKeyCode: KeyPress] = [:]

    /// Number of key units the deck spans, plus gutters, so the whole thing
    /// scales to any window width.
    private var deckUnits: CGFloat { CGFloat(KeyLayout.deckWidth) + 0.9 }
    private var deckRows: CGFloat { 6.0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            deck
            legend
        }
        .padding(18)
        .frame(minWidth: 640, minHeight: 300)
        .background(Color(nsColor: .underPageBackgroundColor))
        .onReceive(state.$activeHit) { hit in
            guard let hit, hit.keyCode != 0 else { return }
            pressed[hit.keyCode] = KeyPress(score: hit.score, tier: hit.tier,
                                            measured: hit.measured)
            Task { await fade(hit.keyCode) }
        }
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Thocky keyboard").font(.headline)
            Text("Every key that gets a sound lights here. Brighter and redder means the accelerometer measured a harder press; grey means the force was estimated, not measured.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 560, alignment: .leading)
        }
    }

    // MARK: the deck

    private var deck: some View {
        GeometryReader { geo in
            let unit = geo.size.width / deckUnits
            let keyH = geo.size.height / deckRows

            ZStack(alignment: .topLeading) {
                /* the aluminium tray the keys sit in */
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.white.opacity(0.06), lineWidth: 1))

                ForEach(KeyLayout.allKeys, id: \.code) { key in
                    keyView(key, unit: unit, height: keyH)
                        .offset(x: CGFloat(key.pos.x) * unit + unit * 0.45,
                                y: (5.0 - CGFloat(key.pos.y)) * keyH + unit * 0.45)
                }
            }
        }
        .aspectRatio(deckUnits / deckRows, contentMode: .fit)
    }

    private func keyView(_ key: (code: CGKeyCode, pos: KeyLayout.KeyPos),
                         unit: CGFloat, height: CGFloat) -> some View {
        let press = pressed[key.code]
        let score = press.map { CGFloat($0.score) } ?? 0
        let measured = press?.measured ?? false
        let tier = press?.tier ?? -1

        return KeyCap(label: key.pos.label,
                      width: CGFloat(key.pos.width) * unit - unit * 0.12,
                      height: height - unit * 0.12,
                      tint: measured ? KeyStyle.fill(tier: tier, score: score)
                                    : Color.gray.opacity(0.3 * score))
            /* the squash: the harder the press, the further the cap sits down */
            .offset(y: -score * height * 0.16)
    }

    // MARK: legend

    private var legend: some View {
        HStack(spacing: 6) {
            ForEach(0..<4, id: \.self) { tier in
                Text(AppState.tierLabels[tier])
                    .font(.caption2.bold())
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(KeyStyle.fill(tier: tier, score: 1).opacity(0.25), in: Capsule())
                    .foregroundStyle(KeyStyle.tint(tier: tier))
            }
            Spacer()
            Text(state.recentHits.isEmpty
                 ? "Type to see it"
                 : "last: \(state.recentHits.first!.label) → \(state.recentHits.first!.tierLabel)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    // MARK: animation

    /// Pressure decays on its own, the way a key returns to rest.
    private func fade(_ code: CGKeyCode) async {
        for _ in 0..<14 {
            try? await Task.sleep(nanoseconds: 45_000_000)
            if let p = pressed[code], p.score > 0.02 {
                pressed[code] = KeyPress(score: p.score * 0.82, tier: p.tier,
                                         measured: p.measured)
            } else if pressed[code] != nil {
                pressed[code] = nil
            }
        }
    }

    private struct KeyPress {
        var score: Double
        var tier: Int
        var measured: Bool
    }
}

/// One keycap: a rounded rect with a label, sized to look like the real deck.
private struct KeyCap: View {
    let label: String
    let width: CGFloat
    let height: CGFloat
    let tint: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: min(4, height * 0.22), style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.9))
            RoundedRectangle(cornerRadius: min(4, height * 0.22), style: .continuous)
                .fill(tint)
            Text(label)
                .font(.system(size: max(7, height * 0.34), weight: .medium))
                .foregroundStyle(Color(nsColor: .labelColor))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .frame(width: max(8, width), height: max(8, height))
    }
}

/// Force colouring: cold for a soft tap, hot for a slam. `score` scales the
/// intensity so a 0.3 press and a 0.9 press look different even on the same tier.
private enum KeyStyle {
    static func tint(tier: Int) -> Color {
        switch tier {
        case 0: return Color(red: 0.35, green: 0.70, blue: 1.0)
        case 1: return Color(red: 0.35, green: 0.90, blue: 0.65)
        case 2: return Color(red: 1.0, green: 0.78, blue: 0.35)
        default: return Color(red: 1.0, green: 0.42, blue: 0.42)
        }
    }

    static func fill(tier: Int, score: CGFloat) -> Color {
        tint(tier: tier).opacity(0.25 + 0.75 * min(1.0, max(0.0, score)))
    }
}