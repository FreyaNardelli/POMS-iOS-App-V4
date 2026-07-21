import Foundation
import simd

/// Per-axis exponential low-pass gravity removal, factored out so live
/// capture (`WalkingModelStore.ingest`) and imported data
/// (`TrainingDataImporter`) run through **exactly the same algorithm**.
///
/// Why this matters: the pca-acc feature pipeline is sensitive to how
/// gravity is estimated and removed. If live-captured and imported data used
/// even slightly different gravity handling, the two sources would produce
/// systematically different features for physically identical motion — the
/// model would be learning a spurious "which pipeline was this from" signal
/// instead of a clean speed signal. Using one shared implementation makes
/// that impossible by construction rather than by careful duplication.
///
/// Same technique as `SensorStore.removeGravity`: track a slow-moving
/// per-axis estimate of the gravity vector and subtract it out, leaving
/// linear (external) acceleration plus a unit gravity direction.
struct GravityRemover {
    private var gravity = SIMD3<Double>(0, 0, 0)
    private var primed = false
    private let alpha: Double

    /// `alpha` closer to 1 = slower to adapt = more low-frequency content
    /// treated as gravity. Matches `SensorStore`/`WalkingModelStore`'s 0.9.
    init(alpha: Double = 0.9) {
        self.alpha = alpha
    }

    /// Feed one raw (gravity-included) accelerometer reading; returns the
    /// external (linear) acceleration and the current unit gravity direction.
    mutating func process(_ raw: SIMD3<Double>) -> (ext: SIMD3<Double>, gravityDir: SIMD3<Double>) {
        if primed {
            gravity = alpha * gravity + (1 - alpha) * raw
        } else {
            gravity = raw
            primed = true
        }
        let ext = raw - gravity
        let len = simd_length(gravity)
        let dir = len > 1e-6 ? gravity / len : SIMD3<Double>(0, 0, 1)
        return (ext, dir)
    }
}
