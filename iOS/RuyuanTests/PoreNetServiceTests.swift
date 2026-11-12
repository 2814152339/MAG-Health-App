import CoreGraphics
import CoreML
import CoreVideo
import Foundation
import Vision
import XCTest
@testable import Ruyuan

final class PoreNetServiceTests: XCTestCase {
    private var landmarks: [String: [Ruyuan.NormalizedPoint]] {
        func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> [Ruyuan.NormalizedPoint] {
            [.init(x: x, y: y), .init(x: x + w, y: y), .init(x: x + w, y: y + h), .init(x: x, y: y + h)]
        }
        return ["leftEye": rect(0.25, 0.40, 0.14, 0.04), "rightEye": rect(0.61, 0.40, 0.14, 0.04),
                "leftEyebrow": rect(0.23, 0.35, 0.18, 0.02), "rightEyebrow": rect(0.59, 0.35, 0.18, 0.02),
                "outerLips": rect(0.39, 0.72, 0.22, 0.07), "nose": rect(0.43, 0.44, 0.14, 0.21),
                "faceContour": [.init(x: 0.12, y: 0.40), .init(x: 0.50, y: 0.90), .init(x: 0.88, y: 0.40)]]
    }

    private func mask(width: Int = 100, height: Int = 100,
                      category: (Int, Int) -> FaceSegmentationService.Category = { _, _ in .faceSkin }) throws -> FaceSegmentationService.Mask {
        var labels = [UInt8](repeating: 0, count: width * height)
        var confidence = (0..<6).map { _ in [Float](repeating: 0, count: width * height) }
        for y in 0..<height { for x in 0..<width {
            let i = y * width + x, c = category(x, y)
            labels[i] = c.rawValue; confidence[Int(c.rawValue)][i] = 1
        } }
        return try .init(width: width, height: height, categories: labels, confidence: confidence)
    }

    private func image(width: Int = 1024, height: Int = 1280) throws -> CGImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) { pixels[i] = 182; pixels[i + 1] = 137; pixels[i + 2] = 111 }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func observation(_ result: (statistics: PoreNetService.Statistics, overlay: OverlayLayer)) -> PoreNetService.Observation {
        .init(state: .ready, nativeCropWidth: 1024, nativeCropHeight: 1280, elapsed: 0.01,
              statistics: result.statistics, overlay: result.overlay, source: PoreNetService.source)
    }

    private func report() -> AnalysisReport {
        let skin = SkinDimension.allCases.map { dimension in
            SkinMetric(dimension: dimension, score: dimension == .smoothness ? 42 : nil, status: "existing",
                items: [SkinItem(id: "existing-fine-dot", title: "Existing heuristic", valueText: "unchanged", note: "test", overlayID: nil)], scoreSource: "photoHeuristic")
        }
        return AnalysisReport(id: "pore-test", createdAt: Date(), origin: .local, status: "test", imageFileName: "synthetic.jpg",
            imageWidth: 1024, imageHeight: 1280, geometry: [], skin: skin, landmarks: [], overlays: [], quality: [], modelVersion: "existing", summary: "test")
    }

    /// Missing/corrupt .mlmodelc/receipt or inference fails this test; no skip or synthetic model.
    /// Uniform pixels have no asserted biological meaning; only the real execution contract is tested.
    func testBundledConvertedModelActuallyRunsOnCPU() throws {
        _ = try XCTUnwrap(PoreNetService.modelURL(), "Production bundle must include real compiled PoreNet")
        let receipt = try XCTUnwrap(PoreNetService.manifestURL())
        XCTAssertNoThrow(try PoreNetService.validateManifest(Data(contentsOf: receipt)))
        let result = try PoreNetService.analyze(image: image(), faceBox: CGRect(x: 0, y: 0, width: 1, height: 1),
                                              landmarks: landmarks, segmentation: mask())
        XCTAssertEqual(result.state, .ready)
        let stats = try XCTUnwrap(result.statistics)
        XCTAssertGreaterThan(stats.validSkinPixels, 0)
        XCTAssertTrue((0...100).contains(stats.coveragePercent))
        XCTAssertEqual(result.overlay?.id, "model-pore-net")
        XCTAssertLessThanOrEqual(result.overlay?.paths.flatMap { $0 }.count ?? 0, 300)
    }

    func testActualCoreMLUniformRGBMatchesPinnedTorchProbabilityProbes() throws {
        struct Reference: Decodable {
            struct Input: Decodable { let width: Int; let height: Int; let colorRGB: [Int] }
            struct Probe: Decodable { let x: Int; let y: Int; let probability: Double }
            struct Count: Decodable { let threshold: Float; let candidatePixels: Int }
            let schema: Int; let revision: String; let sourceSHA256: String
            let input: Input; let probes: [Probe]; let thresholdCounts: [Count]
        }
        let referenceURL = try XCTUnwrap(Bundle.main.url(forResource: "PoreNet-fixture-reference", withExtension: "json", subdirectory: "Models")
            ?? Bundle.main.url(forResource: "PoreNet-fixture-reference", withExtension: "json"))
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: referenceURL))
        XCTAssertEqual(reference.schema, 1)
        XCTAssertEqual(reference.revision, PoreNetService.revision)
        XCTAssertEqual(reference.sourceSHA256, PoreNetService.weightSHA256)
        XCTAssertEqual(reference.input.width, 1024)
        XCTAssertEqual(reference.input.height, 1280)
        XCTAssertEqual(reference.input.colorRGB, [182, 137, 111])
        XCTAssertEqual(reference.probes.count, 9)
        let url = try XCTUnwrap(PoreNetService.modelURL())
        let configuration = MLModelConfiguration(); configuration.computeUnits = .cpuOnly
        let model = try MLModel(contentsOf: url, configuration: configuration)
        let metadata = model.modelDescription.metadata[MLModelMetadataKey.creatorDefinedKey] as? [String: String] ?? [:]
        try PoreNetService.validateMetadata(metadata)
        let constraint = try XCTUnwrap(model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint)
        let outputConstraint = try XCTUnwrap(model.modelDescription.outputDescriptionsByName["poreProbability"]?.multiArrayConstraint)
        let staticShape = outputConstraint.shape.map(\.intValue)
        let contractDiagnostic = "Actual SDK input=\(constraint.pixelsWide)x\(constraint.pixelsHigh), pixelFormat=\(constraint.pixelFormatType); output dtype=\(outputConstraint.dataType.rawValue), declaredShape=\(staticShape)"
        XCTAssertNoThrow(try PoreNetService.validateConstraints(pixelsWide: constraint.pixelsWide, pixelsHigh: constraint.pixelsHigh,
            pixelFormat: constraint.pixelFormatType, outputDataType: outputConstraint.dataType,
            declaredOutputShape: staticShape), contractDiagnostic)
        // Exact sRGB uint8 pixels, matching the source Torch fixture. No second normalization.
        let feature = try MLFeatureValue(cgImage: image(), constraint: constraint,
                                        options: [.cropAndScale: VNImageCropAndScaleOption.scaleFill.rawValue])
        let prediction = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": feature]))
        let output = try XCTUnwrap(prediction.featureValue(for: "poreProbability")?.multiArrayValue)
        let probabilities = try PoreNetService.copyProbabilityMap(output, width: 1024, height: 1280)
        for probe in reference.probes {
            guard (0..<1024).contains(probe.x), (0..<1280).contains(probe.y), probe.probability.isFinite else { XCTFail("Invalid pinned probe"); continue }
            XCTAssertEqual(Double(probabilities[probe.y * 1024 + probe.x]), probe.probability, accuracy: 0.0001,
                           "Actual Core ML differs from fixed original-weight Torch at x=\(probe.x),y=\(probe.y)")
        }
        XCTAssertEqual(reference.thresholdCounts.count, 2)
        for count in reference.thresholdCounts {
            XCTAssertEqual(probabilities.filter { $0 > count.threshold }.count, count.candidatePixels,
                           "Uniform fixture is well below both thresholds; no synthetic pore pixels expected")
        }
    }

    func testCropConvertsBottomLeftToTopLeftAndNeverUpscalesForEligibility() throws {
        let plan = try XCTUnwrap(PoreNetService.cropPlan(imageWidth: 1000, imageHeight: 2000,
            faceBox: CGRect(x: 0.2, y: 0.1, width: 0.6, height: 0.4)))
        XCTAssertEqual(plan.pixels.minX, 200)
        XCTAssertEqual(plan.pixels.minY, 1000)
        XCTAssertEqual(plan.pixels.width, 600)
        XCTAssertEqual(plan.pixels.height, 800)
        XCTAssertEqual(plan.normalized.minY, 0.5, accuracy: 1e-12)
        XCTAssertNil(PoreNetService.cropPlan(imageWidth: 1000, imageHeight: 2000, faceBox: CGRect(x: -0.1, y: 0, width: 0.8, height: 1)))
        let result = try PoreNetService.analyze(image: image(width: 1000, height: 1280),
            faceBox: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), landmarks: landmarks, segmentation: mask())
        XCTAssertEqual(result.state, .lowResolution)
        XCTAssertEqual(result.nativeCropWidth, 500)
        XCTAssertEqual(result.nativeCropHeight, 640)
        XCTAssertNil(result.statistics)
        XCTAssertNil(result.overlay)
        let missingMask = try PoreNetService.analyze(image: image(), faceBox: CGRect(x: 0, y: 0, width: 1, height: 1),
            landmarks: landmarks, segmentation: nil)
        XCTAssertEqual(missingMask.state, .missingSegmentation)
        XCTAssertNil(missingMask.statistics)
    }

    func testNCHWProbabilityCopyHandlesPaddingWithoutTranspose() throws {
        let array = try MLMultiArray(shape: [1, 1, 2, 3], dataType: .float32)
        for i in 0..<6 { array[i] = NSNumber(value: Float(i) / 10) }
        XCTAssertEqual(try PoreNetService.copyProbabilityMap(array, width: 3, height: 2), [0, 0.1, 0.2, 0.3, 0.4, 0.5])
        let pointer = UnsafeMutablePointer<Float>.allocate(capacity: 10)
        pointer.initialize(repeating: 0.99, count: 10)
        let padded = try MLMultiArray(dataPointer: UnsafeMutableRawPointer(pointer), shape: [1, 1, 2, 3], dataType: .float32,
                                     strides: [10, 10, 5, 1], deallocator: { raw in
            let floats = raw.assumingMemoryBound(to: Float.self); floats.deinitialize(count: 10); floats.deallocate()
        })
        for y in 0..<2 { for x in 0..<3 { padded[[0, 0, NSNumber(value: y), NSNumber(value: x)]] = NSNumber(value: Float(y * 3 + x) / 10) } }
        XCTAssertEqual(try PoreNetService.copyProbabilityMap(padded, width: 3, height: 2), [0, 0.1, 0.2, 0.3, 0.4, 0.5])
        array[0] = NSNumber(value: Float.nan)
        XCTAssertThrowsError(try PoreNetService.copyProbabilityMap(array, width: 3, height: 2))
        XCTAssertThrowsError(try PoreNetService.copyProbabilityMap(padded, width: 2, height: 3))
    }

    func testPinnedNeuralNetworkAllowsOmittedStaticShapeButRejectsInvalidDeclaredContract() throws {
        for shape in [[], [1, 1, 1280, 1024]] {
            XCTAssertNoThrow(try PoreNetService.validateConstraints(pixelsWide: 1024, pixelsHigh: 1280,
                pixelFormat: kCVPixelFormatType_32BGRA, outputDataType: .float32, declaredOutputShape: shape))
        }
        for shape in [[1, 1280, 1024], [1, 1, 1024, 1280], [2, 1, 1280, 1024], [1, 3, 1280, 1024], [0], [1280, 1024]] {
            XCTAssertThrowsError(try PoreNetService.validateConstraints(pixelsWide: 1024, pixelsHigh: 1280,
                pixelFormat: kCVPixelFormatType_32BGRA, outputDataType: .float32, declaredOutputShape: shape))
        }
        for dataType in [MLMultiArrayDataType.double, .int32, .float16] {
            XCTAssertThrowsError(try PoreNetService.validateConstraints(pixelsWide: 1024, pixelsHigh: 1280,
                pixelFormat: kCVPixelFormatType_32BGRA, outputDataType: dataType, declaredOutputShape: []))
        }
        XCTAssertThrowsError(try PoreNetService.validateConstraints(pixelsWide: 1024, pixelsHigh: 1280,
            pixelFormat: kCVPixelFormatType_32ARGB, outputDataType: .float32, declaredOutputShape: []))
        XCTAssertThrowsError(try PoreNetService.validateConstraints(pixelsWide: 1280, pixelsHigh: 1024,
            pixelFormat: kCVPixelFormatType_32BGRA, outputDataType: .float32, declaredOutputShape: []))
        // Static omission must never relax actual output dimensions or float32 enforcement.
        let wrongRuntimeShape = try MLMultiArray(shape: [1, 2, 3], dataType: .float32)
        XCTAssertThrowsError(try PoreNetService.copyProbabilityMap(wrongRuntimeShape, width: 3, height: 2))
        let wrongRuntimeType = try MLMultiArray(shape: [1, 1, 2, 3], dataType: .double)
        XCTAssertThrowsError(try PoreNetService.copyProbabilityMap(wrongRuntimeType, width: 3, height: 2))
    }

    func testWholeImageMappingCoverageAndEightNeighborComponents() throws {
        let result = try PoreNetService.summarize(probabilities: [0.9, 0, 0.3, 0, 0, 0, 0, 0.95], width: 4, height: 2,
            crop: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5), landmarks: [:], segmentation: mask())
        XCTAssertEqual(result.statistics.validSkinPixels, 8)
        XCTAssertEqual(result.statistics.candidatePixels, 3)
        XCTAssertEqual(result.statistics.connectedComponents, 2, "Diagonal candidates form one eight-neighbor component")
        XCTAssertEqual(result.statistics.coveragePercent, 37.5, accuracy: 1e-10)
        let points = try XCTUnwrap(result.overlay.paths.first)
        XCTAssertEqual(points.count, 2)
        XCTAssertEqual(points[0].x, 0.6875, accuracy: 1e-12)
        XCTAssertEqual(points[0].y, 0.625, accuracy: 1e-12)
        XCTAssertEqual(points[1].x, 0.3125, accuracy: 1e-12)
        XCTAssertEqual(points[1].y, 0.375, accuracy: 1e-12)
        let exactThreshold = try PoreNetService.summarize(probabilities: [0.25], width: 1, height: 1,
            crop: CGRect(x: 0, y: 0, width: 1, height: 1), landmarks: [:], segmentation: mask())
        XCTAssertEqual(exactThreshold.statistics.candidatePixels, 0, "Author inference uses >, not >=")
        XCTAssertEqual(exactThreshold.statistics.coveragePercent, 0)
        XCTAssertTrue(exactThreshold.overlay.paths.isEmpty)
    }

    func testSemanticHairAccessoriesLowConfidenceAndEyePixelsCannotBecomePoreCandidates() throws {
        let width = 40, height = 40
        var labels = [UInt8](repeating: 3, count: width * height)
        var confidence = (0..<6).map { _ in [Float](repeating: 0, count: width * height) }
        for y in 0..<height { for x in 0..<width {
            let i = y * width + x
            labels[i] = y < 3 ? 1 : (x < 3 ? 5 : 3)
            confidence[Int(labels[i])][i] = y == 3 ? 0.64 : 1
        } }
        let input = try FaceSegmentationService.Mask(width: width, height: height, categories: labels, confidence: confidence)
        let result = try PoreNetService.summarize(probabilities: .init(repeating: 1, count: width * height), width: width, height: height,
            crop: CGRect(x: 0, y: 0, width: 1, height: 1), landmarks: landmarks, segmentation: input)
        let expected = (0..<(width * height)).filter { index in
            input.isFaceSkin(x: (Double(index % width) + 0.5) / Double(width), y: (Double(index / width) + 0.5) / Double(height), landmarks: landmarks)
        }.count
        XCTAssertEqual(result.statistics.validSkinPixels, expected)
        XCTAssertEqual(result.statistics.candidatePixels, expected)
        XCTAssertLessThan(expected, width * height)
        XCTAssertTrue(result.overlay.paths.flatMap { $0 }.allSatisfy { input.isFaceSkin(x: $0.x, y: $0.y, landmarks: landmarks) })
        for y in 0...50 { for x in 0...50 {
            let px = Double(x) / 50, py = Double(y) / 50
            XCTAssertEqual(PoreNetService.exclusionRects(landmarks).contains { $0.contains(x: px, y: py) },
                           FaceSegmentationService.Mask.excludesFeature(x: px, y: py, landmarks: landmarks))
        } }
        XCTAssertThrowsError(try PoreNetService.summarize(probabilities: [1], width: 1, height: 1,
            crop: CGRect(x: 0, y: 0, width: 1, height: 1), landmarks: [:], segmentation: mask { _, _ in .accessories }))
    }

    func testDisplayCapDoesNotReduceFullPixelOrComponentStatistics() throws {
        let width = 200, height = 200
        let probabilities: [Float] = (0..<(width * height)).map { i in (i % width) % 3 == 0 && (i / width) % 3 == 0 ? 1 : 0 }
        let expected = probabilities.filter { $0 > 0.25 }.count
        let result = try PoreNetService.summarize(probabilities: probabilities, width: width, height: height,
            crop: CGRect(x: 0, y: 0, width: 1, height: 1), landmarks: [:], segmentation: mask())
        XCTAssertGreaterThan(expected, 300)
        XCTAssertEqual(result.statistics.validSkinPixels, width * height)
        XCTAssertEqual(result.statistics.candidatePixels, expected)
        XCTAssertEqual(result.statistics.connectedComponents, expected)
        XCTAssertEqual(result.statistics.coveragePercent, Double(expected) / Double(width * height) * 100, accuracy: 1e-10)
        XCTAssertEqual(result.overlay.paths.count, 1)
        XCTAssertEqual(result.overlay.paths[0].count, 300)
        XCTAssertTrue(result.overlay.paths[0].allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) })
    }

    func testInvalidOutputDoesNotProduceNumericalObservations() throws {
        let invalidMaps: [[Float]] = [[.nan], [.infinity], [-0.01], [1.01], []]
        for values in invalidMaps {
            XCTAssertThrowsError(try PoreNetService.summarize(probabilities: values, width: 1, height: 1,
                crop: CGRect(x: 0, y: 0, width: 1, height: 1), landmarks: [:], segmentation: mask()))
        }
        let original = report()
        for state in [PoreNetService.State.notBundled, .lowResolution, .missingSegmentation, .inferenceFailed] {
            let unavailable = PoreNetService.Observation(state: state, nativeCropWidth: 300, nativeCropHeight: 400,
                elapsed: 0, statistics: nil, overlay: nil, source: PoreNetService.source)
            let result = PoreNetService.applying(unavailable, to: original)
            let item = try XCTUnwrap(result.skin.first { $0.dimension == .smoothness }?.items.first { $0.id == "trained-pore-net" })
            XCTAssertFalse(item.valueText.contains("0.00%"))
            XCTAssertNil(item.overlayID)
            XCTAssertFalse(try XCTUnwrap(result.quality.first { $0.id == "trainedPoreNet" }).passed)
            XCTAssertTrue(result.overlays.isEmpty)
        }
    }

    func testApplicationPreservesHeuristicAndScoreAndIsIdempotent() throws {
        let result = try PoreNetService.summarize(probabilities: [0.3, 0, 0, 0], width: 2, height: 2,
            crop: CGRect(x: 0, y: 0, width: 1, height: 1), landmarks: [:], segmentation: mask())
        let once = PoreNetService.applying(observation(result), to: report())
        let twice = PoreNetService.applying(observation(result), to: once)
        let skin = try XCTUnwrap(twice.skin.first { $0.dimension == .smoothness })
        XCTAssertEqual(skin.score, 42)
        XCTAssertEqual(skin.scoreSource, "photoHeuristic")
        XCTAssertEqual(skin.status, "existing")
        XCTAssertEqual(skin.items.first { $0.id == "existing-fine-dot" }?.valueText, "unchanged")
        XCTAssertEqual(skin.items.filter { $0.id == "trained-pore-net" }.count, 1)
        XCTAssertEqual(twice.overlays.filter { $0.id == "model-pore-net" }.count, 1)
        XCTAssertEqual(twice.modelVersion, once.modelVersion)
        XCTAssertEqual(twice.summary, once.summary)
        XCTAssertNoThrow(try ReportValidator.validate(twice))
    }

    private func validMetadata() -> [String: String] {
        ["ruyuan.repository": "ZombaSY/Pore-Net-release", "ruyuan.revision": PoreNetService.revision,
         "ruyuan.source_sha256": PoreNetService.weightSHA256, "ruyuan.compute_precision": "float32",
         "ruyuan.threshold": "0.25", "ruyuan.normalization": "{\"mean\":[0.512,0.459,0.353],\"std\":[0.254,0.226,0.219]}"]
    }

    func testWrongModelOrDoubleNormalizationMetadataIsRejected() throws {
        XCTAssertNoThrow(try PoreNetService.validateMetadata(validMetadata()))
        for (key, value) in [("ruyuan.repository", "other"), ("ruyuan.revision", "other"), ("ruyuan.source_sha256", "other"),
                             ("ruyuan.compute_precision", "float16"), ("ruyuan.threshold", "0.5"),
                             ("ruyuan.normalization", "{\"mean\":[0,0,0],\"std\":[1,1,1]}")] {
            var wrong = validMetadata(); wrong[key] = value
            XCTAssertThrowsError(try PoreNetService.validateMetadata(wrong))
        }
        XCTAssertThrowsError(try PoreNetService.validateManifest(Data("{\"state\":\"torch_preflight_only\"}".utf8)))
    }

    func testFullStackSemanticGeometry478AndPoresFitsNearFullReportBudget() throws {
        let width = 640, height = 640, box = CGRect(x: 0.12, y: 0.08, width: 0.76, height: 0.84)
        let input = try mask(width: width, height: height) { x, y in
            if y < 128 { return .hair }
            return x % 9 == 0 ? .accessories : .faceSkin
        }
        let raster = try XCTUnwrap(LocalAnalyzer.makeRaster(image(width: width, height: height)))
        let appearance = AppearanceAnalyzer.analyze(raster: raster, landmarks: landmarks, faceBox: box, segmentation: input)
        let boundary = input.boundaryGeometry(landmarks: landmarks, faceBox: box)
        let densePoints = (0..<478).map { i in Ruyuan.NormalizedPoint(x: 0.1 + Double(i % 23) / 30, y: 0.1 + Double(i / 23) / 30) }
        let dense = try FaceLandmarkService.makeResult(points: densePoints, relativeZ: .init(repeating: 0, count: 478))
        var paths = landmarks.map { LandmarkPath(id: $0.key, points: $0.value, closed: false) } + dense.landmarks
        if let path = boundary.path { paths.append(path) }
        var overlays = appearance.overlays + input.overlays(landmarks: landmarks, faceBox: box)
            + FaceGeometryAnalyzer.overlays(landmarks: landmarks, width: width, height: height) + dense.overlays
        if let layer = boundary.overlay { overlays.append(layer) }
        // Keep all real service layers and add adversarial existing content to exercise the
        // practical near-full report budget, rather than validating an artificially empty report.
        let padding = max(0, 9_200 - paths.count - overlays.flatMap(\.paths).count)
        overlays.append(OverlayLayer(id: "budget-padding", title: "Synthetic capacity fixture", colorHex: "FFFFFF", kind: .lines,
            paths: .init(repeating: [.init(x: 0.1, y: 0.2), .init(x: 0.8, y: 0.9)], count: padding), note: "test", source: "test"))
        let geometry = LocalAnalyzer.geometryMetrics(landmarks, width: width, height: height)
            + FaceGeometryAnalyzer.metrics(landmarks: landmarks, width: width, height: height) + boundary.metrics
        let original = AnalysisReport(id: "pore-full-stack", createdAt: Date(), origin: .local, status: "test",
            imageFileName: "synthetic.jpg", imageWidth: width, imageHeight: height, geometry: geometry,
            skin: appearance.metrics, landmarks: paths, overlays: overlays, quality: [], modelVersion: dense.source, summary: "test")
        let mapWidth = 200, mapHeight = 200
        let values: [Float] = (0..<(mapWidth * mapHeight)).map { i in (i % mapWidth) % 3 == 0 && (i / mapWidth) % 3 == 0 ? 0.9 : 0 }
        let pore = try PoreNetService.summarize(probabilities: values, width: mapWidth, height: mapHeight,
            crop: CGRect(x: 0.12, y: 0.08, width: 0.76, height: 0.84), landmarks: landmarks, segmentation: input)
        let complete = PoreNetService.applying(observation(pore), to: original)
        XCTAssertNoThrow(try ReportValidator.validate(complete))
        XCTAssertNoThrow(try FaceCalibration.applying(to: complete, hairlineY: 0.2, pupilDistanceMM: nil))
        XCTAssertLessThanOrEqual(complete.landmarks.count + complete.overlays.flatMap(\.paths).count, 10_000)
        XCTAssertLessThanOrEqual(complete.overlays.count, 49)
        XCTAssertEqual(complete.overlays.filter { $0.id == "model-pore-net" }.count, 1)
    }
}
