import AVFoundation
import AppKit
import SwiftUI

struct RecorderView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isSelectingRegion = false
    @State private var isWorking = false
    @State private var regionController = RegionSelectionController()

    private var controlsDisabled: Bool {
        model.recorder.isRecording || model.recorder.isStarting || isWorking || isSelectingRegion
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeading(title: "录制", subtitle: "选择屏幕、窗口或框选区域开始录制，完成后会自动创建本地项目。")

            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("录制来源")
                        .font(.headline)

                    HStack(spacing: 10) {
                        ForEach(CaptureSourceKind.allCases) { kind in
                            sourceCard(kind: kind)
                        }
                    }

                    targetPickerSection

                    Divider()

                    audioSettingsSection

                    if let error = model.recorder.lastError {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }

                    Spacer(minLength: 6)

                    recordingActionBar
                }
                .padding(22)
                .frame(maxWidth: 590, minHeight: 440, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(model.recorder.isRecording ? Color.red.opacity(0.45) : Color.secondary.opacity(0.25))
                )

                VStack(alignment: .leading, spacing: 14) {
                    Label("录制流程", systemImage: "sparkles")
                        .font(.headline)
                    Text("1. 选择整个屏幕、指定窗口或框选区域\n2. 按需开启系统声音与麦克风\n3. 停止后自动保存为本地项目")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineSpacing(7)
                    Divider()
                    Text("采集参数")
                        .font(.subheadline.weight(.semibold))
                    Text("30 fps · H.264 · MOV\n系统声音与麦克风随录制写入同一 MOV 源文件。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineSpacing(4)
                    Spacer()
                }
                .padding(20)
                .frame(maxWidth: 255, minHeight: 280, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            }

            Spacer()
        }
        .padding(28)
        .task {
            if model.recorder.displays.isEmpty {
                await model.recorder.refreshDisplays()
            }
            model.recorder.refreshMicrophones()
        }
        .onDisappear {
            if isSelectingRegion {
                regionController.cancelSelection()
            }
        }
        .onChange(of: model.recorder.selectedSourceKind) { _, newKind in
            if newKind == .window && model.recorder.windows.isEmpty {
                Task { await model.recorder.refreshWindows() }
            }
        }
    }

    private func sourceCard(kind: CaptureSourceKind) -> some View {
        let isSelected = model.recorder.selectedSourceKind == kind
        return Button {
            model.recorder.selectedSourceKind = kind
        } label: {
            VStack(spacing: 9) {
                Image(systemName: kind.symbol).font(.system(size: 19))
                Text(kind.title).font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 76)
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary.opacity(0.75))
            .background(
                isSelected ? Color.accentColor.opacity(0.11) : Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.45) : Color.secondary.opacity(0.18))
            )
        }
        .buttonStyle(.plain)
        .disabled(controlsDisabled)
    }

    @ViewBuilder
    private var targetPickerSection: some View {
        switch model.recorder.selectedSourceKind {
        case .display:
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("显示器")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Button("刷新") {
                        Task { await model.recorder.refreshDisplays() }
                    }
                    .buttonStyle(.link)
                    .disabled(controlsDisabled)
                }

                if model.recorder.displays.isEmpty {
                    Text("尚未读取屏幕列表。首次使用请先授予屏幕录制权限。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
                } else {
                    Picker("显示器", selection: Binding(
                        get: { model.recorder.selectedDisplayID },
                        set: { model.recorder.selectedDisplayID = $0 }
                    )) {
                        ForEach(model.recorder.displays) { display in
                            Text(display.summary).tag(display.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
                    .disabled(controlsDisabled)
                }
            }

        case .window:
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("应用窗口")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Button(model.recorder.isLoadingWindows ? "读取中…" : "刷新窗口") {
                        Task { await model.recorder.refreshWindows() }
                    }
                    .buttonStyle(.link)
                    .disabled(controlsDisabled || model.recorder.isLoadingWindows)
                }

                if model.recorder.windows.isEmpty {
                    Text("未找到可录制的应用窗口。请确认目标窗口未最小化并已授予屏幕录制权限。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
                } else {
                    Picker("应用窗口", selection: Binding(
                        get: { model.recorder.selectedWindowID },
                        set: { model.recorder.selectedWindowID = $0 }
                    )) {
                        ForEach(model.recorder.windows) { window in
                            Text(window.summary).tag(window.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
                    .disabled(controlsDisabled)
                }
            }

        case .region:
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("录制区域")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    if model.recorder.selectedRegion != nil {
                        Button("清除选区") {
                            model.recorder.selectedRegion = nil
                        }
                        .buttonStyle(.link)
                        .disabled(controlsDisabled)
                    }
                }

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        if let region = model.recorder.selectedRegion {
                            Text(region.summary)
                                .font(.callout.weight(.medium))
                            Text("位置：(\(Int(region.rectInDisplayPoints.minX)), \(Int(region.rectInDisplayPoints.minY))) pt")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("尚未框选录制区域")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Text("点击右侧按钮后可在任意屏幕上拖拽画框并微调大小")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button {
                        Task { await selectRegion() }
                    } label: {
                        Label(model.recorder.selectedRegion == nil ? "框选区域…" : "重新框选…", systemImage: "viewfinder")
                    }
                    .buttonStyle(.bordered)
                    .disabled(controlsDisabled)
                }
                .padding(12)
                .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
            }
        }
    }

    private var audioSettingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("音频输入")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(model.recorder.currentAudioOptions.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 20) {
                Toggle("系统声音", isOn: Binding(
                    get: { model.recorder.capturesSystemAudio },
                    set: { model.recorder.capturesSystemAudio = $0 }
                ))
                    .toggleStyle(.checkbox)
                    .disabled(controlsDisabled)

                Toggle("麦克风", isOn: Binding(
                    get: { model.recorder.capturesMicrophone },
                    set: { model.recorder.capturesMicrophone = $0 }
                ))
                    .toggleStyle(.checkbox)
                    .disabled(controlsDisabled)
            }

            if model.recorder.capturesMicrophone {
                HStack(spacing: 10) {
                    Picker("麦克风设备", selection: Binding(
                        get: { model.recorder.selectedMicrophoneID },
                        set: { model.recorder.selectedMicrophoneID = $0 }
                    )) {
                        Text("系统默认麦克风").tag("")
                        ForEach(model.recorder.microphones) { mic in
                            Text(mic.isDefault ? "\(mic.name)（系统默认）" : mic.name)
                                .tag(mic.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .disabled(controlsDisabled)

                    Button("刷新") {
                        model.recorder.refreshMicrophones()
                    }
                    .buttonStyle(.link)
                    .disabled(controlsDisabled)
                }
                .padding(10)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 9))

                if model.recorder.microphoneAuthStatus == .denied || model.recorder.microphoneAuthStatus == .restricted {
                    HStack(spacing: 8) {
                        Text("当前未授权麦克风权限，录制人声前请先在系统设置中开启。")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("前往设置") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
            }
        }
    }

    private var recordingActionBar: some View {
        HStack(spacing: 12) {
            if model.recorder.isRecording {
                RecordingPulseDot()
                VStack(alignment: .leading, spacing: 2) {
                    Text("当前正在录制中")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.red)
                    if let startedAt = model.recorder.recordingStartedAt {
                        TimelineView(.periodic(from: startedAt, by: 1)) { context in
                            let elapsed = max(0, context.date.timeIntervalSince(startedAt))
                            Text("已录制 \(elapsed.formattedDuration) · 切换页面也会继续录制")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                Button(model.recorder.isStopping ? "正在保存…" : "停止并打开项目") {
                    Task { await stopRecording() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(isWorking || model.recorder.isStopping)
            } else {
                Label("当前未在录制", systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await startRecording() }
                } label: {
                    Label(isWorking ? "准备中…" : "开始录制", systemImage: "record.circle")
                        .frame(minWidth: 142)
                }
                .buttonStyle(.borderedProminent)
                .disabled(controlsDisabled || model.recorder.currentCaptureTarget == nil)
            }
        }
        .padding(12)
        .background(
            (model.recorder.isRecording ? Color.red.opacity(0.08) : Color(nsColor: .controlBackgroundColor)),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(model.recorder.isRecording ? Color.red.opacity(0.35) : Color.clear)
        )
    }

    private func selectRegion() async {
        guard !controlsDisabled else { return }
        isSelectingRegion = true
        let previousKeyWindow = NSApp.keyWindow
        let windowsToRestore = NSApp.windows.filter { window in
            window.isVisible &&
            window.canBecomeKey &&
            window.level == .normal
        }
        windowsToRestore.forEach { $0.orderOut(nil) }
        defer {
            for window in windowsToRestore {
                window.orderFront(nil)
            }
            if let previousKeyWindow, windowsToRestore.contains(previousKeyWindow) {
                previousKeyWindow.makeKeyAndOrderFront(nil)
            } else {
                windowsToRestore.first?.makeKeyAndOrderFront(nil)
            }
            NSApp.activate(ignoringOtherApps: true)
            isSelectingRegion = false
        }

        if let result = await regionController.selectRegion() {
            model.recorder.selectedRegion = RegionChoice(
                displayID: result.displayID,
                displayName: result.displayName,
                rectInDisplayPoints: result.rectInDisplayPoints,
                pixelScale: result.pixelScale
            )
        }
    }

    private func startRecording() async {
        guard let target = model.recorder.currentCaptureTarget else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let options = RecordingOptions(target: target, audio: model.recorder.currentAudioOptions)
            try await model.recorder.startRecording(options: options)
        } catch {
            model.alertMessage = "无法开始录制：\(error.localizedDescription)"
        }
    }

    private func stopRecording() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let trackNames = model.recorder.audioTrackNames(for: model.recorder.activeAudioOptions)
            let url = try await model.recorder.stopRecording()
            await model.finishRecording(at: url, audioTrackNames: trackNames)
        } catch {
            model.alertMessage = "停止录制失败：\(error.localizedDescription)"
        }
    }
}
