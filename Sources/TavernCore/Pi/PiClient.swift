import Foundation

public enum PiClientError: Error, Equatable {
    case rejected(command: String, error: String?)
    case disconnected
    case timedOut(command: String)
}

/// Request/response correlation over a `PiTransport`. Responses match by `id`, never by order.
/// Everything that isn't a response (events, dialogs, notices) goes to `records`.
public actor PiClient {
    private let transport: PiTransport
    private var pending: [String: CheckedContinuation<PiResponse, Error>] = [:]
    private var deadlines: [String: Task<Void, Never>] = [:]
    private let requestTimeout: Duration
    private var nextID = 0
    private var closed = false

    public nonisolated let records: AsyncStream<PiRecord>
    private let recordSink: AsyncStream<PiRecord>.Continuation

    public init(transport: PiTransport, requestTimeout: Duration = .seconds(60)) {
        self.transport = transport
        self.requestTimeout = requestTimeout
        let made = AsyncStream.makeStream(of: PiRecord.self, bufferingPolicy: .unbounded)
        records = made.stream
        recordSink = made.continuation
    }

    /// Subscribes before any command is sent, so a fast completion can't be missed.
    public func start() throws {
        // One stream and one consumer task keep lines in arrival order.
        let (lines, sink) = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .unbounded)
        try transport.start(
            onLine: { line in sink.yield(line) },
            onClose: { _ in sink.finish() }
        )
        Task { [weak self] in
            for await line in lines {
                await self?.receive(line)
            }
            await self?.didClose()
        }
    }

    /// Sends a command and waits for its response. Throws `rejected` when `success` is false.
    @discardableResult
    public func send(_ command: PiCommand) async throws -> PiResponse {
        let response = try await request(command)
        guard response.success else {
            throw PiClientError.rejected(command: response.command, error: response.error)
        }
        return response
    }

    /// Like `send`, but returns a failed response instead of throwing, for callers that branch on it
    /// (`get_entries` with an unknown `since` is how Pi says "resync from scratch").
    public func request(_ command: PiCommand) async throws -> PiResponse {
        guard !closed else { throw PiClientError.disconnected }
        nextID += 1
        let id = "tavern-\(nextID)"
        let line = try command.json(id: id, requestId: command.submitsMessage ? UUID().uuidString : nil).encoded()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                deadlines[id] = Task { [weak self, requestTimeout] in
                    do { try await Task.sleep(for: requestTimeout) } catch { return }
                    await self?.expire(id, command: command.type)
                }
                do {
                    try transport.send(line)
                } catch {
                    finish(id, result: .failure(error))
                }
            }
        } onCancel: {
            Task { await self.finish(id, result: .failure(CancellationError())) }
        }
    }

    private func finish(_ id: String, result: Result<PiResponse, Error>) {
        deadlines.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: result)
    }

    private func expire(_ id: String, command: String) {
        // A timeout is not evidence that a prompt was rejected. Callers must not resend it.
        finish(id, result: .failure(PiClientError.timedOut(command: command)))
    }

    public func answer(_ dialog: PiDialog, with answer: PiDialogAnswer) throws {
        try transport.send(try answer.json(dialogID: dialog.id).encoded())
    }

    public func close() {
        transport.close()
        didClose()
    }

    func receive(_ line: Data) {
        guard let record = try? PiRecord.parse(line) else { return }
        if case .response(let response) = record, let id = response.id {
            // Late replies after timeout/cancel are ignored, never matched to another request.
            finish(id, result: .success(response))
        } else {
            recordSink.yield(record)
        }
    }

    func didClose() {
        closed = true
        let waiting = pending
        pending = [:]
        deadlines.values.forEach { $0.cancel() }
        deadlines = [:]
        waiting.values.forEach { $0.resume(throwing: PiClientError.disconnected) }
        recordSink.finish()
    }
}
