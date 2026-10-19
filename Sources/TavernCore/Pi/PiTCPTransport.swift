import Foundation
import Network

/// Pi RPC over a plain TCP stream (one JSON record per LF-terminated line, both ways).
/// Meant for tailnet-only or SSH-forwarded ports; the protocol has no auth of its own.
public final class PiTCPTransport: PiTransport, @unchecked Sendable {
    public let host: String
    public let port: UInt16

    private let queue = DispatchQueue(label: "tavern.pi.tcp")
    private var connection: NWConnection?
    private var framer = LineFramer()
    private var closed = false

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    public func start(onLine: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable (Error?) -> Void) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw PiTransportError.notRunning }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        self.connection = connection

        let finish: @Sendable (Error?) -> Void = { [weak self] error in
            guard let self else { return }
            self.queue.async {
                guard !self.closed else { return }
                self.closed = true
                self.connection?.cancel()
                onClose(error)
            }
        }

        connection.stateUpdateHandler = { state in
            switch state {
            case .failed(let error):
                finish(error)
            case .waiting(let error):
                // Unreachable host or refused port: fail fast so the session can back off and retry.
                finish(error)
            case .cancelled:
                finish(nil)
            default:
                break
            }
        }
        receive(on: connection, onLine: onLine, finish: finish)
        connection.start(queue: queue)
    }

    private func receive(on connection: NWConnection, onLine: @escaping @Sendable (Data) -> Void,
                         finish: @escaping @Sendable (Error?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.framer.push(data).forEach(onLine)
            }
            if let error {
                finish(error)
            } else if isComplete {
                finish(nil)
            } else {
                self.receive(on: connection, onLine: onLine, finish: finish)
            }
        }
    }

    public func send(_ line: Data) throws {
        guard let connection, !closed else { throw PiTransportError.notRunning }
        connection.send(content: line + Data([0x0A]), completion: .contentProcessed { _ in })
    }

    public func close() {
        queue.async { [weak self] in
            self?.connection?.cancel()
        }
    }
}
