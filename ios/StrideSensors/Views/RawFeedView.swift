import SwiftUI

/// Raw packet inspector — a scrolling list of the most recent samples with all
/// fields, so you can visually confirm the data arriving on :12345 is correct.
struct RawFeedView: View {
    @EnvironmentObject var store: SensorStore

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Text("Raw feed").font(Theme.display(22, .semibold)).foregroundColor(.white)
                    Spacer()
                    Button {
                        store.clear()
                    } label: {
                        Text("Clear")
                            .font(Theme.display(12, .bold))
                            .foregroundColor(Theme.orange)
                    }
                }
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 12)

                TimelineView(.animation(minimumInterval: 0.25)) { _ in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(store.lastN(120).reversed()) { s in
                                row(s)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                    }
                }
            }
        }
    }

    private func row(_ s: SensorSample) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(String(format: "t %.3f", s.timestamp))
                    .font(Theme.mono(11)).foregroundColor(Theme.textDim)
                Spacer()
                if let hr = s.heartRate {
                    Text("♥ \(Int(hr))").font(Theme.mono(11)).foregroundColor(Theme.coral)
                }
            }
            HStack(spacing: 14) {
                triple("acc", s.accel.x, s.accel.y, s.accel.z, Theme.orange)
                triple("gyr", s.gyro.x, s.gyro.y, s.gyro.z, Theme.purple)
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12).fill(Theme.panel)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.panelBorder, lineWidth: 1))
        )
    }

    private func triple(_ label: String, _ x: Double, _ y: Double, _ z: Double, _ c: Color) -> some View {
        HStack(spacing: 5) {
            Text(label).font(Theme.display(10, .heavy)).foregroundColor(c)
            Text(String(format: "%.2f %.2f %.2f", x, y, z))
                .font(Theme.mono(11)).foregroundColor(Theme.textPrimary)
        }
    }
}
