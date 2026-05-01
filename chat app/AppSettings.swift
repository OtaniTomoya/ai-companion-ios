import Combine
import Security
import SwiftUI

enum ChatConnectionState: String, CaseIterable, Identifiable {
    case disconnected
    case connecting
    case connected
    case error

    var id: String { rawValue }

    var label: String {
        switch self {
        case .disconnected:
            "未接続"
        case .connecting:
            "接続中"
        case .connected:
            "接続済み"
        case .error:
            "エラー"
        }
    }

    var tint: Color {
        switch self {
        case .disconnected:
            .gray
        case .connecting:
            .orange
        case .connected:
            .green
        case .error:
            .red
        }
    }

    var systemImage: String {
        switch self {
        case .disconnected:
            "bolt.slash"
        case .connecting:
            "bolt"
        case .connected:
            "bolt.fill"
        case .error:
            "bolt.slash.fill"
        }
    }
}

struct ConversationMessage: Identifiable, Equatable {
    enum Speaker: String {
        case user
        case assistant
        case system

        var label: String {
            switch self {
            case .user:
                "あなた"
            case .assistant:
                "AIアバター"
            case .system:
                "システム"
            }
        }
    }

    let id: UUID
    var speaker: Speaker
    var text: String
    var date: Date

    init(id: UUID = UUID(), speaker: Speaker, text: String, date: Date = Date()) {
        self.id = id
        self.speaker = speaker
        self.text = text
        self.date = date
    }
}

@MainActor
final class AppSettings: ObservableObject {
    #if DEBUG
    static let defaultWebSocketURL = "ws://127.0.0.1:8000/ws"
    #else
    static let defaultWebSocketURL = "wss://your-backend.example.com/ws"
    #endif

    static let productionPlaceholderWebSocketURL = "wss://your-backend.example.com/ws"
    private static let apiKeyStorageKey = "chatApp.apiKey"

    #if DEBUG
    static let localBackendWebSocketURL = "ws://127.0.0.1:8000/ws"
    #endif

    @AppStorage("chatApp.websocketURL") var websocketURL = AppSettings.defaultWebSocketURL {
        didSet { objectWillChange.send() }
    }

    @Published var apiKey = AppSettings.loadAPIKey() {
        didSet { AppSettings.storeAPIKey(apiKey) }
    }

    @AppStorage("chatApp.bargeInEnabled.v2") var bargeInEnabled = false {
        didSet { objectWillChange.send() }
    }

    @AppStorage("chatApp.calendarContextEnabled") var calendarContextEnabled = false {
        didSet { objectWillChange.send() }
    }

    @AppStorage("chatApp.lipSyncSensitivity") var lipSyncSensitivity = 0.55 {
        didSet { objectWillChange.send() }
    }

    var hasAPIKey: Bool {
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasConfiguredWebSocketURL: Bool {
        let trimmedURL = websocketURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedURL.isEmpty && trimmedURL != Self.productionPlaceholderWebSocketURL
    }

    #if DEBUG
    func useLocalBackend() {
        websocketURL = Self.localBackendWebSocketURL
    }
    #endif

    private static func loadAPIKey() -> String {
        KeychainStore.string(forKey: apiKeyStorageKey) ?? ""
    }

    private static func storeAPIKey(_ apiKey: String) {
        KeychainStore.set(apiKey, forKey: apiKeyStorageKey)
    }
}

private enum KeychainStore {
    private static var service: String {
        Bundle.main.bundleIdentifier ?? "com.Tomoya.chat-app"
    }

    static func string(forKey key: String) -> String? {
        var query = baseQuery(forKey: key)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, forKey key: String) {
        deleteValue(forKey: key)

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty, let data = trimmedValue.data(using: .utf8) else {
            return
        }

        var query = baseQuery(forKey: key)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func deleteValue(forKey key: String) {
        SecItemDelete(baseQuery(forKey: key) as CFDictionary)
    }

    private static func baseQuery(forKey key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }
}
