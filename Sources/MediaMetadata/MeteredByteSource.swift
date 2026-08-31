import Foundation

/// Wraps any ``MediaByteSource`` to do two jobs no conformance should have to do itself:
/// count what a parse actually read, and remember that a read failed.
///
/// **Counting** used to live on `FileByteSource`, which meant a custom source either
/// reimplemented byte accounting or silently reported nothing — and read metrics that only
/// work for one conformance are not read metrics. The package already knows every offset
/// and length it asked for, so it does the counting, once, here.
///
/// **Remembering** is what makes `.readFailure` reachable. Parsers read defensively with
/// `try?`, because a container legitimately points at ranges that are not there and a
/// parser must survive that. The cost is that a thrown transport error looks exactly like
/// a range past the end of the file, and the parse then reports a definitive "no metadata
/// present" for a file it never managed to read. Latching the first failure here lets
/// `extract` tell those apart afterwards without a single parser changing how it reads.
final class MeteredByteSource: MediaByteSource {
    let size: UInt64

    private let upstream: MediaByteSource
    private var readOperationCount = 0
    private var failedReadOperationCount = 0
    private var byteRequestedCount: UInt64 = 0
    private var byteReadCount: UInt64 = 0
    private var successfulReadRanges: [Range<UInt64>] = []
    private var largestReadLength: Int = 0
    private var highestReadEndOffset: UInt64 = 0
    private var latchedFailure: Error?

    init(wrapping upstream: MediaByteSource) {
        self.upstream = upstream
        size = upstream.size
    }

    /// The first read failure this parse hit, or nil if every read was answered.
    ///
    /// First rather than last: the earliest failure is the one that explains the shape of
    /// everything after it, since a parser that could not read an index goes on to make
    /// wrong-looking requests based on nothing.
    var readFailure: Error? { latchedFailure }

    func data(offset: UInt64, length: Int) throws -> Data? {
        readOperationCount += 1
        byteRequestedCount += UInt64(max(0, length))
        let data: Data?
        do {
            data = try upstream.data(offset: offset, length: length)
        } catch {
            failedReadOperationCount += 1
            if latchedFailure == nil {
                latchedFailure = error
            }
            // Returned as nil rather than rethrown so parsers keep their existing
            // defensive reads: the failure is recorded, not routed through nineteen
            // call sites that would each have to decide what to do with it.
            return nil
        }
        guard let data else {
            failedReadOperationCount += 1
            return nil
        }
        byteReadCount += UInt64(data.count)
        successfulReadRanges.append(offset ..< (offset + UInt64(data.count)))
        largestReadLength = max(largestReadLength, data.count)
        highestReadEndOffset = max(highestReadEndOffset, offset + UInt64(data.count))
        return data
    }

    func close() {
        upstream.close()
    }

    func readMetricsSnapshot() -> MediaMetadataReadMetrics.SourceReadMetrics {
        MediaMetadataReadMetrics.SourceReadMetrics(
            readOperationCount: readOperationCount,
            failedReadOperationCount: failedReadOperationCount,
            byteRequestedCount: byteRequestedCount,
            byteReadCount: byteReadCount,
            uniqueByteReadCount: Self.uniqueByteCount(in: successfulReadRanges),
            largestReadLength: largestReadLength,
            highestReadEndOffset: highestReadEndOffset
        )
    }

    private static func uniqueByteCount(in ranges: [Range<UInt64>]) -> UInt64 {
        guard !ranges.isEmpty else {
            return 0
        }
        let sortedRanges = ranges.sorted {
            if $0.lowerBound != $1.lowerBound {
                return $0.lowerBound < $1.lowerBound
            }
            return $0.upperBound < $1.upperBound
        }
        var total: UInt64 = 0
        var current = sortedRanges[0]
        for range in sortedRanges.dropFirst() {
            if range.lowerBound <= current.upperBound {
                current = current.lowerBound ..< max(current.upperBound, range.upperBound)
            } else {
                total += current.upperBound - current.lowerBound
                current = range
            }
        }
        total += current.upperBound - current.lowerBound
        return total
    }
}
