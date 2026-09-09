import Foundation

/// Where a voice sample was captured.
///
/// Embeddings only compare meaningfully inside one domain: the same person
/// heard over a compressed conference stream and over a local microphone lands
/// in different regions of the embedding space. Every stored sample carries its
/// domain so matching can prefer like-for-like references.
public enum SpeakerCaptureDomain: String, Sendable, Codable, CaseIterable {
    case system
    case microphone
    case file
}

/// Identifies the representation an embedding was produced in.
///
/// Two identifiers rather than one, because the vector FluidAudio hands back is
/// the VBx *clustering* centroid, not a raw model output. It therefore moves
/// when the clustering configuration moves, even if the embedding model itself
/// is untouched — a change that a model-only identifier would miss. See the
/// 2026-09-09 amendment to `plans/active/2026-07-03-speaker-voiceprints.md`.
public struct SpeakerModelIdentity: Sendable, Equatable, Hashable, Codable {
    /// The embedding model. A mismatch makes two vectors incomparable.
    public let embeddingModelId: String
    /// The aggregation configuration that produced the centroid. A mismatch is
    /// comparable but less trustworthy, so callers tighten their threshold.
    public let aggregationProfileId: String

    /// - Parameters:
    ///   - embeddingModelId: the model that produced the vector.
    ///   - aggregationProfileId: the clustering configuration that shaped the
    ///     centroid, so a configuration change is visible even when the model
    ///     is unchanged.
    public init(embeddingModelId: String, aggregationProfileId: String) {
        self.embeddingModelId = embeddingModelId
        self.aggregationProfileId = aggregationProfileId
    }
}

/// A speaker voice embedding, L2-normalized on construction.
///
/// Normalization happens here and nowhere else. FluidAudio's `speakerDatabase`
/// vectors are un-normalized centroids, and comparing them with a bare dot
/// product scales every distance by `‖a‖·‖b‖` — which silently pushes
/// same-speaker pairs past any calibrated threshold, with no error to observe.
/// Worse, the centroid norm shrinks as a cluster gets noisier, so the bias is
/// anti-correlated with signal quality. Normalizing at the boundary makes every
/// downstream comparison correct by construction.
public struct SpeakerEmbedding: Sendable, Equatable {
    /// WeSpeaker embedding width.
    public static let dimension = 256
    /// Serialized size: 256 × Float32.
    public static let byteCount = dimension * MemoryLayout<Float32>.size
    /// Below this, a vector carries no usable direction. FluidAudio emits an
    /// all-zero centroid when a cluster's responsibility denominator is zero.
    static let minimumNorm: Float = 1e-6
    /// Tolerance when re-reading a stored vector that is already normalized.
    static let normTolerance: Float = 1e-3

    /// Unit-length, `dimension` values.
    public let vector: [Float]
    public let identity: SpeakerModelIdentity

    /// Normalizes `rawVector`. Returns `nil` for the wrong width, non-finite
    /// values, or a vector too short to carry a direction.
    public init?(rawVector: [Float], identity: SpeakerModelIdentity) {
        guard rawVector.count == Self.dimension else { return nil }
        guard rawVector.allSatisfy(\.isFinite) else { return nil }

        let norm = Self.norm(of: rawVector)
        guard norm.isFinite, norm >= Self.minimumNorm else { return nil }

        self.vector = rawVector.map { $0 / norm }
        self.identity = identity
    }

    /// Rebuilds a vector previously produced by ``data``.
    ///
    /// Deliberately does not re-normalize: the bytes are already unit-length, and
    /// dividing again by a norm that floating-point rounding puts at 0.99999994
    /// would make a store/load round trip lossy. The norm is validated instead,
    /// so corruption is rejected rather than silently rescaled.
    public init?(data: Data, identity: SpeakerModelIdentity) {
        guard data.count == Self.byteCount else { return nil }

        var values = [Float]()
        values.reserveCapacity(Self.dimension)
        for index in 0..<Self.dimension {
            let start = data.startIndex + index * MemoryLayout<Float32>.size
            let bits = data[start..<start + MemoryLayout<Float32>.size]
                .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            values.append(Float(bitPattern: UInt32(littleEndian: bits)))
        }

        guard values.allSatisfy(\.isFinite) else { return nil }
        guard abs(Self.norm(of: values) - 1) <= Self.normTolerance else { return nil }

        self.vector = values
        self.identity = identity
    }

    /// Little-endian Float32, `byteCount` bytes. The stored form.
    public var data: Data {
        var output = Data(capacity: Self.byteCount)
        for value in vector {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { output.append(contentsOf: $0) }
        }
        return output
    }

    /// Cosine distance in FluidAudio's convention: 0 is identical, 1 is
    /// unrelated. Both operands are unit-length, so the dot product is the
    /// cosine and no rescaling is needed.
    ///
    /// Returns `nil` when the embedding models differ, since vectors from
    /// different models share no space. A differing aggregation profile is
    /// comparable and left to the caller's threshold policy.
    public func cosineDistance(to other: SpeakerEmbedding) -> Double? {
        guard identity.embeddingModelId == other.identity.embeddingModelId else { return nil }

        var dot: Float = 0
        for index in 0..<Self.dimension {
            dot += vector[index] * other.vector[index]
        }
        return 1 - Double(min(max(dot, -1), 1))
    }

    private static func norm(of values: [Float]) -> Float {
        var sumOfSquares: Float = 0
        for value in values {
            sumOfSquares += value * value
        }
        return sumOfSquares.squareRoot()
    }
}
