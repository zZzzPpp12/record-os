import AppKit
import Foundation

struct AppVersionInfo: Equatable, Sendable {
    let shortVersion: String
    let buildNumber: String

    static var current: AppVersionInfo {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = (info["CFBundleShortVersionString"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let build = (info["CFBundleVersion"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return AppVersionInfo(
            shortVersion: (short?.isEmpty == false ? short! : "1.0.0"),
            buildNumber: (build?.isEmpty == false ? build! : "1")
        )
    }

    var displayLabel: String {
        "v\(shortVersion) (Build \(buildNumber))"
    }
}

struct AppReleaseAsset: Equatable, Sendable {
    let name: String
    let downloadURL: URL
    let sizeBytes: Int64

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: max(0, sizeBytes), countStyle: .file)
    }
}

struct AppReleaseInfo: Equatable, Sendable {
    let version: String
    let tagName: String
    let title: String
    let releaseNotes: String
    let htmlURL: URL
    let publishedAt: Date?
    let installerAsset: AppReleaseAsset?
}

enum AppUpdateStatus: Equatable {
    case idle
    case checking
    case upToDate(latestVersion: String?)
    case updateAvailable(AppReleaseInfo)
    case downloading(info: AppReleaseInfo, progress: Double?)
    case downloaded(info: AppReleaseInfo, fileURL: URL)
    case failed(message: String)
}

@MainActor
final class AppUpdateChecker: ObservableObject {
    @Published private(set) var status: AppUpdateStatus = .idle
    @Published private(set) var lastCheckedAt: Date?

    let currentVersion: AppVersionInfo

    static let repositoryOwner = "zZzzPpp12"
    static let repositoryName = "record-os"
    static let releasesPageURL = URL(string: "https://github.com/\(repositoryOwner)/\(repositoryName)/releases")!
    private static let latestReleaseAPIURL = URL(
        string: "https://api.github.com/repos/\(repositoryOwner)/\(repositoryName)/releases/latest"
    )!

    private static let minAutomaticCheckInterval: TimeInterval = 15 * 60
    private var cachedETag: String?
    private var cachedLatestRelease: GitHubReleasePayload?
    private var activeDownloadDelegate: DownloadProgressDelegate?
    private var activeDownloadTask: URLSessionDownloadTask?
    private var activeDownloadSession: URLSession?

    init(currentVersion: AppVersionInfo = .current) {
        self.currentVersion = currentVersion
    }

    var availableRelease: AppReleaseInfo? {
        switch status {
        case .updateAvailable(let info), .downloading(let info, _), .downloaded(let info, _):
            return info
        case .idle, .checking, .upToDate, .failed:
            return nil
        }
    }

    var isBusy: Bool {
        switch status {
        case .checking, .downloading:
            return true
        case .idle, .upToDate, .updateAvailable, .downloaded, .failed:
            return false
        }
    }

    func checkIfNeededOnAppear() async {
        if case .downloading = status { return }
        if case .downloaded = status { return }
        if case .checking = status { return }

        if let lastCheckedAt,
           Date.now.timeIntervalSince(lastCheckedAt) < Self.minAutomaticCheckInterval,
           status != .idle {
            return
        }
        await checkForUpdates(userInitiated: false)
    }

    func checkForUpdates(userInitiated: Bool = true) async {
        if case .checking = status { return }
        if case .downloading = status { return }

        status = .checking

        var request = URLRequest(url: Self.latestReleaseAPIURL)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("RecordOS/\(currentVersion.shortVersion)", forHTTPHeaderField: "User-Agent")
        if let cachedETag {
            request.setValue(cachedETag, forHTTPHeaderField: "If-None-Match")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                status = .failed(message: "无法解析更新服务器响应。")
                return
            }

            switch http.statusCode {
            case 200:
                if let etag = http.value(forHTTPHeaderField: "ETag") {
                    cachedETag = etag
                }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let payload = try decoder.decode(GitHubReleasePayload.self, from: data)
                cachedLatestRelease = payload
                lastCheckedAt = .now
                applyReleasePayload(payload)

            case 304:
                lastCheckedAt = .now
                if let cachedLatestRelease {
                    applyReleasePayload(cachedLatestRelease)
                } else {
                    status = .upToDate(latestVersion: currentVersion.shortVersion)
                }

            case 404:
                // Repository exists, but no GitHub Release has been published yet.
                lastCheckedAt = .now
                status = .upToDate(latestVersion: nil)

            case 403, 429:
                status = .failed(message: "GitHub 更新检测请求过于频繁（API 限流），请稍后再试或直接前往发布页查看。")

            default:
                status = .failed(message: "检查更新失败（HTTP \(http.statusCode)）。")
            }
        } catch is CancellationError {
            if status == .checking {
                status = .idle
            }
        } catch {
            if userInitiated || status == .checking {
                status = .failed(message: "无法连接更新服务器：\(error.localizedDescription)")
            }
        }
    }

    func performUpdate() {
        switch status {
        case .downloaded(_, let fileURL):
            openInstaller(at: fileURL)
        case .updateAvailable(let info):
            if let asset = info.installerAsset {
                startInstallerDownload(release: info, asset: asset)
            } else {
                NSWorkspace.shared.open(info.htmlURL)
            }
        default:
            break
        }
    }

    func cancelDownload() {
        guard case .downloading(let info, _) = status else { return }
        activeDownloadTask?.cancel()
        cleanupDownloadSession(cancelImmediately: true)
        status = .updateAvailable(info)
    }

    func openReleasesPage() {
        let url = availableRelease?.htmlURL ?? Self.releasesPageURL
        NSWorkspace.shared.open(url)
    }

    func openInstaller(at url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else if let info = availableRelease {
            status = .updateAvailable(info)
        }
    }

    func revealInstallerInFinder(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func applyReleasePayload(_ payload: GitHubReleasePayload) {
        guard !payload.draft, !payload.prerelease else {
            status = .upToDate(latestVersion: nil)
            return
        }

        let normalizedRemote = SemanticVersion.normalize(payload.tagName)
        let releaseURL = URL(string: payload.htmlUrl) ?? Self.releasesPageURL

        guard SemanticVersion.isNewer(remote: normalizedRemote, thanLocal: currentVersion.shortVersion) else {
            status = .upToDate(latestVersion: normalizedRemote)
            return
        }

        let selectedAsset = Self.selectPreferredInstallerAsset(from: payload.assets)
        let title = payload.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = payload.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let info = AppReleaseInfo(
            version: normalizedRemote,
            tagName: payload.tagName,
            title: (title?.isEmpty == false ? title! : "RecordOS v\(normalizedRemote)"),
            releaseNotes: body,
            htmlURL: releaseURL,
            publishedAt: payload.publishedAt,
            installerAsset: selectedAsset
        )
        status = .updateAvailable(info)
    }

    private func startInstallerDownload(release: AppReleaseInfo, asset: AppReleaseAsset) {
        cleanupDownloadSession(cancelImmediately: true)
        status = .downloading(info: release, progress: 0)

        let delegate = DownloadProgressDelegate(
            onProgress: { [weak self] fraction in
                Task { @MainActor [weak self] in
                    guard let self, case .downloading(let currentInfo, _) = self.status else { return }
                    self.status = .downloading(info: currentInfo, progress: fraction)
                }
            },
            onFinish: { [weak self] result in
                Task { @MainActor [weak self] in
                    self?.handleDownloadFinished(release: release, asset: asset, result: result)
                }
            }
        )

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)

        var request = URLRequest(url: asset.downloadURL)
        request.setValue("RecordOS/\(currentVersion.shortVersion)", forHTTPHeaderField: "User-Agent")

        let task = session.downloadTask(with: request)
        activeDownloadDelegate = delegate
        activeDownloadSession = session
        activeDownloadTask = task
        task.resume()
        session.finishTasksAndInvalidate()
    }

    private func handleDownloadFinished(
        release: AppReleaseInfo,
        asset: AppReleaseAsset,
        result: Result<URL, Error>
    ) {
        cleanupDownloadSession()

        switch result {
        case .success(let stagedTempURL):
            do {
                let destination = try moveDownloadedInstaller(from: stagedTempURL, fileName: asset.name)
                status = .downloaded(info: release, fileURL: destination)
                NSWorkspace.shared.open(destination)
            } catch {
                try? FileManager.default.removeItem(at: stagedTempURL)
                status = .failed(message: "保存安装包失败：\(error.localizedDescription)")
            }

        case .failure(let error):
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                status = .updateAvailable(release)
                return
            }
            status = .failed(message: "下载更新安装包失败：\(error.localizedDescription)")
        }
    }

    private func moveDownloadedInstaller(from stagedURL: URL, fileName: String) throws -> URL {
        let fm = FileManager.default
        let downloadsDir = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        try fm.createDirectory(at: downloadsDir, withIntermediateDirectories: true)

        let sanitizedName = Self.sanitizedInstallerFileName(fileName)
        let targetURL = Self.uniqueDestinationURL(in: downloadsDir, preferredFileName: sanitizedName, fileManager: fm)
        try fm.moveItem(at: stagedURL, to: targetURL)
        return targetURL
    }

    private func cleanupDownloadSession(cancelImmediately: Bool = false) {
        activeDownloadTask = nil
        activeDownloadDelegate = nil
        if cancelImmediately {
            activeDownloadSession?.invalidateAndCancel()
        } else {
            activeDownloadSession?.finishTasksAndInvalidate()
        }
        activeDownloadSession = nil
    }

    private static func sanitizedInstallerFileName(_ raw: String) -> String {
        let base = (raw as NSString).lastPathComponent
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? "RecordOS-Installer.dmg" : base
    }

    private static func uniqueDestinationURL(
        in directory: URL,
        preferredFileName: String,
        fileManager: FileManager
    ) -> URL {
        let candidate = directory.appendingPathComponent(preferredFileName)
        if !fileManager.fileExists(atPath: candidate.path) {
            return candidate
        }
        let nsName = preferredFileName as NSString
        let ext = nsName.pathExtension
        let stem = nsName.deletingPathExtension
        for index in 1...999 {
            let numbered = ext.isEmpty ? "\(stem) (\(index))" : "\(stem) (\(index)).\(ext)"
            let url = directory.appendingPathComponent(numbered)
            if !fileManager.fileExists(atPath: url.path) {
                return url
            }
        }
        return directory.appendingPathComponent("\(UUID().uuidString)-\(preferredFileName)")
    }

    static func selectPreferredInstallerAsset(from assets: [GitHubAssetPayload]) -> AppReleaseAsset? {
        let supportedExtensions = ["dmg", "pkg", "zip"]
        let ranked = assets.compactMap { asset -> (priority: Int, item: AppReleaseAsset)? in
            guard let url = URL(string: asset.browserDownloadUrl) else { return nil }
            let lower = asset.name.lowercased()
            guard let extIndex = supportedExtensions.firstIndex(where: { lower.hasSuffix(".\($0)") }) else {
                return nil
            }
            let archBonus = (lower.contains("arm64") || lower.contains("universal") || lower.contains("macos")) ? 0 : 1
            let priority = extIndex * 10 + archBonus
            return (
                priority,
                AppReleaseAsset(name: asset.name, downloadURL: url, sizeBytes: asset.size)
            )
        }
        .sorted { $0.priority < $1.priority }

        return ranked.first?.item
    }
}

enum SemanticVersion {
    static func normalize(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("v") {
            trimmed.removeFirst()
        }
        if let plusIndex = trimmed.firstIndex(of: "+") {
            trimmed = String(trimmed[..<plusIndex])
        }
        return trimmed
    }

    static func isNewer(remote: String, thanLocal local: String) -> Bool {
        let remoteParts = parse(remote)
        let localParts = parse(local)
        guard !remoteParts.core.isEmpty, !localParts.core.isEmpty else {
            return false
        }

        let maxCount = max(remoteParts.core.count, localParts.core.count)
        for index in 0..<maxCount {
            let r = index < remoteParts.core.count ? remoteParts.core[index] : 0
            let l = index < localParts.core.count ? localParts.core[index] : 0
            if r != l {
                return r > l
            }
        }

        // Same numeric core: a stable release is newer than a pre-release of the same core.
        switch (localParts.prerelease, remoteParts.prerelease) {
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        case (.some(let lPre), .some(let rPre)):
            return rPre.localizedStandardCompare(lPre) == .orderedDescending
        case (nil, nil):
            return false
        }
    }

    private static func parse(_ raw: String) -> (core: [Int], prerelease: String?) {
        let normalized = normalize(raw)
        let segments = normalized.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let coreString = segments.first.map(String.init) ?? ""
        let prerelease = segments.count > 1 ? String(segments[1]) : nil

        let numbers = coreString.split(separator: ".").compactMap { Int($0) }
        guard numbers.count == coreString.split(separator: ".").count else {
            return ([], nil)
        }
        return (numbers, prerelease)
    }
}

struct GitHubReleasePayload: Decodable, Sendable {
    let tagName: String
    let name: String?
    let body: String?
    let draft: Bool
    let prerelease: Bool
    let htmlUrl: String
    let publishedAt: Date?
    let assets: [GitHubAssetPayload]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case draft
        case prerelease
        case htmlUrl = "html_url"
        case publishedAt = "published_at"
        case assets
    }
}

struct GitHubAssetPayload: Decodable, Sendable {
    let name: String
    let browserDownloadUrl: String
    let size: Int64

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadUrl = "browser_download_url"
        case size
    }
}

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double?) -> Void
    private let onFinish: @Sendable (Result<URL, Error>) -> Void
    private let lock = NSLock()
    private var didFinish = false
    private var lastReportedBucket = -1

    init(
        onProgress: @escaping @Sendable (Double?) -> Void,
        onFinish: @escaping @Sendable (Result<URL, Error>) -> Void
    ) {
        self.onProgress = onProgress
        self.onFinish = onFinish
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesExpectedToWrite > 0 {
            let fraction = min(max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0), 1)
            let bucket = Int((fraction * 100).rounded(.down))
            lock.lock()
            let shouldReport = bucket != lastReportedBucket
            if shouldReport {
                lastReportedBucket = bucket
            }
            lock.unlock()
            if shouldReport {
                onProgress(fraction)
            }
        } else {
            lock.lock()
            let shouldReport = lastReportedBucket != -2
            lastReportedBucket = -2
            lock.unlock()
            if shouldReport {
                onProgress(nil)
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            finishOnce(.failure(URLError(.badServerResponse)))
            return
        }

        // URLSession deletes `location` as soon as this delegate method returns,
        // so stage it to our own temporary file before hopping to MainActor.
        let stagedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordOS-Update-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: stagedURL)
            finishOnce(.success(stagedURL))
        } catch {
            finishOnce(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finishOnce(.failure(error))
        }
    }

    private func finishOnce(_ result: Result<URL, Error>) {
        lock.lock()
        let alreadyFinished = didFinish
        didFinish = true
        lock.unlock()
        guard !alreadyFinished else { return }
        onFinish(result)
    }
}
