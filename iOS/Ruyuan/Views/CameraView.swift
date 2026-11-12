import AVFoundation
import SwiftUI
import UIKit

struct CameraView: View {
    let onDepthCapture: (CameraCapture) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var camera = CameraService()
    @State private var showsInstructions = false

    init(onCapture: @escaping (UIImage) -> Void) { self.onDepthCapture = { onCapture($0.image) } }
    init(onDepthCapture: @escaping (CameraCapture) -> Void) { self.onDepthCapture = onDepthCapture }

    var body: some View {
        Group {
            if let image = camera.capturedImage {
                review(image)
            } else {
                captureContent
            }
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(.white)
        .statusBarHidden(true)
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { camera.start() } else { camera.stop() }
        }
    }

    private var captureContent: some View {
        GeometryReader { proxy in
            let previewHeight = CameraFraming.previewHeight(in: proxy.size,
                accessibility: dynamicTypeSize.isAccessibilitySize)
            VStack(spacing: 0) {
                CameraTopBar(onInfo: { showsInstructions = true })
                livePreview
                    .frame(height: previewHeight)
                captureControls
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(Color.black)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cameraCaptureScreen")
        .sheet(isPresented: $showsInstructions) {
            CameraInstructions(depthNotice: liveDepthNotice, reviewing: false)
        }
    }

    private var liveDepthNotice: String {
        camera.depthAvailable
            ? "当前摄像头已启用同拍深度；只有取得有效绝对深度与标定后，才提供可见表面毫米参考。"
            : "当前摄像头使用二维照片分析，不生成无依据的毫米值。"
    }

    private var livePreview: some View {
        GeometryReader { proxy in
            // Keep the viewport 3:4 even on a short screen / large Dynamic Type.
            // Black side gutters are preferable to cropping the composition guide.
            let width = min(proxy.size.width, proxy.size.height * 3 / 4)
            ZStack {
                CameraPreview(session: camera.session, mirrored: camera.position == .front)
                    .background(Color.black)
                if camera.authorizationStatus == .authorized && camera.isRunning {
                    CameraCompositionGrid()
                    VStack {
                        Text("均匀光线 · 正对镜头 · 关闭美颜")
                            .font(.caption2).multilineTextAlignment(.center).lineLimit(2)
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.black.opacity(0.35), in: Capsule())
                            .padding(.horizontal, 12).padding(.top, 10)
                        Spacer()
                        Label(camera.isCapturing ? "正在拍摄，请保持稳定" : camera.guidanceMessage,
                              systemImage: camera.isWellPositioned ? "checkmark.circle.fill" : "viewfinder")
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(.black.opacity(0.48), in: Capsule())
                            .padding(.horizontal, 12).padding(.bottom, 12)
                    }
                    .allowsHitTesting(false)
                }
                cameraStateOverlay
            }
            .frame(width: width, height: proxy.size.height)
            .clipped()
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
    }

    private var captureControls: some View {
        VStack(spacing: 6) {
            Text("拍照").font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(hex: "FF6868"))
                .accessibilityHidden(true)
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 23, weight: .light))
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("关闭相机")
                .accessibilityIdentifier("cameraClose")
                Spacer(minLength: 12)
                Button { camera.capture() } label: {
                    ZStack {
                        Circle().stroke(.white, lineWidth: 2.5).frame(width: 72, height: 72)
                        Circle().fill(.white).frame(width: 60, height: 60)
                        if camera.isCapturing { ProgressView().tint(.black) }
                    }
                    .frame(width: 76, height: 76).contentShape(Circle())
                }
                .accessibilityLabel(camera.isCapturing ? "正在拍摄照片" : "拍摄照片")
                .accessibilityIdentifier("cameraCaptureShutter")
                .disabled(!camera.isRunning || camera.isCapturing || camera.isSwitching)
                .opacity(camera.isRunning ? 1 : 0.4)
                Spacer(minLength: 12)
                Button { camera.switchCamera() } label: {
                    Image(systemName: "arrow.triangle.2.circlepath.camera")
                        .font(.system(size: 23, weight: .light))
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("切换前后摄像头")
                .accessibilityIdentifier("cameraSwitchLens")
                .disabled(!camera.isRunning || camera.isCapturing || camera.isSwitching)
            }
            .foregroundStyle(.white)
            .buttonStyle(.plain)
            .padding(.horizontal, 20)
        }
        .padding(.top, 6).padding(.bottom, 10)
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
                Text("请允许相机访问").font(.subheadline).foregroundStyle(.white)
            }
        case .authorized:
            if let message = camera.errorMessage {
                stateCard(title: "相机暂不可用", detail: message, action: "重试") { camera.retry() }
            } else if !camera.isRunning {
                VStack(spacing: 12) {
                    ProgressView().tint(.white)
                    Text("正在准备相机…").font(.subheadline).foregroundStyle(.white)
                }
            }
        @unknown default:
            stateCard(title: "相机权限未知", detail: "请返回后从系统设置检查权限。")
        }
    }

    private func stateCard(title: String, detail: String, action: String? = nil,
                           perform: (() -> Void)? = nil) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                Image(systemName: "camera").font(.system(size: 30, weight: .light))
                Text(title).font(.headline)
                Text(detail).font(.subheadline).multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.8))
                if let action, let perform {
                    Button(action, action: perform).font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(.white.opacity(0.15), in: Capsule())
                }
            }
            .foregroundStyle(.white).padding(22).frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: 340, maxHeight: 280)
        .background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 18))
        .padding(16)
    }

    private func review(_ image: UIImage) -> some View {
        CameraPhotoReview(image: image, depthNotice: camera.depthNotice,
            onRetake: { camera.retake() },
            onUse: {
                camera.stop()
                onDepthCapture(CameraCapture(image: image, depth: camera.capturedDepth, depthNotice: camera.depthNotice))
                dismiss()
            }, onClose: { dismiss() })
    }
}

/// Shared by live and confirmation screens. It changes presentation only; it does
/// not resize/crop/re-encode the captured UIImage or alter a depth binding.
enum CameraFraming {
    static let topBarHeight: CGFloat = 44

    static func previewHeight(in size: CGSize, accessibility: Bool = false) -> CGFloat {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return 0 }
        let controls: CGFloat = accessibility ? 220 : 116
        return min(size.width * 4 / 3, max(0, size.height - topBarHeight - controls))
    }
}

/// Uses the same real confirmation component in the app and any explicit DEBUG
/// synthetic layout harness. Callers retain responsibility for the capture payload.
struct CameraPhotoReview: View {
    let image: UIImage
    let depthNotice: String
    let onRetake: () -> Void
    let onUse: () -> Void
    var onClose: (() -> Void)? = nil
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showsInstructions = false

    var body: some View {
        GeometryReader { proxy in
            let previewHeight = CameraFraming.previewHeight(in: proxy.size,
                accessibility: dynamicTypeSize.isAccessibilitySize)
            VStack(spacing: 0) {
                CameraTopBar(onInfo: { showsInstructions = true }, onClose: onClose)
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(width: proxy.size.width, height: previewHeight)
                    .background(Color.black)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("待确认照片")
                    .accessibilityValue("完整原图，未裁剪")
                    .accessibilityIdentifier("cameraReviewPhoto")
                VStack(spacing: 8) {
                    Text(depthNotice).font(.caption2).foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center).lineLimit(3)
                        .padding(.horizontal, 18)
                    HStack {
                        Button(action: onRetake) {
                            Image(systemName: "xmark").font(.system(size: 23, weight: .light))
                                .foregroundStyle(.white).frame(width: 64, height: 64)
                                .background(Color(white: 0.19), in: Circle())
                        }
                        .accessibilityLabel("重拍照片")
                        .accessibilityIdentifier("cameraRetakePhoto")
                        Spacer(minLength: 24)
                        Button(action: onUse) {
                            Image(systemName: "checkmark").font(.system(size: 25, weight: .regular))
                                .foregroundStyle(.black).frame(width: 64, height: 64)
                                .background(.white, in: Circle())
                        }
                        .accessibilityLabel("使用这张照片")
                        .accessibilityIdentifier("cameraUsePhoto")
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, max(28, proxy.size.width * 0.15))
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(.white)
        .statusBarHidden(true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cameraReviewScreen")
        .sheet(isPresented: $showsInstructions) {
            CameraInstructions(depthNotice: depthNotice, reviewing: true)
        }
    }
}

private struct CameraTopBar: View {
    let onInfo: () -> Void
    var onClose: (() -> Void)? = nil

    var body: some View {
        HStack {
            Button(action: onInfo) {
                Image(systemName: "info.circle").font(.system(size: 18, weight: .regular))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("拍摄与深度说明")
            .accessibilityIdentifier("cameraCaptureInfo")
            Spacer()
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 18, weight: .regular))
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("关闭相机，不使用这张照片")
                .accessibilityIdentifier("cameraClose")
            }
        }
        .padding(.horizontal, 8).frame(height: CameraFraming.topBarHeight)
        .foregroundStyle(.white).background(.black).buttonStyle(.plain)
    }
}

private struct CameraCompositionGrid: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            // The reference uses a near-golden-section nine-cell composition grid,
            // not evidence about detected face coordinates.
            for fraction in [CGFloat(0.382), CGFloat(0.618)] {
                path.move(to: CGPoint(x: size.width * fraction, y: 0))
                path.addLine(to: CGPoint(x: size.width * fraction, y: size.height))
                path.move(to: CGPoint(x: 0, y: size.height * fraction))
                path.addLine(to: CGPoint(x: size.width, y: size.height * fraction))
            }
            context.stroke(path, with: .color(.white.opacity(0.25)), lineWidth: 0.6)
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

private struct CameraInstructions: View {
    @Environment(\.dismiss) private var dismiss
    let depthNotice: String
    let reviewing: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(reviewing ? "确认画面清晰、五官无遮挡，再继续检测。" : "均匀自然光 · 素颜优先 · 关闭美颜")
                        .font(.headline)
                    Text("请竖屏拍摄。自拍预览会镜像，保存照片不会镜像；构图线只作参考，不会裁剪照片。")
                    Text("实时定位只作拍摄参考，不录制视频，也不会因为定位暂时失败而限制手动拍照。")
                    Text(depthNotice)
                    Text("深度只用于本次本机分析；表面距离不是骨性或临床测量。不支持或深度证据不足时，继续二维照片分析。")
                        .foregroundStyle(.secondary)
                }.font(.body).padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("拍摄说明").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
        .tint(.white)
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
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
