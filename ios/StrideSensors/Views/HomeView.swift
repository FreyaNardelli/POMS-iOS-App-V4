import SwiftUI

/// Kid-facing Home tab — mirrors the HTML prototype's Home screen: greeting +
/// level bar, MOVE score ring with live vitals, and the three daily quest cards
/// that navigate to the Check-in, 6-minute walk, and SDMT screens.
struct HomeView: View {
    @EnvironmentObject var store: SensorStore
    @ObservedObject private var walkModel = WalkingModelStore.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    greeting
                    moveScore
                    calibrationCard
                    quests
                }
                .padding(.bottom, 20)
            }
            .background(Theme.cream.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    // MARK: Greeting + level

    private var greeting: some View {
        HStack(spacing: 12) {
            Text("🐻").font(.system(size: 40))
            VStack(alignment: .leading, spacing: 3) {
                Text("LET'S GO, MAYA!")
                    .font(Theme.display(12, .heavy)).foregroundColor(.white.opacity(0.95))
                Text("Level 4 · 340 XP")
                    .font(Theme.display(22, .bold)).foregroundColor(.white)
                ProgressCapsule(fraction: 0.64, track: .white.opacity(0.3), fill: .white)
                    .frame(height: 7).padding(.top, 3)
            }
            VStack(spacing: 1) {
                Text("7").font(Theme.display(26, .bold)).foregroundColor(.white)
                Text("🔥 STREAK").font(Theme.display(10, .heavy)).foregroundColor(.white)
            }
        }
        .padding(16)
        .background(
            LinearGradient(colors: [Theme.orange, Theme.coralRed],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 14).padding(.top, 8)
    }

    // MARK: MOVE score

    private var moveScore: some View {
        let live = store.packetsPerSecond > 0
        let hr = store.latest?.heartRate
        let gpsFix = store.hasGPSFix
        return HStack(spacing: 16) {
            ZStack {
                Circle().stroke(Color(hex: 0x5A463E), lineWidth: 11)
                Circle()
                    .trim(from: 0, to: 0.74)
                    .stroke(Theme.orange, style: StrokeStyle(lineWidth: 11, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 1) {
                    Text("74").font(Theme.display(32, .bold)).foregroundColor(Color(hex: 0xFFF3E9))
                    Text("MOVE SCORE").font(Theme.display(9, .bold)).foregroundColor(Color(hex: 0xC9B6AC))
                }
            }
            .frame(width: 104, height: 104)

            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Circle().fill(live ? Theme.mint : Color(hex: 0xC9B6AC)).frame(width: 7, height: 7)
                        Text(live ? "Watch connected" : "Watch offline")
                            .font(Theme.display(12, .heavy))
                            .foregroundColor(live ? Theme.mint : Color(hex: 0xC9B6AC))
                    }
                    HStack(spacing: 6) {
                        Circle().fill(gpsFix ? Theme.mint : Color(hex: 0xC9B6AC)).frame(width: 7, height: 7)
                        Text(gpsFix ? "GPS Fix Acquired" : "Waiting for GPS Fix")
                            .font(Theme.display(12, .heavy))
                            .foregroundColor(gpsFix ? Theme.mint : Color(hex: 0xC9B6AC))
                    }
                }
                HStack(spacing: 16) {
                    vital(hr != nil ? String(Int(hr!)) : "—", "♥ bpm")
                    vital("98%", "SpO₂")
                    vital("3.1k", "steps")
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(
            LinearGradient(colors: [Color(hex: 0x2E1F19), Color(hex: 0x43302A)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.horizontal, 14).padding(.top, 14)
    }

    private func vital(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(Theme.display(19, .bold)).foregroundColor(Color(hex: 0xFFF3E9))
            Text(label).font(.system(size: 10)).foregroundColor(Color(hex: 0xC9B6AC))
        }
    }

    // MARK: Calibration walk
    //
    // The swing-based speed/distance estimate is per-patient and learns from
    // GPS-labelled walking, so this is prominent (and clearly "action needed")
    // until the model is calibrated, then collapses to a quiet "recalibrate"
    // row so it stays reachable without competing with the daily quests.

    private var calibrationCard: some View {
        let calibrated = walkModel.model.isCalibrated
        let count = walkModel.model.trainingCount
        let target = PatientWalkingModel.minExamplesToTrust
        let fraction = min(1.0, Double(count) / Double(max(target, 1)))

        return NavigationLink { CalibrationWalkView() } label: {
            HStack(spacing: 12) {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(calibrated ? Color(hex: 0xE3F6EA) : Color(hex: 0xE7F0FF))
                    .frame(width: 42, height: 42)
                    .overlay(
                        Image(systemName: calibrated ? "checkmark.seal.fill" : "location.north.line.fill")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundColor(calibrated ? Color(hex: 0x3E8659) : Color(hex: 0x3B6FC4))
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(calibrated ? "Walking model calibrated" : "Calibration walk")
                        .font(Theme.display(16, .semibold)).foregroundColor(Theme.ink)
                    Text(calibrated
                         ? "Trained on \(count) segments · tap to improve"
                         : "Needed for speed & distance · ~3 min outdoors")
                        .font(.system(size: 12)).foregroundColor(Theme.brown)
                        .fixedSize(horizontal: false, vertical: true)
                    if !calibrated {
                        ProgressCapsule(fraction: CGFloat(fraction),
                                        track: Color(hex: 0xEDE2DA),
                                        fill: Color(hex: 0x3B6FC4))
                            .frame(height: 6).padding(.top, 2)
                    }
                }

                Spacer(minLength: 4)

                if calibrated {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(Theme.brownDim)
                } else {
                    Text("\(Int(fraction * 100))%")
                        .font(Theme.display(13, .bold))
                        .foregroundColor(Color(hex: 0x3B6FC4))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Capsule().fill(Color(hex: 0xE7F0FF)))
                }
            }
            .padding(EdgeInsets(top: 13, leading: 14, bottom: 13, trailing: 14))
            .background(Theme.card)
            .overlay(alignment: .leading) {
                Rectangle().fill(calibrated ? Theme.green : Color(hex: 0x3B6FC4)).frame(width: 5)
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: Theme.cardShadow, radius: 8, y: 6)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14).padding(.top, 14)
    }

    // MARK: Quests

    private var quests: some View {
        VStack(spacing: 11) {
            HStack {
                Text("Today's quests").font(Theme.display(15, .bold)).foregroundColor(Theme.inkSoft)
                Spacer()
                Text("+30 XP left").font(Theme.display(12, .heavy)).foregroundColor(Theme.coralRed)
            }.padding(.top, 4)

            NavigationLink { CheckinView() } label: {
                QuestCard(accent: Theme.coralRed, iconBg: Color(hex: 0xFFE3D2),
                          icon: AnyView(Circle().strokeBorder(Theme.coralRed, lineWidth: 2.5).frame(width: 19, height: 19)),
                          title: "Daily check-in", subtitle: "+10 XP · feelings, fatigue & symptoms",
                          goBg: Theme.coralRed, goFg: .white)
            }.buttonStyle(.plain)

            NavigationLink { WalkView() } label: {
                QuestCard(accent: Theme.amber, iconBg: Color(hex: 0xFFF0D6),
                          icon: AnyView(Image(systemName: "figure.walk").font(.system(size: 18, weight: .bold)).foregroundColor(Color(hex: 0xE8952A))),
                          title: "6-minute walk", subtitle: "+15 XP · beat your best 512 m",
                          goBg: Color(hex: 0xFFE7CF), goFg: Color(hex: 0xB57518))
            }.buttonStyle(.plain)

            NavigationLink { SDMTView() } label: {
                QuestCard(accent: Theme.purple, iconBg: Color(hex: 0xEEE7F7),
                          icon: AnyView(RoundedRectangle(cornerRadius: 4).fill(Theme.purple).frame(width: 15, height: 15)),
                          title: "Symbol match (SDMT)", subtitle: "+5 XP · thinking speed · 90 sec",
                          goBg: Color(hex: 0xEEE7F7), goFg: Color(hex: 0x6B4FB0))
            }.buttonStyle(.plain)

            HStack(spacing: 8) {
                statChip("🏅", "12 badges", Color(hex: 0xFFF7DF), Color(hex: 0x8A6A20))
                statChip("🏆", "Rank #3", Color(hex: 0xFFE9E0), Color(hex: 0xC4502F))
                statChip("⚡", "Combo x3", Color(hex: 0xE9F6EE), Color(hex: 0x3E8659))
            }.padding(.top, 2)
        }
        .padding(.horizontal, 14).padding(.top, 16)
    }

    private func statChip(_ emoji: String, _ label: String, _ bg: Color, _ fg: Color) -> some View {
        VStack(spacing: 3) {
            Text(emoji).font(.system(size: 20))
            Text(label).font(Theme.display(10, .heavy)).foregroundColor(fg)
        }
        .frame(maxWidth: .infinity).padding(10)
        .background(bg).clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Reusable pieces

struct QuestCard: View {
    let accent: Color
    let iconBg: Color
    let icon: AnyView
    let title: String
    let subtitle: String
    let goBg: Color
    let goFg: Color

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(iconBg).frame(width: 42, height: 42)
                .overlay(icon)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.display(16, .semibold)).foregroundColor(Theme.ink)
                Text(subtitle).font(.system(size: 12)).foregroundColor(Theme.brown)
            }
            Spacer(minLength: 4)
            Text("GO").font(Theme.display(13, .bold)).foregroundColor(goFg)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Capsule().fill(goBg))
        }
        .padding(EdgeInsets(top: 13, leading: 14, bottom: 13, trailing: 14))
        .background(Theme.card)
        .overlay(alignment: .leading) {
            Rectangle().fill(accent).frame(width: 5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: Theme.cardShadow, radius: 8, y: 6)
    }
}

struct ProgressCapsule: View {
    let fraction: CGFloat
    var track: Color = Theme.track
    var fill: Color = Theme.orange
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(fill).frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
    }
}
