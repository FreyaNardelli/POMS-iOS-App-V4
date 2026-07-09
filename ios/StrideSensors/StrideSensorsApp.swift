import SwiftUI

@main
struct StrideSensorsApp: App {
    // One receiver, wired straight into the shared store.
    @StateObject private var receiver = UDPReceiver(port: 12345)

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(SensorStore.shared)
                .environmentObject(SensorLogStore.shared)
                .environmentObject(receiver)
                .preferredColorScheme(.dark)
                .onAppear {
                    receiver.onData = { data, date in
                        SensorStore.shared.ingest(data, receivedAt: date)
                    }
                    receiver.start()

                    // Example: run your own formula on every packet.
                    // SensorStore.shared.onSample = { sample in
                    //     let jerk = sample.accelMagnitude   // ...your math
                    // }
                }
        }
    }
}
