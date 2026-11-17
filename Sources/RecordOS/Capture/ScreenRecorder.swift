import AppKit
import CoreMedia
import Foundation
import ScreenCaptureKit

struct DisplayChoice: Identifiable, Hashable {
    var id: CGDirectDisplayID
    var name: String
    var width: Int
    var height: Int

    var summary: String { "\(name) · \(width) × \(height)" }
}

@MainActor
final class ScreenRecorder: ObservableObject {
    @Published private(set) var displays: [DisplayChoice] = []
    @Published private(set) var isRecording = false
    @Published private(set) var isStopping = false
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var activeDisplay: DisplayChoice?
    @Published private(set) var lastError: String?

    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private let streamDelegate = StreamDelegate()
    private var outputDelegate: RecordingDelegate?
    private var finishSignal: RecordingFinishSignal?
    private let fileManager = FileManager.default

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
                width: Int(screen.frame.width * scale),
                height: Int(screen.frame.height * scale)
            )
        }
    }

    func startRecording(displayID: CGDirectDisplayID) async throws {
        guard !isRecording else { return }
        lastError = nil

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenRecorderError.displayUnavailable
        }

        try fileManager.createDirectory(at: recordingsURL, withIntermediateDirectories: true)
        let outputURL = recordingsURL.appendingPathComponent("Take-\(UUID().uuidString).mov")
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = display.width
        configuration.height = display.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 8
        configuration.showsCursor = true
        configuration.capturesAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2

        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = outputURL
        recordingConfiguration.outputFileType = .mov
        recordingConfiguration.videoCodecType = .h264

        let finishSignal = RecordingFinishSignal()
        let outputDelegate = RecordingDelegate(finishSignal: finishSignal)
        let recordingOutput = SCRecordingOutput(configuration: recordingConfiguration, delegate: outputDelegate)
        let captureStream = SCStream(filter: filter, configuration: configuration, delegate: streamDelegate)
        try captureStream.addRecordingOutput(recordingOutput)
        try await captureStream.startCapture()

        output = recordingOutput
        self.outputDelegate = outputDelegate
        self.finishSignal = finishSignal
        stream = captureStream
        activeOutputURL = outputURL
        activeDisplay = displays.first(where: { $0.id == displayID })
            ?? DisplayChoice(id: displayID, name: "显示器", width: display.width, height: display.height)
        recordingStartedAt = .now
        isStopping = false
        isRecording = true
    }

    private var activeOutputURL: URL?

    func stopRecording() async throws -> URL {
        guard !isStopping else {
            throw ScreenRecorderError.alreadyStopping
        }
        guard let stream, let outputURL = activeOutputURL, let finishSignal else {
            throw ScreenRecorderError.noActiveRecording
        }
        isStopping = true
        defer { resetRecordingState() }
        do {
            try await stream.stopCapture()
            let failure = await finishSignal.wait()
            if let failure, !failure.isEmpty {
                throw ScreenRecorderError.outputFailed(failure)
            }
            return outputURL
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    private func resetRecordingState() {
        stream = nil
        output = nil
        outputDelegate = nil
        finishSignal = nil
        activeOutputURL = nil
        activeDisplay = nil
        recordingStartedAt = nil
        isStopping = false
        isRecording = false
    }
}

private enum ScreenRecorderError: LocalizedError {
    case displayUnavailable
    case noActiveRecording
    case alreadyStopping
    case outputFailed(String)

    var errorDescription: String? {
        switch self {
        case .displayUnavailable: "所选显示器已不可用，请刷新屏幕列表。"
        case .noActiveRecording: "当前没有正在进行的录制。"
        case .alreadyStopping: "正在停止录制，请稍候。"
        case .outputFailed(let message): "录制文件写入失败：\(message)"
        }
    }
}

private final class StreamDelegate: NSObject, SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("RecordOS capture stream stopped: %@", error.localizedDescription)
    }
}

private final class RecordingDelegate: NSObject, SCRecordingOutputDelegate {
    private let finishSignal: RecordingFinishSignal

    init(finishSignal: RecordingFinishSignal) {
        self.finishSignal = finishSignal
    }

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {}

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        finishSignal.finish()
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        NSLog("RecordOS recording output failed: %@", error.localizedDescription)
        finishSignal.finish(errorMessage: error.localizedDescription)
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
