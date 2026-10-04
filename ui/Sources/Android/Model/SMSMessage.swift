import Foundation
import KDEConnectKit

/// One SMS/MMS as marshalled by KDE Connect: (i event, s body, a(s) addresses, x date, i type,
/// i read, x threadID, i uID, x subID, a(xsss) attachments).
struct SMSMessage: Identifiable, Equatable {
    struct Attachment: Equatable, Identifiable {
        let partID: Int64
        let mimeType: String
        let thumbnail: Data?
        let uniqueIdentifier: String
        var id: String { uniqueIdentifier + String(partID) }
    }

    let body: String
    let addresses: [String]
    let date: Date
    let type: Int
    let isRead: Bool
    let threadID: Int64
    let uID: Int32
    let attachments: [Attachment]

    var id: Int32 { uID }
    var isIncoming: Bool { type == 1 }
    var isFailed: Bool { type == 5 }
    var isPending: Bool { type == 4 || type == 6 }

    init?(_ value: DBusValue) {
        guard case .structure(let f) = value.unwrapped, f.count >= 8 else { return nil }
        body = f[1].string ?? ""
        addresses = f[2].array?.compactMap { $0.array?.first?.string } ?? []
        date = Date(timeIntervalSince1970: Double(f[3].int ?? 0) / 1000)
        type = f[4].int ?? 1
        isRead = (f[5].int ?? 1) != 0
        guard let thread = f[6].int, let uid = f[7].int else { return nil }
        threadID = Int64(thread)
        uID = Int32(truncatingIfNeeded: uid)
        attachments = (f.count > 9 ? f[9].array ?? [] : []).compactMap { a in
            guard let p = a.array, p.count >= 4 else { return nil }
            return Attachment(partID: Int64(p[0].int ?? 0), mimeType: p[1].string ?? "",
                              thumbnail: p[2].string.flatMap { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) },
                              uniqueIdentifier: p[3].string ?? "")
        }
    }
}
