import Foundation
import SwiftUI

/// Notification text as the phone's engine sends it: plain, or (group chats, some mail apps) simple HTML such as
/// `<b>~ M</b><br/>Hello`. Shown with its bold/italic/line breaks; plain wherever only text fits (system notifications,
/// code detection, previews). Text that only looks like a tag ("<3", "a<b") stays as it is.
enum NotificationText {
    private static let tagPattern = #"<(/?)(b|strong|i|em|u|s|strike|del|br|p|div|span|font|small|big|a|li|ul|ol|tt|code|blockquote)\b([^>]*)>"#
    private static let tagRegex = try! NSRegularExpression(pattern: tagPattern, options: [.caseInsensitive])

    static func isHTML(_ s: String) -> Bool {
        s.contains("<") && tagRegex.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    /// Bold, italic, underline, strikethrough, monospaced and links kept; breaks and paragraphs as line breaks.
    static func attributed(_ raw: String) -> AttributedString {
        guard isHTML(raw) else { return AttributedString(raw) }
        var out = AttributedString()
        var bold = 0, italic = 0, underline = 0, strike = 0, mono = 0
        var link: URL?
        let ns = raw as NSString
        var cursor = 0
        func append(_ text: String) {
            guard !text.isEmpty else { return }
            var piece = AttributedString(decodeEntities(text))
            var intent: InlinePresentationIntent = []
            if bold > 0 { intent.insert(.stronglyEmphasized) }
            if italic > 0 { intent.insert(.emphasized) }
            if strike > 0 { intent.insert(.strikethrough) }
            if mono > 0 { intent.insert(.code) }
            if !intent.isEmpty { piece.inlinePresentationIntent = intent }
            if underline > 0 { piece.underlineStyle = .single }
            if let link { piece.link = link }
            out += piece
        }
        func newline() {
            // No blank lines at the start or doubled up by <p> after <br>.
            guard !out.characters.isEmpty, out.characters.last != "\n" else { return }
            out += AttributedString("\n")
        }
        for m in tagRegex.matches(in: raw, range: NSRange(location: 0, length: ns.length)) {
            append(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)))
            cursor = m.range.upperBound
            let closing = ns.substring(with: m.range(at: 1)) == "/"
            let tag = ns.substring(with: m.range(at: 2)).lowercased()
            let d = closing ? -1 : 1
            switch tag {
            case "b", "strong": bold = max(0, bold + d)
            case "i", "em": italic = max(0, italic + d)
            case "u": underline = max(0, underline + d)
            case "s", "strike", "del": strike = max(0, strike + d)
            case "tt", "code": mono = max(0, mono + d)
            case "br": out += AttributedString("\n")
            case "p", "div", "blockquote", "ul", "ol": newline()
            case "li": if !closing { newline(); out += AttributedString("• ") }
            case "a":
                if closing { link = nil } else {
                    let attrs = ns.substring(with: m.range(at: 3))
                    if let r = attrs.range(of: #"href\s*=\s*["']([^"']+)["']"#, options: .regularExpression) {
                        let href = String(attrs[r]).replacingOccurrences(of: #"^href\s*=\s*["']|["']$"#, with: "", options: .regularExpression)
                        link = URL(string: decodeEntities(href))
                    }
                }
            default: break   // span, font, small, big: their text only
            }
        }
        append(ns.substring(from: cursor))
        // Trailing line breaks (a final <br/>) take room for nothing.
        while out.characters.last == "\n" { out.removeSubrange(out.index(beforeCharacter: out.endIndex)..<out.endIndex) }
        return out
    }

    /// The same text without markup.
    static func plain(_ raw: String) -> String {
        guard isHTML(raw) else { return raw }
        return String(attributed(raw).characters)
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        for (e, c) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'")] {
            out = out.replacingOccurrences(of: e, with: c)
        }
        // Numeric entities: &#128591; &#x1F64F;
        if let re = try? NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]+|[0-9]+);"#) {
            let ns = out as NSString
            var result = ""
            var last = 0
            for m in re.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let v = ns.substring(with: m.range(at: 1))
                let code = v.hasPrefix("x") ? UInt32(v.dropFirst(), radix: 16) : UInt32(v)
                result += code.flatMap(Unicode.Scalar.init).map { String(Character($0)) } ?? ns.substring(with: m.range)
                last = m.range.upperBound
            }
            out = result + ns.substring(from: last)
        }
        return out.replacingOccurrences(of: "&amp;", with: "&")
    }
}
