import Foundation

public struct PhoneContact: Sendable, Identifiable {
    public let id: String
    public let name: String
    public let numbers: [String]
    public let photo: Data?
}

/// Reads the vCards KDE Connect's contacts plugin syncs from the phone.
public enum ContactBook {
    public static func directory(forDevice id: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("kpeoplevcard/kdeconnect-\(id)", isDirectory: true)
    }

    public static func load(deviceID: String) -> [PhoneContact] {
        let dir = directory(forDevice: deviceID)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "vcf" }.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return parse(text, id: url.deletingPathExtension().lastPathComponent)
        }
    }

    /// The last 7 digits, Android's own minimum for matching a number with or without its country and area code
    /// ("+45 12 34 56 78" and "12345678"; "+1 415 555 0134" and "4155550134"). Numbers sharing it are told apart by
    /// `sameNumber`.
    public static func key(for number: String) -> String {
        String(number.filter(\.isNumber).suffix(7))
    }

    /// Whether two numbers are the same line: one's digits end with the other's (country and trunk prefixes
    /// dropped), at least 7 of them. Short codes (under 7 digits) must match exactly.
    public static func sameNumber(_ a: String, _ b: String) -> Bool {
        var x = a.filter(\.isNumber), y = b.filter(\.isNumber)
        if x.count < y.count { swap(&x, &y) }
        guard y.count >= 7 else { return x == y }
        // "0" trunk prefixes ("0555 12 34 56" vs "+1 202 555 0143").
        let shorter = y.hasPrefix("0") ? String(y.dropFirst()) : y
        return x.hasSuffix(shorter)
    }

    static func parse(_ text: String, id: String) -> PhoneContact? {
        // Unfold continuation lines (vCard 3/4: leading space; 2.1 quoted-printable: trailing "=").
        var lines: [String] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if (line.hasPrefix(" ") || line.hasPrefix("\t")), !lines.isEmpty {
                lines[lines.count - 1] += line.dropFirst()
            } else if let last = lines.last, last.hasSuffix("="), last.uppercased().contains("QUOTED-PRINTABLE") {
                lines[lines.count - 1] = String(last.dropLast()) + line
            } else {
                lines.append(line)
            }
        }
        var name = "", numbers: [String] = [], photo: Data?
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let params = line[..<colon].uppercased().split(separator: ";").map(String.init)
            var value = String(line[line.index(after: colon)...])
            if params.contains("ENCODING=QUOTED-PRINTABLE") { value = decodeQuotedPrintable(value) }
            switch params.first {
            case "FN": name = value
            case "N" where name.isEmpty:
                name = value.split(separator: ";").reversed().filter { !$0.isEmpty }.joined(separator: " ")
            case "TEL": if !value.isEmpty { numbers.append(value) }
            case "PHOTO":
                if let d = Data(base64Encoded: value, options: .ignoreUnknownCharacters) { photo = d }
            default: break
            }
        }
        guard !name.isEmpty || !numbers.isEmpty else { return nil }
        return PhoneContact(id: id, name: name.isEmpty ? numbers[0] : name, numbers: numbers, photo: photo)
    }

    static func decodeQuotedPrintable(_ s: String) -> String {
        var bytes: [UInt8] = []
        var it = Array(s.utf8)[...]
        while let c = it.popFirst() {
            if c == UInt8(ascii: "="), it.count >= 2,
               let v = UInt8(String(decoding: it.prefix(2), as: UTF8.self), radix: 16) {
                bytes.append(v); it = it.dropFirst(2)
            } else {
                bytes.append(c)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
