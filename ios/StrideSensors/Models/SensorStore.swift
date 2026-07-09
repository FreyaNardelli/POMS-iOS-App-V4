import Foundation
import Combine
import simd

/// The single source of truth for incoming sensor data.
///
/// - `latest` and the published counters are safe to observe from SwiftUI.
/// - `history` is a rolling buffer (newest at the end) for any calculation you
///   want to run later. Read it through `snapshot()` / `recent(_:)`, which are
///   thread-safe.
/// - Attach `onSample` to run your own formula on every packet as it arrives.
///
/// Access it anywhere with `SensorStore.shared`.
final class SensorStore: ObservableObject {

    static let shared = SensorStore()

    // MARK: Published (main-thread) state
    @Published private(set) var latest: SensorSample?
    @Published private(set) var packetsPerSecond: Double = 0
    @Published private(set) var totalPackets: Int = 0

    // MARK: History
    private(set) var history: [SensorSample] = []
    let maxHistory = 6000        // ~2 min at 50 Hz

    /// Optional consumer for custom, real-time calculations. Called on the
    /// receiver's background queue for every parsed sample.
    var onSample: ((SensorSample) -> Void)?

    private var arrivals: [Date] = []          // for packets/sec
    private let lock = NSLock()

    // MARK: Ingest (called from UDPReceiver.onData, background queue)

    func ingest(_ data: Data, receivedAt: Date) {
        guard let sample = SensorPacketParser.parse(data, receivedAt: receivedAt) else {
            return   // malformed / unknown format — ignored
        }

        lock.lock()
        history.append(sample)
        if history.count > maxHistory {
            history.removeFirst(history.count - maxHistory)
        }
        arrivals.append(receivedAt)
        arrivals.removeAll { receivedAt.timeIntervalSince($0) > 1.0 }
        let pps = Double(arrivals.count)
        let total = totalPackets + 1
        lock.unlock()

        DispatchQueue.main.async {
            self.latest = sample
            self.packetsPerSecond = pps
            self.totalPackets = total
        }

        SensorLogStore.shared.record(sample, receivedAt: receivedAt)   // persist to daily CSV
        onSample?(sample)
    }

    // MARK: Thread-safe reads for formulas

    /// Full history snapshot (copy), newest last.
    func snapshot() -> [SensorSample] {
        lock.lock(); defer { lock.unlock() }
        return history
    }

    /// Samples received within the last `seconds`.
    func recent(_ seconds: TimeInterval) -> [SensorSample] {
        let cutoff = Date().addingTimeInterval(-seconds)
        lock.lock(); defer { lock.unlock() }
        return history.filter { $0.receivedAt >= cutoff }
    }

    /// The last `count` samples (or fewer).
    func lastN(_ count: Int) -> [SensorSample] {
        lock.lock(); defer { lock.unlock() }
        return Array(history.suffix(count))
    }

    func clear() {
        lock.lock()
        history.removeAll()
        arrivals.removeAll()
        lock.unlock()
        DispatchQueue.main.async {
            self.latest = nil
            self.packetsPerSecond = 0
            self.totalPackets = 0
        }
    }

    // MARK: Example derived metrics (illustrative — extend freely)

    /// Effective sample rate over the last second (Hz).
    var sampleRateHz: Double { packetsPerSecond }

    /// Mean acceleration magnitude over a window (g).
    func meanAccelMagnitude(seconds: TimeInterval = 5) -> Double {
        let w = recent(seconds)
        guard !w.isEmpty else { return 0 }
        return w.reduce(0) { $0 + $1.accelMagnitude } / Double(w.count)
    }

    /// RMS angular velocity over a window.
    func gyroRMS(seconds: TimeInterval = 5) -> Double {
        let w = recent(seconds)
        guard !w.isEmpty else { return 0 }
        let sumSq = w.reduce(0.0) { $0 + $1.gyroMagnitude * $1.gyroMagnitude }
        return (sumSq / Double(w.count)).squareRoot()
    }

    /// Most recent non-nil heart rate.
    var currentHeartRate: Double? {
        lock.lock(); defer { lock.unlock() }
        return history.reversed().first(where: { $0.heartRate != nil })?.heartRate
    }
}
