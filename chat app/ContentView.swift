//
//  ContentView.swift
//  chat app
//
//  Created by TomoyaOtani on 2026/04/29.
//

import CoreLocation
import SwiftUI
import UIKit

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var settings = AppSettings()
    @StateObject private var viewModel = ConversationViewModel()
    @StateObject private var locationAuthorization = LocationAuthorizationManager()
    @StateObject private var journalStore = JournalStore()
    @StateObject private var cameraObservation = CameraObservationManager()
    @StateObject private var calendarContext = CalendarContextManager()
    @State private var draftText = "こんにちは"
    @State private var isChromeVisible = false
    @State private var isJournalPresented = false
    @State private var isCameraObservationMode = false
    @State private var avatarLoadState: MotionPNGTuberLoadState = .loading
    @State private var hasRequestedInitialConnection = false

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(red: 0.96, green: 0.97, blue: 0.98)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: revealChrome)
                    .allowsHitTesting(!isChromeVisible)

                avatarSurface
                    .frame(
                        width: avatarSize(in: proxy.size).width,
                        height: avatarSize(in: proxy.size).height
                    )
                    .position(
                        x: proxy.size.width / 2,
                        y: avatarCenterY(in: proxy.size, safeArea: proxy.safeAreaInsets)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture(perform: revealChrome)
                    .allowsHitTesting(!isChromeVisible)

                if isChromeVisible {
                    controlOverlay(proxy: proxy)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }

                if isCameraObservationMode && isChromeVisible {
                    cameraObservationPanel(proxy: proxy)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                modeButtons(proxy: proxy)
            }
        }
        .statusBarHidden(!isChromeVisible)
        .persistentSystemOverlays(isChromeVisible ? .automatic : .hidden)
        .onAppear {
            cameraObservation.onFrameCaptured = { frame in
                viewModel.sendCameraContext(frame)
            }
            locationAuthorization.onLocationUpdate = { location in
                journalStore.recordLocation(location)
            }
            viewModel.setJournalModeActive(
                journalStore.isJournaling,
                context: journalStore.isJournaling ? journalStore.promptContext() : nil
            )
            refreshCalendarContextIfNeeded()
            connectOnLaunchIfNeeded()
        }
        .onChange(of: viewModel.messages) { _, messages in
            _ = journalStore.addConversationMessages(messages)
        }
        .onChange(of: viewModel.journalSlotStatusUpdate) { _, update in
            guard let update, journalStore.isJournaling else { return }
            let didChange = journalStore.updateSlotStatuses(update.statuses)
            if didChange {
                viewModel.updateJournalContext(journalStore.promptContext())
            }
        }
        .onChange(of: journalStore.isJournaling) { _, isJournaling in
            viewModel.setJournalModeActive(
                isJournaling,
                context: isJournaling ? journalStore.promptContext() : nil
            )
        }
        .onChange(of: settings.calendarContextEnabled) { _, isEnabled in
            if isEnabled {
                refreshCalendarContextIfNeeded()
            } else if journalStore.updateCalendarContextLines([]), journalStore.isJournaling {
                viewModel.updateJournalContext(journalStore.promptContext())
            }
        }
        .onChange(of: calendarContext.upcomingEvents) { _, _ in
            updateJournalCalendarContextFromCurrentEvents(notifyServer: journalStore.isJournaling)
        }
        .onChange(of: viewModel.isCapturingUserSpeech) { _, isCapturing in
            guard isCameraObservationMode else { return }
            if isCapturing {
                cameraObservation.beginSpeechFrameCapture()
            } else {
                cameraObservation.endSpeechFrameCapture()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                viewModel.suppressMicrophoneInput(for: 1.0)
                if isCameraObservationMode {
                    cameraObservation.startObserving()
                }
            case .background:
                viewModel.suppressMicrophoneInput(for: 1.5)
                cameraObservation.stopObserving()
            case .inactive:
                viewModel.suppressMicrophoneInput(for: 1.5)
                cameraObservation.stopObserving()
            @unknown default:
                break
            }
        }
        .sheet(isPresented: $isJournalPresented) {
            NavigationStack {
                JournalModeView(
                    journalStore: journalStore,
                    locationAuthorization: locationAuthorization,
                    calendarContextLines: currentCalendarContextLines(),
                    existingConversationMessages: viewModel.messages,
                    onStartSession: { context in
                        isChromeVisible = true
                        viewModel.beginJournalSession(context: context)
                    },
                    onPhotoContextUpdated: { context in
                        isChromeVisible = true
                        viewModel.updateJournalContext(context)
                    },
                    onFinish: { _ in
                        viewModel.setJournalModeActive(false)
                        viewModel.askJournalQuestion("今日の出来事をまとめたよ〜")
                    }
                )
            }
        }
    }

    private var avatarSurface: some View {
        ZStack {
            AvatarStartupPreviewView(state: viewModel.avatarFrameState)
                .opacity(avatarLoadState == .ready ? 0 : 1)

            MotionPNGTuberAvatarView(
                state: viewModel.avatarFrameState,
                sensitivity: settings.lipSyncSensitivity,
                loadState: $avatarLoadState
            )
            .opacity(avatarLoadState == .ready ? 1 : 0.01)

            avatarLoadingOverlay
                .opacity(avatarLoadState == .ready ? 0 : 1)
        }
    }

    @ViewBuilder
    private var avatarLoadingOverlay: some View {
        switch avatarLoadState {
        case .loading:
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.regular)
                Text("アバターを読み込み中")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .failed(let message):
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("アバターを表示できません")
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(18)
        case .ready:
            EmptyView()
        }
    }

    private func controlOverlay(proxy: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: 12) {
                overlayHeader

                ControlPanelView(
                    settings: settings,
                    locationAuthorization: locationAuthorization,
                    calendarContext: calendarContext,
                    connectionState: viewModel.chatConnectionState,
                    isMuted: Binding(
                        get: { viewModel.isMuted },
                        set: { viewModel.setMuted($0) }
                    ),
                    onConnect: connect,
                    onDisconnect: viewModel.disconnect
                )

                inputBar

                ConversationTranscriptView(
                    messages: viewModel.messages,
                    maxHeight: min(220, proxy.size.height * 0.25)
                )
            }
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, 14)
            .padding(.bottom, max(10, proxy.safeAreaInsets.bottom + 8))
        }
    }

    private var overlayHeader: some View {
        HStack(spacing: 10) {
            statusSummary
            Spacer(minLength: 8)
            audioMeter
            hideButton
        }
    }

    private var statusSummary: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(settings.websocketURL)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Text(statusText)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
        }
    }

    private var audioMeter: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Label("\(Int(max(viewModel.microphoneLevel, viewModel.speechLevel) * 100))%", systemImage: "waveform")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            Text(viewModel.currentFace)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    private var hideButton: some View {
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                isChromeVisible = false
            }
        } label: {
            Label("閉じる", systemImage: "chevron.down")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("操作パネルを閉じる")
    }

    private func modeButtons(proxy: GeometryProxy) -> some View {
        VStack {
            HStack {
                Spacer()

                Button {
                    toggleCameraObservationMode()
                } label: {
                    Label("vision", systemImage: isCameraObservationMode ? "camera.viewfinder" : "camera")
                        .font(.subheadline.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .tint(isCameraObservationMode ? .teal : .gray)
                .accessibilityLabel(isCameraObservationMode ? "visionモードを終了" : "visionモードを開始")

                Button {
                    Task {
                        await refreshCalendarContextForJournal()
                        isJournalPresented = true
                    }
                } label: {
                    Label("journal", systemImage: journalStore.isJournaling ? "book.fill" : "book")
                        .font(.subheadline.weight(.semibold))
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .tint(journalStore.isJournaling ? .green : .blue)
                .accessibilityLabel(journalStore.isJournaling ? "ジャーナリング中" : "ジャーナリングを開く")
            }
            .padding(.top, max(10, proxy.safeAreaInsets.top + 8))
            .padding(.horizontal, 14)

            Spacer()
        }
    }

    private func cameraObservationPanel(proxy: GeometryProxy) -> some View {
        VStack {
            HStack {
                VStack(alignment: .leading, spacing: 7) {
                    ZStack {
                        if cameraObservation.isObserving {
                            CameraPreviewView(session: cameraObservation.session)
                        } else {
                            Color.black.opacity(0.72)
                            VStack(spacing: 6) {
                                Image(systemName: "camera.viewfinder")
                                    .font(.title3.weight(.semibold))
                                Text(cameraObservation.errorMessage ?? cameraObservation.authorizationState.label)
                                    .font(.caption2.weight(.semibold))
                                    .multilineTextAlignment(.center)
                                    .lineLimit(3)
                            }
                            .foregroundStyle(.white)
                            .padding(8)
                        }
                    }
                    .frame(height: 108)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    HStack(spacing: 6) {
                        Label("vision", systemImage: "eye")
                            .font(.caption.weight(.semibold))
                        Spacer(minLength: 4)
                        Text(cameraObservation.isObserving ? "更新中" : "待機")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: min(180, proxy.size.width * 0.44))
                .padding(10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                Spacer()
            }
            .padding(.top, max(54, proxy.safeAreaInsets.top + 52))
            .padding(.horizontal, 14)

            Spacer()
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField(journalStore.isJournaling ? "質問に答える" : "テキストで話しかける", text: $draftText)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.send)
                .onSubmit(sendDraft)

            Button(action: sendDraft) {
                Label("送信", systemImage: "paperplane.fill")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderedProminent)
            .disabled(draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("送信")
        }
    }

    private func avatarSize(in size: CGSize) -> CGSize {
        if isChromeVisible {
            return CGSize(
                width: min(size.width * 0.78, 360),
                height: min(size.height * 0.38, 360)
            )
        }

        return CGSize(
            width: min(size.width * 0.96, 440),
            height: size.height * 0.86
        )
    }

    private func avatarCenterY(in size: CGSize, safeArea: EdgeInsets) -> CGFloat {
        if isChromeVisible {
            return max(safeArea.top + size.height * 0.2, size.height * 0.24)
        }
        return size.height * 0.52
    }

    private func revealChrome() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
            isChromeVisible = true
        }
    }

    private var statusText: String {
        if let errorMessage = viewModel.errorMessage, !errorMessage.isEmpty {
            return errorMessage
        }
        if journalStore.isJournaling {
            return "ジャーナリング中"
        }
        if isCameraObservationMode {
            if let message = cameraObservation.errorMessage, !message.isEmpty {
                return message
            }
            return cameraObservation.isObserving ? "visionモードで周囲を見ています" : "visionモードを準備中"
        }
        if viewModel.isSpeaking {
            return "AIアバターが話しています"
        }
        if viewModel.microphoneState == .recording && !viewModel.isMuted {
            return "聞き取り中"
        }
        return viewModel.chatConnectionState.label
    }

    private func connect() {
        guard settings.hasConfiguredWebSocketURL else {
            viewModel.showConnectionConfigurationError("WebSocket URLを設定してください。公開用の外部接続は wss://.../ws を使います。")
            return
        }

        viewModel.connect(
            to: settings.websocketURL,
            apiKey: settings.hasAPIKey ? settings.apiKey : nil,
            bargeInEnabled: settings.bargeInEnabled
        )
    }

    private func connectOnLaunchIfNeeded() {
        guard !hasRequestedInitialConnection else { return }
        hasRequestedInitialConnection = true

        guard settings.hasConfiguredWebSocketURL else { return }
        connect()
    }

    private func currentCalendarContextLines() -> [String] {
        settings.calendarContextEnabled ? calendarContext.contextSummaryLines : []
    }

    private func refreshCalendarContextIfNeeded() {
        Task {
            await refreshCalendarContextForJournal()
        }
    }

    private func refreshCalendarContextForJournal() async {
        guard settings.calendarContextEnabled else {
            updateJournalCalendarContextFromCurrentEvents(notifyServer: false)
            return
        }

        await calendarContext.refreshUpcomingEvents()
        updateJournalCalendarContextFromCurrentEvents(notifyServer: false)
    }

    private func updateJournalCalendarContextFromCurrentEvents(notifyServer: Bool) {
        let didChange = journalStore.updateCalendarContextLines(currentCalendarContextLines())
        if notifyServer, didChange, journalStore.isJournaling {
            viewModel.updateJournalContext(journalStore.promptContext())
        }
    }

    private func sendDraft() {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if journalStore.isJournaling {
            viewModel.sendJournalMessage(
                text,
                context: journalStore.promptContext(),
                visualContext: isCameraObservationMode ? cameraObservation.latestFrame : nil
            )
        } else {
            viewModel.sendMessage(
                text,
                visualContext: isCameraObservationMode ? cameraObservation.latestFrame : nil
            )
        }
        draftText = ""
    }

    private func toggleCameraObservationMode() {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
            isCameraObservationMode.toggle()
        }

        if isCameraObservationMode {
            cameraObservation.startObserving()
        } else {
            cameraObservation.stopObserving()
        }
    }
}

#Preview {
    ContentView()
}

private struct AvatarStartupPreviewView: View {
    let state: AvatarFrameState

    private static let previewImage: UIImage? = {
        guard let path = Bundle.main.path(forResource: "preview", ofType: "png") else {
            return nil
        }

        return UIImage(contentsOfFile: path)
    }()

    var body: some View {
        Group {
            if let previewImage = Self.previewImage {
                Image(uiImage: previewImage)
                    .resizable()
                    .scaledToFit()
            } else {
                MotionAvatarView(state: state)
                    .padding(.vertical, 24)
            }
        }
        .accessibilityHidden(true)
    }
}
