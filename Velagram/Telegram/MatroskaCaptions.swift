import Foundation

struct MatroskaCaptionTrack: Sendable {
    let number: Int
    let codec: String
}

/// Reads text captions from already cached Matroska clusters. It never starts a
/// second download or decodes video/audio, and bounds every read and EBML span.
actor MatroskaCaptionCache {
    private var tracks: [MatroskaCaptionTrack] = []
    private var scale: Double = 1_000_000
    private var parsed = Set<Int64>()
    private var lastWindow: String?
    private var cues: [Int: [SubtitleCue]] = [:]
    func captions(path: String, offset: Int64, prefix: Int64, position: Double, trackIndex: Int) throws -> [SubtitleCue]? {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path)); defer { try? handle.close() }
        if tracks.isEmpty {
            let header = try handle.read(upToCount: 2_097_152) ?? Data()
            parseHeader(header)
        }
        guard tracks.indices.contains(trackIndex) else { return nil }
        let track = tracks[trackIndex]
        guard ["S_TEXT/UTF8", "S_TEXT/ASS", "S_TEXT/SSA", "S_TEXT/WEBVTT"].contains(track.codec) else { return nil }
        let start = max(0, offset + max(0, prefix - 8_388_608))
        let window = "\(start):\(prefix)"
        if lastWindow != window {
        lastWindow = window
        try handle.seek(toOffset: UInt64(start))
        let data = try handle.read(upToCount: Int(min(8_388_608, max(0, prefix)))) ?? Data()
        ingest(data, fileOffset: start)
        // Header/startup clusters may still contain the current caption after
        // a tail/index probe moves TDLib's active download window.
        if offset > 0, position < 120 {
            try handle.seek(toOffset: 0)
            ingest(try handle.read(upToCount: 4_194_304) ?? Data(), fileOffset: 0)
        }
        }
        for key in cues.keys { cues[key]?.removeAll { $0.endTime < position - 120 } }
        let result = (cues[track.number] ?? []).sorted { $0.startTime < $1.startTime }
        return Array(result.suffix(4000))
    }
    private func parseHeader(_ data: Data) {
        for element in Self.elements(data, range: 0..<data.count) where element.id == 0x18538067 {
            for child in Self.elements(data, range: element.payload) {
                if child.id == 0x1549A966 {
                    for value in Self.elements(data, range: child.payload) where value.id == 0x2AD7B1 { scale = Double(Self.uint(data, value.payload)) }
                }
                if child.id == 0x1654AE6B {
                    for entry in Self.elements(data, range: child.payload) where entry.id == 0xAE {
                        let fields = Self.elements(data, range: entry.payload)
                        guard let type = fields.first(where: { $0.id == 0x83 }), Self.uint(data, type.payload) == 17,
                              let number = fields.first(where: { $0.id == 0xD7 }), let codec = fields.first(where: { $0.id == 0x86 }) else { continue }
                        let trackNumber = Self.uint(data, number.payload)
                        guard trackNumber > 0, trackNumber <= UInt64(Int.max) else { continue }
                        tracks.append(.init(number: Int(trackNumber), codec: String(decoding: data[codec.payload], as: UTF8.self)))
                    }
                }
            }
        }
    }
    private func ingest(_ data: Data, fileOffset: Int64) {
        let marker = Data([0x1F, 0x43, 0xB6, 0x75])
        var cursor = 0
        while cursor < data.count, let match = data.range(of: marker, in: cursor..<data.count) {
            cursor = match.upperBound
            guard let cluster = Self.element(data, at: match.lowerBound, limit: data.count), cluster.id == 0x1F43B675 else { continue }
            let children = Self.elements(data, range: cluster.payload)
            guard let timestamp = children.first(where: { $0.id == 0xE7 }) else { continue }
            let base = Double(Self.uint(data, timestamp.payload))
            for child in children {
                if child.id == 0xA3 { parseBlock(data, child, clusterTime: base, duration: nil, fileOffset: fileOffset) }
                if child.id == 0xA0 {
                    let group = Self.elements(data, range: child.payload)
                    let duration = group.first(where: { $0.id == 0x9B }).map { Double(Self.uint(data, $0.payload)) * scale / 1_000_000_000 }
                    if let block = group.first(where: { $0.id == 0xA1 }) { parseBlock(data, block, clusterTime: base, duration: duration, fileOffset: fileOffset) }
                }
            }
            // Partial final clusters are revisited when more cached data arrives.
            if cluster.end > match.lowerBound { cursor = cluster.end }
        }
    }
    private func parseBlock(_ data: Data, _ block: Element, clusterTime: Double, duration: Double?, fileOffset: Int64) {
        let key = fileOffset + Int64(block.payload.lowerBound)
        guard block.complete, !parsed.contains(key), let (number, width) = Self.vint(data, at: block.payload.lowerBound, keepMarker: false),
              let track = tracks.first(where: { $0.number == Int(number) }), block.payload.count > width + 3 else { return }
        let start = block.payload.lowerBound + width
        guard data[start + 2] & 0x06 == 0 else { return } // laced text needs a separate decoder
        let relative = Int16(bitPattern: UInt16(data[start]) << 8 | UInt16(data[start + 1]))
        let time = (clusterTime + Double(relative)) * scale / 1_000_000_000
        var text = String(decoding: data[(start + 3)..<block.payload.upperBound], as: UTF8.self)
        if track.codec == "S_TEXT/ASS" || track.codec == "S_TEXT/SSA" {
            let fields = text.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
            if fields.count == 9 { text = String(fields[8]) }
            text = text.replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\N"#, with: "\n").replacingOccurrences(of: #"\n"#, with: "\n")
        }
        text = text.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        parsed.insert(key)
        cues[track.number, default: []].append(.init(startTime: max(0, time), endTime: max(0, time) + max(0.1, duration ?? 3), text: text))
    }
    private struct Element { let id: UInt64; let payload: Range<Int>; let end: Int; let complete: Bool }
    private static func vint(_ data: Data, at index: Int, keepMarker: Bool) -> (UInt64, Int)? {
        guard index >= 0, index < data.count, data[index] != 0 else { return nil }
        var mask: UInt8 = 0x80; var width = 1
        while data[index] & mask == 0 { mask >>= 1; width += 1 }
        guard width <= 8, index + width <= data.count else { return nil }
        var value = UInt64(keepMarker ? data[index] : data[index] & ~mask)
        for i in 1..<width { value = (value << 8) | UInt64(data[index + i]) }
        return (value, width)
    }
    private static func element(_ data: Data, at index: Int, limit: Int) -> Element? {
        guard let (id, a) = vint(data, at: index, keepMarker: true), let (size, b) = vint(data, at: index + a, keepMarker: false) else { return nil }
        let start = index + a + b
        guard start <= limit else { return nil }
        let end = start + Int(min(size, UInt64(limit - start)))
        return Element(id: id, payload: start..<end, end: end, complete: size <= UInt64(limit - start))
    }
    private static func elements(_ data: Data, range: Range<Int>) -> [Element] {
        var result: [Element] = []; var cursor = range.lowerBound
        while cursor < range.upperBound, result.count < 100_000, let next = element(data, at: cursor, limit: range.upperBound), next.end > cursor {
            result.append(next); cursor = next.end
        }
        return result
    }
    private static func uint(_ data: Data, _ range: Range<Int>) -> UInt64 {
        guard range.count <= 8 else { return 0 }
        return data[range].reduce(0) { ($0 << 8) | UInt64($1) }
    }
}
