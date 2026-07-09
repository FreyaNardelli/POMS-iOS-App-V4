import Foundation
import simd

/// One reading from the watch. Everything a formula might need is here, and the
/// full set of raw numeric fields is preserved in `fields` so nothing is lost
/// even if the packet carries extra data we don't model yet.
struct SensorSample: Identifiable, Equatable {
    let id = UUID()

    /// Timestamp reported by the watch, in **seconds**. If the packet carried a
    /// millisecond value it is normalised to seconds. Falls back to `receivedAt`
    /// if the packet had no timestamp.
    let timestamp: TimeInterval

    /// When this app actually received the datagram (device clock).
    let receivedAt: Date

    /// Linear acceleration, g (x, y, z).
    let accel: SIMD3<Double>

    /// Angular velocity, deg/s or rad/s — whatever the sender uses (x, y, z).
    let gyro: SIMD3<Double>

    /// Heart rate, bpm. Optional because HR is sampled far less often than IMU.
    let heartRate: Double?

    /// Every numeric field seen in the packet, keyed by its original name.
    /// Use this for calculations on fields not promoted to typed properties.
    let fields: [String: Double]

    /// The exact bytes received, for debugging / re-parsing.
    let raw: Data

    // Handy derived values for quick formulas.
    var accelMagnitude: Double { simd_length(accel) }
    var gyroMagnitude: Double { simd_length(gyro) }

    static func == (lhs: SensorSample, rhs: SensorSample) -> Bool { lhs.id == rhs.id }
}
