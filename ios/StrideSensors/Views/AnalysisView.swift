import SwiftUI

/// Demonstrates how easily the stored data feeds arbitrary formulas. Everything
/// here just reads `SensorStore.shared` — add your own metrics the same way.
struct AnalysisView: View {
    @EnvironmentObject var store: SensorStore

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            TimelineView(.animation(minimumInterval: 0.5)) { _ in
                ScrollView {
                    VStack(spacing: 14) {
                        HStack {
                            Text("Analysis").font(Theme.display(22, .semibold)).foregroundColor(.white)
                            Spacer()
                        }
                        .padding(.top, 8)

                        metric("Sample rate", String(format: "%.0f Hz", store.sampleRateHz), Theme.mint)
                        metric("Mean |accel| · 5 s", String(format: "%.3f g", store.meanAccelMagnitude(seconds: 5)), Theme.orange)
                        metric("Gyro RMS · 5 s", String(format: "%.1f °/s", store.gyroRMS(seconds: 5)), Theme.purple)
                        metric("Heart rate", store.currentHeartRate.map { String(format: "%.0f bpm", $0) } ?? "—", Theme.coral)
                        metric("Samples buffered", "\(store.snapshot().count)", Theme.green)

                        note
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
            }
        }
    }

    private func metric(_ title: String, _ value: String, _ color: Color) -> some View {
        HStack {
            Text(title).font(Theme.display(14, .medium)).foregroundColor(Theme.textDim)
            Spacer()
            Text(value).font(Theme.display(20, .bold)).foregroundColor(color)
        }
        .padding(.horizontal, 16).padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 16).fill(Theme.panel)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.panelBorder, lineWidth: 1))
        )
    }

    private var note: some View {
        Text("These are examples. Read `SensorStore.shared.snapshot()` / `recent(_:)` or set `onSample` to compute anything you like.")
            .font(.system(size: 12))
            .foregroundColor(Theme.textFaint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
    }
}
