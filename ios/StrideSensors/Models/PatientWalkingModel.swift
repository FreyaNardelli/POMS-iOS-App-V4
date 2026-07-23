import Foundation

/// Per-patient regression mapping pca-acc features → walking speed.
///
/// The paper compares two regressors: Gaussian Process Regression (its best
/// result, 5.9% MAE) and LSR-Lasso (a regularised linear baseline). We use a
/// **ridge** regression — the same regularised-linear family as LSR-Lasso, but
/// with a stable closed-form solution `(XᵀX + λI)⁻¹Xᵀy` that needs no iterative
/// solver and behaves well on-device with the 48-dimensional feature vector and
/// the modest number of epochs a single test provides. (GPR is the paper's
/// stronger model and a reasonable future upgrade; it's far heavier to run and
/// tune on a phone, and needs O(N³) inference.)
///
/// **Why per-patient, and why GPS-trained.** The paper explicitly found that a
/// *subject-specific* model was necessary for slow walking (<100 cm/s), where a
/// generalised model's error more than tripled. Pediatric-onset MS gait is
/// typically slow and irregular — squarely in that regime — so a single shared
/// model would be the wrong choice here. Each patient's model self-calibrates
/// from their own GPS-labelled walking: during any 6MWT with a GPS fix, the
/// per-epoch GPS speed supplies the training label for that epoch's features.
///
/// The whole thing is `Codable` and persisted by `WalkingModelStore` to the
/// app's Documents directory — this is the "file dedicated to storage of user
/// information" called for in the project spec.
struct PatientWalkingModel: Codable {

    /// A stored training example: one epoch's features and its speed label.
    struct Example: Codable {
        let features: [Double]
        let speed: Double            // m/s
        let date: Date
        /// Human-readable origin of this example, e.g. `"6MWT"`,
        /// `"Calibration walk"`, or `"Imported: track_test.csv"`. `nil` for
        /// examples recorded before this field existed — a plain `Optional`
        /// stored property decodes safely from old persisted files with no
        /// migration needed (Codable synthesis uses `decodeIfPresent` for
        /// any `Optional` property, so a missing key just becomes `nil`
        /// rather than throwing).
        let source: String?
        /// This epoch's actual duration in seconds (epochs are usually
        /// ~5s, but the last epoch of a test can be shorter). `nil` for
        /// examples recorded before this field existed; falls back to
        /// `WalkingSpeedEstimator.epochSeconds` wherever it's used.
        var duration: Double?
    }

    /// A logical batch of examples added together in one call — one 6MWT,
    /// one calibration walk, or one session within an imported file. Not
    /// stored explicitly: reconstructed by grouping `examples` on
    /// `(date, source)`, since every batch added in a single
    /// `addExamples`/`addAndRetrain` call already shares one `Date` (either
    /// `Date()` at capture time, or one imported session's own timestamp)
    /// and one `source` label. Used by the researcher view to show and
    /// delete whole sessions instead of 3000 individual feature rows.
    struct SessionGroup: Identifiable {
        let date: Date
        let source: String?
        /// Indices into `examples` *as of when this group was computed* —
        /// only valid until the next mutation, so callers should recompute
        /// `sessionGroups()` fresh after any add/delete rather than caching
        /// these across a mutation.
        let indices: [Int]
        var id: String { "\(date.timeIntervalSince1970)|\(source ?? "")" }
        var count: Int { indices.count }
    }

    /// Standardisation + learned weights. `nil` until first successful fit.
    private(set) var featureMean: [Double] = []
    private(set) var featureStd: [Double] = []
    private(set) var weights: [Double] = []     // on standardised features
    private(set) var bias: Double = 0           // = mean(training speeds)
    private(set) var trainedAt: Date?
    private(set) var loocvSpeedRMSE: Double? = nil   // m/s, leave-one-out cross-validated
    private(set) var loocvSpeedMAE: Double? = nil    // m/s, leave-one-out cross-validated    
    
    /// Rolling training buffer (capped) so refits can pool across tests.
    private(set) var examples: [Example] = []

    // Tunables.
    static let ridgeLambda = 5.0                 // regularisation strength
    static let maxExamples = 3000                // memory cap on the buffer
    static let minExamplesToTrust = 30           // below this → "calibrating"

    // Tunables for inverse-variance weighting between label sources. Not
    // empirically calibrated — see chat. preciseWeight/gpsWeight should
    // roughly equal (gpsError/preciseError)². The researcher view's
    // "measured vs. predicted" scatter is the tool to check whether this
    // ratio looks right in practice — these two lines are what to adjust.
    static let gpsWeight: Double = 1.0
    static let preciseWeight: Double = 16.0   // manual tape-measure / imported precise distance

    /// How much to trust an example's speed label, based on where it came
    /// from. Matches the exact `source` strings set at each collection
    /// point: "6MWT" and plain "Calibration walk" are GPS-derived;
    /// "Calibration walk (manual)" and "Imported: ..." are precise.
    static func precisionWeight(for source: String?) -> Double {
        guard let source else { return gpsWeight }
        if source.contains("(manual)") || source.contains("Imported:") { return preciseWeight }
        return gpsWeight
    }

    var isCalibrated: Bool {
        trainedAt != nil && examples.count >= Self.minExamplesToTrust && !weights.isEmpty
    }

    var trainingCount: Int { examples.count }

    // MARK: - Training

    /// Add GPS-labelled epochs from a completed test and refit. Epochs without
    /// a GPS speed are ignored for *training* (they can still be *predicted*).
    mutating func addAndRetrain(epochs: [WalkingSpeedEstimator.Epoch], date: Date = Date(),
                                source: String? = nil) {
        let labelled = epochs.compactMap { e -> Example? in
            guard let s = e.trainingSpeed, s.isFinite, s >= 0,
                  e.features.count == WalkingSpeedEstimator.featureCount else { return nil }
            return Example(features: e.features, speed: s, date: date, source: source, duration: e.duration)
        }
        addExamples(labelled)
    }

    /// Add already-labelled examples and refit — the path used for imported
    /// data, where the caller (e.g. `TrainingDataImporter`) has already
    /// computed each example's features and speed label from an externally
    /// supplied precise distance rather than GPS. Unlike `addAndRetrain`,
    /// this doesn't filter by GPS speed; the caller is responsible for
    /// having already validated `speed` is finite and non-negative.
    mutating func addExamples(_ new: [Example]) {
        guard !new.isEmpty else { return }
        examples.append(contentsOf: new)
        if examples.count > Self.maxExamples {
            examples.removeFirst(examples.count - Self.maxExamples)
        }
        fit()
    }

    /// Deletes examples at the given positions in `examples` and refits on
    /// whatever remains. If fewer than 2 examples remain, the fit is
    /// cleared entirely (see `clearFit()`) rather than leaving stale
    /// weights around that were partly trained on now-deleted data.
    mutating func removeExamples(at offsets: IndexSet) {
        examples.remove(atOffsets: offsets)
        if examples.count >= 2 {
            fit()
        } else {
            clearFit()
        }
    }

    /// Resets the fitted model (weights, standardisation, bias, trainedAt)
    /// without touching `examples` — used when a deletion drops the buffer
    /// below the minimum size `fit()` needs, so the model honestly reports
    /// "not calibrated" instead of continuing to serve predictions from
    /// weights that included data the researcher just removed.
    private mutating func clearFit() {
        featureMean = []; featureStd = []; weights = []; bias = 0; trainedAt = nil
    }

    /// Groups `examples` into the batches they were added in — one 6MWT, one
    /// calibration walk, or one session within an imported file — for the
    /// researcher view. See `SessionGroup` for why `(date, source)` is a
    /// reliable grouping key without storing session IDs explicitly.
    /// Newest first.
    func sessionGroups() -> [SessionGroup] {
        var buckets: [String: (date: Date, source: String?, indices: [Int])] = [:]
        for (i, e) in examples.enumerated() {
            let key = "\(e.date.timeIntervalSince1970)|\(e.source ?? "")"
            buckets[key, default: (e.date, e.source, [])].indices.append(i)
        }
        return buckets.values
            .map { SessionGroup(date: $0.date, source: $0.source, indices: $0.indices) }
            .sorted { $0.date > $1.date }
    }

    /// Total distance covered by a session, in metres — sum of each
    /// example's speed × duration. Falls back to
    /// `WalkingSpeedEstimator.epochSeconds` for examples recorded before
    /// `Example.duration` existed.
    func distanceCovered(by group: SessionGroup) -> Double {
        group.indices.reduce(0.0) { total, idx in
            guard idx < examples.count else { return total }
            let e = examples[idx]
            return total + e.speed * (e.duration ?? WalkingSpeedEstimator.epochSeconds)
        }
    }

    /// Every example vs. what the model (as CURRENTLY trained, including
    /// everything) would predict for it — the full "how well does the
    /// current model fit everything it's ever seen" picture.
    func allValidationPoints() -> [ValidationPoint] {
        examples.compactMap { e in
            predictSpeed(features: e.features).map { ValidationPoint(actual: e.speed, predicted: $0) }
        }
    }

    /// One session's examples vs. what the CURRENT model predicts for them
    /// — an in-sample look, useful for spotting outliers after the fact.
    /// Note: `group.indices` are only valid as of when `group` was computed
    /// — same staleness rule as `sessionGroups()` itself.
    func validationPoints(for group: SessionGroup) -> [ValidationPoint] {
        group.indices.compactMap { idx -> ValidationPoint? in
            guard idx < examples.count else { return nil }
            let e = examples[idx]
            return predictSpeed(features: e.features).map { ValidationPoint(actual: e.speed, predicted: $0) }
        }
    }

    /// Fit ridge regression on the current buffer.
    /// Fit ridge regression on the current buffer.
    mutating func fit() {
        let d = WalkingSpeedEstimator.featureCount
        let rows = examples.filter { $0.features.count == d }
        guard let result = Self.fitRidge(rows, featureCount: d) else { return }

        featureMean = result.featureMean
        featureStd = result.featureStd
        weights = result.weights
        bias = result.bias
        trainedAt = Date()

        let cv = Self.crossValidatedError(rows, featureCount: d)
        loocvSpeedRMSE = cv?.rmse
        loocvSpeedMAE = cv?.mae
    }

    /// Result of fitting ridge regression on some set of examples.
    private struct FitResult {
        let featureMean: [Double]
        let featureStd: [Double]
        let weights: [Double]
        let bias: Double
    }

    /// Fits weighted ridge regression on exactly the given rows. Used by
    /// BOTH the real `fit()` above and `crossValidatedError()` below, so
    /// there is exactly one implementation of "how to fit" — this is what
    /// closes the bug where a hand-derived cross-validation formula quietly
    /// stopped matching what the real (weighted) fit actually does.
    private static func fitRidge(_ rows: [Example], featureCount d: Int) -> FitResult? {
        guard rows.count >= 2 else { return nil }
        let n = Double(rows.count)

        var mean = [Double](repeating: 0, count: d)
        var std = [Double](repeating: 0, count: d)
        for r in rows { for j in 0..<d { mean[j] += r.features[j] } }
        for j in 0..<d { mean[j] /= n }
        for r in rows { for j in 0..<d { let dv = r.features[j] - mean[j]; std[j] += dv * dv } }
        for j in 0..<d { std[j] = max((std[j] / n).squareRoot(), 1e-8) }

        let exampleWeights = rows.map { Self.precisionWeight(for: $0.source) }
        let totalWeight = exampleWeights.reduce(0, +)
        let yMean = zip(rows, exampleWeights).reduce(0.0) { $0 + $1.0.speed * $1.1 } / totalWeight

        var X = [[Double]](repeating: [Double](repeating: 0, count: d), count: rows.count)
        var y = [Double](repeating: 0, count: rows.count)
        for (i, r) in rows.enumerated() {
            for j in 0..<d { X[i][j] = (r.features[j] - mean[j]) / std[j] }
            y[i] = r.speed - yMean
        }

        var xtx = [[Double]](repeating: [Double](repeating: 0, count: d), count: d)
        var xty = [Double](repeating: 0, count: d)
        for i in 0..<rows.count {
            let xi = X[i]
            let wi = exampleWeights[i]
            for a in 0..<d {
                let xia = xi[a]
                if xia == 0 { continue }
                xty[a] += wi * xia * y[i]
                for b in a..<d { xtx[a][b] += wi * xia * xi[b] }
            }
        }
        for a in 0..<d {
            for b in a..<d { xtx[b][a] = xtx[a][b] }
            xtx[a][a] += Self.ridgeLambda
        }

        guard let w = LinearAlgebra.solveSPD(xtx, xty) else { return nil }
        return FitResult(featureMean: mean, featureStd: std, weights: w, bias: yMean)
    }

    private static func predict(_ fr: FitResult, features: [Double]) -> Double? {
        guard fr.weights.count == features.count else { return nil }
        var acc = fr.bias
        for j in 0..<fr.weights.count {
            let z = (features[j] - fr.featureMean[j]) / fr.featureStd[j]
            acc += fr.weights[j] * z
        }
        return max(0, acc)
    }

    /// K-fold cross-validated speed error (m/s), via real refits on held-out
    /// folds — see the top of this file section in chat for why this
    /// replaced a closed-form leverage formula. True leave-one-out (k = n)
    /// when the buffer is small enough for that to be cheap (≤60 examples);
    /// a fixed 10-fold split above that, so cost stays bounded regardless
    /// of buffer size.
    private static func crossValidatedError(_ rows: [Example], featureCount d: Int) -> (rmse: Double, mae: Double)? {
        guard rows.count >= 4 else { return nil }

        let k = rows.count <= 60 ? rows.count : 10
        var foldOf = [Int](repeating: 0, count: rows.count)
        for i in 0..<rows.count { foldOf[i] = i % k }

        var residuals: [Double] = []
        residuals.reserveCapacity(rows.count)

        for fold in 0..<k {
            let trainRows = rows.enumerated().filter { foldOf[$0.offset] != fold }.map { $0.element }
            let testRows = rows.enumerated().filter { foldOf[$0.offset] == fold }.map { $0.element }
            guard let fr = fitRidge(trainRows, featureCount: d) else { continue }
            for r in testRows {
                guard let pred = predict(fr, features: r.features) else { continue }
                residuals.append(r.speed - pred)
            }
        }

        guard !residuals.isEmpty else { return nil }
        let rmse = (residuals.reduce(0) { $0 + $1 * $1 } / Double(residuals.count)).squareRoot()
        let mae = residuals.reduce(0) { $0 + abs($1) } / Double(residuals.count)
        return (rmse, mae)
    }

    // MARK: - Prediction

    /// Predicted speed (m/s, clamped ≥ 0) for one epoch's features, or nil if
    /// the model isn't fitted yet or the feature vector is malformed.
    func predictSpeed(features: [Double]) -> Double? {
        guard !weights.isEmpty, features.count == weights.count,
              featureMean.count == weights.count, featureStd.count == weights.count
        else { return nil }
        var acc = bias
        for j in 0..<weights.count {
            let z = (features[j] - featureMean[j]) / featureStd[j]
            acc += weights[j] * z
        }
        return max(0, acc)
    }
}

/// Minimal dense linear algebra — just enough to solve the ridge normal
/// equations. `solveSPD` uses Cholesky (the matrix is symmetric positive
/// definite once the ridge term is added), falling back to nil if the
/// factorisation fails.
enum LinearAlgebra {
    /// Cholesky factorization: returns L such that A = L·Lᵀ, or nil if A
    /// isn't symmetric positive definite.
    static func cholesky(_ A: [[Double]]) -> [[Double]]? {
        let n = A.count
        guard A.allSatisfy({ $0.count == n }) else { return nil }
        var L = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n {
            for j in 0...i {
                var sum = A[i][j]
                for k in 0..<j { sum -= L[i][k] * L[j][k] }
                if i == j {
                    if sum <= 0 { return nil }
                    L[i][j] = sum.squareRoot()
                } else {
                    L[i][j] = sum / L[j][j]
                }
            }
        }
        return L
    }

    /// Solve Ax = b given A's Cholesky factor L — reusable across many
    /// right-hand sides (e.g. once per training row, for leverage) without
    /// re-factoring A each time.
    static func solveWithCholesky(_ L: [[Double]], _ b: [Double]) -> [Double] {
        let n = b.count
        var z = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var sum = b[i]
            for k in 0..<i { sum -= L[i][k] * z[k] }
            z[i] = sum / L[i][i]
        }
        var x = [Double](repeating: 0, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            var sum = z[i]
            for k in (i + 1)..<n { sum -= L[k][i] * x[k] }
            x[i] = sum / L[i][i]
        }
        return x
    }

    static func solveSPD(_ A: [[Double]], _ b: [Double]) -> [Double]? {
        guard let L = cholesky(A) else { return nil }
        return solveWithCholesky(L, b)
    }
}
