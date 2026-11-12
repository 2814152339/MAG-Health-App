import Foundation
import XCTest
@testable import Ruyuan

final class OverlayItemPresentationTests: XCTestCase {
    func testExactObservationPreservesSourceTitleValueAndUnits() throws {
        let report = fixture()
        let reference = try XCTUnwrap(OverlayItemPresentation.reference(in: report, dimension: .tone, itemID: "chosen"))
        let item = try XCTUnwrap(resolve(reference, report))
        XCTAssertEqual(reference.reportID, report.id)
        XCTAssertEqual(reference.dimension, .tone)
        XCTAssertEqual(reference.itemID, "chosen")
        XCTAssertEqual(reference.overlayID, "shared")
        XCTAssertEqual(item.title, "合成眼下明暗记录")
        XCTAssertEqual(item.valueText, " 3.1 L* · 合成测试原文 ")
        XCTAssertEqual(item.note, "只作解析测试，不是检测结果。")
    }

    func testSeveralItemsSharingLayerResolveTheTappedItemRatherThanFirstMatch() throws {
        let report = fixture()
        let first = try XCTUnwrap(OverlayItemPresentation.reference(in: report, dimension: .tone, itemID: "first"))
        let chosen = try XCTUnwrap(OverlayItemPresentation.reference(in: report, dimension: .tone, itemID: "chosen"))
        XCTAssertEqual(first.overlayID, chosen.overlayID)
        XCTAssertEqual(resolve(first, report)?.valueText, "合成基线 A")
        XCTAssertEqual(resolve(chosen, report)?.valueText, " 3.1 L* · 合成测试原文 ")
        var reordered = report
        reordered.skin[0].items.reverse()
        XCTAssertEqual(resolve(chosen, reordered)?.id, "chosen")
        XCTAssertEqual(resolve(first, reordered)?.id, "first")
    }

    func testDimensionIdentityDisambiguatesIdenticalItemIDsAcrossDimensions() throws {
        var report = fixture()
        report.skin.append(SkinMetric(dimension: .aging, score: nil, status: "合成",
            items: [SkinItem(id: "chosen", title: "另一维度的合成项目", valueText: "不同的合成原值",
                             note: "", overlayID: "shared")]))
        let tone = try XCTUnwrap(OverlayItemPresentation.reference(in: report, dimension: .tone, itemID: "chosen"))
        let aging = try XCTUnwrap(OverlayItemPresentation.reference(in: report, dimension: .aging, itemID: "chosen"))
        XCTAssertEqual(resolve(tone, report)?.title, "合成眼下明暗记录")
        XCTAssertEqual(resolve(aging, report)?.title, "另一维度的合成项目")
    }

    func testDuplicateItemOrDimensionAbstainsEvenWhenCopiesHaveIdenticalText() throws {
        let original = fixture()
        let reference = try XCTUnwrap(OverlayItemPresentation.reference(in: original, dimension: .tone, itemID: "chosen"))
        var duplicateItem = original
        duplicateItem.skin[0].items.append(duplicateItem.skin[0].items[1])
        XCTAssertNil(OverlayItemPresentation.reference(in: duplicateItem, dimension: .tone, itemID: "chosen"))
        XCTAssertNil(resolve(reference, duplicateItem))
        var duplicateDimension = original
        duplicateDimension.skin.append(duplicateDimension.skin[0])
        XCTAssertNil(OverlayItemPresentation.reference(in: duplicateDimension, dimension: .tone, itemID: "chosen"))
        XCTAssertNil(resolve(reference, duplicateDimension))
    }

    func testMissingReferenceOriginalPhotoAndMissingSelectedLayerHaveNoObservationValue() throws {
        let report = fixture()
        let reference = try XCTUnwrap(OverlayItemPresentation.reference(in: report, dimension: .tone, itemID: "chosen"))
        XCTAssertNil(OverlayItemPresentation.resolvedItem(nil, in: report, selectedLayerID: "shared", showOverlay: true))
        XCTAssertNil(OverlayItemPresentation.resolvedItem(reference, in: report, selectedLayerID: "shared", showOverlay: false))
        XCTAssertNil(OverlayItemPresentation.resolvedItem(reference, in: report, selectedLayerID: nil, showOverlay: true))
        XCTAssertNil(OverlayItemPresentation.reference(in: report, dimension: .waterOil, itemID: "chosen"))
        XCTAssertNil(OverlayItemPresentation.reference(in: report, dimension: .tone, itemID: "missing"))
    }

    func testSwitchingLayerCannotShowThePreviousItemOrInferAnItemForGenericLayerEntry() throws {
        let report = fixture()
        let reference = try XCTUnwrap(OverlayItemPresentation.reference(in: report, dimension: .tone, itemID: "chosen"))
        XCTAssertNotNil(resolve(reference, report))
        XCTAssertNil(OverlayItemPresentation.resolvedItem(reference, in: report, selectedLayerID: "other", showOverlay: true))
        XCTAssertNil(OverlayItemPresentation.resolvedItem(nil, in: report, selectedLayerID: "other", showOverlay: true))
        XCTAssertNil(OverlayItemPresentation.resolvedItem(nil, in: report, selectedLayerID: "shared", showOverlay: true),
                     "Returning through the generic layer strip must not choose a first same-layer item.")
    }

    func testMissingAmbiguousAndAbsentOverlayBindingsDoNotProduceContext() throws {
        let report = fixture()
        let reference = try XCTUnwrap(OverlayItemPresentation.reference(in: report, dimension: .tone, itemID: "chosen"))
        var missing = report
        missing.overlays.removeAll { $0.id == "shared" }
        XCTAssertNil(OverlayItemPresentation.reference(in: missing, dimension: .tone, itemID: "chosen"))
        XCTAssertNil(resolve(reference, missing))
        var duplicate = report
        duplicate.overlays.append(duplicate.overlays[0])
        XCTAssertNil(OverlayItemPresentation.reference(in: duplicate, dimension: .tone, itemID: "chosen"))
        XCTAssertNil(resolve(reference, duplicate))
        var unbound = report
        unbound.skin[0].items[1].overlayID = nil
        XCTAssertNil(OverlayItemPresentation.reference(in: unbound, dimension: .tone, itemID: "chosen"))
        XCTAssertNil(resolve(reference, unbound))
    }

    func testObsoleteReportItemAndChangedLayerLinkDoNotLeakStaleValues() throws {
        let original = fixture()
        let reference = try XCTUnwrap(OverlayItemPresentation.reference(in: original, dimension: .tone, itemID: "chosen"))
        var otherReport = original
        otherReport.id = "different-report"
        XCTAssertNil(resolve(reference, otherReport))
        var removed = original
        removed.skin[0].items.removeAll { $0.id == "chosen" }
        XCTAssertNil(resolve(reference, removed))
        var relinked = original
        relinked.skin[0].items[1].overlayID = "other"
        XCTAssertNil(resolve(reference, relinked))
        XCTAssertNil(OverlayItemPresentation.resolvedItem(reference, in: relinked, selectedLayerID: "other", showOverlay: true))
    }

    func testBlankSourceFieldsAbstainWithoutSubstitutingScoresOrNeighborValues() {
        for blank in ["", " \n\t"] {
            for field in ["title", "value", "reportID", "itemID", "overlayID"] {
                var report = fixture()
                if field == "title" { report.skin[0].items[1].title = blank }
                if field == "value" { report.skin[0].items[1].valueText = blank }
                if field == "reportID" { report.id = blank }
                if field == "itemID" { report.skin[0].items[1].id = blank }
                if field == "overlayID" {
                    report.skin[0].items[1].overlayID = blank
                    report.overlays[0].id = blank
                }
                let itemID = field == "itemID" ? blank : "chosen"
                XCTAssertNil(OverlayItemPresentation.reference(in: report, dimension: .tone, itemID: itemID), field)
            }
        }
    }

    func testResolutionReadsCurrentUnmodifiedSourceAndNeverMutatesReport() throws {
        var report = fixture()
        let reference = try XCTUnwrap(OverlayItemPresentation.reference(in: report, dimension: .tone, itemID: "chosen"))
        report.skin[0].items[1].valueText = "现有报告更新后的合成原值"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(report)
        XCTAssertEqual(resolve(reference, report)?.valueText, "现有报告更新后的合成原值")
        XCTAssertEqual(try encoder.encode(report), before)
    }

    private func resolve(_ reference: OverlayItemReference, _ report: AnalysisReport) -> SkinItem? {
        OverlayItemPresentation.resolvedItem(reference, in: report, selectedLayerID: "shared", showOverlay: true)
    }

    private func fixture() -> AnalysisReport {
        var report = SampleData.report
        report.id = "overlay-item-resolution-synthetic"
        report.skin = [SkinMetric(dimension: .tone, score: nil, status: "纯解析合成测试",
            items: [
                SkinItem(id: "first", title: "合成基线", valueText: "合成基线 A", note: "", overlayID: "shared"),
                SkinItem(id: "chosen", title: "合成眼下明暗记录", valueText: " 3.1 L* · 合成测试原文 ",
                         note: "只作解析测试，不是检测结果。", overlayID: "shared"),
                SkinItem(id: "other", title: "另一合成图层项目", valueText: "合成原值 B", note: "", overlayID: "other")
            ])]
        report.overlays = [
            OverlayLayer(id: "shared", title: "多项共用合成图层", colorHex: "8677B9", kind: .polygons,
                         paths: [], note: "合成层说明", source: "unit-test-synthetic"),
            OverlayLayer(id: "other", title: "另一合成图层", colorHex: "8677B9", kind: .polygons,
                         paths: [], note: "合成层说明", source: "unit-test-synthetic")
        ]
        return report
    }
}
