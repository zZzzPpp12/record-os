import AVFoundation
import AppKit
import CoreMedia
import Foundation
import ScreenCaptureKit

enum CaptureSourceKind: String, CaseIterable, Identifiable {
    case display
    case window
    case region

    var id: String { rawValue }

    var title: String {
        switch self {
        case .display: "整个屏幕"
        case .window: "窗口"
        case .region: "区域"
        }
    }

    var symbol: String {
        switch self {
        case .display: "display"
        case .window: "macwindow"
        case .region: "viewfinder"
        }
    }
}

struct DisplayChoice: Identifiable, Hashable {
    var id: CGDirectDisplayID
    var name: String
    var width: Int
    var height: Int
    var pointWidth: CGFloat
    var pointHeight: CGFloat
    var backingScaleFactor: CGFloat

    var summary: String { "\(name) · \(width) × \(height)" }
}

struct WindowChoice: Identifiable, Hashable {
    var id: CGWindowID
    var title: String
    var appName: String
    var bundleIdentifier: String?
    var width: Int
    var height: Int
    var frame: CGRect

    var displayLabel: String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedApp = appName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedApp.isEmpty && !trimmedTitle.isEmpty {
            return "\(trimmedApp) — \(trimmedTitle)"
        }
        return !trimmedTitle.isEmpty ? trimmedTitle : (trimmedApp.isEmpty ? "未命名窗口" : trimmedApp)
    }

    var summary: String { "\(displayLabel) · \(width) × \(height) pt" }
}

struct RegionChoice: Hashable {
    var displayID: CGDirectDisplayID
    var displayName: String
    var rectInDisplayPoints: CGRect
    var pixelScale: CGFloat

    var pixelWidth: Int {
        evenPixelDimension(rectInDisplayPoints.width * pixelScale, minimum: 16)
    }

    var pixelHeight: Int {
        evenPixelDimension(rectInDisplayPoints.height * pixelScale, minimum: 16)
    }

    var summary: String {
        "\(displayName) · \(Int(rectInDisplayPoints.width.rounded())) × \(Int(rectInDisplayPoints.height.rounded())) pt (\(pixelWidth) × \(pixelHeight) px)"
    }

    var shortLabel: String {
        "\(displayName) 区域 \(pixelWidth)×\(pixelHeight)"
    }
}

struct MicrophoneChoice: Identifiable, Hashable {
    var id: String
    var name: String
    var isDefault: Bool
}

struct RecordingAudioOptions: Hashable {
    var capturesSystemAudio: Bool = true
    var capturesMicrophone: Bool = false
    var microphoneDeviceID: String?

    var summary: String {
        switch (capturesSystemAudio, capturesMicrophone) {
        case (true, true): "画面、系统声音与麦克风"
        case (true, false): "画面与系统声音"
        case (false, true): "画面与麦克风"
        case (false, false): "仅画面（无声音）"
        }
    }
}

enum CaptureTarget: Hashable {
    case display(DisplayChoice)
    case window(WindowChoice)
    case region(RegionChoice)

    var shortLabel: String {
        switch self {
        case .display(let display): display.name
        case .window(let window): window.displayLabel
        case .region(let region): region.shortLabel
        }
    }

    var detailSummary: String {
        switch self {
        case .display(let display): display.summary
        case .window(let window): window.summary
        case .region(let region): region.summary
        }
    }
}

struct RecordingOptions: Hashable {
    var target: CaptureTarget
    var audio: RecordingAudioOptions
}

@MainActor
final class ScreenRecorder: ObservableObject {
    @Published var selectedSourceKind: CaptureSourceKind = .display
    @Published var selectedDisplayID: CGDirectDisplayID = 0
    @Published var selectedWindowID: CGWindowID = 0
    @Published var selectedRegion: RegionChoice?
    @Published var capturesSystemAudio = true
    @Published var capturesMicrophone = false
    @Published var selectedMicrophoneID: String = ""

    @Published private(set) var displays: [DisplayChoice] = []
    @Published private(set) var windows: [WindowChoice] = []
    @Published private(set) var microphones: [MicrophoneChoice] = []
    @Published private(set) var microphoneAuthStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @Published private(set) var isLoadingWindows = false
    @Published private(set) var isStarting = false
    @Published private(set) var isRecording = false
    @Published private(set) var isStopping = false
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var activeTarget: CaptureTarget?
    @Published private(set) var activeAudioOptions = RecordingAudioOptions()
    @Published private(set) var lastError: String?
    @Published private(set) var unexpectedFailureMessage: String?

    func audioTrackNames(for options: RecordingAudioOptions) -> [String] {
        var names: [String] = []
        if options.capturesSystemAudio {
            names.append("系统声音")
        }
        if options.capturesMicrophone {
            names.append("麦克风")
        }
        return names
    }

    var currentAudioOptions: RecordingAudioOptions {
        RecordingAudioOptions(
            capturesSystemAudio: capturesSystemAudio,
            capturesMicrophone: capturesMicrophone,
            microphoneDeviceID: selectedMicrophoneID.isEmpty ? nil : selectedMicrophoneID
        )
    }

    var currentCaptureTarget: CaptureTarget? {
        switch selectedSourceKind {
        case .display:
            guard let display = displays.first(where: { $0.id == selectedDisplayID }) else {
                return nil
            }
            return .display(display)
        case .window:
            guard let window = windows.first(where: { $0.id == selectedWindowID }) else {
                return nil
            }
            return .window(window)
        case .region:
            guard let region = selectedRegion else { return nil }
            return .region(region)
        }
    }

    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private let streamDelegate = StreamDelegate()
    private var outputDelegate: RecordingDelegate?
    private var finishSignal: RecordingFinishSignal?
    private var activeOutputURL: URL?
    private let fileManager = FileManager.default
    private nonisolated(unsafe) var deviceObservers: [NSObjectProtocol] = []

    init() {
        let handler: @Sendable (String) -> Void = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.handleStreamStoppedUnexpectedly(message: message)
            }
        }
        streamDelegate.onStreamStopWithError = handler
        let center = NotificationCenter.default
        let connected = center.addObserver(
            forName: AVCaptureDevice.wasConnectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMicrophones() }
        }
        let disconnected = center.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMicrophones() }
        }
        deviceObservers = [connected, disconnected]
        refreshMicrophones()
    }

    deinit {
        for observer in deviceObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private var recordingsURL: URL {
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return support.appendingPathComponent("RecordOS/Recordings", isDirectory: true)
    }

    func refreshDisplays() async {
        lastError = nil
        displays = NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let scale = screen.backingScaleFactor
            return DisplayChoice(
                id: CGDirectDisplayID(number.uint32Value),
                name: screen.localizedName,
                width: Int((screen.frame.width * scale).rounded()),
                height: Int((screen.frame.height * scale).rounded()),
                pointWidth: screen.frame.width,
                pointHeight: screen.frame.height,
                backingScaleFactor: scale
            )
        }
        if !displays.contains(where: { $0.id == selectedDisplayID }) {
            selectedDisplayID = displays.first?.id ?? 0
        }
    }

    func refreshWindows() async {
        isLoadingWindows = true
        defer { isLoadingWindows = false }
        lastError = nil
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            let ownPID = ProcessInfo.processInfo.processIdentifier
            let ownBundleID = Bundle.main.bundleIdentifier
            windows = content.windows.compactMap { window -> WindowChoice? in
                guard window.windowLayer == 0,
                      window.isOnScreen,
                      window.frame.width >= 80,
                      window.frame.height >= 80 else {
                    return nil
                }
                if let app = window.owningApplication {
                    if app.processID == ownPID { return nil }
                    if let ownBundleID, app.bundleIdentifier == ownBundleID { return nil }
                }
                let title = window.title ?? ""
                let appName = window.owningApplication?.applicationName ?? ""
                guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                      !appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                return WindowChoice(
                    id: window.windowID,
                    title: title,
                    appName: appName,
                    bundleIdentifier: window.owningApplication?.bundleIdentifier,
                    width: Int(window.frame.width.rounded()),
                    height: Int(window.frame.height.rounded()),
                    frame: window.frame
                )
            }
            .sorted {
                let appOrder = $0.appName.localizedCaseInsensitiveCompare($1.appName)
                if appOrder != .orderedSame {
                    return appOrder == .orderedAscending
                }
                return $0.displayLabel.localizedCaseInsensitiveCompare($1.displayLabel) == .orderedAscending
            }
            if !windows.contains(where: { $0.id == selectedWindowID }) {
                selectedWindowID = windows.first?.id ?? 0
            }
        } catch {
            windows = []
            selectedWindowID = 0
            lastError = "读取窗口列表失败：\(error.localizedDescription)"
        }
    }

    func refreshMicrophones() {
        microphoneAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        let defaultID = AVCaptureDevice.default(for: .audio)?.uniqueID
        microphones = discovery.devices
            .map { device in
                MicrophoneChoice(
                    id: device.uniqueID,
                    name: device.localizedName,
                    isDefault: device.uniqueID == defaultID
                )
            }
            .sorted { lhs, rhs in
                if lhs.isDefault != rhs.isDefault {
                    return lhs.isDefault
                }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        if !selectedMicrophoneID.isEmpty,
           !microphones.contains(where: { $0.id == selectedMicrophoneID }) {
            selectedMicrophoneID = ""
        }
    }

    func ensureMicrophonePermission() async throws {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        microphoneAuthStatus = status
        switch status {
        case .authorized:
            return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            microphoneAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            if !granted {
                throw ScreenRecorderError.microphonePermissionDenied
            }
        case .denied, .restricted:
            throw ScreenRecorderError.microphonePermissionDenied
        @unknown default:
            throw ScreenRecorderError.microphonePermissionDenied
        }
    }

    func startRecording(options: RecordingOptions) async throws {
        guard !isStarting, !isRecording, !isStopping else { return }
        isStarting = true
        defer { isStarting = false }
        lastError = nil
        unexpectedFailureMessage = nil

        if options.audio.capturesMicrophone {
            try await ensureMicrophonePermission()
        }

        let (filter, configuration, resolvedTarget, resolvedAudio) = try await buildFilterAndConfiguration(for: options)

        try fileManager.createDirectory(at: recordingsURL, withIntermediateDirectories: true)
        let outputURL = recordingsURL.appendingPathComponent("Take-\(UUID().uuidString).mov")

        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = outputURL
        recordingConfiguration.outputFileType = .mov
        recordingConfiguration.videoCodecType = .h264

        let finishSignal = RecordingFinishSignal()
        let outputDelegate = RecordingDelegate(finishSignal: finishSignal) { [weak self] message in
            Task { @MainActor [weak self] in
                self?.handleOutputFailedUnexpectedly(message: message)
            }
        }
        let recordingOutput = SCRecordingOutput(configuration: recordingConfiguration, delegate: outputDelegate)
        let captureStream = SCStream(filter: filter, configuration: configuration, delegate: streamDelegate)

        do {
            try captureStream.addRecordingOutput(recordingOutput)
            try await captureStream.startCapture()
        } catch {
            try? captureStream.removeRecordingOutput(recordingOutput)
            try? fileManager.removeItem(at: outputURL)
            throw error
        }

        output = recordingOutput
        self.outputDelegate = outputDelegate
        self.finishSignal = finishSignal
        stream = captureStream
        activeOutputURL = outputURL
        activeTarget = resolvedTarget
        activeAudioOptions = resolvedAudio
        recordingStartedAt = .now
        isStopping = false
        isRecording = true
    }

    func stopRecording() async throws -> URL {
        guard !isStopping else {
            throw ScreenRecorderError.alreadyStopping
        }
        guard isRecording, let stream, let outputURL = activeOutputURL, let finishSignal else {
            throw ScreenRecorderError.noActiveRecording
        }
        isStopping = true
        defer { resetRecordingState() }
        do {
            try await stream.stopCapture()
            let failure = await finishSignal.wait()
            if let failure, !failure.isEmpty {
                try? fileManager.removeItem(at: outputURL)
                throw ScreenRecorderError.outputFailed(failure)
            }
            return outputURL
        } catch {
            try? fileManager.removeItem(at: outputURL)
            lastError = error.localizedDescription
            throw error
        }
    }

    private func buildFilterAndConfiguration(
        for options: RecordingOptions
    ) async throws -> (SCContentFilter, SCStreamConfiguration, CaptureTarget, RecordingAudioOptions) {
        let configuration = SCStreamConfiguration()
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 8
        configuration.showsCursor = true
        configuration.capturesAudio = options.audio.capturesSystemAudio
        configuration.captureMicrophone = options.audio.capturesMicrophone
        var resolvedAudio = options.audio
        if options.audio.capturesMicrophone,
           let deviceID = options.audio.microphoneDeviceID,
           !deviceID.isEmpty {
            if microphones.contains(where: { $0.id == deviceID }) {
                configuration.microphoneCaptureDeviceID = deviceID
            } else {
                resolvedAudio.microphoneDeviceID = nil
                selectedMicrophoneID = ""
            }
        }
        configuration.sampleRate = 48_000
        configuration.channelCount = 2

        switch options.target {
        case .display(let choice):
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let scDisplay = content.displays.first(where: { $0.displayID == choice.id }) else {
                throw ScreenRecorderError.displayUnavailable
            }
            let filter = SCContentFilter(display: scDisplay, excludingApplications: [], exceptingWindows: [])
            let info = SCShareableContent.info(for: filter)
            let scale = info.pointPixelScale > 0 ? CGFloat(info.pointPixelScale) : choice.backingScaleFactor
            configuration.width = evenPixelDimension(CGFloat(scDisplay.width) * scale)
            configuration.height = evenPixelDimension(CGFloat(scDisplay.height) * scale)
            let resolved = displays.first(where: { $0.id == choice.id }) ?? choice
            return (filter, configuration, .display(resolved), resolvedAudio)

        case .window(let choice):
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let scWindow = content.windows.first(where: { $0.windowID == choice.id }) else {
                throw ScreenRecorderError.windowUnavailable
            }
            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let info = SCShareableContent.info(for: filter)
            let fallbackScale = screenScale(forWindowFrame: scWindow.frame, in: content.displays)
            let scale = info.pointPixelScale > 0 ? CGFloat(info.pointPixelScale) : fallbackScale
            let logicalSize = (info.contentRect.width > 0 && info.contentRect.height > 0)
                ? info.contentRect.size
                : scWindow.frame.size
            configuration.width = evenPixelDimension(logicalSize.width * scale, minimum: 16)
            configuration.height = evenPixelDimension(logicalSize.height * scale, minimum: 16)
            configuration.scalesToFit = true
            configuration.preservesAspectRatio = true
            let updatedWindow = WindowChoice(
                id: scWindow.windowID,
                title: scWindow.title ?? choice.title,
                appName: scWindow.owningApplication?.applicationName ?? choice.appName,
                bundleIdentifier: scWindow.owningApplication?.bundleIdentifier ?? choice.bundleIdentifier,
                width: Int(logicalSize.width.rounded()),
                height: Int(logicalSize.height.rounded()),
                frame: scWindow.frame
            )
            return (filter, configuration, .window(updatedWindow), resolvedAudio)

        case .region(let choice):
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let scDisplay = content.displays.first(where: { $0.displayID == choice.displayID }) else {
                throw ScreenRecorderError.displayUnavailable
            }
            let displayBounds = CGRect(x: 0, y: 0, width: scDisplay.width, height: scDisplay.height)
            let clampedRect = choice.rectInDisplayPoints.intersection(displayBounds)
            guard clampedRect.width >= 16, clampedRect.height >= 16 else {
                throw ScreenRecorderError.invalidRegion
            }
            let filter = SCContentFilter(display: scDisplay, excludingApplications: [], exceptingWindows: [])
            let info = SCShareableContent.info(for: filter)
            let scale = info.pointPixelScale > 0 ? CGFloat(info.pointPixelScale) : choice.pixelScale
            configuration.sourceRect = clampedRect
            configuration.width = evenPixelDimension(clampedRect.width * scale, minimum: 16)
            configuration.height = evenPixelDimension(clampedRect.height * scale, minimum: 16)
            configuration.scalesToFit = true
            configuration.preservesAspectRatio = true
            let resolvedRegion = RegionChoice(
                displayID: choice.displayID,
                displayName: choice.displayName,
                rectInDisplayPoints: clampedRect,
                pixelScale: scale
            )
            return (filter, configuration, .region(resolvedRegion), resolvedAudio)
        }
    }

    private func screenScale(forWindowFrame frame: CGRect, in scDisplays: [SCDisplay]) -> CGFloat {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if let matchedSCDisplay = scDisplays.first(where: { $0.frame.contains(center) }) ??
            scDisplays.max(by: { lhs, rhs in
                let lhsArea = lhs.frame.intersection(frame).width * lhs.frame.intersection(frame).height
                let rhsArea = rhs.frame.intersection(frame).width * rhs.frame.intersection(frame).height
                return lhsArea < rhsArea
            }),
           let screen = NSScreen.screens.first(where: {
               ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == matchedSCDisplay.displayID
           }) {
            return screen.backingScaleFactor
        }
        return NSScreen.main?.backingScaleFactor ?? 2
    }

    private func handleStreamStoppedUnexpectedly(message: String) {
        guard isRecording, !isStopping else { return }
        if let outputURL = activeOutputURL {
            try? fileManager.removeItem(at: outputURL)
        }
        let formatted = "录制流已中断：\(message)"
        lastError = formatted
        unexpectedFailureMessage = formatted
        finishSignal?.finish(errorMessage: message)
        resetRecordingState()
    }

    private func handleOutputFailedUnexpectedly(message: String) {
        guard isRecording, !isStopping else { return }
        let activeStream = stream
        let outputURL = activeOutputURL
        let formatted = "录制文件写入失败：\(message)"
        lastError = formatted
        unexpectedFailureMessage = formatted
        finishSignal?.finish(errorMessage: message)
        resetRecordingState()
        if let activeStream {
            Task { try? await activeStream.stopCapture() }
        }
        if let outputURL {
            try? fileManager.removeItem(at: outputURL)
        }
    }

    func consumeUnexpectedFailure() -> String? {
        defer { unexpectedFailureMessage = nil }
        return unexpectedFailureMessage
    }

    private func resetRecordingState() {
        stream = nil
        output = nil
        outputDelegate = nil
        finishSignal = nil
        activeOutputURL = nil
        activeTarget = nil
        activeAudioOptions = RecordingAudioOptions()
        recordingStartedAt = nil
        isStarting = false
        isStopping = false
        isRecording = false
    }
}

private func evenPixelDimension(_ value: CGFloat, minimum: Int = 2) -> Int {
    let rounded = max(minimum, Int(value.rounded()))
    return rounded.isMultiple(of: 2) ? rounded : rounded + 1
}

private enum ScreenRecorderError: LocalizedError {
    case displayUnavailable
    case windowUnavailable
    case invalidRegion
    case microphonePermissionDenied
    case noActiveRecording
    case alreadyStopping
    case outputFailed(String)

    var errorDescription: String? {
        switch self {
        case .displayUnavailable: "所选显示器已不可用，请刷新屏幕列表。"
        case .windowUnavailable: "所选窗口已关闭或不可用，请刷新窗口列表。"
        case .invalidRegion: "所选区域无效或尺寸过小，请重新框选。"
        case .microphonePermissionDenied: "未获得麦克风权限，请在「系统设置 → 隐私与安全性 → 麦克风」中允许 RecordOS 访问。"
        case .noActiveRecording: "当前没有正在进行的录制。"
        case .alreadyStopping: "正在停止录制，请稍候。"
        case .outputFailed(let message): "录制文件写入失败：\(message)"
        }
    }
}

private final class StreamDelegate: NSObject, SCStreamDelegate, @unchecked Sendable {
    var onStreamStopWithError: (@Sendable (String) -> Void)?

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let message = error.localizedDescription
        NSLog("RecordOS capture stream stopped: %@", message)
        onStreamStopWithError?(message)
    }
}

private final class RecordingDelegate: NSObject, SCRecordingOutputDelegate {
    private let finishSignal: RecordingFinishSignal
    private let onFail: @Sendable (String) -> Void

    init(finishSignal: RecordingFinishSignal, onFail: @escaping @Sendable (String) -> Void) {
        self.finishSignal = finishSignal
        self.onFail = onFail
    }

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {}

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        finishSignal.finish()
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        let message = error.localizedDescription
        NSLog("RecordOS recording output failed: %@", message)
        finishSignal.finish(errorMessage: message)
        onFail(message)
    }
}

private final class RecordingFinishSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var isFinished = false
    private var failureMessage: String?
    private var waiters: [CheckedContinuation<String?, Never>] = []

    func wait() async -> String? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isFinished {
                let failureMessage = failureMessage
                lock.unlock()
                continuation.resume(returning: failureMessage)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func finish(errorMessage: String? = nil) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        failureMessage = errorMessage
        let waiters = waiters
        self.waiters.removeAll()
        lock.unlock()
        waiters.forEach { $0.resume(returning: errorMessage) }
    }
}
