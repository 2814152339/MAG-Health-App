import XCTest
@testable import Ruyuan

final class SelfAssessmentCalibrationTests:XCTestCase {
    func testQuestionnaireIsSeparatedAndDoesNotOverwriteServerScores() {
        var report=SampleData.report
        report.origin = .server
        let old=report.skin.map(\.score)
        let answer=SkinSelfAssessment(dryness:1,oiliness:2,reactivity:0,age:30)
        let next=answer.applying(to:report)
        XCTAssertEqual(next.skin.map(\.score),old)
        XCTAssertEqual(next.assessment?.age,30)
        XCTAssertTrue(next.skin.flatMap(\.items).contains{$0.id == "self-dryness"})
    }
    func testMissingScoresCanUseClearlyMarkedSelfReport() {
        var report=SampleData.report
        report.origin = .local
        report.skin=report.skin.map { metric in var m=metric;m.score=nil;return m }
        let next=SkinSelfAssessment(dryness:2,oiliness:1,reactivity:3,age:nil).applying(to:report)
        XCTAssertEqual(next.skin.first{$0.dimension == .waterOil}?.score,66)
        XCTAssertEqual(next.skin.first{$0.dimension == .sensitivity}?.score,34)
        XCTAssertEqual(next.skin.first{$0.dimension == .waterOil}?.scoreSource,"selfReport")
        XCTAssertNil(next.totalScore)
    }
    func testLegacyReportWithoutNewOptionalFieldsDecodes() throws {
        let data=try JSONEncoder().encode(SampleData.report)
        var json=try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        json.removeValue(forKey:"assessment")
        var skin=try XCTUnwrap(json["skin"] as? [[String:Any]])
        for index in skin.indices{skin[index].removeValue(forKey:"scoreSource")}
        json["skin"]=skin
        let old=try JSONSerialization.data(withJSONObject:json)
        let decoded=try JSONDecoder().decode(AnalysisReport.self,from:old)
        XCTAssertNil(decoded.assessment)
        XCTAssertTrue(decoded.skin.allSatisfy{$0.scoreSource == nil})
    }
    func testInvalidQuestionnaireDoesNotAlterOriginal() {
        let original=SampleData.report
        let next=SkinSelfAssessment(dryness:-1,oiliness:8,reactivity:0,age:nil).applying(to:original)
        XCTAssertNil(next.assessment)
        XCTAssertEqual(next.summary,original.summary)
    }
    private var calibrationReport:AnalysisReport {
        var r=SampleData.report
        r.landmarks=[
            .init(id:"faceContour",points:[.init(x:0.1,y:0.5),.init(x:0.5,y:0.9),.init(x:0.9,y:0.5)],closed:false),
            .init(id:"leftEyebrow",points:[.init(x:0.2,y:0.3),.init(x:0.4,y:0.3)],closed:false),
            .init(id:"rightEyebrow",points:[.init(x:0.6,y:0.3),.init(x:0.8,y:0.3)],closed:false),
            .init(id:"nose",points:[.init(x:0.45,y:0.4),.init(x:0.55,y:0.6)],closed:true),
            .init(id:"leftPupil",points:[.init(x:0.3,y:0.4)],closed:false),
            .init(id:"rightPupil",points:[.init(x:0.7,y:0.4)],closed:false)]
        return r
    }
    func testManualHairlineProducesThreePartsSummingTo100WithoutFakeMM() throws {
        let original=calibrationReport
        let next=try FaceCalibration.applying(to:original,hairlineY:0.1,pupilDistanceMM:nil)
        let values=next.geometry.filter{$0.id.hasPrefix("calibrated-")}.compactMap(\.value)
        XCTAssertEqual(values.count,3)
        XCTAssertEqual(values.reduce(0,+),100,accuracy:0.00001)
        XCTAssertTrue(next.geometry.filter{$0.id.hasPrefix("calibrated-")}.allSatisfy{$0.unit == "%"})
        XCTAssertEqual(next.landmarks.map(\.id),original.landmarks.map(\.id))
        XCTAssertEqual(next.landmarks.map(\.points),original.landmarks.map(\.points))
    }
    func testMillimetersRequireExplicitValidMeasuredPupilScale() throws {
        let next=try FaceCalibration.applying(to:calibrationReport,hairlineY:nil,pupilDistanceMM:64)
        let value=try XCTUnwrap(next.geometry.first{$0.id == "calibrated-faceContour-mm"}?.value)
        XCTAssertEqual(value,128,accuracy:0.00001)
        XCTAssertThrowsError(try FaceCalibration.applying(to:calibrationReport,hairlineY:0.6,pupilDistanceMM:nil))
        XCTAssertThrowsError(try FaceCalibration.applying(to:calibrationReport,hairlineY:nil,pupilDistanceMM:120))
        XCTAssertThrowsError(try FaceCalibration.applying(to:calibrationReport,hairlineY:nil,pupilDistanceMM:nil))
    }
}
