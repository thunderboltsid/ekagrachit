import Foundation

/// Length-prefixed message framing shared by Chrome Native Messaging (stdio)
/// and the host <-> app Unix socket: a 32-bit unsigned length in native byte
/// order (little-endian on every Mac Chrome supports) followed by UTF-8 JSON.
public enum Framing {
    /// Chrome caps host -> extension messages at 1 MB; we use the same limit
    /// in both directions. Real messages are a few hundred bytes.
    public static let maxMessageSize = 1 << 20

    public static func encode(_ payload: Data) -> Data {
        var length = UInt32(payload.count).littleEndian
        var out = Data(bytes: &length, count: 4)
        out.append(payload)
        return out
    }
}

public enum FramingError: Error, Equatable {
    case messageTooLarge(Int)
}

/// Incremental decoder: feed arbitrary chunks, get complete frames out.
public struct FrameDecoder {
    private var buffer = Data()
    public let maxSize: Int

    public init(maxSize: Int = Framing.maxMessageSize) {
        self.maxSize = maxSize
    }

    public mutating func feed(_ chunk: Data) throws -> [Data] {
        buffer.append(chunk)
        var frames: [Data] = []
        while buffer.count >= 4 {
            let b = [UInt8](buffer.prefix(4))
            let length = Int(UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24)
            if length > maxSize { throw FramingError.messageTooLarge(length) }
            guard buffer.count >= 4 + length else { break }
            frames.append(Data(buffer.dropFirst(4).prefix(length)))
            buffer = Data(buffer.dropFirst(4 + length))
        }
        return frames
    }
}
