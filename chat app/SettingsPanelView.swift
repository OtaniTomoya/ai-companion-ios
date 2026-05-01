import SwiftUI

struct SettingsPanelView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var locationAuthorization: LocationAuthorizationManager
    @ObservedObject var calendarContext: CalendarContextManager

    var body: some View {
        Form {
            Section("接続") {
                TextField("WebSocket URL", text: $settings.websocketURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)

                SecureField("APIキー 任意", text: $settings.apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                #if DEBUG
                HStack(spacing: 10) {
                    Button {
                        settings.useLocalBackend()
                    } label: {
                        Label("ローカル", systemImage: "desktopcomputer")
                    }
                    .buttonStyle(.bordered)
                }
                #endif
            }

            Section("動作") {
                Toggle("バージイン", isOn: $settings.bargeInEnabled)
                Toggle("予定を会話文脈に使う", isOn: $settings.calendarContextEnabled)
            }

            Section("カレンダー") {
                Label(calendarContext.authorizationSummary, systemImage: "calendar")

                Text(calendarContext.eventsSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let lastErrorMessage = calendarContext.lastErrorMessage {
                    Text(lastErrorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button {
                    if calendarContext.authorizationState.canReadEvents {
                        calendarContext.refreshUpcomingEventsIfAuthorized()
                    } else {
                        calendarContext.requestFullAccessAndRefresh()
                    }
                } label: {
                    Label(
                        calendarContext.authorizationState.canReadEvents ? "予定を再読み込み" : "アクセスを許可",
                        systemImage: "calendar.badge.checkmark"
                    )
                }

                Button {
                    calendarContext.openSystemSettings()
                } label: {
                    Label("iOS設定を開く", systemImage: "gearshape")
                }
            }

            Section("位置情報") {
                Label(locationAuthorization.authorizationSummary, systemImage: "location.fill")

                Text(locationAuthorization.latestLocationSummary)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                if let lastErrorMessage = locationAuthorization.lastErrorMessage {
                    Text(lastErrorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                Button {
                    locationAuthorization.requestForegroundAuthorization()
                } label: {
                    Label("使用中のみ許可して取得", systemImage: "location.viewfinder")
                }

                Button {
                    locationAuthorization.openSystemSettings()
                } label: {
                    Label("iOS設定を開く", systemImage: "gearshape")
                }
            }

            Section("音声") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("リップシンク感度")
                        Spacer()
                        Text(settings.lipSyncSensitivity, format: .percent)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $settings.lipSyncSensitivity, in: 0...1)
                }
            }
        }
        .navigationTitle("設定")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        SettingsPanelView(
            settings: AppSettings(),
            locationAuthorization: LocationAuthorizationManager(),
            calendarContext: CalendarContextManager()
        )
    }
}
