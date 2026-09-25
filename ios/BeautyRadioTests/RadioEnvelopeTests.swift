import XCTest
@testable import BeautyRadio

final class RadioEnvelopeTests: XCTestCase {

    /// The exact vector the backend asserts in `tests/radioBackend.test.js`
    /// ("BRAD v1 parser accepts the Swift encoder fixture byte-for-byte"). If
    /// this test passes, the wire format matches the server's parser.
    func testEncoderMatchesServerFixtureByteForByte() throws {
        let encoded = try RadioEnvelope.encode(
            flags: [.mixed, .replay],
            sequence: 0x01020304,
            mediaTimestampMicroseconds: 0x0102030405060708,
            transmissionGeneration: 0x11223344,
            channel: "genel",
            speakerId: "speaker-7",
            streamId: "stream-9",
            pcm: Data([0xd2, 0x04, 0xd7, 0xf6])
        )
        let expected = "4252414401030032010203040102030405060708112233440509080067656e656c"
            + "737065616b65722d3773747265616d2d39d204d7f6"
        XCTAssertEqual(encoded.map { String(format: "%02x", $0) }.joined(), expected)
    }

    func testRoundTrip() throws {
        let pcm = Data((0..<640).map { UInt8($0 % 256) })
        let encoded = try RadioEnvelope.encode(
            sequence: 7,
            mediaTimestampMicroseconds: 1_000_000,
            transmissionGeneration: 3,
            channel: "genel",
            speakerId: "11111111-1111-4111-8111-111111111111",
            streamId: "22222222-2222-4222-8222-222222222222",
            pcm: pcm
        )
        let frame = try XCTUnwrap(RadioEnvelope.decode(encoded))
        XCTAssertEqual(frame.sequence, 7)
        XCTAssertEqual(frame.transmissionGeneration, 3)
        XCTAssertEqual(frame.channel, "genel")
        XCTAssertEqual(frame.pcm, pcm)
    }

    /// The regression that made the previous build silent: a downlink frame has
    /// a shorter header than anything this device sends, because the server's
    /// mix uses the speaker id "server-mix" instead of a 36-character UUID. A
    /// decoder that reuses its own header size reads the payload 26 bytes late.
    func testDecodesDownlinkHeaderShorterThanUplinkHeader() throws {
        let pcm = Data((0..<640).map { _ in UInt8.random(in: 0...255) })
        let uplink = try RadioEnvelope.encode(
            sequence: 0,
            mediaTimestampMicroseconds: 0,
            transmissionGeneration: 1,
            channel: "tanilama",
            speakerId: "9f000000-0000-4000-8000-00000000000a",
            streamId: "22222222-2222-4222-8222-222222222222",
            pcm: pcm
        )
        let downlink = try RadioEnvelope.encode(
            flags: [.mixed],
            sequence: 0,
            mediaTimestampMicroseconds: 0,
            transmissionGeneration: 1,
            channel: "tanilama",
            speakerId: "server-mix",
            streamId: "22222222-2222-4222-8222-222222222222",
            pcm: pcm
        )
        XCTAssertEqual(uplink.count - downlink.count, 26, "uplink/downlink header delta changed")

        let decoded = try XCTUnwrap(RadioEnvelope.decode(downlink))
        XCTAssertEqual(decoded.speakerId, "server-mix")
        XCTAssertEqual(decoded.pcm, pcm, "payload must be sliced using the frame's own header length")
    }

    func testPlainPcmIsNotMistakenForAnEnvelope() throws {
        XCTAssertNil(try RadioEnvelope.decode(Data(repeating: 0, count: 640)))
    }
}
