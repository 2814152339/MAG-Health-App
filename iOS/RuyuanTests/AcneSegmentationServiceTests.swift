import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import Vision
import XCTest
@testable import Ruyuan

/// Both the bundled actual CPU graph and the pure coordinate/statistics adapter are mandatory.
/// Synthetic arrays/fixture pixels assert format fidelity, never biological accuracy.
final class AcneSegmentationServiceTests: XCTestCase {
    private var landmarks: [String: [Ruyuan.NormalizedPoint]] {
        func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> [Ruyuan.NormalizedPoint] {
            [.init(x: x, y: y), .init(x: x + w, y: y), .init(x: x + w, y: y + h), .init(x: x, y: y + h)]
        }
        return ["leftEye": rect(0.25, 0.40, 0.14, 0.04), "rightEye": rect(0.61, 0.40, 0.14, 0.04),
                "leftEyebrow": rect(0.23, 0.35, 0.18, 0.02), "rightEyebrow": rect(0.59, 0.35, 0.18, 0.02),
                "outerLips": rect(0.39, 0.72, 0.22, 0.07), "nose": rect(0.43, 0.44, 0.14, 0.21)]
    }

    private func mask(width: Int = 100, height: Int = 100,
                      category: (Int, Int) -> FaceSegmentationService.Category = { _, _ in .faceSkin },
                      confidenceAt: (Int, Int) -> Float = { _, _ in 1 }) throws -> FaceSegmentationService.Mask {
        var labels = [UInt8](repeating: 0, count: width * height)
        var confidence = (0..<6).map { _ in [Float](repeating: 0, count: width * height) }
        for y in 0..<height { for x in 0..<width {
            let i = y * width + x, c = category(x, y)
            labels[i] = c.rawValue; confidence[Int(c.rawValue)][i] = confidenceAt(x, y)
        } }
        return try .init(width: width, height: height, categories: labels, confidence: confidence)
    }

    private func image(width: Int = 256, height: Int = 256) throws -> CGImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) { pixels[i] = 182; pixels[i + 1] = 137; pixels[i + 2] = 111 }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func observation(_ result: (statistics: AcneSegmentationService.Statistics, overlay: OverlayLayer)) -> AcneSegmentationService.Observation {
        .init(state: .ready, nativeCropWidth: 256, nativeCropHeight: 256, elapsed: 0.01,
              statistics: result.statistics, overlay: result.overlay, source: AcneSegmentationService.source)
    }

    private func report() -> AnalysisReport {
        let skin = SkinDimension.allCases.map { dimension in
            SkinMetric(dimension: dimension, score: dimension == .smoothness ? 42 : nil, status: "existing",
                items: [SkinItem(id: "existing-fine-dot", title: "Existing heuristic", valueText: "unchanged", note: "test", overlayID: nil)], scoreSource: "photoHeuristic")
        }
        return AnalysisReport(id: "acne-test", createdAt: Date(), origin: .local, status: "test", imageFileName: "synthetic.jpg",
            imageWidth: 1024, imageHeight: 1280, geometry: [], skin: skin, landmarks: [], overlays: [], quality: [], modelVersion: "existing", summary: "test")
    }

    /// Missing resource/receipt, model loading or actual inference errors fail, never skip.
    func testBundledApprovedModelActuallyRunsOnCPUWithRealOutputContract() throws {
        _ = try XCTUnwrap(AcneSegmentationService.modelURL(), "Real compiled AcneSegmentation must be bundled")
        let receipt = try XCTUnwrap(AcneSegmentationService.manifestURL())
        XCTAssertNoThrow(try AcneSegmentationService.validateManifest(Data(contentsOf: receipt)))
        let result = try AcneSegmentationService.analyze(image: image(), faceBox: CGRect(x: 0, y: 0, width: 1, height: 1),
            landmarks: landmarks, segmentation: mask())
        XCTAssertEqual(result.state, .ready)
        let statistics = try XCTUnwrap(result.statistics)
        XCTAssertGreaterThan(statistics.validSkinPixels, 0)
        XCTAssertEqual(statistics.candidatePixels, 0, "Actual pinned uniform fixture is below threshold; this is not a skin assessment")
        XCTAssertEqual(statistics.connectedComponents, 0)
        XCTAssertEqual(statistics.coveragePercent, 0)
        XCTAssertEqual(result.overlay?.id, "model-acne-segmentation")
        XCTAssertTrue(try XCTUnwrap(result.overlay).paths.isEmpty)
    }

    func testActualCoreMLUniformRGBMatchesPinnedOriginalTorchProbabilityProbes() throws {
        struct Reference: Decodable {
            struct Input: Decodable { let width: Int; let height: Int; let colorRGB: [Int] }
            struct Probe: Decodable { let x: Int; let y: Int; let probability: Double }
            struct Count: Decodable { let threshold: Float; let candidatePixels: Int }
            let schema: Int; let revision: String; let sourceSHA256: String
            let input: Input; let probes: [Probe]; let thresholdCounts: [Count]
        }
        let referenceURL = try XCTUnwrap(Bundle.main.url(forResource: "AcneSegmentation-fixture-reference", withExtension: "json", subdirectory: "Models")
            ?? Bundle.main.url(forResource: "AcneSegmentation-fixture-reference", withExtension: "json"))
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: referenceURL))
        XCTAssertEqual(reference.schema, 1); XCTAssertEqual(reference.revision, AcneSegmentationService.revision)
        XCTAssertEqual(reference.sourceSHA256, AcneSegmentationService.weightSHA256)
        XCTAssertEqual(reference.input.width, 256); XCTAssertEqual(reference.input.height, 256)
        XCTAssertEqual(reference.input.colorRGB, [182, 137, 111]); XCTAssertEqual(reference.probes.count, 9)
        let configuration = MLModelConfiguration(); configuration.computeUnits = .cpuOnly
        let model = try MLModel(contentsOf: XCTUnwrap(AcneSegmentationService.modelURL()), configuration: configuration)
        let metadata = model.modelDescription.metadata[MLModelMetadataKey.creatorDefinedKey] as? [String: String] ?? [:]
        try AcneSegmentationService.validateMetadata(metadata)
        let constraint = try XCTUnwrap(model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint)
        let outputConstraint = try XCTUnwrap(model.modelDescription.outputDescriptionsByName["acneProbability"]?.multiArrayConstraint)
        let staticShape = outputConstraint.shape.map(\.intValue)
        let diagnostic = "Actual SDK input=\(constraint.pixelsWide)x\(constraint.pixelsHigh), pixelFormat=\(constraint.pixelFormatType); output dtype=\(outputConstraint.dataType.rawValue), declaredShape=\(staticShape)"
        XCTAssertNoThrow(try AcneSegmentationService.validateConstraints(pixelsWide: constraint.pixelsWide, pixelsHigh: constraint.pixelsHigh,
            pixelFormat: constraint.pixelFormatType, outputDataType: outputConstraint.dataType, declaredOutputShape: staticShape), diagnostic)
        // Exact uniform 256x256 sRGB uint8; no spatial resize difference or repeated normalization.
        let feature = try MLFeatureValue(cgImage: image(), constraint: constraint,
            options: [.cropAndScale: VNImageCropAndScaleOption.scaleFill.rawValue])
        let prediction = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": feature]))
        let output = try XCTUnwrap(prediction.featureValue(for: "acneProbability")?.multiArrayValue)
        let probabilities = try AcneSegmentationService.copyProbabilityMap(output, width: 256, height: 256)
        for probe in reference.probes {
            guard (0..<256).contains(probe.x), (0..<256).contains(probe.y), probe.probability.isFinite else { XCTFail("Invalid pinned probe"); continue }
            XCTAssertEqual(Double(probabilities[probe.y * 256 + probe.x]), probe.probability, accuracy: 0.0001,
                "Actual FP16-weight/FP32 CPU output differs from source Torch at \(probe.x),\(probe.y)")
        }
        XCTAssertEqual(reference.thresholdCounts.count, 2)
        for count in reference.thresholdCounts {
            XCTAssertEqual(probabilities.filter { $0 > count.threshold }.count, count.candidatePixels)
        }
    }

    func testCropUsesOriginalPixelsAndConvertsVisionOriginWithoutCropExpansion() throws {
        let plan = try XCTUnwrap(AcneSegmentationService.cropPlan(imageWidth: 1000, imageHeight: 2000,
            faceBox: CGRect(x: 0.2, y: 0.1, width: 0.6, height: 0.4)))
        XCTAssertEqual(plan.pixels, CGRect(x: 200, y: 1000, width: 600, height: 800))
        XCTAssertEqual(plan.normalized, CGRect(x: 0.2, y: 0.5, width: 0.6, height: 0.4))
        let inward = try XCTUnwrap(AcneSegmentationService.cropPlan(imageWidth: 1000, imageHeight: 1000,
            faceBox: CGRect(x: 0.2011, y: 0.2011, width: 0.5978, height: 0.5978)))
        XCTAssertEqual(inward.pixels, CGRect(x: 202, y: 202, width: 596, height: 596))
        XCTAssertNil(AcneSegmentationService.cropPlan(imageWidth: 1000, imageHeight: 2000,
            faceBox: CGRect(x: -0.1, y: 0, width: 0.8, height: 1)))
        XCTAssertNil(AcneSegmentationService.cropPlan(imageWidth: 1000, imageHeight: 2000,
            faceBox: CGRect(x: 0, y: 0, width: 1, height: CGFloat.nan)))
    }

    func testNativeResolutionAndRealSemanticMaskRequiredBeforeInference() throws {
        let low = try AcneSegmentationService.analyze(image: image(width: 510, height: 512),
            faceBox: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), landmarks: landmarks, segmentation: mask())
        XCTAssertEqual(low.state, .lowResolution)
        // Inward-only crop: floor(0.75 * 510) - ceil(0.25 * 510) = 382 - 128 = 254.
        XCTAssertEqual(low.nativeCropWidth, 254); XCTAssertEqual(low.nativeCropHeight, 256)
        XCTAssertNil(low.statistics); XCTAssertNil(low.overlay)
        let noMask = try AcneSegmentationService.analyze(image: image(), faceBox: CGRect(x: 0, y: 0, width: 1, height: 1),
            landmarks: landmarks, segmentation: nil)
        XCTAssertEqual(noMask.state, .missingSegmentation); XCTAssertNil(noMask.statistics)
        let noFeatures = try AcneSegmentationService.analyze(image: image(), faceBox: CGRect(x: 0, y: 0, width: 1, height: 1),
            landmarks: [:], segmentation: mask())
        XCTAssertEqual(noFeatures.state, .invalidInput); XCTAssertNil(noFeatures.statistics)
    }

    func testStaticShapeMayBeOmittedButInvalidPixelFormatDtypeOrShapeIsRejected() throws {
        for shape in [[], [1, 1, 256, 256]] {
            XCTAssertNoThrow(try AcneSegmentationService.validateConstraints(pixelsWide: 256, pixelsHigh: 256,
                pixelFormat: kCVPixelFormatType_32BGRA, outputDataType: .float32, declaredOutputShape: shape))
        }
        for shape in [[1, 256, 256], [256, 256], [1, 1, 128, 256], [1, 2, 256, 256], [2, 1, 256, 256]] {
            XCTAssertThrowsError(try AcneSegmentationService.validateConstraints(pixelsWide: 256, pixelsHigh: 256,
                pixelFormat: kCVPixelFormatType_32BGRA, outputDataType: .float32, declaredOutputShape: shape))
        }
        XCTAssertThrowsError(try AcneSegmentationService.validateConstraints(pixelsWide: 256, pixelsHigh: 256,
            pixelFormat: kCVPixelFormatType_32ARGB, outputDataType: .float32, declaredOutputShape: []))
        XCTAssertThrowsError(try AcneSegmentationService.validateConstraints(pixelsWide: 256, pixelsHigh: 256,
            pixelFormat: kCVPixelFormatType_32BGRA, outputDataType: .double, declaredOutputShape: []))
        XCTAssertThrowsError(try AcneSegmentationService.validateConstraints(pixelsWide: 255, pixelsHigh: 256,
            pixelFormat: kCVPixelFormatType_32BGRA, outputDataType: .float32, declaredOutputShape: []))
    }

    func testRuntimeCopyRequiresFiniteProbabilityNCHWAndRespectsPaddedRowStrides() throws {
        let pointer = UnsafeMutablePointer<Float>.allocate(capacity: 10)
        pointer.initialize(repeating: 0.99, count: 10)
        let padded = try MLMultiArray(dataPointer: UnsafeMutableRawPointer(pointer), shape: [1, 1, 2, 3], dataType: .float32,
            strides: [10, 10, 5, 1], deallocator: { raw in
                let values = raw.assumingMemoryBound(to: Float.self); values.deinitialize(count: 10); values.deallocate()
            })
        for y in 0..<2 { for x in 0..<3 { padded[[0, 0, NSNumber(value: y), NSNumber(value: x)]] = NSNumber(value: Float(y * 3 + x) / 10) } }
        XCTAssertEqual(try AcneSegmentationService.copyProbabilityMap(padded, width: 3, height: 2), [0, 0.1, 0.2, 0.3, 0.4, 0.5])
        let wrongShape = try MLMultiArray(shape: [1, 2, 3], dataType: .float32)
        XCTAssertThrowsError(try AcneSegmentationService.copyProbabilityMap(wrongShape, width: 3, height: 2))
        let wrongType = try MLMultiArray(shape: [1, 1, 2, 3], dataType: .double)
        XCTAssertThrowsError(try AcneSegmentationService.copyProbabilityMap(wrongType, width: 3, height: 2))
        for value in [Float.nan, .infinity, -0.01, 1.01] {
            padded[[0, 0, 0, 0]] = NSNumber(value: value)
            XCTAssertThrowsError(try AcneSegmentationService.copyProbabilityMap(padded, width: 3, height: 2))
        }
    }

    func testFullPixelStatisticsEightNeighborConnectivityAndExactMaskCoordinates() throws {
        let result = try AcneSegmentationService.summarize(probabilities: [0.9, 0, 0.3, 0, 0, 0, 0, 0.95], width: 4, height: 2,
            crop: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), landmarks: [:], segmentation: mask())
        XCTAssertEqual(result.statistics.validSkinPixels, 8); XCTAssertEqual(result.statistics.candidatePixels, 3)
        XCTAssertEqual(result.statistics.connectedComponents, 2, "Diagonal candidates are one 8-neighbor component, not two clinical lesions")
        XCTAssertEqual(result.statistics.coveragePercent, 37.5, accuracy: 1e-10)
        XCTAssertEqual(result.overlay.kind, .polygons); XCTAssertEqual(result.overlay.paths.count, 3)
        XCTAssertEqual(result.overlay.paths[0], [.init(x: 0.25, y: 0.25), .init(x: 0.375, y: 0.25),
            .init(x: 0.375, y: 0.5), .init(x: 0.25, y: 0.5)])
        XCTAssertEqual(result.overlay.paths[2], [.init(x: 0.625, y: 0.5), .init(x: 0.75, y: 0.5),
            .init(x: 0.75, y: 0.75), .init(x: 0.625, y: 0.75)])
        let exact = try AcneSegmentationService.summarize(probabilities: [0.2, Float(0.2).nextUp], width: 2, height: 1,
            crop: CGRect(x: 0, y: 0, width: 1, height: 1), landmarks: [:], segmentation: mask())
        XCTAssertEqual(exact.statistics.candidatePixels, 1, "Use strict author >0.20 in Float32")
    }

    func testVerticalRunMergingNeverFillsNegativeHolesOrGaps() throws {
        let probabilities: [Float] = [0, 1, 1, 1, 0, 0, 1, 1, 1, 0, 0, 1, 0, 1, 0]
        let result = try AcneSegmentationService.summarize(probabilities: probabilities, width: 5, height: 3,
            crop: CGRect(x: 0, y: 0, width: 1, height: 1), landmarks: [:], segmentation: mask())
        XCTAssertEqual(result.statistics.candidatePixels, 8); XCTAssertEqual(result.statistics.connectedComponents, 1)
        XCTAssertEqual(result.overlay.paths.count, 3, "Identical consecutive runs merge; the third row's hole must stay empty")
        for y in 0..<3 { for x in 0..<5 {
            let px = (Double(x) + 0.5) / 5, py = (Double(y) + 0.5) / 3
            let displayed = result.overlay.paths.contains { points in
                px > points[0].x && px < points[1].x && py > points[0].y && py < points[2].y
            }
            XCTAssertEqual(displayed, probabilities[y * 5 + x] > 0.2, "Mask changed at \(x),\(y)")
        } }
    }

    func testHairAccessoriesLowConfidenceEyesBrowsLipsAndNostrilsAreExcluded() throws {
        let width = 40, height = 40
        let semantic = try mask(width: width, height: height,
            category: { x, y in y < 3 ? .hair : (x < 3 ? .accessories : .faceSkin) },
            confidenceAt: { _, y in y == 3 ? 0.64 : 1 })
        let result = try AcneSegmentationService.summarize(probabilities: .init(repeating: 1, count: width * height), width: width, height: height,
            crop: CGRect(x: 0, y: 0, width: 1, height: 1), landmarks: landmarks, segmentation: semantic)
        var expected = 0
        for y in 0..<height { for x in 0..<width {
            let px = (Double(x) + 0.5) / Double(width), py = (Double(y) + 0.5) / Double(height)
            let accepted = semantic.isFaceSkin(x: px, y: py, landmarks: landmarks)
            if accepted { expected += 1 }
            let displayed = result.overlay.paths.contains { p in px > p[0].x && px < p[1].x && py > p[0].y && py < p[2].y }
            XCTAssertEqual(displayed, accepted, "Must preserve the actual semantic/feature exclusion at \(x),\(y)")
        } }
        XCTAssertEqual(result.statistics.validSkinPixels, expected); XCTAssertEqual(result.statistics.candidatePixels, expected)
        XCTAssertLessThan(expected, width * height)
        XCTAssertThrowsError(try AcneSegmentationService.summarize(probabilities: [1], width: 1, height: 1,
            crop: CGRect(x: 0, y: 0, width: 1, height: 1), landmarks: [:], segmentation: mask(category: { _, _ in .accessories })))
    }

    func testDisplayCapacityDoesNotReduceWholeGridCoverageOrComponents() throws {
        let width = 256, height = 256
        let values: [Float] = (0..<(width * height)).map { i in (i % width) % 3 == 0 && (i / width) % 3 == 0 ? 1 : 0 }
        let expected = values.filter { $0 > 0.2 }.count
        let result = try AcneSegmentationService.summarize(probabilities: values, width: width, height: height,
            crop: CGRect(x: 0, y: 0, width: 1, height: 1), landmarks: [:], segmentation: mask())
        XCTAssertEqual(result.statistics.validSkinPixels, 65_536)
        XCTAssertEqual(result.statistics.candidatePixels, expected); XCTAssertEqual(result.statistics.connectedComponents, expected)
        XCTAssertGreaterThan(expected, 300); XCTAssertEqual(result.overlay.paths.count, 300)
        XCTAssertEqual(result.overlay.paths.flatMap { $0 }.count, 1200)
        XCTAssertTrue(result.overlay.paths.flatMap { $0 }.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) })
        var original = report()
        original.overlays.append(.init(id: "near-full", title: "Synthetic capacity", colorHex: "FFFFFF", kind: .lines,
            paths: .init(repeating: [.init(x: 0.1, y: 0.2), .init(x: 0.8, y: 0.9)], count: 9500), note: "test", source: "test"))
        let complete = AcneSegmentationService.applying(observation(result), to: original)
        XCTAssertNoThrow(try ReportValidator.validate(complete))
        XCTAssertEqual(complete.overlays.flatMap(\.paths).count, 9800)
    }

    func testCombinedSemanticGeometry478PoreAndAcneFitsNearFullReportBudget() throws {
        // Explicit synthetic chin is required by the production hairline-calibration contract.
        // The fixture keeps hairline .20 < brow .36 < nose base .65 < chin .90.
        var landmarks = self.landmarks
        landmarks["faceContour"] = [.init(x: 0.12, y: 0.4), .init(x: 0.5, y: 0.9), .init(x: 0.88, y: 0.4)]
        let width = 640, height = 640, box = CGRect(x: 0.12, y: 0.08, width: 0.76, height: 0.84)
        let semantic = try mask(width: width, height: height, category: { x, y in
            y < 128 ? .hair : (x % 9 == 0 ? .accessories : .faceSkin)
        })
        let raster = try XCTUnwrap(LocalAnalyzer.makeRaster(image(width: width, height: height)))
        let appearance = AppearanceAnalyzer.analyze(raster: raster, landmarks: landmarks, faceBox: box, segmentation: semantic)
        let boundary = semantic.boundaryGeometry(landmarks: landmarks, faceBox: box)
        let densePoints = (0..<478).map { i in Ruyuan.NormalizedPoint(x: 0.1 + Double(i % 23) / 30, y: 0.1 + Double(i / 23) / 30) }
        let dense = try FaceLandmarkService.makeResult(points: densePoints, relativeZ: .init(repeating: 0, count: 478))
        var paths = landmarks.map { LandmarkPath(id: $0.key, points: $0.value, closed: false) } + dense.landmarks
        if let path = boundary.path { paths.append(path) }
        var overlays = appearance.overlays + semantic.overlays(landmarks: landmarks, faceBox: box)
            + FaceGeometryAnalyzer.overlays(landmarks: landmarks, width: width, height: height) + dense.overlays
        if let layer = boundary.overlay { overlays.append(layer) }
        let padding = max(0, 9_200 - paths.count - overlays.flatMap(\.paths).count)
        overlays.append(.init(id: "combined-capacity", title: "Synthetic existing capacity", colorHex: "FFFFFF", kind: .lines,
            paths: .init(repeating: [.init(x: 0.1, y: 0.2), .init(x: 0.8, y: 0.9)], count: padding), note: "test", source: "test"))
        let geometry = LocalAnalyzer.geometryMetrics(landmarks, width: width, height: height)
            + FaceGeometryAnalyzer.metrics(landmarks: landmarks, width: width, height: height) + boundary.metrics
        let original = AnalysisReport(id: "combined-model-capacity", createdAt: Date(), origin: .local, status: "test", imageFileName: "synthetic.jpg",
            imageWidth: width, imageHeight: height, geometry: geometry, skin: appearance.metrics, landmarks: paths, overlays: overlays,
            quality: [], modelVersion: dense.source, summary: "test")
        let mapWidth = 200, mapHeight = 200
        let values: [Float] = (0..<(mapWidth * mapHeight)).map { i in (i % mapWidth) % 3 == 0 && (i / mapWidth) % 3 == 0 ? 0.9 : 0 }
        let pore = try PoreNetService.summarize(probabilities: values, width: mapWidth, height: mapHeight,
            crop: CGRect(x: 0.12, y: 0.08, width: 0.76, height: 0.84), landmarks: landmarks, segmentation: semantic)
        let poreObservation = PoreNetService.Observation(state: .ready, nativeCropWidth: 512, nativeCropHeight: 640, elapsed: 0.01,
            statistics: pore.statistics, overlay: pore.overlay, source: PoreNetService.source)
        let acne = try AcneSegmentationService.summarize(probabilities: values, width: mapWidth, height: mapHeight,
            crop: CGRect(x: 0.12, y: 0.08, width: 0.76, height: 0.84), landmarks: landmarks, segmentation: semantic)
        let complete = AcneSegmentationService.applying(observation(acne), to: PoreNetService.applying(poreObservation, to: original))
        XCTAssertNoThrow(try ReportValidator.validate(complete))
        XCTAssertNoThrow(try FaceCalibration.applying(to: complete, hairlineY: 0.2, pupilDistanceMM: nil))
        XCTAssertLessThanOrEqual(complete.landmarks.count + complete.overlays.flatMap(\.paths).count, 10_000)
        XCTAssertLessThanOrEqual(complete.overlays.flatMap(\.paths).flatMap { $0 }.count + complete.landmarks.flatMap(\.points).count, 100_000)
        XCTAssertEqual(complete.overlays.filter { $0.id == "model-pore-net" }.count, 1)
        XCTAssertEqual(complete.overlays.filter { $0.id == "model-acne-segmentation" }.count, 1)
    }

    func testInvalidOutputsAndAbstentionsNeverBecomeNumericalResults() throws {
        for values in [[Float.nan], [.infinity], [-0.01], [1.01], []] {
            XCTAssertThrowsError(try AcneSegmentationService.summarize(probabilities: values, width: 1, height: 1,
                crop: CGRect(x: 0, y: 0, width: 1, height: 1), landmarks: [:], segmentation: mask()))
        }
        for state in [AcneSegmentationService.State.notBundled, .lowResolution, .missingSegmentation, .inferenceFailed, .invalidModel] {
            let unavailable = AcneSegmentationService.Observation(state: state, nativeCropWidth: 256, nativeCropHeight: 256,
                elapsed: 0, statistics: nil, overlay: nil, source: AcneSegmentationService.source)
            let result = AcneSegmentationService.applying(unavailable, to: report())
            let item = try XCTUnwrap(result.skin.first { $0.dimension == .smoothness }?.items.first { $0.id == "trained-acne-segmentation" })
            XCTAssertFalse(item.valueText.contains("0.00%")); XCTAssertNil(item.overlayID)
            XCTAssertFalse(try XCTUnwrap(result.quality.first { $0.id == "trainedAcneSegmentation" }).passed)
            XCTAssertTrue(result.overlays.isEmpty)
        }
    }

    func testApplicationPreservesExistingScoresAndHeuristicAndClearsStaleOwnClaims() throws {
        let result = try AcneSegmentationService.summarize(probabilities: [0.3, 0, 0, 0], width: 2, height: 2,
            crop: CGRect(x: 0, y: 0, width: 1, height: 1), landmarks: [:], segmentation: mask())
        let once = AcneSegmentationService.applying(observation(result), to: report())
        let twice = AcneSegmentationService.applying(observation(result), to: once)
        let skin = try XCTUnwrap(twice.skin.first { $0.dimension == .smoothness })
        XCTAssertEqual(skin.score, 42); XCTAssertEqual(skin.scoreSource, "photoHeuristic"); XCTAssertEqual(skin.status, "existing")
        XCTAssertEqual(skin.items.first { $0.id == "existing-fine-dot" }?.valueText, "unchanged")
        XCTAssertEqual(skin.items.filter { $0.id == "trained-acne-segmentation" }.count, 1)
        XCTAssertEqual(twice.overlays.filter { $0.id == "model-acne-segmentation" }.count, 1)
        XCTAssertEqual(twice.modelVersion, once.modelVersion); XCTAssertEqual(twice.summary, once.summary)
        XCTAssertNoThrow(try ReportValidator.validate(twice))
        let unavailable = AcneSegmentationService.Observation(state: .inferenceFailed, nativeCropWidth: 256, nativeCropHeight: 256,
            elapsed: 0, statistics: nil, overlay: nil, source: AcneSegmentationService.source)
        let cleared = AcneSegmentationService.applying(unavailable, to: twice)
        XCTAssertEqual(cleared.modelVersion, "existing"); XCTAssertEqual(cleared.summary, "test")
        XCTAssertTrue(cleared.overlays.isEmpty)
        XCTAssertEqual(cleared.skin.first { $0.dimension == .smoothness }?.score, 42)
    }

    func testAlreadyCancelledTaskThrowsInsteadOfPublishingResults() async throws {
        let semantic = try mask()
        let task = Task {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            return try AcneSegmentationService.summarize(probabilities: [1], width: 1, height: 1,
                crop: CGRect(x: 0, y: 0, width: 1, height: 1), landmarks: [:], segmentation: semantic)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled work must not return observations") }
        catch is CancellationError {} catch { XCTFail("Wrong cancellation error: \(error)") }
    }

    private func metadata() -> [String: String] {
        ["ruyuan.repository": "RihemXX/Acnes", "ruyuan.revision": AcneSegmentationService.revision,
         "ruyuan.source_sha256": AcneSegmentationService.weightSHA256, "ruyuan.compute_precision": AcneSegmentationService.computePrecision,
         "ruyuan.threshold": "0.2", "ruyuan.normalization": "{\"mean\":[0.485,0.456,0.406],\"std\":[0.229,0.224,0.225]}"]
    }

    func testSourcePrecisionAndSingleNormalizationMetadataAreStrict() throws {
        XCTAssertNoThrow(try AcneSegmentationService.validateMetadata(metadata()))
        for (key, value) in [("ruyuan.repository", "other"), ("ruyuan.revision", "other"), ("ruyuan.source_sha256", "other"),
                             ("ruyuan.compute_precision", "float32"), ("ruyuan.threshold", "0.5"),
                             ("ruyuan.normalization", "{\"mean\":[0,0,0],\"std\":[1,1,1]}")] {
            var wrong = metadata(); wrong[key] = value
            XCTAssertThrowsError(try AcneSegmentationService.validateMetadata(wrong))
        }
    }

    /// Entirely synthetic receipt for validator negative tests, NOT an actual model pin.
    private let syntheticPin = AcneSegmentationService.ArtifactPin(sha256: String(repeating: "a", count: 64), bytes: 12345)
    private func receipt() -> [String: Any] {
        let shape = [1, 1, 256, 256]
        let sampleNames = ["author_public_example", "uniform_skin_rgb", "uniform_dark_rgb", "uniform_light_rgb", "seeded_rgb_noise"]
        let samples: [[String: Any]] = sampleNames.map { name in
            ["name": name, "shape": shape, "maxAbsoluteProbabilityError": 0.0001, "meanAbsoluteProbabilityError": 0.00001,
             "thresholds": [["threshold": 0.2, "maskDisagreementFraction": 0.0], ["threshold": 0.5, "maskDisagreementFraction": 0.0]]]
        }
        return ["schema": 1, "id": "acne_segmentation", "state": "converted_and_coreml_cpu_verified", "computePrecision": AcneSegmentationService.computePrecision,
            "modelType": "neuralNetwork", "threshold": 0.2,
            "source": ["repository": "RihemXX/Acnes", "revision": AcneSegmentationService.revision, "license": "Apache-2.0",
                "files": [["path": "Acnes_model.pth", "bytes": 97_920_000, "sha256": AcneSegmentationService.weightSHA256]]],
            "resource": ["fileName": "AcneSegmentation.mlmodel", "bytes": syntheticPin.bytes, "sha256": syntheticPin.sha256,
                "revision": AcneSegmentationService.revision, "computePrecision": AcneSegmentationService.computePrecision, "threshold": 0.2,
                "inputName": "image", "outputName": "acneProbability", "outputShape": shape],
            "input": ["name": "image", "width": 256, "height": 256, "colorLayout": "RGB", "scale": 1.0 / 255.0, "bias": [0, 0, 0],
                "embeddedNormalization": ["mean": [0.485, 0.456, 0.406], "std": [0.229, 0.224, 0.225]]],
            "output": ["name": "acneProbability", "dtype": "float32", "shape": shape], "validation": ["samples": samples]]
    }

    private func validate(_ value: [String: Any], pin: AcneSegmentationService.ArtifactPin? = nil) throws {
        try AcneSegmentationService.validateManifest(JSONSerialization.data(withJSONObject: value), approvedArtifact: pin ?? syntheticPin)
    }

    func testManifestRequiresReviewedPinAndActualCpuParityNotMerelyPytorchReceipt() throws {
        XCTAssertNoThrow(try validate(receipt()))
        let validData = try JSONSerialization.data(withJSONObject: receipt())
        XCTAssertThrowsError(try AcneSegmentationService.validateManifest(validData, approvedArtifact: nil), "No approved conversion is not a model")
        for (key, value) in [("state", "torch_preflight_only"), ("computePrecision", "float32"), ("id", "other"), ("modelType", "mlProgram")] {
            var wrong = receipt(); wrong[key] = value
            XCTAssertThrowsError(try validate(wrong))
        }
        var wrongPin = receipt(); var resource = try XCTUnwrap(wrongPin["resource"] as? [String: Any])
        resource["sha256"] = String(repeating: "b", count: 64); wrongPin["resource"] = resource
        XCTAssertThrowsError(try validate(wrongPin))
        var badScale = receipt(); var input = try XCTUnwrap(badScale["input"] as? [String: Any])
        input["scale"] = 1; badScale["input"] = input
        XCTAssertThrowsError(try validate(badScale))
        var badGate = receipt(); var validation = try XCTUnwrap(badGate["validation"] as? [String: Any])
        var samples = try XCTUnwrap(validation["samples"] as? [[String: Any]])
        samples[0]["maxAbsoluteProbabilityError"] = 0.0011; validation["samples"] = samples; badGate["validation"] = validation
        XCTAssertThrowsError(try validate(badGate))
    }
}
