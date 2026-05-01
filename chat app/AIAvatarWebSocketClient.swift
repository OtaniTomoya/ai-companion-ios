//
//  AIAvatarWebSocketClient.swift
//  chat app
//

import Foundation

final class AIAvatarWebSocketClient: NSObject {
    enum ConnectionState: Equatable {
        case disconnected
        case connecting(URL)
        case connected(URL)
        case failed(String)
    }

    struct Event: Identifiable, Equatable {
        var id = UUID()
        var type: String
        var text: String?
        var voiceText: String?
        var requestText: String?
        var audio: Data?
        var audioFormat: AudioEngineManager.PCMFormat? = nil
        var face: String?
        var animation: String?
        var error: String?
        var payload: [String: String]
        var rawText: String?

        var displayText: String? {
            voiceText ?? text
        }

        var isError: Bool {
            type == "error" || error != nil
        }
    }

    var onStateChange: ((ConnectionState) -> Void)?
    var onEvent: ((Event) -> Void)?
    var onError: ((String) -> Void)?

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var connectedURL: URL?
    private let callbackQueue = DispatchQueue.main
    private var isIntentionalDisconnect = false

    private var sessionID = "ios_session"
    private var userID = "ios_user"
    private var contextID: String?
    private var apiKey: String?
    private var bargeInEnabled = false

    private(set) var state: ConnectionState = .disconnected {
        didSet {
            callbackQueue.async { [state, onStateChange] in
                onStateChange?(state)
            }
        }
    }

    deinit {
        disconnect()
    }

    func connect(
        to url: URL,
        sessionID: String = "ios_session",
        userID: String = "ios_user",
        apiKey: String? = nil,
        bargeInEnabled: Bool = false
    ) {
        disconnect()
        isIntentionalDisconnect = false

        self.sessionID = sessionID
        self.userID = userID
        self.contextID = nil
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.bargeInEnabled = bargeInEnabled

        connectedURL = url
        state = .connecting(url)

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)

        var request = URLRequest(url: url)
        if let apiKey = self.apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let task = session.webSocketTask(with: request)
        self.session = session
        self.task = task

        task.resume()
        receiveNext(for: task)
    }

    func disconnect() {
        isIntentionalDisconnect = true
        if task != nil {
            sendStopSession()
        }
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        connectedURL = nil
        contextID = nil
        state = .disconnected
    }

    func sendText(
        _ text: String,
        visualContext: CameraObservationFrame? = nil,
        metadata: [String: Any]? = nil,
        systemPromptParams: [String: Any]? = nil
    ) {
        sendJSONEvent(aiAvatarDataPayload(
            text: text,
            visualContext: visualContext,
            metadata: metadata,
            systemPromptParams: systemPromptParams
        ))
    }

    func sendCameraContext(_ frame: CameraObservationFrame) {
        sendJSONEvent([
            "type": "camera_context",
            "session_id": sessionID,
            "user_id": userID,
            "context_id": contextID as Any? ?? NSNull(),
            "files": cameraContextFiles(for: frame),
            "metadata": cameraContextMetadata(for: frame)
        ])
    }

    func sendSessionConfig(metadata: [String: Any]) {
        sendJSONEvent([
            "type": "config",
            "session_id": sessionID,
            "user_id": userID,
            "context_id": contextID as Any? ?? NSNull(),
            "metadata": metadata
        ])
    }

    func sendAudioPCM(_ data: Data, format: AudioEngineManager.PCMFormat) {
        guard !data.isEmpty else { return }

        sendJSONEvent([
            "type": "data",
            "session_id": sessionID,
            "audio_data": data.base64EncodedString()
        ])
    }

    func sendJSONEvent(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object) else {
            reportError("Invalid JSON event")
            return
        }

        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [])
            guard let text = String(data: data, encoding: .utf8) else {
                reportError("Failed to encode JSON event")
                return
            }
            send(.string(text))
        } catch {
            reportError(error.localizedDescription)
        }
    }

    private func sendStartSession() {
        sendJSONEvent([
            "type": "start",
            "session_id": sessionID,
            "user_id": userID,
            "context_id": contextID as Any? ?? NSNull(),
            "metadata": [
                "barge_in_enabled": bargeInEnabled
            ]
        ])
    }

    private func sendStopSession() {
        sendJSONEvent([
            "type": "stop",
            "session_id": sessionID
        ])
    }

    private func aiAvatarDataPayload(
        text: String,
        visualContext: CameraObservationFrame? = nil,
        metadata: [String: Any]? = nil,
        systemPromptParams: [String: Any]? = nil
    ) -> [String: Any] {
        var payload: [String: Any] = [
            "type": "invoke",
            "session_id": sessionID,
            "user_id": userID,
            "context_id": contextID as Any? ?? NSNull(),
            "text": text
        ]

        if let metadata {
            payload["metadata"] = metadata
        }

        if let systemPromptParams {
            payload["system_prompt_params"] = systemPromptParams
        }

        if let visualContext {
            payload["files"] = cameraContextFiles(for: visualContext)
            payload["metadata"] = mergedMetadata(metadata, cameraContextMetadata(for: visualContext))
        }

        return payload
    }

    private func mergedMetadata(_ lhs: [String: Any]?, _ rhs: [String: Any]) -> [String: Any] {
        var metadata = lhs ?? [:]
        rhs.forEach { key, value in
            metadata[key] = value
        }
        return metadata
    }

    private func cameraContextFiles(for frame: CameraObservationFrame) -> [[String: String]] {
        [
            [
                "url": frame.dataURL,
                "mime_type": "image/jpeg",
                "name": "camera-frame.jpg"
            ]
        ]
    }

    private func cameraContextMetadata(for frame: CameraObservationFrame) -> [String: Any] {
        [
            "camera_context": true,
            "camera_captured_at": ISO8601DateFormatter().string(from: frame.capturedAt),
            "camera_width": frame.width,
            "camera_height": frame.height
        ]
    }

    private func send(_ message: URLSessionWebSocketTask.Message) {
        guard let task else {
            if !isIntentionalDisconnect {
                reportError("WebSocket is not connected")
            }
            return
        }

        task.send(message) { [weak self] error in
            guard let self, self.task === task else { return }
            if let error {
                self.reportError(error.localizedDescription)
            }
        }
    }

    private func receiveNext(for task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self, self.task === task else { return }

            switch result {
            case .success(let message):
                self.handle(message)
                self.receiveNext(for: task)
            case .failure(let error):
                guard !self.isIntentionalDisconnect else { return }
                self.task = nil
                self.session?.invalidateAndCancel()
                self.session = nil
                self.connectedURL = nil
                self.contextID = nil
                self.state = .failed(error.localizedDescription)
                self.reportError(error.localizedDescription)
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            handleTextMessage(text)
        case .data(let data):
            publish(Event(type: "audio", audio: data, payload: [:]))
        @unknown default:
            reportError("Unsupported WebSocket message")
        }
    }

    private func handleTextMessage(_ text: String) {
        guard let data = text.data(using: .utf8) else {
            publish(Event(type: "text", text: text, payload: [:], rawText: text))
            return
        }

        guard
            let json = try? JSONSerialization.jsonObject(with: data, options: []),
            let dictionary = json as? [String: Any]
        else {
            publish(Event(type: "text", text: text, payload: [:], rawText: text))
            return
        }

        updateSession(from: dictionary)
        publish(event(from: dictionary, rawText: text))
    }

    private func updateSession(from dictionary: [String: Any]) {
        if let sessionID = stringValue(for: "session_id", in: dictionary) {
            self.sessionID = sessionID
        }
        if let userID = stringValue(for: "user_id", in: dictionary) {
            self.userID = userID
        }
        if let contextID = stringValue(for: "context_id", in: dictionary), !contextID.isEmpty {
            self.contextID = contextID
        }
    }

    private func event(from dictionary: [String: Any], rawText: String) -> Event {
        let metadata = dictionaryValue(for: "metadata", in: dictionary)
        let avatarControl = dictionaryValue(for: "avatar_control_request", in: dictionary)
        let type = stringValue(for: "type", in: dictionary) ?? "message"

        let audioString = stringValue(for: "audio_data", in: dictionary)
            ?? stringValue(for: "audio", in: dictionary)
            ?? stringValue(for: "audioBase64", in: dictionary)
            ?? stringValue(for: "data", in: dictionary)

        let text = stringValue(for: "text", in: dictionary)
            ?? stringValue(for: "message", in: dictionary)
            ?? stringValue(for: "content", in: dictionary)
        let voiceText = stringValue(for: "voice_text", in: dictionary)
        let requestText = stringValue(for: "request_text", in: metadata)
        let error = stringValue(for: "error", in: dictionary)
            ?? stringValue(for: "reason", in: dictionary)
            ?? stringValue(for: "error", in: metadata)

        var payload = stringPayload(from: dictionary)
        payload.merge(stringPayload(from: metadata)) { current, _ in current }
        payload.merge(stringPayload(from: avatarControl)) { current, _ in current }

        return Event(
            type: type,
            text: text,
            voiceText: voiceText,
            requestText: requestText,
            audio: decodedAudio(from: audioString),
            audioFormat: pcmFormat(from: metadata),
            face: stringValue(for: "face_name", in: avatarControl)
                ?? stringValue(for: "face", in: dictionary)
                ?? stringValue(for: "expression", in: dictionary),
            animation: stringValue(for: "animation_name", in: avatarControl)
                ?? stringValue(for: "animation", in: dictionary)
                ?? stringValue(for: "motion", in: dictionary),
            error: error,
            payload: payload,
            rawText: rawText
        )
    }

    private func dictionaryValue(for key: String, in dictionary: [String: Any]) -> [String: Any] {
        dictionary[key] as? [String: Any] ?? [:]
    }

    private func stringValue(for key: String, in dictionary: [String: Any]) -> String? {
        if dictionary[key] is NSNull {
            return nil
        }
        if let value = dictionary[key] as? String {
            return value
        }
        if let value = dictionary[key] as? CustomStringConvertible {
            return value.description
        }
        return nil
    }

    private func pcmFormat(from metadata: [String: Any]) -> AudioEngineManager.PCMFormat? {
        guard let pcm = metadata["pcm_format"] as? [String: Any] else {
            return nil
        }

        let sampleRate = intValue(for: "sample_rate", in: pcm)
        let channels = intValue(for: "channels", in: pcm)
        let sampleWidth = intValue(for: "sample_width", in: pcm)
        guard let sampleRate, let channels, let sampleWidth else {
            return nil
        }

        return AudioEngineManager.PCMFormat(
            sampleRate: sampleRate,
            channels: channels,
            bitDepth: sampleWidth * 8
        )
    }

    private func intValue(for key: String, in dictionary: [String: Any]) -> Int? {
        if dictionary[key] is NSNull {
            return nil
        }
        if let value = dictionary[key] as? Int {
            return value
        }
        if let value = dictionary[key] as? NSNumber {
            return value.intValue
        }
        if let value = dictionary[key] as? String {
            return Int(value)
        }
        return nil
    }

    private func stringPayload(from dictionary: [String: Any]) -> [String: String] {
        dictionary.reduce(into: [String: String]()) { result, entry in
            if let value = entry.value as? String {
                result[entry.key] = value
            } else if let value = entry.value as? CustomStringConvertible {
                result[entry.key] = value.description
            }
        }
    }

    private func decodedAudio(from value: String?) -> Data? {
        guard let value, !value.isEmpty, let data = Data(base64Encoded: value), !data.isEmpty else {
            return nil
        }
        return data
    }

    private func publish(_ event: Event) {
        callbackQueue.async { [weak self] in
            guard let self else { return }
            self.onEvent?(event)

            if let error = event.error {
                self.onError?(error)
            }
        }
    }

    private func reportError(_ message: String) {
        callbackQueue.async { [weak self] in
            self?.onError?(message)
        }
    }
}

extension AIAvatarWebSocketClient: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard task === webSocketTask, let connectedURL else { return }
        state = .connected(connectedURL)
        sendStartSession()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        guard task === webSocketTask else { return }
        task = nil
        self.session?.invalidateAndCancel()
        self.session = nil
        connectedURL = nil
        contextID = nil
        state = .disconnected
    }
}
