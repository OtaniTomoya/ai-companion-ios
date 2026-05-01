//
//  ConversationViewModel.swift
//  chat app
//

import Combine
import Foundation
import SwiftUI

final class ConversationViewModel: ObservableObject {
    @Published private(set) var messages: [ConversationMessage] = []
    @Published private(set) var receivedEvents: [AIAvatarWebSocketClient.Event] = []
    @Published private(set) var connectionState: AIAvatarWebSocketClient.ConnectionState = .disconnected
    @Published private(set) var chatConnectionState: ChatConnectionState = .disconnected
    @Published private(set) var microphoneState: AudioEngineManager.MicrophoneState = .idle
    @Published private(set) var isMuted = false
    @Published private(set) var isSpeaking = false
    @Published private(set) var microphoneLevel: Float = 0
    @Published private(set) var speechLevel: Float = 0
    @Published private(set) var currentFace: String = "neutral"
    @Published private(set) var currentAnimation: String = "idle"
    @Published private(set) var isCapturingUserSpeech = false
    @Published private(set) var journalSlotStatusUpdate: JournalSlotStatusUpdate?
    @Published var errorMessage: String?

    let audioManager: AudioEngineManager
    let webSocketClient: AIAvatarWebSocketClient

    private struct CapturedAudioChunk {
        var data: Data
        var format: AudioEngineManager.PCMFormat
        var duration: TimeInterval
    }

    private var bargeInEnabled = false
    private var activeRemoteAssistantMessageID: UUID?
    private var isJournalModeActive = false
    private var currentJournalContext: JournalPromptContext?
    private var preSpeechAudioBuffer: [CapturedAudioChunk] = []
    private var utteranceAudioBuffer: [CapturedAudioChunk] = []
    private var isCapturingUserUtterance = false
    private var capturedVoiceDuration: TimeInterval = 0
    private var trailingSilenceDuration: TimeInterval = 0
    private var microphoneSuppressedUntil = Date.distantPast
    private var lastCameraContextSentAt = Date.distantPast
    private let preSpeechBufferDuration: TimeInterval = 0.25
    private let speechStartLevelThreshold: Float = 0.035
    private let speechEndLevelThreshold: Float = 0.02
    private let utteranceEndSilenceDuration: TimeInterval = 0.7
    private let minimumUtteranceVoiceDuration: TimeInterval = 0.45
    private let activeCameraContextInterval: TimeInterval = 1.2

    init(
        audioManager: AudioEngineManager = AudioEngineManager(),
        webSocketClient: AIAvatarWebSocketClient = AIAvatarWebSocketClient()
    ) {
        self.audioManager = audioManager
        self.webSocketClient = webSocketClient
        bindAudio()
        bindWebSocket()
    }

    deinit {
        audioManager.stopMicrophone()
        audioManager.stopSpeaking()
        webSocketClient.disconnect()
    }

    var avatarFrameState: AvatarFrameState {
        if let errorMessage, !errorMessage.isEmpty {
            return AvatarFrameState(mood: .concerned, runtimeState: .error(errorMessage))
        }
        if isSpeaking {
            return AvatarFrameState.talking(volumeLevel: Double(speechLevel), mood: avatarMood)
        }
        if chatConnectionState == .connecting {
            return AvatarFrameState(mood: .focused, runtimeState: .connecting, volumeLevel: 0.12, attentionLevel: 0.8)
        }
        if microphoneState == .recording && !isMuted {
            return AvatarFrameState.listening(volumeLevel: Double(microphoneLevel), mood: .focused)
        }
        return AvatarFrameState(mood: avatarMood, runtimeState: .idle, volumeLevel: 0, attentionLevel: 0.5)
    }

    func connect(
        to urlString: String,
        apiKey: String? = nil,
        bargeInEnabled: Bool = false
    ) {
        self.bargeInEnabled = bargeInEnabled

        guard let url = URL(string: urlString), url.scheme == "ws" || url.scheme == "wss" else {
            chatConnectionState = .error
            errorMessage = "WebSocket URLが不正です。"
            appendSystemMessage("WebSocket URLが不正です。設定を確認してください。")
            return
        }

        guard url.scheme == "wss" || Self.isLocalPlaintextWebSocket(url) else {
            chatConnectionState = .error
            errorMessage = "外部接続には wss:// のWebSocket URLを設定してください。"
            appendSystemMessage("外部接続には wss:// のWebSocket URLを設定してください。")
            return
        }

        errorMessage = nil
        webSocketClient.connect(to: url, apiKey: apiKey, bargeInEnabled: bargeInEnabled)
    }

    func disconnect() {
        stopRecording()
        stopSpeaking()
        resetUserUtteranceCapture()
        errorMessage = nil
        chatConnectionState = .disconnected
        connectionState = .disconnected
        webSocketClient.disconnect()
        appendSystemMessage("切断しました。")
    }

    func startRecording() {
        audioManager.startMicrophone()
    }

    func stopRecording() {
        audioManager.stopMicrophone()
        resetUserUtteranceCapture()
    }

    func toggleMute() {
        setMuted(!isMuted)
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        audioManager.setMuted(muted)
    }

    func sendMessage(
        _ text: String = "こんにちは",
        visualContext: CameraObservationFrame? = nil
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        appendMessage(speaker: .user, text: trimmed)

        if isWebSocketConnected {
            webSocketClient.sendText(trimmed, visualContext: visualContext)
        } else {
            errorMessage = "サーバーに未接続です。先に接続してください。"
            appendSystemMessage("サーバーに未接続のため送信できませんでした。")
        }
    }

    func sendCameraContext(_ frame: CameraObservationFrame) {
        guard isWebSocketConnected, isCapturingUserSpeech, !isSpeaking else { return }
        let now = Date()
        guard now.timeIntervalSince(lastCameraContextSentAt) >= activeCameraContextInterval else { return }
        lastCameraContextSentAt = now
        webSocketClient.sendCameraContext(frame)
    }

    func suppressMicrophoneInput(for duration: TimeInterval) {
        microphoneSuppressedUntil = Date().addingTimeInterval(duration)
        resetUserUtteranceCapture()
        microphoneLevel = 0
    }

    func setJournalModeActive(_ active: Bool, context: JournalPromptContext? = nil) {
        let updatedContext = active ? (context ?? currentJournalContext) : nil
        let shouldNotifyServer = isJournalModeActive != active || context != nil
        isJournalModeActive = active
        currentJournalContext = updatedContext
        resetActiveRemoteResponse()

        if active {
            audioManager.stopRemoteAudio()
        }

        guard shouldNotifyServer, isWebSocketConnected else { return }

        if active, let currentJournalContext {
            webSocketClient.sendSessionConfig(metadata: currentJournalContext.metadata)
        } else {
            webSocketClient.sendSessionConfig(metadata: ["journal_mode": false])
        }
    }

    func beginJournalSession(context: JournalPromptContext) {
        setJournalModeActive(true, context: context)

        if isWebSocketConnected {
            errorMessage = nil
            currentAnimation = "thinking"
            webSocketClient.sendText(
                "ジャーナリングを開始します。最初の質問を1つだけしてください。",
                metadata: context.controlMetadata,
                systemPromptParams: context.systemPromptParams
            )
        } else {
            askJournalQuestion("今日はどんなことがあった？")
        }
    }

    func updateJournalContext(_ context: JournalPromptContext) {
        setJournalModeActive(true, context: context)

        guard isWebSocketConnected else {
            askJournalQuestion("選んだ写真や今日の移動についても、印象に残っていることを教えて。")
            return
        }

        currentAnimation = "thinking"
        webSocketClient.sendText(
            "ジャーナル素材が更新されました。写真や移動履歴に必要なら触れながら、次の質問を1つだけしてください。",
            metadata: context.controlMetadata,
            systemPromptParams: context.systemPromptParams
        )
    }

    func sendJournalMessage(
        _ text: String,
        context: JournalPromptContext,
        visualContext: CameraObservationFrame? = nil
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        setJournalModeActive(true, context: context)
        errorMessage = nil
        currentFace = "focused"
        currentAnimation = isWebSocketConnected ? "thinking" : "listening"
        appendMessage(speaker: .user, text: trimmed)

        if isWebSocketConnected {
            webSocketClient.sendText(
                trimmed,
                visualContext: visualContext,
                metadata: context.metadata,
                systemPromptParams: context.systemPromptParams
            )
        } else {
            askJournalQuestion("もう少し詳しく聞かせて。特に印象に残っている場面はどこ？")
        }
    }

    func askJournalQuestion(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        resetActiveRemoteResponse()
        errorMessage = nil
        currentFace = "smile"
        currentAnimation = "talk"
        appendMessage(speaker: .assistant, text: trimmed)
        speak(trimmed)
    }

    func speak(_ text: String, mouthCues: [AudioEngineManager.MouthCue] = []) {
        isSpeaking = true
        audioManager.stopRemoteAudio()
        audioManager.speak(text, mouthCues: mouthCues)
    }

    func stopSpeaking() {
        isSpeaking = false
        audioManager.stopSpeaking()
    }

    func clearConversation() {
        messages.removeAll()
        receivedEvents.removeAll()
        resetActiveRemoteResponse()
        errorMessage = nil
        currentFace = "neutral"
        currentAnimation = "idle"
    }

    func showConnectionConfigurationError(_ message: String) {
        chatConnectionState = .error
        errorMessage = message
        appendSystemMessage(message)
    }

    private var isWebSocketConnected: Bool {
        if case .connected = connectionState {
            return true
        }
        return false
    }

    private static func isLocalPlaintextWebSocket(_ url: URL) -> Bool {
        #if DEBUG
        guard url.scheme == "ws", let host = url.host?.lowercased() else {
            return false
        }
        if host == "localhost" || host == "127.0.0.1" || host == "::1" {
            return true
        }

        if host.hasPrefix("10.") || host.hasPrefix("192.168.") {
            return true
        }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4, parts[0] == 172, (16...31).contains(parts[1]) {
            return true
        }

        return false
        #else
        return false
        #endif
    }

    private func bindAudio() {
        audioManager.onStateChange = { [weak self] state in
            self?.microphoneState = state
        }

        audioManager.onMicrophoneLevel = { [weak self] level in
            self?.microphoneLevel = level
        }

        audioManager.onSpeechLevel = { [weak self] level in
            self?.speechLevel = level
            if level > 0 {
                self?.isSpeaking = true
            }
        }

        audioManager.onSpeechFinished = { [weak self] in
            self?.isSpeaking = false
            self?.speechLevel = 0
        }

        audioManager.onPCMData = { [weak self] data, format in
            self?.handleMicrophoneAudio(data, format: format)
        }
    }

    private func handleMicrophoneAudio(_ data: Data, format: AudioEngineManager.PCMFormat) {
        guard Date() >= microphoneSuppressedUntil else {
            resetUserUtteranceCapture()
            return
        }

        guard isWebSocketConnected, !isMuted else {
            resetUserUtteranceCapture()
            return
        }

        if isSpeaking && !bargeInEnabled {
            resetUserUtteranceCapture()
            return
        }

        let duration = audioDuration(for: data, format: format)
        guard duration > 0 else { return }

        let chunk = CapturedAudioChunk(data: data, format: format, duration: duration)
        let level = microphoneLevel

        if level >= speechStartLevelThreshold {
            if !isCapturingUserUtterance {
                isCapturingUserUtterance = true
                isCapturingUserSpeech = true
                lastCameraContextSentAt = .distantPast
                utteranceAudioBuffer = preSpeechAudioBuffer
                preSpeechAudioBuffer.removeAll()
                capturedVoiceDuration = 0
                trailingSilenceDuration = 0
            }

            utteranceAudioBuffer.append(chunk)
            capturedVoiceDuration += duration
            trailingSilenceDuration = 0
            currentAnimation = "listening"
        } else if isCapturingUserUtterance {
            utteranceAudioBuffer.append(chunk)
            if level <= speechEndLevelThreshold {
                trailingSilenceDuration += duration
            } else {
                trailingSilenceDuration = 0
            }
        } else {
            preSpeechAudioBuffer.append(chunk)
            trimBuffer(&preSpeechAudioBuffer, keepingLast: preSpeechBufferDuration)
        }

        if isCapturingUserUtterance && trailingSilenceDuration >= utteranceEndSilenceDuration {
            flushCapturedUserUtterance()
        }
    }

    private func flushCapturedUserUtterance() {
        let chunks = utteranceAudioBuffer
        let voiceDuration = capturedVoiceDuration
        resetUserUtteranceCapture()

        guard isWebSocketConnected, voiceDuration >= minimumUtteranceVoiceDuration else { return }

        currentAnimation = "thinking"
        for chunk in chunks {
            webSocketClient.sendAudioPCM(chunk.data, format: chunk.format)
        }
    }

    private func resetUserUtteranceCapture() {
        preSpeechAudioBuffer.removeAll()
        utteranceAudioBuffer.removeAll()
        isCapturingUserUtterance = false
        isCapturingUserSpeech = false
        capturedVoiceDuration = 0
        trailingSilenceDuration = 0
    }

    private func audioDuration(for data: Data, format: AudioEngineManager.PCMFormat) -> TimeInterval {
        let bytesPerSample = max(format.bitDepth / 8, 1)
        let frameSize = max(bytesPerSample * format.channels, 1)
        let frameCount = data.count / frameSize
        guard format.sampleRate > 0, frameCount > 0 else { return 0 }
        return TimeInterval(frameCount) / TimeInterval(format.sampleRate)
    }

    private func trimBuffer(_ buffer: inout [CapturedAudioChunk], keepingLast duration: TimeInterval) {
        var totalDuration = buffer.reduce(0) { $0 + $1.duration }
        while totalDuration > duration, !buffer.isEmpty {
            totalDuration -= buffer.removeFirst().duration
        }
    }

    private func bindWebSocket() {
        webSocketClient.onStateChange = { [weak self] state in
            guard let self else { return }
            self.connectionState = state

            switch state {
            case .connected:
                self.chatConnectionState = .connected
                self.errorMessage = nil
                self.appendSystemMessage("WebSocketに接続しました。")
                self.startRecording()
            case .failed(let message):
                self.chatConnectionState = .error
                self.errorMessage = message
                self.stopRecording()
                self.appendSystemMessage("WebSocket接続に失敗しました。サーバーの起動状態を確認してください。")
            case .disconnected:
                self.chatConnectionState = .disconnected
                self.stopRecording()
            case .connecting:
                self.chatConnectionState = .connecting
                break
            }
        }

        webSocketClient.onEvent = { [weak self] event in
            self?.handleRemoteEvent(event)
        }

        webSocketClient.onError = { [weak self] message in
            self?.errorMessage = message
        }
    }

    private func handleRemoteEvent(_ event: AIAvatarWebSocketClient.Event) {
        receivedEvents.append(event)

        if let requestText = event.requestText, shouldAppendRemoteRequestText(requestText, event: event) {
            appendMessage(speaker: .user, text: requestText)
        }

        if event.type == "start" {
            resetActiveRemoteResponse()
        }
        if event.type == "accepted" {
            currentAnimation = "thinking"
        }
        if event.type == "voiced" {
            currentAnimation = "listening"
        }
        if event.type == "stop" {
            stopSpeaking()
            resetActiveRemoteResponse()
            currentFace = "neutral"
            currentAnimation = "idle"
        }

        if isJournalModeActive, event.type == "final" {
            publishJournalSlotStatuses(from: event.text ?? event.voiceText)
        }

        let displayText = displayText(for: event)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let displayText, !displayText.isEmpty {
            handleRemoteDisplayText(displayText, eventType: event.type)
        }

        if let audio = event.audio {
            isSpeaking = true
            audioManager.stopSynthesizedSpeech()
            _ = audioManager.playAudioData(audio, format: event.audioFormat)
        }

        if event.type == "final" {
            resetActiveRemoteResponse()
        }

        if let face = event.face, !face.isEmpty {
            currentFace = face
        }

        if let animation = event.animation, !animation.isEmpty {
            currentAnimation = animation
        }

        if let error = event.error, !error.isEmpty {
            errorMessage = error
            appendSystemMessage(error)
        }
    }

    private func shouldAppendRemoteRequestText(_ text: String, event: AIAvatarWebSocketClient.Event) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if trimmed.hasPrefix("ジャーナリングを開始します。")
            || trimmed.hasPrefix("ジャーナル素材が更新されました。") {
            return false
        }

        if messages.last?.speaker == .user && messages.last?.text == trimmed {
            return false
        }

        return event.payload["journal_control"] != "true"
    }

    private var avatarMood: AvatarMood {
        switch currentFace.lowercased() {
        case "joy", "happy", "smile", "fun":
            return .happy
        case "surprised", "surprise":
            return .surprised
        case "sad", "concerned", "angry", "error":
            return .concerned
        case "sleepy":
            return .sleepy
        case "focused", "thinking":
            return .focused
        default:
            return .neutral
        }
    }

    private func handleRemoteDisplayText(_ text: String, eventType: String) {
        switch eventType {
        case "chunk":
            upsertActiveAssistantMessage(text, replacing: false)
        case "final":
            upsertActiveAssistantMessage(text, replacing: true)
        case "message", "text":
            resetActiveRemoteResponse()
            appendMessage(speaker: .assistant, text: text)
        default:
            break
        }
    }

    private func displayText(for event: AIAvatarWebSocketClient.Event) -> String? {
        guard isJournalModeActive else {
            return event.displayText
        }

        if let voiceText = event.voiceText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !voiceText.isEmpty {
            return voiceText
        }

        if JournalAssistantPayload.containsJournalTag(event.text) {
            if event.type == "final",
               let answerText = JournalAssistantPayload.answerText(from: event.text),
               !answerText.isEmpty {
                return answerText
            }
            return nil
        }

        if let payload = JournalAssistantPayload.parse(from: event.text) {
            if let text = payload.text?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                return text
            }
            if !payload.statuses.isEmpty {
                return nil
            }
        }

        return event.displayText
    }

    private func publishJournalSlotStatuses(from rawText: String?) {
        guard let payload = JournalAssistantPayload.parse(from: rawText),
              !payload.statuses.isEmpty else { return }

        journalSlotStatusUpdate = JournalSlotStatusUpdate(statuses: payload.statuses)
    }

    private func upsertActiveAssistantMessage(_ text: String, replacing: Bool) {
        guard !text.isEmpty else { return }

        if let activeRemoteAssistantMessageID,
           let index = messages.firstIndex(where: { $0.id == activeRemoteAssistantMessageID }) {
            messages[index].text = replacing ? text : messages[index].text + text
            return
        }

        activeRemoteAssistantMessageID = appendMessage(speaker: .assistant, text: text)
    }

    private func resetActiveRemoteResponse() {
        activeRemoteAssistantMessageID = nil
    }

    @discardableResult
    private func appendMessage(speaker: ConversationMessage.Speaker, text: String) -> UUID {
        let message = ConversationMessage(speaker: speaker, text: text)
        messages.append(message)
        return message.id
    }

    private func appendSystemMessage(_ text: String) {
        appendMessage(speaker: .system, text: text)
    }
}

private struct JournalAssistantPayload {
    var text: String?
    var statuses: [String: JournalSlotStatus]

    static func parse(from rawText: String?) -> JournalAssistantPayload? {
        guard let rawText else { return nil }

        for candidate in jsonCandidates(from: rawText) {
            guard
                let data = candidate.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data, options: []),
                let dictionary = json as? [String: Any]
            else {
                continue
            }

            let text = dictionary["text"] as? String
            var statuses: [String: JournalSlotStatus] = [:]
            for (key, value) in dictionary where key != "text" {
                guard
                    let label = JournalSlot.canonicalLabel(for: key),
                    let status = JournalSlotStatus(llmValue: value)
                else {
                    continue
                }
                statuses[label] = status
            }

            if text != nil || !statuses.isEmpty {
                return JournalAssistantPayload(text: text, statuses: statuses)
            }
        }

        return nil
    }

    static func containsJournalTag(_ rawText: String?) -> Bool {
        guard let rawText else { return false }
        return rawText.contains("<journal>") || rawText.contains("</journal>")
    }

    static func answerText(from rawText: String?) -> String? {
        guard let rawText else { return nil }
        return content(in: rawText, startTag: "<answer>", endTag: "</answer>")
    }

    private static func jsonCandidates(from rawText: String) -> [String] {
        var candidates: [String] = []
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)

        if let journalContent = content(in: trimmed, startTag: "<journal>", endTag: "</journal>") {
            candidates.append(journalContent)
        }

        if trimmed.hasPrefix("{"), trimmed.hasSuffix("}") {
            candidates.append(trimmed)
        } else if let start = trimmed.firstIndex(of: "{"),
                  let end = trimmed.lastIndex(of: "}"),
                  start <= end {
            candidates.append(String(trimmed[start...end]))
        }

        return candidates
    }

    private static func content(in text: String, startTag: String, endTag: String) -> String? {
        guard
            let start = text.range(of: startTag),
            let end = text.range(of: endTag, range: start.upperBound..<text.endIndex)
        else {
            return nil
        }

        return String(text[start.upperBound..<end.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
