import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import OdysseyApplication
import OdysseySync
import OdysseyTelemetry
import Testing

@Test
func featureConfigurationTransportUsesAuthenticatedOriginLockedRoute() async throws {
    let envelope = try transportFeatureEnvelope()
    let loader = RecordingFeatureConfigurationLoader(
        response: StubFeatureConfigurationResponse(
            body: try JSONEncoder().encode(envelope)
        )
    )
    let transport = try URLSessionFeatureConfigurationTransport(
        configuration: try featureRemoteConfiguration(),
        tokenProvider: FeatureTransportTokenProvider(),
        loader: loader
    )

    #expect(
        try await transport.currentConfiguration(audience: "com.example.odyssey.app")
            == envelope
    )
    let request = try #require(await loader.request())
    #expect(request.httpMethod == "GET")
    #expect(request.url?.path == "/root/v1/product/feature-configuration")
    #expect(
        URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?
            .queryItems == [
                URLQueryItem(name: "audience", value: "com.example.odyssey.app"),
            ]
    )
    #expect(
        request.value(forHTTPHeaderField: "Authorization")
            == "Bearer synthetic-access-token"
    )
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    #expect(request.value(forHTTPHeaderField: "User-Agent") == "Odyssey/1.0-test (ios; staging)")
    #expect(request.value(forHTTPHeaderField: "X-Correlation-ID")?.isEmpty == false)
}

@Test
func featureConfigurationTransportPreservesStableErrorsAndRejectsRedirects() async throws {
    let body = APIErrorBody(
        code: "FEATURE_CONFIGURATION_UNAVAILABLE",
        message: "No active feature configuration is available for this client.",
        retryable: false,
        correlationID: "correlation-1",
        details: [:]
    )
    let unavailable = try URLSessionFeatureConfigurationTransport(
        configuration: try featureRemoteConfiguration(),
        tokenProvider: FeatureTransportTokenProvider(),
        loader: RecordingFeatureConfigurationLoader(
            response: StubFeatureConfigurationResponse(
                statusCode: 404,
                body: try SyncJSONCoding.makeEncoder().encode(APIErrorEnvelope(error: body))
            )
        )
    )
    await #expect(
        throws: FeatureConfigurationTransportError.api(statusCode: 404, error: body)
    ) {
        try await unavailable.currentConfiguration(audience: "com.example.odyssey.app")
    }

    let redirected = try URLSessionFeatureConfigurationTransport(
        configuration: try featureRemoteConfiguration(),
        tokenProvider: FeatureTransportTokenProvider(),
        loader: RecordingFeatureConfigurationLoader(
            response: StubFeatureConfigurationResponse(
                body: try JSONEncoder().encode(transportFeatureEnvelope()),
                responseURL: URL(
                    string: "https://redirected.example.test/v1/product/feature-configuration"
                )!
            )
        )
    )
    await #expect(throws: FeatureConfigurationTransportError.redirected(
        expectedOrigin: "https://api.example.test:443",
        actualOrigin: "https://redirected.example.test:443"
    )) {
        try await redirected.currentConfiguration(audience: "com.example.odyssey.app")
    }
}

private struct FeatureTransportTokenProvider: BearerTokenProvider {
    func validAccessToken() async throws -> String {
        "synthetic-access-token"
    }
}

private struct StubFeatureConfigurationResponse: Sendable {
    let statusCode: Int
    let body: Data
    let responseURL: URL?

    init(statusCode: Int = 200, body: Data, responseURL: URL? = nil) {
        self.statusCode = statusCode
        self.body = body
        self.responseURL = responseURL
    }
}

private actor RecordingFeatureConfigurationLoader: FeatureConfigurationHTTPDataLoading {
    private let response: StubFeatureConfigurationResponse
    private var recordedRequest: URLRequest?

    init(response: StubFeatureConfigurationResponse) {
        self.response = response
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        recordedRequest = request
        let response = HTTPURLResponse(
            url: self.response.responseURL ?? request.url!,
            statusCode: self.response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "application/json; charset=utf-8",
                "X-Correlation-ID": "correlation-1",
            ]
        )!
        return (self.response.body, response)
    }

    func request() -> URLRequest? {
        recordedRequest
    }
}

private func featureRemoteConfiguration() throws -> NativeRemoteConfiguration {
    try NativeRemoteConfiguration(
        baseURL: URL(string: "https://api.example.test/root")!,
        environment: .staging,
        platform: .iOS,
        appVersion: "1.0-test"
    )
}

private func transportFeatureEnvelope() throws -> FeatureConfigurationEnvelope {
    try FeatureConfigurationEnvelope(
        keyID: "synthetic-key-1",
        payloadBase64: Data("{}".utf8).base64EncodedString(),
        payloadSHA256: String(repeating: "0", count: 64),
        signatureBase64: Data(repeating: 1, count: 64).base64EncodedString()
    )
}
