import Foundation
import Combine
import simd

/// One epoch's ground-truth (tape-measure) speed vs. what the model would
/// have predicted for it, using the model as it existed BEFORE this walk's
/// own data was added — a genuine out-of-sample check, not a comparison
/// against a model that was just trained on these same points.
struct ValidationPoint: Identifiable {
    let id = UUID()
    let actual: Double      // m/s, from tape-measure marks
    let predicted: Double   // m/s, prior model's prediction
}

/// The outcome shown after a 6-minute walk test or a calibration walk.
struct WalkResult: Identifiable {
    let id = UUID()
    let date: Date
    let durationSeconds: Double
    let swingDistanceMeters: Double?
    let swingAvgSpeed: Double?
    let swingDistanceErrorMeters: Double?
    let perMinuteSpeed: [Double]
    let gpsDistanceMeters: Double?
    let epochCount: Int
    let gpsEpochCount: Int
    let manualEpochCount: Int
    let manualValidation: [ValidationPoint]
    let calibrated: Bool
    let trainingCount: Int
    let usedGPSForTraining: Bool
    let usedManualForTraining: Bool
    let note: String

    init(date: Date,
         durationSeconds: Double,
         swingDistanceMeters: Double?,
         swingAvgSpeed: Double?,
         swingDistanceErrorMeters: Double?,
         perMinuteSpeed: [Double],
         gpsDistanceMeters: Double?,
         epochCount: Int,
         gpsEpochCount: Int,
         manualEpochCount: Int,
         manualValidation: [ValidationPoint],
         calibrated: Bool,
         trainingCount: Int,
         usedGPSForTraining: Bool,
         usedManualForTraining: Bool,
         note: String)
    {
        self.date = date
        self.durationSeconds = durationSeconds
        self.swingDistanceMeters = swingDistanceMeters
        self.swingAvgSpeed = swingAvgSpeed
        self.swingDistanceErrorMeters = swingDistanceErrorMeters
        self.perMinuteSpeed = perMinuteSpeed
        self.gpsDistanceMeters = gpsDistanceMeters
        self.epochCount = epochCount
        self.gpsEpochCount = gpsEpochCount
        self.manualEpochCount = manualEpochCount
        self.manualValidation = manualValidation
        self.calibrated = calibrated
        self.trainingCount = trainingCount
        self.usedGPSForTraining = usedGPSForTraining
        self.usedManualForTraining = usedManualForTraining
        self.note = note
    }
}

/// A single GPS fix observed during capture, with the timestamp of the sample
/// it arrived on.
struct LiveFix: Equatable {
    let lat: Double
    let long: Double
    let time: Date
}

/// Owns the persisted `PatientWalkingModel`, drives training/prediction, and
/// buffers the live stream during a 6MWT so a `WalkResult` can be produced the
/// moment the test ends.
///
/// Gravity handling mirrors `SensorStore`: a per-axis exponential low-pass of
/// **raw** accel gives the gravity direction; subtracting it yields the
/// external (linear) acceleration the estimator needs. We buffer raw-derived
/// readings only while a test is active, so there's no cost the rest of the
/// time.
final class WalkingModelStore: ObservableObject {

    static let shared = WalkingModelStore()

    @Published private(set) var model: PatientWalkingModel
    @Published private(set) var lastResult: WalkResult?
    @Published private(set) var isAnalyzing = false

    // MARK: Live GPS tracking (accumulated at full packet rate)
    //
    // Every packet is inspected as it arrives — not sampled on a timer — but
    // distance itself accumulates as locked-in ~20s chunks (net displacement
    // per chunk) rather than a running sum of every fix-to-fix hop; see
    // trackDistance's doc comment for why. Publishing to SwiftUI is
    // throttled separately (see `publishInterval`) because inspection can
    // run at the full IMU rate, far faster than any display needs.
    @Published private(set) var liveStartFix: LiveFix?
    @Published private(set) var liveCurrentFix: LiveFix?
    @Published private(set) var liveDistance: Double = 0
    /// Number of distinct GPS fixes seen this capture (lets the UI show the
    /// effective GPS update rate rather than implying a fixed 1 Hz).
    @Published private(set) var liveFixCount: Int = 0
    @Published private(set) var manualMode = false
    @Published private(set) var liveManualDistance: Double = 0
    @Published private(set) var liveManualMarkCount: Int = 0

    /// UI refresh cap for the live values. Accumulation is unthrottled.
    private let publishInterval: CFTimeInterval = 0.1   // 10 Hz

    /// True while a test is recording into the swing buffer.
    private(set) var capturing = false

    private var buffer: [WalkingSpeedEstimator.Reading] = []
    private var gravityRemover = GravityRemover()
    private let lock = NSLock()

    // Internal (lock-protected) tracking accumulators.
    private var trackStart: LiveFix?
    private var trackCurrent: LiveFix?
    // Distance is tracked as locked-in ~20s chunks (see gpsLabelWindowSeconds)
    // plus the current still-open chunk's own net displacement, NOT raw
    // per-fix summation -- see epochGPSSpeed's doc comment for why summing
    // every consecutive fix-to-fix hop is severely biased by GPS jitter.
    private var trackDistance: Double = 0             // sum of COMPLETED chunks
    private var trackChunkStartTime: Double?
    private var trackChunkStartCoord: (Double, Double)?
    private var trackChunkLastCoord: (Double, Double)?
    /// Running max of "chunk-start -> latest fix" displacement seen so far
    /// THIS chunk. Used only for the live display (see currentLiveDistance)
    /// so the number never visibly decreases mid-chunk from GPS noise
    /// (a single haversine(start, latest) snapshot can legitimately dip as
    /// new noisy fixes arrive, even while genuinely walking forward — that
    /// looked like a bug, not "more accurate," so it's clamped here). The
    /// LOCKED-IN total (trackDistance) still uses the true, unclamped
    /// chunk-end displacement when a chunk closes, so the accumulated total
    /// over a whole test stays unbiased — only the live mid-chunk display
    /// is smoothed, not the number actually banked.
    private var trackChunkDisplayMax: Double = 0
    private var trackFixCount: Int = 0
    private var lastPublishAt: CFTimeInterval = 0
    private var manualMarks: [WalkingSpeedEstimator.ManualMark] = []

    private let fm = FileManager.default

    private init() {
        model = Self.load() ?? PatientWalkingModel()
    }
    
    /// Locked-in distance from completed ~20s chunks, plus the current
    /// (still-open) chunk's clamped display value — see
    /// `trackChunkDisplayMax`'s doc comment for why it's a running max
    /// rather than a raw snapshot. Must be called with `lock` already held.
    private func currentLiveDistance() -> Double {
        trackDistance + trackChunkDisplayMax
    }

    // MARK: - Test lifecycle (called from WalkView)

func startCapture(manualMode: Bool = false) {
        lock.lock()
        buffer.removeAll(keepingCapacity: true)
        gravityRemover = GravityRemover()
        capturing = true
        trackStart = nil
        trackCurrent = nil
        trackDistance = 0
        trackChunkStartTime = nil
        trackChunkStartCoord = nil
        trackChunkLastCoord = nil
        trackChunkDisplayMax = 0
        trackFixCount = 0
        manualMarks.removeAll(keepingCapacity: true)
        lock.unlock()
        // startCapture() is only ever called from a SwiftUI button action
        // (WalkView / CalibrationWalkView), i.e. already on the main thread
        // — unlike ingest()/analyze(), which run on background threads and
        // need the DispatchQueue.main.async wrapping seen below.
        self.manualMode = manualMode
        DispatchQueue.main.async {
            self.lastResult = nil
            self.liveStartFix = nil
            self.liveCurrentFix = nil
            self.liveDistance = 0
            self.liveFixCount = 0
            self.liveManualDistance = 0
            self.liveManualMarkCount = 0
        }
    }

    /// Records one manual distance-mark tap. Call this directly from the
    /// "Mark" button's action.
    ///
    /// Uses the most recent sample's own timestamp — NOT the phone's local
    /// clock — so marks land on the same timebase as the buffered readings
    /// (`Reading.t`, which comes from the watch's reported time, or the
    /// phone's receive time as a fallback). Stamping marks with `Date()`
    /// instead would silently offset every mark relative to the epochs
    /// it's meant to label.
    func recordManualMark(intervalMeters: Double) {
        guard capturing, manualMode, intervalMeters > 0,
              let t = SensorStore.shared.latest?.timestamp else { return }
        lock.lock()
        let newTotal = (manualMarks.last?.cumulativeDistance ?? 0) + intervalMeters
        manualMarks.append(WalkingSpeedEstimator.ManualMark(t: t, cumulativeDistance: newTotal))
        let count = manualMarks.count
        lock.unlock()
        liveManualDistance = newTotal
        liveManualMarkCount = count
    }

    /// Stop capturing and analyse. Returns immediately; the result is published
    /// on `lastResult` (analysis runs off the main thread).
    ///
    /// `source` labels any training examples this test produces (see
    /// `PatientWalkingModel.Example.source`) — `WalkView`'s 6-minute walk
    /// test and `CalibrationWalkView`'s calibration walk both drive capture
    /// through this same method, and this is how the researcher view tells
    /// their examples apart later.
    func stopCaptureAndAnalyze(source: String = "6MWT") {
        lock.lock()
        capturing = false
        let readings = buffer
        buffer.removeAll(keepingCapacity: true)
        // Final exact publish so the displayed values aren't left up to one
        // throttle interval stale.
        let fStart = trackStart, fCur = trackCurrent
        let fDist = currentLiveDistance(), fCount = trackFixCount
        lock.unlock()

        DispatchQueue.main.async {
            self.liveStartFix = fStart
            self.liveCurrentFix = fCur
            self.liveDistance = fDist
            self.liveFixCount = fCount
        }

        guard readings.count >= 8 else {
            DispatchQueue.main.async {
                self.lastResult = WalkResult(
                    date: Date(), durationSeconds: 0,
                    swingDistanceMeters: nil, swingAvgSpeed: nil, swingDistanceErrorMeters: nil, perMinuteSpeed: [],
                    gpsDistanceMeters: nil, epochCount: 0, gpsEpochCount: 0, manualEpochCount: 0,
                    manualValidation: [],
                    calibrated: self.model.isCalibrated,
                    trainingCount: self.model.trainingCount, usedGPSForTraining: false, usedManualForTraining: false,
                    note: "Not enough sensor data was captured to estimate speed.")
            }
            return
        }

        DispatchQueue.main.async { self.isAnalyzing = true }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.analyze(readings, source: source)
            DispatchQueue.main.async {
                self.lastResult = result
                self.isAnalyzing = false
            }
        }
    }

    // MARK: - Ingest (called from SensorStore.ingest, background queue)

    /// `rawAccel` is the accelerometer reading *before* gravity removal, in the
    /// sensor frame; gyro is currently unused for orientation (accel low-pass
    /// suffices for the gravity direction) but is accepted for future upgrades.
    func ingest(rawAccel: SIMD3<Double>, gyro: SIMD3<Double>,
                timestamp: Double, latitude: Double?, longitude: Double?) {
        lock.lock()
        guard capturing else { lock.unlock(); return }

        let (ext, gDir) = gravityRemover.process(rawAccel)

        buffer.append(WalkingSpeedEstimator.Reading(
            t: timestamp, ext: ext, gravityDir: gDir, lat: latitude, long: longitude))
        // Safety cap: 6 min at 100 Hz = 36k; keep generous headroom.
        if buffer.count > 120_000 { buffer.removeFirst(buffer.count - 120_000) }

        // ── Live GPS accumulation, at whatever rate fixes actually arrive ──
        // Distance locks in one ~20s chunk (gpsLabelWindowSeconds) at a
        // time via net displacement (chunk-start fix -> latest fix in that
        // chunk). The live DISPLAY value is the locked-in total plus a
        // running max of the current chunk's displacement so far (see
        // trackChunkDisplayMax) -- not a raw snapshot, so the number never
        // visibly dips mid-chunk from GPS noise. This avoids both the
        // severe overestimation bias of summing every fix-to-fix hop (see
        // epochGPSSpeed's doc comment) and a live number that looks broken
        // by occasionally ticking backward. Fix count only advances on
        // genuinely new coordinates: the watch streams IMU faster than its
        // GPS updates, so consecutive packets often repeat the same fix.
        var publish: (LiveFix?, LiveFix?, Double, Int)? = nil
        if let la = latitude, let lo = longitude {
            let fix = LiveFix(lat: la, long: lo,
                              time: Date(timeIntervalSince1970: timestamp))
            let windowSeconds = WalkingSpeedEstimator.gpsLabelWindowSeconds

            let isNewCoordinate = trackChunkLastCoord.map { $0.0 != la || $0.1 != lo } ?? true
            if isNewCoordinate { trackFixCount += 1 }

            if trackChunkStartTime == nil {
                // First GPS fix of this capture: opens the first chunk.
                trackChunkStartTime = timestamp
                trackChunkStartCoord = (la, lo)
                trackChunkDisplayMax = 0
            } else if let chunkStart = trackChunkStartTime, timestamp - chunkStart >= windowSeconds {
                // Current chunk is done: lock in its net displacement, then
                // open the next chunk at this fix (catching up on any gap).
                if let start = trackChunkStartCoord, let last = trackChunkLastCoord {
                    trackDistance += WalkingSpeedEstimator.haversine(start.0, start.1, last.0, last.1)
                }
                var next = chunkStart
                while timestamp - next >= windowSeconds { next += windowSeconds }
                trackChunkStartTime = next
                trackChunkStartCoord = (la, lo)
                trackChunkDisplayMax = 0
            }
            trackChunkLastCoord = (la, lo)   // always the latest fix, whichever chunk it's in
            if let start = trackChunkStartCoord {
                let d = WalkingSpeedEstimator.haversine(start.0, start.1, la, lo)
                trackChunkDisplayMax = max(trackChunkDisplayMax, d)
            }

            trackCurrent = fix
            if trackStart == nil { trackStart = fix }

            let now = CFAbsoluteTimeGetCurrent()
            if now - lastPublishAt >= publishInterval {
                lastPublishAt = now
                publish = (trackStart, trackCurrent, currentLiveDistance(), trackFixCount)
            }
        }
        lock.unlock()

        if let (s, c, d, n) = publish {
            DispatchQueue.main.async {
                self.liveStartFix = s
                self.liveCurrentFix = c
                self.liveDistance = d
                self.liveFixCount = n
            }
        }
    }

    // MARK: - Analysis + training

    private func analyze(_ readings: [WalkingSpeedEstimator.Reading], source: String) -> WalkResult {
        var analysis = WalkingSpeedEstimator.analyze(readings)

        // Re-derive each epoch's GPS speed LABEL from a ~20s window instead
        // of its own narrow 5s span (see WalkingSpeedEstimator.
        // gpsLabelWindowSeconds) -- reduces GPS position-error-relative-to-
        // distance noise. Feature extraction stays on 5s epochs throughout;
        // only the GPS ground-truth label attached to each epoch changes.
        // Applies to both 6MWT tests and calibration walks, since both
        // funnel through this same function.
        analysis = WalkingSpeedEstimator.Analysis(
            epochs: WalkingSpeedEstimator.widenGPSWindow(analysis.epochs, readings: readings),
            gpsDistanceMeters: analysis.gpsDistanceMeters,
            durationSeconds: analysis.durationSeconds,
            sampleRateHz: analysis.sampleRateHz)

        let marksSnapshot: [WalkingSpeedEstimator.ManualMark]
        lock.lock(); marksSnapshot = manualMarks; lock.unlock()
        let usedManual = marksSnapshot.count >= 2
        if usedManual {
            analysis = WalkingSpeedEstimator.Analysis(
                epochs: WalkingSpeedEstimator.assignManualSpeeds(analysis.epochs, marks: marksSnapshot),
                gpsDistanceMeters: analysis.gpsDistanceMeters,
                durationSeconds: analysis.durationSeconds,
                sampleRateHz: analysis.sampleRateHz)
        }

        let gpsEpochCount = analysis.epochs.filter { $0.gpsSpeed != nil }.count
        let manualEpochCount = analysis.epochs.filter { $0.manualSpeed != nil }.count
        let hadGPS = gpsEpochCount > 0
        let hadManual = manualEpochCount > 0

        // Out-of-sample validation: compare against `model` (the stored
        // property) BEFORE it's reassigned below — not `m` (the local copy
        // that's about to be trained on these same points).
        var validation: [ValidationPoint] = []
        if hadManual {
            for e in analysis.epochs {
                if let truth = e.manualSpeed, let pred = model.predictSpeed(features: e.features) {
                    validation.append(ValidationPoint(actual: truth, predicted: pred))
                }
            }
        }

        // Train from this test's labelled epochs, then read the model back.
        var m = model
        if hadGPS || hadManual { m.addAndRetrain(epochs: analysis.epochs, date: Date(), source: source) }
        let calibrated = m.isCalibrated

        var swingDistance: Double? = nil
        var swingAvg: Double? = nil
        var perMinute: [Double] = []
        if calibrated {
            var dist = 0.0
            var speeds: [(t: Double, v: Double)] = []
            for e in analysis.epochs {
                if let v = m.predictSpeed(features: e.features) {
                    dist += v * e.duration
                    speeds.append((e.startT, v))
                }
            }
            if !speeds.isEmpty {
                swingDistance = dist
                swingAvg = analysis.durationSeconds > 0 ? dist / analysis.durationSeconds : nil
                perMinute = perMinuteAverages(speeds, t0: readings.first!.t,
                                              duration: analysis.durationSeconds)
            }
        }

        var swingDistanceError: Double? = nil
        if let rmse = m.loocvSpeedRMSE {
            swingDistanceError = rmse * analysis.durationSeconds
        }

        let note = makeNote(hadGPS: hadGPS, hadManual: hadManual, calibrated: calibrated,
                            trainingCount: m.trainingCount, gpsDistance: analysis.gpsDistanceMeters)

        if hadGPS || hadManual {
            DispatchQueue.main.async { self.model = m }
            Self.save(m)
        }

        return WalkResult(
            date: Date(),
            durationSeconds: analysis.durationSeconds,
            swingDistanceMeters: swingDistance,
            swingAvgSpeed: swingAvg,
            swingDistanceErrorMeters: swingDistanceError,
            perMinuteSpeed: perMinute,
            gpsDistanceMeters: analysis.gpsDistanceMeters,
            epochCount: analysis.epochs.count,
            gpsEpochCount: gpsEpochCount,
            manualEpochCount: manualEpochCount,
            manualValidation: validation,
            calibrated: calibrated,
            trainingCount: m.trainingCount,
            usedGPSForTraining: hadGPS,
            usedManualForTraining: hadManual,
            note: note)
    }

    private func perMinuteAverages(_ speeds: [(t: Double, v: Double)],
                                   t0: Double, duration: Double) -> [Double] {
        guard duration > 0 else { return [] }
        let minutes = Int(ceil(duration / 60))
        var sums = [Double](repeating: 0, count: minutes)
        var counts = [Int](repeating: 0, count: minutes)
        for s in speeds {
            var idx = Int((s.t - t0) / 60)
            if idx < 0 { idx = 0 }; if idx >= minutes { idx = minutes - 1 }
            sums[idx] += s.v; counts[idx] += 1
        }
        return (0..<minutes).map { counts[$0] > 0 ? sums[$0] / Double(counts[$0]) : 0 }
    }

    private func makeNote(hadGPS: Bool, hadManual: Bool, calibrated: Bool,
                          trainingCount: Int, gpsDistance: Double?) -> String {
        let sourceWord = hadManual ? "manually marked distance" : "GPS"
        if calibrated {
            return (hadGPS || hadManual)
                ? "Estimate refined with this test's \(sourceWord). Model trained on \(trainingCount) walking segments."
                : "Estimate from your calibrated model (no new labels this test). Trained on \(trainingCount) segments."
        }
        if hadGPS || hadManual {
            let need = max(0, PatientWalkingModel.minExamplesToTrust - trainingCount)
            return "Calibrating: collected \(trainingCount) labelled segments so far" +
                   (need > 0 ? " — about \(need) more needed before swing-only estimates are shown." : ".")
        }
        return "No GPS fix and no manual marks were recorded this test, and the model isn't calibrated yet."
    }

    // MARK: - Persistence (the patient "user information" file)

    static var modelURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("patient_walking_model.json")
    }

    private static func load() -> PatientWalkingModel? {
        guard let data = try? Data(contentsOf: modelURL) else { return nil }
        return try? JSONDecoder().decode(PatientWalkingModel.self, from: data)
    }

    private static func save(_ model: PatientWalkingModel) {
        guard let data = try? JSONEncoder().encode(model) else { return }
        try? data.write(to: modelURL, options: .atomic)
    }

    /// Wipe the patient model (e.g. new patient on this device).
    func resetModel() {
        let fresh = PatientWalkingModel()
        model = fresh
        try? fm.removeItem(at: Self.modelURL)
    }

    // MARK: - Import (external, more-precise distance data)

    /// Parses a CSV at `url` (see `TrainingDataImporter` for the required
    /// format) and adds any resulting examples to the training buffer,
    /// refitting the model. Runs off the main thread — CSV parsing plus
    /// running the full pca-acc pipeline on potentially many rows is real
    /// work — and calls `completion` back on the main thread with a summary
    /// the UI can show directly (sessions found, examples added, any rows
    /// or sessions that had to be skipped and why).
    func importTrainingData(from url: URL,
                            completion: @escaping (TrainingDataImporter.ImportResult) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = TrainingDataImporter.importCSV(url: url)
            if !result.examples.isEmpty {
                var m = self.model
                m.addExamples(result.examples)
                DispatchQueue.main.async {
                    self.model = m
                    Self.save(m)
                    completion(result)
                }
            } else {
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    // MARK: - Researcher view (inspect / delete training sessions)

    /// Every training session currently in the buffer, newest first — one
    /// entry per completed 6MWT, calibration walk, or imported session. See
    /// `PatientWalkingModel.sessionGroups()`.
    func sessionGroups() -> [PatientWalkingModel.SessionGroup] { model.sessionGroups() }

    /// Deletes one whole session (every example belonging to it) and refits
    /// on what remains.
    func deleteSession(_ group: PatientWalkingModel.SessionGroup) {
        deleteExamples(at: IndexSet(group.indices))
    }

    /// Deletes individual examples by their current index in `model.examples`
    /// and refits on what remains. Callers should get `offsets` from a
    /// freshly-read `model.examples`/`sessionGroups()` — indices are only
    /// valid until the next mutation.
    func deleteExamples(at offsets: IndexSet) {
        var m = model
        m.removeExamples(at: offsets)
        model = m
        Self.save(m)
    }
}
