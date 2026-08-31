import Foundation

/// A source of bytes that parsers read ranges from.
///
/// Parsing here is *directed*: a parser reads the container's own index, then reads exactly
/// the regions that index points at. Nothing in that depends on where the bytes live, so
/// this protocol is the only thing between the parsers and a local file, an in-memory
/// buffer, a zip member, an HTTP range request, or a camera reachable only over MTP.
///
/// ## Read contract
///
/// A read has three outcomes, and keeping them distinct is why this is a protocol with a
/// `throws` signature rather than a closure returning optional data:
///
/// | Situation | Result |
/// | --- | --- |
/// | Fully in-bounds range, every byte delivered | `Data` of exactly `length` |
/// | Range extends past `size` | `nil` |
/// | Fully in-bounds range that did not deliver `length` bytes | `throw` |
///
/// `nil` is a *structural* fact about the file — "there is nothing there". Throwing is a
/// fact about the transport — "I cannot tell you what is there". Collapsing the two is the
/// mistake this protocol exists to prevent: a caller that records "this file has no capture
/// date" when the truth was "the cable was pulled" has written a durable wrong answer, and
/// will not revisit it.
///
/// The distinction is not theoretical. `ICCameraFile.requestReadDataAtOffset` has been
/// observed calling its completion with a zero-byte `Data` and a nil error (Apple
/// FB7663947), and MTP's underlying `GetPartialObject` is an optional operation that some
/// devices fail by timeout. A conformance with only `nil` available would report every one
/// of those as absence.
///
/// ## Execution contract
///
/// Reads are synchronous and **may block the calling thread** for as long as the transport
/// takes — tens of milliseconds per read is normal for a remote source. Callers must run
/// parses off the main actor, and off any actor whose own progress the read depends on.
///
/// A source is confined to a single ``MediaMetadataReader/read(source:filenameHint:)`` call:
/// it must not escape that call, be stored beyond it, or be used concurrently. That
/// confinement is deliberate — it is what lets a conformance hold non-`Sendable` transport
/// state (a device handle, a socket) without an unsafe escape hatch, which matters in
/// codebases that forbid them outright.
public protocol MediaByteSource {
    /// Total size of the resource in bytes.
    ///
    /// A property of the source, not of a filesystem entry: a remote source reports what
    /// its own catalog says, and may have no path to stat.
    var size: UInt64 { get }

    /// Reads exactly `length` bytes at `offset`, per the table above.
    func data(offset: UInt64, length: Int) throws -> Data?

    /// Releases whatever the source holds. Called once, at the end of a parse.
    func close()
}

/// Why a fully in-bounds read did not deliver its bytes.
///
/// Distinct from returning `nil`, which means the range ran past the end of the resource.
/// Anything thrown from ``MediaByteSource/data(offset:length:)`` — including errors a
/// conformance defines itself — makes the resulting ``ReadOutcome`` `.readFailure`.
public enum MediaByteSourceError: Error, Equatable, Sendable {
    /// The range was inside the resource, but fewer bytes arrived than were asked for.
    ///
    /// The common shape of a transport failure that is not reported as one: a truncated
    /// response, a dropped connection, or a device that answers a range request with
    /// nothing at all.
    case shortRead(offset: UInt64, requested: Int, delivered: Int)

    /// The transport failed outright — disconnected, timed out, refused.
    case transportFailure(String)
}
