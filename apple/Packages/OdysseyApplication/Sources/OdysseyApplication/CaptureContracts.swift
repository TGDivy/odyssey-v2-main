import Foundation
import OdysseyDomain

public enum CaptureContractError: Error, Equatable, Sendable {
    case emptyPayload
    case payloadTooLarge(maximumBytes: Int)
    case invalidContext(String)
    case invalidAttachment(String)
    case invalidInterpretation(String)
}

extension CaptureContractError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyPayload:
            "A capture cannot be empty."
        case let .payloadTooLarge(maximumBytes):
            "The capture exceeds the local \(maximumBytes)-byte limit."
        case let .invalidContext(field):
            "The capture has invalid \(field)."
        case let .invalidAttachment(field):
            "A capture attachment has invalid \(field)."
        case let .invalidInterpretation(field):
            "A capture interpretation has invalid \(field)."
        }
    }
}

public enum CapturePayloadKind: String, Codable, CaseIterable, Hashable, Sendable {
    case text
    case audio
    case imageReference = "image_ref"
    case fileReference = "file_ref"
    case structuredQuickAction = "structured_quick_action"
}

public enum CaptureLocationPermissionState: String, Codable, CaseIterable, Hashable, Sendable {
    case notDetermined = "not_determined"
    case restricted
    case denied
    case authorizedWhenInUse = "authorized_when_in_use"
    case authorizedAlways = "authorized_always"
    case unavailable
}

public enum CaptureInterpretationStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case pending
    case processing
    case needsClarification = "needs_clarification"
    case interpreted
    case failed
}

public struct CaptureInvokingSurface: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard (1 ... 100).contains(rawValue.count),
              rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines),
              rawValue.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics
                      .union(CharacterSet(charactersIn: "._-"))
                      .contains($0)
              })
        else {
            return nil
        }
        self.rawValue = rawValue
    }

    public static let iPhoneNow = Self(rawValue: "iphone.now")!
    public static let iPhoneGlobalCapture = Self(rawValue: "iphone.global_capture")!
    public static let watchQuickAction = Self(rawValue: "watch.quick_action")!
    public static let shareExtension = Self(rawValue: "share_extension")!
    public static let appIntent = Self(rawValue: "app_intent")!
    public static let mac = Self(rawValue: "mac")!

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let value = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid capture invoking surface."
            )
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct CaptureAttachmentReference: Codable, Hashable, Sendable {
    public let attachmentID: UUIDv7
    public let kind: CapturePayloadKind
    public let objectRef: String
    public let contentHash: String

    public init(
        attachmentID: UUIDv7 = UUIDv7(),
        kind: CapturePayloadKind,
        objectRef: String,
        contentHash: String
    ) throws {
        guard kind == .audio || kind == .imageReference || kind == .fileReference else {
            throw CaptureContractError.invalidAttachment("kind")
        }
        guard (1 ... 2_048).contains(objectRef.count),
              objectRef == objectRef.trimmingCharacters(in: .whitespacesAndNewlines),
              !objectRef.unicodeScalars.contains(where: { $0.value == 0 })
        else {
            throw CaptureContractError.invalidAttachment("object reference")
        }
        guard Self.isSHA256(contentHash) else {
            throw CaptureContractError.invalidAttachment("content hash")
        }
        self.attachmentID = attachmentID
        self.kind = kind
        self.objectRef = objectRef
        self.contentHash = contentHash
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy {
            (48 ... 57).contains($0) || (97 ... 102).contains($0)
        }
    }
}

public struct CaptureOriginalPayload: Codable, Hashable, Sendable {
    public let kind: CapturePayloadKind
    public let contentOrObjectRef: String
    public let contentHash: String

    public init(
        kind: CapturePayloadKind,
        contentOrObjectRef: String,
        contentHash: String
    ) {
        self.kind = kind
        self.contentOrObjectRef = contentOrObjectRef
        self.contentHash = contentHash
    }
}

public struct CaptureInitialContext: Codable, Hashable, Sendable {
    public let deviceID: UUIDv7
    public let timeZoneID: String
    public let locationPermissionState: CaptureLocationPermissionState
    public let broadLocation: String?
    public let invokingSurface: CaptureInvokingSurface

    public init(
        deviceID: UUIDv7,
        timeZoneID: String,
        locationPermissionState: CaptureLocationPermissionState,
        broadLocation: String?,
        invokingSurface: CaptureInvokingSurface
    ) {
        self.deviceID = deviceID
        self.timeZoneID = timeZoneID
        self.locationPermissionState = locationPermissionState
        self.broadLocation = broadLocation
        self.invokingSurface = invokingSurface
    }
}

public struct CaptureRecord: Codable, Hashable, Sendable {
    public let metadata: EntityMetadata
    public let capturedAt: Date
    public let originalPayload: CaptureOriginalPayload
    public let initialContext: CaptureInitialContext
    public let attachments: [CaptureAttachmentReference]
    public let interpretationStatus: CaptureInterpretationStatus
    public let interpretationVersions: [CaptureInterpretationVersion]

    public init(
        metadata: EntityMetadata,
        capturedAt: Date,
        originalPayload: CaptureOriginalPayload,
        initialContext: CaptureInitialContext,
        attachments: [CaptureAttachmentReference],
        interpretationStatus: CaptureInterpretationStatus,
        interpretationVersions: [CaptureInterpretationVersion]
    ) {
        self.metadata = metadata
        self.capturedAt = capturedAt
        self.originalPayload = originalPayload
        self.initialContext = initialContext
        self.attachments = attachments
        self.interpretationStatus = interpretationStatus
        self.interpretationVersions = interpretationVersions
    }
}

public struct ManualCaptureDraft: Hashable, Sendable {
    public static let maximumPayloadBytes = 240 * 1_024
    public static let maximumAttachmentCount = 16

    public let kind: CapturePayloadKind
    public let contentOrObjectReference: String
    public let timeZoneID: String
    public let locationPermissionState: CaptureLocationPermissionState
    public let broadLocation: String?
    public let invokingSurface: CaptureInvokingSurface
    public let attachments: [CaptureAttachmentReference]
    public let sensitivity: DataClass

    public init(
        kind: CapturePayloadKind,
        contentOrObjectReference: String,
        timeZoneID: String,
        locationPermissionState: CaptureLocationPermissionState,
        broadLocation: String? = nil,
        invokingSurface: CaptureInvokingSurface,
        attachments: [CaptureAttachmentReference] = [],
        sensitivity: DataClass = .private
    ) throws {
        guard !contentOrObjectReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !contentOrObjectReference.unicodeScalars.contains(where: { $0.value == 0 })
        else {
            throw CaptureContractError.emptyPayload
        }
        let payloadSize = contentOrObjectReference.lengthOfBytes(using: .utf8)
        guard payloadSize <= Self.maximumPayloadBytes else {
            throw CaptureContractError.payloadTooLarge(maximumBytes: Self.maximumPayloadBytes)
        }
        guard TimeZone(identifier: timeZoneID) != nil else {
            throw CaptureContractError.invalidContext("timezone")
        }
        if let broadLocation {
            guard (1 ... 100).contains(broadLocation.count),
                  broadLocation == broadLocation.trimmingCharacters(in: .whitespacesAndNewlines)
            else {
                throw CaptureContractError.invalidContext("broad location")
            }
        }
        guard attachments.count <= Self.maximumAttachmentCount,
              Set(attachments.map(\.attachmentID)).count == attachments.count
        else {
            throw CaptureContractError.invalidAttachment("count or identity")
        }
        guard sensitivity != .operationalSecret else {
            throw CaptureContractError.invalidContext("sensitivity")
        }
        self.kind = kind
        self.contentOrObjectReference = contentOrObjectReference
        self.timeZoneID = timeZoneID
        self.locationPermissionState = locationPermissionState
        self.broadLocation = broadLocation
        self.invokingSurface = invokingSurface
        self.attachments = attachments
        self.sensitivity = sensitivity
    }

    public static func text(
        _ text: String,
        timeZoneID: String,
        locationPermissionState: CaptureLocationPermissionState,
        broadLocation: String? = nil,
        invokingSurface: CaptureInvokingSurface,
        sensitivity: DataClass = .private
    ) throws -> Self {
        try Self(
            kind: .text,
            contentOrObjectReference: text,
            timeZoneID: timeZoneID,
            locationPermissionState: locationPermissionState,
            broadLocation: broadLocation,
            invokingSurface: invokingSurface,
            sensitivity: sensitivity
        )
    }
}
