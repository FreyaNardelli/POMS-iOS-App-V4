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

    /// GPS latitude / longitude reported by the watch, degrees. `nil` until a
    /// fix has been acquired (or if the sender omits GPS entirely).
    let latitude: Double?
    let longitude: Double?

    /// Watch-reported IMU sampling rate (Hz) — how fast the watch itself is
    /// sampling the accelerometer/gyro, independent of how often it sends.
    let imuRateHz: Double?

    /// Watch-reported send rate (Hz) — how often packets are transmitted.
    let sendRateHz: Double?

    /// Every numeric field seen in the packet, keyed by its original name.
    /// Use this for calculations on fields not promoted to typed properties.
    let fields: [String: Double]

    /// The exact bytes received, for debugging / re-parsing.
    let raw: Data

    // Handy derived values for quick formulas.
    var accelMagnitude: Double { simd_length(accel) }
    var gyroMagnitude: Double { simd_length(gyro) }

    /// True once the watch has reported a plausible, non-zero GPS fix.
    /// (0, 0) is treated as "no fix" since that's the common placeholder for
    /// an unlocated reading, and out-of-range values are rejected too.
    var hasGPSFix: Bool {
        guard let lat = latitude, let lon = longitude else { return false }
        guard lat.isFinite, lon.isFinite else { return false }
        if lat == 0 && lon == 0 { return false }
        return abs(lat) <= 90 && abs(lon) <= 180
    }

    static func == (lhs: SensorSample, rhs: SensorSample) -> Bool { lhs.id == rhs.id }
}
