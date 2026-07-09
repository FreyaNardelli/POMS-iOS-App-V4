import Foundation
import Network
import Combine

/// Listens for UDP datagrams on a port (default 12345) and hands each raw
/// payload to `onData`. Built on Apple's Network framework so it works on a
/// real device and on the simulator (over the Mac's network).
///
/// UDP has no "connections" in the TCP sense, but `NWListener` surfaces each
/// distinct sending endpoint as an `NWConnection`. We keep every such flow
/// alive and read one datagram at a time from it.
final class UDPReceiver: ObservableObject {

    // MARK: Published state (safe to bind from SwiftUI)
    @Published private(set) var isListening = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastPacketDate: Date?
    @Published private(set) var boundPort: UInt16

    /// Called for every datagram received, on the receiver's background queue.
    /// Keep the work light or hop to your own queue.
    var onData: ((Data, Date) -> Void)?

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let queue = DispatchQueue(label: "com.stride.udp.receiver")

    init(port: UInt16 = 12345) {
        self.boundPort = port
    }

    // MARK: Lifecycle

    func start() {
        guard listener == nil else { return }
        guard let port = NWEndpoint.Port(rawValue: boundPort) else {
            publish { self.lastError = "Invalid port \(self.boundPort)" }
            return
        }

        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true           // rebind after a crash / relaunch
        params.includePeerToPeer = true                 // allow AWDL / local link peers

        do {
            let listener = try NWListener(using: params, on: port)
            self.listener = listener

            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.publish { self.isListening = true; self.lastError = nil }
                case .failed(let error):
                    self.publish { self.isListening = false; self.lastError = error.localizedDescription }
                    self.restartSoon()
                case .cancelled:
                    self.publish { self.isListening = false }
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }

            listener.start(queue: queue)
        } catch {
            publish { self.lastError = error.localizedDescription }
        }
    }

    func stop() {
        queue.async {
            self.connections.values.forEach { $0.cancel() }
            self.connections.removeAll()
            self.listener?.cancel()
            self.listener = nil
        }
        publish { self.isListening = false }
    }

    // MARK: Connection handling

    private func handle(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections[key] = connection

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.queue.async { self?.connections[key] = nil }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        // receiveMessage yields exactly one UDP datagram per call.
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                let now = Date()
                self.publish { self.lastPacketDate = now }
                self.onData?(data, now)
            }
            if error == nil {
                self.receive(on: connection)   // keep reading
            } else {
                connection.cancel()
            }
        }
    }

    private func restartSoon() {
        queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.listener == nil || self.isListening == false else { return }
            self.listener?.cancel()
            self.listener = nil
            self.start()
        }
    }

    private func publish(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
    }
}
