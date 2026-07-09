import SwiftUI

/// A live line chart of the most recent values. Redraws on a timeline so it
/// stays live even though `SensorStore.history` isn't a @Published array.
struct SignalChart: View {
    /// Pulls the latest values to plot (e.g. accel magnitude, HR, one axis).
    let sample: () -> [Double]
    var color: Color = Theme.coral
    var lineWidth: CGFloat = 2.5

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { _ in
            Canvas { ctx, size in
                let values = sample()
                guard values.count > 1 else { return }

                let minV = values.min() ?? 0
                let maxV = values.max() ?? 1
                let span = max(maxV - minV, 0.0001)
                let stepX = size.width / CGFloat(values.count - 1)
                let pad: CGFloat = 3

                var path = Path()
                for (i, v) in values.enumerated() {
                    let x = CGFloat(i) * stepX
                    let norm = (v - minV) / span
                    let y = size.height - pad - CGFloat(norm) * (size.height - pad * 2)
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
                ctx.stroke(
                    path,
                    with: .color(color),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                )
            }
        }
    }
}
