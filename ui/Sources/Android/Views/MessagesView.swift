import SwiftUI
import KDEConnectKit

struct MessagesView: View {
    let device: Device
    @State private var selected: Int64?
    @State private var search = ""
    @Environment(AppModel.self) private var model

    private var filtered: [SMSMessage] {
        let all = device.sortedConversations
        guard !search.isEmpty else { return all }
        return all.filter {
            device.displayName(for: $0.addresses).localizedCaseInsensitiveContains(search)
                || $0.body.localizedCaseInsensitiveContains(search)
                || $0.addresses.contains { $0.contains(search) }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            List(filtered, selection: $selected) { m in
                ConversationRow(device: device, message: m)
                    .tag(m.threadID)
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .frame(width: 300)
            .overlay {
                if device.conversations.isEmpty {
                    ProgressView("Loading conversations…")
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            Divider()
            Group {
                if let selected {
                    ThreadView(device: device, thread: selected)
                        .id(selected)
                } else {
                    ContentUnavailableView("No Conversation Selected", systemImage: "message",
                                           description: Text("Choose a conversation, or start a new one."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Messages")
        .searchable(text: $search, placement: .toolbar, prompt: "Search messages")
        .toolbar {
            ToolbarItem {
                Button { device.markAllRead() } label: { Label("Mark All as Read", systemImage: "envelope.open") }
                    .disabled(device.unreadCount == 0)
                    .help("Mark all conversations as read")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { model.composePrefill = ""; model.showCompose = true } label: { Label("New Message", systemImage: "square.and.pencil") }
            }
        }
        .sheet(isPresented: Binding(get: { model.showCompose }, set: { model.showCompose = $0 })) {
            ComposeSheet(device: device, prefill: model.composePrefill)
        }
    }
}

struct ConversationRow: View {
    let device: Device
    let message: SMSMessage
    var compact = false

    var body: some View {
        let name = device.displayName(for: message.addresses)
        HStack(spacing: 10) {
            ZStack(alignment: .topLeading) {
                Avatar(name: message.addresses.count > 1 ? "" : name,
                       photo: message.addresses.count == 1 ? device.contact(for: message.addresses[0])?.photo : nil,
                       size: compact ? 30 : 40)
                if device.isUnread(message) {
                    Circle().fill(.blue).frame(width: 9, height: 9).offset(x: -5, y: 2)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(name).font(compact ? .callout.weight(.medium) : .headline).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(message.date.conversationStamp).font(.caption).foregroundStyle(.secondary)
                }
                Text(preview)
                    .font(compact ? .caption : .callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(compact ? 1 : 2)
            }
        }
        .padding(.vertical, compact ? 1 : 4)
    }

    private var preview: String {
        let text = message.body.isEmpty && !message.attachments.isEmpty ? "Attachment" : message.body
        return (message.isIncoming ? "" : "You: ") + text
    }
}

private struct ThreadView: View {
    let device: Device
    let thread: Int64
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var messages: [SMSMessage] {
        (device.threads[thread]?.values.map { $0 } ?? []).sorted { $0.date < $1.date }
    }

    private var header: SMSMessage? { device.conversations[thread] }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 4) {
                    if device.loadingThreads.contains(thread) {
                        ProgressView().controlSize(.small).padding()
                    } else if messages.count >= 20 {
                        Button("Load Earlier Messages") { device.loadThread(thread, more: true) }
                            .buttonStyle(.link).padding(8)
                    }
                    ForEach(Array(messages.enumerated()), id: \.element.uID) { i, m in
                        if i == 0 || m.date.timeIntervalSince(messages[i - 1].date) > 3600 {
                            Text(m.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2).foregroundStyle(.secondary)
                                .padding(.top, 12).padding(.bottom, 4)
                        }
                        Bubble(device: device, message: m, showSender: (header?.addresses.count ?? 0) > 1)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .defaultScrollAnchor(.bottom)

            composer
        }
        .navigationSubtitle(header.map { device.displayName(for: $0.addresses) } ?? "")
        .toolbar {
            if let addresses = header?.addresses, addresses.count == 1, device.has("telephony"), device.supports("dial") {
                ToolbarItem {
                    Button { device.dial(addresses[0]); Notifier.shared.calling(addresses[0], device: device) } label: {
                        Label("Call", systemImage: "phone.fill")
                    }
                    .help("Call \(device.displayName(for: addresses)) from \(device.name)")
                }
            }
        }
        .onAppear {
            device.loadThread(thread)
            device.markRead(thread)
            focused = true
        }
        // New messages arriving while the conversation is open count as read.
        .onChange(of: header?.uID) { _, _ in device.markRead(thread) }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Text Message", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...6)
                .focused($focused)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(.background, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).strokeBorder(.separator))
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary : .blue)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(12)
        .background(.bar)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        device.sendMessage(text, thread: thread)
        draft = ""
    }
}

private struct Bubble: View {
    let device: Device
    let message: SMSMessage
    let showSender: Bool

    var body: some View {
        HStack {
            if !message.isIncoming { Spacer(minLength: 80) }
            VStack(alignment: message.isIncoming ? .leading : .trailing, spacing: 2) {
                if showSender && message.isIncoming, let a = message.addresses.first {
                    Text(device.contact(for: a)?.name ?? a).font(.caption2).foregroundStyle(.secondary).padding(.leading, 10)
                }
                ForEach(message.attachments) { att in
                    if let data = att.thumbnail, let img = NSImage(data: data) {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 220, maxHeight: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    } else {
                        Label(att.mimeType.isEmpty ? "Attachment" : att.mimeType, systemImage: "paperclip")
                            .font(.caption).padding(8)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                if !message.body.isEmpty {
                    Text(message.body)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .foregroundStyle(message.isIncoming ? Color.primary : .white)
                        .background(message.isIncoming ? AnyShapeStyle(.quaternary) : AnyShapeStyle(Color.blue.gradient),
                                    in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                        .help(message.date.formatted(date: .abbreviated, time: .shortened))
                }
                if message.isFailed {
                    Label("Not Delivered", systemImage: "exclamationmark.circle.fill").font(.caption2).foregroundStyle(.red)
                } else if message.isPending {
                    Text("Sending…").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if message.isIncoming { Spacer(minLength: 80) }
        }
    }
}

/// State of the New Message sheet (a class so the developer probe can observe it).
@MainActor @Observable
final class ComposeModel {
    @ObservationIgnored static weak var current: ComposeModel?
    struct Recipient: Identifiable, Hashable {
        let number: String
        let name: String?
        var id: String { ContactBook.key(for: number) }
    }
    struct Match: Identifiable {
        let contact: PhoneContact?
        let number: String
        var id: String { (contact?.id ?? "") + "|" + ContactBook.key(for: number) }
        var name: String { contact?.name ?? number }
    }
    var query = ""
    var recipients: [Recipient] = []
    var text = ""

    init() { Self.current = self }

    static func digits(_ s: String) -> String { s.filter(\.isNumber) }

    func matches(in device: Device) -> [Match] {
        let taken = Set(recipients.map(\.id))
        var seen = Set<String>()
        func add(_ m: Match, to list: inout [Match]) {
            let key = ContactBook.key(for: m.number)
            guard !key.isEmpty, !taken.contains(key), seen.insert(key).inserted else { return }
            list.append(m)
        }
        var out: [Match] = []
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            // Recent people from conversations.
            for m in device.sortedConversations where m.addresses.count == 1 {
                add(Match(contact: device.contact(for: m.addresses[0]), number: m.addresses[0]), to: &out)
                if out.count >= 8 { break }
            }
            return out
        }
        let qd = Self.digits(q)
        for c in device.contacts {
            let nameHit = c.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            for n in c.numbers where nameHit || (qd.count >= 3 && Self.digits(n).contains(qd)) {
                add(Match(contact: c, number: n), to: &out)
            }
            if out.count >= 40 { break }
        }
        return out
    }

    func pick(_ m: Match) {
        recipients.append(Recipient(number: m.number, name: m.contact?.name))
        query = ""
    }

    /// Return in the To field: a typed number is added as-is, otherwise the top match.
    func submitQuery(device: Device) {
        let q = query.trimmingCharacters(in: .whitespaces)
        if Self.digits(q).count >= 3, q.allSatisfy({ $0.isNumber || " +-()".contains($0) }) {
            recipients.append(Recipient(number: q, name: device.contact(for: q)?.name))
            query = ""
        } else if let first = matches(in: device).first {
            pick(first)
        }
    }
}

private struct ComposeSheet: View {
    let device: Device
    var prefill = ""
    @Environment(\.dismiss) private var dismiss
    @State private var compose = ComposeModel()
    @FocusState private var toFocused: Bool

    var body: some View {
        let matches = compose.matches(in: device)
        VStack(alignment: .leading, spacing: 12) {
            Text("New Message").font(.title2.weight(.semibold))

            // To: chips + search field
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("To:").foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(compose.recipients) { r in
                            HStack(spacing: 4) {
                                Text(r.name ?? r.number).lineLimit(1)
                                Button { compose.recipients.removeAll { $0.id == r.id } } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.janus.opacity(0.18), in: Capsule())
                        }
                        TextField(compose.recipients.isEmpty ? "Name or phone number" : "Add another", text: $compose.query)
                            .textFieldStyle(.plain)
                            .frame(minWidth: 160)
                            .focused($toFocused)
                            .onSubmit { compose.submitQuery(device: device) }
                    }
                }
            }
            .padding(8)
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))

            // Results
            VStack(alignment: .leading, spacing: 4) {
                Text(compose.query.isEmpty ? "Recent" : "Contacts").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(matches) { m in
                            MatchRow(match: m) { compose.pick(m); toFocused = true }
                        }
                    }
                }
                .frame(height: 180)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    if matches.isEmpty {
                        Text(compose.query.isEmpty ? "Type a name or number" : "No matching contacts. Press Return to use “\(compose.query)”.")
                            .font(.callout).foregroundStyle(.secondary).padding()
                    }
                }
            }

            TextEditor(text: $compose.text)
                .font(.body)
                .frame(minHeight: 90)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Send") {
                    device.sendMessage(compose.text, to: compose.recipients.map(\.number))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(compose.recipients.isEmpty || compose.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            compose.query = prefill
            toFocused = true
        }
    }
}

private struct MatchRow: View {
    let match: ComposeModel.Match
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Avatar(name: match.name, photo: match.contact?.photo, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(match.name).lineLimit(1)
                    if match.contact != nil {
                        Text(match.number).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Color.janus.opacity(0.15) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
