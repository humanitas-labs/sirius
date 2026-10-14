import Foundation

// Accumulates reads until the first "\n", bounded before parsing. The frame
// excludes its "\n"; whatever follows it is never looked at.
struct FrameAccumulator {
    let limit: Int
    private(set) var buffer = Data()

    enum Outcome: Equatable {
        case needMore
        case frame(Data)
        // Bytes seen without a "\n" within the limit.
        case oversize(received: Int)
    }

    init(limit: Int) {
        self.limit = limit
    }

    mutating func append<Bytes: Collection>(_ chunk: Bytes) -> Outcome where Bytes.Element == UInt8 {
        if let newline = chunk.firstIndex(of: 0x0A) {
            let length = buffer.count + chunk.distance(from: chunk.startIndex, to: newline)
            guard length <= limit else { return .oversize(received: length) }
            buffer.append(contentsOf: chunk[chunk.startIndex..<newline])
            return .frame(buffer)
        }
        let length = buffer.count + chunk.count
        guard length <= limit else { return .oversize(received: length) }
        buffer.append(contentsOf: chunk)
        return .needMore
    }
}
