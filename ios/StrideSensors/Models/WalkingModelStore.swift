import Foundation
import Combine
import simd

/// The outcome shown after a 6-minute walk test.
struct WalkResult: Identifiable {
    let id = UUID()
    let date: Date
    let durationSeconds: Double

    /// Swing-based (pca-acc regression) estimates.
    let swingDistanceMeters: Double?
    let swingAvgSpeed: Double?           // m/s
    let perMinuteSpeed: [Double]         // m/s, one entry per completed minute

    /// GPS reference for the same test, if a fix was held.
    let gpsDistanceMeters: Double?

    /// Number of 5-second pca-acc analysis windows computed for this test
    /// (see `WalkingSpeedEstimator.epochSeconds`), and how many of those
    /// carried a usable GPS speed label. Useful on its own even before/without
    /// calibration — and especially on an early Finish, where it shows
    /// exactly how much data the walk actually produced.
    let epochCount: Int
    let gpsEpochCount: Int

    /// Calibration state at the time of this result.
    let calibrated: Bool
    let trainingCount: Int
    let usedGPSForTraining: Bool
    let note: String
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
    // Distance is summed across *every distinct* fix that arrives while
    // capturing — not sampled on a timer — so it matches the resolution the
    // training labels are computed at. Publishing to SwiftUI is throttled
    // separately (see `publishInterval`) because the accumulation can run at
    // the full IMU rate, which is far faster than any display needs.
    @Published private(set) var liveStartFix: LiveFix?
    @Published private(set) var liveCurrentFix: LiveFix?
    @Published private(set) var liveDistance: Double = 0
    /// Number of distinct GPS fixes seen this capture (lets the UI show the
    /// effective GPS update rate rather than implying a fixed 1 Hz).
    @Published private(set) var liveFixCount: Int = 0

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
    private var trackLastCoord: (Double, Double)?
    private var trackDistance: Double = 0
    private var trackFixCount: Int = 0
    private var lastPublishAt: CFTimeInterval = 0

    private let fm = FileManager.default

    private init() {
        model = Self.load() ?? PatientWalkingModel()
    }

    // MARK: - Test lifecycle (called from WalkView)

    func startCapture() {
        lock.lock()
        buffer.removeAll(keepingCapacity: true)
        gravityRemover = GravityRemover()
        capturing = true
        trackStart = nil
        trackCurrent = nil
        trackLastCoord = nil
        trackDistance = 0
        trackFixCount = 0
        lastPublishAt = 0
        lock.unlock()
        DispatchQueue.main.async {
            self.lastResult = nil
            self.liveStartFix = nil
            self.liveCurrentFix = nil
            self.liveDistance = 0
            self.liveFixCount = 0
        }
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
        let fDist = trackDistance, fCount = trackFixCount
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
                    swingDistanceMeters: nil, swingAvgSpeed: nil, perMinuteSpeed: [],
                    gpsDistanceMeters: nil, epochCount: 0, gpsEpochCount: 0,
                    calibrated: self.model.isCalibrated,
                    trainingCount: self.model.trainingCount, usedGPSForTraining: false,
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
        // Every packet is inspected. Only *distinct* coordinates advance the
        // distance: the watch streams IMU faster than its GPS updates, so
        // consecutive packets often repeat the same fix, and summing those
        // repeats would add nothing but would inflate the fix count.
        var publish: (LiveFix?, LiveFix?, Double, Int)? = nil
        if let la = latitude, let lo = longitude {
            let fix = LiveFix(lat: la, long: lo,
                              time: Date(timeIntervalSince1970: timestamp))
            let changed = trackLastCoord.map { $0.0 != la || $0.1 != lo } ?? true
            if changed {
                if let last = trackLastCoord {
                    trackDistance += WalkingSpeedEstimator.haversine(last.0, last.1, la, lo)
                }
                trackLastCoord = (la, lo)
                trackFixCount += 1
            }
            trackCurrent = fix
            if trackStart == nil { trackStart = fix }

            let now = CFAbsoluteTimeGetCurrent()
            if now - lastPublishAt >= publishInterval {
                lastPublishAt = now
                publish = (trackStart, trackCurrent, trackDistance, trackFixCount)
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
        let analysis = WalkingSpeedEstimator.analyze(readings)
        let gpsEpochCount = analysis.epochs.filter { $0.gpsSpeed != nil }.count
        let hadGPS = gpsEpochCount > 0

        // Train from this test's GPS-labelled epochs, then read the model back.
        var m = model
        if hadGPS { m.addAndRetrain(epochs: analysis.epochs, date: Date(), source: source) }
        let calibrated = m.isCalibrated

        // Predict per-epoch speed and integrate distance (only meaningful once
        // the model is calibrated).
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

        let note = makeNote(hadGPS: hadGPS, calibrated: calibrated,
                            trainingCount: m.trainingCount,
                            gpsDistance: analysis.gpsDistanceMeters)

        // Persist the (possibly) updated model.
        if hadGPS {
            DispatchQueue.main.async { self.model = m }
            Self.save(m)
        }

        return WalkResult(
            date: Date(),
            durationSeconds: analysis.durationSeconds,
            swingDistanceMeters: swingDistance,
            swingAvgSpeed: swingAvg,
            perMinuteSpeed: perMinute,
            gpsDistanceMeters: analysis.gpsDistanceMeters,
            epochCount: analysis.epochs.count,
            gpsEpochCount: gpsEpochCount,
            calibrated: calibrated,
            trainingCount: m.trainingCount,
            usedGPSForTraining: hadGPS,
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

    private func makeNote(hadGPS: Bool, calibrated: Bool,
                          trainingCount: Int, gpsDistance: Double?) -> String {
        if calibrated {
            return hadGPS
                ? "Estimate refined with this test's GPS. Model trained on \(trainingCount) walking segments."
                : "Estimate from your calibrated model (no GPS this test). Trained on \(trainingCount) segments."
        }
        if hadGPS {
            let need = max(0, PatientWalkingModel.minExamplesToTrust - trainingCount)
            return "Calibrating: collected \(trainingCount) GPS-labelled segments so far" +
                   (need > 0 ? " — about \(need) more needed before swing-only estimates are shown." : ".")
        }
        return "No GPS fix during this test and the model isn't calibrated yet. Record a walk outdoors with a GPS fix to start calibration."
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
