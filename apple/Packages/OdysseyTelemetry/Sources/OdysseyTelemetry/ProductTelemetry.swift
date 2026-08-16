import Foundation
import OdysseyDomain

public enum ProductTelemetryQuestionID: String, Codable, CaseIterable, Sendable {
    case captureFriction = "capture_friction_v1"
    case tomorrowMapValue = "tomorrow_map_value_v1"
}

public enum ProductTelemetryEventName: String, Codable, CaseIterable, Sendable {
    case captureWorkflowStarted = "capture.workflow_started.v1"
    case captureWorkflowFinished = "capture.workflow_finished.v1"
    case captureFeedbackRecorded = "capture.feedback_recorded.v1"
    case tomorrowMapAvailabilityEvaluated = "tomorrow_map.availability_evaluated.v1"
    case tomorrowMapViewed = "tomorrow_map.viewed.v1"
    case tomorrowMapSessionFinished = "tomorrow_map.session_finished.v1"
    case tomorrowMapFeedbackRecorded = "tomorrow_map.feedback_recorded.v1"
    case tomorrowMapPlanDeviationRecorded = "tomorrow_map.plan_deviation_recorded.v1"
}

public enum ProductTelemetryExpectedFrequency: String, Codable, Sendable {
    case habitual
    case dailyWhenRelevant = "daily_when_relevant"
}

public enum ProductTelemetryPropertyType: String, Codable, Sendable {
    case string
    case boolean
    case integer
    case number
}

public enum ProductTelemetryPropertyValue: Hashable, Sendable, Codable {
    case string(String)
    case boolean(Bool)
    case integer(Int)
    case number(Double)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .string(value):
            try container.encode(value)
        case let .boolean(value):
            try container.encode(value)
        case let .integer(value):
            try container.encode(value)
        case let .number(value):
            try container.encode(value)
        }
    }

    var propertyType: ProductTelemetryPropertyType {
        switch self {
        case .string: .string
        case .boolean: .boolean
        case .integer: .integer
        case .number: .number
        }
    }
}

public struct ProductTelemetryQuestionDefinition: Hashable, Sendable {
    public let questionID: ProductTelemetryQuestionID
    public let statement: String
    public let decisionUse: String
    public let expectedFrequency: ProductTelemetryExpectedFrequency
}

public struct ProductTelemetryPropertyDefinition: Hashable, Sendable {
    public let name: String
    public let propertyType: ProductTelemetryPropertyType
    public let required: Bool
    public let allowedValues: [String]
    public let minimum: Int?
    public let maximum: Int?

    public init(
        name: String,
        propertyType: ProductTelemetryPropertyType,
        required: Bool = true,
        allowedValues: [String] = [],
        minimum: Int? = nil,
        maximum: Int? = nil
    ) {
        self.name = name
        self.propertyType = propertyType
        self.required = required
        self.allowedValues = allowedValues
        self.minimum = minimum
        self.maximum = maximum
    }
}

public struct ProductTelemetryEventDefinition: Hashable, Sendable {
    public let eventName: ProductTelemetryEventName
    public let questionID: ProductTelemetryQuestionID
    public let owner: String
    public let purpose: String
    public let sensitivity: DataClass
    public let retentionDays: Int
    public let localOnlyByDefault: Bool
    public let properties: [ProductTelemetryPropertyDefinition]
}

public enum ProductTelemetryValidationError: Error, Equatable, Sendable {
    case invalidField(String)
    case unknownProperty(String)
    case missingProperty(String)
    case invalidProperty(String)
}

public enum ProductTelemetryRegistry {
    public static let version = 1

    public static let questions: [ProductTelemetryQuestionDefinition] = [
        ProductTelemetryQuestionDefinition(
            questionID: .captureFriction,
            statement: "Does capture remain fast and low-friction across supported inputs "
                + "without collecting captured content?",
            decisionUse: "Identify bounded workflow friction or abandonment without measuring "
                + "generic engagement.",
            expectedFrequency: .habitual
        ),
        ProductTelemetryQuestionDefinition(
            questionID: .tomorrowMapValue,
            statement: "Does the Tomorrow Map reduce uncertainty without becoming a nightly chore?",
            decisionUse: "Decide whether to preserve, refine, suppress, or remove the bounded map "
                + "surface.",
            expectedFrequency: .dailyWhenRelevant
        ),
    ]

    public static let events: [ProductTelemetryEventDefinition] = [
        event(
            .captureWorkflowStarted,
            question: .captureFriction,
            purpose: "Mark a payload-free capture attempt denominator.",
            properties: [
                string("capture_kind", captureKinds),
                string("invoking_surface", captureSurfaces),
            ]
        ),
        event(
            .captureWorkflowFinished,
            question: .captureFriction,
            purpose: "Measure bounded capture completion, failure, or abandonment friction.",
            properties: [
                string("capture_kind", captureKinds),
                string("invoking_surface", captureSurfaces),
                string("outcome", ["committed", "failed", "abandoned"]),
                string("exit_stage", ["entry", "selection", "saving", "local_commit"]),
                string("duration_bucket", durationBuckets),
            ]
        ),
        event(
            .captureFeedbackRecorded,
            question: .captureFriction,
            purpose: "Record situated usefulness or friction without capture payload.",
            properties: [
                string("rating", ["useful", "neutral", "added_friction"]),
                string(
                    "reason",
                    ["fast", "too_many_steps", "wrong_context", "bad_timing", "unclear", "other"],
                    required: false
                ),
            ]
        ),
        event(
            .tomorrowMapAvailabilityEvaluated,
            question: .tomorrowMapValue,
            purpose: "Distinguish automatic availability, degradation, and intentional absence.",
            properties: [
                string("calendar_state", calendarStates),
                boolean("intentionally_absent"),
                integer("transition_count", minimum: 0, maximum: 3),
                boolean("pressure_present"),
                boolean("protected_open_present"),
            ]
        ),
        event(
            .tomorrowMapViewed,
            question: .tomorrowMapValue,
            purpose: "Record a bounded map view and its entry point.",
            properties: [
                string("calendar_state", calendarStates),
                string("entry_point", ["automatic_now", "notification", "widget"]),
            ]
        ),
        event(
            .tomorrowMapSessionFinished,
            question: .tomorrowMapValue,
            purpose: "Measure bounded viewing effort without retaining navigation history.",
            properties: [
                string("duration_bucket", durationBuckets),
                string("outcome", ["dismissed", "feedback", "backgrounded"]),
            ]
        ),
        event(
            .tomorrowMapFeedbackRecorded,
            question: .tomorrowMapValue,
            purpose: "Record situated map usefulness or correction reason.",
            properties: [
                string("rating", ["useful", "not_useful", "added_friction"]),
                string(
                    "reason",
                    [
                        "wrong_context",
                        "bad_timing",
                        "already_handled",
                        "too_intrusive",
                        "reasoning_wrong",
                        "fact_wrong",
                        "preference_changed",
                        "show_less",
                        "other",
                    ],
                    required: false
                ),
            ]
        ),
        event(
            .tomorrowMapPlanDeviationRecorded,
            question: .tomorrowMapValue,
            purpose: "Capture a next-day deviation without recording plan content.",
            properties: [
                string("deviation", ["none", "minor", "material", "unknown"]),
                string("map_influence", ["helped", "no_effect", "added_burden", "uncertain"]),
            ]
        ),
    ]

    public static func definition(
        for eventName: ProductTelemetryEventName
    ) -> ProductTelemetryEventDefinition {
        eventsByName[eventName]!
    }

    public static func validate(
        eventName: ProductTelemetryEventName,
        properties: [String: ProductTelemetryPropertyValue]
    ) throws {
        let definitions = Dictionary(
            uniqueKeysWithValues: definition(for: eventName).properties.map { ($0.name, $0) }
        )
        if let unknown = Set(properties.keys).subtracting(definitions.keys).sorted().first {
            throw ProductTelemetryValidationError.unknownProperty(unknown)
        }
        if let missing = definitions.values
            .filter(\.required)
            .map(\.name)
            .filter({ properties[$0] == nil })
            .sorted()
            .first
        {
            throw ProductTelemetryValidationError.missingProperty(missing)
        }
        for (name, value) in properties {
            guard let propertyDefinition = definitions[name],
                  propertyDefinition.propertyType == value.propertyType
            else {
                throw ProductTelemetryValidationError.invalidProperty(name)
            }
            try validate(value, against: propertyDefinition)
        }
    }

    private static let captureKinds = ["text", "audio", "image_reference", "file_reference"]
    private static let captureSurfaces = [
        "iphone_now",
        "iphone_global_capture",
        "app_intent",
        "share",
        "widget",
        "watch",
        "control",
        "mac",
    ]
    private static let durationBuckets = [
        "under_1s",
        "1_to_3s",
        "3_to_5s",
        "5_to_10s",
        "10_to_30s",
        "30s_or_more",
    ]
    private static let calendarStates = ["fresh", "stale", "missing", "denied", "unavailable"]
    private static let eventsByName = Dictionary(
        uniqueKeysWithValues: events.map { ($0.eventName, $0) }
    )

    private static func event(
        _ eventName: ProductTelemetryEventName,
        question: ProductTelemetryQuestionID,
        purpose: String,
        properties: [ProductTelemetryPropertyDefinition]
    ) -> ProductTelemetryEventDefinition {
        ProductTelemetryEventDefinition(
            eventName: eventName,
            questionID: question,
            owner: "product_evaluation",
            purpose: purpose,
            sensitivity: .private,
            retentionDays: 30,
            localOnlyByDefault: true,
            properties: properties
        )
    }

    private static func string(
        _ name: String,
        _ allowedValues: [String],
        required: Bool = true
    ) -> ProductTelemetryPropertyDefinition {
        ProductTelemetryPropertyDefinition(
            name: name,
            propertyType: .string,
            required: required,
            allowedValues: allowedValues
        )
    }

    private static func boolean(_ name: String) -> ProductTelemetryPropertyDefinition {
        ProductTelemetryPropertyDefinition(name: name, propertyType: .boolean)
    }

    private static func integer(
        _ name: String,
        minimum: Int,
        maximum: Int
    ) -> ProductTelemetryPropertyDefinition {
        ProductTelemetryPropertyDefinition(
            name: name,
            propertyType: .integer,
            minimum: minimum,
            maximum: maximum
        )
    }

    private static func validate(
        _ value: ProductTelemetryPropertyValue,
        against definition: ProductTelemetryPropertyDefinition
    ) throws {
        switch value {
        case let .string(stringValue):
            guard (1 ... 100).contains(stringValue.count),
                  definition.allowedValues.isEmpty
                    || definition.allowedValues.contains(stringValue)
            else {
                throw ProductTelemetryValidationError.invalidProperty(definition.name)
            }
        case let .integer(integerValue):
            guard definition.minimum.map({ integerValue >= $0 }) ?? true,
                  definition.maximum.map({ integerValue <= $0 }) ?? true
            else {
                throw ProductTelemetryValidationError.invalidProperty(definition.name)
            }
        case let .number(numberValue):
            guard numberValue.isFinite,
                  definition.minimum.map({ numberValue >= Double($0) }) ?? true,
                  definition.maximum.map({ numberValue <= Double($0) }) ?? true
            else {
                throw ProductTelemetryValidationError.invalidProperty(definition.name)
            }
        case .boolean:
            break
        }
    }
}

public struct ProductTelemetryEvent: Hashable, Sendable, Codable {
    public let eventID: UUIDv7
    public let occurredAt: Date
    public let receivedAt: Date
    public let sessionID: UUIDv7?
    public let deviceID: UUIDv7
    public let appBuild: String
    public let surface: String
    public let eventName: ProductTelemetryEventName
    public let objectType: String?
    public let objectIDPseudonymous: String?
    public let contextVersion: String
    public let featureFlagAssignments: [String: String]
    public let properties: [String: ProductTelemetryPropertyValue]
    public let causalParentEventID: UUIDv7?
    public let localOnly: Bool

    public init(
        eventID: UUIDv7 = UUIDv7(),
        occurredAt: Date,
        receivedAt: Date,
        sessionID: UUIDv7? = nil,
        deviceID: UUIDv7,
        appBuild: String,
        surface: String,
        eventName: ProductTelemetryEventName,
        objectType: String? = nil,
        objectIDPseudonymous: String? = nil,
        contextVersion: String,
        featureFlagAssignments: [String: String] = [:],
        properties: [String: ProductTelemetryPropertyValue],
        causalParentEventID: UUIDv7? = nil,
        localOnly: Bool = true
    ) throws {
        guard Self.validText(appBuild, maximum: 100),
              Self.validToken(surface, maximum: 80),
              Self.validText(contextVersion, maximum: 100),
              occurredAt.timeIntervalSinceReferenceDate.isFinite,
              receivedAt.timeIntervalSinceReferenceDate.isFinite,
              receivedAt >= occurredAt,
              objectType.map({ Self.validToken($0, maximum: 80) }) ?? true,
              objectIDPseudonymous.map(Self.validPseudonym) ?? true,
              featureFlagAssignments.count <= 50,
              featureFlagAssignments.allSatisfy({
                  Self.validToken($0.key, maximum: 100)
                    && Self.validToken($0.value, maximum: 100)
              }),
              properties.count <= 30
        else {
            throw ProductTelemetryValidationError.invalidField(eventName.rawValue)
        }
        try ProductTelemetryRegistry.validate(eventName: eventName, properties: properties)
        self.eventID = eventID
        self.occurredAt = occurredAt
        self.receivedAt = receivedAt
        self.sessionID = sessionID
        self.deviceID = deviceID
        self.appBuild = appBuild
        self.surface = surface
        self.eventName = eventName
        self.objectType = objectType
        self.objectIDPseudonymous = objectIDPseudonymous
        self.contextVersion = contextVersion
        self.featureFlagAssignments = featureFlagAssignments
        self.properties = properties
        self.causalParentEventID = causalParentEventID
        self.localOnly = localOnly
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            eventID: container.decode(UUIDv7.self, forKey: .eventID),
            occurredAt: container.decode(Date.self, forKey: .occurredAt),
            receivedAt: container.decode(Date.self, forKey: .receivedAt),
            sessionID: container.decodeIfPresent(UUIDv7.self, forKey: .sessionID),
            deviceID: container.decode(UUIDv7.self, forKey: .deviceID),
            appBuild: container.decode(String.self, forKey: .appBuild),
            surface: container.decode(String.self, forKey: .surface),
            eventName: container.decode(ProductTelemetryEventName.self, forKey: .eventName),
            objectType: container.decodeIfPresent(String.self, forKey: .objectType),
            objectIDPseudonymous: container.decodeIfPresent(
                String.self,
                forKey: .objectIDPseudonymous
            ),
            contextVersion: container.decode(String.self, forKey: .contextVersion),
            featureFlagAssignments: container.decode(
                [String: String].self,
                forKey: .featureFlagAssignments
            ),
            properties: container.decode(
                [String: ProductTelemetryPropertyValue].self,
                forKey: .properties
            ),
            causalParentEventID: container.decodeIfPresent(
                UUIDv7.self,
                forKey: .causalParentEventID
            ),
            localOnly: container.decode(Bool.self, forKey: .localOnly)
        )
    }

    private enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case occurredAt = "occurred_at"
        case receivedAt = "received_at"
        case sessionID = "session_id"
        case deviceID = "device_id"
        case appBuild = "app_build"
        case surface
        case eventName = "event_name"
        case objectType = "object_type"
        case objectIDPseudonymous = "object_id_pseudonymous"
        case contextVersion = "context_version"
        case featureFlagAssignments = "feature_flag_assignments"
        case properties = "properties_typed"
        case causalParentEventID = "causal_parent_event_id"
        case localOnly = "local_only_flag"
    }

    private static func validText(_ value: String, maximum: Int) -> Bool {
        (1 ... maximum).contains(value.count)
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func validToken(_ value: String, maximum: Int) -> Bool {
        validText(value, maximum: maximum)
            && value.unicodeScalars.allSatisfy {
                $0.isASCII
                    && (CharacterSet.alphanumerics.contains($0)
                        || "._-".unicodeScalars.contains($0))
            }
    }

    private static func validPseudonym(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}
