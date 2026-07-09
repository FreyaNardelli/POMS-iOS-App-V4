import SwiftUI

/// Symbol match (SDMT) — thinking-speed test. A fixed symbol→digit key sits at
/// the top; the user taps the digit matching the prompted symbol, scoring as
/// many correct as possible before the 90-second timer runs out.
struct SDMTView: View {
    @Environment(\.dismiss) private var dismiss

    private let symbols = ["◐", "◇", "△", "☆", "♥", "▢", "◍", "⬡", "⌘"]
    @State private var current = Int.random(in: 0..<9)
    @State private var score = 0
    @State private var secondsLeft = 90
    @State private var started = false
    @State private var finished = false
    @State private var lastWrong: Int? = nil
    @State private var ticker: Timer? = nil

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 22) {
                    keyGrid
                    prompt
                    answerPad
                }
                .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 24)
            }
        }
        .background(Theme.cream.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .onDisappear { stopTicker() }
    }

    private func startTicker() {
        stopTicker()
        let t = Timer(timeInterval: 1, repeats: true) { _ in tick() }
        RunLoop.main.add(t, forMode: .common)   // keeps firing during scroll
        ticker = t
    }

    private func stopTicker() { ticker?.invalidate(); ticker = nil }

    private func tick() {
        guard started, !finished else { return }
        if secondsLeft > 0 { secondsLeft -= 1 }
        if secondsLeft <= 0 {
            secondsLeft = 0
            finished = true
            started = false
            stopTicker()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Text("‹").font(.system(size: 22, weight: .semibold)).foregroundColor(Color(hex: 0x8A7266))
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0xF4E7DC)))
            }
            Text("Symbol Match").font(Theme.display(18, .semibold)).foregroundColor(Theme.ink)
            Spacer()
            Text(String(format: "⏱ %d:%02d", secondsLeft / 60, secondsLeft % 60))
                .font(Theme.display(13, .heavy)).foregroundColor(secondsLeft <= 10 ? Theme.coralRed : Theme.brown)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(Theme.card))
        }
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 6)
    }

    private var keyGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("KEY").font(Theme.display(11, .heavy)).foregroundColor(Theme.brownDim)
            HStack(spacing: 6) {
                ForEach(0..<9) { i in
                    VStack(spacing: 2) {
                        Text(symbols[i]).font(.system(size: 20)).foregroundColor(Theme.purple)
                        Rectangle().fill(Color(hex: 0xEAD9CC)).frame(height: 1)
                        Text("\(i + 1)").font(Theme.display(15, .bold)).foregroundColor(Theme.ink)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
                }
            }
        }
    }

    private var prompt: some View {
        VStack(spacing: 8) {
            Text(finished ? "Test complete" : (started ? "What number matches?" : "Tap Start, then match each symbol"))
                .font(Theme.display(14, .semibold)).foregroundColor(Theme.brown)
            Text(symbols[current]).font(.system(size: 78)).foregroundColor(Theme.purple)
                .frame(maxWidth: .infinity).padding(.vertical, 20)
                .background(RoundedRectangle(cornerRadius: 22).fill(Theme.card).shadow(color: Theme.cardShadow, radius: 8, y: 6))
                .opacity(finished ? 0.35 : 1)
            Text("Score: \(score)").font(Theme.display(15, .heavy)).foregroundColor(Theme.coralRed)
        }
    }

    private var answerPad: some View {
        Group {
            if finished {
                VStack(spacing: 14) {
                    Text("⏱ Time's up!").font(Theme.display(15, .heavy)).foregroundColor(Theme.brown)
                    Text("\(score)").font(Theme.display(64, .bold)).foregroundColor(Theme.coralRed)
                    Text("symbols matched in 90 seconds")
                        .font(Theme.display(14, .semibold)).foregroundColor(Theme.inkSoft)
                    Button { restart() } label: {
                        Text("Play again").font(Theme.display(16, .bold)).foregroundColor(.white)
                            .frame(maxWidth: .infinity).padding(15)
                            .background(RoundedRectangle(cornerRadius: 18).fill(Theme.purple))
                    }
                    Button { dismiss() } label: {
                        Text("Done · +5 XP").font(Theme.display(15, .bold)).foregroundColor(Theme.purple)
                    }.padding(.top, 2)
                }
                .frame(maxWidth: .infinity)
                .padding(22)
                .background(RoundedRectangle(cornerRadius: 22).fill(Theme.card).shadow(color: Theme.cardShadow, radius: 10, y: 8))
            } else if started && secondsLeft > 0 {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(1...9, id: \.self) { n in
                        Button { answer(n) } label: {
                            Text("\(n)").font(Theme.display(24, .bold))
                                .foregroundColor(lastWrong == n ? .white : Theme.ink)
                                .frame(maxWidth: .infinity).padding(.vertical, 16)
                                .background(RoundedRectangle(cornerRadius: 14).fill(lastWrong == n ? Theme.coralRed : Theme.card))
                        }.buttonStyle(.plain)
                    }
                }
            } else {
                Button { begin() } label: {
                    Text("Start · 90 sec").font(Theme.display(17, .semibold)).foregroundColor(.white)
                        .frame(maxWidth: .infinity).padding(15)
                        .background(RoundedRectangle(cornerRadius: 18).fill(Theme.purple))
                }
            }
        }
    }

    private func begin() {
        score = 0; secondsLeft = 90; finished = false; lastWrong = nil
        current = Int.random(in: 0..<9)
        started = true
        startTicker()
    }

    private func answer(_ n: Int) {
        guard started, !finished, secondsLeft > 0 else { return }
        if n == current + 1 {
            score += 1; lastWrong = nil
            current = Int.random(in: 0..<9)
        } else {
            lastWrong = n
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { lastWrong = nil }
        }
    }

    private func restart() { begin() }
}
