import Foundation
import SiriusProtocol

// A validated request from one agent, as the socket server hands it on.
public struct Command: Equatable, Sendable {
    // The agent whose socket it arrived on.
    public var agent: String
    public var id: RequestId
    public var call: Call
    public var received: Date

    public init(agent: String, id: RequestId, call: Call, received: Date = Date()) {
        self.agent = agent
        self.id = id
        self.call = call
        self.received = received
    }
}

// The seam between the socket server and the presenters.
// The server calls accept once per valid request and sends the answer back
// as the response: a result means accepted into the queue, not yet shown.
// An implementation checks capacity and enqueues in one step, so concurrent
// agents cannot overfill a queue, and returns once accepted, never after
// presenting. The result must suit the call (Call.admits); the server answers
// INTERNAL_ERROR rather than send one that does not.
public protocol CommandQueue: Sendable {
    // .failure carries QUEUE_FULL, NOT_READY or ACCESS_DENIED.
    func accept(_ command: Command) async -> Result<MethodResult, RPCError>
}

extension Call {
    // display and notify answer delivered; speak answers its queued receipt.
    public func admits(_ result: MethodResult) -> Bool {
        switch (self, result) {
        case (.display, .delivered), (.notify, .delivered), (.speak, .queued): true
        default: false
        }
    }
}
