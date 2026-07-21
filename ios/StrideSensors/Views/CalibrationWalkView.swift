import SwiftUI

/// Calibration walk — an outdoor walk whose GPS speed labels train this
/// patient's personal `PatientWalkingModel`.
///
/// This exists because the swing-based (pca-acc) speed estimate is *per
/// patient*: Zihajehzadeh & Park found a subject-specific model is necessary
/// below ~100 cm/s, which is where most pediatric-onset MS gait sits. The model
/// learns the mapping from this patient's own arm-swing signature to their own
/// GPS-measured speed.
///
/// Unlike `WalkView` this does **not** open a `[6MWT]` session in the CSV log —
/// a calibration walk isn't a clinical test, and mixing the two would pollute
/// the 6MWT history. It only feeds the training buffer.
struct CalibrationWalkView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: SensorStore
    @ObservedObject private var walkModel = WalkingModelStore.shared

    @State private var recording = false
    @State private var elapsed = 0
    @State private var ticker: Timer? = nil
    @State private var countBefore = 0
    @State private var finishedRun = false
    @State private var showResetConfirm = false
    @State private var showImportSheet = false
    @State private var showResearcherView = false
    enum DistanceSource: String, CaseIterable { case gps = "GPS", manual = "Manual" }
    @State private var distanceSource: DistanceSource = .gps
    @State private var manualIntervalText: String = "1"
    @State private var activeMarkInterval: Double = 1.0

    private var parsedInterval: Double? {
        guard let v = Double(manualIntervalText), v > 0 else { return nil }
        return v
    }

    private var gpsFix: Bool { store.hasGPSFix }
    private var watchLive: Bool { store.packetsPerSecond > 0 }
    private var ready: Bool {
        guard watchLive else { return false }
        return distanceSource == .gps ? gpsFix : parsedInterval != nil
    }

    private var target: Int { PatientWalkingModel.minExamplesToTrust }
    private var progress: Double {
        min(1.0, Double(walkModel.model.trainingCount) / Double(max(target, 1)))
    }
    private var elapsedText: String { String(format: "%d:%02d", elapsed / 60, elapsed % 60) }

    // Coordinates/distance come from `WalkingModelStore`, which accumulates on
    // every packet during capture rather than on a timer. Before a recording
    // starts (and after it ends) the "current" row falls back to the live
    // sensor stream so the reading stays useful outside a session.
    private var startFix: LiveFix? { walkModel.liveStartFix }
    private var currentFix: LiveFix? {
        if recording, let f = walkModel.liveCurrentFix { return f }
        guard gpsFix, let s = store.latest, let la = s.latitude, let lo = s.longitude else { return nil }
        return LiveFix(lat: la, long: lo, time: Date(timeIntervalSince1970: s.timestamp))
    }
    private var distanceTraveled: Double { walkModel.liveDistance }
    private var fixCount: Int { walkModel.liveFixCount }

    /// Observed GPS update rate this session — surfaced so it's visible that
    /// fixes are consumed as fast as they arrive, not at a fixed 1 Hz.
    private var fixRateText: String {
        guard fixCount > 1, elapsed > 0 else { return "—" }
        return String(format: "%.1f Hz", Double(fixCount) / Double(elapsed))
    }

    private static let clockFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()
    private func clock(_ d: Date?) -> String { d.map { Self.clockFmt.string(from: $0) } ?? "--:--:--" }
    private func coordText(_ f: LiveFix?) -> String {
        f.map { String(format: "%.5f, %.5f", $0.lat, $0.long) } ?? "—, —"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                sourcePicker.padding(.horizontal, 18).padding(.top, 12)
                readiness.padding(.horizontal, 18).padding(.top, 14)
                if distanceSource == .manual {
                    manualStatus.padding(.horizontal, 18).padding(.top, 12)
                    markButton.padding(.horizontal, 18).padding(.top, 12)
                } else {
                    coordinatesSection.padding(.horizontal, 18).padding(.top, 12)
                }
                progressRing.padding(.top, 22)
                controls.padding(.horizontal, 22).padding(.top, 24)
                outcome.padding(.horizontal, 18).padding(.top, 18)
                guidance.padding(.horizontal, 18).padding(.top, 20)
                researcherTools.padding(.horizontal, 18).padding(.top, 22)
                Spacer(minLength: 34)
            }
        }
        .background(Color(hex: 0x2E1F19).ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .onDisappear {
            stopTicker()
            // Keep whatever was walked — train on it rather than discarding.
            if walkModel.capturing {
                let label = distanceSource == .manual ? "Calibration walk (manual)" : "Calibration walk"
                walkModel.stopCaptureAndAnalyze(source: label)
            }
        }
        .confirmationDialog("Reset calibration?", isPresented: $showResetConfirm, titleVisibility: .visible) {
            Button("Reset calibration data", role: .destructive) { walkModel.resetModel() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Deletes this patient's learned walking model and all \(walkModel.model.trainingCount) training segments. Use this when handing the device to a different patient.")
        }
        .sheet(isPresented: $showImportSheet) { ImportInstructionsView() }
        .sheet(isPresented: $showResearcherView) { ResearcherDataView() }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Text("‹ Calibration walk")
                    .font(Theme.display(16, .semibold))
                    .foregroundColor(Color(hex: 0xF6C9B8))
            }
            Spacer()
        }
        .padding(.horizontal, 22).padding(.top, 10)
    }

    // MARK: Readiness (both signals are required to collect training data)

    private var readiness: some View {
        VStack(spacing: 8) {
            readyRow(ok: watchLive,
                     okText: "Watch streaming",
                     badText: "Watch not streaming")
            if distanceSource == .gps {
                readyRow(ok: gpsFix,
                         okText: "GPS Fix Acquired",
                         badText: "Waiting for GPS Fix")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(hex: 0x3A2820))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color(hex: 0x5A463E), lineWidth: 1))
        )
    }

    private func readyRow(ok: Bool, okText: String, badText: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(ok ? Theme.mint : Theme.amber).frame(width: 8, height: 8)
            Text(ok ? okText : badText)
                .font(Theme.display(13, .heavy))
                .foregroundColor(ok ? Theme.mint : Theme.amber)
            Spacer()
        }
    }

    // MARK: Coordinates / distance

    /// Starting/current fixes and the running distance walked during the
    /// active (or most recently finished) recording. Starting coordinates are
    /// captured lazily — a GPS fix may not exist the instant "Start" is
    /// tapped — and everything freezes once recording stops so the numbers
    /// stay readable afterward instead of clearing.
    private var coordinatesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            coordRow(label: "Starting Coordinates", fix: startFix)
            coordRow(label: "Current Coordinates", fix: currentFix)
            HStack {
                Text("Distance traveled (m)")
                    .font(Theme.display(11, .heavy)).foregroundColor(Color(hex: 0xC9B6AC))
                Spacer()
                Text(String(format: "%.1f", distanceTraveled))
                    .font(Theme.mono(14)).foregroundColor(.white)
            }
            if fixCount > 0 {
                HStack {
                    Text("GPS fixes used")
                        .font(Theme.display(11, .heavy)).foregroundColor(Color(hex: 0x9A8478))
                    Spacer()
                    Text("\(fixCount)  ·  \(fixRateText)")
                        .font(Theme.mono(11)).foregroundColor(Color(hex: 0x9A8478))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(hex: 0x3A2820))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color(hex: 0x5A463E), lineWidth: 1))
        )
    }

    private func coordRow(label: String, fix: LiveFix?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(label) (\(clock(fix?.time)))")
                .font(Theme.display(11, .heavy)).foregroundColor(Color(hex: 0xC9B6AC))
            Text(coordText(fix))
                .font(Theme.mono(13)).foregroundColor(.white)
        }
    }

    // MARK: Progress ring

    private var progressRing: some View {
        ZStack {
            Circle().stroke(Color(hex: 0x4A362E), lineWidth: 18)
            Circle().trim(from: 0, to: progress)
                .stroke(walkModel.model.isCalibrated ? Theme.mint : Theme.orange,
                        style: StrokeStyle(lineWidth: 18, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.4), value: progress)
            VStack(spacing: 3) {
                if recording {
                    Text("RECORDING").font(Theme.display(10, .heavy)).foregroundColor(Theme.amber)
                    Text(elapsedText).font(Theme.display(40, .bold)).foregroundColor(.white)
                } else {
                    Text(walkModel.model.isCalibrated ? "CALIBRATED" : "CALIBRATION")
                        .font(Theme.display(10, .heavy))
                        .foregroundColor(Color(hex: 0xC9B6AC))
                    Text("\(Int(progress * 100))%")
                        .font(Theme.display(40, .bold)).foregroundColor(.white)
                }
                Text("\(walkModel.model.trainingCount) / \(target) segments")
                    .font(Theme.mono(11)).foregroundColor(Color(hex: 0xC9B6AC))
            }
        }
        .frame(width: 216, height: 216)
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 10) {
            Button { toggle() } label: {
                Text(recording ? "Stop & save" : "Start calibration walk")
                    .font(Theme.display(16, .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity).padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(recording ? Theme.coralRed : (ready ? Theme.orange : Color(hex: 0x6B4F44)))
                    )
            }
            .disabled(!ready && !recording)

            if !ready && !recording {
                Text("Both the watch stream and a GPS fix are needed — GPS provides the speed the model learns from.")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: 0x9A8478))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Outcome of the run just completed

    @ViewBuilder
    private var outcome: some View {
        if walkModel.isAnalyzing {
            HStack(spacing: 10) {
                ProgressView().tint(Theme.orange)
                Text("Processing walk…")
                    .font(Theme.display(13, .heavy)).foregroundColor(Color(hex: 0xC9B6AC))
            }
        } else if finishedRun, let r = walkModel.lastResult {
            let added = max(0, r.trainingCount - countBefore)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: added > 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(added > 0 ? Theme.mint : Theme.amber)
                    Text(added > 0 ? "Added \(added) training segments" : "No usable segments from that walk")
                        .font(Theme.display(14, .bold))
                        .foregroundColor(added > 0 ? Theme.mint : Theme.amber)
                }
                if added == 0 {
                    Text("Segments need a steady GPS fix and real movement. Try walking outdoors, away from buildings.")
                        .font(.system(size: 12)).foregroundColor(Color(hex: 0xC9B6AC))
                        .fixedSize(horizontal: false, vertical: true)
                } else if walkModel.model.isCalibrated {
                    Text("This patient's model is calibrated. Swing-based speed & distance will now appear after each 6-minute walk test.")
                        .font(.system(size: 12)).foregroundColor(Color(hex: 0xC9B6AC))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    let need = max(0, target - r.trainingCount)
                    Text("About \(need) more segments (~\(Int(ceil(Double(need) * 5.0 / 60.0))) more minutes of walking) to finish calibrating.")
                        .font(.system(size: 12)).foregroundColor(Color(hex: 0xC9B6AC))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(hex: 0x3A2820))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color(hex: 0x5A463E), lineWidth: 1))
            )
        }
    }

    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("DISTANCE GROUND TRUTH")
                .font(Theme.display(10, .heavy)).foregroundColor(Color(hex: 0x9A8478))
            Picker("", selection: $distanceSource) {
                Text("GPS").tag(DistanceSource.gps)
                Text("Manual (tape measure)").tag(DistanceSource.manual)
            }
            .pickerStyle(.segmented)
            .disabled(recording)

            if distanceSource == .manual {
                HStack(spacing: 8) {
                    Text("Mark every").font(.system(size: 13)).foregroundColor(Color(hex: 0xC9B6AC))
                    TextField("1", text: $manualIntervalText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.center)
                        .frame(width: 50)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(hex: 0x2E1F19)))
                        .foregroundColor(.white)
                        .disabled(recording)
                    Text("meters").font(.system(size: 13)).foregroundColor(Color(hex: 0xC9B6AC))
                }
            }
        }
    }

    private var manualStatus: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "%.1f m", walkModel.liveManualDistance))
                    .font(Theme.display(22, .bold)).foregroundColor(.white)
                Text("distance (manual)").font(.system(size: 11)).foregroundColor(Color(hex: 0xC9B6AC))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(walkModel.liveManualMarkCount)")
                    .font(Theme.display(22, .bold)).foregroundColor(Theme.mint)
                Text("marks").font(.system(size: 11)).foregroundColor(Color(hex: 0xC9B6AC))
            }
            Spacer()
        }
    }

    private var markButton: some View {
        Button {
            walkModel.recordManualMark(intervalMeters: activeMarkInterval)
        } label: {
            VStack(spacing: 4) {
                Text("MARK").font(Theme.display(14, .heavy))
                Text("+\(String(format: "%g", activeMarkInterval)) m").font(Theme.mono(12))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.orange))
        }
        .buttonStyle(.plain)
        .disabled(!recording)
    }
    
    // MARK: Guidance

    private var guidance: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("HOW TO CALIBRATE")
                .font(Theme.display(10, .heavy)).tracking(0.5)
                .foregroundColor(Color(hex: 0xFFB98C))
            bullet("Walk outdoors where GPS is strong — an open path, not indoors or between tall buildings.")
            bullet("Let the arm wearing the watch swing naturally. Don't hold it, pocket it, or push a stroller.")
            bullet("Walk at a comfortable, everyday pace for about 3 minutes. Mixing in some slower and faster stretches makes the model more accurate across speeds.")
            bullet("Repeat on another day to keep improving it — training carries over between walks.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(hex: 0x3A2820).opacity(0.6))
        )
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•").font(.system(size: 12)).foregroundColor(Theme.orange)
            Text(text).font(.system(size: 12)).foregroundColor(Color(hex: 0xC9B6AC))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Researcher tools

    /// Import + inspect/delete + reset — grouped together since they're all
    /// advanced actions a researcher or clinician uses, not something a
    /// patient taps day to day, unlike everything above this divider.
    private var researcherTools: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Rectangle().fill(Color(hex: 0x5A463E)).frame(height: 1)
                Text("RESEARCHER TOOLS")
                    .font(Theme.display(10, .heavy)).tracking(0.5)
                    .foregroundColor(Color(hex: 0x9A8478))
                    .fixedSize()
                Rectangle().fill(Color(hex: 0x5A463E)).frame(height: 1)
            }

            toolButton(icon: "square.and.arrow.down", title: "Import training data",
                      subtitle: "Add a walk with a more precise known distance than GPS") {
                showImportSheet = true
            }
            toolButton(icon: "list.bullet.rectangle", title: "Researcher view",
                      subtitle: "View or delete recorded training sessions") {
                showResearcherView = true
            }

            if walkModel.model.trainingCount > 0 && !recording {
                Button { showResetConfirm = true } label: {
                    Text("Reset calibration (new patient)")
                        .font(Theme.display(12, .heavy))
                        .foregroundColor(Color(hex: 0x9A8478))
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
            }
        }
    }

    private func toolButton(icon: String, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Color(hex: 0xFFB98C))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.display(14, .semibold)).foregroundColor(.white)
                    Text(subtitle).font(.system(size: 11)).foregroundColor(Color(hex: 0xC9B6AC))
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold))
                    .foregroundColor(Color(hex: 0x9A8478))
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(hex: 0x3A2820))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color(hex: 0x5A463E), lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: Logic

    private func toggle() {
        if recording {
            recording = false
            stopTicker()
            let label = distanceSource == .manual ? "Calibration walk (manual)" : "Calibration walk"
            walkModel.stopCaptureAndAnalyze(source: label)
            finishedRun = true
        } else {
            countBefore = walkModel.model.trainingCount
            finishedRun = false
            elapsed = 0
            if distanceSource == .manual { activeMarkInterval = parsedInterval ?? 1.0 }
            walkModel.startCapture(manualMode: distanceSource == .manual)
            recording = true
            startTicker()
        }
    }

    /// Only drives the elapsed clock — GPS distance and coordinates are
    /// accumulated in `WalkingModelStore` on every incoming packet, not here.
    private func startTicker() {
        stopTicker()
        let t = Timer(timeInterval: 1, repeats: true) { _ in
            guard recording else { return }
            elapsed += 1
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func stopTicker() { ticker?.invalidate(); ticker = nil }
}
