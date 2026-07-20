import SwiftUI
import FirebaseCore

@main
struct StrideSensorsApp: App {

    // One receiver, wired straight into the shared store.
    @StateObject private var receiver = UDPReceiver(port: 12345)

    // Firebase must be configured before any Firebase service is used.
    // Doing it here (in init) guarantees it runs before the first scene is built.
    init() {
        FirebaseApp.configure()
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(SensorStore.shared)
                .environmentObject(SensorLogStore.shared)
                .environmentObject(receiver)
                .preferredColorScheme(.dark)
                .onAppear {
                    // ── UDP channel (unchanged) ────────────────────────────
                    // Every arriving packet updates SensorStore and resets
                    // the Firebase fallback timer so the cloud channel stays
                    // quiet while UDP is healthy.
                    receiver.onData = { data, date in
                        SensorStore.shared.ingest(data, receivedAt: date)
                        FirebaseReceiver.shared.noteUDPActivity()
                    }
                    receiver.start()

                    // ── Cloud channel (new) ────────────────────────────────
                    // Listens to Firebase for data pushed by the watch at 2 Hz.
                    // Only feeds SensorStore when UDP has been silent for >2 s,
                    // so on the same network UDP always wins.
                    FirebaseReceiver.shared.start()

                    // Example: run your own formula on every packet.
                    // SensorStore.shared.onSample = { sample in
                    //     let jerk = sample.accelMagnitude   // ...your math
                    // }
                }
        }
    }
}
