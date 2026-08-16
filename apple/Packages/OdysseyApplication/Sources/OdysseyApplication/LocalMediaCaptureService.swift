import Foundation
import OdysseyDomain

public enum LocalMediaCaptureSource: Hashable, Sendable {
    case file(URL)
    case data(Data)
}

public struct LocalMediaCaptureDraft: Hashable, Sendable {
    public let source: LocalMediaCaptureSource
    public let kind: CapturePayloadKind
    public let mediaType: String
    public let timeZoneID: String
    public let locationPermissionState: CaptureLocationPermissionState
    public let broadLocation: String?
    public let invokingSurface: CaptureInvokingSurface
    public let sensitivity: DataClass

    public init(
        source: LocalMediaCaptureSource,
        kind: CapturePayloadKind,
        mediaType: String,
        timeZoneID: String,
        locationPermissionState: CaptureLocationPermissionState,
        broadLocation: String? = nil,
        invokingSurface: CaptureInvokingSurface,
        sensitivity: DataClass = .private
    ) throws {
        guard kind == .audio || kind == .imageReference || kind == .fileReference else {
            throw LocalCaptureAttachmentError.unsupportedKind
        }
        guard TimeZone(identifier: timeZoneID) != nil else {
            throw CaptureContractError.invalidContext("timezone")
        }
        if let broadLocation {
            guard (1 ... 100).contains(broadLocation.count),
                  broadLocation == broadLocation.trimmingCharacters(
                      in: .whitespacesAndNewlines
                  )
            else {
                throw CaptureContractError.invalidContext("broad location")
            }
        }
        guard sensitivity != .operationalSecret else {
            throw CaptureContractError.invalidContext("sensitivity")
        }
        self.source = source
        self.kind = kind
        self.mediaType = mediaType
        self.timeZoneID = timeZoneID
        self.locationPermissionState = locationPermissionState
        self.broadLocation = broadLocation
        self.invokingSurface = invokingSurface
        self.sensitivity = sensitivity
    }
}

public enum LocalMediaCaptureFinalizationState: String, Codable, Hashable, Sendable {
    case committed
    case recoveryRequired = "recovery_required"
}

public struct LocalMediaCaptureReceipt: Hashable, Sendable {
    public let captureReceipt: ManualCaptureReceipt
    public let attachment: LocalCaptureAttachmentManifest
    public let finalizationState: LocalMediaCaptureFinalizationState

    public init(
        captureReceipt: ManualCaptureReceipt,
        attachment: LocalCaptureAttachmentManifest,
        finalizationState: LocalMediaCaptureFinalizationState
    ) {
        self.captureReceipt = captureReceipt
        self.attachment = attachment
        self.finalizationState = finalizationState
    }
}

public actor LocalMediaCaptureService {
    private let attachmentStore: LocalCaptureAttachmentStore
    private let captureService: ManualCaptureService

    public init(
        attachmentStore: LocalCaptureAttachmentStore,
        captureService: ManualCaptureService
    ) {
        self.attachmentStore = attachmentStore
        self.captureService = captureService
    }

    public func record(_ draft: LocalMediaCaptureDraft) async throws
        -> LocalMediaCaptureReceipt
    {
        let staged: LocalCaptureAttachmentManifest
        switch draft.source {
        case let .file(sourceURL):
            staged = try await attachmentStore.stageFile(
                at: sourceURL,
                kind: draft.kind,
                mediaType: draft.mediaType,
                sensitivity: draft.sensitivity
            )
        case let .data(data):
            staged = try await attachmentStore.stageData(
                data,
                kind: draft.kind,
                mediaType: draft.mediaType,
                sensitivity: draft.sensitivity
            )
        }

        let captureReceipt: ManualCaptureReceipt
        do {
            let reference = try staged.captureReference
            captureReceipt = try await captureService.record(ManualCaptureDraft(
                kind: draft.kind,
                contentOrObjectReference: staged.objectReference,
                timeZoneID: draft.timeZoneID,
                locationPermissionState: draft.locationPermissionState,
                broadLocation: draft.broadLocation,
                invokingSurface: draft.invokingSurface,
                attachments: [reference],
                sensitivity: draft.sensitivity
            ))
        } catch {
            try? await attachmentStore.discardStaged(staged.attachmentID)
            throw error
        }

        do {
            let committed = try await attachmentStore.markCommitted(staged.attachmentID)
            return LocalMediaCaptureReceipt(
                captureReceipt: captureReceipt,
                attachment: committed,
                finalizationState: .committed
            )
        } catch {
            return LocalMediaCaptureReceipt(
                captureReceipt: captureReceipt,
                attachment: staged,
                finalizationState: .recoveryRequired
            )
        }
    }
}
