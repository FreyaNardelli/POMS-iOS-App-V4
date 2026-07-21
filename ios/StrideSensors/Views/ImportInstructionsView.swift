import SwiftUI
import UniformTypeIdentifiers

/// Sheet shown from the calibration screen's "Import training data" button.
/// Explains the required CSV format (mirrors `TrainingDataImporter`'s doc
/// comment — that's the source of truth; this is the in-app reading of it),
/// lets the person pick a file, and shows what happened afterward.
struct ImportInstructionsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var walkModel = WalkingModelStore.shared

    @State private var showFilePicker = false
    @State private var isImporting = false
    @State private var result: TrainingDataImporter.ImportResult?

    private let cardFill = Color(hex: 0x3A2820)
    private let cardBorder = Color(hex: 0x5A463E)
    private let dimText = Color(hex: 0xC9B6AC)
    private let faintText = Color(hex: 0x9A8478)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    intro
                    formatCard
                    exampleCard
                    statusArea
                    pickButton
                }
                .padding(18)
            }
            .background(Color(hex: 0x2E1F19).ignoresSafeArea())
            .navigationTitle("Import Training Data")
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
        .fileImporter(isPresented: $showFilePicker,
                      allowedContentTypes: [.commaSeparatedText, .plainText, .text],
                      allowsMultipleSelection: false,
                      onCompletion: handlePicked)
    }

    // MARK: Sections

    private var intro: some View {
        Text("Bring in a walk with a more precise known distance than phone GPS can give — a measured or marked course, survey-grade GPS, a treadmill readout, and so on. It runs through the same feature pipeline as a live walk, so it trains the model exactly like a calibration walk would — just with a better label.")
            .font(.system(size: 14))
            .foregroundColor(dimText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var formatCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("REQUIRED CSV COLUMNS")
                .font(Theme.display(10, .heavy)).tracking(0.5)
                .foregroundColor(Color(hex: 0xFFB98C))
            columnRow("session_id",
                      "Groups rows into separate walks within one file. Optional — omit it to treat the whole file as one walk.")
            columnRow("timestamp",
                      "Epoch milliseconds or seconds. Determines each session's duration.")
            columnRow("accel_x / accel_y / accel_z",
                      "RAW accelerometer, m/s², WITH gravity included (~9.8 total at rest) — same as what the watch streams. Do not pre-remove gravity; getting this wrong silently produces bad features rather than an error.")
            columnRow("gyro_x / gyro_y / gyro_z",
                      "rad/s. Optional — defaults to 0 if the columns are absent.")
            columnRow("known_distance_m",
                      "The precise TOTAL distance for that whole session, in metres — the same value repeated on every row of the session. This is the number this import exists to supply.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(cardFill)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(cardBorder, lineWidth: 1))
        )
    }

    private func columnRow(_ name: String, _ desc: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name).font(Theme.mono(13)).foregroundColor(.white)
            Text(desc).font(.system(size: 12)).foregroundColor(dimText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var exampleCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("EXAMPLE")
                .font(Theme.display(10, .heavy)).tracking(0.5)
                .foregroundColor(Color(hex: 0xFFB98C))
            Text("""
            session_id,timestamp,accel_x,accel_y,accel_z,known_distance_m
            trackA,1721570000000,1.02,-0.34,9.71,50
            trackA,1721570000020,1.05,-0.31,9.68,50
            trackA,1721570000040,0.98,-0.29,9.75,50
            """)
            .font(Theme.mono(10))
            .foregroundColor(dimText)
            Text("Column order doesn't matter — matching is by header name, and header names tolerate case, spacing, and units like \"Distance (m)\". Keep session_id free of commas.")
                .font(.system(size: 11)).foregroundColor(faintText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(cardFill.opacity(0.6))
        )
    }

    @ViewBuilder
    private var statusArea: some View {
        if isImporting {
            HStack(spacing: 10) {
                ProgressView().tint(Theme.orange)
                Text("Importing and processing…").font(.system(size: 13)).foregroundColor(dimText)
            }
        } else if let r = result {
            resultCard(r)
        }
    }

    private func resultCard(_ r: TrainingDataImporter.ImportResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: r.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundColor(r.success ? Theme.mint : Theme.amber)
                Text(r.success
                     ? "Added \(r.examplesAdded) segment\(r.examplesAdded == 1 ? "" : "s") from \(r.sessionsImported) of \(r.sessionsFound) session\(r.sessionsFound == 1 ? "" : "s")"
                     : "Nothing was imported")
                    .font(Theme.display(14, .bold))
                    .foregroundColor(r.success ? Theme.mint : Theme.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if r.skippedRowCount > 0 {
                Text("\(r.skippedRowCount) row(s) skipped — missing or invalid values.")
                    .font(.system(size: 12)).foregroundColor(dimText)
            }
            ForEach(r.issues, id: \.self) { issue in
                Text("• \(issue)").font(.system(size: 12)).foregroundColor(dimText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if r.success {
                Text(walkModel.model.isCalibrated
                     ? "Model is calibrated."
                     : "Trained on \(walkModel.model.trainingCount) of \(PatientWalkingModel.minExamplesToTrust) segments needed to calibrate.")
                    .font(.system(size: 12)).foregroundColor(faintText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(cardFill)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(cardBorder, lineWidth: 1))
        )
    }

    private var pickButton: some View {
        Button { showFilePicker = true } label: {
            Text(result == nil ? "Choose CSV file…" : "Choose another file…")
                .font(Theme.display(16, .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity).padding(14)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.orange))
        }
        .disabled(isImporting)
    }

    // MARK: Logic

    private func handlePicked(_ picked: Result<[URL], Error>) {
        switch picked {
        case .success(let urls):
            guard let url = urls.first else { return }
            isImporting = true
            result = nil
            walkModel.importTrainingData(from: url) { r in
                isImporting = false
                result = r
            }
        case .failure:
            result = TrainingDataImporter.ImportResult(issues: ["Couldn't access that file."])
        }
    }
}
