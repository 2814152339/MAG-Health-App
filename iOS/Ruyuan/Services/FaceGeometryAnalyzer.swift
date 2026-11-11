import Foundation

/// Deterministic, pixel-aspect-correct geometry derived only from observed Vision paths.
/// These are explicitly defined 2D contour measurements, not calibrated anatomy or beauty scores.
enum FaceGeometryAnalyzer {
    static func metrics(landmarks: [String: [NormalizedPoint]], width: Int, height: Int) -> [GeometryMetric] {
        let data = Geometry(landmarks, width: width, height: height)
        var result: [GeometryMetric] = []
        func add(_ id: String, _ title: String, _ value: Double?, _ note: String, unit: String = "") {
            result.append(GeometryMetric(id: "v2-" + id, title: title,
                value: value.flatMap { $0.isFinite ? $0 : nil }, unit: unit,
                note: "二维几何规则 v2；" + note + (value == nil ? "可用点位不足或几何退化，未计算。" : "不代表审美评分或真实毫米。")))
        }
        let contourNote = "faceContour 可见轮廓的横向/纵向包络，不含发际线或完整额部；"
        let contourAspect = ratio(data.contourHeight, data.contourWidth)
        let trend = contourAspect.map { $0 >= 1 ? "纵向跨度不少于横向跨度" : "横向跨度大于纵向跨度" } ?? "未确定"
        add("contour-aspect", "二维可见轮廓趋势", contourAspect,
            contourNote + "纵跨度/横跨度；仅描述“\(trend)”，不是脸型或长脸/圆脸分类；")
        for side in ["left", "right"] {
            let jaw = side == "left" ? data.leftJaw : data.rightJaw
            add("jaw-\(side)-angle", "图像\(side == "left" ? "左" : "右")侧二维下颌轮廓角", jaw?.angle,
                "从该侧横向极点至颏底的连续轮廓，取偏离端点连线最远的实测点为折点，再求两邻边夹角；直线不构成折角；不是骨性下颌角；", unit: "°")
        }
        let chinNote = "颏区上界定义为 outerLips 最低点的水平线，下界为 faceContour 颏底；宽在该区垂直中点与轮廓交点间计算；非解剖组织测量；"
        add("chin-height-face-width", "下唇下界至颏底高 / 轮廓横宽", ratio(data.chin?.height, data.contourWidth), chinNote)
        add("chin-width-face-width", "颏区中部宽 / 轮廓横宽", ratio(data.chin?.width, data.contourWidth), chinNote)
        add("chin-height-width", "二维颏区高宽比", ratio(data.chin?.height, data.chin?.width), chinNote)
        let triangleNote = "本模块将“黄金三角”明确定义为两眼轮廓点均值与外唇轮廓点均值三点的二维三角形；不预设黄金标准或优劣阈值；"
        add("triangle-mouth-angle", "黄金三角 · 唇中心顶角", data.triangle?.mouthAngle, triangleNote, unit: "°")
        add("triangle-left-eye-angle", "黄金三角 · Vision 左眼中心角", data.triangle?.leftAngle, triangleNote, unit: "°")
        add("triangle-right-eye-angle", "黄金三角 · Vision 右眼中心角", data.triangle?.rightAngle, triangleNote, unit: "°")
        let fiveNote = "按图像左右排列双眼；五段为左轮廓留白、左眼、眼间、右眼、右轮廓留白的水平像素跨度，分别除以平均眼宽；轮廓边界不是鬓角，数值不与审美标准比较；"
        let fiveTitles = ["图像左留白", "图像左眼宽", "眼间距", "图像右眼宽", "图像右留白"]
        let fiveIDs = ["left-margin", "left-eye", "gap", "right-eye", "right-margin"]
        for index in 0..<fiveTitles.count {
            add("five-" + fiveIDs[index], "五眼 · " + fiveTitles[index] + " / 平均眼宽", data.five[index]?.ratio, fiveNote)
        }
        for (key, title) in [("leftEyebrow", "Vision 左眉"), ("rightEyebrow", "Vision 右眉")] {
            let brow = data.brow(key)
            add("\(key)-width-face-width", title + "横宽 / 轮廓横宽", ratio(data.bounds(key)?.width, data.contourWidth), "眉区点集 X 跨度/轮廓 X 跨度；不是毛发粗细；")
            add("\(key)-arch-angle", title + "眉弓夹角", brow?.angle,
                "眉区横向两极点连弦，取偏离弦最远的内部实测点，求端点—该点—端点夹角；直眉为 180°；不是临床眉峰角；", unit: "°")
            add("\(key)-curvature", title + "弯曲度", brow?.curvature,
                "实测点至眉两端弦的最大垂直距离/弦长；直眉为 0；不测毛发粗细；")
        }
        for (key, title) in [("leftEye", "Vision 左眼"), ("rightEye", "Vision 右眼")] {
            let eye = data.bounds(key)
            let aspect = ratio(eye?.height, eye?.width)
            let eyeTrend = aspect.map { $0 <= 0.20 ? "轮廓相对窄" : $0 >= 0.35 ? "轮廓相对高" : "中间范围" } ?? "未确定"
            add("\(key)-aspect", title + "高宽趋势", aspect,
                "眼轮廓 Y 像素跨度/X 像素跨度；界面几何规则≤0.20为相对窄、≥0.35为相对高，其余中间范围，本次“\(eyeTrend)”；阈值未经临床标定，不是眼型诊断；")
            add("\(key)-inner-angle", title + "内侧轮廓夹角", data.innerAngle(key),
                "先按图像位置确定朝向面中线的 X 极点，再取闭合眼轮廓两相邻非重合点求角；是定位折线角，不冒充精细解剖内眦角；", unit: "°")
            add("\(key)-tilt", title + "横向端点倾角", data.tilt(key),
                "图像 X 两极点连线相对水平的 atan2 角，图像向右上为正；左右沿用 Vision 名称；", unit: "°")
        }
        add("nose-width-face-width", "鼻部轮廓横宽 / 轮廓横宽", ratio(data.bounds("nose")?.width, data.contourWidth),
            "Vision nose 点集 X 包络；不等同临床鼻翼宽；")
        add("nose-height-width", "鼻部轮廓高宽比", ratio(data.bounds("nose")?.height, data.bounds("nose")?.width),
            "Vision nose 点集 Y 像素跨度/X 像素跨度；不推断侧面鼻唇角；")
        add("lips-width-face-width", "外唇横宽 / 轮廓横宽", ratio(data.bounds("outerLips")?.width, data.contourWidth), "outerLips 横向包络/轮廓横向包络；")
        add("lips-height-width", "外唇轮廓高宽比", ratio(data.bounds("outerLips")?.height, data.bounds("outerLips")?.width), "outerLips 纵向包络/横向包络，张口时包含开口；")
        let lipNote = "在外唇横向包络中线，分别与闭合内外唇折线相交；上段=内上界−外上界，下段=外下界−内下界；仅二维轮廓代理，不是唇组织厚度；"
        add("upper-lip-width", "中线上唇轮廓厚 / 唇宽", ratio(data.lips?.upper, data.bounds("outerLips")?.width), lipNote)
        add("lower-lip-width", "中线下唇轮廓厚 / 唇宽", ratio(data.lips?.lower, data.bounds("outerLips")?.width), lipNote)
        add("upper-lower-lip", "中线上下唇轮廓厚度比", ratio(data.lips?.upper, data.lips?.lower), lipNote)
        return result
    }

    static func overlays(landmarks: [String: [NormalizedPoint]], width: Int, height: Int) -> [OverlayLayer] {
        let data = Geometry(landmarks, width: width, height: height)
        guard data.validSize else { return [] }
        var result: [OverlayLayer] = []
        func add(_ id: String, _ title: String, _ segments: [(Point, Point)], _ points: [Point], _ note: String) {
            let paths = segments.flatMap { arrow($0.0, $0.1, width: Double(width), height: Double(height)) }
            if !paths.isEmpty {
                result.append(OverlayLayer(id: "geometry-" + id, title: title, colorHex: "F1C55E", kind: .lines,
                    paths: paths, note: note, source: "Vision 实测点 + 确定性二维几何 v2"))
            }
            if !points.isEmpty {
                result.append(OverlayLayer(id: "geometry-" + id + "-points", title: title + " · 取点", colorHex: "9588E3", kind: .points,
                    paths: [points.map { $0.normalized(width: Double(width), height: Double(height)) }],
                    note: note, source: "Vision 实测点 + 确定性二维几何 v2"))
            }
        }
        for (side, jaw) in [("left", data.leftJaw), ("right", data.rightJaw)] {
            if let jaw { add("jaw-" + side, "二维下颌轮廓角", [(jaw.side, jaw.vertex), (jaw.vertex, jaw.chin)], [jaw.side, jaw.vertex, jaw.chin], "最大弦偏离点构成的二维轮廓折角，不是骨性下颌角。") }
        }
        if let chin = data.chin {
            add("chin", "二维颏区宽高", [(chin.left, chin.right), (chin.top, chin.bottom)], [chin.left, chin.right, chin.top, chin.bottom], "上界为下唇最低点水平线，宽取该区垂直中点；非组织厚度。")
        }
        if let t = data.triangle {
            add("golden-triangle", "双眼中心—唇中心三角形", [(t.left, t.right), (t.left, t.mouth), (t.right, t.mouth)], [t.left, t.right, t.mouth], "三点为各自轮廓点的均值；无黄金标准或审美评分。")
        }
        let five = data.five.compactMap { $0 }
        if !five.isEmpty { add("five-eyes", "五眼水平分段", five.map { ($0.start, $0.end) }, five.flatMap { [$0.start, $0.end] }, "图像左右顺序，轮廓留白不是鬓角测量。") }
        for key in ["leftEyebrow", "rightEyebrow"] {
            if let b = data.brow(key) {
                add("brow-" + key, "眉弓取点", [(b.left, b.vertex), (b.vertex, b.right), (b.left, b.right)], [b.left, b.vertex, b.right], "最大弦偏离/弦长定义弯曲度；不测眉毛粗细。")
            }
        }
        for key in ["leftEye", "rightEye"] {
            if let c = data.innerCorner(key) {
                add("eye-" + key, "眼内侧轮廓夹角", [(c.vertex, c.before), (c.vertex, c.after)], [c.before, c.vertex, c.after], "内侧 X 极点和相邻轮廓点；非精细解剖内眦角。")
            }
        }
        for key in ["nose", "outerLips"] {
            if let b = data.bounds(key), b.width > 0.5, b.height > 0.5 {
                let center = b.center
                let points = [Point(x: b.minX, y: center.y), Point(x: b.maxX, y: center.y), Point(x: center.x, y: b.minY), Point(x: center.x, y: b.maxY)]
                add(key == "nose" ? "nose-size" : "lips-size", key == "nose" ? "鼻部轮廓包络" : "外唇轮廓包络", [(points[0], points[1]), (points[2], points[3])], points, "由点集横纵包络构成的尺寸线，不是毫米或组织厚度。")
            }
        }
        if let l = data.lips {
            add("lip-bands", "二维上下唇轮廓分段", [(l.outerTop, l.innerTop), (l.innerBottom, l.outerBottom)], [l.outerTop, l.innerTop, l.innerBottom, l.outerBottom], "外唇包络中线与内外唇闭合折线相交。")
        }
        return result
    }

    private struct Point {
        var x: Double
        var y: Double
        func normalized(width: Double, height: Double) -> NormalizedPoint {
            NormalizedPoint(x: min(1, max(0, x / width)), y: min(1, max(0, y / height)))
        }
    }
    private struct Bounds {
        let minX: Double, maxX: Double, minY: Double, maxY: Double
        var width: Double { maxX - minX }
        var height: Double { maxY - minY }
        var center: Point { Point(x: (minX + maxX) / 2, y: (minY + maxY) / 2) }
    }
    private struct Jaw { let side: Point, vertex: Point, chin: Point; let angle: Double }
    private struct Chin {
        let left: Point, right: Point, top: Point, bottom: Point
        var width: Double { right.x - left.x }
        var height: Double { bottom.y - top.y }
    }
    private struct Triangle {
        let left: Point, right: Point, mouth: Point
        let leftAngle: Double, rightAngle: Double, mouthAngle: Double
    }
    private struct Brow { let left: Point, vertex: Point, right: Point; let angle: Double, curvature: Double }
    private struct Corner { let before: Point, vertex: Point, after: Point }
    private struct Segment { let start: Point, end: Point; let ratio: Double }
    private struct Lips {
        let outerTop: Point, innerTop: Point, innerBottom: Point, outerBottom: Point
        var upper: Double { innerTop.y - outerTop.y }
        var lower: Double { outerBottom.y - innerBottom.y }
    }
    private struct Geometry {
        let paths: [String: [Point]]
        let validSize: Bool
        init(_ source: [String: [NormalizedPoint]], width: Int, height: Int) {
            validSize = width > 0 && height > 0
            guard validSize else { paths = [:]; return }
            paths = source.reduce(into: [:]) { output, entry in
                guard entry.value.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }) else { return }
                var points: [Point] = []
                for p in entry.value {
                    let next = Point(x: p.x * Double(width), y: p.y * Double(height))
                    if let last = points.last, FaceGeometryAnalyzer.distance(last, next) < 0.000001 { continue }
                    points.append(next)
                }
                if points.count > 1, let first = points.first, let last = points.last, FaceGeometryAnalyzer.distance(first, last) < 0.000001 { points.removeLast() }
                output[entry.key] = points
            }
        }
        func bounds(_ key: String) -> Bounds? {
            let minimum = ["leftEye", "rightEye"].contains(key) ? 4 : ["faceContour", "nose", "outerLips", "innerLips"].contains(key) ? 3 : 2
            guard let p = paths[key], p.count >= minimum else { return nil }
            return Bounds(minX: p.map(\.x).min()!, maxX: p.map(\.x).max()!, minY: p.map(\.y).min()!, maxY: p.map(\.y).max()!)
        }
        var contourWidth: Double? { bounds("faceContour")?.width }
        var contourHeight: Double? { bounds("faceContour")?.height }
        func center(_ key: String) -> Point? {
            let minimum = ["leftEye", "rightEye"].contains(key) ? 4 : 3
            guard let p = paths[key], p.count >= minimum else { return nil }
            return Point(x: p.map(\.x).reduce(0, +) / Double(p.count), y: p.map(\.y).reduce(0, +) / Double(p.count))
        }
        private func extremum(_ p: [Point], left: Bool) -> Int? {
            p.indices.min { a, b in
                if p[a].x == p[b].x { return p[a].y < p[b].y }
                return left ? p[a].x < p[b].x : p[a].x > p[b].x
            }
        }
        private var chinIndex: Int? {
            guard let p = paths["faceContour"], p.count >= 3, let b = bounds("faceContour") else { return nil }
            return p.indices.min { a, c in
                if p[a].y == p[c].y { return abs(p[a].x - b.center.x) < abs(p[c].x - b.center.x) }
                return p[a].y > p[c].y
            }
        }
        var leftJaw: Jaw? { jaw(left: true) }
        var rightJaw: Jaw? { jaw(left: false) }
        private func jaw(left: Bool) -> Jaw? {
            guard let p = paths["faceContour"], p.count >= 3, let side = extremum(p, left: left), let chin = chinIndex,
                  abs(side - chin) >= 2 else { return nil }
            let a = p[side], c = p[chin]
            let interior = p[(min(side, chin) + 1)..<max(side, chin)]
            guard let vertex = interior.max(by: { FaceGeometryAnalyzer.deviation($0, a, c) < FaceGeometryAnalyzer.deviation($1, a, c) }),
                  FaceGeometryAnalyzer.deviation(vertex, a, c) > 0.5, let degrees = FaceGeometryAnalyzer.angle(a, vertex, c) else { return nil }
            return Jaw(side: a, vertex: vertex, chin: c, angle: degrees)
        }
        var chin: Chin? {
            guard let p = paths["faceContour"], let index = chinIndex, let lip = bounds("outerLips"),
                  p[index].y - lip.maxY > 0.5 else { return nil }
            let bottom = p[index], y = (lip.maxY + bottom.y) / 2
            let xs = FaceGeometryAnalyzer.intersections(p, level: y, vertical: false, closed: false)
            guard let left = xs.min(), let right = xs.max(), right - left > 0.5 else { return nil }
            return Chin(left: Point(x: left, y: y), right: Point(x: right, y: y), top: Point(x: bottom.x, y: lip.maxY), bottom: bottom)
        }
        var triangle: Triangle? {
            guard let left = center("leftEye"), let right = center("rightEye"), let mouth = center("outerLips"),
                  abs((right.x - left.x) * (mouth.y - left.y) - (right.y - left.y) * (mouth.x - left.x)) > 0.01,
                  let a = FaceGeometryAnalyzer.angle(right, left, mouth), let b = FaceGeometryAnalyzer.angle(left, right, mouth), let c = FaceGeometryAnalyzer.angle(left, mouth, right) else { return nil }
            return Triangle(left: left, right: right, mouth: mouth, leftAngle: a, rightAngle: b, mouthAngle: c)
        }
        var five: [Segment?] {
            guard let a = bounds("leftEye"), let b = bounds("rightEye"), a.width > 0.5, b.width > 0.5,
                  let ca = center("leftEye"), let cb = center("rightEye") else { return Array(repeating: nil, count: 5) }
            let left = a.center.x < b.center.x ? a : b, right = a.center.x < b.center.x ? b : a
            guard right.minX >= left.maxX else { return Array(repeating: nil, count: 5) }
            let mean = (left.width + right.width) / 2, y = (ca.y + cb.y) / 2
            func segment(_ start: Double?, _ end: Double?) -> Segment? {
                guard let start, let end, end >= start else { return nil }
                return Segment(start: Point(x: start, y: y), end: Point(x: end, y: y), ratio: (end - start) / mean)
            }
            let face = bounds("faceContour")
            return [segment(face?.minX, left.minX), segment(left.minX, left.maxX), segment(left.maxX, right.minX), segment(right.minX, right.maxX), segment(right.maxX, face?.maxX)]
        }
        func brow(_ key: String) -> Brow? {
            guard let p = paths[key], p.count >= 3, let li = extremum(p, left: true), let ri = extremum(p, left: false), li != ri else { return nil }
            let left = p[li], right = p[ri]
            guard FaceGeometryAnalyzer.distance(left, right) > 0.5,
                  let vertex = p.indices.filter({ $0 != li && $0 != ri }).map({ p[$0] }).max(by: { FaceGeometryAnalyzer.deviation($0, left, right) < FaceGeometryAnalyzer.deviation($1, left, right) }),
                  let degrees = FaceGeometryAnalyzer.angle(left, vertex, right) else { return nil }
            return Brow(left: left, vertex: vertex, right: right, angle: degrees, curvature: FaceGeometryAnalyzer.deviation(vertex, left, right) / FaceGeometryAnalyzer.distance(left, right))
        }
        func innerCorner(_ key: String) -> Corner? {
            let other = key == "leftEye" ? "rightEye" : "leftEye"
            guard let p = paths[key], p.count >= 4, let ownCenter = center(key), let otherCenter = center(other), ownCenter.x != otherCenter.x,
                  let index = extremum(p, left: ownCenter.x > otherCenter.x) else { return nil }
            return Corner(before: p[(index + p.count - 1) % p.count], vertex: p[index], after: p[(index + 1) % p.count])
        }
        func innerAngle(_ key: String) -> Double? {
            guard let c = innerCorner(key) else { return nil }
            return FaceGeometryAnalyzer.angle(c.before, c.vertex, c.after)
        }
        func tilt(_ key: String) -> Double? {
            guard let p = paths[key], p.count >= 4, let li = extremum(p, left: true), let ri = extremum(p, left: false), p[ri].x - p[li].x > 0.5 else { return nil }
            return atan2(p[li].y - p[ri].y, p[ri].x - p[li].x) * 180 / .pi
        }
        var lips: Lips? {
            guard let outer = paths["outerLips"], let inner = paths["innerLips"], outer.count >= 3, inner.count >= 3,
                  let b = bounds("outerLips"), b.width > 0.5 else { return nil }
            let x = b.center.x
            let outside = FaceGeometryAnalyzer.intersections(outer, level: x, vertical: true, closed: true)
            let inside = FaceGeometryAnalyzer.intersections(inner, level: x, vertical: true, closed: true)
            guard let ot = outside.min(), let ob = outside.max(), let it = inside.min(), let ib = inside.max(), it >= ot, ib <= ob else { return nil }
            return Lips(outerTop: Point(x: x, y: ot), innerTop: Point(x: x, y: it), innerBottom: Point(x: x, y: ib), outerBottom: Point(x: x, y: ob))
        }
    }
    private static func ratio(_ numerator: Double?, _ denominator: Double?) -> Double? {
        guard let a = numerator, let b = denominator, a.isFinite, b.isFinite, a >= 0, b > 0.5 else { return nil }
        return a / b
    }
    private static func distance(_ a: Point, _ b: Point) -> Double { hypot(a.x - b.x, a.y - b.y) }
    private static func angle(_ a: Point, _ b: Point, _ c: Point) -> Double? {
        let ab = distance(a, b), cb = distance(c, b)
        guard ab > 0.5, cb > 0.5 else { return nil }
        let cosine = ((a.x - b.x) * (c.x - b.x) + (a.y - b.y) * (c.y - b.y)) / (ab * cb)
        return acos(min(1, max(-1, cosine))) * 180 / .pi
    }
    private static func deviation(_ p: Point, _ a: Point, _ b: Point) -> Double {
        let length = distance(a, b)
        guard length > 0.5 else { return 0 }
        return abs((b.x - a.x) * (a.y - p.y) - (a.x - p.x) * (b.y - a.y)) / length
    }
    private static func intersections(_ points: [Point], level: Double, vertical: Bool, closed: Bool) -> [Double] {
        guard points.count >= 2 else { return [] }
        var values: [Double] = []
        let count = closed ? points.count : points.count - 1
        for index in 0..<count {
            let a = points[index], b = points[(index + 1) % points.count]
            let av = vertical ? a.x : a.y, bv = vertical ? b.x : b.y
            let ao = vertical ? a.y : a.x, bo = vertical ? b.y : b.x
            guard level >= min(av, bv), level <= max(av, bv) else { continue }
            if abs(bv - av) < 0.000001 {
                if abs(level - av) < 0.000001 { values.append(contentsOf: [ao, bo]) }
            } else { values.append(ao + (level - av) / (bv - av) * (bo - ao)) }
        }
        return values
    }
    private static func arrow(_ a: Point, _ b: Point, width: Double, height: Double) -> [[NormalizedPoint]] {
        let length = distance(a, b)
        guard length > 0.5 else { return [] }
        let ux = (b.x - a.x) / length, uy = (b.y - a.y) / length
        let head = min(9, length * 0.2), wing = head * 0.4
        let ah = [Point(x: a.x + ux * head - uy * wing, y: a.y + uy * head + ux * wing), a,
                  Point(x: a.x + ux * head + uy * wing, y: a.y + uy * head - ux * wing)]
        let bh = [Point(x: b.x - ux * head - uy * wing, y: b.y - uy * head + ux * wing), b,
                  Point(x: b.x - ux * head + uy * wing, y: b.y - uy * head - ux * wing)]
        return [[a, b], ah, bh].map { $0.map { $0.normalized(width: width, height: height) } }
    }
}
