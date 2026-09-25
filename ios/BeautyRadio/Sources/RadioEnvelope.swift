import Foundation

/// BRAD v1 wire format used by `/ws/radio` when the connection opts in with
/// `mediaProtocol=2`.
///
///     0..3    ASCII "BRAD"
///     4       UInt8  version (1)
///     5       UInt8  flags (bit 0 mixed, bit 1 replay)
///     6..7    UInt16 header length
///     8..11   UInt32 sequence
///     12..19  UInt64 media timestamp, microseconds
///     20..23  UInt32 transmission generation
///     24      UInt8  channel UTF-8 byte length
///     25      UInt8  speaker id UTF-8 byte length
///     26      UInt8  stream id UTF-8 byte length
///     27      reserved, zero
///     28..    channel, speaker id, stream id, then PCM16LE
///
/// Integer metadata is big-endian. The PCM payload stays little-endian.
///
/// The header length is **not** the same in both directions. An uplink frame
/// carries this device's 36-character installation UUID as the speaker id, so
/// its header is 108 bytes on a channel named "tanilama"; the server's downlink
/// mix uses the 10-character speaker id "server-mix", so the same channel
/// produces an 82-byte header. A decoder that assumes the layout it writes will
/// read the payload 26 bytes off and play silence or noise. Always take
/// `headerLength` from offset 6.
public enum RadioEnvelope {

    public struct Frame: Equatable {
        public var version: UInt8
        public var flags: UInt8
        public var sequence: UInt32
        public var mediaTimestampMicroseconds: UInt64
        public var transmissionGeneration: UInt32
        public var channel: String
        public var speakerId: String
        public var streamId: String
        public var pcm: Data
    }

    public struct Flags: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let mixed = Flags(rawValue: 0x01)
        public static let replay = Flags(rawValue: 0x02)
    }

    public enum DecodeError: Error, Equatable {
        case notAnEnvelope
        case truncatedHeader
        case unsupportedVersion(UInt8)
        case invalidHeaderLength
        case fieldTooLong(String)
    }

    public static let magic: [UInt8] = Array("BRAD".utf8)
    public static let version: UInt8 = 1
    public static let baseHeaderBytes = 28

    // MARK: - Encoding

    public static func encode(
        flags: Flags = [],
        sequence: UInt32,
        mediaTimestampMicroseconds: UInt64,
        transmissionGeneration: UInt32,
        channel: String,
        speakerId: String,
        streamId: String,
        pcm: Data
    ) throws -> Data {
        let channelBytes = Array(channel.utf8)
        let speakerBytes = Array(speakerId.utf8)
        let streamBytes = Array(streamId.utf8)
        guard channelBytes.count <= 0xFF else { throw DecodeError.fieldTooLong("channel") }
        guard speakerBytes.count <= 0xFF else { throw DecodeError.fieldTooLong("speakerId") }
        guard streamBytes.count <= 0xFF else { throw DecodeError.fieldTooLong("streamId") }

        let headerLength = baseHeaderBytes + channelBytes.count + speakerBytes.count + streamBytes.count
        var out = Data(capacity: headerLength + pcm.count)
        out.append(contentsOf: magic)
        out.append(version)
        out.append(flags.rawValue)
        out.appendBigEndian(UInt16(headerLength))
        out.appendBigEndian(sequence)
        out.appendBigEndian(mediaTimestampMicroseconds)
        out.appendBigEndian(transmissionGeneration)
        out.append(UInt8(channelBytes.count))
        out.append(UInt8(speakerBytes.count))
        out.append(UInt8(streamBytes.count))
        out.append(0)
        out.append(contentsOf: channelBytes)
        out.append(contentsOf: speakerBytes)
        out.append(contentsOf: streamBytes)
        out.append(pcm)
        return out
    }

    // MARK: - Decoding

    public static func hasMagic(_ data: Data) -> Bool {
        guard data.count >= magic.count else { return false }
        return Array(data.prefix(magic.count)) == magic
    }

    /// Returns `nil` for a frame that is plain PCM rather than an envelope, so a
    /// connection can accept both protocol versions from the same socket.
    public static func decode(_ data: Data) throws -> Frame? {
        guard hasMagic(data) else { return nil }
        guard data.count >= baseHeaderBytes else { throw DecodeError.truncatedHeader }

        let bytes = [UInt8](data)
        let frameVersion = bytes[4]
        guard frameVersion == version else { throw DecodeError.unsupportedVersion(frameVersion) }

        // Read the declared header length rather than recomputing it from our
        // own field sizes: the downlink layout differs from the uplink layout.
        let headerLength = Int(UInt16(bigEndian: bytes, at: 6))
        let channelLength = Int(bytes[24])
        let speakerIdLength = Int(bytes[25])
        let streamIdLength = Int(bytes[26])
        let minimumHeaderLength = baseHeaderBytes + channelLength + speakerIdLength + streamIdLength
        guard headerLength >= minimumHeaderLength, headerLength <= data.count else {
            throw DecodeError.invalidHeaderLength
        }

        var offset = baseHeaderBytes
        let channel = String(decoding: bytes[offset..<(offset + channelLength)], as: UTF8.self)
        offset += channelLength
        let speakerId = String(decoding: bytes[offset..<(offset + speakerIdLength)], as: UTF8.self)
        offset += speakerIdLength
        let streamId = String(decoding: bytes[offset..<(offset + streamIdLength)], as: UTF8.self)

        return Frame(
            version: frameVersion,
            flags: bytes[5],
            sequence: UInt32(bigEndian: bytes, at: 8),
            mediaTimestampMicroseconds: UInt64(bigEndian: bytes, at: 12),
            transmissionGeneration: UInt32(bigEndian: bytes, at: 20),
            channel: channel,
            speakerId: speakerId,
            streamId: streamId,
            pcm: data.subdata(in: headerLength..<data.count)
        )
    }
}

// MARK: - Big-endian helpers

private extension Data {
    mutating func appendBigEndian(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }
    mutating func appendBigEndian(_ value: UInt32) {
        for shift in stride(from: 24, through: 0, by: -8) {
            append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }
    mutating func appendBigEndian(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }
}

private extension UInt16 {
    init(bigEndian bytes: [UInt8], at index: Int) {
        self = (UInt16(bytes[index]) << 8) | UInt16(bytes[index + 1])
    }
}

private extension UInt32 {
    init(bigEndian bytes: [UInt8], at index: Int) {
        var value: UInt32 = 0
        for offset in 0..<4 { value = (value << 8) | UInt32(bytes[index + offset]) }
        self = value
    }
}

private extension UInt64 {
    init(bigEndian bytes: [UInt8], at index: Int) {
        var value: UInt64 = 0
        for offset in 0..<8 { value = (value << 8) | UInt64(bytes[index + offset]) }
        self = value
    }
}
