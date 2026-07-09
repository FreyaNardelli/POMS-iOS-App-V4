import SwiftUI

/// A center-zero horizontal bar for a signed sensor axis (accel g, gyro deg/s).
/// The fill grows right for positive, left for negative, from the midline.
struct AxisBar: View {
    let label: String
    let value: Double
    let range: Double          // full-scale (± range maps to ± half width)
    let color: Color
    var valueFormat: String = "%.2f"
    var labelWidth: CGFloat = 12

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(Theme.display(12, .heavy))
                .foregroundColor(color)
                .frame(width: labelWidth, alignment: .leading)

            GeometryReader { geo in
                let w = geo.size.width
                let frac = max(-1, min(1, value / range))   // clamp to [-1, 1]
                let half = w / 2
                let fillW = abs(frac) * half
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.track)
                    // midline tick
                    Rectangle()
                        .fill(Theme.tick)
                        .frame(width: 1.5)
                        .offset(x: half - 0.75)
                    // fill
                    Capsule()
                        .fill(color)
                        .frame(width: fillW)
                        .offset(x: frac >= 0 ? half : half - fillW)
                }
            }
            .frame(height: 8)

            Text(String(format: valueFormat, value))
                .font(Theme.mono(11))
                .foregroundColor(Theme.textPrimary)
                .frame(width: 40, alignment: .trailing)
        }
    }
}
