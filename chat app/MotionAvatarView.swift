//
//  MotionAvatarView.swift
//  chat app
//

import SwiftUI

struct MotionAvatarView: View {
    let state: AvatarFrameState

    init(state: AvatarFrameState = .idle) {
        self.state = state
    }

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let speakingLift = state.runtimeState.isTalking ? side * 0.012 : 0

            ZStack {
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.25, green: 0.44, blue: 0.72),
                                Color(red: 0.16, green: 0.28, blue: 0.48)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: side * 0.42, height: side * 0.54)
                    .offset(y: side * 0.22)

                Circle()
                    .fill(Color(red: 0.98, green: 0.86, blue: 0.75))
                    .frame(width: side * 0.56, height: side * 0.56)
                    .overlay(alignment: .top) {
                        Capsule(style: .continuous)
                            .fill(Color(red: 0.22, green: 0.18, blue: 0.16))
                            .frame(width: side * 0.52, height: side * 0.21)
                            .offset(y: -side * 0.02)
                    }
                    .overlay {
                        FaceView(
                            mood: state.mood,
                            mouthOpen: state.runtimeState.isTalking ? max(0.18, state.volumeLevel) : 0.08
                        )
                        .frame(width: side * 0.36, height: side * 0.25)
                        .offset(y: side * 0.07)
                    }
                    .offset(y: -side * 0.1 - speakingLift)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .shadow(color: Color.black.opacity(0.14), radius: 16, y: 9)
            .scaleEffect(scale)
            .animation(.spring(response: 0.24, dampingFraction: 0.86), value: state.runtimeState)
            .animation(.easeOut(duration: 0.12), value: state.volumeLevel)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var scale: CGFloat {
        switch state.runtimeState {
        case .listening:
            return 1.02
        case .talking:
            return 1.025
        case .connecting:
            return 0.98
        case .error:
            return 0.97
        case .idle:
            return 1
        }
    }

    private var accessibilityLabel: String {
        switch state.runtimeState {
        case .idle:
            return "サンプルアバター 待機中"
        case .listening:
            return "サンプルアバター 聞き取り中"
        case .talking:
            return "サンプルアバター 発話中"
        case .connecting:
            return "サンプルアバター 接続中"
        case .error:
            return "サンプルアバター エラー"
        }
    }
}

private struct FaceView: View {
    let mood: AvatarMood
    let mouthOpen: Double

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 42) {
                eye
                eye
            }

            mouth
        }
    }

    private var eye: some View {
        Circle()
            .fill(Color(red: 0.08, green: 0.07, blue: 0.06))
            .frame(width: 16, height: eyeHeight)
    }

    private var eyeHeight: CGFloat {
        switch mood {
        case .sleepy:
            return 5
        case .happy:
            return 11
        default:
            return 16
        }
    }

    private var mouth: some View {
        Capsule(style: .continuous)
            .fill(mouthColor)
            .frame(width: mouthWidth, height: mouthHeight)
            .overlay(alignment: .top) {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.55))
                    .frame(width: mouthWidth * 0.58, height: max(2, mouthHeight * 0.18))
                    .padding(.top, 2)
            }
    }

    private var mouthColor: Color {
        switch mood {
        case .concerned:
            return Color(red: 0.46, green: 0.18, blue: 0.23)
        default:
            return Color(red: 0.65, green: 0.18, blue: 0.23)
        }
    }

    private var mouthWidth: CGFloat {
        switch mood {
        case .surprised:
            return 24
        case .concerned:
            return 28
        default:
            return 42
        }
    }

    private var mouthHeight: CGFloat {
        let clamped = min(max(mouthOpen, 0.05), 1)
        return 5 + CGFloat(clamped) * 28
    }
}

#Preview("Sample Avatar") {
    MotionAvatarView(state: .talking(volumeLevel: 0.78))
        .frame(width: 260, height: 420)
        .padding()
}
