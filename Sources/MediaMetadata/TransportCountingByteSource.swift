import Foundation

/// Counts reads that actually reach the underlying source.
///
/// Sits *below* the coalescing buffer so the two numbers on ``ReadCost`` mean different,
/// separately useful things: `readOperationCount` is what the parsers asked for, and
/// `transportReadCount` is what the transport was made to do. The ratio between them is the
/// answer to "is the buffering working", which previously could only be inferred by running
/// a parse twice with different wrappers and comparing.
final class TransportCountingByteSource: MediaByteSource {
    let size: UInt64

    private let upstream: MediaByteSource
    private(set) var transportReadCount = 0

    init(wrapping upstream: MediaByteSource) {
        self.upstream = upstream
        size = upstream.size
    }

    func data(offset: UInt64, length: Int) throws -> Data? {
        transportReadCount += 1
        return try upstream.data(offset: offset, length: length)
    }

    func close() {
        upstream.close()
    }
}
