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

    /// Calibration state at the time of this result.
    let calibrated: Bool
    let trainingCount: Int
    let usedGPSForTraining: Bool
    let note: String
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

    /// True while a test is recording into the swing buffer.
    private(set) var capturing = false

    private var buffer: [WalkingSpeedEstimator.Reading] = []
    private var gravity = SIMD3<Double>(0, 0, 0)
    private var gravityPrimed = false
    private let gravityAlpha = 0.9        // same as SensorStore
    private let lock = NSLock()

    private let fm = FileManager.default

    private init() {
        model = Self.load() ?? PatientWalkingModel()
    }

    // MARK: - Test lifecycle (called from WalkView)

    func startCapture() {
        lock.lock()
        buffer.removeAll(keepingCapacity: true)
        gravity = .zero
        gravityPrimed = false
        capturing = true
        lock.unlock()
        DispatchQueue.main.async { self.lastResult = nil }
    }

    /// Stop capturing and analyse. Returns immediately; the result is published
    /// on `lastResult` (analysis runs off the main thread).
    func stopCaptureAndAnalyze() {
        lock.lock()
        capturing = false
        let readings = buffer
        buffer.removeAll(keepingCapacity: true)
        lock.unlock()

        guard readings.count >= 8 else {
            DispatchQueue.main.async {
                self.lastResult = WalkResult(
                    date: Date(), durationSeconds: 0,
                    swingDistanceMeters: nil, swingAvgSpeed: nil, perMinuteSpeed: [],
                    gpsDistanceMeters: nil, calibrated: self.model.isCalibrated,
                    trainingCount: self.model.trainingCount, usedGPSForTraining: false,
                    note: "Not enough sensor data was captured to estimate speed.")
            }
            return
        }

        DispatchQueue.main.async { self.isAnalyzing = true }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = self.analyze(readings)
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

        if gravityPrimed {
            gravity = gravityAlpha * gravity + (1 - gravityAlpha) * rawAccel
        } else {
            gravity = rawAccel
            gravityPrimed = true
        }
        let ext = rawAccel - gravity
        let gLen = simd_length(gravity)
        let gDir = gLen > 1e-6 ? gravity / gLen : SIMD3<Double>(0, 0, 1)

        buffer.append(WalkingSpeedEstimator.Reading(
            t: timestamp, ext: ext, gravityDir: gDir, lat: latitude, long: longitude))
        // Safety cap: 6 min at 100 Hz = 36k; keep generous headroom.
        if buffer.count > 120_000 { buffer.removeFirst(buffer.count - 120_000) }
        lock.unlock()
    }

    // MARK: - Analysis + training

    private func analyze(_ readings: [WalkingSpeedEstimator.Reading]) -> WalkResult {
        let analysis = WalkingSpeedEstimator.analyze(readings)
        let hadGPS = analysis.epochs.contains { $0.gpsSpeed != nil }

        // Train from this test's GPS-labelled epochs, then read the model back.
        var m = model
        if hadGPS { m.addAndRetrain(epochs: analysis.epochs, date: Date()) }
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
}
