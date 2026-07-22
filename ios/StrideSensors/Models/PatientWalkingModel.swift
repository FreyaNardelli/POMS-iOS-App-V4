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
        let duration: Double? = nil
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

    /// Fit ridge regression on the current buffer.
/// Fit ridge regression on the current buffer.
    mutating func fit() {
        let d = WalkingSpeedEstimator.featureCount
        let rows = examples.filter { $0.features.count == d }
        guard rows.count >= 2 else { return }

        // Standardise features.
        var mean = [Double](repeating: 0, count: d)
        var std = [Double](repeating: 0, count: d)
        let n = Double(rows.count)
        for r in rows { for j in 0..<d { mean[j] += r.features[j] } }
        for j in 0..<d { mean[j] /= n }
        for r in rows { for j in 0..<d { let dv = r.features[j] - mean[j]; std[j] += dv * dv } }
        for j in 0..<d { std[j] = max((std[j] / n).squareRoot(), 1e-8) }

        // Build standardised design matrix X and centred targets y.
        let yMean = rows.reduce(0) { $0 + $1.speed } / n
        var X = [[Double]](repeating: [Double](repeating: 0, count: d), count: rows.count)
        var y = [Double](repeating: 0, count: rows.count)
        for (i, r) in rows.enumerated() {
            for j in 0..<d { X[i][j] = (r.features[j] - mean[j]) / std[j] }
            y[i] = r.speed - yMean
        }

        // Normal equations: (XᵀX + λI) w = Xᵀy.
        var xtx = [[Double]](repeating: [Double](repeating: 0, count: d), count: d)
        var xty = [Double](repeating: 0, count: d)
        for i in 0..<rows.count {
            let xi = X[i]
            for a in 0..<d {
                let xia = xi[a]
                if xia == 0 { continue }
                xty[a] += xia * y[i]
                for b in a..<d { xtx[a][b] += xia * xi[b] }
            }
        }
        // Mirror upper→lower triangle and add ridge term.
        for a in 0..<d {
            for b in a..<d { xtx[b][a] = xtx[a][b] }
            xtx[a][a] += Self.ridgeLambda
        }

        guard let L = LinearAlgebra.cholesky(xtx) else { return }
        let w = LinearAlgebra.solveWithCholesky(L, xty)

        featureMean = mean
        featureStd = std
        weights = w
        bias = yMean
        trainedAt = Date()

        // Leave-one-out cross-validated error via the ridge hat-matrix
        // shortcut: e_i^loo = e_i / (1 - H_ii). Reuses L from the fit above,
        // so this is O(n·d²) rather than O(n·d³) from refitting n times.
        // NOTE: not numerically re-validated after this edit (see chat) --
        // worth a sanity check, especially near n ≈ d (48 features).
        var looResiduals = [Double](repeating: 0, count: rows.count)
        for i in 0..<rows.count {
            let xi = X[i]
            let v = LinearAlgebra.solveWithCholesky(L, xi)      // v = (XᵀX+λI)⁻¹xi
            var hii = 0.0
            for j in 0..<d { hii += xi[j] * v[j] }
            let yhat = yMean + zip(xi, w).reduce(0) { $0 + $1.0 * $1.1 }
            let resid = rows[i].speed - yhat
            let denom = max(1 - hii, 1e-6)   // guards a near-leverage-1 row
            looResiduals[i] = resid / denom
        }
        loocvSpeedRMSE = (looResiduals.reduce(0) { $0 + $1 * $1 } / Double(looResiduals.count)).squareRoot()
        loocvSpeedMAE = looResiduals.reduce(0) { $0 + abs($1) } / Double(looResiduals.count)
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
