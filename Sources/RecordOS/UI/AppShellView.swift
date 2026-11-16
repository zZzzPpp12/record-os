import SwiftUI

struct AppShellView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            mainContent
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("RecordOS", isPresented: alertPresented) {
            Button("好", role: .cancel) { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 10) {
                Image(systemName: "record.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.red)
                Text("RecordOS")
                    .font(.system(size: 17, weight: .semibold))
            }
            .padding(.top, 22)
            .padding(.horizontal, 18)

            VStack(spacing: 5) {
                ForEach(AppRoute.allCases) { route in
                    Button {
                        model.route = route
                    } label: {
                        Label(route.title, systemImage: route.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(model.route == route ? Color.accentColor : Color.primary.opacity(0.75))
                    .background {
                        if model.route == route {
                            RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.11))
                        }
                    }
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            Text("本地录制 · 本地项目")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
                .padding(.bottom, 16)
        }
        .frame(width: 198)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    @ViewBuilder
    private var mainContent: some View {
        switch model.route {
        case .record:
            RecorderView()
        case .library:
            if let editor = model.activeEditor {
                EditorView(session: editor)
            } else {
                LibraryView()
            }
        case .settings:
            SettingsView()
        }
    }

    private var alertPresented: Binding<Bool> {
        Binding(
            get: { model.alertMessage != nil },
            set: { if !$0 { model.alertMessage = nil } }
        )
    }
}
