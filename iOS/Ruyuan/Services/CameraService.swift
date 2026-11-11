import AVFoundation
import Combine
import UIKit

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
    @Published private(set) var errorMessage: String?

    private let sessionQueue = DispatchQueue(label: "com.ruyuan.camera.session", qos: .userInitiated)
    private let photoOutput = AVCapturePhotoOutput()
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
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
            object: session, queue: nil) { [weak self] notification in
                let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
                self?.sessionQueue.async { [weak self] in
                    guard let self else { return }
                    if error?.code == .mediaServicesWereReset, self.wantsRunning, !self.reviewingPhoto {
                        self.startConfiguredSession()
                    } else {
                        self.publish { camera in
                            camera.isRunning = false
                            camera.errorMessage = "相机运行中断，请关闭相机后重新打开。"
                        }
                    }
                }
            })
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
            object: session, queue: nil) { [weak self] _ in
                self?.publish { camera in
                    camera.isRunning = false
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
        // The view may disappear before an enqueued weak-self stop executes.
        let captureSession = session
        sessionQueue.async {
            if captureSession.isRunning { captureSession.stopRunning() }
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
        let captureSession = session
        sessionQueue.async { [weak self, captureSession] in
            self?.wantsRunning = false
            if captureSession.isRunning { captureSession.stopRunning() }
            self?.publish { $0.isRunning = false }
        }
    }

    func retry() {
        publish { $0.errorMessage = nil }
        start()
    }

    func retake() {
        publish { camera in
            camera.capturedImage = nil
            camera.errorMessage = nil
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
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: nextPosition) else {
                self.publish { $0.errorMessage = "这台设备没有可用的另一侧摄像头。" }
                return
            }
            self.publish { $0.isSwitching = true }
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
                self.session.commitConfiguration()
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
            self.publish { camera in
                camera.isCapturing = true
                camera.errorMessage = nil
            }
            self.configurePhotoConnection()
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            settings.flashMode = .off
            settings.photoQualityPrioritization = .quality
            let processor = PhotoProcessor { [weak self] result in
                guard let self else { return }
                self.sessionQueue.async { [weak self] in
                    guard let self else { return }
                    self.captureInFlight = false
                    self.processor = nil
                    switch result {
                    case .success(let image):
                        self.reviewingPhoto = true
                        if self.session.isRunning { self.session.stopRunning() }
                        self.publish { camera in
                            camera.capturedImage = image
                            camera.isCapturing = false
                            camera.isRunning = false
                        }
                    case .failure:
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
        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
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
        input = newInput
        configureDevice(device)
        configurePhotoConnection()
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

    private func configureDevice(_ device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
        } catch {
            // The camera's automatic defaults remain usable if this optional configuration fails.
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

    private final class PhotoProcessor: NSObject, AVCapturePhotoCaptureDelegate {
        private let completion: (Result<UIImage, Error>) -> Void
        private var processed: Result<UIImage, Error>?
        init(completion: @escaping (Result<UIImage, Error>) -> Void) { self.completion = completion }

        func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
            if let error { processed = .failure(error); return }
            guard let data = photo.fileDataRepresentation(), let image = UIImage(data: data) else {
                processed = .failure(CameraFailure.invalidPhoto)
                return
            }
            // Preserve the capture's EXIF rotation until the caller canonicalizes pixels.
            // The capture connection explicitly disabled horizontal mirroring.
            processed = .success(image)
        }

        func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
            if let error { completion(.failure(error)) }
            else { completion(processed ?? .failure(CameraFailure.invalidPhoto)) }
        }
    }
}
