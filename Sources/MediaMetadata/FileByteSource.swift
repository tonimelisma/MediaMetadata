import Foundation

/// A ``MediaByteSource`` over a local file.
///
/// Byte accounting used to live here; it now lives in `MeteredByteSource`, which wraps
/// every source so metrics work the same for a file, a network reader, or a test double.
/// What remains is the file-specific part: opening a handle, reporting the file's size, and
/// answering ranges.
final class FileByteSource: MediaByteSource {
    let size: UInt64

    private let handle: FileHandle

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        size = UInt64(values.fileSize ?? 0)
    }

    func close() {
        try? handle.close()
    }

    /// Three outcomes, per the ``MediaByteSource`` contract.
    ///
    /// A range past the end of the file is `nil` — a structural fact a parser is expected
    /// to handle, since containers do point at ranges that are not there. A range that is
    /// entirely inside the file but comes back short is a *throw*: the file said those
    /// bytes exist, so failing to read them is an I/O problem, not an absence, and
    /// reporting it as absence would let a truncated read masquerade as "no metadata".
    func data(offset: UInt64, length: Int) throws -> Data? {
        guard length >= 0, offset <= size, UInt64(length) <= size - offset else {
            return nil
        }
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: length)
        let delivered = data?.count ?? 0
        guard let data, delivered == length else {
            throw MediaByteSourceError.shortRead(offset: offset, requested: length, delivered: delivered)
        }
        return data
    }
}
