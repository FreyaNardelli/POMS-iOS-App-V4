import Foundation

/// Builds a single .zip containing everything collected and calculated for
/// this patient — the raw sensor logs, and everything the swing-based
/// walking-speed model uses and produces:
///
///   README.txt                 — what's in the archive, generated when
///   training_examples.csv      — every GPS-labelled segment used to train
///                                 the model: its 48 pca-acc features and the
///                                 GPS speed label, one row per segment
///   model_summary.csv          — calibration state, training count, when it
///                                 was last fit, fitted bias
///   model_feature_weights.csv  — the fitted ridge-regression weight (plus
///                                 standardisation mean/std) for each feature
///   feature_legend.csv         — plain-language description of all 48
///                                 features, so the numbers above are legible
///                                 without reading the estimator's source
///   sensor_logs/*.csv          — the same per-day raw logs shown in the
///                                 History tab, one file per day of data
///
/// This is a `.zip` of plain CSVs, not a multi-sheet Excel workbook — true
/// CSV has no concept of "sheets" (that's an Excel-only feature), and the
/// zip-of-CSVs form was the explicit choice here over `.xlsx`, since it's
/// easier to script/parse programmatically (pandas, R, etc.) than opening a
/// multi-sheet workbook.
enum DataExportManager {

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    private static let filenameFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Builds the full export and writes it to a temp file, returning its
    /// URL. Touches disk (reads every day's raw log) and can take a moment
    /// on a long history — call this off the main thread.
    static func buildFullExport() -> URL? {
        SensorLogStore.shared.flushNow()   // make sure today's in-memory data is on disk first

        var zip = ZipArchiveWriter()
        zip.addCSV(name: "README.txt", text: readmeText())
        zip.addCSV(name: "training_examples.csv", text: trainingExamplesCSV())
        zip.addCSV(name: "model_summary.csv", text: modelSummaryCSV())
        zip.addCSV(name: "model_feature_weights.csv", text: modelWeightsCSV())
        zip.addCSV(name: "feature_legend.csv", text: featureLegendCSV())

        for day in SensorLogStore.shared.availableDays {
            let url = SensorLogStore.fileURL(for: day)
            if let data = try? Data(contentsOf: url) {
                zip.add(name: "sensor_logs/\(day).csv", data: data)
            }
        }

        let data = zip.finalize()
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("POMS_full_export_\(filenameFmt.string(from: Date())).zip")
        do {
            try data.write(to: outURL, options: .atomic)
            return outURL
        } catch {
            return nil
        }
    }

    /// Exports just one calibration/6MWT session's training examples as a
    /// single CSV — quick access from the results screen, without pulling
    /// the full "everything" export. Returns nil if there's nothing to export.
    static func buildSessionExport(examples: [PatientWalkingModel.Example], sessionLabel: String) -> URL? {
        guard !examples.isEmpty else { return nil }
        guard let data = trainingExamplesCSV(examples).data(using: .utf8) else { return nil }
        let safeLabel = sessionLabel.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("training_data_\(safeLabel)_\(filenameFmt.string(from: Date())).csv")
        do {
            try data.write(to: outURL, options: .atomic)
            return outURL
        } catch {
            return nil
        }
    }

    /// Exports EVERY training session as one combined CSV — shown at the
    /// bottom of the Researcher View's session list. Rows are sorted
    /// chronologically by date; since every example within one session
    /// shares that session's exact date, a plain chronological sort
    /// automatically keeps each session's rows contiguous with no separate
    /// grouping pass needed. A `# ---- session ----` comment line is still
    /// inserted before each session purely for human readability when the
    /// file is opened directly.
    ///
    /// Columns beyond `trainingExamplesCSV`'s: `session_source` (the raw
    /// origin string) and `ground_truth_type` ("GPS" / "Manual" / "Imported
    /// (precise)", via `PatientWalkingModel.groundTruthLabel(for:)`).
    static func buildAllSessionsCombinedCSV() -> URL? {
        let examples = WalkingModelStore.shared.model.examples
        guard !examples.isEmpty else { return nil }

        let sorted = examples.sorted { $0.date < $1.date }
        let names = WalkingSpeedEstimator.featureNames
        var out = (["session_source", "ground_truth_type", "date", "speed_mps"] + names).joined(separator: ",") + "\n"

        var lastSessionKey: String? = nil
        for e in sorted {
            let key = "\(e.date.timeIntervalSince1970)|\(e.source ?? "")"
            if key != lastSessionKey {
                let label = e.source ?? "Unlabeled session"
                out += "# ---- Session: \(csvEscape(label)) · \(dateFmt.string(from: e.date)) ----\n"
                lastSessionKey = key
            }
            let type = PatientWalkingModel.groundTruthLabel(for: e.source)
            var fields = [csvEscape(e.source ?? ""), type, dateFmt.string(from: e.date), String(format: "%.4f", e.speed)]
            fields.append(contentsOf: e.features.map { String(format: "%.6f", $0) })
            out += fields.joined(separator: ",") + "\n"
        }

        guard let data = out.data(using: .utf8) else { return nil }
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("all_training_sessions_\(filenameFmt.string(from: Date())).csv")
        do {
            try data.write(to: outURL, options: .atomic)
            return outURL
        } catch {
            return nil
        }
    }

    // MARK: - CSV builders

    private static func csvEscape(_ s: String) -> String {
        guard s.contains(",") || s.contains("\"") || s.contains("\n") else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func readmeText() -> String {
        let m = WalkingModelStore.shared.model
        let trainedLine = m.trainedAt.map { ", last fit \(dateFmt.string(from: $0))" } ?? ""
        return """
        POMS full data export
        Generated \(dateFmt.string(from: Date()))

        Contents:
          training_examples.csv     Every GPS-labelled 5-second walking segment used
                                     to train this patient's swing-based speed model.
                                     One row per segment: its 48 pca-acc features and
                                     the GPS speed (m/s) it was labelled with.
          model_summary.csv         The model's calibration state: fit or not, how
                                     many segments it was trained on, when it was
                                     last refit, and its fitted bias (intercept).
          model_feature_weights.csv The fitted ridge-regression weight for each
                                     feature, plus the mean/std used to standardise
                                     it before fitting. Empty until fit at least once.
          feature_legend.csv        Plain-language description of all 48 features.
          sensor_logs/*.csv         The same per-day raw sensor logs shown in the
                                     app's History tab (timestamp, gravity-removed
                                     accel, gyro, heart rate, GPS, IMU/sender rate),
                                     one file per day of data on this device.

        Model status at export time: \(m.isCalibrated ? "calibrated" : "not yet calibrated"), \
        trained on \(m.trainingCount) segment\(m.trainingCount == 1 ? "" : "s")\(trainedLine).

        This data comes from a research prototype, not a validated clinical device.
        The walking-speed method is adapted from Zihajehzadeh & Park (2016, PLoS
        ONE), "Regression Model-Based Walking Speed Estimation Using Wrist-Worn
        Inertial Sensor" — see that estimator's source comments for the method
        and its documented limitations.
        """
    }

    private static func trainingExamplesCSV(_ examples: [PatientWalkingModel.Example]? = nil) -> String {
        let rows = examples ?? WalkingModelStore.shared.model.examples
        let names = WalkingSpeedEstimator.featureNames
        var out = (["index", "date", "speed_mps"] + names).joined(separator: ",") + "\n"
        for (i, e) in rows.enumerated() {
            var fields = [String(i + 1), dateFmt.string(from: e.date), String(format: "%.4f", e.speed)]
            fields.append(contentsOf: e.features.map { String(format: "%.6f", $0) })
            out += fields.joined(separator: ",") + "\n"
        }
        return out
    }

    private static func modelSummaryCSV() -> String {
        let m = WalkingModelStore.shared.model
        let rows: [(String, String)] = [
            ("isCalibrated", m.isCalibrated ? "true" : "false"),
            ("trainingCount", "\(m.trainingCount)"),
            ("trainedAt", m.trainedAt.map { dateFmt.string(from: $0) } ?? ""),
            ("bias_mps", String(format: "%.6f", m.bias)),
            ("ridgeLambda", "\(PatientWalkingModel.ridgeLambda)"),
            ("minExamplesToTrust", "\(PatientWalkingModel.minExamplesToTrust)"),
            ("maxExamples", "\(PatientWalkingModel.maxExamples)"),
            ("featureCount", "\(WalkingSpeedEstimator.featureCount)"),
            ("exportedAt", dateFmt.string(from: Date())),
        ]
        var out = "key,value\n"
        for (k, v) in rows { out += "\(k),\(csvEscape(v))\n" }
        return out
    }

    private static func modelWeightsCSV() -> String {
        let m = WalkingModelStore.shared.model
        let names = WalkingSpeedEstimator.featureNames
        var out = "index,name,weight,mean,std\n"
        guard m.weights.count == names.count,
              m.featureMean.count == names.count,
              m.featureStd.count == names.count
        else { return out }   // not fit yet — header only, still a valid CSV

        for i in 0..<names.count {
            out += "\(i + 1),\(names[i])," +
                   "\(String(format: "%.6f", m.weights[i]))," +
                   "\(String(format: "%.6f", m.featureMean[i]))," +
                   "\(String(format: "%.6f", m.featureStd[i]))\n"
        }
        return out
    }

    private static func featureLegendCSV() -> String {
        let tdDescriptions: [String: String] = [
            "mean": "Mean of the pca-acc signal over the 5-second window",
            "sd": "Standard deviation of the pca-acc signal",
            "median": "Median of the pca-acc signal",
            "mode": "Most frequent value of the pca-acc signal (32-bin histogram)",
            "meanAbs": "Mean absolute value of the pca-acc signal",
            "crossings": "Number of times the signal crosses its own mean",
            "sma": "Signal magnitude area — sum of |pca-acc| over the window",
            "energy": "Sum of squared pca-acc values over the window",
        ]
        let names = WalkingSpeedEstimator.featureNames
        var out = "index,name,category,description\n"
        for (i, name) in names.enumerated() {
            let idx = i + 1
            if let td = tdDescriptions[name] {
                out += "\(idx),\(name),time-domain,\(csvEscape(td))\n"
            } else {
                // Frequency-domain: bin index within the FFT, plus the
                // approximate frequency it corresponds to given the
                // estimator's fixed 50Hz resample rate and 512-point FFT.
                let bin = i - WalkingSpeedEstimator.tdCoeffCount
                let hz = Double(bin) * WalkingSpeedEstimator.resampleHz / Double(WalkingSpeedEstimator.fftSize)
                let desc = "FFT amplitude at ~\(String(format: "%.2f", hz)) Hz (bin \(bin))"
                out += "\(idx),\(name),frequency-domain,\(csvEscape(desc))\n"
            }
        }
        return out
    }
}
