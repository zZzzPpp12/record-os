import SwiftUI

struct RecorderView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedDisplayID: UInt32 = 0
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            PageHeading(title: "录制", subtitle: "选择屏幕并开始录制，完成后会自动创建本地项目。")

            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("录制来源")
                        .font(.headline)

                    HStack(spacing: 10) {
                        sourceCard(title: "整个屏幕", symbol: "display", enabled: true)
                        sourceCard(title: "窗口", symbol: "macwindow", enabled: false)
                        sourceCard(title: "区域", symbol: "viewfinder", enabled: false)
                    }

                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Text("显示器")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                            Button("刷新") {
                                Task { await refreshDisplays() }
                            }
                            .buttonStyle(.link)
                        }

                        if model.recorder.displays.isEmpty {
                            Text("尚未读取屏幕列表。首次使用请先授予屏幕录制权限。")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
                        } else {
                            Picker("显示器", selection: $selectedDisplayID) {
                                ForEach(model.recorder.displays) { display in
                                    Text(display.summary).tag(display.id)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
                            .disabled(model.recorder.isRecording)
                        }
                    }

                    HStack(spacing: 12) {
                        Image(systemName: "waveform")
                            .foregroundStyle(.secondary)
                        Text("系统声音会随屏幕录制写入 MOV 文件。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    if let error = model.recorder.lastError {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }

                    Spacer(minLength: 10)

                    HStack(spacing: 12) {
                        if model.recorder.isRecording {
                            RecordingPulseDot()
                            VStack(alignment: .leading, spacing: 2) {
                                Text("当前屏幕正在录制中")
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
                            .disabled(isWorking || selectedDisplayID == 0)
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
                .padding(22)
                .frame(maxWidth: 560, minHeight: 370, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(model.recorder.isRecording ? Color.red.opacity(0.45) : Color.secondary.opacity(0.25)))

                VStack(alignment: .leading, spacing: 14) {
                    Label("录制流程", systemImage: "sparkles")
                        .font(.headline)
                    Text("1. 选择显示器\n2. 开始采集画面与系统声音\n3. 停止后自动保存为项目")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineSpacing(7)
                    Divider()
                    Text("当前原型")
                        .font(.subheadline.weight(.semibold))
                    Text("30 fps · H.264 · MOV\n源文件保存在本机应用支持目录。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(20)
                .frame(maxWidth: 255, minHeight: 260, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            }

            Spacer()
        }
        .padding(28)
        .task { await refreshDisplays() }
    }

    private func sourceCard(title: String, symbol: String, enabled: Bool) -> some View {
        VStack(spacing: 9) {
            Image(systemName: symbol).font(.system(size: 19))
            Text(title).font(.caption.weight(.medium))
            if !enabled { Text("后续接入").font(.system(size: 10)).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 82)
        .foregroundStyle(enabled ? Color.accentColor : Color.secondary)
        .background(enabled ? Color.accentColor.opacity(0.09) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(enabled ? Color.accentColor.opacity(0.38) : Color.clear))
    }

    private func refreshDisplays() async {
        await model.recorder.refreshDisplays()
        if !model.recorder.displays.contains(where: { $0.id == selectedDisplayID }) {
            selectedDisplayID = model.recorder.displays.first?.id ?? 0
        }
    }

    private func startRecording() async {
        guard selectedDisplayID != 0 else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await model.recorder.startRecording(displayID: selectedDisplayID)
        } catch {
            model.alertMessage = "无法开始录制：\(error.localizedDescription)"
        }
    }

    private func stopRecording() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let url = try await model.recorder.stopRecording()
            await model.finishRecording(at: url)
        } catch {
            model.alertMessage = "停止录制失败：\(error.localizedDescription)"
        }
    }
}
