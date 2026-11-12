import Foundation
import simd

/// Metric surface chords from real, same-photo absolute TrueDepth plus rectification.
/// Not a monocular model, not geodesic lengths, and never bone or clinical anthropometry.
enum DepthMeasurementService {
    struct SurfacePoint: Sendable {
        let x: Double
        let y: Double
        let z: Double
    }
    struct Measurement: Sendable {
        let id: String
        let title: String
        let start: NormalizedPoint
        let end: NormalizedPoint
        let millimeters: Double
    }

    /// Lift a point observed in the distorted, upright color photo. Depth is sampled there;
    /// only the camera ray is rectified. Resampling a rectified depth value at the old pixel
    /// would silently use the wrong surface, so that tempting shortcut is deliberately avoided.
    static func surfacePoint(snapshot: DepthSnapshot, point: NormalizedPoint) -> SurfacePoint? {
        guard snapshot.isUsable, point.x.isFinite, point.y.isFinite,
              (0...1).contains(point.x), (0...1).contains(point.y) else { return nil }
        return lift(snapshot: snapshot, point: point)
    }

    private static func lift(snapshot: DepthSnapshot, point: NormalizedPoint) -> SurfacePoint? {
        let x = min(snapshot.width - 1, Int(point.x * Double(snapshot.width)))
        let y = min(snapshot.height - 1, Int(point.y * Double(snapshot.height)))
        guard x >= 1, y >= 1, x + 1 < snapshot.width, y + 1 < snapshot.height else { return nil }
        var samples: [Double] = []
        for row in (y - 1)...(y + 1) { for column in (x - 1)...(x + 1) {
            let z = Double(snapshot.depthMeters[row * snapshot.width + column])
            if z.isFinite && (0.15...1.2).contains(z) { samples.append(z) }
        } }
        // Missing/edge/background mixtures do not get filled with a typical face depth.
        guard samples.count >= 7 else { return nil }
        samples.sort()
        let z = samples[samples.count / 2]
        let deviations = samples.map { abs($0 - z) }.sorted()
        guard deviations[deviations.count / 2] <= 0.004,
              let low = samples.first, let high = samples.last, high - low <= 0.025 else { return nil }
        let u = point.x * snapshot.referenceWidth, v = point.y * snapshot.referenceHeight
        guard let rectified = radialMap(x: u, y: v, snapshot: snapshot, table: snapshot.inverseLensDistortion),
              let roundTrip = radialMap(x: rectified.x, y: rectified.y, snapshot: snapshot, table: snapshot.lensDistortion),
              hypot(roundTrip.x - u, roundTrip.y - v) <= max(1, max(snapshot.referenceWidth, snapshot.referenceHeight) * 0.001) else { return nil }
        let a = snapshot.intrinsicMatrix.map(Double.init)
        let matrix = simd_double3x3(columns: (SIMD3(a[0], a[1], a[2]), SIMD3(a[3], a[4], a[5]), SIMD3(a[6], a[7], a[8])))
        guard abs(simd_determinant(matrix)) > 0.000001 else { return nil }
        let ray = simd_inverse(matrix) * SIMD3(rectified.x, rectified.y, 1)
        guard ray.x.isFinite, ray.y.isFinite, ray.z.isFinite, abs(ray.z) > 0.000001 else { return nil }
        let result = ray * (z / ray.z)
        return SurfacePoint(x: result.x, y: result.y, z: result.z)
    }

    /// Apple's radial-LUT reference convention: relative magnification, interpolate radius,
    /// output = center + (point-center)*(1+magnification). Zero LUT is identity, not collapse.
    static func radialMap(x: Double, y: Double, snapshot: DepthSnapshot, table: [Float]) -> (x: Double, y: Double)? {
        guard x.isFinite, y.isFinite, table.count >= 2 else { return nil }
        let dx = x - snapshot.distortionCenterX, dy = y - snapshot.distortionCenterY
        let maximumX = max(snapshot.distortionCenterX, snapshot.referenceWidth - snapshot.distortionCenterX)
        let maximumY = max(snapshot.distortionCenterY, snapshot.referenceHeight - snapshot.distortionCenterY)
        let maximumRadius = hypot(maximumX, maximumY)
        guard maximumRadius > 0 else { return nil }
        let position = min(1, hypot(dx, dy) / maximumRadius) * Double(table.count - 1)
        let left = min(table.count - 2, Int(position)), fraction = position - Double(left)
        let magnification = Double(table[left]) * (1 - fraction) + Double(table[left + 1]) * fraction
        guard magnification.isFinite, magnification > -1 else { return nil }
        return (snapshot.distortionCenterX + dx * (1 + magnification), snapshot.distortionCenterY + dy * (1 + magnification))
    }

    static func measurements(snapshot: DepthSnapshot, landmarks: [String: [NormalizedPoint]], imageWidth: Int, imageHeight: Int) -> [Measurement] {
        guard snapshot.isUsable, imageWidth > 0, imageHeight > 0,
              abs(Double(imageWidth) / Double(imageHeight) / (Double(snapshot.imageWidth) / Double(snapshot.imageHeight)) - 1) <= 0.015 else { return [] }
        func horizontal(_ key: String) -> (NormalizedPoint, NormalizedPoint)? {
            guard let p = landmarks[key], p.count >= 3,
                  p.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }),
                  let left = p.min(by: { $0.x < $1.x }), let right = p.max(by: { $0.x < $1.x }), right.x > left.x else { return nil }
            return (left, right)
        }
        var definitions: [(String, String, NormalizedPoint, NormalizedPoint)] = []
        for (key, title) in [("faceContour", "可见轮廓两侧表面弦距"), ("nose", "鼻部轮廓两侧表面弦距"), ("outerLips", "外唇两侧表面弦距")] {
            if let (left, right) = horizontal(key) { definitions.append((key, title, left, right)) }
        }
        if let lip = landmarks["outerLips"]?.max(by: { $0.y < $1.y }), let chin = landmarks["faceContour"]?.max(by: { $0.y < $1.y }),
           chin.y > lip.y, lip.x.isFinite, lip.y.isFinite, chin.x.isFinite, chin.y.isFinite,
           (0...1).contains(lip.x), (0...1).contains(lip.y), (0...1).contains(chin.x), (0...1).contains(chin.y) {
            definitions.append(("lip-to-chin", "下唇轮廓下界至颏底表面弦距", lip, chin))
        }
        return definitions.compactMap { id, title, start, end in
            guard let a = lift(snapshot: snapshot, point: start), let b = lift(snapshot: snapshot, point: end) else { return nil }
            let distance = sqrt(pow(a.x - b.x, 2) + pow(a.y - b.y, 2) + pow(a.z - b.z, 2)) * 1000
            guard distance.isFinite, distance >= 1, distance <= 350 else { return nil }
            return Measurement(id: "depth-surface-" + id, title: title, start: start, end: end, millimeters: distance)
        }
    }

    static func metrics(snapshot: DepthSnapshot, landmarks: [String: [NormalizedPoint]], imageWidth: Int, imageHeight: Int) -> [GeometryMetric] {
        measurements(snapshot: snapshot, landmarks: landmarks, imageWidth: imageWidth, imageHeight: imageHeight).map {
            GeometryMetric(id: $0.id, title: $0.title, value: $0.millimeters, unit: "mm",
                note: "同次TrueDepth绝对深度，经照片EXIF统一方向、相机径向畸变及内参校正后求两端3D直线距离×1000。3×3邻域≥7有效点，深度中位绝对偏差≤4mm、极差≤25mm；无效不补值。是可见表面弦距，不是沿皮肤曲线长度、骨性尺寸或临床测量。深度仅本次内存使用；复原旧照片不重建深度。")
        }
    }

    static func overlays(snapshot: DepthSnapshot, landmarks: [String: [NormalizedPoint]], imageWidth: Int, imageHeight: Int) -> [OverlayLayer] {
        let measurements = measurements(snapshot: snapshot, landmarks: landmarks, imageWidth: imageWidth, imageHeight: imageHeight)
        guard !measurements.isEmpty else { return [] }
        return [OverlayLayer(id: "geometry-depth-surface", title: "TrueDepth同拍表面测量端点", colorHex: "FFE45E", kind: .lines,
            paths: measurements.map { [$0.start, $0.end] },
            note: "连线只连接已取得稳定深度的本次实测特征端点；数值为3D表面弦距，不是骨性测量。原图显示仍为二维投影。",
            source: snapshot.source + "; captureID=" + snapshot.captureID + "; originalJPEG-SHA256=" + snapshot.originalJPEGSHA256)]
    }
}
