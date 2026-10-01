import FluidAudio
import Foundation

/// Adds inaudible uniform noise to every sample so Community-1 never sees exact
/// digital silence.
///
/// Community-1's FBank subtracts the mean log-mel over each 10 s window, and
/// exact zeros sit at the log floor. A window holding a little speech and a
/// muted remote track is dominated by those zeros, its embedding loses the
/// voice, and such windows gather into extra clusters that mix several people
/// (#1046, FluidAudio #981). On AMI with its non-speech zeroed, ±10 LSB of noise
/// restores the original speaker counts and confusion; on audio without
/// digital silence it costs about 0.2–0.5 pt DER.
///
/// The noise is a pure function of the absolute sample index, so overlapping
/// windows read identical samples and a recording always diarizes the same way.
struct DitheredAudioSampleSource<Base: AudioSampleSource>: AudioSampleSource {
    /// ±10 LSB of 16-bit audio, about −70 dBFS.
    static var amplitude: Float { 10 / 32_768 }

    let base: Base

    var sampleCount: Int { base.sampleCount }

    func copySamples(into destination: UnsafeMutablePointer<Float>, offset: Int, count: Int) throws {
        try base.copySamples(into: destination, offset: offset, count: count)
        for index in 0..<count {
            destination[index] += Self.noise(at: offset + index)
        }
    }

    /// Uniform in [−amplitude, amplitude), from a SplitMix64 hash of `index`.
    static func noise(at index: Int) -> Float {
        var z = UInt64(bitPattern: Int64(index)) &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        let unit = Float(z >> 40) / Float(1 << 24)
        return (unit * 2 - 1) * amplitude
    }
}
