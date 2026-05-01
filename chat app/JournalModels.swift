//
//  JournalModels.swift
//  chat app
//

import Foundation

struct JournalEntry: Identifiable, Codable, Equatable {
    let id: UUID
    var date: Date
    var createdAt: Date
    var updatedAt: Date
    var title: String
    var overview: String
    var eventNotes: [String]
    var feelingNotes: [String]
    var carryOvers: [String]
    var messages: [JournalMessage]
    var photos: [JournalPhotoItem]
    var locations: [JournalLocationPoint]
    var markdown: String
}

struct JournalDraft: Identifiable, Codable, Equatable {
    let id: UUID
    var date: Date
    var startedAt: Date
    var messages: [JournalMessage]
    var photoItems: [JournalPhotoItem]
    var locationItems: [JournalLocationPoint]
    var nextPromptIndex: Int
    var slotStatuses: [String: JournalSlotStatus]

    static func empty(date: Date = Date()) -> JournalDraft {
        JournalDraft(
            id: UUID(),
            date: date,
            startedAt: Date(),
            messages: [],
            photoItems: [],
            locationItems: [],
            nextPromptIndex: 0,
            slotStatuses: JournalSlot.defaultStatuses
        )
    }
}

struct JournalPromptContext: Equatable {
    var dateText: String
    var requiredSlots: [String]
    var optionalSlots: [String]
    var availableContext: [String]
    var progressSummary: String
    var slotStatuses: [String: String]

    var metadata: [String: Any] {
        [
            "journal_mode": "active",
            "journal_prompt": systemPromptParams
        ]
    }

    var controlMetadata: [String: Any] {
        [
            "journal_mode": "active",
            "journal_control": true,
            "journal_prompt": systemPromptParams
        ]
    }

    var systemPromptParams: [String: Any] {
        [
            "mode": "journal",
            "journal_date": dateText,
            "required_slots": requiredSlots,
            "optional_slots": optionalSlots,
            "available_context": availableContext,
            "progress_summary": progressSummary,
            "slot_statuses": slotStatuses
        ]
    }
}

enum JournalSlotStatus: String, Codable, Equatable {
    case missing
    case filled

    init?(llmValue: Any) {
        guard let text = llmValue as? String else { return nil }
        switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "filled", "fill", "true", "done", "yes", "埋まった", "済み":
            self = .filled
        case "missing", "empty", "false", "none", "no", "未入力", "未完了":
            self = .missing
        default:
            return nil
        }
    }

    var label: String {
        switch self {
        case .missing:
            "未"
        case .filled:
            "済"
        }
    }
}

enum JournalSlot: String, CaseIterable, Codable, Equatable, Identifiable {
    case overallImpression = "今日全体の印象"
    case event = "出来事"
    case feeling = "気持ち"
    case peopleConversation = "人物・会話"
    case carryOver = "明日に残すこと"

    var id: String { rawValue }

    var aliases: [String] {
        switch self {
        case .overallImpression:
            ["今日全体の印象", "全体の印象", "印象"]
        case .event:
            ["出来事", "印象に残った出来事", "イベント"]
        case .feeling:
            ["気持ち", "その時の気持ち", "感情"]
        case .peopleConversation:
            ["人物・会話", "人物", "会話", "誰と話したか"]
        case .carryOver:
            ["明日に残すこと", "明日に残すこと・忘れたくないこと", "忘れたくないこと", "持ち越し"]
        }
    }

    static var labels: [String] {
        allCases.map(\.rawValue)
    }

    static var defaultStatuses: [String: JournalSlotStatus] {
        Dictionary(uniqueKeysWithValues: labels.map { ($0, .missing) })
    }

    static func canonicalLabel(for label: String) -> String? {
        let normalized = normalize(label)
        return allCases.first { slot in
            slot.aliases.contains { normalize($0) == normalized }
        }?.rawValue
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "　", with: "")
            .replacingOccurrences(of: " ", with: "")
            .lowercased()
    }
}

struct JournalSlotStatusUpdate: Equatable {
    let id = UUID()
    var statuses: [String: JournalSlotStatus]
}

struct JournalMessage: Identifiable, Codable, Equatable {
    let id: UUID
    var createdAt: Date
    var speaker: JournalSpeaker
    var text: String
    var source: JournalMessageSource
}

enum JournalSpeaker: String, Codable, Equatable {
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

enum JournalMessageSource: String, Codable, Equatable {
    case voice
    case text
    case conversation
    case photoPrompt
    case locationPrompt
    case system
}

struct JournalPhotoItem: Identifiable, Codable, Equatable {
    let id: UUID
    var fileName: String
    var importedAt: Date
    var capturedAt: Date?
    var userMemo: String
}

struct JournalLocationPoint: Identifiable, Codable, Equatable {
    let id: UUID
    var recordedAt: Date
    var latitude: Double
    var longitude: Double
    var horizontalAccuracy: Double
    var altitude: Double?
    var speed: Double?

    var coordinateText: String {
        let lat = latitude.formatted(.number.precision(.fractionLength(6)))
        let lon = longitude.formatted(.number.precision(.fractionLength(6)))
        return "\(lat), \(lon)"
    }
}
