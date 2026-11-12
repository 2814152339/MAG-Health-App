import AVFoundation
import SwiftUI
import UIKit

struct CameraView: View {
    let onDepthCapture: (CameraCapture) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var camera = CameraService()
    private let ink = RuyuanStyle.ink
    private let accent = Color(hex: "7775FF")
    private let paper = Color(hex: "F5F3FC")

    init(onCapture: @escaping (UIImage) -> Void) { self.onDepthCapture = { onCapture($0.image) } }
    init(onDepthCapture: @escaping (CameraCapture) -> Void) { self.onDepthCapture = onDepthCapture }

    var body: some View {
        ZStack {
            paper.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                if let image = camera.capturedImage {
                    review(image)
                } else {
                    captureContent
                }
            }
        }
        .preferredColorScheme(.light)
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { camera.start() } else { camera.stop() }
        }
    }

    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 44, height: 44)
                    .background(.white.opacity(0.75), in: Circle())
            }
            .accessibilityLabel("关闭相机")
            Spacer()
            VStack(spacing: 3) {
                Text(camera.capturedImage == nil ? "拍照测肤" : "确认这张照片")
                    .font(.system(size: 19, weight: .semibold))
                Text("如愿 · 美学记录")
                    .font(.system(size: 11))
                    .tracking(2)
                    .foregroundStyle(ink.opacity(0.55))
            }
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 18)
    }

    private var captureContent: some View {
        VStack(spacing: 18) {
            ZStack {
                CameraPreview(session: camera.session, mirrored: camera.position == .front)
                    .background(Color.black)
                if camera.authorizationStatus == .authorized && camera.isRunning {
                    GeometryReader { proxy in
                        let width = min(proxy.size.width * 0.72, min(270, max(60, (proxy.size.height - 70) / 1.32)))
                        VStack {
                            Spacer()
                            Ellipse()
                                .stroke(camera.isWellPositioned ? Color(hex: "7EE1B5") : .white.opacity(0.85),
                                        style: StrokeStyle(lineWidth: camera.isWellPositioned ? 2.5 : 1.2, dash: [7, 6]))
                                .frame(width: width, height: width * 1.32)
                                .animation(.easeInOut(duration: 0.2), value: camera.isWellPositioned)
                            Spacer()
                            Label(camera.guidanceMessage, systemImage: camera.isWellPositioned ? "checkmark.circle.fill" : "viewfinder")
                                .font(.system(size: 12, weight: .medium))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 15).padding(.vertical, 9)
                                .background(.black.opacity(0.35), in: Capsule())
                                .foregroundStyle(camera.isWellPositioned ? Color(hex: "A9F1D0") : .white)
                                .padding(.horizontal, 12)
                                .padding(.bottom, 18)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .allowsHitTesting(false)
                }
                cameraStateOverlay
            }
            .clipShape(RoundedRectangle(cornerRadius: 28))
            .padding(.horizontal, 22)
            .frame(maxHeight: .infinity)

            VStack(spacing: 5) {
                Text("均匀自然光 · 素颜优先 · 关闭美颜")
                    .font(.system(size: 13, weight: .medium))
                Text("请竖屏拍摄；自拍预览会镜像，保存照片不会镜像")
                    .font(.system(size: 11))
                    .foregroundStyle(ink.opacity(0.58))
                Text("实时定位仅作拍摄参考，不录制视频，也不限制手动拍摄")
                    .font(.system(size: 10)).foregroundStyle(accent)
                    .multilineTextAlignment(.center)
                Text(camera.depthAvailable ? "TrueDepth同拍深度已启用 · 不支持时自动保留二维分析" : "当前摄像头为二维照片分析 · 不生成无依据的毫米")
                    .font(.system(size: 10)).foregroundStyle(ink.opacity(0.58))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(ink)
            HStack {
                Color.clear.frame(width: 56, height: 56)
                Spacer()
                Button { camera.capture() } label: {
                    ZStack {
                        Circle().stroke(accent.opacity(0.55), lineWidth: 2).frame(width: 76, height: 76)
                        Circle().fill(LinearGradient(colors: [accent, Color(hex: "9C82ED")], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 62, height: 62)
                        if camera.isCapturing { ProgressView().tint(.white) }
                    }
                }
                .accessibilityLabel("拍摄照片")
                .disabled(!camera.isRunning || camera.isCapturing || camera.isSwitching)
                .opacity(camera.isRunning ? 1 : 0.4)
                Spacer()
                Button { camera.switchCamera() } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(.system(size: 23, weight: .light))
                        .frame(width: 56, height: 56)
                        .foregroundStyle(accent)
                        .background(.white.opacity(0.8), in: Circle())
                }
                .accessibilityLabel("切换前后摄像头")
                .disabled(!camera.isRunning || camera.isCapturing || camera.isSwitching)
            }
            .padding(.horizontal, 42)
            .padding(.bottom, 24)
        }
    }

    @ViewBuilder private var cameraStateOverlay: some View {
        switch camera.authorizationStatus {
        case .denied:
            stateCard(title: "需要相机权限", detail: "照片只在你确认后使用。也可以返回首页从相册选择照片。", action: "前往系统设置") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
        case .restricted:
            stateCard(title: "相机受到系统限制", detail: "请检查设备管理或屏幕使用时间设置，也可返回使用相册。")
        case .notDetermined:
            VStack(spacing: 12) {
                ProgressView().tint(.white)
                Text("请允许相机访问").font(.system(size: 14)).foregroundStyle(.white)
            }
        case .authorized:
            if let message = camera.errorMessage {
                stateCard(title: "相机暂不可用", detail: message, action: "重试") { camera.retry() }
            } else if !camera.isRunning {
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text("正在准备相机…").font(.system(size: 14)).foregroundStyle(.white)
                }
            }
        @unknown default:
            stateCard(title: "相机权限未知", detail: "请返回后从系统设置检查权限。")
        }
    }

    private func stateCard(title: String, detail: String, action: String? = nil,
                           perform: (() -> Void)? = nil) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "camera").font(.system(size: 32, weight: .light)).foregroundStyle(accent)
            Text(title).font(.system(size: 18, weight: .medium))
            Text(detail).font(.system(size: 13)).multilineTextAlignment(.center).foregroundStyle(ink.opacity(0.65))
            if let action, let perform {
                Button(action, action: perform).font(.system(size: 14, weight: .medium)).foregroundStyle(accent)
                    .padding(.top, 3)
            }
        }
        .foregroundStyle(ink)
        .padding(25)
        .frame(maxWidth: 300)
        .background(paper, in: RoundedRectangle(cornerRadius: 24))
        .padding(20)
    }

    private func review(_ image: UIImage) -> some View {
        VStack(spacing: 20) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ink.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 28))
                .padding(.horizontal, 22)
            Text("确认画面清晰、五官无遮挡，再继续检测。")
                .font(.system(size: 12))
                .foregroundStyle(ink.opacity(0.65))
            Text(camera.depthNotice)
                .font(.system(size: 10)).foregroundStyle(ink.opacity(0.58))
                .multilineTextAlignment(.center).padding(.horizontal, 25)
            HStack(spacing: 14) {
                Button("重拍") { camera.retake() }
                    .frame(maxWidth: .infinity).frame(height: 52)
                    .foregroundStyle(accent)
                    .background(.white, in: Capsule())
                Button("使用这张") {
                    camera.stop()
                    onDepthCapture(CameraCapture(image: image, depth: camera.capturedDepth, depthNotice: camera.depthNotice))
                    dismiss()
                }
                .frame(maxWidth: .infinity).frame(height: 52)
                .foregroundStyle(.white)
                .background(accent, in: Capsule())
            }
            .font(.system(size: 15, weight: .medium))
            .padding(.horizontal, 22)
            .padding(.bottom, 24)
        }
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let mirrored: Bool

    func makeUIView(context: Context) -> PreviewSurface {
        let view = PreviewSurface()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        updateConnection(view)
        return view
    }

    func updateUIView(_ view: PreviewSurface, context: Context) { updateConnection(view) }

    private func updateConnection(_ view: PreviewSurface) {
        guard let connection = view.previewLayer.connection else { return }
        if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
    }

    final class PreviewSurface: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
