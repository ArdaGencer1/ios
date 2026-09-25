import XCTest
@testable import BeautyRadio

/// Collects frames from the audio queue for assertions on the test thread.
private final class FrameCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [Data] = []
    func append(_ frame: Data) { lock.withLock { frames.append(frame) } }
    var all: [Data] { lock.withLock { frames } }
    var count: Int { lock.withLock { frames.count } }
    func reset() { lock.withLock { frames.removeAll() } }
}

/// The two ways a walkie-talkie loses words: the syllable spoken just before
/// the button goes down, and the one still in the pipeline when it comes up.
final class RadioAudioEngineTests: XCTestCase {

    private func frame(_ marker: UInt8, engine: RadioAudioEngine) -> Data {
        Data(repeating: marker, count: engine.frameByteCount)
    }

    func testPreRollSendsTheAudioCapturedBeforeThePress() {
        var configuration = RadioAudioEngine.Configuration()
        configuration.preRollDuration = 0.3 // 15 frames at 20 ms
        let engine = RadioAudioEngine(configuration: configuration)
        let collector = FrameCollector()
        engine.onCapturedFrame = { collector.append($0) }

        // Speech arriving before the button is pressed.
        for marker in 0..<20 { engine.deliver(frame(UInt8(marker), engine: engine)) }
        XCTAssertEqual(collector.count, 0, "nothing is transmitted before the press")

        engine.beginTransmitting()
        engine.syncForTesting()

        let sent = collector.all
        XCTAssertEqual(sent.count, 15, "the retained pre-roll is sent on the press")
        // Oldest trimmed, order preserved: markers 5...19.
        XCTAssertEqual(sent.first?.first, 5)
        XCTAssertEqual(sent.last?.first, 19)
    }

    func testReleaseKeepsCapturingUntilTheTailIsSent() {
        var configuration = RadioAudioEngine.Configuration()
        configuration.tailDuration = 0.05
        let engine = RadioAudioEngine(configuration: configuration)
        let collector = FrameCollector()
        engine.onCapturedFrame = { collector.append($0) }

        engine.beginTransmitting()
        engine.syncForTesting()
        engine.deliver(frame(1, engine: engine))
        XCTAssertEqual(collector.count, 1)

        // Half a frame is still in the converter when the button comes up.
        engine.pendingCapture = Data(repeating: 9, count: engine.frameByteCount / 2)

        let completed = expectation(description: "stop is signalled after the tail")
        let releasedAt = Date()
        engine.endTransmitting { completed.fulfill() }

        // Deliberately inside the tail window but after the point where an
        // implementation that stopped on release would already have closed:
        // delivering immediately would pass either way.
        Thread.sleep(forTimeInterval: configuration.tailDuration / 2)
        engine.deliver(frame(2, engine: engine))
        wait(for: [completed], timeout: 2)
        engine.syncForTesting()

        XCTAssertGreaterThan(
            Date().timeIntervalSince(releasedAt),
            configuration.tailDuration * 0.8,
            "the stop must wait for the tail instead of firing on release"
        )

        let sent = collector.all
        XCTAssertEqual(sent.count, 3, "spoken frame, tail frame, then the padded remainder")
        XCTAssertEqual(sent[1].first, 2, "the frame captured during the tail was sent")
        let padded = sent[2]
        XCTAssertEqual(padded.count, engine.frameByteCount, "the partial frame is zero-padded to a wire frame")
        XCTAssertEqual(padded.first, 9)
        XCTAssertEqual(padded.last, 0)

        // After the stop, capture goes back to the pre-roll instead of the wire.
        collector.reset()
        engine.deliver(frame(3, engine: engine))
        engine.syncForTesting()
        XCTAssertEqual(collector.count, 0)
    }
}
