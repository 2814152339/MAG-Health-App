import XCTest
@testable import Ruyuan

final class ReportContractTests: XCTestCase {
    func testSampleIsExplicitAndNotPersistedAsUserResult() throws {
        let report = SampleData.report
        XCTAssertEqual(report.origin, .sample)
        XCTAssertTrue(report.isSample)
        XCTAssertEqual(report.imageFileName, "")
        XCTAssertTrue(report.summary.contains("演示"))
        XCTAssertEqual(report.skin.count, 5)
        XCTAssertNotNil(report.totalScore)
        try ReportValidator.validate(report)
    }

    func testMissingScoreDoesNotTurnIntoZero() {
        var report = SampleData.report
        report.skin[0].score = nil
        XCTAssertNil(report.totalScore)
    }

    func testCodableRoundTripPreservesCoordinatesAndMissingValues() throws {
        var report = SampleData.report
        report.skin[1].score = nil
        let data = try JSONEncoder().encode(report)
        let copy = try JSONDecoder().decode(AnalysisReport.self, from: data)
        XCTAssertEqual(copy.id, report.id)
        XCTAssertNil(copy.skin[1].score)
        XCTAssertEqual(copy.overlays.first?.paths, report.overlays.first?.paths)
    }

    func testRejectsInvalidCoordinatesAndDuplicateDimensions() {
        var report = SampleData.report
        report.overlays[0].paths[0][0].x = 1.5
        XCTAssertThrowsError(try ReportValidator.validate(report))
        report = SampleData.report
        report.skin[1].dimension = .waterOil
        XCTAssertThrowsError(try ReportValidator.validate(report))
    }

    func testRequiresSecureRemoteTransportAndNonemptyToken() {
        XCTAssertThrowsError(try APIClient(url: "http://public.example.com", token: "secret"))
        XCTAssertThrowsError(try APIClient(url: "https://public.example.com", token: ""))
        XCTAssertNoThrow(try APIClient(url: "http://192.168.1.10:8000", token: "secret"))
        XCTAssertThrowsError(try APIClient(url: "https://user:pass@public.example.com", token: "secret"))
        XCTAssertThrowsError(try APIClient(url: "http://10.192.168.1.evil.com", token: "secret"))
    }
}
