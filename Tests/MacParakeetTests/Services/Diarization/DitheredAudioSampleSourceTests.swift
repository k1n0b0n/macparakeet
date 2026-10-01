import FluidAudio
import XCTest

@testable import MacParakeetCore

final class DitheredAudioSampleSourceTests: XCTestCase {
    private typealias Dithered = DitheredAudioSampleSource<ArrayAudioSampleSource>

    private func read(_ source: Dithered, offset: Int, count: Int) throws -> [Float] {
        var samples = [Float](repeating: 0, count: count)
        try samples.withUnsafeMutableBufferPointer {
            try source.copySamples(into: $0.baseAddress!, offset: offset, count: count)
        }
        return samples
    }

    func testDigitalSilenceHasNoExactZeroLeft() throws {
        let source = Dithered(base: ArrayAudioSampleSource(samples: [Float](repeating: 0, count: 48_000)))

        let samples = try read(source, offset: 0, count: 48_000)

        XCTAssertFalse(samples.contains(0))
        XCTAssertTrue(samples.allSatisfy { abs($0) <= Dithered.amplitude })
    }

    func testNoiseIsInaudibleAndCentered() throws {
        let source = Dithered(base: ArrayAudioSampleSource(samples: [Float](repeating: 0, count: 160_000)))

        let samples = try read(source, offset: 0, count: 160_000)
        let mean = samples.reduce(0, +) / Float(samples.count)
        let rms = (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()

        XCTAssertLessThan(abs(mean), Dithered.amplitude / 50)
        XCTAssertEqual(rms, Dithered.amplitude / Float(3).squareRoot(), accuracy: Dithered.amplitude / 50)
    }

    func testOverlappingReadsGetTheSameNoise() throws {
        let source = Dithered(base: ArrayAudioSampleSource(samples: [Float](repeating: 0, count: 1_000)))

        let whole = try read(source, offset: 0, count: 1_000)
        let tail = try read(source, offset: 600, count: 400)

        XCTAssertEqual(Array(whole[600...]), tail)
    }

    func testSpeechIsOnlyShiftedByTheNoise() throws {
        let speech = (0..<1_000).map { sin(Float($0) * 0.05) * 0.5 }
        let source = Dithered(base: ArrayAudioSampleSource(samples: speech))

        let samples = try read(source, offset: 0, count: 1_000)

        for (dithered, original) in zip(samples, speech) {
            XCTAssertEqual(dithered, original, accuracy: Dithered.amplitude)
        }
        XCTAssertEqual(source.sampleCount, speech.count)
    }
}
