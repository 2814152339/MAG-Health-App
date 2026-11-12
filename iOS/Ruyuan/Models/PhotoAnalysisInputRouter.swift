import Foundation
import UIKit

/// A single in-memory photo request. Neither the router nor its questionnaire
/// persists, uploads, crops, or re-encodes the photo or its same-capture depth.
struct PhotoAnalysisInput {
    let image: UIImage
    let depth: DepthSnapshot?
    let depthNotice: String?
    let assessment: SkinSelfAssessment?
}

/// The production intake state machine shared by camera and library dismissal.
/// Consume and clear synchronously before starting any asynchronous analysis.
struct PhotoAnalysisInputRouter {
    static let assessmentPreferenceKey = "ruyuan.capture.requestSkinAssessment.v1"

    enum Decision {
        case wait
        case showAssessment
        case analyze(PhotoAnalysisInput)
    }

    private enum Phase: Equatable { case empty, photo, assessment, assessmentReady }
    private var phase: Phase = .empty
    private var pending: PhotoAnalysisInput?
    var hasPendingInput: Bool { pending != nil }

    /// The caller supplies only CameraCapture.validatedDepth(), or nil for an
    /// imported image. Replacing a photo always discards the prior answers.
    mutating func receive(image: UIImage, depth: DepthSnapshot?, depthNotice: String?) {
        pending = PhotoAnalysisInput(image: image, depth: depth, depthNotice: depthNotice, assessment: nil)
        phase = .photo
    }

    /// PHPicker's successful nil image means cancel, not an analysis input.
    mutating func receiveImportedImage(_ image: UIImage?) {
        guard let image else { cancel(); return }
        receive(image: image, depth: nil,
                depthNotice: "本次为相册照片，未携带受信同次 TrueDepth 深度；按二维照片分析。")
    }

    mutating func afterPhotoDismissal(cameraPresented: Bool, pickerPresented: Bool,
                                     requestsAssessment: Bool = false) -> Decision {
        guard !cameraPresented, !pickerPresented, phase == .photo, pending != nil else { return .wait }
        if requestsAssessment {
            phase = .assessment
            return .showAssessment
        }
        guard let input = takeInput() else { return .wait }
        return .analyze(input)
    }

    /// nil is the user's explicit "skip" choice, not a fabricated answer.
    @discardableResult
    mutating func completeAssessment(_ answer: SkinSelfAssessment?) -> Bool {
        guard phase == .assessment, let input = pending,
              answer?.isValid ?? true else { return false }
        pending = PhotoAnalysisInput(image: input.image, depth: input.depth,
            depthNotice: input.depthNotice, assessment: answer)
        phase = .assessmentReady
        return true
    }

    mutating func afterAssessmentDismissal() -> PhotoAnalysisInput? {
        guard phase == .assessmentReady else { return nil }
        return takeInput()
    }

    mutating func cancel() {
        pending = nil
        phase = .empty
    }

    private mutating func takeInput() -> PhotoAnalysisInput? {
        let input = pending
        cancel()
        return input
    }
}
