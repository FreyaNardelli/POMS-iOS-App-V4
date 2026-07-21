import SwiftUI
import simd

struct LiveSensorsView: View {
    @EnvironmentObject var store: SensorStore
    @EnvironmentObject var receiver: UDPReceiver
    @State private var resetToken = 0

    private var isStreaming: Bool {
        guard let last = receiver.lastPacketDate else { return false }
        return Date().timeIntervalSince(last) < 2.0
    }

    private var accel: SIMD3<Double> { store.latest?.accel ?? .zero }
    private var gyro: SIMD3<Double> { store.latest?.gyro ?? .zero }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            VStack(spacing: 14) {
                header
                sourceStrip
                ZStack(alignment: .bottomTrailing) {
                    WatchModel3DView(resetToken: resetToken).frame(height: 190) // edit height for model cropping
                    Button {
                        resetToken += 1
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.counterclockwise")
                            Text("Reset")
                        }
                        .font(Theme.display(11, .heavy))
                        .foregroundColor(Theme.textDim)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(
                            Capsule().fill(Theme.panel)
                                .overlay(Capsule().stroke(Theme.panelBorder, lineWidth: 1))
                        )
                    }
                    .padding(.trailing, 4)
                }

                HStack(alignment: .top, spacing: 11) {
                    accelCard
                    gyroCard
                }

                heartRateCard
                freshness
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("Live sensors")
                .font(Theme.display(22, .semibold))
                .foregroundColor(.white)
            Spacer()
            HStack(spacing: 7) {
                Circle()
                    .fill(isStreaming ? Theme.mint : Theme.textFaint)
                    .frame(width: 7, height: 7)
                Text(isStreaming ? "Streaming" : "Waiting…")
                    .font(Theme.display(11, .heavy))
                    .foregroundColor(isStreaming ? Theme.mint : Theme.textFaint)
            }
            .padding(.horizontal, 11).padding(.vertical, 5)
            .background(
                Capsule().fill(Color(hex: 0x16261C))
                    .overlay(Capsule().stroke(Color(hex: 0x23412E), lineWidth: 1))
            )
        }
    }

    // MARK: Source strip

    private var sourceStrip: some View {
        HStack(spacing: 8) {
            Text("UDP").foregroundColor(Theme.orange)
            Text(":\(receiver.boundPort)")
            Text("·").foregroundColor(Theme.tick)
            Text("\(Int(store.packetsPerSecond)) Hz")
            Text("·").foregroundColor(Theme.tick)
            Text("\(store.totalPackets) pkts").foregroundColor(Theme.mint)
            Spacer()
        }
        .font(Theme.mono(11))
        .foregroundColor(Theme.textDim)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12).fill(Theme.panel)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.panelBorder, lineWidth: 1))
        )
    }

    // MARK: Accelerometer card

    private var accelCard: some View {
        // Watch streams accelerometer in m/s² (rest ≈ 9.8 on one axis).
        card(title: "ACCEL · m/s²") {
            AxisBar(label: "X", value: accel.x, range: 20, color: Theme.orange, valueFormat: "%.1f")
            AxisBar(label: "Y", value: accel.y, range: 20, color: Theme.purple, valueFormat: "%.1f")
            AxisBar(label: "Z", value: accel.z, range: 20, color: Theme.green, valueFormat: "%.1f")
        }
    }

    // MARK: Gyroscope card

    private var gyroCard: some View {
        // Watch streams gyroscope in rad/s.
        card(title: "GYRO · rad/s") {
            AxisBar(label: "Pitch", value: gyro.x, range: 8, color: Theme.orange,
                    valueFormat: "%.2f", labelWidth: 30)
            AxisBar(label: "Roll", value: gyro.y, range: 8, color: Theme.purple,
                    valueFormat: "%.2f", labelWidth: 30)
            AxisBar(label: "Yaw", value: gyro.z, range: 8, color: Theme.green,
                    valueFormat: "%.2f", labelWidth: 30)
        }
    }

    // MARK: Heart-rate stream

    /// Shows the live BPM plus a **simulated** ECG waveform paced to that BPM
    /// — the watch has no ECG sensor, only optical HR, so there is no real
    /// waveform to plot. See `SimulatedECG` for what this is (and isn't).
    /// This previously plotted wrist accelerometer magnitude under a heart
    /// icon, which was motion data mislabeled as a heart signal — replaced
    /// here with an explicitly-labeled synthetic ECG instead.
    private var heartRateCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.currentHeartRate.map { String(Int($0.rounded())) } ?? "--")
                        .font(Theme.display(28, .bold))
                        .foregroundColor(Theme.coral)
                    Text("♥ BPM").font(Theme.display(9, .heavy)).foregroundColor(Theme.textDim)
                }
                SignalChart(
                    sample: { SimulatedECG.window(bpm: store.currentHeartRate) },
                    color: Theme.coral
                )
                .frame(height: 42)
            }
            Text("Simulated waveform, paced to BPM — the watch has no ECG sensor")
                .font(.system(size: 9))
                .foregroundColor(Theme.textFaint)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16).fill(Theme.panel)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.panelBorder, lineWidth: 1))
        )
    }

    private var freshness: some View {
        Text(freshnessText)
            .font(.system(size: 11))
            .foregroundColor(Theme.textFaint)
            .frame(maxWidth: .infinity)
    }

    private var freshnessText: String {
        guard let last = receiver.lastPacketDate else { return "No packets yet · listening on :\(receiver.boundPort)" }
        let ms = Int(Date().timeIntervalSince(last) * 1000)
        return ms < 1500 ? "Last packet \(ms) ms ago · sensors nominal"
                         : "No recent packets · check the watch connection"
    }

    // MARK: Card shell

    private func card<Content: View>(title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(Theme.display(10, .heavy))
                .tracking(0.5)
                .foregroundColor(Theme.textDim)
                .padding(.bottom, 2)
            content()
        }
        .padding(.horizontal, 13).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16).fill(Theme.panel)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.panelBorder, lineWidth: 1))
        )
    }
}
