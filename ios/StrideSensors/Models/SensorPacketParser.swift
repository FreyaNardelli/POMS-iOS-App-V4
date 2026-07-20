import Foundation
import simd

/// Turns a raw UDP payload into a `SensorSample`.
///
/// **The Wear OS watch's current format** is a UTF-8 *text array* of 12
/// numbers:
/// ```
/// [1783483199425, 1.8148049, -2.2625206, 9.483433, 0.0586, -0.0073, -0.0269, 71.0, 37.3346, -122.0090, 50.0, 10.0]
///  └ timestamp ms   └────── accel x/y/z ──────┘ └────── gyro x/y/z ──────┘  hr    └── lat/long ───┘  imuHz sendHz
/// ```
/// i.e. `[t, ax, ay, az, gx, gy, gz, hr, lat, long, imuRateHz, sendRateHz]`.
/// This is valid JSON, so `parseJSON` handles it directly (see
/// `makeFromArray`). `parseDelimited` is a bracket-tolerant fallback for the
/// same numbers sent as plain CSV, and `parseBinary` remains for any
/// packed-float sender.
///
/// For backwards compatibility, shorter legacy frames are still accepted:
/// `[t, ax,ay,az, gx,gy,gz, hr]` (8) or `[ax,ay,az, gx,gy,gz, hr]` (7).
/// Any trailing fields beyond `hr` are read positionally as
/// `lat, long, imuRateHz, sendRateHz` and are simply absent (`nil`) if the
/// packet doesn't carry them.
///
/// A JSON *object* with named keys (`{"ax":…,"hr":88,"lat":…}`, aliases in
/// `Keys`) also works for testing.
enum SensorPacketParser {

    static func parse(_ data: Data, receivedAt: Date) -> SensorSample? {
        if let sample = parseJSON(data, receivedAt: receivedAt) { return sample }
        if let sample = parseDelimited(data, receivedAt: receivedAt) { return sample }
        if let sample = parseBinary(data, receivedAt: receivedAt) { return sample }
        return nil
    }

    /// Maps a bare numeric array to a sample.
    ///
    /// Current format (12 values, with timestamp): `[t, ax,ay,az, gx,gy,gz,
    /// hr, lat, long, imuRateHz, sendRateHz]`.
    ///
    /// Also accepts, for backwards compatibility:
    /// - 11 values (no timestamp): `[ax,ay,az, gx,gy,gz, hr, lat, long, imuRateHz, sendRateHz]`
    /// - 8 values (legacy, with timestamp): `[t, ax,ay,az, gx,gy,gz, hr]`
    /// - 7 values (legacy, no timestamp): `[ax,ay,az, gx,gy,gz, hr]`
    ///
    /// A leading timestamp is assumed whenever the count is even (8, 10, 12…)
    /// since every current/legacy format pairs "with timestamp" counts to
    /// even totals and "without" to odd — see the worked table in the doc
    /// comment above.
    private static func makeFromArray(_ nums: [Double], receivedAt: Date, raw: Data) -> SensorSample? {
        let hasTimestamp = nums.count >= 8 && nums.count % 2 == 0
        let core = hasTimestamp ? Array(nums.dropFirst()) : nums
        guard core.count >= 6 else { return nil }   // need at least accel + gyro

        var fields: [String: Double] = [
            "ax": core[0], "ay": core[1], "az": core[2],
            "gx": core[3], "gy": core[4], "gz": core[5]
        ]
        if core.count >= 7  { fields["hr"] = core[6] }
        if core.count >= 8  { fields["lat"] = core[7] }
        if core.count >= 9  { fields["long"] = core[8] }
        if core.count >= 10 { fields["imuRateHz"] = core[9] }
        if core.count >= 11 { fields["sendRateHz"] = core[10] }
        if hasTimestamp { fields["t"] = nums[0] }

        return make(from: fields, receivedAt: receivedAt, raw: raw)
    }

    // MARK: Binary (watch format)

    /// Decodes a packed float array `[ax, ay, az, gx, gy, gz, hr, lat, long,
    /// imuRateHz, sendRateHz]` (optionally preceded by a timestamp). Tries
    /// Float32/Float64 × big/little-endian and keeps whichever interpretation
    /// is most physically plausible, so it works regardless of how the
    /// Wear OS side set its `ByteBuffer` order.
    private static func parseBinary(_ data: Data, receivedAt: Date) -> SensorSample? {
        let bytes = [UInt8](data)
        let n = bytes.count

        // Accepted frame sizes: legacy 7/8 (no GPS/rates), current 11/12.
        let validCounts: Set<Int> = [7, 8, 11, 12]

        func decode(width: Int, big: Bool) -> [Double]? {
            guard n % width == 0 else { return nil }
            let count = n / width
            guard validCounts.contains(count) else { return nil }
            var out: [Double] = []
            out.reserveCapacity(count)
            for i in 0..<count {
                let s = i * width
                if width == 4 {
                    var bits: UInt32 = 0
                    for b in 0..<4 {
                        let byte = bytes[s + (big ? b : 3 - b)]
                        bits |= UInt32(byte) << (8 * (3 - b))
                    }
                    out.append(Double(Float(bitPattern: bits)))
                } else {
                    var bits: UInt64 = 0
                    for b in 0..<8 {
                        let byte = bytes[s + (big ? b : 7 - b)]
                        bits |= UInt64(byte) << (8 * (7 - b))
                    }
                    out.append(Double(bitPattern: bits))
                }
            }
            return out
        }

        // Higher score = more values in plausible sensor ranges. Scored
        // against the fixed-position accel/gyro/hr fields only — GPS and
        // rate fields (if present) are trusted positionally since their
        // plausible ranges overlap too much with other fields to score well.
        func score(_ vals: [Double]) -> Int {
            let hasTimestamp = vals.count == 8 || vals.count == 12
            let core = hasTimestamp ? Array(vals.dropFirst()) : vals
            guard core.count >= 7 else { return -1 }
            var s = 0
            for a in core[0...2] where a.isFinite && abs(a) <= 40 { s += 1 }     // accel (g or m/s²)
            for g in core[3...5] where g.isFinite && abs(g) <= 4000 { s += 1 }   // gyro (deg/s or rad/s)
            let hr = core[6]
            if hr.isFinite && hr >= 20 && hr <= 250 { s += 2 }
            return s
        }

        let candidates: [[Double]] = [
            decode(width: 4, big: true), decode(width: 4, big: false),
            decode(width: 8, big: true), decode(width: 8, big: false)
        ].compactMap { $0 }

        guard let best = candidates.max(by: { score($0) < score($1) }),
              score(best) >= 3 else { return nil }   // reject garbage / non-binary payloads

        let hasTimestamp = best.count == 8 || best.count == 12
        let core = hasTimestamp ? Array(best.dropFirst()) : best
        let ts = hasTimestamp ? normaliseTimestamp(best[0]) ?? receivedAt.timeIntervalSince1970
                               : receivedAt.timeIntervalSince1970
        let hr = core[6]
        var fields: [String: Double] = [
            "ax": core[0], "ay": core[1], "az": core[2],
            "gx": core[3], "gy": core[4], "gz": core[5], "hr": hr
        ]
        if core.count >= 8  { fields["lat"] = core[7] }
        if core.count >= 9  { fields["long"] = core[8] }
        if core.count >= 10 { fields["imuRateHz"] = core[9] }
        if hasTimestamp { fields["t"] = best[0] }

        return SensorSample(
            timestamp: ts,
            receivedAt: receivedAt,
            accel: SIMD3<Double>(core[0], core[1], core[2]),
            gyro: SIMD3<Double>(core[3], core[4], core[5]),
            heartRate: (hr >= 20 && hr <= 250) ? hr : nil,
            latitude: fields["lat"],
            longitude: fields["long"],
            imuRateHz: fields["imuRateHz"],
            sendRateHz: core.count >= 11 ? core[10] : nil,
            fields: fields,
            raw: data
        )
    }

    // MARK: JSON

    private static func parseJSON(_ data: Data, receivedAt: Date) -> SensorSample? {
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else { return nil }

        // The watch's `[t, ax, …, hr, lat, long, imuRateHz, sendRateHz]`
        // payload is a top-level JSON array.
        if let arr = obj as? [Any] {
            let nums = arr.compactMap { Self.double($0) }
            guard nums.count >= 6 else { return nil }
            return makeFromArray(nums, receivedAt: receivedAt, raw: data)
        }

        // A named-key object also works (testing / other senders).
        if let dict = obj as? [String: Any] {
            var fields: [String: Double] = [:]
            for (key, value) in dict {
                if let d = Self.double(value) { fields[key] = d }
            }
            guard !fields.isEmpty else { return nil }
            return make(from: fields, receivedAt: receivedAt, raw: data)
        }
        return nil
    }

    // MARK: Delimited

    private static func parseDelimited(_ data: Data, receivedAt: Date) -> SensorSample? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        // Strip brackets/braces so `[1783…, …, 71.0]` tokenises cleanly — this was
        // the bug that dropped the timestamp and trailing HR.
        let separators = CharacterSet(charactersIn: ", ;\t\n\r[](){}")
        let nums = text
            .components(separatedBy: separators)
            .compactMap { Double($0) }
        guard nums.count >= 6 else { return nil }   // need at least accel + gyro
        return makeFromArray(nums, receivedAt: receivedAt, raw: data)
    }

    // MARK: Assembly

    private static func make(from fields: [String: Double], receivedAt: Date, raw: Data) -> SensorSample {
        func first(_ aliases: [String]) -> Double? {
            for a in aliases { if let v = fields[a] { return v } }
            // case-insensitive fallback
            let lower = Dictionary(uniqueKeysWithValues: fields.map { ($0.key.lowercased(), $0.value) })
            for a in aliases { if let v = lower[a.lowercased()] { return v } }
            return nil
        }

        let ts = normaliseTimestamp(first(Keys.time)) ?? receivedAt.timeIntervalSince1970
        let accel = SIMD3<Double>(first(Keys.ax) ?? 0, first(Keys.ay) ?? 0, first(Keys.az) ?? 0)
        let gyro  = SIMD3<Double>(first(Keys.gx) ?? 0, first(Keys.gy) ?? 0, first(Keys.gz) ?? 0)
        let hr    = first(Keys.hr)
        let lat   = first(Keys.lat)
        let long  = first(Keys.long)
        let imuHz = first(Keys.imuRateHz)
        let sendHz = first(Keys.sendRateHz)

        return SensorSample(
            timestamp: ts,
            receivedAt: receivedAt,
            accel: accel,
            gyro: gyro,
            heartRate: hr,
            latitude: lat,
            longitude: long,
            imuRateHz: imuHz,
            sendRateHz: sendHz,
            fields: fields,
            raw: raw
        )
    }

    /// Accept seconds or milliseconds; anything absurdly large is treated as ms.
    private static func normaliseTimestamp(_ value: Double?) -> TimeInterval? {
        guard let value else { return nil }
        return value > 1_000_000_000_000 ? value / 1000.0 : value
    }

    private static func double(_ any: Any) -> Double? {
        switch any {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    // MARK: Field aliases
    private enum Keys {
        static let time = ["t", "ts", "time", "timestamp"]
        static let ax = ["ax", "accx", "accelX", "acc_x", "accelerationX"]
        static let ay = ["ay", "accy", "accelY", "acc_y", "accelerationY"]
        static let az = ["az", "accz", "accelZ", "acc_z", "accelerationZ"]
        static let gx = ["gx", "gyrx", "gyroX", "gyro_x", "rotationX"]
        static let gy = ["gy", "gyry", "gyroY", "gyro_y", "rotationY"]
        static let gz = ["gz", "gyrz", "gyroZ", "gyro_z", "rotationZ"]
        static let hr = ["hr", "bpm", "heart", "heartRate", "heart_rate"]
        static let lat = ["lat", "latitude"]
        static let long = ["long", "lng", "lon", "longitude"]
        static let imuRateHz = ["imuRateHz", "imuRate", "imu_rate_hz", "imuHz"]
        static let sendRateHz = ["sendRateHz", "sendRate", "send_rate_hz", "sendHz"]
    }
}
