import Foundation

/// An aligned read-through cache over another ``MediaByteSource``.
///
/// A parse issues many small reads clustered inside one or two regions — measured on a
/// 991-file corpus: HEIF takes 138 reads totalling 1,533 bytes inside a single 100 KB
/// region, TIFF 21 reads totalling 1,155 bytes inside 44 KB, ISO-BMFF 168 reads across
/// three regions. On a local file that pattern is free. On a remote transport it is the
/// whole cost: at 42.6 ms median latency, HEIF's 138 reads take ~5.9 s per file, which is
/// no faster than downloading the file outright. Served from one cached chunk, the same
/// parse costs 91 ms.
///
/// The pattern is the package's own, so the mitigation belongs here rather than in every
/// consumer that has to work around it. The *size* does not: useful chunk size depends on
/// transport latency and per-request overhead, which this type cannot see, so the consumer
/// supplies it. That split is the whole design — the package owns the mechanism, the
/// consumer owns the number.
///
/// A local-file consumer has no reason to use this. `FileByteSource` already sits on the
/// kernel's page cache, and wrapping it would just add a copy.
public final class CachingByteSource: MediaByteSource {
    public let size: UInt64

    private let upstream: MediaByteSource
    private let chunkSize: UInt64
    private var cachedChunkIndex: UInt64?
    private var cachedChunk: Data = .init()

    /// - Parameters:
    ///   - upstream: the transport to read through.
    ///   - chunkSize: bytes to fetch per upstream read. Sized by the consumer against its
    ///     own latency; 128 KB collapses a typical still-image parse into one fetch.
    ///     Values below 1 are treated as 1.
    public init(wrapping upstream: MediaByteSource, chunkSize: Int) {
        self.upstream = upstream
        self.chunkSize = UInt64(max(chunkSize, 1))
        size = upstream.size
    }

    public func data(offset: UInt64, length: Int) throws -> Data? {
        guard length >= 0, offset <= size, UInt64(length) <= size - offset else {
            return nil
        }
        guard length > 0 else {
            return Data()
        }
        // A request wider than one chunk would need multiple chunks stitched together for
        // no benefit — the caller already wants a large contiguous span, which is exactly
        // what the upstream does best. Pass it straight through.
        guard UInt64(length) <= chunkSize else {
            return try upstream.data(offset: offset, length: length)
        }
        let index = offset / chunkSize
        let start = index * chunkSize
        if cachedChunkIndex != index {
            // Clamped so the final chunk of the resource is an in-bounds request: an
            // over-long read at the tail is exactly the case the three-outcome contract
            // says returns nil, and a nil here would look like end-of-file to the caller
            // even though its own range was fine.
            let want = Int(min(chunkSize, size - start))
            guard let chunk = try upstream.data(offset: start, length: want) else {
                return nil
            }
            cachedChunk = chunk
            cachedChunkIndex = index
        }
        let localStart = Int(offset - start)
        let localEnd = localStart + length
        // A request straddling the chunk boundary is served from the upstream rather than
        // by fetching a second chunk, so one request never costs two round trips.
        guard localEnd <= cachedChunk.count else {
            return try upstream.data(offset: offset, length: length)
        }
        return cachedChunk.subdata(in: localStart ..< localEnd)
    }

    public func close() {
        cachedChunk = Data()
        cachedChunkIndex = nil
        upstream.close()
    }
}
