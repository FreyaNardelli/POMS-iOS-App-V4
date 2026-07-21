import SwiftUI

/// Sheet shown from the calibration screen's "Researcher view" button —
/// lists every training session (one 6MWT, one calibration walk, or one
/// imported session), with counts/dates/speed and swipe-to-delete, plus
/// drill-in to see individual epochs for finer-grained deletion.
///
/// "Session" here isn't stored explicitly — see
/// `PatientWalkingModel.sessionGroups()` for how it's reconstructed from
/// `(date, source)` on each `Example`.
struct ResearcherDataView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var walkModel = WalkingModelStore.shared

    @State private var confirmDeleteSession: PatientWalkingModel.SessionGroup?

    private let cardFill = Color(hex: 0x3A2820)
    private let cardBorder = Color(hex: 0x5A463E)
    private let dimText = Color(hex: 0xC9B6AC)
    private let faintText = Color(hex: 0x9A8478)

    private var groups: [PatientWalkingModel.SessionGroup] { walkModel.sessionGroups() }

    var body: some View {
        NavigationStack {
            Group {
                if groups.isEmpty {
                    empty
                } else {
                    list
                }
            }
            .background(Color(hex: 0x2E1F19).ignoresSafeArea())
            .navigationTitle("Researcher View")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color(hex: 0x2E1F19), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(Color(hex: 0xFFB98C))
                }
            }
        }
        .tint(Theme.orange)
        .preferredColorScheme(.dark)
        .confirmationDialog(
            confirmDeleteSession.map { "Delete this session? (\($0.count) segments)" } ?? "",
            isPresented: Binding(get: { confirmDeleteSession != nil }, set: { if !$0 { confirmDeleteSession = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete session", role: .destructive) {
                if let g = confirmDeleteSession { walkModel.deleteSession(g) }
                confirmDeleteSession = nil
            }
            Button("Cancel", role: .cancel) { confirmDeleteSession = nil }
        }
    }

    // MARK: Summary + list

    private var summary: some View {
        HStack(spacing: 20) {
            stat("\(walkModel.model.trainingCount)", "total segments")
            stat("\(groups.count)", "sessions")
            stat(walkModel.model.isCalibrated ? "Yes" : "No", "calibrated")
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(Theme.display(20, .bold)).foregroundColor(.white)
            Text(label).font(.system(size: 11)).foregroundColor(dimText)
        }
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 0) {
                summary
                LazyVStack(spacing: 10) {
                    ForEach(groups) { group in
                        NavigationLink {
                            SessionDetailView(group: group)
                        } label: {
                            sessionRow(group)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 20)
            }
        }
    }

    private func sessionRow(_ group: PatientWalkingModel.SessionGroup) -> some View {
        let speeds = speedValues(for: group)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(group.source ?? "Unlabeled session")
                    .font(Theme.display(14, .semibold)).foregroundColor(.white)
                Text(dateText(group.date))
                    .font(.system(size: 12)).foregroundColor(dimText)
                if let speeds, let lo = speeds.min(), let hi = speeds.max() {
                    Text(lo == hi
                         ? String(format: "%.2f m/s", lo)
                         : String(format: "%.2f–%.2f m/s", lo, hi))
                        .font(Theme.mono(11)).foregroundColor(faintText)
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 4) {
                Text("\(group.count)").font(Theme.display(18, .bold)).foregroundColor(Theme.mint)
                Text("segments").font(.system(size: 10)).foregroundColor(faintText)
            }
            Button {
                confirmDeleteSession = group
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.coralRed)
                    .padding(8)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(cardFill)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(cardBorder, lineWidth: 1))
        )
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "tray").font(.system(size: 40)).foregroundColor(faintText)
            Text("No training sessions yet").font(Theme.display(16, .bold)).foregroundColor(dimText)
            Text("Record a calibration walk, a 6-minute walk test, or import a CSV to see sessions here.")
                .font(.system(size: 13)).foregroundColor(faintText)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
            Spacer()
        }
    }

    // MARK: Helpers

    private func speedValues(for group: PatientWalkingModel.SessionGroup) -> [Double]? {
        let examples = walkModel.model.examples
        let speeds = group.indices.compactMap { $0 < examples.count ? examples[$0].speed : nil }
        return speeds.isEmpty ? nil : speeds
    }

    private func dateText(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy · h:mm a"
        return f.string(from: date)
    }
}

/// Drill-in from a session row — every individual epoch (feature vector +
/// speed label) in that session, with per-epoch delete for finer control
/// than deleting the whole session.
private struct SessionDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var walkModel = WalkingModelStore.shared
    let group: PatientWalkingModel.SessionGroup

    private let cardFill = Color(hex: 0x3A2820)
    private let cardBorder = Color(hex: 0x5A463E)
    private let dimText = Color(hex: 0xC9B6AC)
    private let faintText = Color(hex: 0x9A8478)

    /// Recomputed each render from the live model rather than the `group`
    /// passed in, so deleting an epoch immediately reflects here — `group`
    /// itself is a point-in-time snapshot whose indices go stale after any
    /// deletion.
    private var currentIndices: [Int] {
        walkModel.model.sessionGroups().first { $0.id == group.id }?.indices ?? []
    }

    var body: some View {
        List {
            Section {
                ForEach(currentIndices, id: \.self) { idx in
                    if idx < walkModel.model.examples.count {
                        epochRow(walkModel.model.examples[idx])
                    }
                }
                .onDelete(perform: delete)
            } header: {
                Text("\(currentIndices.count) segment\(currentIndices.count == 1 ? "" : "s")")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color(hex: 0x2E1F19).ignoresSafeArea())
        .navigationTitle(group.source ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton().foregroundColor(Color(hex: 0xFFB98C)) }
        .tint(Theme.orange)
    }

    private func epochRow(_ e: PatientWalkingModel.Example) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "%.2f m/s", e.speed))
                    .font(Theme.display(14, .semibold)).foregroundColor(.white)
                Text("48 pca-acc features")
                    .font(.system(size: 11)).foregroundColor(faintText)
            }
            Spacer()
        }
        .listRowBackground(cardFill)
    }

    private func delete(at offsets: IndexSet) {
        let toRemove = IndexSet(offsets.compactMap { offset -> Int? in
            guard offset < currentIndices.count else { return nil }
            return currentIndices[offset]
        })
        guard !toRemove.isEmpty else { return }
        walkModel.deleteExamples(at: toRemove)
        // If that emptied the session, back out to the list.
        if walkModel.model.sessionGroups().first(where: { $0.id == group.id }) == nil {
            dismiss()
        }
    }
}
