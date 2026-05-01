//
//  AvatarModels.swift
//  chat app
//

import Foundation

enum AvatarMood: String, CaseIterable, Identifiable, Sendable {
    case neutral
    case happy
    case focused
    case sleepy
    case surprised
    case concerned

    var id: String { rawValue }
}

enum AvatarRuntimeState: Equatable, Sendable {
    case idle
    case listening
    case talking
    case connecting
    case error(String? = nil)

    var isTalking: Bool {
        if case .talking = self { return true }
        return false
    }

    var isListening: Bool {
        if case .listening = self { return true }
        return false
    }

    var isConnecting: Bool {
        if case .connecting = self { return true }
        return false
    }

    var errorMessage: String? {
        if case let .error(message) = self { return message }
        return nil
    }
}

struct AvatarFrameState: Equatable, Sendable {
    var mood: AvatarMood
    var runtimeState: AvatarRuntimeState
    var volumeLevel: Double
    var attentionLevel: Double

    init(
        mood: AvatarMood = .neutral,
        runtimeState: AvatarRuntimeState = .idle,
        volumeLevel: Double = 0,
        attentionLevel: Double = 0.5
    ) {
        self.mood = mood
        self.runtimeState = runtimeState
        self.volumeLevel = volumeLevel.clampedAvatarLevel
        self.attentionLevel = attentionLevel.clampedAvatarLevel
    }

    static let idle = AvatarFrameState()

    static func talking(
        volumeLevel: Double,
        mood: AvatarMood = .happy
    ) -> AvatarFrameState {
        AvatarFrameState(
            mood: mood,
            runtimeState: .talking,
            volumeLevel: volumeLevel,
            attentionLevel: 0.8
        )
    }

    static func listening(
        volumeLevel: Double = 0.12,
        mood: AvatarMood = .focused
    ) -> AvatarFrameState {
        AvatarFrameState(
            mood: mood,
            runtimeState: .listening,
            volumeLevel: volumeLevel,
            attentionLevel: 1
        )
    }
}

private extension Double {
    var clampedAvatarLevel: Double {
        min(max(self, 0), 1)
    }
}
