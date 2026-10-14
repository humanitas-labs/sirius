import Darwin
import Dispatch
import Foundation
import SiriusProtocol

// One accepted connection: read one frame, answer it once, close.
//
// Every stored property is touched only on `io`, the server's serial queue;
// that confinement is what makes the @unchecked Sendable sound. The one hop
// off it is the Task that validates the frame and awaits the CommandQueue,
// which captures only Sendable values and comes back through io.async.
final class AgentSocketConnection: @unchecked Sendable {
    private let fd: Int32
    private let agent: String
    private let io: DispatchQueue
    private let settings: SocketServerSettings
    private let commands: any CommandQueue
    private let onFinish: (AgentSocketConnection) -> Void

    private var accumulator: FrameAccumulator
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var deadline: DispatchSourceTimer?
    private var pending = Data()
    // Oversize: the error is written, the rest of the input read and dropped.
    private var draining = false
    private var peerClosed = false
    private var finished = false
    // fd sources whose cancel handlers have not run; the fd is closed after.
    private var liveSources = 0
    private var fdClosed = false

    private static let chunkSize = 64 * 1024

    init(fd: Int32, agent: String, io: DispatchQueue, settings: SocketServerSettings,
         commands: any CommandQueue, onFinish: @escaping (AgentSocketConnection) -> Void) {
        self.fd = fd
        self.agent = agent
        self.io = io
        self.settings = settings
        self.commands = commands
        self.onFinish = onFinish
        self.accumulator = FrameAccumulator(limit: settings.maxRequestBytes)
    }

    func start() {
        dispatchPrecondition(condition: .onQueue(io))
        arm(settings.readDeadline)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: io)
        source.setEventHandler { [unowned self] in readable() }
        source.setCancelHandler { [self] in sourceCancelled() }
        liveSources += 1
        readSource = source
        source.resume()
    }

    // Closes at once, answered or not. Safe to call more than once.
    func finish() {
        dispatchPrecondition(condition: .onQueue(io))
        guard !finished else { return }
        finished = true
        deadline?.cancel()
        deadline = nil
        readSource?.cancel()
        readSource = nil
        writeSource?.cancel()
        writeSource = nil
        closeIfIdle()
        onFinish(self)
    }

    // MARK: - Reading

    private func readable() {
        var chunk = [UInt8](repeating: 0, count: Self.chunkSize)
        let count = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if count < 0 {
            if errno == EAGAIN || errno == EINTR { return }
            return finish()
        }
        if count == 0 {
            // EOF. An incomplete frame is dropped without a response.
            guard draining else { return finish() }
            peerClosed = true
            stopReading()
            if pending.isEmpty { finish() }
            return
        }
        if draining { return }
        switch accumulator.append(chunk[0..<count]) {
        case .needMore:
            return
        case .frame(let frame):
            received(frame)
        case .oversize(let received):
            rejectOversize(received: received)
        }
    }

    private func stopReading() {
        readSource?.cancel()
        readSource = nil
    }

    // Only the first frame is executed; anything after it is never read.
    private func received(_ frame: Data) {
        stopReading()
        disarm()
        let agent = agent
        let commands = commands
        let now = Date()
        Task { [self] in
            let reply = await Self.answer(frame: frame, agent: agent, received: now, commands: commands)
            io.async { [self] in
                guard let reply else { return finish() }
                respond(reply)
            }
        }
    }

    // Answered with TOO_LARGE (id null: nothing was parsed), then the rest of
    // the input is read and dropped until EOF or the read deadline, so a
    // helper still writing its request can finish and read the answer rather
    // than hit EPIPE and report an unknown outcome.
    private func rejectOversize(received: Int) {
        draining = true
        accumulator = FrameAccumulator(limit: 0)
        let error = RPCError(.tooLarge, "maxRequestBytes is \(settings.maxRequestBytes); got at least \(received)",
                             data: ErrorData(limit: .maxRequestBytes, value: received))
        respond((try? encodeFrame(Response(id: nil, .error(error)))) ?? Data())
    }

    static func answer(frame: Data, agent: String, received: Date, commands: any CommandQueue) async -> Data? {
        let response: Response
        switch validate(frame: frame) {
        case .notification:
            return nil
        case .failure(let id, let error):
            response = Response(id: id, .error(error))
        case .request(let id, let call):
            switch await commands.accept(Command(agent: agent, id: id, call: call, received: received)) {
            case .success(let result) where call.admits(result):
                response = Response(id: id, .result(result))
            case .success:
                response = Response(id: id, .error(RPCError(.internalError, "Internal error",
                                                            data: ErrorData(method: call.method))))
            case .failure(let error): response = Response(id: id, .error(error))
            }
        }
        return try? encodeFrame(response)
    }

    // MARK: - Writing

    private func respond(_ data: Data) {
        guard !finished else { return }
        guard !data.isEmpty else { return finish() }
        pending = data
        // The draining case keeps the read deadline it already has.
        if !draining { arm(settings.writeDeadline) }
        flush()
    }

    private func flush() {
        while !pending.isEmpty {
            let written = pending.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if written > 0 {
                pending.removeFirst(written)
            } else if written < 0 && errno == EINTR {
                continue
            } else if written < 0 && errno == EAGAIN {
                return awaitWritable()
            } else {
                return finish()
            }
        }
        writeSource?.cancel()
        writeSource = nil
        if draining && !peerClosed {
            // Tell the helper the answer is complete; keep reading to EOF.
            shutdown(fd, SHUT_WR)
            return
        }
        finish()
    }

    private func awaitWritable() {
        guard writeSource == nil else { return }
        let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: io)
        source.setEventHandler { [unowned self] in flush() }
        source.setCancelHandler { [self] in sourceCancelled() }
        liveSources += 1
        writeSource = source
        source.resume()
    }

    // MARK: - Deadline and teardown

    private func arm(_ seconds: TimeInterval) {
        deadline?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: io)
        timer.schedule(deadline: .now() + seconds)
        // Past the deadline the connection is closed with no response.
        timer.setEventHandler { [weak self] in self?.finish() }
        deadline = timer
        timer.resume()
    }

    private func disarm() {
        deadline?.cancel()
        deadline = nil
    }

    // The fd may be closed only once no source still watches it.
    private func sourceCancelled() {
        liveSources -= 1
        closeIfIdle()
    }

    private func closeIfIdle() {
        guard finished, liveSources == 0, !fdClosed else { return }
        fdClosed = true
        Darwin.close(fd)
    }
}
