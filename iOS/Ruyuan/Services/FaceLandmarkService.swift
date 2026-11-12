import Foundation
import UIKit
import CryptoKit
import MediaPipeTasksVision

/// Independent pretrained 478-point surface landmarks. Vision's existing canonical paths retain
/// their original semantics; no approximate index mapping silently replaces them. Inference is
/// local and per call, with no image retention, upload, blendshape or metric-depth claim.
enum FaceLandmarkService {
    static let modelName = "face_landmarker"
    static let modelSHA256 = "64184e229b263107bc2b804c6625db1341ff2bb731874b0bcc2fe6544e0bc9ff"
    static let version = "Google-FaceLandmarker478-float16-v1"
    static let source = version + "; SHA256 " + modelSHA256 + "; MediaPipe Tasks 1.2.2 CPU; Apache-2.0"

    enum Failure: Error, LocalizedError, Equatable {
        case missingModel, invalidModel, invalidImage, noFace, multipleFaces, invalidOutput, invalidTopology
        var errorDescription: String? {
            switch self {
            case .missingModel: return "本机478点模型缺失；本次没有生成密集面部点。"
            case .invalidModel: return "本机478点模型校验失败；未使用该模型输出。"
            case .invalidImage: return "478点输入图像无效；未生成密集面部点。"
            case .noFace: return "478点模型未找到可靠人脸；本次保留独立的Vision结果。"
            case .multipleFaces: return "478点模型发现多人；未选择其中一人生成密集点。"
            case .invalidOutput: return "478点模型输出不完整或越界；未补点或伪造坐标。"
            case .invalidTopology: return "面部模型连接索引校验失败；未生成推测轮廓。"
            }
        }
    }

    struct Result: Sendable {
        let points: [NormalizedPoint]
        /// Raw model-relative Z, scaled like normalized X. NOT meters and never a millimeter input.
        let relativeZ: [Double]
        let landmarks: [LandmarkPath]
        let overlays: [OverlayLayer]
        let source: String
    }

    struct Edge: Hashable, Sendable {
        let start: Int
        let end: Int
        init(_ a: Int, _ b: Int) { start = min(a, b); end = max(a, b) }
    }

    struct IndexPath: Sendable {
        let indices: [Int]
        let closed: Bool
    }

    static func modelURL(bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: modelName, withExtension: "bin", subdirectory: "Models")
            ?? bundle.url(forResource: modelName, withExtension: "bin")
    }

    /// Input must be the same upright, uncropped CGImage used by the report. Only an isotropic
    /// resolution reduction is performed; normalized points remain in the full-image frame.
    static func detect(image: CGImage, modelURL suppliedURL: URL? = nil) throws -> Result {
        try Task.checkCancellation()
        guard let url = suppliedURL ?? modelURL() else { throw Failure.missingModel }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count == 3_758_596,
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == modelSHA256 else { throw Failure.invalidModel }
        guard let raster = LocalAnalyzer.makeRaster(image), raster.width > 0, raster.height > 0,
              let provider = CGDataProvider(data: Data(raster.pixels) as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let rgba = CGImage(width: raster.width, height: raster.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                 bytesPerRow: raster.width * 4, space: colorSpace,
                                 bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                                 provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw Failure.invalidImage }
        let options = FaceLandmarkerOptions()
        options.baseOptions.modelAssetPath = url.path
        options.runningMode = .image
        options.numFaces = 2 // Do not silently choose one person from a group photo.
        options.minFaceDetectionConfidence = 0.6
        options.minFacePresenceConfidence = 0.6
        options.outputFaceBlendshapes = false
        options.outputFacialTransformationMatrixes = false
        let task = try FaceLandmarker(options: options)
        let result = try task.detect(image: MPImage(uiImage: UIImage(cgImage: rgba, scale: 1, orientation: .up)))
        try Task.checkCancellation()
        guard !result.faceLandmarks.isEmpty else { throw Failure.noFace }
        guard result.faceLandmarks.count == 1 else { throw Failure.multipleFaces }
        let face = result.faceLandmarks[0]
        // Copy every native result before releasing the per-call task and its intermediate buffers.
        return try makeResult(points: face.map { NormalizedPoint(x: Double($0.x), y: Double($0.y)) },
                              relativeZ: face.map { Double($0.z) })
    }

    /// SDK connection arrays are the official index authority, not manually remembered indices.
    /// This pure-output adapter is also exercised with a full 478-point synthetic fixture.
    static func makeResult(points: [NormalizedPoint], relativeZ: [Double]) throws -> Result {
        guard points.count == 478, relativeZ.count == 478,
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }),
              relativeZ.allSatisfy(\.isFinite) else { throw Failure.invalidOutput }
        func edges(_ input: [Connection]) -> [Edge] { input.map { Edge(Int($0.start), Int($0.end)) } }
        let definitions: [(String, [Edge])] = [
            ("mp-faceOval", edges(FaceLandmarker.faceOvalConnections())),
            ("mp-leftEye", edges(FaceLandmarker.leftEyeConnections())),
            ("mp-rightEye", edges(FaceLandmarker.rightEyeConnections())),
            ("mp-leftEyebrow", edges(FaceLandmarker.leftEyebrowConnections())),
            ("mp-rightEyebrow", edges(FaceLandmarker.rightEyebrowConnections())),
            ("mp-leftIris", edges(FaceLandmarker.leftIrisConnections())),
            ("mp-rightIris", edges(FaceLandmarker.rightIrisConnections()))
        ]
        var landmarks = [LandmarkPath(id: "mp-faceMesh478", points: points, closed: false)]
        for (id, connections) in definitions {
            let components = try orderedPaths(edges: connections, pointCount: points.count)
            for (index, component) in components.enumerated() {
                let suffix = components.count == 1 ? "" : "-\(index)"
                landmarks.append(LandmarkPath(id: id + suffix, points: component.indices.map { points[$0] }, closed: component.closed))
            }
        }
        let lips = try orderedPaths(edges: edges(FaceLandmarker.lipsConnections()), pointCount: points.count)
        guard lips.count == 2, lips.allSatisfy(\.closed) else { throw Failure.invalidTopology }
        let sortedLips = lips.sorted { area($0.indices.map { points[$0] }) > area($1.indices.map { points[$0] }) }
        for (id, component) in zip(["mp-outerLips", "mp-innerLips"], sortedLips) {
            landmarks.append(LandmarkPath(id: id, points: component.indices.map { points[$0] }, closed: true))
        }
        let contourEdges = Array(Set(edges(FaceLandmarker.contoursConnections())
            + edges(FaceLandmarker.leftIrisConnections()) + edges(FaceLandmarker.rightIrisConnections())))
            .sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        guard contourEdges.allSatisfy({ $0.start >= 0 && $0.end < points.count && $0.start != $0.end }) else { throw Failure.invalidTopology }
        let note = "本照片真实478个模型表面点；坐标为原照左上原点归一化位置。连接取自Google SDK官方眼、眉、唇、虹膜及脸缘索引，不替换Vision的几何定义。Z仅模型相对值，不是实测深度、骨骼或毫米。虹膜环不等于瞳孔中心。"
        let overlays = [
            OverlayLayer(id: "geometry-mp-dense-points", title: "本机模型478个面部点", colorHex: "FFE45E", kind: .points,
                         paths: [points], note: note, source: source),
            OverlayLayer(id: "geometry-mp-contours", title: "本机模型五官与轮廓连接", colorHex: "9183EE", kind: .lines,
                         paths: contourEdges.map { [points[$0.start], points[$0.end]] }, note: note, source: source)
        ]
        let allPaths = landmarks.map(\.points) + overlays.flatMap(\.paths)
        guard overlays.count <= 3, allPaths.count <= 500, allPaths.reduce(0, { $0 + $1.count }) <= 5_000 else { throw Failure.invalidOutput }
        return Result(points: points, relativeZ: relativeZ, landmarks: landmarks, overlays: overlays, source: source)
    }

    /// Reconstruct connected chains/rings by graph adjacency, irrespective of input edge direction
    /// or order. Never sort anatomical points by angle or infer missing edges.
    static func orderedPaths(edges: [Edge], pointCount: Int) throws -> [IndexPath] {
        guard !edges.isEmpty, pointCount > 0, edges.allSatisfy({ $0.start >= 0 && $0.end < pointCount && $0.start != $0.end }) else { throw Failure.invalidTopology }
        var adjacency: [Int: Set<Int>] = [:]
        for edge in Set(edges) {
            adjacency[edge.start, default: []].insert(edge.end)
            adjacency[edge.end, default: []].insert(edge.start)
        }
        guard adjacency.values.allSatisfy({ (1...2).contains($0.count) }) else { throw Failure.invalidTopology }
        var unvisited = Set(adjacency.keys), paths: [IndexPath] = []
        while let seed = unvisited.min() {
            var component: Set<Int> = [seed], stack = [seed]
            while let next = stack.popLast() {
                for neighbor in adjacency[next, default: []] where component.insert(neighbor).inserted { stack.append(neighbor) }
            }
            let ends = component.filter { adjacency[$0]?.count == 1 }.sorted()
            guard ends.count == 0 || ends.count == 2 else { throw Failure.invalidTopology }
            let closed = ends.isEmpty, first = ends.first ?? seed
            var ordered = [first], previous: Int?, current = first
            while let next = adjacency[current, default: []].filter({ $0 != previous }).sorted().first {
                if next == first { break }
                guard ordered.count < component.count else { throw Failure.invalidTopology }
                ordered.append(next); previous = current; current = next
            }
            guard ordered.count == component.count else { throw Failure.invalidTopology }
            paths.append(IndexPath(indices: ordered, closed: closed))
            unvisited.subtract(component)
        }
        return paths
    }

    private static func area(_ points: [NormalizedPoint]) -> Double {
        guard points.count > 2 else { return 0 }
        return abs(points.indices.reduce(0) { sum, i in
            let next = points[(i + 1) % points.count]
            return sum + points[i].x * next.y - next.x * points[i].y
        }) / 2
    }
}
