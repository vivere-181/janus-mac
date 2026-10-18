import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// Files through Janus Cloud (shared/CLOUD.md §6), like Blip: the offer goes out before the upload finishes, the
/// receiver downloads each chunk as it lands, 4 chunks in flight each way, every chunk retried until it's through.
@MainActor
final class CloudTransfers {
    static let shared = CloudTransfers()
    private let parallel = 4
    /// blob → our transfer in the feed (to mark it delivered).
    private var sentBlobs: [String: UUID] = [:]
    private var receiving: Set<String> = []
    /// One upload after another (the receiver can already be downloading the first).
    private var queue: Task<Void, Never>?

    // MARK: Sending

    func send(_ urls: [URL], to device: Device) {
        guard let peer = CloudService.shared.peer(forDevice: device.id) else { return }
        for url in urls {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            var t = Transfer(direction: .sent, kind: .file, deviceID: device.id, deviceName: device.name,
                             url: url, name: url.lastPathComponent, size: size)
            t.viaCloud = true
            t.note = "Waiting to send via Cloud"
            TransferStore.shared.add(t)
            let previous = queue
            queue = Task {
                await previous?.value
                await self.upload(url, transfer: t.id, to: peer)
            }
        }
    }

    private func upload(_ url: URL, transfer: UUID, to peer: CloudService.Peer) async {
        let store = TransferStore.shared, cloud = CloudService.shared
        func fail(_ note: String) { store.update(transfer) { $0.state = .failed; $0.note = note; $0.speed = 0 } }
        let fd = open(url.path, O_RDONLY)
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init), fd >= 0 else {
            if fd >= 0 { close(fd) }
            return fail("Couldn't read the file")
        }
        defer { close(fd) }
        let count = CloudCrypto.chunkCount(size: size), chunk = CloudCrypto.chunkSize
        let blob: String
        do {
            let (data, res) = try await cloud.call("POST", "/v1/blobs", json: ["to": peer.cloudID, "count": count, "size": CloudCrypto.encryptedSize(size: size)])
            if res.statusCode == 507 { return fail("Cloud storage is full. Try again later.") }
            guard res.statusCode == 200, let o = try JSONSerialization.jsonObject(with: data) as? [String: Any], let id = o["id"] as? String else {
                return fail("The relay answered \(res.statusCode)")
            }
            blob = id
        } catch {
            return fail("Couldn't reach Janus Cloud")
        }
        sentBlobs[blob] = transfer
        let fileKey = SymmetricKey(size: .bits256)
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        do {
            try await cloud.send("file", ["blob": blob, "name": url.lastPathComponent, "size": size, "mime": mime, "chunk": chunk,
                                          "count": count, "key": fileKey.withUnsafeBytes { Data($0) }.base64EncodedString()], to: peer)
        } catch {
            return fail("Couldn't reach Janus Cloud")
        }
        store.update(transfer) { $0.note = "Sending via Cloud"; $0.bytesDone = 0 }

        // Chunks go out 4 at a time, in order; each one retried until it's through.
        let started = Date()
        var done: Int64 = 0
        var next = 0
        var failed = false
        await withTaskGroup(of: Int64?.self) { group in
            func add() {
                guard next < count else { return }
                let i = next
                next += 1
                group.addTask {
                    // Read (positioned, safe in parallel) and encrypt off the main thread.
                    guard let plain = Self.read(fd, at: off_t(i) * off_t(chunk), count: chunk),
                          let sealed = try? CloudCrypto.sealChunk(plain, key: fileKey, blob: blob, index: i, count: count) else { return nil }
                    return await self.put(sealed, blob: blob, index: i) ? Int64(plain.count) : nil
                }
            }
            for _ in 0..<parallel { add() }
            while let result = await group.next() {
                guard let bytes = result else { failed = true; group.cancelAll(); break }
                done += bytes
                let elapsed = max(Date().timeIntervalSince(started), 0.001)
                store.update(transfer) { $0.bytesDone = done; $0.speed = Double(done) / elapsed }
                add()
            }
        }
        if failed {
            _ = try? await cloud.call("DELETE", "/v1/blobs/\(blob)")
            try? await cloud.send("file-cancel", ["blob": blob], to: peer)
            sentBlobs[blob] = nil
            return fail("Couldn't upload. Check the connection and send it again.")
        }
        // Uploaded: it waits in the cloud (up to 72 hours) until the phone takes it.
        store.update(transfer) { t in
            t.speed = 0
            // The phone may already have it all (it downloads while we upload): then "file-done" arrived first.
            if t.note != "Delivered" { t.state = .done; t.awaitingPickup = true; t.note = "Waiting for \(peer.name)" }
        }
    }

    /// PUT with retries: dropped connections, deploys (502/503/504) and slow links are retried with backoff.
    private nonisolated func put(_ sealed: Data, blob: String, index: Int) async -> Bool {
        var delay: Double = 1
        for _ in 0..<10 {
            if Task.isCancelled { return false }
            if let res = try? await CloudService.shared.call("PUT", "/v1/blobs/\(blob)/\(index)", body: sealed).1 {
                if res.statusCode == 204 { return true }
                if res.statusCode == 404 { return false }   // the file was removed
            }
            try? await Task.sleep(for: .seconds(delay))
            delay = min(delay * 2, 30)
        }
        return false
    }

    func delivered(blob: String) {
        guard let id = sentBlobs.removeValue(forKey: blob) else { return }
        TransferStore.shared.update(id) { $0.state = .done; $0.awaitingPickup = nil; $0.note = "Delivered" }
    }

    func cancelled(blob: String) {
        if let id = sentBlobs.removeValue(forKey: blob) {
            TransferStore.shared.update(id) { $0.state = .failed; $0.note = "Not received" }
        }
        receiving.remove(blob)
    }

    // MARK: Receiving

    func receive(offer o: [String: Any], from peer: CloudService.Peer) {
        guard let blob = o["blob"] as? String, blob.count == 32, !receiving.contains(blob),
              let size = (o["size"] as? NSNumber)?.int64Value, size >= 0,
              let count = (o["count"] as? NSNumber)?.intValue, count == CloudCrypto.chunkCount(size: size),
              let chunk = (o["chunk"] as? NSNumber)?.intValue, chunk == CloudCrypto.chunkSize,
              let keyData = (o["key"] as? String).flatMap({ Data(base64Encoded: $0) }), keyData.count == 32 else { return }
        // Only the file's name, never a path.
        let name = ((o["name"] as? String) ?? "File").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        receiving.insert(blob)
        let device = AppModel.shared.devices.first { $0.id == peer.kdeID }
        var t = Transfer(direction: .received, kind: .file, deviceID: peer.kdeID, deviceName: device?.name ?? peer.name,
                         name: name.isEmpty ? "File" : name, size: size)
        t.viaCloud = true
        t.note = "Receiving via Cloud"
        TransferStore.shared.add(t)
        Task { await download(blob: blob, name: t.name, size: size, count: count, key: SymmetricKey(data: keyData), transfer: t.id, from: peer) }
    }

    private func download(blob: String, name: String, size: Int64, count: Int, key: SymmetricKey, transfer: UUID, from peer: CloudService.Peer) async {
        let store = TransferStore.shared, cloud = CloudService.shared
        defer { receiving.remove(blob) }
        func fail(_ note: String) { store.update(transfer) { $0.state = .failed; $0.note = note; $0.speed = 0 } }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Janus/Cloud", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let part = dir.appendingPathComponent(blob + ".part")
        FileManager.default.createFile(atPath: part.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let fd = open(part.path, O_WRONLY)
        guard fd >= 0 else { return fail("Couldn't save the file") }

        let started = Date()
        var done: Int64 = 0, next = 0
        var failure: String?
        await withTaskGroup(of: (Int64?, String?).self) { group in
            func add() {
                guard next < count else { return }
                let i = next
                next += 1
                group.addTask {
                    // Download, decrypt and write (positioned, safe in parallel) off the main thread.
                    let (plain, error) = await self.fetch(blob: blob, index: i, count: count, key: key)
                    guard let plain else { return (nil, error) }
                    return Self.write(fd, plain, at: off_t(i) * off_t(CloudCrypto.chunkSize)) ? (Int64(plain.count), nil) : (nil, "Couldn't save the file")
                }
            }
            for _ in 0..<parallel { add() }
            while let (bytes, error) = await group.next() {
                guard let bytes else { failure = error; group.cancelAll(); break }
                done += bytes
                let elapsed = max(Date().timeIntervalSince(started), 0.001)
                store.update(transfer) { $0.bytesDone = done; $0.speed = Double(done) / elapsed }
                add()
            }
        }
        close(fd)
        if let failure {
            try? FileManager.default.removeItem(at: part)
            if failure != "cancelled" { try? await cloud.send("file-cancel", ["blob": blob], to: peer) }
            return fail(failure == "cancelled" ? "The sender stopped" : failure)
        }
        // Where files from the phone go: Downloads, with a free name.
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var dest = downloads.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var n = 1
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = downloads.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        do { try FileManager.default.moveItem(at: part, to: dest) } catch {
            try? FileManager.default.removeItem(at: part)
            return fail("Couldn't save the file")
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dest.path)
        store.update(transfer) { $0.url = dest; $0.name = dest.lastPathComponent; $0.state = .done; $0.bytesDone = size; $0.speed = 0; $0.note = nil }
        ReceivePopup.shared.show(transfer)
        if let device = AppModel.shared.devices.first(where: { $0.id == peer.kdeID }) { Notifier.shared.received(dest, device: device) }
        _ = try? await cloud.call("DELETE", "/v1/blobs/\(blob)")
        try? await cloud.send("file-done", ["blob": blob], to: peer)
    }

    /// One chunk: waits while it's still being uploaded (the relay holds the request), retries drops with backoff,
    /// and gives up only if the file is removed or nothing arrives for 10 minutes.
    private nonisolated func fetch(blob: String, index: Int, count: Int, key: SymmetricKey) async -> (Data?, String?) {
        var delay: Double = 1
        let started = Date()
        while !Task.isCancelled {
            if Date().timeIntervalSince(started) > 600 { return (nil, "The sender stopped") }
            do {
                let (data, res) = try await CloudService.shared.call("GET", "/v1/blobs/\(blob)/\(index)")
                switch res.statusCode {
                case 200:
                    guard let plain = try? CloudCrypto.openChunk(data, key: key, blob: blob, index: index, count: count) else {
                        return (nil, "The file was damaged on the way")
                    }
                    return (plain, nil)
                case 204:
                    continue   // the relay waited 25 s and it isn't uploaded yet: ask again
                case 404, 410:
                    return (nil, "cancelled")
                default: break
                }
            } catch {}
            try? await Task.sleep(for: .seconds(delay))
            delay = min(delay * 2, 30)
        }
        return (nil, "cancelled")
    }

    private nonisolated static func read(_ fd: Int32, at offset: off_t, count: Int) -> Data? {
        var data = Data(count: count)
        let n = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, offset) }
        guard n >= 0 else { return nil }
        data.count = n
        return data
    }

    private nonisolated static func write(_ fd: Int32, _ data: Data, at offset: off_t) -> Bool {
        data.withUnsafeBytes { pwrite(fd, $0.baseAddress, data.count, offset) } == data.count
    }
}
