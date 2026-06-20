import Foundation

final class FileByteSource {
    let size: UInt64

    private let handle: FileHandle
    private var readOperationCount = 0
    private var failedReadOperationCount = 0
    private var byteRequestedCount: UInt64 = 0
    private var byteReadCount: UInt64 = 0
    private var successfulReadRanges: [Range<UInt64>] = []
    private var largestReadLength: Int = 0
    private var highestReadEndOffset: UInt64 = 0

    init(url: URL) throws {
        self.handle = try FileHandle(forReadingFrom: url)
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        self.size = UInt64(values.fileSize ?? 0)
    }

    func close() {
        try? handle.close()
    }

    func data(offset: UInt64, length: Int) throws -> Data? {
        readOperationCount += 1
        byteRequestedCount += UInt64(max(0, length))
        guard length >= 0,
              offset <= size,
              UInt64(length) <= size - offset else {
            failedReadOperationCount += 1
            return nil
        }
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: length)
        guard let data, data.count == length else {
            failedReadOperationCount += 1
            return nil
        }
        byteReadCount += UInt64(data.count)
        successfulReadRanges.append(offset..<(offset + UInt64(data.count)))
        largestReadLength = max(largestReadLength, data.count)
        highestReadEndOffset = max(highestReadEndOffset, offset + UInt64(data.count))
        return data
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
                current = current.lowerBound..<max(current.upperBound, range.upperBound)
            } else {
                total += current.upperBound - current.lowerBound
                current = range
            }
        }
        total += current.upperBound - current.lowerBound
        return total
    }
}
