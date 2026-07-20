import Foundation
import simd
import UIKit

/// Persists every sensor sample to a per-day CSV file in the app's Documents
/// directory, named `YYYY_MM_DD.csv`. Each daily file holds two tables with the
/// same columns:
///
///   `timestamp, accel.x, accel.y, accel.z (gravity removed), gyro.x, gyro.y,
///   gyro.z, heartbeat, Live GPS Lat, Live GPS Long, IMU Sampling Rate, Sender Rate`
///
///   • **[FREE-LIVING]** — every sample received that day.
///   • **[6MWT]** — samples captured during each 6-minute walk test, one
///     `# session N` block per test.
///
/// Accelerometer values are gravity-removed (linear acceleration) via a per-axis
/// low-pass gravity estimate; timestamps are epoch milliseconds (from the watch
/// packet when present, else the device receive time). Gyro is rad/s. GPS
/// lat/long are the live readings at the moment each sample arrived, and the
/// IMU/sender rates are the watch-reported values from the same packet.
///
/// Access anywhere with `SensorLogStore.shared`.
final class SensorLogStore: ObservableObject {

    static let shared = SensorLogStore()

    /// Column header — exactly as requested by the spec.
    static let columns = "timestamp,accel.x,accel.y,accel.z (gravity removed),gyro.x,gyro.y,gyro.z,heartbeat,Live GPS Lat,Live GPS Long,IMU Sampling Rate,Sender Rate"

    // MARK: Types

    struct Row {
        let t: Double            // epoch ms
        let ax, ay, az: Double   // gravity-removed, m/s²
        let gx, gy, gz: Double   // rad/s
        let hr: Double?          // bpm (optional)
        let lat: Double?         // live GPS latitude, degrees (optional — nil until fix)
        let long: Double?        // live GPS longitude, degrees (optional — nil until fix)
        let imuRateHz: Double?   // watch-reported IMU sampling rate, Hz (optional)
        let sendRateHz: Double?  // watch-reported send rate, Hz (optional)
    }

    struct Session: Identifiable {
        let id = UUID()
        let start: Date
        var rows: [Row]
    }

    struct DayLog {
        var day: String
        var freeLiving: [Row]
        var sessions: [Session]
    }

    // MARK: Published (main-thread) state
    @Published private(set) var todayFreeLivingCount = 0
    @Published private(set) var todaySessionCount = 0
    @Published private(set) var availableDays: [String] = []
    @Published private(set) var mwtActive = false

    // MARK: Private
    private var current: DayLog
    private var activeSession: Session?
    private let lock = NSLock()
    private var dirty = false
    private var persistTimer: Timer?
    private let softCap = 400_000             // keep memory bounded on very long days

    private let fm = FileManager.default

    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy_MM_dd"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    private static let isoFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()

    static func dayString(_ date: Date) -> String { dayFmt.string(from: date) }

    // MARK: Init

    private init() {
        current = DayLog(day: Self.dayString(Date()), freeLiving: [], sessions: [])
        createDirIfNeeded()
        if let loaded = try? Self.parse(url: Self.fileURL(for: current.day)) {
            current = loaded
        }
        todayFreeLivingCount = current.freeLiving.count
        todaySessionCount = current.sessions.count
        refreshAvailableDays()
        startPersistTimer()
        NotificationCenter.default.addObserver(
            self, selector: #selector(flushNow),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(flushNow),
            name: UIApplication.willResignActiveNotification, object: nil)
    }

    // MARK: Ingest (called from SensorStore.ingest, background queue)

    func record(_ sample: SensorSample, receivedAt: Date) {
        // sample.accel is already gravity-removed (linear acceleration) —
        // SensorStore.ingest strips gravity once, upstream, before anything
        // (this log, LiveSensorsView, WatchModel3DView) sees the sample.
        let lin = sample.accel
        let t = sample.fields["t"] ?? (receivedAt.timeIntervalSince1970 * 1000)

        lock.lock()

        // Day rollover — persist the finished day, start a fresh one.
        let today = Self.dayString(receivedAt)
        if today != current.day {
            writeToDisk_locked()
            current = DayLog(day: today, freeLiving: [], sessions: [])
        }

        let row = Row(t: t, ax: lin.x, ay: lin.y, az: lin.z,
                      gx: sample.gyro.x, gy: sample.gyro.y, gz: sample.gyro.z,
                      hr: sample.heartRate,
                      lat: sample.hasGPSFix ? sample.latitude : nil,
                      long: sample.hasGPSFix ? sample.longitude : nil,
                      imuRateHz: sample.imuRateHz,
                      sendRateHz: sample.sendRateHz)

        current.freeLiving.append(row)
        if current.freeLiving.count > softCap {
            current.freeLiving.removeFirst(current.freeLiving.count - softCap)
        }
        if activeSession != nil { activeSession!.rows.append(row) }
        dirty = true

        let fCount = current.freeLiving.count
        lock.unlock()

        DispatchQueue.main.async { self.todayFreeLivingCount = fCount }
    }

    // MARK: 6-minute walk session control

    func startMWTSession() {
        lock.lock()
        if let s = activeSession { current.sessions.append(s) }   // close any stragglers
        activeSession = Session(start: Date(), rows: [])
        lock.unlock()
        DispatchQueue.main.async { self.mwtActive = true }
    }

    func endMWTSession() {
        lock.lock()
        var closed = false
        if let s = activeSession, !s.rows.isEmpty {
            current.sessions.append(s)
            dirty = true
            closed = true
        }
        activeSession = nil
        let sCount = current.sessions.count
        lock.unlock()
        if closed { flushNow() }
        DispatchQueue.main.async {
            self.mwtActive = false
            self.todaySessionCount = sCount
        }
    }

    // MARK: History reads

    /// Parse a stored day for display. Returns an empty log if the file is gone.
    func loadDay(_ day: String) -> DayLog {
        // If it's the day we're actively logging, return the in-memory copy
        // (includes rows not yet flushed) with any in-progress session appended.
        lock.lock()
        if day == current.day {
            var copy = current
            if let s = activeSession, !s.rows.isEmpty { copy.sessions.append(s) }
            lock.unlock()
            return copy
        }
        lock.unlock()
        return (try? Self.parse(url: Self.fileURL(for: day)))
            ?? DayLog(day: day, freeLiving: [], sessions: [])
    }

    func fileURL(for day: String) -> URL { Self.fileURL(for: day) }

    func refreshAvailableDays() {
        let dir = Self.logsDir
        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        var days = names
            .filter { $0.hasSuffix(".csv") }
            .map { String($0.dropLast(4)) }
            .filter { $0.range(of: #"^\d{4}_\d{2}_\d{2}$"#, options: .regularExpression) != nil }
        let today = current.day
        if !days.contains(today) { days.append(today) }   // today may not be flushed yet
        days.sort(by: >)
        DispatchQueue.main.async { self.availableDays = days }
    }

    // MARK: Persistence

    private func startPersistTimer() {
        let t = Timer(timeInterval: 6, repeats: true) { [weak self] _ in self?.flushNow() }
        RunLoop.main.add(t, forMode: .common)
        persistTimer = t
    }

    @objc func flushNow() {
        lock.lock()
        guard dirty else { lock.unlock(); return }
        writeToDisk_locked()
        lock.unlock()
        refreshAvailableDays()
    }

    /// Caller must hold `lock`.
    private func writeToDisk_locked() {
        var sessions = current.sessions
        if let s = activeSession, !s.rows.isEmpty { sessions.append(s) }
        let text = Self.serialize(day: current.day, freeLiving: current.freeLiving, sessions: sessions)
        let url = Self.fileURL(for: current.day)
        try? text.data(using: .utf8)?.write(to: url, options: .atomic)
        dirty = false
    }

    private func createDirIfNeeded() {
        try? fm.createDirectory(at: Self.logsDir, withIntermediateDirectories: true)
    }

    // MARK: File paths

    static var logsDir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("SensorLogs", isDirectory: true)
    }
    static func fileURL(for day: String) -> URL {
        logsDir.appendingPathComponent("\(day).csv")
    }

    // MARK: Serialize / parse

    private static func fmtNum(_ d: Double) -> String { String(format: "%.6f", d) }
    private static func fmtTime(_ d: Double) -> String { String(format: "%.0f", d) }
    private static func fmtCoord(_ d: Double) -> String { String(format: "%.6f", d) }
    private static func rowLine(_ r: Row) -> String {
        "\(fmtTime(r.t)),\(fmtNum(r.ax)),\(fmtNum(r.ay)),\(fmtNum(r.az)),\(fmtNum(r.gx)),\(fmtNum(r.gy)),\(fmtNum(r.gz)),\(r.hr.map { fmtNum($0) } ?? ""),\(r.lat.map { fmtCoord($0) } ?? ""),\(r.long.map { fmtCoord($0) } ?? ""),\(r.imuRateHz.map { fmtNum($0) } ?? ""),\(r.sendRateHz.map { fmtNum($0) } ?? "")"
    }

    static func serialize(day: String, freeLiving: [Row], sessions: [Session]) -> String {
        var out = "# Stride sensor log — \(day)\n"
        out += "# timestamp = epoch ms | accel gravity-removed (linear), m/s² | gyro rad/s | heartbeat bpm\n\n"

        out += "[FREE-LIVING]\n\(columns)\n"
        for r in freeLiving { out += rowLine(r) + "\n" }

        out += "\n[6MWT]\n\(columns)\n"
        for (i, s) in sessions.enumerated() {
            out += "# session \(i + 1) — started \(isoFmt.string(from: s.start))\n"
            for r in s.rows { out += rowLine(r) + "\n" }
        }
        return out
    }

    static func parse(url: URL) throws -> DayLog {
        let text = try String(contentsOf: url, encoding: .utf8)
        let day = url.deletingPathExtension().lastPathComponent
        var freeLiving: [Row] = []
        var sessions: [Session] = []

        enum Section { case none, free, mwt }
        var section: Section = .none
        var curStart = Date()
        var curRows: [Row] = []
        var inSession = false

        func closeSession() {
            if inSession { sessions.append(Session(start: curStart, rows: curRows)) }
            curRows = []; inSession = false
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line == "[FREE-LIVING]" { section = .free; continue }
            if line == "[6MWT]" { closeSession(); section = .mwt; continue }
            if line.hasPrefix("#") {
                if section == .mwt, line.lowercased().contains("session") {
                    closeSession()
                    inSession = true
                    if let range = line.range(of: "started ") {
                        curStart = isoFmt.date(from: String(line[range.upperBound...])) ?? Date()
                    }
                }
                continue
            }
            if line == columns { continue }                     // header row
            guard let row = parseRow(line) else { continue }
            switch section {
            case .free: freeLiving.append(row)
            case .mwt:  if inSession { curRows.append(row) }
            case .none: break
            }
        }
        closeSession()
        return DayLog(day: day, freeLiving: freeLiving, sessions: sessions)
    }

    /// Backward compatible with older logs that only had up to the `heartbeat`
    /// column (8 fields) — GPS/rate columns simply read back as `nil` for
    /// those rows.
    private static func parseRow(_ line: String) -> Row? {
        let p = line.split(separator: ",", omittingEmptySubsequences: false).map { String($0) }
        guard p.count >= 7, let t = Double(p[0]),
              let ax = Double(p[1]), let ay = Double(p[2]), let az = Double(p[3]),
              let gx = Double(p[4]), let gy = Double(p[5]), let gz = Double(p[6]) else { return nil }
        let hr = p.count >= 8 ? Double(p[7]) : nil
        let lat = p.count >= 9 ? Double(p[8]) : nil
        let long = p.count >= 10 ? Double(p[9]) : nil
        let imuRateHz = p.count >= 11 ? Double(p[10]) : nil
        let sendRateHz = p.count >= 12 ? Double(p[11]) : nil
        return Row(t: t, ax: ax, ay: ay, az: az, gx: gx, gy: gy, gz: gz, hr: hr,
                   lat: lat, long: long, imuRateHz: imuRateHz, sendRateHz: sendRateHz)
    }
}
