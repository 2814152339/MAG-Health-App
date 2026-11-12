import Foundation
import CoreGraphics

/// Presentation-only selection of one observed eye and its same-ID-side brow.
/// Does not relabel anatomical sides, synthesize landmarks, or modify report data.
enum ScanFocusPresentation {
    struct EyeFocus: Equatable {
        let eyeID: String
        let browID: String
        let landmarkIDs: [String]
        let region: CGRect

        /// Only the selected geometry producer's four exact IDs are eligible.
        /// Similar prefixes, other sides, and unrelated layers do not qualify.
        func allowsGeometryLayer(id: String) -> Bool {
            let brow = "geometry-brow-" + browID
            let eye = "geometry-eye-" + eyeID
            return id == brow || id == brow + "-points"
                || id == eye || id == eye + "-points"
        }
    }

    /// Both unique eye contours are required to know which is image-leftmost.
    /// Any invalid eye or tied min-X returns nil, rather than choosing the other
    /// eye by input order. The chosen side's unique valid brow is required; an
    /// unselected brow is irrelevant and may be absent. No cross-side fallback.
    static func eyeFocus(landmarks: [LandmarkPath]) -> EyeFocus? {
        guard let left = unique("leftEye", in: landmarks), validEye(left),
              let right = unique("rightEye", in: landmarks), validEye(right),
              let leftX = left.points.map(\.x).min(),
              let rightX = right.points.map(\.x).min(), leftX != rightX else { return nil }
        let eye: LandmarkPath = leftX < rightX ? left : right
        let browID = eye.id == "leftEye" ? "leftEyebrow" : "rightEyebrow"
        guard let brow = unique(browID, in: landmarks), validBrow(brow),
              let region = ReportPhotoTransform.region(points: eye.points + brow.points,
                  padding: CGSize(width: 0.13, height: 0.19),
                  minimum: CGSize(width: 0.56, height: 0.66)),
              region.minX.isFinite, region.minY.isFinite,
              region.width.isFinite, region.height.isFinite,
              region.minX >= 0, region.minY >= 0,
              region.maxX <= 1, region.maxY <= 1,
              region.width > 0, region.height > 0 else { return nil }
        return EyeFocus(eyeID: eye.id, browID: browID,
                        landmarkIDs: [eye.id, browID], region: region)
    }

    private static func unique(_ id: String, in paths: [LandmarkPath]) -> LandmarkPath? {
        let matches = paths.filter { $0.id == id }
        guard matches.count == 1 else { return nil }
        return matches.first
    }

    private static func valid(_ point: NormalizedPoint) -> Bool {
        point.x.isFinite && point.y.isFinite && (0...1).contains(point.x) && (0...1).contains(point.y)
    }

    private static func validBrow(_ path: LandmarkPath) -> Bool {
        path.points.allSatisfy(valid) && Set(path.points).count >= 2
    }

    private static func validEye(_ path: LandmarkPath) -> Bool {
        guard path.closed, path.points.allSatisfy(valid), Set(path.points).count >= 3 else { return false }
        var twiceArea = 0.0
        for index in path.points.indices {
            let a = path.points[index]
            let b = path.points[(index + 1) % path.points.count]
            twiceArea += a.x * b.y - b.x * a.y
        }
        return twiceArea.isFinite && abs(twiceArea) > 0
    }
}
