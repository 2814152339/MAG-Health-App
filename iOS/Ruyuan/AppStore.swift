import SwiftUI
import UIKit

private struct PendingAnalysis: Codable {
    var key: String
    var imageFileName: String
    var serverURL: String
    var assetID: String?
    var consentID: String?
    var jobID: String?
    var cancelRequested: Bool = false
    var assessment: SkinSelfAssessment? = nil
}

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var reports: [AnalysisReport] = []
    @Published var activeReport: AnalysisReport?
    @Published var isAnalyzing = false
    @Published var showsAnalysis = false
    @Published var analysisImage: UIImage?
    @Published var scanReport: AnalysisReport?
    @Published var analysisStartedAt = Date()
    @Published var stage: AnalysisStage = .preparing
    @Published var errorMessage: String?
    @Published var hasConsent: Bool
    @Published var serverEnabled: Bool
    @Published var serverURL: String
    @Published var serverToken: String
    @Published private(set) var isDeleting = false
    @Published private(set) var isCancelling = false
    private let root: URL
    private let photos: URL
    private let defaults = UserDefaults.standard
    private var analysisTask: Task<Void, Never>?
    private var runID: UUID?
    private var pending: PendingAnalysis?
    private var deletingIDs = Set<String>()
    private var completedReport: AnalysisReport?

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = base.appendingPathComponent("Ruyuan", isDirectory: true)
        photos = root.appendingPathComponent("Photos", isDirectory: true)
        hasConsent = UserDefaults.standard.bool(forKey: "consent.v1")
        serverEnabled = UserDefaults.standard.bool(forKey: "server.enabled")
        serverURL = UserDefaults.standard.string(forKey: "server.url") ?? ""
        serverToken = KeychainStore.read()
        do {
            try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
            var excluded = URLResourceValues()
            excluded.isExcludedFromBackup = true
            var rootURL = root
            try rootURL.setResourceValues(excluded)
            let index = root.appendingPathComponent("reports.json")
            if FileManager.default.fileExists(atPath: index.path) {
                do { reports = try JSONDecoder().decode([AnalysisReport].self, from: Data(contentsOf: index)) }
                catch {
                    let recovery = root.appendingPathComponent("reports-recovery-\(UUID().uuidString).json")
                    try FileManager.default.copyItem(at: index, to: recovery)
                    errorMessage = "报告索引读取失败，已保留恢复副本。请先导出设备备份再继续。"
                }
            }
            let pendingURL = root.appendingPathComponent("pending.json")
            if FileManager.default.fileExists(atPath: pendingURL.path) {
                pending = try JSONDecoder().decode(PendingAnalysis.self, from: Data(contentsOf: pendingURL))
            }
            reports.sort { $0.createdAt > $1.createdAt }
        } catch { errorMessage = "本机资料读取失败：\(error.localizedDescription)" }
    }

    func acceptConsent() { hasConsent = true; defaults.set(true, forKey: "consent.v1") }

    @discardableResult
    func persistSettings() -> Bool {
        do {
            if serverEnabled { _ = try APIClient(url: serverURL, token: serverToken) }
            if let pending, pending.serverURL != serverURL {
                throw AnalysisError.network("还有未结束的服务端任务。请先恢复或取消，再更换地址。")
            }
            try KeychainStore.write(serverToken)
            defaults.set(serverEnabled, forKey: "server.enabled")
            defaults.set(serverURL, forKey: "server.url")
            return true
        } catch {
            serverEnabled = defaults.bool(forKey: "server.enabled")
            serverURL = defaults.string(forKey: "server.url") ?? ""
            serverToken = KeychainStore.read()
            errorMessage = error.localizedDescription
            return false
        }
    }

    func image(for report: AnalysisReport) -> UIImage? {
        guard !report.imageFileName.isEmpty, URL(fileURLWithPath: report.imageFileName).lastPathComponent == report.imageFileName else { return nil }
        return UIImage(contentsOfFile: photos.appendingPathComponent(report.imageFileName).path)
    }

    func analyze(image: UIImage, assessment: SkinSelfAssessment? = nil,
                 depth: DepthSnapshot? = nil, depthNotice: String? = nil) async {
        guard !isAnalyzing, !isDeleting, !isCancelling else { return }
        guard hasConsent else { errorMessage = "请先同意照片处理说明。"; return }
        guard pending == nil else {
            errorMessage = "有一项待恢复的服务端分析，请先在首页恢复或取消。"
            return
        }
        let run = UUID()
        runID = run
        isAnalyzing = true
        showsAnalysis = true
        analysisImage = image
        scanReport = nil
        analysisStartedAt = Date()
        stage = .preparing
        let filename = UUID().uuidString + ".jpg"
        let destination = photos.appendingPathComponent(filename)
        // Match the original camera pixels before upright isotropic preprocessing.
        // Never persist/upload depth; interrupted remote jobs resume as ordinary 2D.
        let trustedDepth = depth?.matches(image: image) == true ? depth : nil
        let trustedDepthNotice = depth != nil && trustedDepth == nil
            ? "同拍深度与照片绑定校验失败，按二维照片分析。" : depthNotice
        analysisTask = Task { [weak self] in
            guard let self else { return }
            do {
                let prepared = try await ImagePreprocessor.prepare(image)
                self.analysisImage = prepared.image
                try Task.checkCancellation()
                try prepared.data.write(to: destination, options: [.atomic, .completeFileProtection])
                try Task.checkCancellation()
                var report: AnalysisReport
                if self.serverEnabled {
                    _ = try APIClient(url: self.serverURL, token: self.serverToken)
                    self.pending = PendingAnalysis(key: UUID().uuidString, imageFileName: filename, serverURL: self.serverURL, assessment: assessment)
                    try self.savePending()
                    report = try await self.performRemote(data: prepared.data, run: run)
                } else {
                    report = try await LocalAnalyzer.analyze(image: prepared.image, reportID: UUID().uuidString,
                                                           imageFileName: filename, depth: trustedDepth,
                                                           depthNotice: trustedDepthNotice) { [weak self] stage in
                        Task { @MainActor in if self?.runID == run { self?.stage = stage } }
                    }
                }
                try Task.checkCancellation()
                guard self.runID == run else { return }
                if let assessment { report = assessment.applying(to: report) }
                try self.commit(report)
                self.pending = nil
                try self.savePending()
                self.finish(report: report, run: run)
            } catch {
                if self.pending == nil && !self.reports.contains(where: { $0.imageFileName == filename }) {
                    try? FileManager.default.removeItem(at: destination)
                }
                guard self.runID == run else { return }
                self.isAnalyzing = false
                self.showsAnalysis = false
                self.runID = nil
                if !(error is CancellationError) {
                    self.errorMessage = error.localizedDescription + (self.pending == nil ? "" : "\n任务已保留，可在首页恢复；不必重新上传。")
                }
            }
        }
        await analysisTask?.value
    }

    var hasPendingAnalysis: Bool { pending != nil }

    func resumePendingAnalysis() async {
        guard !isAnalyzing, !isDeleting, !isCancelling, let saved = pending else { return }
        guard !serverToken.isEmpty else { errorMessage = "请先在设置中恢复服务端令牌，再继续待处理任务。"; return }
        let run = UUID()
        runID = run
        isAnalyzing = true
        showsAnalysis = true
        analysisImage = UIImage(contentsOfFile: photos.appendingPathComponent(saved.imageFileName).path)
        scanReport = nil
        analysisStartedAt = Date()
        stage = .preparing
        analysisTask = Task { [weak self] in
            guard let self else { return }
            do {
                if saved.cancelRequested {
                    try await self.cleanupRemote(saved)
                    try self.removeFileIfPresent(self.photos.appendingPathComponent(saved.imageFileName))
                    self.pending = nil
                    try self.savePending()
                    self.isAnalyzing = false
                    self.showsAnalysis = false
                    self.runID = nil
                    return
                }
                let data = try Data(contentsOf: self.photos.appendingPathComponent(saved.imageFileName))
                var report = try await self.performRemote(data: data, run: run)
                if let assessment = saved.assessment { report = assessment.applying(to: report) }
                try Task.checkCancellation()
                guard self.runID == run else { return }
                try self.commit(report)
                self.pending = nil
                try self.savePending()
                self.finish(report: report, run: run)
            } catch {
                guard self.runID == run else { return }
                self.isAnalyzing = false
                self.showsAnalysis = false
                self.runID = nil
                if !(error is CancellationError) { self.errorMessage = "任务尚未完成：\(error.localizedDescription)" }
            }
        }
        await analysisTask?.value
    }

    private func performRemote(data: Data, run: UUID) async throws -> AnalysisReport {
        guard var saved = pending else { throw AnalysisError.network("找不到待处理任务。") }
        let client = try APIClient(url: saved.serverURL, token: serverToken)
        if saved.consentID == nil {
            saved.consentID = try await client.consent()
            saved.cancelRequested = pending?.cancelRequested ?? saved.cancelRequested
            pending = saved; try savePending()
        }
        try Task.checkCancellation()
        if saved.assetID == nil {
            saved.assetID = try await client.upload(data, key: saved.key)
            saved.cancelRequested = pending?.cancelRequested ?? saved.cancelRequested
            pending = saved; try savePending()
        }
        try Task.checkCancellation()
        if saved.jobID == nil {
            let job = try await client.create(asset: saved.assetID!, consent: saved.consentID!, key: saved.key)
            saved.jobID = job.id
            saved.cancelRequested = pending?.cancelRequested ?? saved.cancelRequested
            pending = saved; try savePending()
        }
        // Polling is foreground-only. The durable task ID survives termination/backgrounding.
        for _ in 0..<300 {
            try Task.checkCancellation()
            let job = try await client.job(saved.jobID!)
            if runID != run { throw CancellationError() }
            stage = Self.mapStage(job.stage)
            if ["ready", "partial", "completed"].contains(job.status) {
                guard let id = job.reportId else { throw AnalysisError.network("报告尚未生成。") }
                var report = try await client.report(id)
                report.imageFileName = saved.imageFileName
                report.origin = .server
                return report
            }
            if ["failed", "rejected", "cancelled"].contains(job.status) {
                throw AnalysisError.network(job.error ?? "任务未能完成，请取消后重新拍摄。")
            }
            try await Task.sleep(for: .seconds(2))
        }
        throw AnalysisError.network("本次等待结束，服务端任务仍可恢复查询。")
    }

    private static func mapStage(_ value: String) -> AnalysisStage {
        switch value {
        case "quality_checking": return .quality
        case "geometry": return .geometry
        case "skin_models": return .skin
        case "scoring", "report_render", "ready": return .report
        default: return .preparing
        }
    }

    func cancelAnalysis() {
        guard !isCancelling, !isDeleting else { return }
        if !isAnalyzing, completedReport != nil { finishScanPresentation(); return }
        isCancelling = true
        isAnalyzing = true
        completedReport = nil
        let previous = analysisTask
        analysisTask?.cancel()
        runID = nil
        if pending != nil {
            pending?.cancelRequested = true
            do { try savePending() } catch { errorMessage = error.localizedDescription }
        }
        // Drain the old task before deleting images or clearing its pending receipt.
        // The operation-key tombstone also blocks an upload still executing on the server.
        Task {
            await previous?.value
            do {
                if let saved = pending {
                    try await cleanupRemote(saved)
                    try removeFileIfPresent(photos.appendingPathComponent(saved.imageFileName))
                    pending = nil
                    try savePending()
                }
            } catch {
                pending?.cancelRequested = true
                try? savePending()
                errorMessage = "取消尚未得到服务端确认，已保留待处理记录：\(error.localizedDescription)"
            }
            isCancelling = false
            isAnalyzing = false
            showsAnalysis = false
            scanReport = nil
            analysisImage = nil
        }
    }

    private func cleanupRemote(_ saved: PendingAnalysis) async throws {
        let client = try APIClient(url: saved.serverURL, token: serverToken)
        try await client.deleteOperation(saved.key)
    }

    private func commit(_ report: AnalysisReport) throws {
        try ReportValidator.validate(report)
        var next = reports.filter { $0.id != report.id }
        next.append(report)
        next.sort { $0.createdAt > $1.createdAt }
        try JSONEncoder().encode(next).write(to: root.appendingPathComponent("reports.json"), options: [.atomic, .completeFileProtection])
        reports = next
        if report.origin == .server, let saved = pending {
            defaults.set(saved.serverURL, forKey: "server.report.\(report.id)")
        }
    }

    private func savePending() throws {
        let url = root.appendingPathComponent("pending.json")
        if let pending {
            try JSONEncoder().encode(pending).write(to: url, options: [.atomic, .completeFileProtection])
        } else if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        objectWillChange.send()
    }

    private func finish(report: AnalysisReport, run: UUID) {
        guard runID == run else { return }
        isAnalyzing = false
        runID = nil
        completedReport = report
        scanReport = report
    }

    func saveCalibratedReport(_ report: AnalysisReport) throws {
        guard !isAnalyzing, !isDeleting, !isCancelling, reports.contains(where: { $0.id == report.id }) else {
            throw AnalysisError.poorQuality("请先完成本次分析后再保存标定；演示数据不保存。")
        }
        try commit(report)
        if activeReport?.id == report.id { activeReport = report }
    }

    func finishScanPresentation() {
        guard !isAnalyzing, scanReport != nil else { return }
        showsAnalysis = false
    }

    func presentCompletedReport() {
        guard !isAnalyzing, let report = completedReport else { return }
        completedReport = nil
        activeReport = report
        scanReport = nil
        analysisImage = nil
    }

    func showSample() { activeReport = SampleData.report }

    #if DEBUG
    /// UI-only fixture: explicitly synthetic, never saved as a user's analysis.
    func beginUITestScan() {
        guard ProcessInfo.processInfo.arguments.contains("--ui-test-scan"),
              !isAnalyzing, pending == nil else { return }
        let report = SampleData.scannerReport
        analysisImage = nil
        scanReport = report
        completedReport = report
        analysisStartedAt = Date()
        stage = .preparing
        showsAnalysis = true
    }
    #endif

    func delete(_ report: AnalysisReport) {
        guard !isDeleting, !isAnalyzing, !isCancelling, !deletingIDs.contains(report.id) else { return }
        isDeleting = true
        deletingIDs.insert(report.id)
        Task {
            defer { deletingIDs.remove(report.id); isDeleting = false }
            do { try await remove(report) } catch { errorMessage = "删除未完成：\(error.localizedDescription)" }
        }
    }

    private func remove(_ report: AnalysisReport) async throws {
        if report.origin == .server {
            guard let url = defaults.string(forKey: "server.report.\(report.id)") else {
                throw AnalysisError.network("缺少原服务端地址，暂未删除该报告。")
            }
            try await APIClient(url: url, token: serverToken).deleteReport(report.id)
        }
        // Keep the report as a retry target if sensitive-file cleanup fails.
        if !report.imageFileName.isEmpty { try removeFileIfPresent(photos.appendingPathComponent(report.imageFileName)) }
        let export = FileManager.default.temporaryDirectory.appendingPathComponent("RuyuanExports")
            .appendingPathComponent("如愿美学-\(report.id).pdf")
        try removeFileIfPresent(export)
        let next = reports.filter { $0.id != report.id }
        try JSONEncoder().encode(next).write(to: root.appendingPathComponent("reports.json"), options: [.atomic, .completeFileProtection])
        reports = next
        defaults.removeObject(forKey: "server.report.\(report.id)")
        defaults.removeObject(forKey: "report.feedback.v1.\(report.id)")
    }

    func deleteAll() {
        guard !isAnalyzing, !isDeleting, !isCancelling else { errorMessage = "请先等待当前操作结束，或取消分析任务。"; return }
        isDeleting = true
        Task {
            defer { isDeleting = false }
            do {
                if let pending {
                    try await cleanupRemote(pending)
                    try removeFileIfPresent(photos.appendingPathComponent(pending.imageFileName))
                    self.pending = nil
                    try savePending()
                }
                for report in reports { try await remove(report) }
                let files = try FileManager.default.contentsOfDirectory(at: photos, includingPropertiesForKeys: nil)
                for file in files { try FileManager.default.removeItem(at: file) }
                let exports = FileManager.default.temporaryDirectory.appendingPathComponent("RuyuanExports")
                if FileManager.default.fileExists(atPath: exports.path) { try FileManager.default.removeItem(at: exports) }
                hasConsent = false
                defaults.set(false, forKey: "consent.v1")
            } catch { errorMessage = "清除未完成，未删除的报告仍保留：\(error.localizedDescription)" }
        }
    }

    func exportPDF(_ report: AnalysisReport) throws -> URL { try PDFExporter.export(report: report, image: image(for: report)) }

    private func removeFileIfPresent(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}
