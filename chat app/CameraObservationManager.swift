//
//  CameraObservationManager.swift
//  chat app
//

import AVFoundation
import Combine
import CoreImage
import SwiftUI
import UIKit

struct CameraObservationFrame {
    let jpegData: Data
    let capturedAt: Date
    let width: Int
    let height: Int

    var dataURL: String {
        "data:image/jpeg;base64,\(jpegData.base64EncodedString())"
    }
}

final class CameraObservationManager: NSObject, ObservableObject {
    enum AuthorizationState: Equatable {
        case unknown
        case authorized
        case denied
        case restricted

        var label: String {
            switch self {
            case .unknown:
                "未確認"
            case .authorized:
                "許可済み"
            case .denied:
                "カメラ権限がありません"
            case .restricted:
                "カメラを使用できません"
            }
        }
    }

    @Published private(set) var isObserving = false
    @Published private(set) var latestFrame: CameraObservationFrame?
    @Published private(set) var authorizationState: AuthorizationState
    @Published private(set) var errorMessage: String?

    let session = AVCaptureSession()
    var onFrameCaptured: ((CameraObservationFrame) -> Void)?

    private let sessionQueue = DispatchQueue(label: "chat-app.camera.session")
    private let frameQueue = DispatchQueue(label: "chat-app.camera.frames")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let ciContext = CIContext()
    private var isConfigured = false
    private var lastFrameTime = Date.distantPast
    private var highFrequencyFrameCaptureUntil = Date.distantPast
    private let idleFrameInterval: TimeInterval = 4.0
    private let speechFrameInterval: TimeInterval = 1.2
    private let maxFrameSide: CGFloat = 384

    override init() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authorizationState = .authorized
        case .denied:
            authorizationState = .denied
        case .restricted:
            authorizationState = .restricted
        case .notDetermined:
            authorizationState = .unknown
        @unknown default:
            authorizationState = .unknown
        }

        super.init()
    }

    func startObserving() {
        errorMessage = nil

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authorizationState = .authorized
            configureAndStartSession()
        case .notDetermined:
            authorizationState = .unknown
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.authorizationState = granted ? .authorized : .denied
                    if granted {
                        self.configureAndStartSession()
                    } else {
                        self.isObserving = false
                        self.errorMessage = "設定アプリでカメラ権限を許可してください。"
                    }
                }
            }
        case .denied:
            authorizationState = .denied
            isObserving = false
            errorMessage = "設定アプリでカメラ権限を許可してください。"
        case .restricted:
            authorizationState = .restricted
            isObserving = false
            errorMessage = "この端末ではカメラを使用できません。"
        @unknown default:
            authorizationState = .unknown
            isObserving = false
            errorMessage = "カメラの状態を確認できません。"
        }
    }

    func stopObserving() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
            DispatchQueue.main.async {
                self.isObserving = false
            }
        }
    }

    func beginSpeechFrameCapture() {
        frameQueue.async { [weak self] in
            self?.highFrequencyFrameCaptureUntil = Date().addingTimeInterval(15)
            self?.lastFrameTime = .distantPast
        }
    }

    func endSpeechFrameCapture() {
        frameQueue.async { [weak self] in
            self?.highFrequencyFrameCaptureUntil = .distantPast
        }
    }

    private func configureAndStartSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            if !self.isConfigured {
                do {
                    try self.configureSession()
                    self.isConfigured = true
                } catch {
                    DispatchQueue.main.async {
                        self.isObserving = false
                        self.errorMessage = error.localizedDescription
                    }
                    return
                }
            }

            if !self.session.isRunning {
                self.session.startRunning()
            }

            let running = self.session.isRunning
            DispatchQueue.main.async {
                self.isObserving = running
                if running {
                    self.errorMessage = nil
                }
            }
        }
    }

    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .vga640x480

        guard
            let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        else {
            throw CameraObservationError.cameraUnavailable
        }

        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input) else {
            throw CameraObservationError.cannotAddInput
        }
        session.addInput(input)

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.setSampleBufferDelegate(self, queue: frameQueue)

        guard session.canAddOutput(videoOutput) else {
            throw CameraObservationError.cannotAddOutput
        }
        session.addOutput(videoOutput)

        if let connection = videoOutput.connection(with: .video),
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
    }
}

extension CameraObservationManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = Date()
        let frameInterval = now < highFrequencyFrameCaptureUntil ? speechFrameInterval : idleFrameInterval
        guard now.timeIntervalSince(lastFrameTime) >= frameInterval else { return }
        lastFrameTime = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = ciImage.extent
        let scale = min(maxFrameSide / max(extent.width, extent.height), 1)
        let outputImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cgImage = ciContext.createCGImage(outputImage, from: outputImage.extent) else { return }

        let image = UIImage(cgImage: cgImage)
        guard let data = image.jpegData(compressionQuality: 0.48) else { return }

        let frame = CameraObservationFrame(
            jpegData: data,
            capturedAt: now,
            width: Int(outputImage.extent.width),
            height: Int(outputImage.extent.height)
        )

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.latestFrame = frame
            self.onFrameCaptured?(frame)
        }
    }
}

private enum CameraObservationError: LocalizedError {
    case cameraUnavailable
    case cannotAddInput
    case cannotAddOutput

    var errorDescription: String? {
        switch self {
        case .cameraUnavailable:
            "利用できるカメラがありません。"
        case .cannotAddInput:
            "カメラ入力を開始できません。"
        case .cannotAddOutput:
            "カメラ映像を取得できません。"
        }
    }
}

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }
    }
}

final class CameraPreviewUIView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}
