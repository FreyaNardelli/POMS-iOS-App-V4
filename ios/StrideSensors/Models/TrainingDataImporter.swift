import Foundation
import simd

/// Imports externally supplied walking data — a raw accelerometer/gyro time
/// series plus a precise known distance — as new training examples for the
/// patient's swing-speed model.
///
/// **Why this exists.** The model's normal training labels are speeds
/// derived from the phone's own GPS, which is convenient but imprecise
/// (consumer GPS is typically accurate to a few metres, worse near
/// buildings). A researcher who has a more precise ground truth for a walk —
/// a measured/marked course timed with a stopwatch, survey-grade GPS, a
/// treadmill readout, motion-capture, etc. — can import that walk's raw
/// sensor stream plus its known distance instead. It's run through
/// **exactly** the same pca-acc feature pipeline (`WalkingSpeedEstimator` +
/// `GravityRemover`) that live capture uses, so the resulting examples are
/// indistinguishable in kind from GPS-labelled ones — just more accurate.
///
/// ## Required CSV format
///
/// One row per raw sensor sample:
///
/// ```
/// session_id, timestamp, accel_x, accel_y, accel_z, gyro_x, gyro_y, gyro_z, known_distance_m
/// ```
///
/// - **session_id** — groups rows into separate walks within one file. Rows
///   sharing a `session_id` are treated as one continuous walk, sorted by
///   `timestamp`. If the column is missing entirely, the whole file is
///   treated as one session.
/// - **timestamp** — epoch milliseconds or seconds (auto-detected: values
///   above 1e12 are treated as ms — the same rule the watch packet parser
///   uses). A session's *duration* (last timestamp − first, within that
///   session) combined with `known_distance_m` is what produces the speed
///   label, so real, monotonically meaningful timestamps matter here —
///   relative "seconds since start of recording" numbers work fine for
///   duration, but produce a nonsense calendar date for the example (which
///   this importer detects and falls back to the import time for instead).
/// - **accel_x / accel_y / accel_z** — **raw** accelerometer, m/s², *with
///   gravity still included* (~9.8 m/s² total magnitude at rest) — the same
///   as what the watch streams. Do **not** pre-subtract gravity;
///   `GravityRemover` does that identically to live capture. Supplying
///   already-gravity-removed linear acceleration here will silently produce
///   bad features rather than an error, so this is the single most
///   important thing to get right.
/// - **gyro_x / gyro_y / gyro_z** — rad/s. Optional (defaults to 0 if the
///   columns are absent) — not currently used by the feature pipeline, but
///   accepted for forward compatibility.
/// - **known_distance_m** — the precise *total* distance covered during
///   that entire session, in metres, repeated on every row of that session.
///   This is the whole point of importing: a number more trustworthy than
///   what the phone's own GPS would have measured. If it varies row to row
///   within a session (e.g. a typo on one row), the values are averaged
///   rather than one arbitrarily picked — but that's a fallback, not a
///   feature to rely on; keep it constant per session.
///
/// Column **names** are matched case- and punctuation-insensitively and with
/// unit annotations stripped (so `"Session ID"`, `"SessionId"`,
/// `"session_id"`, and `"Timestamp (ms)"` all work), and column **order**
/// doesn't need to match the list above — matching is by header name.
///
/// Each session is treated as **constant-speed** for labelling purposes —
/// `speed = known_distance_m / session_duration_seconds`, applied to every
/// 5-second analysis window in that session. That's the simplifying
/// assumption implicit in any single "total distance" ground truth. If a
/// session's real speed varied a lot, splitting it into multiple
/// `session_id`s (one per roughly-constant-speed stretch), each with its own
/// `known_distance_m`, gives the model cleaner labels than one long
/// variable-speed session would.
///
/// A plain CSV parser is used (naive comma-splitting, no quoted-field
/// support) — consistent with the rest of this app's CSV handling
/// (`SensorLogStore`). Keep `session_id` free of commas.
enum TrainingDataImporter {

    struct ImportResult {
        var sessionsFound: Int = 0
        var sessionsImported: Int = 0
        var examplesAdded: Int = 0
        var skippedRowCount: Int = 0
        var issues: [String] = []
        /// The examples this import produced — `WalkingModelStore` adds
        /// these to the training buffer and refits. Empty on any failure
        /// serious enough that nothing usable was found.
        var examples: [PatientWalkingModel.Example] = []
        var success: Bool { examplesAdded > 0 }
    }

    private enum Column: CaseIterable {
        case sessionID, timestamp, accelX, accelY, accelZ, gyroX, gyroY, gyroZ, knownDistance

        /// Canonicalised (see `canonical(_:)`) header aliases this column
        /// will match.
        var aliases: [String] {
            switch self {
            case .sessionID:     return ["sessionid", "session", "sessionidentifier", "id"]
            case .timestamp:     return ["timestamp", "time", "t", "ts"]
            case .accelX:        return ["accelx", "accx", "ax", "accelerationx"]
            case .accelY:        return ["accely", "accy", "ay", "accelerationy"]
            case .accelZ:        return ["accelz", "accz", "az", "accelerationz"]
            case .gyroX:         return ["gyrox", "gyrx", "gx", "rotationx"]
            case .gyroY:         return ["gyroy", "gyry", "gy", "rotationy"]
            case .gyroZ:         return ["gyroz", "gyrz", "gz", "rotationz"]
            case .knownDistance: return ["knowndistancem", "knowndistance", "distancem",
                                          "distance", "distancemeters"]
            }
        }
    }

    /// Lowercases, strips parenthetical/bracketed unit annotations (so
    /// `"Timestamp (ms)"` canonicalises to `"timestamp"`, not
    /// `"timestampms"` — stripping punctuation *before* removing the
    /// annotation would glue the unit onto the name and break matching),
    /// then strips remaining non-alphanumeric characters.
    private static func canonical(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\[[^\]]*\]"#, with: "", options: .regularExpression)
        return out.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    // MARK: - Entry point

    /// Parses `url` and builds training examples. Does file I/O and runs the
    /// full feature pipeline — call this off the main thread (see
    /// `WalkingModelStore.importTrainingData`).
    static func importCSV(url: URL) -> ImportResult {
        var result = ImportResult()

        // Files picked from outside the app's sandbox (Files app, iCloud
        // Drive, AirDrop) need this to actually be readable.
        let needsSecurityScope = url.startAccessingSecurityScopedResource()
        defer { if needsSecurityScope { url.stopAccessingSecurityScopedResource() } }

        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            result.issues.append("Couldn't read the file — make sure it's a plain-text .csv.")
            return result
        }

        var lines = text.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else {
            result.issues.append("The file is empty.")
            return result
        }
        let headers = lines.removeFirst().components(separatedBy: ",").map { canonical($0) }

        var colIndex: [Column: Int] = [:]
        for col in Column.allCases {
            if let idx = headers.firstIndex(where: { col.aliases.contains($0) }) {
                colIndex[col] = idx
            }
        }

        guard let tsIdx = colIndex[.timestamp],
              let axIdx = colIndex[.accelX], let ayIdx = colIndex[.accelY], let azIdx = colIndex[.accelZ]
        else {
            result.issues.append("Missing required columns — need at least timestamp, accel_x, accel_y, accel_z, and known_distance_m.")
            return result
        }
        guard let distIdx = colIndex[.knownDistance] else {
            result.issues.append("Missing 'known_distance_m' column — that's the precise distance this import is for.")
            return result
        }
        let sidIdx = colIndex[.sessionID]
        if sidIdx == nil {
            result.issues.append("No 'session_id' column found — treating the whole file as one session.")
        }
        let gxIdx = colIndex[.gyroX], gyIdx = colIndex[.gyroY], gzIdx = colIndex[.gyroZ]

        struct RawRow {
            let sessionID: String
            let t: Double
            let accel: SIMD3<Double>
            let gyro: SIMD3<Double>
            let dist: Double
        }
        var rows: [RawRow] = []

        for line in lines {
            let fields = line.components(separatedBy: ",")
            func field(_ i: Int?) -> String? {
                guard let i, i < fields.count else { return nil }
                return fields[i].trimmingCharacters(in: .whitespaces)
            }
            guard let tRaw = field(tsIdx).flatMap(Double.init),
                  let ax = field(axIdx).flatMap(Double.init),
                  let ay = field(ayIdx).flatMap(Double.init),
                  let az = field(azIdx).flatMap(Double.init),
                  let dist = field(distIdx).flatMap(Double.init), dist.isFinite, dist > 0
            else {
                result.skippedRowCount += 1
                continue
            }
            let gx = field(gxIdx).flatMap(Double.init) ?? 0
            let gy = field(gyIdx).flatMap(Double.init) ?? 0
            let gz = field(gzIdx).flatMap(Double.init) ?? 0
            let sid = sidIdx.flatMap(field) ?? "session_1"
            // ms -> s, same rule SensorPacketParser uses for the watch feed.
            let t = tRaw > 1_000_000_000_000 ? tRaw / 1000.0 : tRaw

            rows.append(RawRow(sessionID: sid, t: t,
                               accel: SIMD3<Double>(ax, ay, az),
                               gyro: SIMD3<Double>(gx, gy, gz),
                               dist: dist))
        }

        guard !rows.isEmpty else {
            result.issues.append("No valid data rows found — check the column headers and that values parse as numbers.")
            return result
        }

        let sessions = Dictionary(grouping: rows, by: { $0.sessionID })
        result.sessionsFound = sessions.count
        let filenameLabel = url.lastPathComponent

        for (sid, sessionRows) in sessions.sorted(by: { $0.key < $1.key }) {
            let sorted = sessionRows.sorted { $0.t < $1.t }
            guard sorted.count >= 8 else {
                result.issues.append("Session '\(sid)': only \(sorted.count) rows, need at least 8 — skipped.")
                continue
            }
            let duration = sorted.last!.t - sorted.first!.t
            guard duration > 0.5 else {
                result.issues.append("Session '\(sid)': timestamps span \(String(format: "%.2f", duration))s — too short to derive a speed — skipped.")
                continue
            }
            // Average rather than pick one row -- degenerates correctly to
            // the exact value when (as instructed) it's constant per session.
            let knownDistance = sorted.map { $0.dist }.reduce(0, +) / Double(sorted.count)
            let speed = knownDistance / duration
            guard speed.isFinite, speed >= 0, speed < 15 else {   // 15 m/s ≈ 33mph — generous sanity ceiling
                result.issues.append("Session '\(sid)': computed speed \(String(format: "%.2f", speed)) m/s looks implausible — check known_distance_m and timestamps — skipped.")
                continue
            }

            var remover = GravityRemover()
            let readings: [WalkingSpeedEstimator.Reading] = sorted.map { r in
                let (ext, dir) = remover.process(r.accel)
                return WalkingSpeedEstimator.Reading(t: r.t, ext: ext, gravityDir: dir, lat: nil, long: nil)
            }
            let analysis = WalkingSpeedEstimator.analyze(readings)
            guard !analysis.epochs.isEmpty else {
                result.issues.append("Session '\(sid)': produced no analysable 5-second windows — skipped.")
                continue
            }

            let sessionDate = plausibleDate(fromEpochSeconds: sorted.first!.t) ?? Date()
            let source = "Imported: \(filenameLabel) · \(sid)"
            let newExamples = analysis.epochs.map {
                PatientWalkingModel.Example(features: $0.features, speed: speed, date: sessionDate, source: source)
            }
            result.examples.append(contentsOf: newExamples)
            result.examplesAdded += newExamples.count
            result.sessionsImported += 1
        }

        return result
    }

    /// A parsed timestamp is only trustworthy as a real calendar date if it
    /// falls in a sane range — guards against files using relative
    /// (seconds-since-recording-start) timestamps instead of real epoch
    /// values, which would otherwise silently produce a 1970 (or otherwise
    /// absurd) example date.
    private static func plausibleDate(fromEpochSeconds t: Double) -> Date? {
        let d = Date(timeIntervalSince1970: t)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let earliest = cal.date(from: DateComponents(year: 2015, month: 1, day: 1)),
              let latest = cal.date(from: DateComponents(year: 2035, month: 1, day: 1))
        else { return nil }
        return (d > earliest && d < latest) ? d : nil
    }
}
