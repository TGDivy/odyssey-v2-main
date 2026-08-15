import Foundation
import OdysseyData

#if canImport(AuthenticationServices) && (os(iOS) || os(macOS) || os(visionOS))
import AuthenticationServices

@MainActor
public final class SystemAppleAuthorizationPerformer: NSObject, AppleAuthorizationPerforming {
    public typealias PresentationAnchorProvider = @MainActor @Sendable () -> ASPresentationAnchor

    private let presentationAnchorProvider: PresentationAnchorProvider
    private var continuation: CheckedContinuation<AppleAuthorizationCredential, Error>?
    private var expectedState: String?
    private var controller: ASAuthorizationController?

    public init(
        presentationAnchorProvider: @escaping PresentationAnchorProvider
    ) {
        self.presentationAnchorProvider = presentationAnchorProvider
    }

    public func authorize(
        challenge: AppleChallengeResponse
    ) async throws -> AppleAuthorizationCredential {
        guard continuation == nil else {
            throw AppleEnrollmentError.busy
        }
        let state = challenge.challengeID.description
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = []
        request.nonce = AppleNonce.hashed(challenge.nonce)
        request.state = state
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        self.controller = controller
        expectedState = state
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            controller.performRequests()
        }
    }

    private func complete(
        _ result: Result<AppleAuthorizationCredential, Error>
    ) {
        let continuation = continuation
        self.continuation = nil
        expectedState = nil
        controller = nil
        continuation?.resume(with: result)
    }
}

extension SystemAppleAuthorizationPerformer: ASAuthorizationControllerDelegate {
    public func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              credential.state == expectedState,
              let tokenData = credential.identityToken,
              let token = String(data: tokenData, encoding: .utf8)
        else {
            complete(.failure(AppleEnrollmentError.stateMismatch))
            return
        }
        do {
            complete(.success(try AppleAuthorizationCredential(identityToken: token)))
        } catch {
            complete(.failure(AppleEnrollmentError.invalidIdentityToken))
        }
    }

    public func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        if let authorizationError = error as? ASAuthorizationError,
           authorizationError.code == .canceled
        {
            complete(.failure(AppleEnrollmentError.cancelled))
        } else {
            complete(.failure(AppleEnrollmentError.unavailable))
        }
    }
}

extension SystemAppleAuthorizationPerformer: ASAuthorizationControllerPresentationContextProviding {
    public func presentationAnchor(
        for controller: ASAuthorizationController
    ) -> ASPresentationAnchor {
        presentationAnchorProvider()
    }
}
#endif
