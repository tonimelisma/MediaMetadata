#!/usr/bin/env swift

import Foundation

private let fixturePaths = [
    "otos-catalog-state-robustness/Media/ios-heic-offset-date.heic",
    "otos-catalog-state-robustness/Media/jpeg-exif-offset-date.jpg",
    "otos-catalog-state-robustness/Media/mov-no-embedded-capture-date.mov",
    "otos-catalog-state-robustness/Media/mp4-no-embedded-capture-date.mp4",
    "videometa/IMG_5179.MOV",
    "videometa/apple.mov",
    "videometa/dji_inspire3_car_4k120_rec709.mov",
    "videometa/dji_ronin4d_4k_prores4444_25fps.mov",
    "videometa/exiftool_quicktime.mov",
    "videometa/google.mp4",
    "videometa/gopro_action.mp4",
    "videometa/minimal.mp4",
    "videometa/nonfaststart.mp4",
    "videometa/sony_a6700.mp4",
    "videometa/with_audio.mp4",
    "videometa/with_gps.mp4",
]

private let orderedValueSeparator = "\u{1F}"
private let scriptURL = URL(fileURLWithPath: #filePath)
private let repositoryURL = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
private let fixturesURL = repositoryURL.appendingPathComponent("Tests/Fixtures", isDirectory: true)

private struct CommandResult {
    let standardOutput: Data
    let standardError: Data
    let status: Int32
}

private enum GeneratorError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        switch self {
        case let .message(message):
            return message
        }
    }
}

private func run(_ executable: String, arguments: [String]) throws -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [executable] + arguments
    process.currentDirectoryURL = repositoryURL
    var environment = ProcessInfo.processInfo.environment
    environment["LC_ALL"] = "C"
    environment["TZ"] = "UTC"
    process.environment = environment

    let standardOutput = Pipe()
    let standardError = Pipe()
    process.standardOutput = standardOutput
    process.standardError = standardError
    try process.run()
    let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
    let error = standardError.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return CommandResult(standardOutput: output, standardError: error, status: process.terminationStatus)
}

private func exifTool(arguments: [String]) throws -> Data {
    let result = try run("exiftool", arguments: arguments)
    guard result.status == 0 else {
        let message = String(data: result.standardError, encoding: .utf8) ?? "unknown error"
        throw GeneratorError.message("ExifTool failed: \(message)")
    }
    return result.standardOutput
}

private func prettyJSON(_ object: Any) throws -> Data {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    return data + Data([0x0A])
}

private func groupedRecord(path: String, exifToolVersion: String) throws -> Data {
    let repositoryPath = "Tests/Fixtures/\(path)"
    let output = try exifTool(arguments: [
        "-a", "-n", "-json", "-G1",
        "--File:all", "--System:all", "--ExifTool:all",
        repositoryPath,
    ])
    guard let records = try JSONSerialization.jsonObject(with: output) as? [[String: Any]] else {
        throw GeneratorError.message("ExifTool returned an unexpected grouped JSON shape for \(path)")
    }
    return try prettyJSON([
        "schemaVersion": 1,
        "fixture": path,
        "exifToolVersion": exifToolVersion,
        "arguments": ["-a", "-n", "-json", "-G1", "--File:all", "--System:all", "--ExifTool:all"],
        "records": records,
    ])
}

private func orderedRecord(path: String, exifToolVersion: String) throws -> Data {
    let repositoryPath = "Tests/Fixtures/\(path)"
    let output = try exifTool(arguments: [
        "-a", "-n", "-G1", "-S", "-sep", orderedValueSeparator,
        "--File:all", "--System:all", "--ExifTool:all",
        repositoryPath,
    ])
    guard let text = String(data: output, encoding: .utf8) else {
        throw GeneratorError.message("ExifTool returned non-UTF-8 ordered output for \(path)")
    }

    var groups: [[String: Any]] = []
    var groupIndexes: [String: Int] = [:]
    for (lineIndex, rawLine) in text.split(whereSeparator: \Character.isNewline).enumerated() {
        let line = String(rawLine).trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("["),
              let groupEnd = line.firstIndex(of: "]") else {
            throw GeneratorError.message("Malformed ordered ExifTool line \(lineIndex + 1) for \(path)")
        }
        let group = String(line[line.index(after: line.startIndex)..<groupEnd])
        let payload = line[line.index(after: groupEnd)...].trimmingCharacters(in: .whitespaces)
        guard let separator = payload.firstIndex(of: ":") else {
            throw GeneratorError.message("Missing tag separator on ordered ExifTool line \(lineIndex + 1) for \(path)")
        }
        let tag = String(payload[..<separator]).trimmingCharacters(in: .whitespaces)
        let valueText = String(payload[payload.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
        let value: Any = valueText.contains(orderedValueSeparator)
            ? valueText.components(separatedBy: orderedValueSeparator)
            : valueText
        let tagRecord: [String: Any] = ["tag": tag, "value": value]

        if let groupIndex = groupIndexes[group] {
            var tags = groups[groupIndex]["tags"] as? [[String: Any]] ?? []
            tags.append(tagRecord)
            groups[groupIndex]["tags"] = tags
        } else {
            groupIndexes[group] = groups.count
            groups.append(["name": group, "tags": [tagRecord]])
        }
    }

    return try prettyJSON([
        "schemaVersion": 1,
        "fixture": path,
        "exifToolVersion": exifToolVersion,
        "arguments": ["-a", "-n", "-G1", "-S", "-sep", "U+001F", "--File:all", "--System:all", "--ExifTool:all"],
        "groups": groups,
    ])
}

private func write(_ data: Data, to url: URL) throws {
    try data.write(to: url, options: .atomic)
    print("generated \(url.path.replacingOccurrences(of: repositoryURL.path + "/", with: ""))")
}

do {
    let versionData = try exifTool(arguments: ["-ver"])
    guard let version = String(data: versionData, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        !version.isEmpty else {
        throw GeneratorError.message("Could not determine the ExifTool version")
    }

    for path in fixturePaths {
        let fixtureURL = fixturesURL.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw GeneratorError.message("Missing required local fixture: Tests/Fixtures/\(path)")
        }
        try write(try groupedRecord(path: path, exifToolVersion: version), to: URL(fileURLWithPath: fixtureURL.path + ".exiftool.json"))
        try write(try orderedRecord(path: path, exifToolVersion: version), to: URL(fileURLWithPath: fixtureURL.path + ".exiftool.ordered.json"))
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
