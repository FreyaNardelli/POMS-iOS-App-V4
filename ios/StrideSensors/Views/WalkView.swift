import SwiftUI

/// 6-minute walk — a real countdown from 6:00 with a progress ring and a live
/// GPS distance readout. Start / Pause / Resume / Restart; Finish ends the
/// test early.
///
/// The in-progress "so far" distance is real GPS path distance from
/// `WalkingModelStore` (see `distText`) — earlier revisions showed a
/// synthetic time-based placeholder here; that's been replaced.
///
/// When a test completes (timer reaches 0, or the user taps Finish after some
/// walking), the swing-based speed & distance estimate is computed from the
/// wrist pca-acc signal and shown below. See `WalkingSpeedEstimator` /
/// `PatientWalkingModel`.
struct WalkView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: SensorStore
    @ObservedObject private var walkModel = WalkingModelStore.shared

    @State private var secondsLeft = 360
    @State private var running = false
    @State private var ticker: Timer? = nil
    /// Set once this test has ended so the results panel appears.
    @State private var completedThisVisit = false

    private var gpsFix: Bool { store.hasGPSFix }
    private var coordinate: (lat: Double, long: Double)? { store.currentCoordinate }

    private var fraction: Double { Double(360 - secondsLeft) / 360 }
    private var timeText: String { String(format: "%d:%02d", secondsLeft / 60, secondsLeft % 60) }
    /// Real live GPS path distance for this test, from `WalkingModelStore`
    /// (accumulated on every packet — see `WalkingModelStore.ingest`). Shows
    /// a neutral "0 m so far" before a test has started, and "waiting for
    /// GPS…" once recording if no fix has been acquired yet, rather than
    /// silently showing 0 as if that were a real reading.
    private var distText: String {
        guard secondsLeft < 360 || completedThisVisit else { return "0 m so far" }
        guard walkModel.liveFixCount > 0 else { return "waiting for GPS…" }
        return "\(Int(walkModel.liveDistance)) m so far"
    }
    private var buttonLabel: String {
        running ? "Pause" : (secondsLeft <= 0 ? "Restart" : (secondsLeft < 360 ? "Resume" : "Start"))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                HStack {
                    Button { dismiss() } label: {
                        Text("‹ 6-minute walk").font(Theme.display(16, .semibold)).foregroundColor(Color(hex: 0xF6C9B8))
                    }
                    Spacer()
                }
                .padding(.horizontal, 22).padding(.top, 10)

                gpsStatus
                    .padding(.horizontal, 22).padding(.top, 10)

                Spacer(minLength: 24)

                ZStack {
                    Circle().stroke(Color(hex: 0x4A362E), lineWidth: 20)
                    Circle().trim(from: 0, to: fraction)
                        .stroke(Theme.orange, style: StrokeStyle(lineWidth: 20, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.25), value: fraction)
                    VStack(spacing: 4) {
                        Text("TIME LEFT").font(Theme.display(11, .heavy)).foregroundColor(Color(hex: 0xC9B6AC))
                        Text(timeText).font(Theme.display(52, .bold)).foregroundColor(.white)
                        Text(distText).font(Theme.display(13, .heavy)).foregroundColor(Color(hex: 0xFFB98C))
                    }
                }
                .frame(width: 240, height: 240)
                .padding(.top, 8)

                Spacer(minLength: 24)

                HStack(spacing: 12) {
                    Button { toggle() } label: {
                        Text(buttonLabel).font(Theme.display(16, .semibold)).foregroundColor(Color(hex: 0xF6C9B8))
                            .frame(maxWidth: .infinity).padding(14)
                            .background(RoundedRectangle(cornerRadius: 16).strokeBorder(Color(hex: 0x6B4F44), lineWidth: 2))
                    }
                    Button { finish() } label: {
                        Text("Finish").font(Theme.display(16, .semibold)).foregroundColor(.white)
                            .frame(maxWidth: .infinity).padding(14)
                            .background(RoundedRectangle(cornerRadius: 16).fill(Theme.coralRed))
                    }
                }
                .padding(.horizontal, 22).padding(.top, 4)

                resultsSection
                    .padding(.horizontal, 18).padding(.top, 22)

                Spacer(minLength: 30)
            }
        }
        .background(Color(hex: 0x2E1F19).ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .onDisappear {
            stopTicker()
            if running || SensorLogStore.shared.mwtActive {
                endTest()   // close the test if leaving mid-walk
            }
        }
    }

    // MARK: Timer

    private func startTicker() {
        stopTicker()
        let t = Timer(timeInterval: 1, repeats: true) { _ in tick() }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func stopTicker() { ticker?.invalidate(); ticker = nil }

    private func tick() {
        guard running else { return }
        if secondsLeft > 0 { secondsLeft -= 1 }
        if secondsLeft <= 0 {
            secondsLeft = 0
            running = false
            stopTicker()
            endTest()   // test finished → save the session + analyse
        }
    }

    private func toggle() {
        if running {
            running = false
            stopTicker()
            return
        }
        if secondsLeft <= 0 { secondsLeft = 360 }
        if secondsLeft == 360 { startTest() }   // fresh test
        running = true
        startTicker()
    }

    private func finish() {
        running = false
        stopTicker()
        // Capture *before* endTest() clears it — stopCaptureAndAnalyze() flips
        // isAnalyzing/lastResult asynchronously (DispatchQueue.main.async), so
        // checking those flags right after calling it would almost always
        // read their stale pre-dispatch values and dismiss before analysis
        // ever gets to run. Whether a test was actually active is known
        // synchronously, so use that instead: nothing to analyse only if no
        // test was ever started.
        let wasActive = SensorLogStore.shared.mwtActive || WalkingModelStore.shared.capturing
        endTest()
        if !wasActive { dismiss() }
    }

    // MARK: Test start / end (session logging + swing capture together)

    private func startTest() {
        completedThisVisit = false
        SensorLogStore.shared.startMWTSession()
        WalkingModelStore.shared.startCapture()
    }

    private func endTest() {
        guard SensorLogStore.shared.mwtActive || WalkingModelStore.shared.capturing else { return }
        SensorLogStore.shared.endMWTSession()
        WalkingModelStore.shared.stopCaptureAndAnalyze()
        completedThisVisit = true
    }

    // MARK: GPS status

    private var gpsStatus: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(gpsFix ? Theme.mint : Color(hex: 0xC9B6AC)).frame(width: 7, height: 7)
                Text(gpsFix ? "GPS Fix Acquired" : "Waiting for GPS Fix")
                    .font(Theme.display(12, .heavy))
                    .foregroundColor(gpsFix ? Theme.mint : Color(hex: 0xC9B6AC))
            }
            Spacer()
            if let c = coordinate {
                Text(String(format: "%.5f, %.5f", c.lat, c.long))
                    .font(Theme.mono(11))
                    .foregroundColor(Color(hex: 0xC9B6AC))
            } else {
                Text("— , —")
                    .font(Theme.mono(11))
                    .foregroundColor(Color(hex: 0xC9B6AC).opacity(0.6))
            }
        }
    }

    // MARK: Swing-based results

    @ViewBuilder
    private var resultsSection: some View {
        if walkModel.isAnalyzing {
            resultsCard {
                HStack(spacing: 10) {
                    ProgressView().tint(Theme.orange)
                    Text("Analysing arm-swing…")
                        .font(Theme.display(13, .heavy)).foregroundColor(Color(hex: 0xC9B6AC))
                }
            }
        } else if completedThisVisit, let r = walkModel.lastResult {
            resultsCard { WalkResultBody(result: r) }
        }
    }

    private func resultsCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SWING-BASED SPEED & DISTANCE")
                .font(Theme.display(10, .heavy)).tracking(0.5)
                .foregroundColor(Color(hex: 0xFFB98C))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(hex: 0x3A2820))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color(hex: 0x5A463E), lineWidth: 1))
        )
    }
}

/// The body of the post-test results card.
private struct WalkResultBody: View {
    let result: WalkResult

    private func meters(_ v: Double?) -> String { v.map { String(format: "%.0f m", $0) } ?? "—" }
    private func speed(_ v: Double?) -> String { v.map { String(format: "%.2f m/s", $0) } ?? "—" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if result.calibrated {
                HStack(spacing: 20) {
                    stat("Distance", meters(result.swingDistanceMeters), Theme.orange)
                    stat("Avg speed", speed(result.swingAvgSpeed), Theme.mint)
                }
                if result.perMinuteSpeed.contains(where: { $0 > 0 }) {
                    perMinute
                }
            }

            gpsReference

            Text(result.note)
                .font(.system(size: 12))
                .foregroundColor(Color(hex: 0xC9B6AC))
                .fixedSize(horizontal: false, vertical: true)

            Text("Estimate only — not a clinical measurement. Assumes free arm swing; a cane/walker or a held arm will reduce accuracy.")
                .font(.system(size: 11))
                .foregroundColor(Color(hex: 0x9A8478))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// GPS-based distance + how many 5-second analysis windows the walk
    /// produced. Shown unconditionally — not just before calibration —
    /// because it's exactly the number worth seeing on an early Finish,
    /// where the swing model may not have had enough to say anything yet.
    private var gpsReference: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GPS REFERENCE")
                .font(Theme.display(9, .heavy)).foregroundColor(Color(hex: 0x9A8478))
            HStack(spacing: 20) {
                stat("GPS distance", meters(result.gpsDistanceMeters),
                     result.calibrated ? Color(hex: 0xC9B6AC) : Theme.mint,
                     size: result.calibrated ? 16 : 22)
                stat("Epochs", epochsText,
                     Color(hex: 0xC9B6AC), size: result.calibrated ? 16 : 22)
            }
        }
    }

    private var epochsText: String {
        guard result.epochCount > 0 else { return "0" }
        return result.gpsEpochCount > 0
            ? "\(result.epochCount) (\(result.gpsEpochCount) w/ GPS)"
            : "\(result.epochCount)"
    }

    private func stat(_ label: String, _ value: String, _ color: Color, size: CGFloat = 22) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(Theme.display(size, .bold)).foregroundColor(color)
            Text(label).font(Theme.display(10, .heavy)).foregroundColor(Color(hex: 0xC9B6AC))
        }
    }

    private var perMinute: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PER-MINUTE SPEED (m/s)")
                .font(Theme.display(9, .heavy)).foregroundColor(Color(hex: 0x9A8478))
            HStack(alignment: .bottom, spacing: 6) {
                let maxV = max(result.perMinuteSpeed.max() ?? 1, 0.1)
                ForEach(Array(result.perMinuteSpeed.enumerated()), id: \.offset) { i, v in
                    VStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Theme.orange.opacity(0.85))
                            .frame(width: 22, height: max(4, CGFloat(v / maxV) * 46))
                        Text(String(format: "%.2f", v))
                            .font(Theme.mono(8)).foregroundColor(Color(hex: 0xC9B6AC))
                        Text("\(i + 1)")
                            .font(Theme.mono(8)).foregroundColor(Color(hex: 0x9A8478))
                    }
                }
            }
        }
    }
}
