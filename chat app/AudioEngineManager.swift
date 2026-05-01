//
//  AudioEngineManager.swift
//  chat app
//

import AVFoundation
import Foundation

final class AudioEngineManager: NSObject {
    enum MicrophoneState: Equatable {
        case idle
        case unavailable(String)
        case permissionDenied
        case recording
        case muted
        case failed(String)
    }

    struct PCMFormat: Equatable {
        var sampleRate: Int
        var channels: Int
        var bitDepth: Int

        static let aiAvatarDefault = PCMFormat(sampleRate: 16_000, channels: 1, bitDepth: 16)
    }

    struct MouthCue: Equatable {
        var time: TimeInterval
        var level: Float
    }

    private struct SpeechRequest {
        var text: String
        var language: String
        var mouthCues: [MouthCue]
    }

    private enum RemoteAudioPacket {
        case encoded(Data)
        case pcm(Data, PCMFormat)
    }

    var onPCMData: ((Data, PCMFormat) -> Void)?
    var onMicrophoneLevel: ((Float) -> Void)?
    var onSpeechLevel: ((Float) -> Void)?
    var onStateChange: ((MicrophoneState) -> Void)?
    var onSpeechFinished: (() -> Void)?

    private let audioEngine = AVAudioEngine()
    private let synthesizer = AVSpeechSynthesizer()
    private let processingQueue = DispatchQueue(label: "chat-app.audio.processing")
    private let outputFormat = PCMFormat.aiAvatarDefault

    private var speechTimer: Timer?
    private var audioPlayer: AVAudioPlayer?
    private var audioPlayerTimer: Timer?
    private var remoteAudioQueue: [RemoteAudioPacket] = []
    private var pendingSpeechRequest: SpeechRequest?
    private var isReplacingSpeech = false
    private var speechPhase: Float = 0
    private var speechStartedAt: Date?
    private var speechMouthCues: [MouthCue] = []
    private(set) var state: MicrophoneState = .idle {
        didSet {
            DispatchQueue.main.async { [state, onStateChange] in
                onStateChange?(state)
            }
        }
    }

    private(set) var isMuted = false {
        didSet {
            if state == .recording || state == .muted {
                state = isMuted ? .muted : .recording
            }
        }
    }

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    deinit {
        stopMicrophone()
        stopSpeaking()
    }

    func startMicrophone() {
        guard microphoneUsageDescriptionExists else {
            state = .unavailable("Missing NSMicrophoneUsageDescription")
            onMicrophoneLevel?(0)
            return
        }

        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            startEngineAfterPermission()
        case .denied:
            state = .permissionDenied
            onMicrophoneLevel?(0)
        case .undetermined:
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async {
                    granted ? self?.startEngineAfterPermission() : self?.markPermissionDenied()
                }
            }
        @unknown default:
            state = .unavailable("Unknown microphone permission state")
            onMicrophoneLevel?(0)
        }
    }

    func stopMicrophone() {
        if audioEngine.isRunning {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
        onMicrophoneLevel?(0)
        state = .idle
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        if muted {
            onMicrophoneLevel?(0)
        }
    }

    func speak(_ text: String, language: String = "ja-JP", mouthCues: [MouthCue] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        stopRemoteAudio()
        let request = SpeechRequest(text: trimmed, language: language, mouthCues: mouthCues)

        if synthesizer.isSpeaking || synthesizer.isPaused {
            pendingSpeechRequest = request
            isReplacingSpeech = true
            stopSpeechMeter()
            synthesizer.stopSpeaking(at: .immediate)
            return
        }

        pendingSpeechRequest = nil
        startSynthesizedSpeech(request)
    }

    func stopSpeaking() {
        stopSynthesizedSpeech()
        stopRemoteAudio()
    }

    func stopSynthesizedSpeech() {
        pendingSpeechRequest = nil
        isReplacingSpeech = false
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        stopSpeechMeter()
    }

    private func startSynthesizedSpeech(_ request: SpeechRequest) {
        configurePlaybackSession()

        let utterance = AVSpeechUtterance(string: request.text)
        utterance.voice = AVSpeechSynthesisVoice(language: request.language)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        synthesizer.speak(utterance)
        startSpeechMeter(mouthCues: request.mouthCues)
    }

    @discardableResult
    func playAudioData(_ data: Data, format: PCMFormat? = nil) -> Bool {
        guard !data.isEmpty else { return false }

        let packet: RemoteAudioPacket = if let format {
            .pcm(data, format)
        } else {
            .encoded(data)
        }

        if audioPlayer?.isPlaying == true {
            remoteAudioQueue.append(packet)
            return true
        }

        return startRemoteAudioPacket(packet)
    }

    func stopRemoteAudio() {
        remoteAudioQueue.removeAll()
        audioPlayer?.stop()
        audioPlayer = nil
        stopRemoteAudioMeter()
    }

    @discardableResult
    private func startRemoteAudioPacket(_ packet: RemoteAudioPacket) -> Bool {
        let playableData: Data
        switch packet {
        case .encoded(let data):
            playableData = data
        case .pcm(let data, let format):
            playableData = makeWAVData(fromPCM: data, format: format)
        }

        do {
            configurePlaybackSession()
            let player = try AVAudioPlayer(data: playableData)
            player.delegate = self
            player.isMeteringEnabled = true
            player.prepareToPlay()
            audioPlayer = player
            player.play()
            startRemoteAudioMeter()
            return true
        } catch {
            playNextRemoteAudioOrFinish()
            return false
        }
    }

    private func playNextRemoteAudioOrFinish() {
        audioPlayer = nil
        if remoteAudioQueue.isEmpty {
            stopRemoteAudioMeter()
            onSpeechFinished?()
            return
        }

        let nextAudio = remoteAudioQueue.removeFirst()
        startRemoteAudioPacket(nextAudio)
    }

    private func makeWAVData(fromPCM pcmData: Data, format: PCMFormat) -> Data {
        let channels = UInt16(max(format.channels, 1))
        let sampleRate = UInt32(max(format.sampleRate, 1))
        let bitsPerSample = UInt16(max(format.bitDepth, 8))
        let bytesPerSample = UInt32(max(Int(bitsPerSample) / 8, 1))
        let byteRate = sampleRate * UInt32(channels) * bytesPerSample
        let blockAlign = UInt16(UInt32(channels) * bytesPerSample)
        let dataSize = UInt32(pcmData.count)
        let riffSize = UInt32(36) + dataSize

        var wav = Data(capacity: 44 + pcmData.count)
        wav.appendASCII("RIFF")
        wav.appendLittleEndian(riffSize)
        wav.appendASCII("WAVE")
        wav.appendASCII("fmt ")
        wav.appendLittleEndian(UInt32(16))
        wav.appendLittleEndian(UInt16(1))
        wav.appendLittleEndian(channels)
        wav.appendLittleEndian(sampleRate)
        wav.appendLittleEndian(byteRate)
        wav.appendLittleEndian(blockAlign)
        wav.appendLittleEndian(bitsPerSample)
        wav.appendASCII("data")
        wav.appendLittleEndian(dataSize)
        wav.append(pcmData)
        return wav
    }

    private var microphoneUsageDescriptionExists: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil
    }

    private func markPermissionDenied() {
        state = .permissionDenied
        onMicrophoneLevel?(0)
    }

    private func startEngineAfterPermission() {
        guard !audioEngine.isRunning else {
            state = isMuted ? .muted : .recording
            return
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.overrideOutputAudioPort(.speaker)
            try session.setActive(true)

            let inputNode = audioEngine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
                state = .unavailable("Microphone input format is unavailable")
                return
            }

            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
                self?.processInputBuffer(buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()
            state = isMuted ? .muted : .recording
        } catch {
            state = .failed(error.localizedDescription)
            onMicrophoneLevel?(0)
        }
    }

    private func configurePlaybackSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.overrideOutputAudioPort(.speaker)
            try session.setActive(true)
        } catch {
            // TTS can still work in many simulator states, so keep this non-fatal.
        }
    }

    private func processInputBuffer(_ buffer: AVAudioPCMBuffer) {
        guard !isMuted else { return }
        guard let channelData = buffer.floatChannelData else { return }

        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameLength > 0, channelCount > 0 else { return }

        processingQueue.async { [weak self] in
            guard let self else { return }

            var monoSamples = [Float]()
            monoSamples.reserveCapacity(frameLength)

            for frame in 0..<frameLength {
                var sample: Float = 0
                for channel in 0..<channelCount {
                    sample += channelData[channel][frame]
                }
                monoSamples.append(sample / Float(channelCount))
            }

            let level = self.rmsLevel(from: monoSamples)
            let pcm = self.convertToPCM16(samples: monoSamples, sourceRate: buffer.format.sampleRate)

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onMicrophoneLevel?(level)
                if !pcm.isEmpty {
                    self.onPCMData?(pcm, self.outputFormat)
                }
            }
        }
    }

    private func convertToPCM16(samples: [Float], sourceRate: Double) -> Data {
        guard !samples.isEmpty, sourceRate > 0 else { return Data() }

        let targetRate = Double(outputFormat.sampleRate)
        let ratio = sourceRate / targetRate
        let outputCount = max(1, Int(Double(samples.count) / ratio))
        var data = Data(capacity: outputCount * MemoryLayout<Int16>.size)

        for index in 0..<outputCount {
            let sourceIndex = min(samples.count - 1, Int(Double(index) * ratio))
            let clamped = max(-1.0, min(1.0, samples[sourceIndex]))
            let value = Int16(clamped * Float(Int16.max))
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { bytes in
                data.append(contentsOf: bytes)
            }
        }

        return data
    }

    private func rmsLevel(from samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }

        let sum = samples.reduce(Float(0)) { partial, sample in
            partial + sample * sample
        }
        let rms = sqrt(sum / Float(samples.count))
        return min(1, max(0, rms * 8))
    }

    private func startSpeechMeter(mouthCues: [MouthCue] = []) {
        stopSpeechMeter()
        speechPhase = 0
        speechStartedAt = Date()
        speechMouthCues = mouthCues.sorted { $0.time < $1.time }
        speechTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            guard let self else { return }
            let level = self.scriptedSpeechLevel() ?? self.syntheticSpeechLevel()
            self.onSpeechLevel?(self.synthesizer.isSpeaking ? level : 0)
        }
    }

    private func stopSpeechMeter() {
        speechTimer?.invalidate()
        speechTimer = nil
        speechStartedAt = nil
        speechMouthCues = []
        onSpeechLevel?(0)
    }

    private func syntheticSpeechLevel() -> Float {
        speechPhase += 0.32
        return 0.35 + 0.45 * (sin(speechPhase) + 1) / 2
    }

    private func scriptedSpeechLevel() -> Float? {
        guard !speechMouthCues.isEmpty, let speechStartedAt else { return nil }

        let elapsed = Date().timeIntervalSince(speechStartedAt)
        if elapsed <= speechMouthCues[0].time {
            return speechMouthCues[0].level
        }

        for index in 1..<speechMouthCues.count {
            let previous = speechMouthCues[index - 1]
            let next = speechMouthCues[index]
            guard elapsed <= next.time else { continue }

            let span = max(0.001, next.time - previous.time)
            let progress = Float((elapsed - previous.time) / span)
            return previous.level + (next.level - previous.level) * progress
        }

        return speechMouthCues.last?.level
    }

    private func startRemoteAudioMeter() {
        stopRemoteAudioMeter()
        audioPlayerTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let audioPlayer = self.audioPlayer, audioPlayer.isPlaying else {
                self?.stopRemoteAudioMeter()
                self?.onSpeechFinished?()
                return
            }
            audioPlayer.updateMeters()
            let db = audioPlayer.averagePower(forChannel: 0)
            let normalized = pow(10, db / 20)
            self.onSpeechLevel?(min(1, max(0, normalized * 2.5)))
        }
    }

    private func stopRemoteAudioMeter() {
        audioPlayerTimer?.invalidate()
        audioPlayerTimer = nil
        onSpeechLevel?(0)
    }
}

private extension Data {
    mutating func appendASCII(_ value: String) {
        append(contentsOf: value.utf8)
    }

    mutating func appendLittleEndian(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}

extension AudioEngineManager: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finishSynthesizedSpeech()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finishSynthesizedSpeech()
    }

    private func finishSynthesizedSpeech() {
        stopSpeechMeter()

        if let pendingSpeechRequest {
            let request = pendingSpeechRequest
            self.pendingSpeechRequest = nil
            isReplacingSpeech = false
            DispatchQueue.main.async { [weak self] in
                self?.startSynthesizedSpeech(request)
            }
            return
        }

        if isReplacingSpeech {
            isReplacingSpeech = false
        } else {
            onSpeechFinished?()
        }
    }
}

extension AudioEngineManager: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        playNextRemoteAudioOrFinish()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        playNextRemoteAudioOrFinish()
    }
}
