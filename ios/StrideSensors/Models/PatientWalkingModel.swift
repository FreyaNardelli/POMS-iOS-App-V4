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

    /// A stored training example: one epoch's features and its GPS speed label.
    struct Example: Codable {
        let features: [Double]
        let speed: Double            // m/s
        let date: Date
    }

    /// Standardisation + learned weights. `nil` until first successful fit.
    private(set) var featureMean: [Double] = []
    private(set) var featureStd: [Double] = []
    private(set) var weights: [Double] = []     // on standardised features
    private(set) var bias: Double = 0           // = mean(training speeds)
    private(set) var trainedAt: Date?

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
    mutating func addAndRetrain(epochs: [WalkingSpeedEstimator.Epoch], date: Date = Date()) {
        let labelled = epochs.compactMap { e -> Example? in
            guard let s = e.gpsSpeed, s.isFinite, s >= 0,
                  e.features.count == WalkingSpeedEstimator.featureCount else { return nil }
            return Example(features: e.features, speed: s, date: date)
        }
        guard !labelled.isEmpty else { return }

        examples.append(contentsOf: labelled)
        if examples.count > Self.maxExamples {
            examples.removeFirst(examples.count - Self.maxExamples)
        }
        fit()
    }

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

        guard let w = LinearAlgebra.solveSPD(xtx, xty) else { return }

        featureMean = mean
        featureStd = std
        weights = w
        bias = yMean
        trainedAt = Date()
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
    static func solveSPD(_ A: [[Double]], _ b: [Double]) -> [Double]? {
        let n = b.count
        guard A.count == n, A.allSatisfy({ $0.count == n }) else { return nil }

        // Cholesky: A = L Lᵀ.
        var L = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n {
            for j in 0...i {
                var sum = A[i][j]
                for k in 0..<j { sum -= L[i][k] * L[j][k] }
                if i == j {
                    if sum <= 0 { return nil }        // not positive-definite
                    L[i][j] = sum.squareRoot()
                } else {
                    L[i][j] = sum / L[j][j]
                }
            }
        }

        // Forward solve L z = b.
        var z = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var sum = b[i]
            for k in 0..<i { sum -= L[i][k] * z[k] }
            z[i] = sum / L[i][i]
        }
        // Back solve Lᵀ x = z.
        var x = [Double](repeating: 0, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            var sum = z[i]
            for k in (i + 1)..<n where k < n { sum -= L[k][i] * x[k] }
            x[i] = sum / L[i][i]
        }
        return x
    }
}
