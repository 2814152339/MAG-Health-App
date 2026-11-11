import CoreGraphics
import XCTest
@testable import Ruyuan

final class AppearanceAnalyzerTests: XCTestCase {
    private let box = CGRect(x: 0.12, y: 0.08, width: 0.76, height: 0.84)
    private var landmarks: [String: [NormalizedPoint]] {
        func rect(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> [NormalizedPoint] {
            [.init(x:x,y:y),.init(x:x+width,y:y),.init(x:x+width,y:y+height),.init(x:x,y:y+height)]
        }
        return ["leftEye":rect(0.25,0.39,0.14,0.045),"rightEye":rect(0.61,0.39,0.14,0.045),
                "leftEyebrow":rect(0.23,0.32,0.18,0.025),"rightEyebrow":rect(0.59,0.32,0.18,0.025),
                "outerLips":rect(0.39,0.72,0.22,0.07),"nose":rect(0.43,0.43,0.14,0.23)]
    }
    private func raster(width: Int = 640, height: Int = 640,
                        patches: [(CGRect, [UInt8])] = []) -> LocalAnalyzer.Raster {
        var pixels=[UInt8](repeating:255,count:width*height*4)
        for y in 0..<height { for x in 0..<width {
            let point=CGPoint(x:(Double(x)+0.5)/Double(width),y:(Double(y)+0.5)/Double(height))
            var rgb:[UInt8]=[182,137,111]
            for (rect,color) in patches where rect.contains(point) { rgb=color }
            let i=(y*width+x)*4
            pixels[i]=rgb[0];pixels[i+1]=rgb[1];pixels[i+2]=rgb[2]
        } }
        return LocalAnalyzer.Raster(width:width,height:height,pixels:pixels)
    }
    func testSRGBToLabD65ReferenceValues() {
        let white=AppearanceAnalyzer.labFromSRGB(red:1,green:1,blue:1)
        XCTAssertEqual(white.l,100,accuracy:0.01)
        XCTAssertEqual(white.a,0,accuracy:0.01)
        XCTAssertEqual(white.b,0,accuracy:0.01)
        let black=AppearanceAnalyzer.labFromSRGB(red:0,green:0,blue:0)
        XCTAssertEqual(black.l,0,accuracy:0.001)
        let red=AppearanceAnalyzer.labFromSRGB(red:1,green:0,blue:0)
        XCTAssertEqual(red.l,53.2408,accuracy:0.01)
        XCTAssertEqual(red.a,80.0925,accuracy:0.01)
    }
    func testUniformPhotoDoesNotFabricateCandidatesOrMedicalScores() throws {
        let result=AppearanceAnalyzer.analyze(raster:raster(),landmarks:landmarks,faceBox:box)
        XCTAssertEqual(result.metrics.count,5)
        XCTAssertNil(result.metrics.first{$0.dimension == .waterOil}?.score)
        XCTAssertNil(result.metrics.first{$0.dimension == .sensitivity}?.score)
        for layer in result.overlays where layer.id != "appearance-roi" {
            XCTAssertTrue(layer.paths.isEmpty,"Uniform pixels must not create \(layer.id)")
        }
        XCTAssertEqual(try XCTUnwrap(result.metrics.first{$0.dimension == .tone}?.score),100,accuracy:0.01)
        XCTAssertEqual(try XCTUnwrap(result.metrics.first{$0.dimension == .smoothness}?.score),100,accuracy:0.01)
    }
    func testRealHighlightAppearsOnlyAtItsPixelLocation() throws {
        let patch=CGRect(x:0.29,y:0.51,width:0.025,height:0.025)
        let result=AppearanceAnalyzer.analyze(raster:raster(patches:[(patch,[245,241,237])]),landmarks:landmarks,faceBox:box)
        let layer=try XCTUnwrap(result.overlays.first{$0.id == "appearance-highlight"})
        XCTAssertFalse(layer.paths.isEmpty)
        for path in layer.paths { for p in path {
            XCTAssertGreaterThanOrEqual(p.x,patch.minX-0.003)
            XCTAssertLessThanOrEqual(p.x,patch.maxX+0.003)
            XCTAssertGreaterThanOrEqual(p.y,patch.minY-0.003)
            XCTAssertLessThanOrEqual(p.y,patch.maxY+0.003)
        } }
    }
    func testEyeLipAndNostrilPixelsExcludedFromSkinMasks() throws {
        let excluded=[CGRect(x:0.26,y:0.40,width:0.10,height:0.02),
                      CGRect(x:0.44,y:0.74,width:0.12,height:0.02),
                      CGRect(x:0.47,y:0.62,width:0.05,height:0.025)]
        let result=AppearanceAnalyzer.analyze(raster:raster(patches:excluded.map{($0,[250,250,250])}),landmarks:landmarks,faceBox:box)
        XCTAssertTrue(try XCTUnwrap(result.overlays.first{$0.id == "appearance-highlight"}).paths.isEmpty)
    }
    func testMissingLandmarksAndSmallRasterAbstain() {
        let missing=AppearanceAnalyzer.analyze(raster:raster(),landmarks:[:],faceBox:box)
        XCTAssertTrue(missing.overlays.isEmpty)
        XCTAssertTrue(missing.metrics.allSatisfy{$0.score == nil})
        let low=AppearanceAnalyzer.analyze(raster:raster(width:160,height:160),landmarks:landmarks,faceBox:box)
        XCTAssertNil(low.metrics.first{$0.dimension == .smoothness}?.score)
        XCTAssertTrue(low.overlays.first{$0.id == "appearance-dots"}?.paths.isEmpty ?? true)
    }
    func testOutputWithinReportValidationBudgetAndDeterministic() throws {
        let input=raster(patches:[(CGRect(x:0.28,y:0.51,width:0.03,height:0.04),[143,95,70])])
        let first=AppearanceAnalyzer.analyze(raster:input,landmarks:landmarks,faceBox:box)
        let second=AppearanceAnalyzer.analyze(raster:input,landmarks:landmarks,faceBox:box)
        XCTAssertEqual(first.overlays.flatMap(\.paths),second.overlays.flatMap(\.paths))
        XCTAssertLessThanOrEqual(first.overlays.flatMap(\.paths).count,6000)
        XCTAssertLessThan(first.overlays.flatMap(\.paths).reduce(0){$0+$1.count},90000)
        let report=AnalysisReport(id:"appearance-synthetic",createdAt:Date(),origin:.local,status:"test",
            imageFileName:"synthetic.jpg",imageWidth:640,imageHeight:640,geometry:[],skin:first.metrics,
            landmarks:[],overlays:first.overlays,quality:[],modelVersion:AppearanceAnalyzer.version,summary:first.summary)
        XCTAssertNoThrow(try ReportValidator.validate(report))
    }
}
