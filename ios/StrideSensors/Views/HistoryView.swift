import SwiftUI
import UIKit

/// History tab — browse the locally-stored daily CSV logs. Pick a day from the
/// dropdown, switch between the Free-living and 6MWT tables, and export the
/// day's CSV via the share sheet.
struct HistoryView: View {
    @EnvironmentObject var log: SensorLogStore

    enum Table: String, CaseIterable { case freeLiving = "Free-living", mwt = "6MWT" }

    @State private var selectedDay: String = ""
    @State private var table: Table = .freeLiving
    @State private var dayLog: SensorLogStore.DayLog?
    @State private var shareURL: URL?
    @State private var selectedSessionIndex: Int = 0
    @State private var isExportingAll = false

    private let maxRowsShown = 1500

    // "timestamp" is stored as epoch ms (for sorting/precision) but displayed
    // as a plain HH:mm:ss clock time here — readable, and cheap to compute
    // (one cached DateFormatter, no per-row allocation) versus a full
    // YYYY-MM-DD-HH-MM-SS-milliseconds stamp that adds little value in a
    // same-day table where the date is already picked from the dropdown above.
    private let headers = ["time", "accel.x", "accel.y", "accel.z*",
                           "gyro.x", "gyro.y", "gyro.z", "hr",
                           "GPS lat", "GPS long", "IMU Hz", "Send Hz"]
    private let colWidths: [CGFloat] = [92, 78, 78, 88, 78, 78, 78, 52, 90, 90, 62, 66]

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    /// Epoch-ms `Row.t` → "HH:mm:ss" in the device's local time.
    private func formatTime(_ epochMs: Double) -> String {
        Self.timeFmt.string(from: Date(timeIntervalSince1970: epochMs / 1000))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                controls
                Divider().overlay(Theme.panelBorder)
                if let d = dayLog {
                    content(for: d)
                } else {
                    empty
                }
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { exportCurrentDay() } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(selectedDay.isEmpty)
                }
            }
        }
        .tint(Theme.orange)
        .onAppear { primeSelection() }
        .onChange(of: selectedDay) { _ in reload() }
        .sheet(isPresented: Binding(get: { shareURL != nil }, set: { if !$0 { shareURL = nil } })) {
            if let url = shareURL { ShareSheet(items: [url]) }
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Day").font(Theme.display(13, .heavy)).foregroundColor(Theme.textDim)
                Spacer()
                Menu {
                    ForEach(log.availableDays, id: \.self) { day in
                        Button(prettyDay(day)) { selectedDay = day }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(selectedDay.isEmpty ? "No data yet" : prettyDay(selectedDay))
                            .font(Theme.display(15, .bold))
                        Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
                    }
                    .foregroundColor(Theme.textPrimary)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.panelBorder, lineWidth: 1)))
                }
                .disabled(log.availableDays.isEmpty)
            }

            exportAllButton

            Picker("", selection: $table) {
                ForEach(Table.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 12)
    }

    /// Everything collected and calculated for this patient, bundled as one
    /// .zip of CSVs — raw per-day sensor logs plus the swing-speed model's
    /// training data, fitted weights, and a feature legend. See
    /// `DataExportManager` for exactly what goes in it.
    private var exportAllButton: some View {
        Button { exportAll() } label: {
            HStack(spacing: 8) {
                if isExportingAll {
                    ProgressView().tint(Theme.textPrimary)
                } else {
                    Image(systemName: "archivebox")
                }
                Text(isExportingAll ? "Preparing export…" : "Export all data (.zip)")
                    .font(Theme.display(13, .bold))
            }
            .foregroundColor(Theme.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 12).fill(Theme.panel)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.panelBorder, lineWidth: 1))
            )
        }
        .disabled(isExportingAll)
    }

    // MARK: Content

    @ViewBuilder
    private func content(for d: SensorLogStore.DayLog) -> some View {
        switch table {
        case .freeLiving:
            let rows = d.freeLiving
            if rows.isEmpty {
                emptyTable("No free-living data for this day.")
            } else {
                VStack(spacing: 0) {
                    caption("\(rows.count.formatted()) samples" +
                            (rows.count > maxRowsShown ? " · showing latest \(maxRowsShown)" : ""))
                    tableView(Array(rows.suffix(maxRowsShown)))
                }
            }
        case .mwt:
            if d.sessions.isEmpty {
                emptyTable("No 6-minute walk tests recorded this day.")
            } else {
                mwtContent(d.sessions)
            }
        }
    }

    /// Session picker (one tab per test) + a single scrollable table for
    /// whichever session is selected, instead of stacking every session's
    /// full sample table in one continuously-scrolling page.
    @ViewBuilder
    private func mwtContent(_ sessions: [SensorLogStore.Session]) -> some View {
        let idx = min(selectedSessionIndex, sessions.count - 1)
        VStack(spacing: 0) {
            sessionTabs(sessions, selected: idx)
            let session = sessions[idx]
            caption("Test \(idx + 1) · \(timeOfDay(session.start)) · " +
                    "\(session.rows.count.formatted()) samples" +
                    (session.rows.count > maxRowsShown ? " · showing latest \(maxRowsShown)" : ""))
            tableView(Array(session.rows.suffix(maxRowsShown)))
        }
        .onAppear { if selectedSessionIndex >= sessions.count { selectedSessionIndex = 0 } }
        .onChange(of: sessions.count) { count in
            if selectedSessionIndex >= count { selectedSessionIndex = max(0, count - 1) }
        }
    }

    private func sessionTabs(_ sessions: [SensorLogStore.Session], selected: Int) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(sessions.enumerated()), id: \.element.id) { i, session in
                    Button { selectedSessionIndex = i } label: {
                        VStack(spacing: 1) {
                            Text("Test \(i + 1)").font(Theme.display(12, .bold))
                            Text(timeOfDay(session.start)).font(.system(size: 10))
                        }
                        .foregroundColor(i == selected ? .white : Theme.textDim)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(i == selected ? Theme.orange : Theme.panel)
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.panelBorder, lineWidth: i == selected ? 0 : 1))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
    }

    private func caption(_ text: String) -> some View {
        HStack {
            Text(text).font(Theme.display(11, .heavy)).foregroundColor(Theme.textFaint)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    /// Horizontally + vertically scrollable numeric table.
    private func tableView(_ rows: [SensorLogStore.Row]) -> some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(spacing: 0) {
                headerRow
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 0) {
                        ForEach(rows.indices, id: \.self) { i in dataRow(rows[i], i) }
                    }
                }
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            ForEach(headers.indices, id: \.self) { i in
                Text(headers[i])
                    .font(Theme.mono(11)).foregroundColor(Theme.textDim)
                    .frame(width: colWidths[i], alignment: .trailing)
                    .padding(.vertical, 8).padding(.trailing, 10)
            }
        }
        .background(Theme.bgElevated)
    }

    private func dataRow(_ r: SensorLogStore.Row, _ i: Int) -> some View {
        HStack(spacing: 0) {
            cell(formatTime(r.t), 0, primary: true)
            cell(String(format: "%.3f", r.ax), 1)
            cell(String(format: "%.3f", r.ay), 2)
            cell(String(format: "%.3f", r.az), 3)
            cell(String(format: "%.3f", r.gx), 4)
            cell(String(format: "%.3f", r.gy), 5)
            cell(String(format: "%.3f", r.gz), 6)
            cell(r.hr.map { String(format: "%.0f", $0) } ?? "—", 7)
            cell(r.lat.map { String(format: "%.5f", $0) } ?? "—", 8)
            cell(r.long.map { String(format: "%.5f", $0) } ?? "—", 9)
            cell(r.imuRateHz.map { String(format: "%.0f", $0) } ?? "—", 10)
            cell(r.sendRateHz.map { String(format: "%.0f", $0) } ?? "—", 11)
        }
        .background(i % 2 == 0 ? Color.clear : Theme.panel.opacity(0.4))
    }

    private func cell(_ text: String, _ i: Int, primary: Bool = false) -> some View {
        Text(text)
            .font(Theme.mono(11))
            .foregroundColor(primary ? Theme.textDim : Theme.textPrimary)
            .frame(width: colWidths[i], alignment: .trailing)
            .padding(.vertical, 6).padding(.trailing, 10)
    }

    // MARK: Empty states

    private var empty: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "tray").font(.system(size: 40)).foregroundColor(Theme.textFaint)
            Text("No data stored yet").font(Theme.display(16, .bold)).foregroundColor(Theme.textDim)
            Text("Sensor data is saved automatically as the watch streams.")
                .font(.system(size: 13)).foregroundColor(Theme.textFaint)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
            Spacer()
        }
    }

    private func emptyTable(_ msg: String) -> some View {
        VStack {
            Spacer()
            Text(msg).font(.system(size: 14)).foregroundColor(Theme.textFaint)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
            Spacer()
        }
    }

    // MARK: Logic

    private func primeSelection() {
        log.refreshAvailableDays()
        if selectedDay.isEmpty { selectedDay = log.availableDays.first ?? SensorLogStore.dayString(Date()) }
        reload()
    }

    private func reload() {
        guard !selectedDay.isEmpty else { dayLog = nil; return }
        dayLog = log.loadDay(selectedDay)
        selectedSessionIndex = 0
    }

    private func exportCurrentDay() {
        guard !selectedDay.isEmpty else { return }
        log.flushNow()
        shareURL = log.fileURL(for: selectedDay)
    }

    /// Builds the full "everything" export off the main thread (it reads
    /// every day's raw log from disk, which can take a moment on a long
    /// history) and presents the share sheet once ready.
    private func exportAll() {
        guard !isExportingAll else { return }
        isExportingAll = true
        DispatchQueue.global(qos: .userInitiated).async {
            let url = DataExportManager.buildFullExport()
            DispatchQueue.main.async {
                isExportingAll = false
                if let url { shareURL = url }
            }
        }
    }

    // MARK: Formatting

    private func prettyDay(_ day: String) -> String {
        let inFmt = DateFormatter(); inFmt.dateFormat = "yyyy_MM_dd"; inFmt.locale = Locale(identifier: "en_US_POSIX")
        guard let date = inFmt.date(from: day) else { return day }
        let out = DateFormatter(); out.dateFormat = "EEE, MMM d, yyyy"
        return out.string(from: date)
    }

    private func timeOfDay(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f.string(from: date)
    }
}

/// UIKit share sheet wrapper for exporting the CSV file.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
