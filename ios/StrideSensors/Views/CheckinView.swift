import SwiftUI

/// Daily check-in — interactive energy level, mood picker and symptom-severity
/// sliders, matching the HTML prototype. Values are local UI state; wire them to
/// SensorStore / your backend when the scoring model is defined.
struct CheckinView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var energy = 2
    @State private var mood = 2
    private let symptomNames = ["Fatigue", "Depression", "Muscle weakness",
                                "Numbness/tingling", "Muscle rigidity", "Balance issues", "Vision issues"]
    @State private var severity: [Double] = [0.54, 0.24, 0.48, 0.22, 0.32, 0.76, 0.82]

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    energySection
                    moodSection
                    symptomSection
                }
                .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 16)
            }
            saveBar
        }
        .background(Theme.cream.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Text("‹").font(.system(size: 22, weight: .semibold)).foregroundColor(Color(hex: 0x8A7266))
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: 0xF4E7DC)))
            }
            Text("Daily check-in").font(Theme.display(18, .semibold)).foregroundColor(Theme.ink)
            Spacer()
            HStack(spacing: 5) {
                ForEach(0..<4) { i in
                    Capsule().fill(i < 3 ? Theme.coralRed : Color(hex: 0xEAD9CC))
                        .frame(width: 20, height: 6)
                }
            }
        }
        .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 6)
    }

    private var energySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How's your energy today?").font(Theme.display(18, .semibold)).foregroundColor(Theme.ink)
            HStack(alignment: .bottom, spacing: 7) {
                ForEach(0..<5) { i in
                    let heights: [CGFloat] = [24, 34, 44, 50, 56]
                    RoundedRectangle(cornerRadius: 8)
                        .fill(i <= energy ? Theme.orange : Color(hex: 0xF1E1D4))
                        .frame(height: heights[i]).frame(maxWidth: .infinity)
                        .onTapGesture { energy = i }
                }
            }.frame(height: 56)
            HStack {
                Text("Running low"); Spacer()
                Text("Pretty good").foregroundColor(Theme.coralRed); Spacer()
                Text("Full power")
            }
            .font(Theme.display(11, .heavy)).foregroundColor(Theme.brownDim)
        }
    }

    private var moodSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What's your mood?").font(Theme.display(18, .semibold)).foregroundColor(Theme.ink)
            HStack(spacing: 8) {
                ForEach(0..<5) { i in
                    let faces = ["😔", "😐", "🙂", "😊", "😄"]
                    Text(faces[i]).font(.system(size: 30))
                        .frame(width: 54, height: 54)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(i == mood ? Color(hex: 0xFFE7CF) : .clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .strokeBorder(Theme.orange, lineWidth: i == mood ? 3 : 0)
                        )
                        .frame(maxWidth: .infinity)
                        .onTapGesture { mood = i }
                }
            }
        }
    }

    private var symptomSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("How strong are your symptoms?").font(Theme.display(18, .semibold)).foregroundColor(Theme.ink)
            Text("Slide each one — green is mild, red is strong.")
                .font(.system(size: 12)).foregroundColor(Theme.brown).padding(.bottom, 10)
            VStack(spacing: 13) {
                ForEach(symptomNames.indices, id: \.self) { i in
                    HStack(spacing: 11) {
                        Text(symptomNames[i]).font(Theme.display(12.5, .heavy)).foregroundColor(Theme.inkSoft)
                            .frame(width: 118, alignment: .leading).lineLimit(1)
                        SeveritySlider(value: $severity[i])
                    }
                }
            }
        }
    }

    private var saveBar: some View {
        Button { dismiss() } label: {
            Text("Save check-in · +10 XP →")
                .font(Theme.display(17, .semibold)).foregroundColor(.white)
                .frame(maxWidth: .infinity).padding(15)
                .background(RoundedRectangle(cornerRadius: 18).fill(Theme.coralRed))
                .shadow(color: Theme.coralRed.opacity(0.28), radius: 12, y: 10)
        }
        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 22)
    }
}

/// A green→amber→red gradient track with a draggable handle whose color tracks
/// severity.
struct SeveritySlider: View {
    @Binding var value: Double

    private func color(_ v: Double) -> Color {
        v < 0.34 ? Theme.green : (v < 0.67 ? Color(hex: 0xE8952A) : Theme.coralRed)
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(
                    LinearGradient(colors: [Theme.green, Color(hex: 0xF2B72E), Theme.coralRed],
                                   startPoint: .leading, endPoint: .trailing)
                ).frame(height: 12)
                Circle().fill(.white)
                    .overlay(Circle().strokeBorder(color(value), lineWidth: 3))
                    .frame(width: 22, height: 22)
                    .shadow(color: .black.opacity(0.15), radius: 4, y: 3)
                    .offset(x: CGFloat(value) * (w - 22))
            }
            .frame(height: 22)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        value = min(1, max(0, (g.location.x - 11) / (w - 22)))
                    }
            )
        }
        .frame(height: 22)
    }
}
