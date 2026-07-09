import SwiftUI

/// 6-minute walk — a real countdown from 6:00 with a progress ring and running
/// distance estimate, mirroring the HTML prototype. Start / Pause / Resume /
/// Restart; Finish returns home.
struct WalkView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var secondsLeft = 360
    @State private var running = false
    @State private var ticker: Timer? = nil

    private var fraction: Double { Double(360 - secondsLeft) / 360 }
    private var timeText: String { String(format: "%d:%02d", secondsLeft / 60, secondsLeft % 60) }
    private var distText: String { "\(Int(Double(360 - secondsLeft) * 1.5)) m so far" }
    private var buttonLabel: String {
        running ? "Pause" : (secondsLeft <= 0 ? "Restart" : (secondsLeft < 360 ? "Resume" : "Start"))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Text("‹ 6-minute walk").font(Theme.display(16, .semibold)).foregroundColor(Color(hex: 0xF6C9B8))
                }
                Spacer()
            }
            .padding(.horizontal, 22).padding(.top, 10)

            Spacer()

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

            Spacer()

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
            .padding(.horizontal, 22).padding(.bottom, 30)
        }
        .background(Color(hex: 0x2E1F19).ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .onDisappear {
            stopTicker()
            SensorLogStore.shared.endMWTSession()   // close the test if leaving mid-walk
        }
    }

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
            SensorLogStore.shared.endMWTSession()   // test finished → save the session
        }
    }

    private func toggle() {
        if running {
            running = false
            stopTicker()
            return
        }
        if secondsLeft <= 0 { secondsLeft = 360 }
        if secondsLeft == 360 { SensorLogStore.shared.startMWTSession() }   // fresh test
        running = true
        startTicker()
    }

    private func finish() {
        running = false
        stopTicker()
        SensorLogStore.shared.endMWTSession()
        dismiss()
    }
}
