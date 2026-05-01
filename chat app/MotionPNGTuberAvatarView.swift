//
//  MotionPNGTuberAvatarView.swift
//  chat app
//

import SwiftUI
import WebKit

enum MotionPNGTuberLoadState: Equatable {
    case loading
    case ready
    case failed(String)
}

struct MotionPNGTuberAvatarView: UIViewRepresentable {
    let state: AvatarFrameState
    let sensitivity: Double
    @Binding var loadState: MotionPNGTuberLoadState

    init(
        state: AvatarFrameState,
        sensitivity: Double,
        loadState: Binding<MotionPNGTuberLoadState> = .constant(.loading)
    ) {
        self.state = state
        self.sensitivity = sensitivity
        _loadState = loadState
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(loadState: $loadState)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(
            context.coordinator,
            name: Coordinator.readyMessageName
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.accessibilityLabel = accessibilityLabel

        context.coordinator.webView = webView
        context.coordinator.loadPlayer(in: webView)
        context.coordinator.apply(state: state, sensitivity: sensitivity)

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        webView.accessibilityLabel = accessibilityLabel
        context.coordinator.loadState = $loadState
        context.coordinator.apply(state: state, sensitivity: sensitivity)
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.configuration.userContentController.removeScriptMessageHandler(
            forName: Coordinator.readyMessageName
        )
    }

    private var accessibilityLabel: String {
        switch state.runtimeState {
        case .idle:
            return "MotionPNGTuber アバター 待機中"
        case .listening:
            return "MotionPNGTuber アバター 聞き取り中"
        case .talking:
            return "MotionPNGTuber アバター 発話中"
        case .connecting:
            return "MotionPNGTuber アバター 接続中"
        case .error:
            return "MotionPNGTuber アバター エラー"
        }
    }
}

extension MotionPNGTuberAvatarView {
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let readyMessageName = "motionPngTuberReady"

        weak var webView: WKWebView?
        var loadState: Binding<MotionPNGTuberLoadState>

        private var isPlayerReady = false
        private var pendingScript: String?
        private var lastPayload: Payload?

        init(loadState: Binding<MotionPNGTuberLoadState>) {
            self.loadState = loadState
        }

        func loadPlayer(in webView: WKWebView) {
            guard let htmlURL = Bundle.main.url(
                forResource: "embed",
                withExtension: "html"
            ) else {
                setLoadState(.failed("アバタープレイヤーが見つかりません。"))
                webView.loadHTMLString(
                    "<html><body>MotionPNGTuber player is missing.</body></html>",
                    baseURL: nil
                )
                return
            }

            let readAccessURL = htmlURL.deletingLastPathComponent()
            webView.loadFileURL(htmlURL, allowingReadAccessTo: readAccessURL)
        }

        func apply(state: AvatarFrameState, sensitivity: Double) {
            let payload = Payload(
                volume: Self.outputVolume(from: state),
                high: Self.highComponent(from: state),
                low: Self.lowComponent(from: state),
                sensitivity: Int((sensitivity * 100).rounded())
                    .clamped(to: 0...100)
            )

            guard payload != lastPayload else { return }
            lastPayload = payload

            let script = """
            window.motionPngTuberSetVolume && window.motionPngTuberSetVolume({
              rms: \(payload.volume),
              high: \(payload.high),
              low: \(payload.low),
              sensitivity: \(payload.sensitivity)
            });
            """

            guard isPlayerReady else {
                pendingScript = script
                return
            }

            webView?.evaluateJavaScript(script)
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == Self.readyMessageName else { return }

            if let body = message.body as? [String: Any],
               let type = body["type"] as? String {
                switch type {
                case "ready":
                    markReady()
                case "error":
                    let message = body["message"] as? String ?? "アバターの読み込みに失敗しました。"
                    setLoadState(.failed(message))
                default:
                    break
                }
                return
            }

            if let body = message.body as? String, body == "ready" {
                markReady()
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            flushPendingScript()
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            setLoadState(.failed(error.localizedDescription))
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            setLoadState(.failed(error.localizedDescription))
        }

        private func markReady() {
            isPlayerReady = true
            setLoadState(.ready)
            flushPendingScript()
        }

        private func setLoadState(_ state: MotionPNGTuberLoadState) {
            loadState.wrappedValue = state
        }

        private func flushPendingScript() {
            guard isPlayerReady, let pendingScript else { return }
            self.pendingScript = nil
            webView?.evaluateJavaScript(pendingScript)
        }

        private static func outputVolume(from state: AvatarFrameState) -> Double {
            switch state.runtimeState {
            case .talking, .listening:
                return max(0, min(1, state.volumeLevel))
            case .connecting:
                return 0.03
            case .idle, .error:
                return 0
            }
        }

        private static func highComponent(from state: AvatarFrameState) -> Double {
            let volume = outputVolume(from: state)
            switch state.mood {
            case .happy, .surprised:
                return volume * 0.68
            case .sleepy, .concerned:
                return volume * 0.3
            case .neutral, .focused:
                return volume * 0.52
            }
        }

        private static func lowComponent(from state: AvatarFrameState) -> Double {
            let volume = outputVolume(from: state)
            return max(0.0001, volume - highComponent(from: state))
        }
    }

    private struct Payload: Equatable {
        var volume: Double
        var high: Double
        var low: Double
        var sensitivity: Int
    }
}

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}
