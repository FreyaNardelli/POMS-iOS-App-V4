import SwiftUI

/// Kid-facing Rewards tab — mirrors the HTML prototype: XP wallet header,
/// badge grid (earned + locked), and a list of claimable rewards.
struct RewardsView: View {
    private struct Badge: Identifiable {
        let id = UUID(); let emoji: String; let name: String; let bg: UInt; let earned: Bool
    }
    private struct Reward: Identifiable {
        let id = UUID(); let emoji: String; let name: String; let cost: String; let bg: UInt; let locked: Bool
    }

    private let badges: [Badge] = [
        .init(emoji: "🔥", name: "7-day streak", bg: 0xFFE9E0, earned: true),
        .init(emoji: "🏅", name: "First walk",   bg: 0xFFF0D6, earned: true),
        .init(emoji: "🧠", name: "Brain boost",  bg: 0xEEE7F7, earned: true),
        .init(emoji: "🎯", name: "Perfect week", bg: 0xE9F6EE, earned: true),
        .init(emoji: "⚡", name: "Combo x5",     bg: 0xEFE1D5, earned: false),
        .init(emoji: "🏆", name: "Champion",     bg: 0xEFE1D5, earned: false),
    ]
    private let rewards: [Reward] = [
        .init(emoji: "🎨", name: "New watch face",   cost: "100 XP",             bg: 0xFFF0D6, locked: false),
        .init(emoji: "🐾", name: "Sticker pack",     cost: "150 XP",             bg: 0xE9F6EE, locked: false),
        .init(emoji: "🧢", name: "Avatar hat",       cost: "300 XP",             bg: 0xEEE7F7, locked: false),
        .init(emoji: "🎬", name: "Movie night pass", cost: "500 XP · 160 to go", bg: 0xEFE1D5, locked: true),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                wallet
                badgeSection
                rewardSection
            }
            .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 20)
        }
        .background(Theme.cream.ignoresSafeArea())
    }

    private var wallet: some View {
        ZStack(alignment: .topTrailing) {
            Circle().fill(Color.white.opacity(0.12)).frame(width: 110, height: 110).offset(x: 20, y: -20)
            VStack(alignment: .leading, spacing: 4) {
                Text("YOUR XP TO SPEND").font(Theme.display(12, .heavy)).foregroundColor(.white.opacity(0.9))
                Text("340 XP").font(Theme.display(34, .bold)).foregroundColor(.white)
                Text("160 XP to your next reward").font(Theme.display(12, .bold)).foregroundColor(.white)
                ProgressCapsule(fraction: 0.68, track: .white.opacity(0.3), fill: .white)
                    .frame(height: 7).padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .background(
            LinearGradient(colors: [Theme.orange, Color(hex: 0xFF4E2B)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var badgeSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("Badges earned").font(Theme.display(15, .bold)).foregroundColor(Theme.inkSoft)
                Spacer()
                Text("4 of 6").font(Theme.display(12, .heavy)).foregroundColor(Theme.coralRed)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(badges) { b in
                    VStack(spacing: 6) {
                        Text(b.emoji).font(.system(size: 22))
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(Color(hex: b.bg)))
                            .grayscale(b.earned ? 0 : 1).opacity(b.earned ? 1 : 0.5)
                        Text(b.name).font(Theme.display(10.5, .heavy))
                            .foregroundColor(b.earned ? Theme.inkSoft : Theme.brownDim)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 12).padding(.horizontal, 6)
                    .background(b.earned ? Theme.card : Color(hex: 0xF7EDE3))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4]))
                            .foregroundColor(b.earned ? .clear : Color(hex: 0xE3CDBD))
                    )
                    .shadow(color: b.earned ? Theme.cardShadow : .clear, radius: 8, y: 6)
                }
            }
        }
    }

    private var rewardSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("Claim a reward").font(Theme.display(15, .bold)).foregroundColor(Theme.inkSoft)
            VStack(spacing: 10) {
                ForEach(rewards) { r in
                    HStack(spacing: 12) {
                        Text(r.emoji).font(.system(size: 20))
                            .frame(width: 40, height: 40)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color(hex: r.bg)))
                            .grayscale(r.locked ? 1 : 0).opacity(r.locked ? 0.6 : 1)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.name).font(Theme.display(15, .semibold))
                                .foregroundColor(r.locked ? Color(hex: 0x8A7266) : Theme.ink)
                            Text(r.cost).font(.system(size: 11.5)).foregroundColor(Theme.brownDim)
                        }
                        Spacer(minLength: 4)
                        if r.locked {
                            Text("🔒").font(.system(size: 13))
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(Capsule().fill(Color(hex: 0xF1E1D4)))
                        } else {
                            Text("Claim").font(Theme.display(12.5, .bold)).foregroundColor(.white)
                                .padding(.horizontal, 15).padding(.vertical, 8)
                                .background(Capsule().fill(Theme.coralRed))
                        }
                    }
                    .padding(EdgeInsets(top: 11, leading: 13, bottom: 11, trailing: 13))
                    .background(r.locked ? Color(hex: 0xFBF3EA) : Theme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color(hex: 0xF0E4D9), lineWidth: r.locked ? 1 : 0)
                    )
                    .shadow(color: r.locked ? .clear : Theme.cardShadow, radius: 8, y: 6)
                }
            }
        }
    }
}
