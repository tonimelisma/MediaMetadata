import Foundation
import XCTest
@testable import MediaMetadata

/// Property/fuzz tests for the fail-closed contract: whatever bytes arrive, a parse must
/// return — never trap, never hang — and must respect its read caps. Inputs are random
/// bytes, random ISO BMFF box streams, and mutated/truncated copies of committed fixtures.
///
/// Everything is driven by a seeded PRNG so a failure reproduces exactly. If a case ever
/// crashes, the test process dies and the offending seed is in the failure output.
final class ParserRobustnessTests: XCTestCase {
    /// The documented single-read safety cap (also asserted by `RealFixtureGoldenTests`).
    private let maxReadLength = 1_048_576

    func testRandomBytesNeverCrashParsers() {
        var rng = SplitMix64(seed: 0xC0FFEE_1234_5678)
        for _ in 0..<3000 {
            let length = Int.random(in: 0...8192, using: &rng)
            var bytes = Data(count: length)
            for index in 0..<length {
                bytes[index] = UInt8.random(in: .min ... .max, using: &rng)
            }
            assertParseIsSafe(bytes, fileExtension: Self.extensions.randomElement(using: &rng)!, rng: rng)
        }
    }

    func testMalformedISOBoxStreamsNeverCrashParsers() {
        var rng = SplitMix64(seed: 0xBAD_F00D_0BAD_CAFE)
        for _ in 0..<3000 {
            var bytes = Data()
            for _ in 0..<Int.random(in: 0...14, using: &rng) {
                // Deliberately arbitrary size fields: 0 (to-end), tiny, and overruns.
                let size = UInt32.random(in: 0...0x0001_FFFF, using: &rng)
                bytes.append(contentsOf: withUnsafeBytes(of: size.bigEndian, Array.init))
                bytes.append(contentsOf: Self.boxTypes.randomElement(using: &rng)!)
                for _ in 0..<Int.random(in: 0...80, using: &rng) {
                    bytes.append(UInt8.random(in: .min ... .max, using: &rng))
                }
            }
            assertParseIsSafe(bytes, fileExtension: "heic", rng: rng)
        }
    }

    func testMutatedAndTruncatedFixturesNeverCrashParsers() throws {
        var rng = SplitMix64(seed: 0x5EED_0F_FACADE_01)
        let seeds = try smallCommittedFixtures()
        XCTAssertFalse(seeds.isEmpty, "expected at least one small committed fixture to mutate")
        for (name, seed) in seeds {
            let fileExtension = (name as NSString).pathExtension.lowercased()
            for _ in 0..<300 {
                var bytes = seed
                for _ in 0..<Int.random(in: 1...48, using: &rng) {
                    guard !bytes.isEmpty else { break }
                    bytes[Int.random(in: 0..<bytes.count, using: &rng)] = UInt8.random(in: .min ... .max, using: &rng)
                }
                if Bool.random(using: &rng), !bytes.isEmpty {
                    bytes = bytes.prefix(Int.random(in: 0..<bytes.count, using: &rng))
                }
                assertParseIsSafe(bytes, fileExtension: fileExtension, rng: rng)
            }
        }
    }

    func testMutatedAndTruncatedStillImagesNeverCrashParsers() {
        var rng = SplitMix64(seed: 0x9E3_79B9_7F4A_7C15)
        let exif = StillImageFixtures.standardExif()
        let seeds: [(String, Data)] = [
            ("png", StillImageFixtures.png(width: 64, height: 48, exif: exif)),
            ("png", StillImageFixtures.png(width: 64, height: 48, exif: StillImageFixtures.exifPrefix + exif)),
            ("webp", StillImageFixtures.webpExtended(width: 64, height: 48, exif: exif)),
            ("webp", StillImageFixtures.webpLossy(width: 64, height: 48)),
            ("webp", StillImageFixtures.webpLossless(width: 64, height: 48)),
            ("gif", StillImageFixtures.gif(width: 64, height: 48)),
        ]
        for (fileExtension, seed) in seeds {
            for _ in 0..<500 {
                var bytes = seed
                // Leave the signature intact half the time so the mutation reaches the parser.
                let firstMutable = Bool.random(using: &rng) ? min(12, bytes.count - 1) : 0
                for _ in 0..<Int.random(in: 1...24, using: &rng) {
                    bytes[Int.random(in: firstMutable..<bytes.count, using: &rng)] = UInt8.random(in: .min ... .max, using: &rng)
                }
                if Bool.random(using: &rng) {
                    bytes = bytes.prefix(Int.random(in: 0..<bytes.count, using: &rng))
                }
                assertParseIsSafe(bytes, fileExtension: fileExtension, rng: rng)
            }
        }
    }

    // MARK: - Invariants

    private func assertParseIsSafe(
        _ bytes: Data,
        fileExtension: String,
        rng: SplitMix64,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // Reaching here without trapping or hanging is most of the contract. The rest:
        // the parse never issues a single read larger than the documented cap, and a pure
        // in-memory source (which never throws) never yields a transient read failure.
        // (Reads past the end return nil and are expected for malformed input, so the
        // failed-read count is deliberately not asserted here.)
        let parsed = MediaMetadataReader.extract(source: InMemorySource(bytes: bytes), fileExtension: fileExtension)
        let seedInfo = "seed=\(rng.seed) ext=\(fileExtension) len=\(bytes.count)"
        XCTAssertLessThanOrEqual(parsed.readMetrics.largestReadLength, maxReadLength, seedInfo, file: file, line: line)
        XCTAssertNotEqual(ReadOutcome(parsed), .readFailure, seedInfo, file: file, line: line)
    }

    // MARK: - Fixtures

    private func smallCommittedFixtures() throws -> [(name: String, data: Data)] {
        let root = Self.fixturesURL
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else {
            return []
        }
        var result: [(String, Data)] = []
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            guard ["heic", "jpg", "jpeg", "mp4", "mov", "avi", "wav", "tiff"].contains(ext) else {
                continue
            }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            // Keep mutation cheap: small committed fixtures only.
            guard size > 0, size <= 262_144 else {
                continue
            }
            result.append((url.lastPathComponent, try Data(contentsOf: url)))
        }
        return result
    }

    private static let extensions = ["heic", "avif", "mp4", "mov", "tiff", "jpg", "png", "webp", "gif", "wav", "avi", "mp3", "bin", ""]

    private static let boxTypes: [[UInt8]] = [
        "ftyp", "meta", "moov", "trak", "mdia", "minf", "stbl", "udta", "mvhd", "mdhd",
        "tkhd", "hdlr", "stsd", "stts", "iprp", "ipco", "ipma", "pitm", "iloc", "iinf",
        "infe", "irot", "imir", "ispe", "colr", "pixi", "mdat", "uuid", "free", "\u{A9}day",
    ].map { Array($0.utf8) }

    private static let fixturesURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)
}

/// Deterministic generator (SplitMix64) so every fuzz case is reproducible from its seed.
private struct SplitMix64: RandomNumberGenerator {
    private(set) var seed: UInt64
    private var state: UInt64

    init(seed: UInt64) {
        self.seed = seed
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// A `MediaByteSource` backed by an in-memory `Data`, following the protocol's read table:
/// a zero-length read is satisfied with empty `Data`, a range past the end returns `nil`,
/// and it never throws (so any `.readFailure` outcome would be the parser's own doing).
private struct InMemorySource: MediaByteSource {
    let bytes: Data
    var size: UInt64 { UInt64(bytes.count) }

    func data(offset: UInt64, length: Int) throws -> Data? {
        guard length >= 0, offset <= UInt64(bytes.count) else {
            return nil
        }
        let start = Int(offset)
        let available = bytes.count - start
        guard length <= available else {
            return nil
        }
        return bytes.subdata(in: start..<(start + length))
    }

    func close() {}
}
