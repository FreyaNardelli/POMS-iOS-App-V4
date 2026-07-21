import Foundation
import simd

/// Wrist-worn walking-speed estimation, adapted from:
///
///   Zihajehzadeh & Park (2016), "Regression Model-Based Walking Speed
///   Estimation Using Wrist-Worn Inertial Sensor", PLoS ONE 11(10):e0165211.
///
/// The paper's core idea is the **pca-acc** variable: gravity is removed from
/// the wrist accelerometer to get *external* (linear) acceleration, and PCA is
/// applied to its two horizontal components to find the principal axis of
/// arm-swing motion. Projecting onto that axis yields a *direction-independent*
/// scalar (`pca-acc`) whose time- and frequency-domain features map to walking
/// speed through a regression model.
///
/// ── What is faithful to the paper ───────────────────────────────────────────
///  • pca-acc: gravity removal → horizontal external accel → per-window PCA →
///    projection onto the first principal component.
///  • Feature set: 8 time-domain features + the first 40 FFT amplitude
///    coefficients of pca-acc, computed on 5-second epochs (paper §"Feature
///    Extraction"). The paper showed the FD features carry most of the pca-acc
///    signal (removing them drove error from 5.9% → 15.6%), so they are kept.
///  • Regression maps features → speed; distance is the speed integrated over
///    the test. See `PatientWalkingModel`.
///
/// ── Where this DEPARTS from the paper (and why) ─────────────────────────────
///  1. **No magnetometer.** The watch packet carries accel + gyro only, so the
///     paper's Kalman AHRS (accel+gyro+mag) can't be reproduced. We instead take
///     the gravity direction from a low-pass of raw accel. This costs us *yaw*
///     (absolute heading) — but pca-acc never needs heading: PCA resolves the
///     swing axis within the horizontal plane regardless of how that plane is
///     spun. Only roll/pitch (available from accel) are required.
///  2. **Lower sample rate.** The paper sampled at 100 Hz; the watch streams
///     ~10–50 Hz. Each epoch is linearly resampled to a fixed 50 Hz before the
///     FFT so features are comparable across patients and tests, and the
///     low-pass cutoff is capped below Nyquist. Arm-swing (~0.5–2 Hz) sits well
///     inside 50 Hz, so this is safe.
///  3. **Regression is fitted per patient from GPS** (see `PatientWalkingModel`)
///     rather than from a lab reference, because this population's slow/irregular
///     gait falls outside the paper's healthy-adult training domain — the paper
///     itself found subject-specific models necessary below 100 cm/s.
///
/// This type is pure computation. It holds no state and does no I/O.

extension WalkingSpeedEstimator {

    /// One manually-tapped distance mark: cumulative distance at a known
    /// instant, from a person tapping a "Mark" button each time they
    /// physically pass a pre-measured point (e.g. every 1m of taped-down
    /// floor markings). An alternative, potentially higher-precision ground
    /// truth than GPS.
    struct ManualMark {
        let t: Double                    // seconds — SAME clock as Reading.t
        let cumulativeDistance: Double   // metres, running total as of this tap
    }

    /// Overlays manually-marked distance as each epoch's speed label.
    /// Builds a piecewise-linear cumulative-distance-vs-time curve from the
    /// marks (constant speed between consecutive taps), then for each epoch
    /// takes (interpolated distance at epoch end − at epoch start) / epoch
    /// duration. An epoch entirely outside the marked time span gets no
    /// label (nil) — nothing to interpolate from.
    static func assignManualSpeeds(_ epochs: [Epoch], marks: [ManualMark]) -> [Epoch] {
        guard marks.count >= 2 else { return epochs }
        let sorted = marks.sorted { $0.t < $1.t }
        let times = sorted.map { $0.t }
        let dists = sorted.map { $0.cumulativeDistance }

        func interpolate(_ t: Double) -> Double? {
            guard let first = times.first, let last = times.last, t >= first, t <= last else { return nil }
            var j = 0
            while j < times.count - 2 && times[j + 1] < t { j += 1 }
            let t0 = times[j], t1 = times[j + 1]
            let d0 = dists[j], d1 = dists[j + 1]
            guard t1 > t0 else { return d0 }
            let frac = (t - t0) / (t1 - t0)
            return d0 + (d1 - d0) * frac
        }

        return epochs.map { e in
            guard let dStart = interpolate(e.startT), let dEnd = interpolate(e.startT + e.duration) else {
                return e
            }
            return Epoch(startT: e.startT, duration: e.duration, features: e.features,
                        gpsSpeed: e.gpsSpeed, manualSpeed: (dEnd - dStart) / e.duration)
        }
    }
}

enum WalkingSpeedEstimator {

    /// A single ingested reading, already reduced to what the estimator needs.
    /// `ext` is the gravity-removed (external / linear) acceleration in the
    /// sensor frame, `gravityDir` is the unit gravity vector at that instant
    /// (used per-epoch to define the horizontal plane), and lat/long are the
    /// live GPS fix if one was available.
    struct Reading {
        let t: Double                 // seconds
        let ext: SIMD3<Double>        // external accel, m/s², sensor frame
        let gravityDir: SIMD3<Double> // unit gravity direction, sensor frame
        let lat: Double?
        let long: Double?
    }

struct Epoch {
        let startT: Double
        let duration: Double          // seconds
        let features: [Double]        // 48-dim: 8 TD + 40 FD
        let gpsSpeed: Double?         // m/s ground truth, if GPS covered this epoch
        let manualSpeed: Double?      // m/s ground truth from tape-measure marks, if any

        init(startT: Double, duration: Double, features: [Double],
             gpsSpeed: Double?, manualSpeed: Double? = nil) {
            self.startT = startT
            self.duration = duration
            self.features = features
            self.gpsSpeed = gpsSpeed
            self.manualSpeed = manualSpeed
        }

        /// The label actually used for training — manual marks are treated
        /// as authoritative when present ("absolute accurate dataset"),
        /// falling back to GPS otherwise.
        var trainingSpeed: Double? { manualSpeed ?? gpsSpeed }
    }

    /// Result of running the estimator over a whole test.
    struct Analysis {
        let epochs: [Epoch]
        let gpsDistanceMeters: Double?   // total GPS path length over the test
        let durationSeconds: Double
        let sampleRateHz: Double
    }

    // Tunables (kept here so they're easy to find and justify).
    static let epochSeconds: Double = 5.0        // paper's window
    static let resampleHz: Double = 50.0         // fixed rate for FFT/feature parity
    static let fftSize = 512                     // paper's 512-point FFT
    static let fdCoeffCount = 40                 // paper's first 40 amplitude coeffs
    static let tdCoeffCount = 8                  // paper's 8 time-domain features
    static var featureCount: Int { tdCoeffCount + fdCoeffCount }   // 48

    /// Human-readable names for each of the 48 features, in the exact order
    /// `Epoch.features` lists them — `timeDomainFeatures` then
    /// `frequencyDomainFeatures`, concatenated in `makeEpoch` as `td + fd`.
    /// Used by `DataExportManager` so exported CSVs have real column headers
    /// (`mean`, `fft_amp_03`, …) instead of `feature_1`..`feature_48`.
    static let featureNames: [String] = {
        let td = ["mean", "sd", "median", "mode", "meanAbs", "crossings", "sma", "energy"]
        let fd = (0..<fdCoeffCount).map { "fft_amp_\(String(format: "%02d", $0))" }
        return td + fd
    }()

    // Minimum GPS movement within an epoch to trust it as a training label.
    static let minEpochGPSDistance: Double = 1.0   // metres

    // MARK: - Public entry point

    /// Splits the readings into 5-s epochs and computes pca-acc features for
    /// each, plus per-epoch and total GPS ground truth where available.
    static func analyze(_ readings: [Reading]) -> Analysis {
        guard readings.count >= 2 else {
            return Analysis(epochs: [], gpsDistanceMeters: nil, durationSeconds: 0, sampleRateHz: 0)
        }

        let t0 = readings.first!.t
        let tEnd = readings.last!.t
        let duration = max(0, tEnd - t0)
        let fs = duration > 0 ? Double(readings.count - 1) / duration : 0

        // Bucket readings into consecutive 5-s epochs.
        var epochs: [Epoch] = []
        var bucket: [Reading] = []
        var epochStart = t0

        func flush() {
            guard bucket.count >= 4 else { bucket.removeAll(keepingCapacity: true); return }
            if let e = makeEpoch(bucket, startT: epochStart) { epochs.append(e) }
            bucket.removeAll(keepingCapacity: true)
        }

        for r in readings {
            if r.t - epochStart >= epochSeconds && !bucket.isEmpty {
                flush()
                // advance epochStart in whole steps so we don't accumulate drift
                while r.t - epochStart >= epochSeconds { epochStart += epochSeconds }
            }
            bucket.append(r)
        }
        flush()

        let gpsDist = totalGPSDistance(readings)
        return Analysis(epochs: epochs,
                        gpsDistanceMeters: gpsDist,
                        durationSeconds: duration,
                        sampleRateHz: fs)
    }

    // MARK: - Epoch → pca-acc → features

    private static func makeEpoch(_ readings: [Reading], startT: Double) -> Epoch? {
        guard readings.count >= 4 else { return nil }
        let dur = max(readings.last!.t - readings.first!.t, 1e-3)

        // 1) One horizontal frame for the whole epoch: mean gravity direction.
        var g = SIMD3<Double>(repeating: 0)
        for r in readings { g += r.gravityDir }
        let gLen = simd_length(g)
        guard gLen > 1e-6 else { return nil }
        let up = g / gLen

        // Build any orthonormal basis (h1, h2) spanning the plane ⊥ up. The
        // in-plane heading is arbitrary — PCA below is invariant to it.
        let seed = abs(up.x) < 0.9 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0)
        var h1 = seed - up * simd_dot(seed, up)
        h1 = simd_normalize(h1)
        let h2 = simd_cross(up, h1)   // already unit length (up, h1 orthonormal)

        // 2) Project external accel onto the horizontal plane → 2-D series.
        var px: [Double] = []
        var py: [Double] = []
        px.reserveCapacity(readings.count)
        py.reserveCapacity(readings.count)
        for r in readings {
            px.append(simd_dot(r.ext, h1))
            py.append(simd_dot(r.ext, h2))
        }

        // 3) PCA on the 2-D horizontal cloud → first principal component axis.
        let axis = principalAxis2D(px, py)

        // 4) pca-acc = projection of each horizontal sample onto that axis.
        var pca = [Double](repeating: 0, count: px.count)
        for i in 0..<px.count { pca[i] = px[i] * axis.0 + py[i] * axis.1 }

        // 5) Resample to a fixed rate, low-pass, then extract features.
        let n = max(2, Int((dur * resampleHz).rounded()))
        let ts = readings.map { $0.t }
        var resampled = resampleUniform(times: ts, values: pca, count: n)

        let cutoff = min(20.0, 0.4 * resampleHz)      // paper used 20 Hz; keep < Nyquist
        resampled = butterworthLowPass(resampled, fs: resampleHz, cutoff: cutoff)

        let td = timeDomainFeatures(resampled)
        let fd = frequencyDomainFeatures(resampled)
        let features = td + fd

        let gps = epochGPSSpeed(readings)
        return Epoch(startT: startT, duration: dur, features: features, gpsSpeed: gps)
    }

    // MARK: - PCA (2-D closed form)

    /// Returns the unit eigenvector of the 2×2 covariance matrix with the
    /// larger eigenvalue — the direction of greatest acceleration variation.
    private static func principalAxis2D(_ x: [Double], _ y: [Double]) -> (Double, Double) {
        let n = Double(x.count)
        guard n > 1 else { return (1, 0) }
        let mx = x.reduce(0, +) / n
        let my = y.reduce(0, +) / n
        var cxx = 0.0, cyy = 0.0, cxy = 0.0
        for i in 0..<x.count {
            let dx = x[i] - mx, dy = y[i] - my
            cxx += dx * dx; cyy += dy * dy; cxy += dx * dy
        }
        cxx /= (n - 1); cyy /= (n - 1); cxy /= (n - 1)

        // Eigen-decomposition of [[cxx, cxy], [cxy, cyy]].
        let tr = cxx + cyy
        let det = cxx * cyy - cxy * cxy
        let disc = max(0, tr * tr / 4 - det)
        let lambda = tr / 2 + disc.squareRoot()      // larger eigenvalue
        // Eigenvector for lambda.
        if abs(cxy) > 1e-12 {
            let vx = lambda - cyy
            let vy = cxy
            let len = (vx * vx + vy * vy).squareRoot()
            return len > 1e-12 ? (vx / len, vy / len) : (1, 0)
        } else {
            return cxx >= cyy ? (1, 0) : (0, 1)
        }
    }

    // MARK: - Resampling

    /// Linear-interpolate an irregularly-timed series onto `count` uniformly
    /// spaced samples spanning [times.first, times.last].
    private static func resampleUniform(times: [Double], values: [Double], count: Int) -> [Double] {
        guard times.count == values.count, times.count >= 2, count >= 2 else {
            return values
        }
        let t0 = times.first!, t1 = times.last!
        let span = max(t1 - t0, 1e-6)
        var out = [Double](repeating: 0, count: count)
        var j = 0
        for i in 0..<count {
            let t = t0 + span * Double(i) / Double(count - 1)
            while j < times.count - 2 && times[j + 1] < t { j += 1 }
            let ta = times[j], tb = times[j + 1]
            let frac = tb > ta ? (t - ta) / (tb - ta) : 0
            out[i] = values[j] + (values[j + 1] - values[j]) * min(max(frac, 0), 1)
        }
        return out
    }

    // MARK: - Butterworth low-pass (2nd-order biquad)

    /// One-pass 2nd-order Butterworth low-pass (RBJ cookbook coefficients),
    /// applied forward only. Good enough to knock out high-frequency noise
    /// above the arm-swing band before feature extraction.
    static func butterworthLowPass(_ x: [Double], fs: Double, cutoff: Double) -> [Double] {
        guard x.count > 2, fs > 0, cutoff > 0, cutoff < fs / 2 else { return x }
        let w0 = 2.0 * Double.pi * cutoff / fs
        let cosw = cos(w0), sinw = sin(w0)
        let q = 1.0 / 2.0.squareRoot()             // Butterworth Q
        let alpha = sinw / (2 * q)

        let b0 = (1 - cosw) / 2
        let b1 = 1 - cosw
        let b2 = (1 - cosw) / 2
        let a0 = 1 + alpha
        let a1 = -2 * cosw
        let a2 = 1 - alpha

        let nb0 = b0 / a0, nb1 = b1 / a0, nb2 = b2 / a0
        let na1 = a1 / a0, na2 = a2 / a0

        var y = [Double](repeating: 0, count: x.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for i in 0..<x.count {
            let xi = x[i]
            let yi = nb0 * xi + nb1 * x1 + nb2 * x2 - na1 * y1 - na2 * y2
            y[i] = yi
            x2 = x1; x1 = xi; y2 = y1; y1 = yi
        }
        return y
    }

    // MARK: - Time-domain features (8, per paper)

    static func timeDomainFeatures(_ x: [Double]) -> [Double] {
        let n = x.count
        guard n > 0 else { return [Double](repeating: 0, count: tdCoeffCount) }
        let nD = Double(n)
        let mean = x.reduce(0, +) / nD
        var sumsq = 0.0, sumabs = 0.0, energy = 0.0
        for v in x { let d = v - mean; sumsq += d * d; sumabs += abs(v); energy += v * v }
        let sd = (sumsq / nD).squareRoot()
        let meanAbs = sumabs / nD
        let sma = sumabs                              // signal magnitude area (Σ|x|)

        // median
        let sorted = x.sorted()
        let median = n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2

        // mode via a 32-bin histogram (continuous signal has no exact mode)
        let mode = histogramMode(sorted, bins: 32)

        // mean-crossing count
        var crossings = 0.0
        for i in 1..<max(n, 1) {
            if (x[i - 1] - mean) * (x[i] - mean) < 0 { crossings += 1 }
        }

        return [mean, sd, median, mode, meanAbs, crossings, sma, energy]
    }

    private static func histogramMode(_ sorted: [Double], bins: Int) -> Double {
        guard let lo = sorted.first, let hi = sorted.last, hi > lo else { return sorted.first ?? 0 }
        let width = (hi - lo) / Double(bins)
        var counts = [Int](repeating: 0, count: bins)
        for v in sorted {
            var idx = Int((v - lo) / width)
            if idx >= bins { idx = bins - 1 }
            if idx < 0 { idx = 0 }
            counts[idx] += 1
        }
        let best = counts.enumerated().max(by: { $0.element < $1.element })?.offset ?? 0
        return lo + (Double(best) + 0.5) * width      // bin centre
    }

    // MARK: - Frequency-domain features (first 40 amplitude coeffs, per paper)

    static func frequencyDomainFeatures(_ x: [Double]) -> [Double] {
        // Zero-mean, then zero-pad / truncate to fftSize.
        let n = x.count
        let mean = n > 0 ? x.reduce(0, +) / Double(n) : 0
        var re = [Double](repeating: 0, count: fftSize)
        var im = [Double](repeating: 0, count: fftSize)
        for i in 0..<min(n, fftSize) { re[i] = x[i] - mean }

        fftRadix2(&re, &im)

        var out = [Double](repeating: 0, count: fdCoeffCount)
        for k in 0..<fdCoeffCount {
            out[k] = (re[k] * re[k] + im[k] * im[k]).squareRoot() / Double(fftSize)
        }
        return out
    }

    /// In-place iterative radix-2 Cooley–Tukey FFT. `count` must be a power of
    /// two (fftSize = 512 is). Pure Swift so it needs no Accelerate setup.
    static func fftRadix2(_ re: inout [Double], _ im: inout [Double]) {
        let n = re.count
        guard n > 1, (n & (n - 1)) == 0 else { return }

        // Bit-reversal permutation.
        var j = 0
        for i in 1..<n {
            var bit = n >> 1
            while j & bit != 0 { j ^= bit; bit >>= 1 }
            j ^= bit
            if i < j { re.swapAt(i, j); im.swapAt(i, j) }
        }

        // Danielson–Lanczos.
        var len = 2
        while len <= n {
            let ang = -2.0 * Double.pi / Double(len)
            let wlenRe = cos(ang), wlenIm = sin(ang)
            var i = 0
            while i < n {
                var wRe = 1.0, wIm = 0.0
                for k in 0..<(len / 2) {
                    let uRe = re[i + k], uIm = im[i + k]
                    let vRe = re[i + k + len / 2] * wRe - im[i + k + len / 2] * wIm
                    let vIm = re[i + k + len / 2] * wIm + im[i + k + len / 2] * wRe
                    re[i + k] = uRe + vRe
                    im[i + k] = uIm + vIm
                    re[i + k + len / 2] = uRe - vRe
                    im[i + k + len / 2] = uIm - vIm
                    let nwRe = wRe * wlenRe - wIm * wlenIm
                    wIm = wRe * wlenIm + wIm * wlenRe
                    wRe = nwRe
                }
                i += len
            }
            len <<= 1
        }
    }

    // MARK: - GPS ground truth (Haversine)

    /// Great-circle distance between two lat/long points, metres.
    static func haversine(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let R = 6_371_000.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
              + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return R * 2 * atan2(a.squareRoot(), (1 - a).squareRoot())
    }

    /// Total GPS path length over a set of readings (nil if <2 fixes).
    static func totalGPSDistance(_ readings: [Reading]) -> Double? {
        var last: (Double, Double)? = nil
        var dist = 0.0
        var fixes = 0
        for r in readings {
            guard let la = r.lat, let lo = r.long else { continue }
            fixes += 1
            if let (pla, plo) = last { dist += haversine(pla, plo, la, lo) }
            last = (la, lo)
        }
        return fixes >= 2 ? dist : nil
    }

    /// GPS speed within one epoch (m/s), or nil if GPS didn't meaningfully
    /// cover it. Uses the fix span rather than summing noisy point-to-point
    /// hops, which over-estimates distance from GPS jitter when standing still.
    private static func epochGPSSpeed(_ readings: [Reading]) -> Double? {
        let fixes = readings.compactMap { r -> (Double, Double, Double)? in
            guard let la = r.lat, let lo = r.long else { return nil }
            return (r.t, la, lo)
        }
        guard let first = fixes.first, let last = fixes.last, fixes.count >= 2 else { return nil }
        // Sum the path so turns within the epoch aren't undercounted, but only
        // accept the epoch if net movement clears the jitter floor.
        var path = 0.0
        for i in 1..<fixes.count {
            path += haversine(fixes[i - 1].1, fixes[i - 1].2, fixes[i].1, fixes[i].2)
        }
        let dt = last.0 - first.0
        guard dt > 0.5, path >= minEpochGPSDistance else { return nil }
        return path / dt
    }
}
