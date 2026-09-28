import AppKit

/// Rich clipboard content with everything except the prose swapped for placeholders
/// (⟦0⟧, ⟦1⟧, …), so the model can only edit words — mentions and formatting survive.
protocol MaskedContent {
    /// Prose with placeholders — what gets sent to the model.
    var masked: String { get }
    /// Plain-text rendering of (corrected) masked text, for the panel.
    func plainText(from corrected: String) -> String
    /// What to put on the pasteboard for the corrected text, or nil if the model
    /// dropped, duplicated or reordered a placeholder (then nothing should be pasted).
    func pasteboardContents(for corrected: String) -> [NSPasteboard.PasteboardType: Data]?
}

enum RichClipboard {
    static let chromiumCustomData = NSPasteboard.PasteboardType("org.chromium.web-custom-data")

    /// Picks the richest format we know how to round-trip: Slack's editor data, then HTML.
    static func detect(_ pasteboard: NSPasteboard) -> MaskedContent? {
        if let data = pasteboard.data(forType: chromiumCustomData),
           let texty = ChromiumCustomData.decode(data)?["slack/texty"],
           let slack = SlackTexty(json: texty) {
            return slack
        }
        if let html = pasteboard.string(forType: .html), let masked = MaskedHTML(html: html) {
            return masked
        }
        return nil
    }
}

enum Placeholder {
    static let pattern = try! NSRegularExpression(pattern: "⟦(\\d+)⟧")

    static func make(_ index: Int) -> String { "⟦\(index)⟧" }

    /// Splits text into the prose before each placeholder, the placeholder index, and the tail.
    /// Returns nil unless the placeholders are exactly 0, 1, …, count-1 in order.
    static func split(_ text: String, count: Int) -> (segments: [(prose: String, index: Int)], tail: String)? {
        let ns = text as NSString
        var segments: [(String, Int)] = []
        var cursor = 0
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let index = Int(ns.substring(with: match.range(at: 1))) else { return nil }
            segments.append((ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)), index))
            cursor = NSMaxRange(match.range)
        }
        guard segments.map(\.1) == Array(0..<count) else { return nil }
        return (segments, ns.substring(from: cursor))
    }
}

/// Copied HTML with everything except the prose swapped for placeholders (⟦0⟧, ⟦1⟧, …),
/// so the model can only edit words. Mentions, links and code become one opaque
/// placeholder each; every other tag (<p>, <strong>, …) gets its own.
struct MaskedHTML: MaskedContent {
    let masked: String
    /// Raw HTML for each placeholder, by index.
    private let pieces: [String]

    private static let tagPattern = try! NSRegularExpression(pattern: "<!--[\\s\\S]*?-->|<[^>]*>")

    /// Elements kept verbatim: links, code, and anything that looks like a mention
    /// (Asana: data-asana-object; Slack and others: data-*mention*, data-stringify-type, …).
    private static let protectedNames: Set<String> = ["a", "code", "pre"]
    private static let protectedAttributes = try! NSRegularExpression(
        pattern: "data-(asana-object|object-id|mention|stringify-type|user-id|member-id)|class=\"[^\"]*mention",
        options: .caseInsensitive)
    private static let voidNames: Set<String> = [
        "br", "img", "meta", "hr", "input", "link", "wbr", "col", "source",
    ]

    init?(html: String) {
        let ns = html as NSString
        let tags = Self.tagPattern.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard !tags.isEmpty else { return nil }

        var masked = ""
        var pieces: [String] = []
        var cursor = 0
        var i = 0
        while i < tags.count {
            let tag = tags[i].range
            masked += Self.decodeEntities(ns.substring(with: NSRange(location: cursor, length: tag.location - cursor)))

            var end = NSMaxRange(tag)
            let tagText = ns.substring(with: tag)
            if let name = Self.openingName(tagText), Self.isProtected(name: name, tag: tagText),
               let close = Self.matchingClose(for: name, after: i, in: tags, ns) {
                end = NSMaxRange(tags[close].range) // swallow the whole element
                i = close
            }
            masked += Placeholder.make(pieces.count)
            pieces.append(ns.substring(with: NSRange(location: tag.location, length: end - tag.location)))
            cursor = end
            i += 1
        }
        masked += Self.decodeEntities(ns.substring(from: cursor))

        self.masked = masked
        self.pieces = pieces
    }

    func pasteboardContents(for corrected: String) -> [NSPasteboard.PasteboardType: Data]? {
        guard let (segments, tail) = Placeholder.split(corrected, count: pieces.count) else { return nil }
        let html = segments.map { Self.encodeEntities($0.prose) + pieces[$0.index] }.joined()
            + Self.encodeEntities(tail)
        return [.html: Data(html.utf8), .string: Data(plainText(from: corrected).utf8)]
    }

    func plainText(from corrected: String) -> String {
        let ns = corrected as NSString
        var text = ""
        var cursor = 0
        for match in Placeholder.pattern.matches(in: corrected, range: NSRange(location: 0, length: ns.length)) {
            text += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            if let index = Int(ns.substring(with: match.range(at: 1))), pieces.indices.contains(index) {
                text += Self.plainText(ofPiece: pieces[index])
            }
            cursor = NSMaxRange(match.range)
        }
        text += ns.substring(from: cursor)
        return text.replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Helpers

    private static func plainText(ofPiece piece: String) -> String {
        let lower = piece.lowercased()
        if lower.hasPrefix("<br") { return "\n" }
        if lower.range(of: "^</(p|div|li|h[1-6]|tr|blockquote)\\b", options: .regularExpression) != nil { return "\n" }
        let stripped = tagPattern.stringByReplacingMatches(
            in: piece, range: NSRange(location: 0, length: (piece as NSString).length), withTemplate: "")
        return decodeEntities(stripped)
    }

    /// Tag name for an opening, non-void, non-self-closing tag.
    private static func openingName(_ tag: String) -> String? {
        guard tag.hasPrefix("<"), !tag.hasPrefix("</"), !tag.hasPrefix("<!"), !tag.hasSuffix("/>") else { return nil }
        let name = tag.dropFirst().prefix { $0.isLetter || $0.isNumber }.lowercased()
        return name.isEmpty || voidNames.contains(name) ? nil : name
    }

    private static func isProtected(name: String, tag: String) -> Bool {
        protectedNames.contains(name) ||
            protectedAttributes.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) != nil
    }

    private static func matchingClose(for name: String, after start: Int, in tags: [NSTextCheckingResult],
                                      _ ns: NSString) -> Int? {
        var depth = 1
        for j in (start + 1)..<tags.count {
            let text = ns.substring(with: tags[j].range).lowercased()
            if text.hasPrefix("</\(name)") { depth -= 1 } else if openingName(text) == name { depth += 1 }
            if depth == 0 { return j }
        }
        return nil
    }

    private static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        for (entity, char) in [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"),
                               ("&apos;", "'"), ("&nbsp;", "\u{00A0}")] {
            out = out.replacingOccurrences(of: entity, with: char)
        }
        let numeric = try! NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);")
        for match in numeric.matches(in: out, range: NSRange(location: 0, length: (out as NSString).length)).reversed() {
            let ns = out as NSString
            let hex = ns.substring(with: match.range(at: 1)) == "x"
            if let code = UInt32(ns.substring(with: match.range(at: 2)), radix: hex ? 16 : 10),
               let scalar = Unicode.Scalar(code) {
                out = ns.replacingCharacters(in: match.range, with: String(Character(scalar)))
            }
        }
        return out.replacingOccurrences(of: "&amp;", with: "&") // last, so "&amp;lt;" stays "&lt;"
    }

    private static func encodeEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\u{00A0}", with: "&nbsp;")
    }
}
