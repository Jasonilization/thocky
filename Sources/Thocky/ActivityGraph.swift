import SwiftUI

/// Live plot of the linear accelerometer magnitude, with detected impacts marked.
///
/// Drawn with Canvas so it stays cheap while the sensor is streaming at ~800 Hz:
/// the view only re-renders when AppState publishes a new telemetry snapshot.
struct ActivityGraph: View {
    let history: [Double]
    let noiseFloor: Double
    let impacts: [Double]

    var body: some View {
        Canvas { context, size in
            guard history.count > 1 else {
                var text = Text("no signal")
                text = text.font(.caption).foregroundColor(.secondary)
                context.draw(text, at: CGPoint(x: size.width / 2, y: size.height / 2))
                return
            }

            let peak = max(history.max() ?? 0.01, noiseFloor * 3, 0.008) * 1.15
            let step = size.width / Double(history.count - 1)
            func y(for value: Double) -> Double { size.height - min(1, value / peak) * (size.height - 4) - 2 }

            // signal trace
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height))
            for (i, value) in history.enumerated() {
                path.addLine(to: CGPoint(x: Double(i) * step, y: y(for: value)))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            context.fill(path, with: .linearGradient(
                Gradient(colors: [Color.accentColor.opacity(0.55), Color.accentColor.opacity(0.05)]),
                startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height)))

            var line = Path()
            for (i, value) in history.enumerated() {
                let point = CGPoint(x: Double(i) * step, y: y(for: value))
                if i == 0 { line.move(to: point) } else { line.addLine(to: point) }
            }
            context.stroke(line, with: .color(.accentColor), lineWidth: 1)

            // noise floor (the gate the detector uses)
            let floorY = y(for: noiseFloor * 2.5)
            var floor = Path()
            floor.move(to: CGPoint(x: 0, y: floorY))
            floor.addLine(to: CGPoint(x: size.width, y: floorY))
            context.stroke(floor, with: .color(.orange.opacity(0.7)),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

            // recent impact scores along the bottom
            if !impacts.isEmpty {
                let barWidth = max(3, size.width / 40)
                for (i, score) in impacts.enumerated() {
                    let h = max(3, size.height * 0.28 * score)
                    let x = 6 + Double(i) * (barWidth + 2)
                    let rect = CGRect(x: x, y: size.height - h - 2, width: barWidth, height: h)
                    context.fill(Path(rect), with: .color(.purple.opacity(0.65)))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
        .clipped()
        .accessibilityLabel("Accelerometer magnitude over time")
    }
}
