import AppKit

/// Chromium's `org.chromium.web-custom-data` pasteboard format (a base::Pickle):
/// uint32 payload size, uint32 entry count, then (type, value) pairs of string16 —
/// each a uint32 UTF-16 length + UTF-16LE code units, padded to 4 bytes.
enum ChromiumCustomData {
    static func decode(_ data: Data) -> [String: String]? {
        let bytes = [UInt8](data)
        var offset = 0

        func readUInt32() -> Int? {
            guard offset + 4 <= bytes.count else { return nil }
            defer { offset += 4 }
            return Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
                | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
        }
        func readString16() -> String? {
            guard let length = readUInt32(), offset + length * 2 <= bytes.count else { return nil }
            let units = (0..<length).map { UInt16(bytes[offset + $0 * 2]) | UInt16(bytes[offset + $0 * 2 + 1]) << 8 }
            offset += (length * 2 + 3) & ~3
            return String(utf16CodeUnits: units, count: units.count)
        }

        guard readUInt32() != nil, let count = readUInt32(), count < 1000 else { return nil }
        var entries: [String: String] = [:]
        for _ in 0..<count {
            guard let type = readString16(), let value = readString16() else { return nil }
            entries[type] = value
        }
        return entries
    }

    static func encode(_ entries: [(String, String)]) -> Data {
        var payload = Data()
        func appendUInt32(_ value: Int) {
            withUnsafeBytes(of: UInt32(value).littleEndian) { payload.append(contentsOf: $0) }
        }
        func appendString16(_ string: String) {
            let units = Array(string.utf16)
            appendUInt32(units.count)
            for unit in units { withUnsafeBytes(of: unit.littleEndian) { payload.append(contentsOf: $0) } }
            if units.count % 2 == 1 { payload.append(contentsOf: [0, 0]) } // pad to 4 bytes
        }
        appendUInt32(entries.count)
        for (type, value) in entries {
            appendString16(type)
            appendString16(value)
        }
        var data = Data()
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { data.append(contentsOf: $0) }
        return data + payload
    }
}

/// Slack's composer content (`slack/texty`: a Quill delta). Mentions, links, code, emoji and
/// other embeds become one opaque placeholder; bold/italic/strike runs are wrapped in an
/// open and a close placeholder so their words can still be corrected.
struct SlackTexty: MaskedContent {
    let masked: String

    private enum Piece {
        case opaque([String: Any])            // re-inserted verbatim
        case open([String: Any])              // start of a formatted run (its attributes)
        case close
    }

    private let pieces: [Piece]
    private static let editableAttributes: Set<String> = ["bold", "italic", "strike", "underline"]

    init?(json: String) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let ops = object["ops"] as? [[String: Any]]
        else { return nil }

        var masked = ""
        var pieces: [Piece] = []
        for op in ops {
            let attributes = op["attributes"] as? [String: Any] ?? [:]
            guard let text = op["insert"] as? String else {
                masked += Placeholder.make(pieces.count)   // embed (emoji, file, …)
                pieces.append(.opaque(op))
                continue
            }
            if attributes.isEmpty {
                masked += text
            } else if Set(attributes.keys).isSubset(of: Self.editableAttributes), text != "\n" {
                masked += Placeholder.make(pieces.count) + text + Placeholder.make(pieces.count + 1)
                pieces.append(.open(attributes))
                pieces.append(.close)
            } else {
                masked += Placeholder.make(pieces.count)   // mention, link, code, list line, …
                pieces.append(.opaque(op))
            }
        }
        // A text-only delta has nothing to protect; plain text handling is enough.
        guard !pieces.isEmpty else { return nil }
        self.masked = masked
        self.pieces = pieces
    }

    func pasteboardContents(for corrected: String) -> [NSPasteboard.PasteboardType: Data]? {
        guard let (segments, tail) = Placeholder.split(corrected, count: pieces.count) else { return nil }

        var ops: [[String: Any]] = []
        var current: [String: Any]?
        func insert(_ text: String) {
            guard !text.isEmpty else { return }
            var op: [String: Any] = ["insert": text]
            if let current { op["attributes"] = current }
            ops.append(op)
        }
        for (prose, index) in segments {
            insert(prose)
            switch pieces[index] {
            case .opaque(let op): ops.append(op)
            case .open(let attributes): current = attributes
            case .close: current = nil
            }
        }
        insert(tail)

        guard let json = try? JSONSerialization.data(withJSONObject: ["ops": ops], options: .withoutEscapingSlashes),
              let texty = String(data: json, encoding: .utf8)
        else { return nil }
        let plain = plainText(from: corrected)
        let custom = ChromiumCustomData.encode([("public.utf8-plain-text", plain), ("slack/texty", texty)])
        return [.string: Data(plain.utf8), RichClipboard.chromiumCustomData: custom]
    }

    func plainText(from corrected: String) -> String {
        let ns = corrected as NSString
        var text = ""
        var cursor = 0
        for match in Placeholder.pattern.matches(in: corrected, range: NSRange(location: 0, length: ns.length)) {
            text += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            if let index = Int(ns.substring(with: match.range(at: 1))), pieces.indices.contains(index),
               case .opaque(let op) = pieces[index] {
                text += op["insert"] as? String ?? ""
            }
            cursor = NSMaxRange(match.range)
        }
        return (text + ns.substring(from: cursor)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
