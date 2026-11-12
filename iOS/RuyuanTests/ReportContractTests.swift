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

    func testFixedSyntheticV01ReportsDecodeWithoutNewOptionalFields() throws {
        // Hand-written JSON matching 3ac5c2b, not current encoding with keys removed.
        let reports = try assertLegacyFixture(Self.syntheticV01JSON,
                                             expectedIDs: ["synthetic-v01-local", "synthetic-v01-server"])
        for report in reports {
            XCTAssertNil(report.assessment)
            XCTAssertNil(report.calibration)
            XCTAssertTrue(report.skin.allSatisfy { $0.scoreSource == nil })
            XCTAssertNil(report.totalScore)
        }
    }

    func testFixedSyntheticV02ReportsPreserveAssessmentWithoutCalibration() throws {
        // e103678 introduced assessment/scoreSource; e2fcad0 added OPTIONAL calibration.
        // Missing calibration is therefore valid old JSON, not a required migration.
        let reports = try assertLegacyFixture(Self.syntheticV02JSON,
                                             expectedIDs: ["synthetic-v02-local", "synthetic-v02-server"])
        for report in reports { XCTAssertNil(report.calibration) }
        let local = try XCTUnwrap(reports.first)
        XCTAssertEqual(local.assessment?.dryness, 1)
        XCTAssertEqual(local.assessment?.oiliness, 2)
        XCTAssertEqual(local.assessment?.reactivity, 0)
        XCTAssertEqual(local.assessment?.age, 34)
        XCTAssertEqual(local.skin.first?.scoreSource, "selfReport")
        let server = try XCTUnwrap(reports.last)
        XCTAssertEqual(server.assessment?.dryness, 3)
        XCTAssertNil(server.assessment?.age)
        XCTAssertNil(server.skin.first?.score)
        XCTAssertNil(server.skin.first?.scoreSource)
        XCTAssertNil(server.totalScore)
    }

    private func assertLegacyFixture(_ json: String, expectedIDs: [String],
                                     file: StaticString = #filePath, line: UInt = #line) throws -> [AnalysisReport] {
        let data = Data(json.utf8)
        let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]], file: file, line: line)
        let decoded = try JSONDecoder().decode([AnalysisReport].self, from: data)
        XCTAssertEqual(decoded.map(\.id), expectedIDs, file: file, line: line)
        XCTAssertEqual(expected.count, expectedIDs.count, file: file, line: line)

        // Verify every persisted old field both immediately and after current re-encoding.
        // Optional null and an omitted optional key both intentionally mean nil.
        let encoded = try JSONEncoder().encode(decoded)
        let restored = try JSONDecoder().decode([AnalysisReport].self, from: encoded)
        for reports in [decoded, restored] {
            XCTAssertEqual(reports.count, expected.count, file: file, line: line)
            for (report, old) in zip(reports, expected) {
                XCTAssertNoThrow(try ReportValidator.validate(report), file: file, line: line)
                XCTAssertEqual(report.id, old["id"] as? String, file: file, line: line)
                let date = try XCTUnwrap(old["createdAt"] as? Double, file: file, line: line)
                XCTAssertEqual(report.createdAt, Date(timeIntervalSinceReferenceDate: date), file: file, line: line)
                XCTAssertEqual(report.origin.rawValue, old["origin"] as? String, file: file, line: line)
                XCTAssertEqual(report.status, old["status"] as? String, file: file, line: line)
                XCTAssertEqual(report.imageFileName, old["imageFileName"] as? String, file: file, line: line)
                XCTAssertEqual(report.imageWidth, old["imageWidth"] as? Int, file: file, line: line)
                XCTAssertEqual(report.imageHeight, old["imageHeight"] as? Int, file: file, line: line)
                XCTAssertEqual(report.modelVersion, old["modelVersion"] as? String, file: file, line: line)
                XCTAssertEqual(report.summary, old["summary"] as? String, file: file, line: line)
                XCTAssertNil(report.calibration, file: file, line: line)

                let geometry = try XCTUnwrap(old["geometry"] as? [[String: Any]], file: file, line: line)
                XCTAssertEqual(report.geometry.count, geometry.count, file: file, line: line)
                for (metric, row) in zip(report.geometry, geometry) {
                    XCTAssertEqual(metric.id, row["id"] as? String, file: file, line: line)
                    XCTAssertEqual(metric.title, row["title"] as? String, file: file, line: line)
                    XCTAssertEqual(metric.value, row["value"] as? Double, file: file, line: line)
                    XCTAssertEqual(metric.unit, row["unit"] as? String, file: file, line: line)
                    XCTAssertEqual(metric.note, row["note"] as? String, file: file, line: line)
                }
                let skin = try XCTUnwrap(old["skin"] as? [[String: Any]], file: file, line: line)
                XCTAssertEqual(report.skin.count, skin.count, file: file, line: line)
                for (metric, row) in zip(report.skin, skin) {
                    XCTAssertEqual(metric.dimension.rawValue, row["dimension"] as? String, file: file, line: line)
                    XCTAssertEqual(metric.score, row["score"] as? Double, file: file, line: line)
                    XCTAssertEqual(metric.status, row["status"] as? String, file: file, line: line)
                    XCTAssertEqual(metric.scoreSource, row["scoreSource"] as? String, file: file, line: line)
                    let items = try XCTUnwrap(row["items"] as? [[String: Any]], file: file, line: line)
                    XCTAssertEqual(metric.items.count, items.count, file: file, line: line)
                    for (item, itemRow) in zip(metric.items, items) {
                        XCTAssertEqual(item.id, itemRow["id"] as? String, file: file, line: line)
                        XCTAssertEqual(item.title, itemRow["title"] as? String, file: file, line: line)
                        XCTAssertEqual(item.valueText, itemRow["valueText"] as? String, file: file, line: line)
                        XCTAssertEqual(item.note, itemRow["note"] as? String, file: file, line: line)
                        XCTAssertEqual(item.overlayID, itemRow["overlayID"] as? String, file: file, line: line)
                    }
                }
                let landmarks = try XCTUnwrap(old["landmarks"] as? [[String: Any]], file: file, line: line)
                XCTAssertEqual(report.landmarks.count, landmarks.count, file: file, line: line)
                for (path, row) in zip(report.landmarks, landmarks) {
                    XCTAssertEqual(path.id, row["id"] as? String, file: file, line: line)
                    XCTAssertEqual(path.closed, row["closed"] as? Bool, file: file, line: line)
                    try assertLegacyPoints(path.points, row["points"], file: file, line: line)
                }
                let overlays = try XCTUnwrap(old["overlays"] as? [[String: Any]], file: file, line: line)
                XCTAssertEqual(report.overlays.count, overlays.count, file: file, line: line)
                for (layer, row) in zip(report.overlays, overlays) {
                    XCTAssertEqual(layer.id, row["id"] as? String, file: file, line: line)
                    XCTAssertEqual(layer.title, row["title"] as? String, file: file, line: line)
                    XCTAssertEqual(layer.colorHex, row["colorHex"] as? String, file: file, line: line)
                    XCTAssertEqual(layer.kind.rawValue, row["kind"] as? String, file: file, line: line)
                    XCTAssertEqual(layer.note, row["note"] as? String, file: file, line: line)
                    XCTAssertEqual(layer.source, row["source"] as? String, file: file, line: line)
                    let paths = try XCTUnwrap(row["paths"] as? [Any], file: file, line: line)
                    XCTAssertEqual(layer.paths.count, paths.count, file: file, line: line)
                    for (points, oldPoints) in zip(layer.paths, paths) {
                        try assertLegacyPoints(points, oldPoints, file: file, line: line)
                    }
                }
                let quality = try XCTUnwrap(old["quality"] as? [[String: Any]], file: file, line: line)
                XCTAssertEqual(report.quality.count, quality.count, file: file, line: line)
                for (check, row) in zip(report.quality, quality) {
                    XCTAssertEqual(check.id, row["id"] as? String, file: file, line: line)
                    XCTAssertEqual(check.title, row["title"] as? String, file: file, line: line)
                    XCTAssertEqual(check.passed, row["passed"] as? Bool, file: file, line: line)
                    XCTAssertEqual(check.detail, row["detail"] as? String, file: file, line: line)
                }
                if let row = old["assessment"] as? [String: Any] {
                    let assessment = try XCTUnwrap(report.assessment, file: file, line: line)
                    XCTAssertEqual(assessment.dryness, row["dryness"] as? Int, file: file, line: line)
                    XCTAssertEqual(assessment.oiliness, row["oiliness"] as? Int, file: file, line: line)
                    XCTAssertEqual(assessment.reactivity, row["reactivity"] as? Int, file: file, line: line)
                    XCTAssertEqual(assessment.age, row["age"] as? Int, file: file, line: line)
                } else {
                    XCTAssertNil(report.assessment, file: file, line: line)
                }
            }
        }
        return decoded
    }

    private func assertLegacyPoints(_ points: [Ruyuan.NormalizedPoint], _ old: Any?,
                                    file: StaticString, line: UInt) throws {
        let expected = try XCTUnwrap(old as? [[String: Any]], file: file, line: line)
        XCTAssertEqual(points.count, expected.count, file: file, line: line)
        for (point, row) in zip(points, expected) {
            XCTAssertEqual(point.x, row["x"] as? Double, file: file, line: line)
            XCTAssertEqual(point.y, row["y"] as? Double, file: file, line: line)
        }
    }

    // Entirely synthetic metadata/coordinates: no personal report or photo bytes.
    // Dates use the original default Codable Date format (seconds since 2001-01-01).
    private static let syntheticV01JSON = """
    [
      {
        "id":"synthetic-v01-local","createdAt":815000000.25,"origin":"local","status":"partial",
        "imageFileName":"synthetic-v01-local.jpg","imageWidth":640,"imageHeight":960,
        "geometry":[{"id":"legacy-eye-ratio","title":"合成眼距比例","value":12.5,"unit":"%","note":"旧版合成定义"},{"id":"legacy-mm","title":"合成未标定长度","value":null,"unit":"mm","note":"不补测量值"}],
        "skin":[
          {"dimension":"waterOil","score":null,"status":"未测量","items":[{"id":"legacy-shine","title":"合成高亮","valueText":"2.5%","note":"合成像素统计","overlayID":"legacy-shine"}]},
          {"dimension":"tone","score":81.5,"status":"合成参考","items":[]},
          {"dimension":"sensitivity","status":"未测量","items":[]},
          {"dimension":"smoothness","score":76,"status":"合成参考","items":[]},
          {"dimension":"aging","score":72.25,"status":"合成参考","items":[]}
        ],
        "landmarks":[{"id":"legacy-outline","points":[{"x":0.125,"y":0.25},{"x":0.5,"y":0.875}],"closed":false}],
        "overlays":[{"id":"legacy-shine","title":"合成高亮区域","colorHex":"#FFD84D","kind":"polygons","paths":[[{"x":0.25,"y":0.25},{"x":0.5,"y":0.25},{"x":0.5,"y":0.5}]],"note":"旧版合成图层","source":"synthetic Vision RGB v0.1"}],
        "quality":[{"id":"legacy-light","title":"合成光照","passed":true,"detail":"固定合成通过"},{"id":"legacy-blur","title":"合成清晰度","passed":false,"detail":"固定合成提示"}],
        "modelVersion":"synthetic legacy v0.1; no real inference","summary":"合成旧版报告一，保留原文字与缺项。"
      },
      {
        "id":"synthetic-v01-server","createdAt":815086400.5,"origin":"server","status":"ready",
        "imageFileName":"synthetic-v01-server.jpg","imageWidth":1200,"imageHeight":1600,
        "geometry":[{"id":"legacy-angle","title":"合成角度","value":-8.25,"unit":"°","note":"保留负数"}],
        "skin":[
          {"dimension":"waterOil","status":"未提供","items":[]},
          {"dimension":"tone","score":65.5,"status":"合成来源","items":[{"id":"legacy-server-tone","title":"合成肤色","valueText":"原文参考","note":"不改旧注释"}]},
          {"dimension":"sensitivity","score":null,"status":"未提供","items":[]},
          {"dimension":"smoothness","score":62,"status":"合成来源","items":[]},
          {"dimension":"aging","score":58.75,"status":"合成来源","items":[]}
        ],
        "landmarks":[{"id":"legacy-triangle","points":[{"x":0.125,"y":0.125},{"x":0.75,"y":0.25},{"x":0.375,"y":0.75}],"closed":true}],
        "overlays":[{"id":"legacy-server-line","title":"合成服务端线","colorHex":"#8080FF","kind":"lines","paths":[[{"x":0.125,"y":0.5},{"x":0.875,"y":0.5}],[{"x":0.5,"y":0.125},{"x":0.5,"y":0.875}]],"note":"两条路径均保留","source":"synthetic server v0.1"}],
        "quality":[{"id":"legacy-framing","title":"合成构图","passed":true,"detail":"无照片字节"}],
        "modelVersion":"synthetic server legacy v0.1","summary":"合成旧版报告二，不将服务端来源改为本机。"
      }
    ]
    """

    private static let syntheticV02JSON = """
    [
      {
        "id":"synthetic-v02-local","createdAt":815172800.75,"origin":"local","status":"partial",
        "imageFileName":"synthetic-v02-local.jpg","imageWidth":768,"imageHeight":1024,
        "geometry":[{"id":"v02-third","title":"合成三庭比例","value":0.375,"unit":"","note":"固定二维比例"},{"id":"v02-mm","title":"合成未标定毫米","unit":"mm","note":"缺失 value 仍是 nil"}],
        "skin":[
          {"dimension":"waterOil","score":68,"status":"自评参考","scoreSource":"selfReport","items":[{"id":"self-oiliness","title":"合成出油感","valueText":"经常","note":"合成问卷，无仪器测量"}]},
          {"dimension":"tone","score":83.25,"status":"照片参考","scoreSource":"photoHeuristic","items":[]},
          {"dimension":"sensitivity","score":100,"status":"自评参考","scoreSource":"selfReport","items":[]},
          {"dimension":"smoothness","score":77.5,"status":"照片参考","scoreSource":"photoHeuristic","items":[]},
          {"dimension":"aging","score":71,"status":"照片参考","scoreSource":"photoHeuristic","items":[]}
        ],
        "landmarks":[{"id":"v02-brow","points":[{"x":0.25,"y":0.25},{"x":0.375,"y":0.125},{"x":0.5,"y":0.25}],"closed":false}],
        "overlays":[{"id":"v02-red","title":"合成偏红候选","colorHex":"#FF5577","kind":"points","paths":[[{"x":0.375,"y":0.5},{"x":0.625,"y":0.5}]],"note":"候选不是诊断","source":"synthetic Lab thresholds v0.2"}],
        "quality":[{"id":"v02-pose","title":"合成姿态","passed":true,"detail":"固定合成通过"}],
        "modelVersion":"synthetic appearance v0.2; questionnaire v1","summary":"合成 0.2 本机报告，问卷独立保留。",
        "assessment":{"dryness":1,"oiliness":2,"reactivity":0,"age":34}
      },
      {
        "id":"synthetic-v02-server","createdAt":815259200,"origin":"server","status":"partial",
        "imageFileName":"synthetic-v02-server.jpg","imageWidth":1080,"imageHeight":1440,
        "geometry":[{"id":"v02-eye","title":"合成眼宽比","value":18.75,"unit":"%","note":"原始二维定义"}],
        "skin":[
          {"dimension":"waterOil","score":null,"status":"旧来源缺项","items":[]},
          {"dimension":"tone","score":64.25,"status":"照片参考","scoreSource":"photoHeuristic","items":[{"id":"v02-tone","title":"合成明暗","valueText":"-2.5 L*","note":"保留来源与图层关联","overlayID":"v02-shade"}]},
          {"dimension":"sensitivity","score":34,"status":"自评参考","scoreSource":"selfReport","items":[]},
          {"dimension":"smoothness","score":66,"status":"照片参考","scoreSource":"photoHeuristic","items":[]},
          {"dimension":"aging","score":59.5,"status":"照片参考","scoreSource":"photoHeuristic","items":[]}
        ],
        "landmarks":[{"id":"v02-eye-path","points":[{"x":0.25,"y":0.375},{"x":0.375,"y":0.5},{"x":0.5,"y":0.375}],"closed":true}],
        "overlays":[{"id":"v02-shade","title":"合成暗区","colorHex":"#8C6542","kind":"polygons","paths":[[{"x":0.25,"y":0.5},{"x":0.5,"y":0.5},{"x":0.375,"y":0.625}]],"note":"不重算旧结果","source":"synthetic server relative-L v0.2"}],
        "quality":[{"id":"v02-occlusion","title":"合成遮挡","passed":false,"detail":"原始提示不丢失"}],
        "modelVersion":"synthetic server v0.2; voluntary questionnaire","summary":"合成 0.2 服务端报告，年龄未填写。",
        "assessment":{"dryness":3,"oiliness":0,"reactivity":3}
      }
    ]
    """

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
