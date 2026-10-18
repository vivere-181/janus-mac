import AppKit
import Foundation

/// Finds one-time codes in SMS and notification text (wording in many languages) while ignoring amounts in any
/// currency, card numbers, dates and phone numbers.
enum CodeDetector {
    /// Candidates: 4–8 digits, or two 3-digit groups ("123 456", "123-456"), or G-123456 style (compiled once).
    private static let candidateRegex = try! NSRegularExpression(pattern: #"(?<![\w*+/$€£₾])(?<!\d[.,])(?:[A-Z]{1,3}-)?(\d{3}[ -]\d{3}|\d{4,8})(?!\w|[.,]\d|%|/\d|-\d|:\d)"#)
    /// Words that mark a message as carrying a one-time code.
    static let keywords: [String] = [
        "code", "passcode", "password", "otp", "pin", "verification", "verify", "security code",
        "confirmation", "authentication", "one-time", "one time", "login", "sign-in", "sign in",
        "კოდი", "კოდს", "ვერიფიკაცი", "დადასტურებ", "პაროლი", "ერთჯერადი",
        "код", "пароль", "подтвержд",
        "código", "codice", "kod", "kodu", "bestätigung", "bestaetigung", "kennwort", "contraseña", "senha",
        "mot de passe", "vérification", "verificatie", "weryfikac", "şifre", "doğrulama", "mã xác", "mã otp",
        "код", "підтвердж", "קוד", "رمز", "كود", "कोड", "ओटीपी", "验证码", "驗證碼", "校验码", "動態密碼", "认证码",
        "認証", "確認コード", "ワンタイム", "인증", "인증번호",
    ]

    /// Every place the keyword appears (a conversation's notification can hold several messages). Latin keywords
    /// count only as whole words ("pin" isn't "shopping", "code" isn't "barcode").
    private static func mentions(_ keyword: String, in lower: String) -> [Int] {
        var found: [Int] = []
        var search = lower.startIndex..<lower.endIndex
        let latin = keyword.unicodeScalars.allSatisfy { $0.isASCII }
        while let r = lower.range(of: keyword, range: search) {
            let beforeOK = r.lowerBound == lower.startIndex || !lower[lower.index(before: r.lowerBound)].isLetter
            let afterOK = r.upperBound == lower.endIndex || !lower[r.upperBound].isLetter
            if !latin || (beforeOK && afterOK) { found.append(NSRange(r, in: lower).location) }
            search = r.upperBound..<lower.endIndex
        }
        return found
    }

    static func code(in raw: String) -> String? {
        let text = raw.replacingOccurrences(of: "\u{00A0}", with: " ")
        let lower = text.lowercased()
        let keywordPositions = keywords.flatMap { mentions($0, in: lower) }
        guard !keywordPositions.isEmpty else { return nil }

        // Candidates: 4–8 digits, or two 3-digit groups ("123 456", "123-456"), or G-123456 style.
        let re = Self.candidateRegex
        let ns = text as NSString
        var best: (code: String, distance: Int)?
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let range = m.range(at: 1)
            let candidate = ns.substring(with: range).replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
            if isLikelyNotACode(candidate, in: ns, at: m.range) { continue }
            // Prefer the candidate closest to (ideally right after) a keyword; on a tie the later one, the newest
            // message (a conversation's notification lists its messages oldest first: "code 111111 … code 222222").
            let distance = keywordPositions.map { k in
                let d = range.location - k
                return d >= 0 ? d : -d * 3
            }.min() ?? Int.max
            if best == nil || distance <= best!.distance { best = (candidate, distance) }
        }
        return best?.code
    }

    /// ISO codes ("usd", "pln") and common local names for money.
    private static let currencyWords: Set<String> = Set(Locale.commonISOCurrencyCodes.map { $0.lowercased() })
        .union(["lari", "ლარი", "ლარ", "руб", "грн", "zł", "zl", "kr", "rs", "lei", "tl", "dh", "fr", "lira", "euro", "euros",
                "dollar", "dollars", "rupees", "yuan", "yen", "won", "baht", "peso", "pesos", "reais", "rand"])

    private static func isLikelyNotACode(_ digits: String, in text: NSString, at range: NSRange) -> Bool {
        // Years (1990 up to ten years ahead) are usually dates.
        if digits.count == 4, let n = Int(digits), (1990...(Calendar.current.component(.year, from: .now) + 10)).contains(n) { return true }
        // Money: a currency symbol (any: $ € ₹ ¥ ₾ …), an ISO code (USD, PLN…) or a local word right before or after.
        let before = text.substring(with: NSRange(location: max(0, range.location - 5), length: min(5, range.location))).lowercased()
        let afterStart = range.location + range.length
        let after = text.substring(with: NSRange(location: afterStart, length: min(5, text.length - afterStart))).lowercased()
        let isCurrencySymbol = { (c: Character) in c.unicodeScalars.contains { $0.properties.generalCategory == .currencySymbol } }
        if before.last(where: { !$0.isWhitespace }).map(isCurrencySymbol) == true
            || after.first(where: { !$0.isWhitespace }).map(isCurrencySymbol) == true { return true }
        let wordBefore = before.split(whereSeparator: { !$0.isLetter }).last.map(String.init) ?? ""
        let wordAfter = after.split(whereSeparator: { !$0.isLetter }).first.map(String.init) ?? ""
        if [wordBefore, wordAfter].contains(where: { Self.currencyWords.contains($0) }) { return true }
        // Part of a longer run of digit groups ("+1 555 123 4567", "4111 1111 1111 1111"): a phone or card number.
        let groupBefore = before.range(of: #"\d[ -]?$"#, options: .regularExpression) != nil
        let groupAfter = after.range(of: #"^[ -]?\d"#, options: .regularExpression) != nil
        if groupBefore || groupAfter { return true }
        // Long runs are more likely phone or account numbers.
        return digits.count > 8
    }
}

/// Tracks codes seen recently: de-duplicates (SMS + its notification), remembers the latest one,
/// and optionally copies it (clearing it again after two minutes if unchanged).
@MainActor
final class CodeCenter {
    static let shared = CodeCenter()
    private(set) var latest: (code: String, from: String, date: Date)?
    private var recent: [String: Date] = [:]
    /// Testing aid: codes announced, and whether to skip the alerts and clipboard.
    var announced: [String] = []
    var quiet = false

    static var autoCopy: Bool { UserDefaults.standard.bool(forKey: "codes.autoCopy") }
    static var enabled: Bool { UserDefaults.standard.object(forKey: "codes.enabled") as? Bool ?? true }

    /// Returns true if a new code was found and announced.
    @discardableResult
    func inspect(_ text: String, from sender: String, device: Device) -> Bool {
        guard Self.enabled, let code = CodeDetector.code(in: text) else { return false }
        let now = Date()
        recent = recent.filter { now.timeIntervalSince($0.value) < 180 }
        guard recent[code] == nil else { return false }
        recent[code] = now
        latest = (code, sender, now)
        announced.append(code)
        if quiet { return true }
        if Self.autoCopy { copy(code, autoClear: true) }
        Notifier.shared.verificationCode(code, from: sender, device: device, copied: Self.autoCopy)
        AppModel.shared.log(.info, "Verification code received from \(sender)")
        return true
    }

    func copy(_ code: String, autoClear: Bool) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(code, forType: .string)
        guard autoClear else { return }
        let change = pb.changeCount
        Task {
            try? await Task.sleep(for: .seconds(120))
            if pb.changeCount == change, pb.string(forType: .string) == code { pb.clearContents() }
        }
    }
}
