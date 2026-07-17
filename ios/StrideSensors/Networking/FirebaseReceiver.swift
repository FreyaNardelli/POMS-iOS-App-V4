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
        // below handles both Double and NSNumber transparently.
        guard
            let ts  = number(dict["timestamp"]),
            let ax  = number(dict["accelX"]),
            let ay  = number(dict["accelY"]),
            let az  = number(dict["accelZ"]),
            let gx  = number(dict["gyroX"]),
            let gy  = number(dict["gyroY"]),
            let gz  = number(dict["gyroZ"]),
            let hr  = number(dict["heartRate"])
            let lat  = number(dict["latitude"])
            let long = number(dict["longitude"])
            let imufs  = number(dict["imuRateHz"])
            let sendfs = number(dict["sendRateHz"])        
        else { return }

        // Re-encode as the JSON array format the existing SensorPacketParser
        // already handles: [timestamp, ax, ay, az, gx, gy, gz, hr].
        // No new parsing logic needed — the watch and iPhone already agree on
        // this layout for UDP; we just route it through the same path here.
        let payload = "[\(ts),\(ax),\(ay),\(az),\(gx),\(gy),\(gz),\(hr),\(lat),\(long),\(imufs),\(sendfs)]"
        guard let data = payload.data(using: .utf8) else { return }

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
