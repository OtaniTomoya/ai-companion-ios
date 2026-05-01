import SwiftUI

struct ControlPanelView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var locationAuthorization: LocationAuthorizationManager
    @ObservedObject var calendarContext: CalendarContextManager
    var connectionState: ChatConnectionState
    @Binding var isMuted: Bool
    var onConnect: () -> Void
    var onDisconnect: () -> Void

    @State private var isSettingsPresented = false

    private var isConnected: Bool {
        connectionState == .connected
    }

    private var connectionButtonTint: Color {
        switch connectionState {
        case .connected:
            .green
        case .error:
            .red
        default:
            .gray
        }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            regularLayout
            compactLayout
        }
        .sheet(isPresented: $isSettingsPresented) {
            NavigationStack {
                SettingsPanelView(
                    settings: settings,
                    locationAuthorization: locationAuthorization,
                    calendarContext: calendarContext
                )
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("完了") {
                                isSettingsPresented = false
                            }
                        }
                    }
            }
        }
    }

    private var regularLayout: some View {
        HStack(spacing: 10) {
            statusBadge
            Spacer(minLength: 8)
            actionButtons
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var compactLayout: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusBadge
                .frame(maxWidth: .infinity, alignment: .leading)
            actionButtons
        }
        .padding(10)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: connectionState.systemImage)
                .font(.subheadline.weight(.semibold))
                .frame(width: 17, height: 17)
                .foregroundStyle(connectionState.tint)
            Text(connectionState.label)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.primary)
        .accessibilityElement(children: .combine)
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button {
                isConnected ? onDisconnect() : onConnect()
            } label: {
                Label(isConnected ? "切断" : "接続", systemImage: connectionState.systemImage)
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderedProminent)
            .tint(connectionButtonTint)
            .disabled(connectionState == .connecting)
            .accessibilityLabel(isConnected ? "切断" : "接続")

            Button {
                isMuted.toggle()
            } label: {
                Label(isMuted ? "ミュート解除" : "ミュート", systemImage: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel(isMuted ? "ミュート解除" : "ミュート")

            Button {
                isSettingsPresented = true
            } label: {
                Label("設定", systemImage: "gearshape")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("設定")
        }
        .controlSize(.large)
    }
}

#Preview {
    @Previewable @State var muted = false

    ControlPanelView(
        settings: AppSettings(),
        locationAuthorization: LocationAuthorizationManager(),
        calendarContext: CalendarContextManager(),
        connectionState: .connected,
        isMuted: $muted,
        onConnect: {},
        onDisconnect: {}
    )
    .padding()
}
