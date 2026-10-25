@preconcurrency import AVFoundation
import CryptoKit
import UIKit

@MainActor final class DownloadStore: NSObject, ObservableObject {
    @Published private(set) var items: [DownloadRecord] = []
    @Published private(set) var mid: Int?
    @Published var error: String?
    private let client: BiliClient
    private let automaticallyStarts: Bool
    private let preferNative: Bool
    private let directory: URL
    nonisolated private let incoming: URL
    private var cachedKey: SymmetricKey?
    private var generation = UUID()
    private var session: URLSession?
    private var tasks: [Int: (UUID, Int)] = [:]
    private var resolver: Task<Void, Never>?
    private var merger: Task<Void, Never>?
    private var exporting: AVAssetExportSession?
    private var lastSave = Date.distantPast
    private var lastProgress: [Int: Date] = [:]
    private var background: UIBackgroundTaskIdentifier = .invalid
    private var suspendedForSystem = false
    init(
        client: BiliClient, directory: URL? = nil, key: SymmetricKey? = nil, automaticallyStarts: Bool = true,
        preferNative: Bool = true
    ) {
        self.client = client
        self.automaticallyStarts = automaticallyStarts
        self.preferNative = preferNative
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.directory = root.appendingPathComponent("Downloads", isDirectory: true)
        incoming = root.appendingPathComponent("DownloadIncoming", isDirectory: true)
        cachedKey = key
        super.init()
    }
    func restoreLocalAccount() {
        do { if let value: Int = try KeychainVault.load("downloads-account") { account(value, remember: false) } } catch
        { self.error = "下载记录暂时无法读取，请解锁设备后重试。" }
    }
    func account(_ value: Int?, remember: Bool = true) {
        guard value != mid else { return }
        for index in items.indices where [.downloading, .resolving, .merging, .queued].contains(items[index].state) {
            items[index].state = .paused
            items[index].interrupted = true
        }
        saveOrReport()
        generation = UUID()
        resolver?.cancel()
        merger?.cancel()
        exporting?.cancelExport()
        session?.invalidateAndCancel()
        session = nil
        tasks = [:]
        endBackgroundTime()
        mid = value
        items = []
        error = nil
        if remember {
            do {
                if let value {
                    try KeychainVault.save(value, name: "downloads-account")
                } else {
                    KeychainVault.delete("downloads-account")
                }
            } catch { self.error = "下载账号无法安全保存，请解锁设备后重试。" }
        }
        guard value != nil else { return }
        do {
            let file = folder.appendingPathComponent("manifest.sealed")
            if FileManager.default.fileExists(atPath: file.path) {
                let box = try AES.GCM.SealedBox(combined: Data(contentsOf: file))
                items = try JSONDecoder().decode(
                    [DownloadRecord].self, from: AES.GCM.open(box, using: key(), authenticating: accountData))
                for index in items.indices {
                    if [.queued, .resolving, .downloading, .merging].contains(items[index].state) {
                        items[index].state = .paused
                        items[index].interrupted = true
                    }
                    if items[index].state == .completed
                        && !FileManager.default.fileExists(atPath: fileURL(items[index]).path)
                    {
                        items[index].state = .failed
                        items[index].message = "本地文件已丢失，请重新下载。"
                    }
                }
            }
        } catch { self.error = "下载记录无法读取，请解锁设备后重试。" }
    }
    private var folder: URL { directory.appendingPathComponent("\(mid ?? 0)", isDirectory: true) }
    private var accountData: Data { Data("\(mid ?? 0)".utf8) }
    func fileURL(_ item: DownloadRecord) -> URL { folder.appendingPathComponent(item.fileName) }
    private func key() throws -> SymmetricKey {
        if let cachedKey { return cachedKey }
        if let data: Data = try KeychainVault.load("downloads-key") {
            cachedKey = SymmetricKey(data: data)
        } else {
            let value = SymmetricKey(size: .bits256)
            try KeychainVault.save(value.withUnsafeBytes { Data($0) }, name: "downloads-key")
            cachedKey = value
        }
        return cachedKey!
    }
    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try FileManager.default.createDirectory(
            at: incoming, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var root = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
        var temporary = incoming
        try temporary.setResourceValues(values)
    }
    private func save() throws {
        guard mid != nil else { return }
        try prepareDirectory()
        let box = try AES.GCM.seal(JSONEncoder().encode(items), using: key(), authenticating: accountData)
        try box.combined!.write(
            to: folder.appendingPathComponent("manifest.sealed"),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        lastSave = Date()
    }
    private func saveOrReport() {
        do { try save() } catch { self.error = "下载记录未能保存，请检查可用空间或解锁设备后重试。" }
    }
    @discardableResult func enqueue(video: Video, part: VideoPart, quality: Int, label: String) throws -> UUID {
        guard mid != nil else { throw BiliFailure(code: "LOGIN_REQUIRED", message: "请先登录 B 站再下载。") }
        if let existing = items.first(where: {
            $0.video.bvid == video.bvid && $0.part.cid == part.cid
                && ($0.quality == quality || quality == 127 || $0.quality == 127) && $0.state != .failed
        }) {
            return existing.id
        }
        let item = DownloadRecord(id: UUID(), video: video, part: part, quality: quality, qualityLabel: label)
        items.insert(item, at: 0)
        do { try save() } catch {
            items.removeAll { $0.id == item.id }
            throw error
        }
        startNext()
        return item.id
    }
    func resume(_ id: UUID, restart: Bool = false) {
        guard !tasks.values.contains(where: { $0.0 == id }) else { return }
        guard let index = items.firstIndex(where: { $0.id == id }), [.paused, .failed].contains(items[index].state)
        else { return }
        if restart {
            removeFiles(items[index])
            items[index].files = []
        }
        items[index].state = .queued
        items[index].message = nil
        items[index].interrupted = false
        saveOrReport()
        startNext()
    }
    func pause(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].state != .completed else { return }
        let before = items[index].state
        items[index].state = .paused
        items[index].interrupted = false
        if before == .resolving { resolver?.cancel() }
        if before == .merging {
            exporting?.cancelExport()
            merger?.cancel()
            exporting = nil
        }
        let token = generation
        session?.getAllTasks { [weak self] values in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                for task in values {
                    guard let info = self.tasks[task.taskIdentifier], info.0 == id,
                        let download = task as? URLSessionDownloadTask
                    else { continue }
                    download.cancel { data in
                        Task { @MainActor in
                            guard self.generation == token, let row = self.items.firstIndex(where: { $0.id == id }),
                                self.items[row].files.indices.contains(info.1)
                            else { return }
                            self.items[row].files[info.1].resumeData = data
                            self.saveOrReport()
                        }
                    }
                }
            }
        }
        saveOrReport()
        if tasks.isEmpty { startNext() }
    }
    func remove(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        pause(id)
        let item = items.remove(at: index)
        removeFiles(item)
        saveOrReport()
        startNext()
    }
    private func removeFiles(_ item: DownloadRecord) {
        try? FileManager.default.removeItem(at: fileURL(item))
        for file in item.files {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(item.fileName(file.role)))
        }
    }
    private func transferSession() -> URLSession {
        if let session { return session }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.httpMaximumConnectionsPerHost = 2
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 86_400
        config.waitsForConnectivity = true
        let value = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        session = value
        return value
    }
    private func startNext() {
        guard automaticallyStarts, !suspendedForSystem else { return }
        guard tasks.isEmpty, !items.contains(where: { [.resolving, .merging].contains($0.state) }),
            let index = items.lastIndex(where: { $0.state == .queued })
        else {
            if tasks.isEmpty && !items.contains(where: { [.resolving, .merging].contains($0.state) }) { endBackgroundTime() }
            return
        }
        let id = items[index].id
        let item = items[index]
        let token = generation
        items[index].state = .resolving
        resolver = Task {
            do {
                try Task.checkCancellation()
                if item.files.isEmpty {
                    let source = try await client.playback(
                        item.video.bvid, cid: item.part.cid, quality: item.quality, allowNative: preferNative)
                    try Task.checkCancellation()
                    guard generation == token, let row = items.firstIndex(where: { $0.id == id }),
                        items[row].state == .resolving
                    else { return }
                    let estimate = Int64(
                        source.duration * Double((source.video?.bandwidth ?? 0) + (source.audio?.bandwidth ?? 0)) / 8)
                    let available = try folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                        .volumeAvailableCapacityForImportantUsage
                    if let available, available < max(estimate * 2, 100_000_000) + 64_000_000 {
                        throw BiliFailure(code: "DISK_FULL", message: "iPhone 空间不足，请清理后重试。")
                    }
                    items[row].quality = source.quality
                    items[row].qualityLabel =
                        source.qualities.first(where: { $0.id == source.quality })?.label ?? "\(source.quality)"
                    if let url = source.mp4 {
                        items[row].files = [DownloadFile(role: "combined", url: url)]
                    } else if let video = source.video {
                        items[row].files = [DownloadFile(role: "video", url: video.url)]
                        if let audio = source.audio {
                            items[row].files.append(DownloadFile(role: "audio", url: audio.url))
                        }
                    } else {
                        throw BiliFailure.invalid
                    }
                }
                try Task.checkCancellation()
                guard generation == token, let row = items.firstIndex(where: { $0.id == id }),
                    items[row].state == .resolving
                else { return }
                items[row].state = .downloading
                for fileIndex in items[row].files.indices where !items[row].files[fileIndex].finished {
                    let file = items[row].files[fileIndex]
                    guard MediaLoader.allowed(file.url) else { throw BiliFailure.invalid }
                    let task: URLSessionDownloadTask
                    if let data = file.resumeData {
                        task = transferSession().downloadTask(withResumeData: data)
                    } else {
                        var request = URLRequest(url: file.url)
                        request.setValue(BiliHTTP.userAgent, forHTTPHeaderField: "User-Agent")
                        request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
                        request.setValue("bytes=0-", forHTTPHeaderField: "Range")
                        task = transferSession().downloadTask(with: request)
                    }
                    task.priority = URLSessionTask.lowPriority
                    tasks[task.taskIdentifier] = (id, fileIndex)
                    items[row].files[fileIndex].resumeData = nil
                    task.resume()
                }
                saveOrReport()
                if tasks.isEmpty { finishFiles(id) }
            } catch is CancellationError { startNext() } catch {
                guard generation == token else { return }
                fail(id, message: (error as? BiliFailure)?.message ?? "无法开始下载，请检查网络和可用空间后重试。")
            }
        }
    }
    private func finishFiles(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].files.allSatisfy(\.finished),
            items[index].state == .downloading
        else { return }
        if items[index].files.count == 1 && items[index].files[0].role == "combined" {
            do {
                try FileManager.default.moveItem(
                    at: folder.appendingPathComponent(items[index].fileName("combined")), to: fileURL(items[index]))
                complete(id)
            } catch { fail(id, message: "无法保存视频文件，请检查可用空间。") }
            return
        }
        items[index].state = .merging
        saveOrReport()
        let item = items[index]
        let root = folder
        let token = generation
        merger = Task {
            do {
                try await OfflineMovie.merge(item: item, directory: root) { [weak self] value in self?.exporting = value
                }
                try Task.checkCancellation()
                guard generation == token else { return }
                complete(id)
            } catch is CancellationError { startNext() } catch {
                guard generation == token else { return }
                if let row = items.firstIndex(where: { $0.id == id }), items[row].state != .paused {
                    fail(id, message: "音视频合并未完成，可点继续重试；已下载的轨道会保留。")
                }
            }
            exporting = nil
        }
    }
    private func complete(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = .completed
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: fileURL(items[index]).path)
        items[index].message = nil
        for file in items[index].files {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(items[index].fileName(file.role)))
        }
        saveOrReport()
        startNext()
    }
    private func fail(_ id: UUID, message: String) {
        guard let row = items.firstIndex(where: { $0.id == id }) else { return }
        items[row].state = .failed
        items[row].message = message
        session?.getAllTasks { [weak self] values in
            Task { @MainActor in
                guard let self else { return }
                for task in values where self.tasks[task.taskIdentifier]?.0 == id { task.cancel() }
            }
        }
        saveOrReport()
        startNext()
    }
    func requestBackgroundTime() {
        guard !tasks.isEmpty || items.contains(where: { [.resolving, .merging].contains($0.state) }),
            background == .invalid
        else { return }
        background = UIApplication.shared.beginBackgroundTask(withName: "Finish Bilight download") { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.suspendedForSystem = true
                for item in self.items where [.resolving, .downloading, .merging].contains(item.state) {
                    self.pause(item.id)
                    if let row = self.items.firstIndex(where: { $0.id == item.id }) {
                        self.items[row].interrupted = true
                    }
                }
                self.saveOrReport()
                self.endBackgroundTime()
            }
        }
    }
    func resumeInterrupted() {
        suspendedForSystem = false
        for index in items.indices where items[index].state == .paused && items[index].interrupted {
            items[index].state = .queued
            items[index].interrupted = false
        }
        saveOrReport()
        startNext()
    }
    private func endBackgroundTime() {
        if background != .invalid {
            UIApplication.shared.endBackgroundTask(background)
            background = .invalid
        }
    }
}

extension DownloadStore: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        Task { @MainActor in
            guard self.session === session, let target = self.tasks[downloadTask.taskIdentifier],
                let row = self.items.firstIndex(where: { $0.id == target.0 })
            else { return }
            guard self.items[row].files.indices.contains(target.1),
                Date().timeIntervalSince(self.lastProgress[downloadTask.taskIdentifier] ?? .distantPast) >= 0.25
            else { return }
            self.lastProgress[downloadTask.taskIdentifier] = Date()
            self.items[row].files[target.1].received = totalBytesWritten
            self.items[row].files[target.1].expected = max(totalBytesExpectedToWrite, 0)
            if Date().timeIntervalSince(self.lastSave) >= 1 { self.saveOrReport() }
        }
    }
    nonisolated func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {
        let saved = incoming.appendingPathComponent(UUID().uuidString)
        do {
            let size = (try location.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            try DownloadValidation.response(downloadTask.response, size: size)
            try FileManager.default.moveItem(at: location, to: saved)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: saved.path)
            Task { @MainActor in
                defer {
                    try? FileManager.default.removeItem(at: saved)
                    self.startNext()
                }
                guard self.session === session,
                    let target = self.tasks.removeValue(forKey: downloadTask.taskIdentifier),
                    let row = self.items.firstIndex(where: { $0.id == target.0 }),
                    self.items[row].files.indices.contains(target.1), self.items[row].state == .downloading
                else { return }
                do {
                    let file = self.items[row].files[target.1]
                    let destination = self.folder.appendingPathComponent(self.items[row].fileName(file.role))
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: saved, to: destination)
                    self.items[row].files[target.1].finished = true
                    self.items[row].files[target.1].received = size
                    self.items[row].files[target.1].expected = size
                    self.items[row].files[target.1].resumeData = nil
                    self.saveOrReport()
                    self.finishFiles(target.0)
                    self.startNext()
                } catch { self.fail(target.0, message: "下载文件保存失败，请检查可用空间。") }
            }
        } catch {
            try? FileManager.default.removeItem(at: saved)
            Task { @MainActor in
                guard self.session === session, let target = self.tasks.removeValue(forKey: downloadTask.taskIdentifier)
                else { return }
                self.fail(target.0, message: (error as? BiliFailure)?.message ?? "视频文件保存失败。")
            }
        }
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        Task { @MainActor in
            defer { self.startNext() }
            guard self.session === session, let target = self.tasks.removeValue(forKey: task.taskIdentifier),
                let row = self.items.firstIndex(where: { $0.id == target.0 }),
                self.items[row].files.indices.contains(target.1)
            else { return }
            self.items[row].files[target.1].resumeData =
                (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            if self.items[row].state == .downloading { self.fail(target.0, message: "网络中断，点继续下载可尝试断点续传；地址过期时请重新下载。") }
            self.saveOrReport()
            self.startNext()
        }
    }
    nonisolated func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, MediaLoader.allowed(url) else {
            completionHandler(nil)
            return
        }
        var next = request
        next.setValue(nil, forHTTPHeaderField: "Cookie")
        next.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        completionHandler(next)
    }
}

enum OfflineMovie {
    @MainActor static func merge(item: DownloadRecord, directory: URL, export: (AVAssetExportSession) -> Void)
        async throws
    {
        let composition = AVMutableComposition()
        var assets: [AVURLAsset] = []
        for file in item.files {
            let asset = AVURLAsset(url: directory.appendingPathComponent(item.fileName(file.role)))
            assets.append(asset)
            let type: AVMediaType = file.role == "audio" ? .audio : .video
            guard try await !asset.load(.hasProtectedContent),
                let source = try await asset.loadTracks(withMediaType: type).first,
                let target = composition.addMutableTrack(
                    withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { throw BiliFailure.invalid }
            let duration = try await asset.load(.duration)
            let end = min(duration.seconds, item.part.duration > 0 ? item.part.duration : duration.seconds)
            try target.insertTimeRange(
                CMTimeRange(start: .zero, duration: CMTime(seconds: end, preferredTimescale: 600)), of: source,
                at: .zero)
            if type == .video { target.preferredTransform = try await source.load(.preferredTransform) }
        }
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw BiliFailure.invalid
        }
        let target = directory.appendingPathComponent(item.fileName)
        try? FileManager.default.removeItem(at: target)
        session.outputURL = target
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        export(session)
        let handle = ExportHandle(session)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                session.exportAsynchronously {
                    if handle.value.status == .completed {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: handle.value.error ?? BiliFailure.invalid)
                    }
                }
            }
        } onCancel: {
            handle.value.cancelExport()
        }
        withExtendedLifetime(assets) {}
    }
}

/// AVFoundation supports cancellation and final-status reads from its export completion queue.
private final class ExportHandle: @unchecked Sendable {
    let value: AVAssetExportSession
    init(_ value: AVAssetExportSession) { self.value = value }
}
