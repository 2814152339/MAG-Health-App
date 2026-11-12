import AVFoundation
import Combine
import CoreMedia
import CoreVideo
import UIKit
import Vision

/// AVCaptureSession mutations and blocking start/stop calls stay on sessionQueue.
/// Published values are only written on the main queue. This app captures portrait photos.
final class CameraService: NSObject, ObservableObject {
    let session = AVCaptureSession()
    @Published private(set) var authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @Published private(set) var isRunning = false
    @Published private(set) var isCapturing = false
    @Published private(set) var isSwitching = false
    @Published private(set) var position: AVCaptureDevice.Position = .front
    @Published private(set) var capturedImage: UIImage?
    @Published private(set) var capturedDepth: DepthSnapshot?
    @Published private(set) var depthAvailable = false
    @Published private(set) var depthNotice = "本机未提供同拍绝对深度，使用二维照片分析"
    @Published private(set) var errorMessage: String?
    @Published private(set) var guidanceMessage = "将面部放在画面中央，正对镜头"
    @Published private(set) var isWellPositioned = false

    private let sessionQueue = DispatchQueue(label: "com.ruyuan.camera.session", qos: .userInitiated)
    private let visionQueue = DispatchQueue(label: "com.ruyuan.camera.guidance", qos: .userInitiated)
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let guidanceProcessor = FrameGuidanceProcessor()
    private var guidanceAvailable = false // Owned by sessionQueue, never read by the frame queue.
    private var input: AVCaptureDeviceInput?
    private var configured = false
    private var wantsRunning = false
    private var reviewingPhoto = false
    private var captureInFlight = false
    private var requestingPermission = false
    private var processor: PhotoProcessor?
    private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        guidanceProcessor.onResult = { [weak self] result, generation in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.guidanceProcessor.isCurrent(generation), self.isRunning,
                      !self.isCapturing, !self.isSwitching, self.capturedImage == nil else { return }
                self.guidanceMessage = result.message
                self.isWellPositioned = result.ready
            }
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
            object: session, queue: nil) { [weak self] notification in
                let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
                self?.sessionQueue.async { [weak self] in
                    guard let self else { return }
                    if error?.code == .mediaServicesWereReset, self.wantsRunning, !self.reviewingPhoto {
                        self.startConfiguredSession()
                    } else {
                        self.guidanceProcessor.suspend()
                        self.publish { camera in
                            camera.isRunning = false
                            camera.isWellPositioned = false
                            camera.errorMessage = "相机运行中断，请关闭相机后重新打开。"
                        }
                    }
                }
            })
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
            object: session, queue: nil) { [weak self] _ in
                self?.guidanceProcessor.suspend()
                self?.publish { camera in
                    camera.isRunning = false
                    camera.isWellPositioned = false
                    camera.errorMessage = "相机被其他任务占用或暂时中断，恢复后可重试。"
                }
            })
        observers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification,
            object: session, queue: nil) { [weak self] _ in
                self?.sessionQueue.async { [weak self] in
                    guard let self, self.wantsRunning, !self.reviewingPhoto else { return }
                    self.startConfiguredSession()
                }
            })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        guidanceProcessor.suspend()
        // The view may disappear before an enqueued weak-self stop executes.
        let captureSession = session
        let frames = videoOutput
        sessionQueue.async {
            if captureSession.isRunning { captureSession.stopRunning() }
            frames.setSampleBufferDelegate(nil, queue: nil)
        }
    }

    func start() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        publish { $0.authorizationStatus = status }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.wantsRunning = true
            guard !self.reviewingPhoto else { return }
            switch status {
            case .authorized:
                self.prepareAndStart()
            case .notDetermined:
                guard !self.requestingPermission else { return }
                self.requestingPermission = true
                AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                    guard let self else { return }
                    self.publish { $0.authorizationStatus = AVCaptureDevice.authorizationStatus(for: .video) }
                    self.sessionQueue.async { [weak self] in
                        guard let self else { return }
                        self.requestingPermission = false
                        guard self.wantsRunning, !self.reviewingPhoto else { return }
                        if granted { self.prepareAndStart() }
                    }
                }
            case .denied, .restricted:
                self.publish { $0.isRunning = false }
            @unknown default:
                self.publish { $0.errorMessage = "无法确认相机权限，请在系统设置中检查。" }
            }
        }
    }

    func stop() {
        guidanceProcessor.suspend() // Invalidates an in-flight result before the queued stop.
        let captureSession = session
        sessionQueue.async { [weak self, captureSession] in
            self?.wantsRunning = false
            self?.guidanceProcessor.suspend()
            if captureSession.isRunning { captureSession.stopRunning() }
            self?.publish { camera in camera.isRunning = false; camera.isWellPositioned = false }
        }
    }

    func retry() {
        publish { $0.errorMessage = nil }
        start()
    }

    func retake() {
        publish { camera in
            camera.capturedImage = nil
            camera.capturedDepth = nil
            camera.errorMessage = nil
            camera.isWellPositioned = false
        }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.reviewingPhoto = false
            self.wantsRunning = true
            self.prepareAndStart()
        }
    }

    func switchCamera() {
        sessionQueue.async { [weak self] in
            guard let self, self.configured, !self.captureInFlight, !self.reviewingPhoto,
                  let oldInput = self.input else { return }
            let nextPosition: AVCaptureDevice.Position = oldInput.device.position == .front ? .back : .front
            guard let device = Self.captureDevice(position: nextPosition) else {
                self.publish { $0.errorMessage = "这台设备没有可用的另一侧摄像头。" }
                return
            }
            self.publish { $0.isSwitching = true }
            self.guidanceProcessor.suspend()
            do {
                let nextInput = try AVCaptureDeviceInput(device: device)
                self.session.beginConfiguration()
                self.session.removeInput(oldInput)
                let accepted = self.session.canAddInput(nextInput)
                if accepted {
                    self.session.addInput(nextInput)
                    self.input = nextInput
                    self.configureDevice(device)
                    self.configurePhotoConnection()
                } else if self.session.canAddInput(oldInput) {
                    self.session.addInput(oldInput)
                }
                self.configureGuidanceConnection()
                self.configureDepthDelivery()
                self.session.commitConfiguration()
                self.startLiveGuidance()
                self.publish { camera in
                    camera.isSwitching = false
                    if accepted {
                        camera.position = nextPosition
                        camera.errorMessage = nil
                    } else {
                        camera.errorMessage = "切换摄像头失败，请重试。"
                    }
                }
            } catch {
                self.startLiveGuidance()
                self.publish { camera in
                    camera.isSwitching = false
                    camera.errorMessage = "无法打开另一侧摄像头，请重试。"
                }
            }
        }
    }

    func capture() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.configured, self.session.isRunning, !self.session.isInterrupted,
                  !self.captureInFlight, !self.reviewingPhoto else { return }
            self.captureInFlight = true
            self.guidanceProcessor.suspend()
            self.publish { camera in
                camera.isCapturing = true
                camera.isWellPositioned = false
                camera.errorMessage = nil
            }
            self.configurePhotoConnection()
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            settings.flashMode = .off
            settings.photoQualityPrioritization = .quality
            let trueDepth = self.input?.device.deviceType == .builtInTrueDepthCamera
            let requestDepth = trueDepth && self.photoOutput.isDepthDataDeliveryEnabled && self.photoOutput.isDepthDataDeliverySupported
            if requestDepth {
                settings.isDepthDataDeliveryEnabled = true
                settings.isDepthDataFiltered = false
                // Depth remains a transient, explicitly paired payload, not hidden photo metadata.
                settings.embedsDepthDataInPhoto = false
            }
            let processor = PhotoProcessor(isTrueDepth: requestDepth) { [weak self] result in
                guard let self else { return }
                self.sessionQueue.async { [weak self] in
                    guard let self else { return }
                    self.captureInFlight = false
                    self.processor = nil
                    switch result {
                    case .success(let capture):
                        self.reviewingPhoto = true
                        if self.session.isRunning { self.session.stopRunning() }
                        self.publish { camera in
                            camera.capturedImage = capture.image
                            camera.capturedDepth = capture.depth
                            camera.depthNotice = capture.depthNotice
                            camera.isCapturing = false
                            camera.isRunning = false
                        }
                    case .failure:
                        self.startLiveGuidance()
                        self.publish { camera in
                            camera.isCapturing = false
                            camera.errorMessage = "照片拍摄失败，请保持设备稳定后重试。"
                        }
                    }
                }
            }
            self.processor = processor // Retain until didFinishCapture, not only didFinishProcessingPhoto.
            self.photoOutput.capturePhoto(with: settings, delegate: processor)
        }
    }

    private func prepareAndStart() {
        guard wantsRunning, !reviewingPhoto else { return }
        do {
            if !configured { try configure() }
            startConfiguredSession()
        } catch {
            publish { camera in
                camera.isRunning = false
                camera.errorMessage = error.localizedDescription
            }
        }
    }

    private func configure() throws {
        let device = Self.captureDevice(position: .front) ?? Self.captureDevice(position: .back)
        guard let device else { throw CameraFailure.noDevice }
        let newInput = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
        guard session.canAddInput(newInput) else { throw CameraFailure.configuration }
        session.addInput(newInput)
        guard session.canAddOutput(photoOutput) else {
            session.removeInput(newInput)
            throw CameraFailure.configuration
        }
        session.addOutput(photoOutput)
        photoOutput.maxPhotoQualityPrioritization = .quality
        // Preview frames exist only transiently in memory; there is no movie/file output.
        // Guidance is optional: an unsupported data output must not break still capture.
        if session.canAddOutput(videoOutput) {
            videoOutput.alwaysDiscardsLateVideoFrames = true
            session.addOutput(videoOutput)
            videoOutput.setSampleBufferDelegate(guidanceProcessor, queue: visionQueue)
        }
        input = newInput
        configureDevice(device)
        configurePhotoConnection()
        configureGuidanceConnection()
        configureDepthDelivery()
        configured = true
        publish { $0.position = device.position }
    }

    private func startConfiguredSession() {
        guard configured, wantsRunning, !reviewingPhoto else { return }
        guard !session.isInterrupted else {
            publish { camera in
                camera.isRunning = false
                camera.errorMessage = "相机仍处于系统中断状态，请稍后重试。"
            }
            return
        }
        if !session.isRunning { session.startRunning() }
        let running = session.isRunning
        if running { startLiveGuidance() } else { guidanceProcessor.suspend() }
        publish { camera in
            camera.isRunning = running
            camera.errorMessage = running ? nil : "相机未能启动，请检查是否被其他应用占用。"
        }
    }

    private func configurePhotoConnection() {
        guard let connection = photoOutput.connection(with: .video) else { return }
        // Portrait-only app. Saved captures are unmirrored; only the live selfie preview mirrors.
        if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
    }

    private func configureGuidanceConnection() {
        guidanceAvailable = false
        guard let connection = videoOutput.connection(with: .video) else { return }
        // Supported buffer formats can change after switching capture devices.
        let formats = videoOutput.availableVideoPixelFormatTypes
        if formats.contains(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        } else if formats.contains(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        } else { videoOutput.videoSettings = [:] }
        // Physically rotate data buffers upright. Do not guess front/back EXIF mappings.
        // If a device cannot do this, still capture stays available without live guidance.
        if connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
            guidanceAvailable = true
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
    }

    private func startLiveGuidance() {
        guard wantsRunning, !reviewingPhoto, !captureInFlight else { return }
        if guidanceAvailable { guidanceProcessor.begin() } else { guidanceProcessor.suspend() }
        let available = guidanceAvailable
        publish { camera in
            camera.isWellPositioned = false
            camera.guidanceMessage = available ? "将面部放在画面中央，正对镜头" : "实时定位暂不可用，仍可手动拍摄"
        }
    }

    private func configureDevice(_ device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
            if device.deviceType == .builtInTrueDepthCamera {
                let formats = device.activeFormat.supportedDepthDataFormats.filter {
                    let subtype = CMFormatDescriptionGetMediaSubType($0.formatDescription)
                    return subtype == kCVPixelFormatType_DepthFloat16 || subtype == kCVPixelFormatType_DepthFloat32
                }
                if let best = formats.max(by: {
                    CMVideoFormatDescriptionGetDimensions($0.formatDescription).width < CMVideoFormatDescriptionGetDimensions($1.formatDescription).width
                }) { device.activeDepthDataFormat = best }
            }
        } catch {
            // The camera's automatic defaults remain usable if this optional configuration fails.
        }
    }

    private static func captureDevice(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        if position == .front, let trueDepth = AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front) { return trueDepth }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    }

    /// Invoked only inside sessionQueue configuration transactions, never on a frame callback.
    private func configureDepthDelivery() {
        let enabled = input?.device.deviceType == .builtInTrueDepthCamera && photoOutput.isDepthDataDeliverySupported
        photoOutput.isDepthDataDeliveryEnabled = enabled
        publish { camera in
            camera.depthAvailable = enabled
            camera.depthNotice = enabled ? "已启用同拍TrueDepth；仅有效绝对深度与标定齐全时提供表面毫米参考" : "此摄像头无可用同拍绝对深度，继续二维照片分析"
        }
    }

    private func publish(_ update: @escaping (CameraService) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            update(self)
        }
    }

    private enum CameraFailure: LocalizedError {
        case noDevice, configuration, invalidPhoto
        var errorDescription: String? {
            switch self {
            case .noDevice: return "此设备没有可用摄像头。模拟器请返回首页，从相册选择照片。"
            case .configuration: return "相机配置失败，请关闭后重新打开。"
            case .invalidPhoto: return "拍摄的照片无法读取，请重拍。"
            }
        }
    }

    private struct FrameGuidance: Sendable {
        let message: String
        let ready: Bool
    }

    /// Synchronous Vision work stays on a dedicated serial callback queue. Only a small
    /// summary crosses to the UI; sample buffers, crops and face observations are not retained.
    private final class FrameGuidanceProcessor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        var onResult: ((FrameGuidance, UInt64) -> Void)? // Set once before attaching the output.
        private let stateLock = NSLock()
        private var enabled = false
        private var generation: UInt64 = 0
        private var lastAnalysisTime = -Double.infinity // Frame-queue owned.
        private var previousGeneration: UInt64 = 0
        private var readyStreak = 0

        func begin() {
            stateLock.lock()
            generation &+= 1
            enabled = true
            stateLock.unlock()
        }
        func suspend() {
            stateLock.lock()
            generation &+= 1
            enabled = false
            stateLock.unlock()
        }
        func isCurrent(_ token: UInt64) -> Bool {
            stateLock.lock()
            defer { stateLock.unlock() }
            return enabled && generation == token
        }
        private func currentGeneration() -> UInt64? {
            stateLock.lock()
            defer { stateLock.unlock() }
            return enabled ? generation : nil
        }

        func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
            let started = ProcessInfo.processInfo.systemUptime
            guard started - lastAnalysisTime >= 0.4, let token = currentGeneration(),
                  CMSampleBufferDataIsReady(sampleBuffer), let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            lastAnalysisTime = started
            if previousGeneration != token { readyStreak = 0; previousGeneration = token }
            let result: FrameGuidance = autoreleasepool {
                do {
                    let request = VNDetectFaceRectanglesRequest()
                    request.revision = VNDetectFaceRectanglesRequestRevision3
                    try VNImageRequestHandler(cvPixelBuffer: image, orientation: .up, options: [:]).perform([request])
                    return Self.assess(request.results ?? [])
                } catch {
                    // Vision is advisory, not a permission gate or a reason to disable the shutter.
                    return FrameGuidance(message: "暂未稳定定位，正对镜头后仍可手动拍摄", ready: false)
                }
            }
            guard isCurrent(token) else { return }
            guard ProcessInfo.processInfo.systemUptime - started <= 0.9 else {
                readyStreak = 0
                onResult?(FrameGuidance(message: "实时定位较慢，仍可手动拍摄", ready: false), token)
                return // Discard the stale face result, never queue old detections for display.
            }
            readyStreak = result.ready ? min(readyStreak + 1, 2) : 0
            if result.ready && readyStreak < 2 {
                onResult?(FrameGuidance(message: "位置合适，请保持片刻", ready: false), token)
            } else { onResult?(result, token) }
        }

        private static func assess(_ faces: [VNFaceObservation]) -> FrameGuidance {
            guard !faces.isEmpty else { return FrameGuidance(message: "请将面部放入画面中央", ready: false) }
            guard faces.count == 1 else { return FrameGuidance(message: "画面中有多人，请只保留一张脸", ready: false) }
            let face = faces[0], box = face.boundingBox
            guard face.confidence >= 0.55, box.width > 0, box.height > 0 else {
                return FrameGuidance(message: "面部定位不稳定，请正对镜头", ready: false)
            }
            if box.width < 0.22 || box.height < 0.30 { return FrameGuidance(message: "请稍微靠近镜头", ready: false) }
            if box.width > 0.75 || box.height > 0.80 || box.minX < 0.025 || box.maxX > 0.975 || box.minY < 0.025 || box.maxY > 0.975 {
                return FrameGuidance(message: "请稍微远离镜头，保留完整面部", ready: false)
            }
            if abs(box.midX - 0.5) > 0.14 || abs(box.midY - 0.5) > 0.17 {
                return FrameGuidance(message: "请将面部移到画面中央", ready: false)
            }
            guard let yaw = face.yaw?.doubleValue, let roll = face.roll?.doubleValue, let pitch = face.pitch?.doubleValue,
                  yaw.isFinite, roll.isFinite, pitch.isFinite else {
                return FrameGuidance(message: "居中与距离合适，请正对镜头拍摄", ready: false)
            }
            if abs(yaw) > 0.22 { return FrameGuidance(message: "请正对镜头，减少左右侧转", ready: false) }
            if abs(roll) > 0.17 { return FrameGuidance(message: "请保持头部水平", ready: false) }
            if abs(pitch) > 0.22 { return FrameGuidance(message: "请让镜头与双眼平齐", ready: false) }
            return FrameGuidance(message: "位置合适，请保持并拍摄", ready: true)
        }
    }

    private final class PhotoProcessor: NSObject, AVCapturePhotoCaptureDelegate {
        private let completion: (Result<CameraCapture, Error>) -> Void
        private let isTrueDepth: Bool
        private var processed: Result<CameraCapture, Error>?
        init(isTrueDepth: Bool, completion: @escaping (Result<CameraCapture, Error>) -> Void) {
            self.isTrueDepth = isTrueDepth; self.completion = completion
        }

        func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
            if let error { processed = .failure(error); return }
            guard let data = photo.fileDataRepresentation(), let image = UIImage(data: data) else {
                processed = .failure(CameraFailure.invalidPhoto)
                return
            }
            // Preserve the capture's EXIF rotation until the caller canonicalizes pixels.
            // The capture connection explicitly disabled horizontal mirroring.
            let depth: DepthSnapshot?
            let notice: String
            do {
                depth = try DepthSnapshot.capture(photo: photo, image: image, jpeg: data, isTrueDepth: isTrueDepth)
                notice = "已取得同拍绝对深度与标定；仅稳定的可见表面端点提供毫米参考，不是骨性或临床测量。"
            } catch {
                depth = nil
                notice = (error as? DepthSnapshot.CaptureFailure)?.localizedDescription ?? "本次深度处理未完成，照片仍可用于二维分析。"
            }
            processed = .success(CameraCapture(image: image, depth: depth, depthNotice: notice))
        }

        func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
            if let error { completion(.failure(error)) }
            else { completion(processed ?? .failure(CameraFailure.invalidPhoto)) }
        }
    }
}
