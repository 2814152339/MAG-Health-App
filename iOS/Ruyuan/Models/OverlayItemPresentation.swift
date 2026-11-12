import Foundation

/// Exact report-card identity carried into a layer viewer. A layer alone cannot
/// identify an observation: several items may legitimately share the same mask.
struct OverlayItemReference: Equatable, Sendable {
    let reportID: String
    let dimension: SkinDimension
    let itemID: String
    let overlayID: String
}

/// Resolves existing report text only. Never calculates scores or infers a skin
/// item from the first record that happens to reference the displayed layer.
enum OverlayItemPresentation {
    static func reference(in report: AnalysisReport, dimension: SkinDimension,
                          itemID: String) -> OverlayItemReference? {
        let metrics = report.skin.filter { $0.dimension == dimension }
        guard metrics.count == 1, let metric = metrics.first else { return nil }
        let items = metric.items.filter { $0.id == itemID }
        guard items.count == 1, let item = items.first, let overlayID = item.overlayID else { return nil }
        let reference = OverlayItemReference(reportID: report.id, dimension: dimension,
                                             itemID: itemID, overlayID: overlayID)
        guard resolvedItem(reference, in: report, selectedLayerID: overlayID, showOverlay: true) != nil else { return nil }
        return reference
    }

    /// Resolve again against the current report and viewer selection. Nil, a
    /// different report/layer, original-photo mode, duplicate identities, missing
    /// text, or an obsolete overlay binding all abstain instead of showing stale
    /// values. Returned text is the original valueText, including units/wording.
    static func resolvedItem(_ reference: OverlayItemReference?, in report: AnalysisReport,
                             selectedLayerID: String?, showOverlay: Bool) -> SkinItem? {
        guard showOverlay, let reference, reference.reportID == report.id,
              hasText(reference.reportID), hasText(reference.itemID), hasText(reference.overlayID),
              selectedLayerID == reference.overlayID,
              report.overlays.filter({ $0.id == reference.overlayID }).count == 1 else { return nil }
        let metrics = report.skin.filter { $0.dimension == reference.dimension }
        guard metrics.count == 1, let metric = metrics.first else { return nil }
        let items = metric.items.filter { $0.id == reference.itemID }
        guard items.count == 1, let item = items.first,
              item.overlayID == reference.overlayID, hasText(item.title), hasText(item.valueText) else { return nil }
        return item
    }

    private static func hasText(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
