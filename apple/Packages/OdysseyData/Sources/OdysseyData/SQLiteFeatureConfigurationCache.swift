import Foundation
import OdysseyDomain
import OdysseyTelemetry

public enum FeatureConfigurationCacheError: Error, Equatable, Sendable {
    case verificationUnavailable
    case invalidEnvelopeDocument
    case rollbackRejected(currentVersion: Int, proposedVersion: Int)
    case versionConflict(Int)
}

public enum FeatureConfigurationResolutionSource: String, Codable, Hashable, Sendable {
    case verifiedCache = "verified_cache"
    case safeDefaultsUnconfigured = "safe_defaults_unconfigured"
    case safeDefaultsMissing = "safe_defaults_missing"
    case safeDefaultsInactive = "safe_defaults_inactive"
    case safeDefaultsInvalid = "safe_defaults_invalid"
}

public struct CachedFeatureConfiguration: Hashable, Sendable {
    public let envelope: FeatureConfigurationEnvelope
    public let payload: FeatureConfigurationPayload
    public let verifiedAt: Date

    public init(
        envelope: FeatureConfigurationEnvelope,
        payload: FeatureConfigurationPayload,
        verifiedAt: Date
    ) {
        self.envelope = envelope
        self.payload = payload
        self.verifiedAt = verifiedAt
    }
}

public struct FeatureConfigurationResolution: Hashable, Sendable {
    public let source: FeatureConfigurationResolutionSource
    public let payload: FeatureConfigurationPayload?
    public let assignments: [FeatureFlagKey: String]

    public var wireAssignments: [String: String] {
        Dictionary(uniqueKeysWithValues: assignments.map { ($0.key.rawValue, $0.value) })
    }

    fileprivate init(
        source: FeatureConfigurationResolutionSource,
        payload: FeatureConfigurationPayload?,
        assignmentSubject: String
    ) {
        self.source = source
        self.payload = payload
        assignments = FeatureFlagAssignment.variants(
            for: payload,
            assignmentSubject: assignmentSubject
        )
    }
}

public protocol FeatureConfigurationCaching: Sendable {
    @discardableResult
    func cacheFeatureConfiguration(
        _ envelope: FeatureConfigurationEnvelope
    ) throws -> CachedFeatureConfiguration
    func resolveFeatureConfiguration(
        assignmentSubject: String
    ) throws -> FeatureConfigurationResolution
}

extension SQLiteLedgerStore: FeatureConfigurationCaching {
    @discardableResult
    public func cacheFeatureConfiguration(
        _ envelope: FeatureConfigurationEnvelope
    ) throws -> CachedFeatureConfiguration {
        guard let verifier = configuration.featureConfigurationVerifier else {
            throw FeatureConfigurationCacheError.verificationUnavailable
        }
        let verifiedAt = configuration.clock()
        let payload = try verifier.verify(envelope, at: verifiedAt)
        let envelopeDocument = try Self.encodeFeatureConfigurationEnvelope(envelope)
        let envelopeSHA256 = SHA256Digest.hexDigest(of: envelopeDocument)
        return try withWrite {
            if let stored = try readStoredFeatureConfigurationRow() {
                let current = try decodeStoredFeatureConfiguration(
                    stored,
                    verifier: verifier
                )
                if payload.version < current.payload.version {
                    throw FeatureConfigurationCacheError.rollbackRejected(
                        currentVersion: current.payload.version,
                        proposedVersion: payload.version
                    )
                }
                if payload.version == current.payload.version {
                    guard envelopeDocument == stored.envelopeDocument else {
                        throw FeatureConfigurationCacheError.versionConflict(payload.version)
                    }
                    return current
                }
            }
            let statement = try connection.statement(
                """
                INSERT INTO verified_feature_configuration_cache (
                    singleton, environment, audience, configuration_id, version, key_id,
                    envelope_document, envelope_sha256, payload_sha256,
                    issued_at, not_before, expires_at, verified_at
                ) VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT (singleton) DO UPDATE SET
                    environment = excluded.environment,
                    audience = excluded.audience,
                    configuration_id = excluded.configuration_id,
                    version = excluded.version,
                    key_id = excluded.key_id,
                    envelope_document = excluded.envelope_document,
                    envelope_sha256 = excluded.envelope_sha256,
                    payload_sha256 = excluded.payload_sha256,
                    issued_at = excluded.issued_at,
                    not_before = excluded.not_before,
                    expires_at = excluded.expires_at,
                    verified_at = excluded.verified_at
                """
            )
            try statement.bind([
                .text(payload.environment.rawValue),
                .text(payload.audience),
                .text(payload.configurationID.description),
                .integer(Int64(payload.version)),
                .text(envelope.keyID),
                .blob(envelopeDocument),
                .text(envelopeSHA256),
                .text(envelope.payloadSHA256),
                .text(SQLiteValueCodec.dateString(payload.issuedAt)),
                .text(SQLiteValueCodec.dateString(payload.notBefore)),
                .text(SQLiteValueCodec.dateString(payload.expiresAt)),
                .text(SQLiteValueCodec.dateString(verifiedAt)),
            ])
            _ = try statement.step()
            guard try connection.scalarInt("SELECT changes()") == 1 else {
                throw SQLiteLedgerError.integrityFailure(
                    "The verified feature configuration was not persisted."
                )
            }
            return CachedFeatureConfiguration(
                envelope: envelope,
                payload: payload,
                verifiedAt: verifiedAt
            )
        }
    }

    public func resolveFeatureConfiguration(
        assignmentSubject: String
    ) throws -> FeatureConfigurationResolution {
        try resolveFeatureConfiguration(
            at: configuration.clock(),
            assignmentSubject: assignmentSubject
        )
    }

    func resolveFeatureConfiguration(
        at date: Date,
        assignmentSubject: String
    ) throws -> FeatureConfigurationResolution {
        guard date.timeIntervalSinceReferenceDate.isFinite else {
            throw FeatureConfigurationVerificationError.invalidClock
        }
        guard let verifier = configuration.featureConfigurationVerifier else {
            return FeatureConfigurationResolution(
                source: .safeDefaultsUnconfigured,
                payload: nil,
                assignmentSubject: assignmentSubject
            )
        }
        return try withRead {
            guard let stored = try readStoredFeatureConfigurationRow() else {
                return FeatureConfigurationResolution(
                    source: .safeDefaultsMissing,
                    payload: nil,
                    assignmentSubject: assignmentSubject
                )
            }
            let cached: CachedFeatureConfiguration
            do {
                cached = try decodeStoredFeatureConfiguration(
                    stored,
                    verifier: verifier
                )
            } catch {
                return FeatureConfigurationResolution(
                    source: .safeDefaultsInvalid,
                    payload: nil,
                    assignmentSubject: assignmentSubject
                )
            }
            guard date >= cached.payload.notBefore,
                  date < cached.payload.expiresAt
            else {
                return FeatureConfigurationResolution(
                    source: .safeDefaultsInactive,
                    payload: nil,
                    assignmentSubject: assignmentSubject
                )
            }
            return FeatureConfigurationResolution(
                source: .verifiedCache,
                payload: cached.payload,
                assignmentSubject: assignmentSubject
            )
        }
    }

    func verifyFeatureConfigurationCache() throws {
        let count = try connection.scalarInt(
            "SELECT COUNT(*) FROM verified_feature_configuration_cache"
        )
        guard count <= 1 else {
            throw SQLiteLedgerError.integrityFailure(
                "The verified feature configuration cache contains multiple rows."
            )
        }
        guard count == 1 else { return }
        guard let verifier = configuration.featureConfigurationVerifier else {
            throw SQLiteLedgerError.integrityFailure(
                "The feature configuration cache cannot be checked without its pinned verifier."
            )
        }
        guard let stored = try readStoredFeatureConfigurationRow() else {
            throw SQLiteLedgerError.integrityFailure(
                "The feature configuration cache row disappeared during verification."
            )
        }
        _ = try decodeStoredFeatureConfiguration(stored, verifier: verifier)
    }

    private func readStoredFeatureConfigurationRow() throws -> StoredFeatureConfigurationRow? {
        let statement = try connection.statement(
            """
            SELECT environment, audience, configuration_id, version, key_id,
                   envelope_document, envelope_sha256, payload_sha256,
                   issued_at, not_before, expires_at, verified_at
            FROM verified_feature_configuration_cache
            WHERE singleton = 1
            """
        )
        guard try statement.step() else { return nil }
        return StoredFeatureConfigurationRow(
            environment: try statement.text(at: 0),
            audience: try statement.text(at: 1),
            configurationID: try statement.text(at: 2),
            version: Int(statement.int64(at: 3)),
            keyID: try statement.text(at: 4),
            envelopeDocument: try statement.data(at: 5),
            envelopeSHA256: try statement.text(at: 6),
            payloadSHA256: try statement.text(at: 7),
            issuedAt: try statement.text(at: 8),
            notBefore: try statement.text(at: 9),
            expiresAt: try statement.text(at: 10),
            verifiedAt: try statement.text(at: 11)
        )
    }

    private func decodeStoredFeatureConfiguration(
        _ stored: StoredFeatureConfigurationRow,
        verifier: FeatureConfigurationVerifier
    ) throws -> CachedFeatureConfiguration {
        guard SHA256Digest.hexDigest(of: stored.envelopeDocument) == stored.envelopeSHA256 else {
            throw SQLiteLedgerError.integrityFailure(
                "The cached feature configuration envelope failed digest verification."
            )
        }
        let envelope: FeatureConfigurationEnvelope
        do {
            envelope = try JSONDecoder().decode(
                FeatureConfigurationEnvelope.self,
                from: stored.envelopeDocument
            )
        } catch {
            throw SQLiteLedgerError.integrityFailure(
                "The cached feature configuration envelope could not be decoded."
            )
        }
        let payload: FeatureConfigurationPayload
        do {
            payload = try verifier.verifyAuthenticity(of: envelope)
        } catch {
            throw SQLiteLedgerError.integrityFailure(
                "The cached feature configuration failed signature verification."
            )
        }
        let verifiedAt = try SQLiteValueCodec.date(stored.verifiedAt)
        guard stored.environment == verifier.expectedEnvironment.rawValue,
              stored.environment == payload.environment.rawValue,
              stored.audience == verifier.expectedAudience,
              stored.audience == payload.audience,
              stored.configurationID == payload.configurationID.description,
              stored.version == payload.version,
              stored.keyID == verifier.expectedKeyID,
              stored.keyID == envelope.keyID,
              stored.payloadSHA256 == envelope.payloadSHA256,
              stored.issuedAt == SQLiteValueCodec.dateString(payload.issuedAt),
              stored.notBefore == SQLiteValueCodec.dateString(payload.notBefore),
              stored.expiresAt == SQLiteValueCodec.dateString(payload.expiresAt),
              verifiedAt >= payload.issuedAt
        else {
            throw SQLiteLedgerError.integrityFailure(
                "Cached feature configuration metadata diverged from its signed payload."
            )
        }
        return CachedFeatureConfiguration(
            envelope: envelope,
            payload: payload,
            verifiedAt: verifiedAt
        )
    }

    private static func encodeFeatureConfigurationEnvelope(
        _ envelope: FeatureConfigurationEnvelope
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(envelope)
        } catch {
            throw FeatureConfigurationCacheError.invalidEnvelopeDocument
        }
    }
}

private struct StoredFeatureConfigurationRow {
    let environment: String
    let audience: String
    let configurationID: String
    let version: Int
    let keyID: String
    let envelopeDocument: Data
    let envelopeSHA256: String
    let payloadSHA256: String
    let issuedAt: String
    let notBefore: String
    let expiresAt: String
    let verifiedAt: String
}
