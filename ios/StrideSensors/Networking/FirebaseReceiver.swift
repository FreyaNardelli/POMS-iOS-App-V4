import Foundation
import FirebaseDatabase

/// Cloud channel receiver for the dual-stream architecture.
///
/// The watch pushes sensor readings to Firebase Realtime Database at 2 Hz
/// alongside its existing UDP stream. This class listens to that Firebase
/// node and feeds readings into `SensorStore` — but **only when UDP has
/// been silent for longer than `udpFallbackDelay`** (default 2 seconds).
///
/// Result:
/// - Same WiFi as the watch → UDP drives everything at full 10 Hz.
/// - Different network / UDP dropped → Firebase kicks in automatically,
///   giving ~2 Hz updates from anywhere with an internet connection.
///
/// Usage (in `StrideSensorsApp.swift`):
/// ```swift
/// // On every UDP packet:
/// FirebaseReceiver.shared.noteUDPActivity()
///
/// // Once on launch:
/// FirebaseReceiver.shared.start()
/// ```
final class FirebaseReceiver {

    static let shared = FirebaseReceiver()

    /// Seconds of UDP silence required before Firebase samples are accepted.
    /// 2 s means the handoff is seamless — you won't even notice the switch.
    var udpFallbackDelay: TimeInterval = 2.0

    private var ref: DatabaseReference?
    private var handle: DatabaseHandle?
    private var lastUDPActivity: Date = .distantPast

    private init() {}

    // MARK: Lifecycle

    func start() {
        guard handle == nil else { return }   // idempotent

        ref = Database.database().reference(withPath: "sensorData/latest")

        handle = ref?.observe(.value, with: { [weak self] snapshot in
            self?.handleSnapshot(snapshot)
        }, withCancel: { error in
            print("[FirebaseReceiver] listener cancelled: \(error.localizedDescription)")
        })
    }

    func stop() {
        if let h = handle { ref?.removeObserver(withHandle: h) }
        handle = nil
        ref = nil
    }

    // MARK: UDP heartbeat

    /// Call this every time a UDP packet arrives so the fallback timer resets.
    /// Cheap — just writes a Date to a property.
    func noteUDPActivity() {
        lastUDPActivity = Date()
    }

    // MARK: Firebase snapshot handling

    private func handleSnapshot(_ snapshot: DataSnapshot) {
        // Don't compete with UDP — only accept Firebase data when UDP is silent.
        let silence = Date().timeIntervalSince(lastUDPActivity)
        guard silence > udpFallbackDelay else { return }

        guard let dict = snapshot.value as? [String: Any] else { return }

        // Pull each field. Firebase stores numbers as NSNumber; the helper
        // below handles both Double and NSNumber transparently. GPS and rate
        // fields are optional — a watch that hasn't acquired a fix yet, or
        // older firmware that doesn't report imu/send rates, should still
        // stream the rest of the packet, so they're read separately below
        // rather than folded into the required `guard`.
        guard
            let ts  = number(dict["timestamp"]),
            let ax  = number(dict["accelX"]),
            let ay  = number(dict["accelY"]),
            let az  = number(dict["accelZ"]),
            let gx  = number(dict["gyroX"]),
            let gy  = number(dict["gyroY"]),
            let gz  = number(dict["gyroZ"]),
            let hr  = number(dict["heartRate"])
        else { return }

        let lat    = number(dict["latitude"])
        let long   = number(dict["longitude"])
        let imufs  = number(dict["imuRateHz"])
        let sendfs = number(dict["sendRateHz"])

        // Re-encode as a named-key JSON object, which `SensorPacketParser`
        // already handles via its field-alias lookup. A named object (rather
        // than the positional array) is used here specifically because GPS
        // and rate fields are optional: omitting an absent key just leaves
        // that field `nil` downstream, with no risk of shifting the
        // positions of fields that come after it — which a placeholder
        // in a fixed-position array would risk.
        var obj: [String: Any] = [
            "t": ts, "ax": ax, "ay": ay, "az": az,
            "gx": gx, "gy": gy, "gz": gz, "hr": hr
        ]
        if let lat    { obj["lat"] = lat }
        if let long   { obj["long"] = long }
        if let imufs  { obj["imuRateHz"] = imufs }
        if let sendfs { obj["sendRateHz"] = sendfs }

        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }

        SensorStore.shared.ingest(data, receivedAt: Date())
    }

    // MARK: Helpers

    /// Safely extract a Double from Any, handling NSNumber (how Firebase
    /// delivers numbers in Swift) as well as native Double and Int.
    private func number(_ value: Any?) -> Double? {
        switch value {
        case let d as Double:   return d
        case let n as NSNumber: return n.doubleValue
        case let i as Int:      return Double(i)
        default:                return nil
        }
    }
}
