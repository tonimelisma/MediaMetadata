import Foundation

private let isoParserName = "MediaMetadata.ISOBMFFMetadataParser"
private let mdtaMetadataKeysOfInterest: Set<String> = [
    "com.apple.quicktime.creationdate",
    "com.apple.quicktime.location.date",
    "com.apple.quicktime.location.ISO6709",
    "samsung.android.utc_offset",
]

struct ISOBMFFMetadataParser {
    static let quickTimeEpoch = Date(timeIntervalSince1970: -2_082_844_800)
    private static let maxMetadataPayloadLength = 1_048_576
    private static let sonyUSMTUUID: [UInt8] = [
        0x55, 0x53, 0x4D, 0x54, 0x21, 0xD2, 0x4F, 0xCE,
        0xBB, 0x88, 0x69, 0x5C, 0xFA, 0xC9, 0xC7, 0x40,
    ]

    private struct Box {
        let start: UInt64
        let size: UInt64
        let typeBytes: [UInt8]
        let headerSize: UInt64

        var type: String {
            String(bytes: typeBytes, encoding: .isoLatin1) ?? ""
        }

        var payloadStart: UInt64 {
            start + headerSize
        }

        var end: UInt64 {
            start + size
        }

        var payloadLength: UInt64 {
            end - payloadStart
        }
    }

    private struct ItemExtent {
        let offset: UInt64
        let length: UInt64
    }

    private let source: FileByteSource
    private let url: URL
    private var brand: String?
    private var findings: [MetadataFinding] = []
    private var timestamps: [CaptureTimestampCandidate] = []
    private var locations: [CaptureLocationCandidate] = []
    private var camera: CameraMetadata?
    private var diagnostics: [MetadataDiagnostic] = []
    private var exifItemIDs = Set<UInt32>()
    private var itemExtents: [UInt32: [ItemExtent]] = [:]

    init(source: FileByteSource, url: URL) {
        self.source = source
        self.url = url
    }

    mutating func parse() -> MediaMetadataResult {
        walkChildren(start: 0, end: source.size, path: "iso")
        parseHEIFEXIFItems()
        return MediaMetadataResult(
            identity: FormatIdentity(
                family: inferredFamily(),
                observedExtension: url.pathExtension.lowercased(),
                detectedByMagic: true,
                brand: brand
            ),
            findings: findings,
            timestamps: timestamps,
            locations: locations,
            camera: camera,
            diagnostics: diagnostics,
            provenance: [
                ParserProvenance(parser: isoParserName, status: .parsed)
            ]
        )
    }

    private mutating func walkChildren(start: UInt64, end: UInt64, path: String) {
        var cursor = start
        while cursor + 8 <= end, let box = readBox(at: cursor, limit: end) {
            parse(box, path: "\(path).\(box.type)")
            guard box.end > cursor else {
                appendDiagnostic(code: "isoNonAdvancingBox", message: "ISO BMFF box \(box.type) did not advance the cursor.", byteRange: cursor..<min(cursor + 8, source.size))
                break
            }
            cursor = box.end
        }
    }

    private mutating func parse(_ box: Box, path: String) {
        switch box.type {
        case "ftyp":
            parseFileType(box, path: path)
        case "moov", "trak", "mdia", "minf", "dinf", "stbl", "edts", "iprp", "ipco", "ipma":
            walkChildren(start: box.payloadStart, end: box.end, path: path)
        case "udta":
            parseUserData(box, path: path)
        case "meta":
            parseMeta(box, path: path)
        case "mvhd", "tkhd", "mdhd":
            recordQuickTimeContainerCreationDate(box, path: path)
        case "uuid":
            parseUUID(box, path: path)
        default:
            break
        }
    }

    private mutating func parseFileType(_ box: Box, path: String) {
        guard let majorBrand = readASCIIString(offset: box.payloadStart, length: 4) else {
            return
        }
        brand = majorBrand
        appendFinding(namespace: "iso.ftyp", key: "majorBrand", value: majorBrand, sourcePath: "\(path).majorBrand", byteRange: box.payloadStart..<(box.payloadStart + 4))
    }

    private mutating func parseUserData(_ box: Box, path: String) {
        var cursor = box.payloadStart
        while cursor + 8 <= box.end, let child = readBox(at: cursor, limit: box.end) {
            if child.type == "meta" {
                parseMeta(child, path: "\(path).meta")
            } else if child.type == "uuid" {
                parseUUID(child, path: "\(path).uuid")
            } else if child.typeBytes == [0xA9, 0x78, 0x79, 0x7A] {
                parseOldStyleGPS(child, path: "\(path).gpsCoordinates")
            } else if child.typeBytes == [0xA9, 0x64, 0x61, 0x79] {
                for value in parseDataValues(child) {
                    if case let .string(rawValue) = value {
                        recordTimestamp(rawValue, role: .quickTimeContentCreateDate, namespace: "quicktime.udta", key: "contentCreateDate", sourcePath: "\(path).contentCreateDate")
                    }
                }
            }
            guard child.end > cursor else {
                break
            }
            cursor = child.end
        }
    }

    private mutating func parseMeta(_ box: Box, path: String) {
        var cursor = box.payloadStart
        if !startsWithChildBox(at: cursor, limit: box.end) {
            cursor += min(4, box.end - cursor)
        }

        var handlerType: String?
        var keys: [String] = [""]

        while cursor + 8 <= box.end, let child = readBox(at: cursor, limit: box.end) {
            switch child.type {
            case "hdlr":
                handlerType = parseMetaHandler(child)
            case "keys":
                keys = parseKeys(child)
            case "ilst":
                if handlerType == "mdta", keys.count > 1 {
                    parseMdtaItemList(child, keys: keys, path: "\(path).ilst")
                } else {
                    parseStandardItemList(child, path: "\(path).ilst")
                }
            case "idat":
                if handlerType == "nrtm" {
                    parseSonyNRTMDataBox(child, path: "\(path).idat")
                }
            case "xml ":
                if handlerType == "nrtm" {
                    parseSonyNRTMXMLBox(child, path: "\(path).xml")
                }
            case "iinf":
                parseItemInfo(child, path: "\(path).iinf")
            case "iloc":
                parseItemLocation(child, path: "\(path).iloc")
            case "meta":
                parseMeta(child, path: "\(path).meta")
            case "uuid":
                parseUUID(child, path: "\(path).uuid")
            default:
                break
            }
            guard child.end > cursor else {
                break
            }
            cursor = child.end
        }
    }

    private func parseMetaHandler(_ box: Box) -> String? {
        guard box.payloadStart + 12 <= box.end else {
            return nil
        }
        return readASCIIString(offset: box.payloadStart + 8, length: 4)
    }

    private func parseKeys(_ box: Box) -> [String] {
        guard box.payloadStart + 8 <= box.end,
              let entryCount = readUInt32(offset: box.payloadStart + 4),
              entryCount <= 10_000 else {
            return [""]
        }

        var keys = Array(repeating: "", count: Int(entryCount) + 1)
        var cursor = box.payloadStart + 8
        for index in 1...Int(entryCount) {
            guard cursor + 8 <= box.end,
                  let keySize = readUInt32(offset: cursor),
                  keySize >= 8,
                  cursor + UInt64(keySize) <= box.end else {
                break
            }
            let keyLength = UInt64(keySize) - 8
            if keyLength <= 1024,
               let key = readString(offset: cursor + 8, length: keyLength) {
                keys[index] = key
            }
            cursor += UInt64(keySize)
        }
        return keys
    }

    private mutating func parseMdtaItemList(_ box: Box, keys: [String], path: String) {
        var cursor = box.payloadStart
        while cursor + 8 <= box.end, let atom = readBox(at: cursor, limit: box.end) {
            let keyIndex = Int(Self.readUInt32(from: atom.typeBytes))
            if keyIndex > 0, keyIndex < keys.count {
                let key = keys[keyIndex]
                if mdtaMetadataKeysOfInterest.contains(key) {
                    for value in parseDataValues(atom) {
                        applyMdtaValue(value, key: key, path: "\(path).\(key)")
                    }
                }
            }
            guard atom.end > cursor else {
                break
            }
            cursor = atom.end
        }
    }

    private mutating func parseStandardItemList(_ box: Box, path: String) {
        var cursor = box.payloadStart
        while cursor + 8 <= box.end, let atom = readBox(at: cursor, limit: box.end) {
            if atom.typeBytes == [0xA9, 0x78, 0x79, 0x7A] {
                for value in parseDataValues(atom) {
                    if case let .string(rawValue) = value {
                        recordLocation(rawValue, namespace: "quicktime.ilst", key: "gpsCoordinates", sourcePath: "\(path).gpsCoordinates")
                    }
                }
            } else if atom.typeBytes == [0xA9, 0x64, 0x61, 0x79] {
                for value in parseDataValues(atom) {
                    if case let .string(rawValue) = value {
                        recordTimestamp(rawValue, role: .quickTimeContentCreateDate, namespace: "quicktime.ilst", key: "contentCreateDate", sourcePath: "\(path).contentCreateDate")
                    }
                }
            }
            guard atom.end > cursor else {
                break
            }
            cursor = atom.end
        }
    }

    private mutating func applyMdtaValue(_ value: MetadataValue, key: String, path: String) {
        switch key {
        case "com.apple.quicktime.creationdate":
            if case let .string(rawValue) = value {
                recordTimestamp(rawValue, role: .quickTimeCreationDate, namespace: "quicktime.mdta", key: key, sourcePath: path)
            }
        case "com.apple.quicktime.location.date":
            if case let .string(rawValue) = value {
                recordTimestamp(rawValue, role: .quickTimeLocationDate, namespace: "quicktime.mdta", key: key, sourcePath: path)
            }
        case "com.apple.quicktime.location.ISO6709":
            if case let .string(rawValue) = value {
                recordLocation(rawValue, namespace: "quicktime.mdta", key: key, sourcePath: path)
            }
        case "samsung.android.utc_offset":
            switch value {
            case let .string(rawValue):
                appendFinding(namespace: "quicktime.mdta", key: key, value: rawValue, sourcePath: path, byteRange: nil)
            case let .signed(rawValue):
                appendFinding(namespace: "quicktime.mdta", key: key, value: String(rawValue), sourcePath: path, byteRange: nil)
            case let .unsigned(rawValue):
                appendFinding(namespace: "quicktime.mdta", key: key, value: String(rawValue), sourcePath: path, byteRange: nil)
            }
        default:
            break
        }
    }

    private mutating func parseOldStyleGPS(_ box: Box, path: String) {
        let length = min(box.payloadLength, UInt64(Self.maxMetadataPayloadLength))
        guard let data = readData(offset: box.payloadStart, length: length) else {
            return
        }
        let text: String
        if data.count >= 4 {
            let textSize = Int(Self.readUInt16(from: data, offset: 0))
            if textSize > 0, textSize <= data.count - 4 {
                text = Self.decodeString(data.subdata(in: 4..<(4 + textSize))) ?? ""
            } else {
                text = Self.decodeString(data) ?? ""
            }
        } else {
            text = Self.decodeString(data) ?? ""
        }
        recordLocation(text, namespace: "quicktime.udta", key: "gpsCoordinates", sourcePath: path)
    }

    private func parseDataValues(_ atom: Box) -> [MetadataValue] {
        var values: [MetadataValue] = []
        var cursor = atom.payloadStart
        while cursor + 8 <= atom.end, let dataBox = readBox(at: cursor, limit: atom.end) {
            if dataBox.type == "data",
               dataBox.payloadStart + 8 <= dataBox.end {
                let typeIndicator = readUInt32(offset: dataBox.payloadStart) ?? 0
                let valueStart = dataBox.payloadStart + 8
                let valueLength = dataBox.end - valueStart
                if valueLength <= UInt64(Self.maxMetadataPayloadLength),
                   let data = readData(offset: valueStart, length: valueLength),
                   let value = Self.decodeMetadataValue(typeIndicator: typeIndicator, data: data) {
                    values.append(value)
                }
            }
            guard dataBox.end > cursor else {
                break
            }
            cursor = dataBox.end
        }
        return values
    }

    private mutating func parseSonyNRTMDataBox(_ box: Box, path: String) {
        guard box.payloadLength > 0,
              box.payloadLength <= UInt64(Self.maxMetadataPayloadLength),
              let data = readData(offset: box.payloadStart, length: box.payloadLength),
              let xml = Self.extractXMLString(from: data) else {
            return
        }
        applySonyNRTMMetadata(Self.parseSonyNRTMXML(xml), path: path)
    }

    private mutating func parseSonyNRTMXMLBox(_ box: Box, path: String) {
        let xmlPayloadStart = min(box.payloadStart + 4, box.end)
        let xmlPayloadLength = box.end - xmlPayloadStart
        guard xmlPayloadLength > 0,
              xmlPayloadLength <= UInt64(Self.maxMetadataPayloadLength),
              let data = readData(offset: xmlPayloadStart, length: xmlPayloadLength),
              let xml = Self.extractXMLString(from: data) else {
            return
        }
        applySonyNRTMMetadata(Self.parseSonyNRTMXML(xml), path: path)
    }

    private mutating func applySonyNRTMMetadata(_ metadata: SonyNRTMMetadata, path: String) {
        if let creationTimestamp = metadata.creationTimestamp {
            recordTimestamp(creationTimestamp, role: .quickTimeCreationDate, namespace: "sony.nrtm", key: "CreationDate", sourcePath: "\(path).CreationDate")
        }
        if let timeZone = metadata.timeZone {
            appendFinding(namespace: "sony.nrtm", key: "TimeZone", value: timeZone, sourcePath: "\(path).TimeZone", byteRange: nil)
        }
        if let latitude = metadata.latitude,
           let latitudeRef = metadata.latitudeRef,
           let longitude = metadata.longitude,
           let longitudeRef = metadata.longitudeRef,
           let parsedLatitude = Self.parseDMSCoordinate(latitude, ref: latitudeRef),
           let parsedLongitude = Self.parseDMSCoordinate(longitude, ref: longitudeRef) {
            let raw = "\(latitudeRef) \(latitude) \(longitudeRef) \(longitude)"
            let findingID = appendFinding(namespace: "sony.nrtm", key: "GPS", value: raw, sourcePath: "\(path).GPS", byteRange: nil)
            locations.append(
                CaptureLocationCandidate(
                    latitude: parsedLatitude,
                    longitude: parsedLongitude,
                    altitudeMeters: nil,
                    rawValue: raw,
                    source: "sony.nrtm.gps",
                    evidenceIDs: [findingID]
                )
            )
        }
        if let dateStamp = metadata.gpsDateStamp,
           let timeStamp = metadata.gpsTimeStamp,
           let date = Self.parseGPSDateTime(dateStamp: dateStamp, timeStamp: timeStamp) {
            let raw = "\(dateStamp) \(timeStamp)"
            let findingID = appendFinding(namespace: "sony.nrtm", key: "GPSTimestamp", value: raw, sourcePath: "\(path).GPSTimestamp", byteRange: nil)
            timestamps.append(
                CaptureTimestampCandidate(
                    role: .gps,
                    rawTimestamp: raw,
                    dateComponents: CaptureDateComponents.utcComponents(from: date),
                    instant: date,
                    offsetSeconds: 0,
                    authority: .absoluteInstant,
                    evidenceIDs: [findingID]
                )
            )
        }
    }

    private mutating func parseUUID(_ box: Box, path: String) {
        guard box.payloadStart + 16 <= box.end,
              let uuidData = readData(offset: box.payloadStart, length: 16) else {
            return
        }
        let uuid = Array(uuidData)
        guard uuid == Self.sonyUSMTUUID else {
            return
        }
        parseSonyUSMT(start: box.payloadStart + 16, end: box.end, path: path)
    }

    private mutating func parseSonyUSMT(start: UInt64, end: UInt64, path: String) {
        var cursor = start
        while cursor + 8 <= end, let child = readBox(at: cursor, limit: end) {
            if child.type == "MTDT" {
                parseSonyMTDT(child, path: "\(path).MTDT")
            }
            guard child.end > cursor else {
                break
            }
            cursor = child.end
        }
    }

    private mutating func parseSonyMTDT(_ box: Box, path: String) {
        guard box.payloadStart + 2 <= box.end,
              let entryCount = readUInt16(offset: box.payloadStart) else {
            return
        }
        var cursor = box.payloadStart + 2
        for _ in 0..<Int(entryCount) {
            guard cursor + 10 <= box.end,
                  let dataSize = readUInt16(offset: cursor),
                  dataSize >= 10,
                  cursor + UInt64(dataSize) <= box.end,
                  let dataType = readUInt32(offset: cursor + 2) else {
                break
            }
            let valueStart = cursor + 10
            if dataType == 0x000B,
               let rawTimeZone = readUInt16(offset: valueStart) {
                let minutes = Int(Int16(bitPattern: rawTimeZone))
                appendFinding(namespace: "sony.usmt", key: "TimeZone", value: String(minutes * 60), sourcePath: "\(path).TimeZone", byteRange: valueStart..<(valueStart + 2))
            }
            cursor += UInt64(dataSize)
        }
    }

    private mutating func parseItemInfo(_ box: Box, path: String) {
        guard let version = readUInt8(offset: box.payloadStart) else {
            return
        }
        var cursor = box.payloadStart + 4
        let entryCount: UInt32
        if version == 0 {
            guard let count = readUInt16(offset: cursor) else {
                return
            }
            entryCount = UInt32(count)
            cursor += 2
        } else {
            guard let count = readUInt32(offset: cursor) else {
                return
            }
            entryCount = count
            cursor += 4
        }
        guard entryCount <= 10_000 else {
            appendDiagnostic(code: "isoItemInfoLimitExceeded", message: "ISO BMFF item-info entry count exceeds the safety limit.", byteRange: box.start..<box.end)
            return
        }
        for _ in 0..<entryCount {
            guard cursor + 8 <= box.end,
                  let child = readBox(at: cursor, limit: box.end) else {
                break
            }
            if child.type == "infe" {
                parseItemInfoEntry(child, path: "\(path).infe")
            }
            cursor = child.end
        }
    }

    private mutating func parseItemInfoEntry(_ box: Box, path: String) {
        guard let version = readUInt8(offset: box.payloadStart) else {
            return
        }
        var cursor = box.payloadStart + 4
        guard version >= 2 else {
            return
        }
        let itemID: UInt32
        if version == 2 {
            guard let id = readUInt16(offset: cursor) else {
                return
            }
            itemID = UInt32(id)
            cursor += 2
        } else {
            guard let id = readUInt32(offset: cursor) else {
                return
            }
            itemID = id
            cursor += 4
        }
        cursor += 2
        guard cursor + 4 <= box.end,
              let itemType = readASCIIString(offset: cursor, length: 4) else {
            return
        }
        if itemType == "Exif" {
            exifItemIDs.insert(itemID)
            appendFinding(namespace: "iso.iinf", key: "itemType", value: "Exif", sourcePath: "\(path).\(itemID)", byteRange: cursor..<(cursor + 4))
        }
    }

    private mutating func parseItemLocation(_ box: Box, path: String) {
        guard let version = readUInt8(offset: box.payloadStart),
              let sizeBytePair = readUInt16(offset: box.payloadStart + 4) else {
            return
        }
        let offsetSize = Int((sizeBytePair >> 12) & 0x0F)
        let lengthSize = Int((sizeBytePair >> 8) & 0x0F)
        let baseOffsetSize = Int((sizeBytePair >> 4) & 0x0F)
        let indexSize = version == 1 || version == 2 ? Int(sizeBytePair & 0x0F) : 0
        var cursor = box.payloadStart + 6
        let itemCount: UInt32
        if version < 2 {
            guard let count = readUInt16(offset: cursor) else {
                return
            }
            itemCount = UInt32(count)
            cursor += 2
        } else {
            guard let count = readUInt32(offset: cursor) else {
                return
            }
            itemCount = count
            cursor += 4
        }
        guard itemCount <= 10_000 else {
            appendDiagnostic(code: "isoItemLocationLimitExceeded", message: "ISO BMFF item-location count exceeds the safety limit.", byteRange: box.start..<box.end)
            return
        }

        for _ in 0..<itemCount {
            let itemID: UInt32
            if version < 2 {
                guard let id = readUInt16(offset: cursor) else {
                    return
                }
                itemID = UInt32(id)
                cursor += 2
            } else {
                guard let id = readUInt32(offset: cursor) else {
                    return
                }
                itemID = id
                cursor += 4
            }
            var constructionMethod: UInt16 = 0
            if version == 1 || version == 2 {
                guard let raw = readUInt16(offset: cursor) else {
                    return
                }
                constructionMethod = raw & 0x000F
                cursor += 2
            }
            cursor += 2
            guard let baseOffset = readVariableInteger(offset: cursor, byteCount: baseOffsetSize) else {
                return
            }
            cursor += UInt64(baseOffsetSize)
            guard let extentCount = readUInt16(offset: cursor) else {
                return
            }
            cursor += 2
            var extents: [ItemExtent] = []
            for _ in 0..<extentCount {
                if indexSize > 0 {
                    cursor += UInt64(indexSize)
                }
                guard let extentOffset = readVariableInteger(offset: cursor, byteCount: offsetSize) else {
                    return
                }
                cursor += UInt64(offsetSize)
                guard let extentLength = readVariableInteger(offset: cursor, byteCount: lengthSize) else {
                    return
                }
                cursor += UInt64(lengthSize)
                if constructionMethod == 0 {
                    guard let absoluteOffset = checkedAdd(baseOffset, extentOffset) else {
                        appendDiagnostic(
                            code: "isoItemLocationExtentOverflow",
                            message: "ISO BMFF item-location extent offset overflowed UInt64.",
                            byteRange: box.start..<box.end
                        )
                        continue
                    }
                    extents.append(ItemExtent(offset: absoluteOffset, length: extentLength))
                }
            }
            if !extents.isEmpty {
                itemExtents[itemID] = extents
            }
        }
        appendFinding(namespace: "iso.iloc", key: "itemLocationCount", value: String(itemCount), sourcePath: path, byteRange: box.start..<box.end)
    }

    private mutating func parseHEIFEXIFItems() {
        for itemID in exifItemIDs.sorted() {
            guard let extents = itemExtents[itemID] else {
                appendDiagnostic(code: "heifExifItemMissingLocation", message: "HEIF EXIF item \(itemID) has no item-location extent.", byteRange: nil)
                continue
            }
            for extent in extents {
                guard extent.length > 0,
                      extent.length <= UInt64(Self.maxMetadataPayloadLength),
                      let tiffOffset = heifEXIFTIFFOffset(itemOffset: extent.offset, itemLength: extent.length) else {
                    appendDiagnostic(
                        code: "heifExifItemUnreadable",
                        message: "HEIF EXIF item \(itemID) did not contain a readable TIFF payload.",
                        byteRange: boundedRange(offset: extent.offset, length: extent.length)
                    )
                    continue
                }
                var parser = TIFFMetadataParser(source: source, url: url, baseOffset: tiffOffset, family: .heif)
                mergeEmbedded(result: parser.parse())
            }
        }
    }

    private func heifEXIFTIFFOffset(itemOffset: UInt64, itemLength: UInt64) -> UInt64? {
        let probeLength = Int(min(itemLength, 64))
        guard let itemEnd = checkedAdd(itemOffset, itemLength),
              let probe = readData(offset: itemOffset, length: UInt64(probeLength)) else {
            return nil
        }
        if probe.count >= 6,
           Data(probe[0..<6]) == Data([0x45, 0x78, 0x69, 0x66, 0x00, 0x00]),
           let tiffOffset = checkedAdd(itemOffset, 6),
           isTIFFHeader(at: tiffOffset) {
            return tiffOffset
        }
        if isTIFFHeader(at: itemOffset) {
            return itemOffset
        }
        if probe.count >= 4 {
            let offset = UInt64(Self.readUInt32(from: probe, offset: 0))
            let candidates = [
                checkedAdd(itemOffset, offset),
                checkedAdd(itemOffset, 4).flatMap { checkedAdd($0, offset) },
            ].compactMap { $0 }
            for candidate in candidates where candidate < itemEnd && isTIFFHeader(at: candidate) {
                return candidate
            }
        }
        return nil
    }

    private func boundedRange(offset: UInt64, length: UInt64) -> Range<UInt64>? {
        guard offset < source.size else {
            return nil
        }
        let end = checkedAdd(offset, length).map { min($0, source.size) } ?? source.size
        guard end >= offset else {
            return nil
        }
        return offset..<end
    }

    private func checkedAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64? {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? nil : sum
    }

    private func isTIFFHeader(at offset: UInt64) -> Bool {
        guard let header = readData(offset: offset, length: 4), header.count == 4 else {
            return false
        }
        return (header[0] == 0x49 && header[1] == 0x49 && header[2] == 0x2A && header[3] == 0x00)
            || (header[0] == 0x4D && header[1] == 0x4D && header[2] == 0x00 && header[3] == 0x2A)
    }

    private mutating func mergeEmbedded(result: MediaMetadataResult) {
        let idOffset = findings.count
        findings.append(
            contentsOf: result.findings.map { finding in
                MetadataFinding(
                    id: idOffset + finding.id,
                    namespace: finding.namespace,
                    key: finding.key,
                    rawValue: finding.rawValue,
                    parser: finding.parser,
                    sourcePath: finding.sourcePath,
                    byteRange: finding.byteRange
                )
            }
        )
        timestamps.append(
            contentsOf: result.timestamps.map { timestamp in
                CaptureTimestampCandidate(
                    role: timestamp.role,
                    rawTimestamp: timestamp.rawTimestamp,
                    dateComponents: timestamp.dateComponents,
                    instant: timestamp.instant,
                    offsetSeconds: timestamp.offsetSeconds,
                    authority: timestamp.authority,
                    evidenceIDs: timestamp.evidenceIDs.map { idOffset + $0 }
                )
            }
        )
        locations.append(contentsOf: result.locations)
        if camera == nil {
            camera = result.camera
        }
        diagnostics.append(contentsOf: result.diagnostics)
    }

    private mutating func recordQuickTimeContainerCreationDate(_ box: Box, path: String) {
        guard box.payloadStart + 8 <= box.end,
              let version = readUInt8(offset: box.payloadStart) else {
            return
        }
        let creationOffset = box.payloadStart + 4
        let seconds: UInt64?
        if version == 1,
           creationOffset + 8 <= box.end {
            seconds = readUInt64(offset: creationOffset)
        } else if version == 0,
                  creationOffset + 4 <= box.end,
                  let value = readUInt32(offset: creationOffset) {
            seconds = UInt64(value)
        } else {
            seconds = nil
        }
        guard let seconds,
              let date = Self.quickTimeDate(seconds: seconds) else {
            return
        }
        let findingID = appendFinding(namespace: "quicktime.container", key: box.type, value: String(seconds), sourcePath: path, byteRange: creationOffset..<min(creationOffset + (version == 1 ? 8 : 4), box.end))
        timestamps.append(
            CaptureTimestampCandidate(
                role: .quickTimeContainerCreationDate,
                rawTimestamp: String(seconds),
                dateComponents: CaptureDateComponents.utcComponents(from: date),
                instant: date,
                offsetSeconds: 0,
                authority: .absoluteInstant,
                evidenceIDs: [findingID]
            )
        )
    }

    private mutating func recordTimestamp(
        _ rawValue: String,
        role: CaptureTimestampCandidate.Role,
        namespace: String,
        key: String,
        sourcePath: String
    ) {
        let findingID = appendFinding(namespace: namespace, key: key, value: rawValue, sourcePath: sourcePath, byteRange: nil)
        if let parsed = Self.parseTimestampWithOffset(rawValue) {
            timestamps.append(
                CaptureTimestampCandidate(
                    role: role,
                    rawTimestamp: rawValue,
                    dateComponents: parsed.offsetKind == .utc ? CaptureDateComponents.utcComponents(from: parsed.instant) : parsed.localComponents,
                    instant: parsed.instant,
                    offsetSeconds: parsed.offsetKind.secondsFromGMT,
                    authority: parsed.offsetKind == .utc ? .absoluteInstant : .localWithOffset,
                    evidenceIDs: [findingID]
                )
            )
        } else if let components = Self.parseLocalTimestampComponents(rawValue) {
            timestamps.append(
                CaptureTimestampCandidate(
                    role: role,
                    rawTimestamp: rawValue,
                    dateComponents: components,
                    instant: nil,
                    offsetSeconds: nil,
                    authority: .localWithoutOffset,
                    evidenceIDs: [findingID]
                )
            )
        }
    }

    private mutating func recordLocation(
        _ rawValue: String,
        namespace: String,
        key: String,
        sourcePath: String
    ) {
        guard let location = Self.parseLocation(from: rawValue) else {
            return
        }
        let findingID = appendFinding(namespace: namespace, key: key, value: rawValue, sourcePath: sourcePath, byteRange: nil)
        locations.append(
            CaptureLocationCandidate(
                latitude: location.latitude,
                longitude: location.longitude,
                altitudeMeters: location.altitudeMeters,
                rawValue: rawValue,
                source: sourcePath,
                evidenceIDs: [findingID]
            )
        )
    }

    @discardableResult
    private mutating func appendFinding(
        namespace: String,
        key: String,
        value: String,
        sourcePath: String,
        byteRange: Range<UInt64>?
    ) -> Int {
        let id = findings.count
        findings.append(
            MetadataFinding(
                id: id,
                namespace: namespace,
                key: key,
                rawValue: value,
                parser: isoParserName,
                sourcePath: sourcePath,
                byteRange: byteRange
            )
        )
        return id
    }

    private mutating func appendDiagnostic(code: String, message: String, byteRange: Range<UInt64>?) {
        diagnostics.append(
            MetadataDiagnostic(
                severity: .warning,
                code: code,
                message: message,
                parser: isoParserName,
                byteRange: byteRange
            )
        )
    }

    private func inferredFamily() -> FormatIdentity.Family {
        let ext = url.pathExtension.lowercased()
        if ["heic", "heif", "hif", "avci", "avcs"].contains(ext) || ["heic", "heix", "hevc", "mif1", "msf1"].contains(brand ?? "") {
            return .heif
        }
        return .isoBMFF
    }

    private func startsWithChildBox(at offset: UInt64, limit: UInt64) -> Bool {
        guard let box = readBox(at: offset, limit: limit) else {
            return false
        }
        return box.size > 0 && box.end <= limit && box.type.isLikelyASCIIBoxType
    }

    private func readBox(at offset: UInt64, limit: UInt64) -> Box? {
        guard offset + 8 <= limit,
              let header = readData(offset: offset, length: 8) else {
            return nil
        }
        let size32 = Self.readUInt32(from: header, offset: 0)
        let typeBytes = Array(header[4..<8])
        var size = UInt64(size32)
        var headerSize: UInt64 = 8
        if size32 == 1 {
            guard offset + 16 <= limit,
                  let extendedHeader = readData(offset: offset, length: 16) else {
                return nil
            }
            size = Self.readUInt64(from: extendedHeader, offset: 8)
            headerSize = 16
        } else if size32 == 0 {
            size = limit - offset
        }
        guard size >= headerSize,
              offset + size <= limit else {
            return nil
        }
        return Box(start: offset, size: size, typeBytes: typeBytes, headerSize: headerSize)
    }

    private func readData(offset: UInt64, length: UInt64) -> Data? {
        guard length <= UInt64(Int.max) else {
            return nil
        }
        return try? source.data(offset: offset, length: Int(length))
    }

    private func readUInt8(offset: UInt64) -> UInt8? {
        readData(offset: offset, length: 1)?.first
    }

    private func readUInt16(offset: UInt64) -> UInt16? {
        readData(offset: offset, length: 2).map { Self.readUInt16(from: $0, offset: 0) }
    }

    private func readUInt32(offset: UInt64) -> UInt32? {
        readData(offset: offset, length: 4).map { Self.readUInt32(from: $0, offset: 0) }
    }

    private func readUInt64(offset: UInt64) -> UInt64? {
        readData(offset: offset, length: 8).map { Self.readUInt64(from: $0, offset: 0) }
    }

    private func readVariableInteger(offset: UInt64, byteCount: Int) -> UInt64? {
        guard byteCount >= 0, byteCount <= 8 else {
            return nil
        }
        if byteCount == 0 {
            return 0
        }
        guard let data = readData(offset: offset, length: UInt64(byteCount)) else {
            return nil
        }
        return data.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    private func readASCIIString(offset: UInt64, length: UInt64) -> String? {
        readData(offset: offset, length: length).flatMap {
            String(data: $0, encoding: .ascii)
        }
    }

    private func readString(offset: UInt64, length: UInt64) -> String? {
        readData(offset: offset, length: length).flatMap(Self.decodeString)
    }

    private static func readUInt16(from data: Data, offset: Int) -> UInt16 {
        UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
    }

    private static func readUInt32(from bytes: [UInt8]) -> UInt32 {
        bytes.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func readUInt32(from data: Data, offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func readUInt64(from data: Data, offset: Int) -> UInt64 {
        data[offset..<(offset + 8)].reduce(0) { ($0 << 8) | UInt64($1) }
    }

}

private extension String {
    var isLikelyASCIIBoxType: Bool {
        count == 4 && utf8.allSatisfy { byte in
            byte >= 0x20 && byte <= 0x7E
        }
    }
}

extension String {
    var isLikelyISOBoxType: Bool {
        count == 4 && utf8.allSatisfy { byte in
            (byte >= 0x20 && byte <= 0x7E) || (byte >= 0xA9 && byte <= 0xFF)
        }
    }
}
