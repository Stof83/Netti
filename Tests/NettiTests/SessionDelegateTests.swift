import Foundation
import os
import Security
import Testing

@testable import Netti

@Suite("Session delegate", .timeLimit(.minutes(1)))
struct SessionDelegateTests {
    typealias Fixture = TrustFixtures.Certificate

    private static let pinnedPolicy = ServerTrustPolicy([TrustFixtures.host: .publicKeys([Fixture.p256.expectedPin, Fixture.authority.expectedPin])])
    private static let mismatchedPolicy = ServerTrustPolicy([TrustFixtures.host: .publicKeys([Fixture.unrelated.expectedPin, Fixture.otherHost.expectedPin])])

    // MARK: - Server Trust

    @Test("given a policy that accepts the host, when a trust challenge arrives, then the server trust is used")
    func trust_accepted_usesCredential() throws {
        let delegate = SessionDelegate(trustEvaluator: Self.pinnedPolicy)

        let (disposition, credential) = try Self.answer(delegate, trust: TrustFixtures.trust([.p256]))

        #expect(disposition == .useCredential)
        #expect(credential != nil)
    }

    @Test("given a policy that rejects the host, when the challenge is cancelled, then the task fails with serverTrustEvaluationFailed")
    func trust_rejected_surfacesPolicyError() async throws {
        let delegate = SessionDelegate(trustEvaluator: Self.mismatchedPolicy)
        let trust = try TrustFixtures.trust([.p256])
        let session = URLSession(configuration: .ephemeral)
        let url = try #require(URL(string: "https://\(TrustFixtures.host)/resource"))
        let task = session.dataTask(with: url)

        let result = await withCheckedContinuation { continuation in
            delegate.register(task, TaskState(request: URLRequest(url: url), completion: .data(continuation)))
            let (disposition, _) = Self.answer(delegate, trust: trust, task: task, session: session)
            #expect(disposition == .cancelAuthenticationChallenge)
            delegate.urlSession(session, task: task, didCompleteWithError: URLError(.cancelled))
        }

        guard case .failure(.serverTrustEvaluationFailed(let host, _)) = result else {
            Issue.record("Expected serverTrustEvaluationFailed, got \(result)")
            return
        }
        #expect(host == TrustFixtures.host)
        #expect(delegate.registeredTaskCount == 0)
    }

    @Test("given no trust policy, when a trust challenge arrives, then the system decides")
    func trust_noPolicy_performsDefaultHandling() throws {
        let delegate = SessionDelegate(trustEvaluator: nil)

        let (disposition, credential) = try Self.answer(delegate, trust: TrustFixtures.trust([.p256]))

        #expect(disposition == .performDefaultHandling)
        #expect(credential == nil)
    }

    @Test("given a policy, when a non-trust challenge arrives, then the system decides")
    func trust_otherChallenge_performsDefaultHandling() throws {
        let delegate = SessionDelegate(trustEvaluator: Self.pinnedPolicy)

        let (disposition, _) = try Self.answer(delegate, trust: TrustFixtures.trust([.p256]), method: NSURLAuthenticationMethodHTTPBasic)

        #expect(disposition == .performDefaultHandling)
    }

    // MARK: - Redirects

    @Test("given no redirect handler, when the server redirects, then the redirect is followed")
    func redirect_default_follows() async throws {
        let server = try await Self.redirectingServer()
        defer { server.stop() }
        let service = URLSessionNetworkService(configuration: .ephemeral, delegate: SessionDelegate(trustEvaluator: nil))

        let response = try await service.data(for: URLRequest(url: server.url("/start")))

        #expect(response.statusCode == 200)
        #expect(response.rawData == Data("final".utf8))
        #expect(server.requests.map(\.path) == ["/start", "/final"])
    }

    @Test("given a handler that refuses, when the server redirects, then the redirect response is returned")
    func redirect_refused_returnsRedirectResponse() async throws {
        let server = try await Self.redirectingServer()
        defer { server.stop() }
        let delegate = SessionDelegate(trustEvaluator: nil, redirectHandler: .doNotFollow)
        let service = URLSessionNetworkService(configuration: .ephemeral, delegate: delegate)

        let response = try await service.data(for: URLRequest(url: server.url("/start")))

        #expect(response.statusCode == 302)
        #expect(server.requests.map(\.path) == ["/start"])
    }

    @Test("given a handler that rewrites, when the server redirects, then the rewritten request is sent")
    func redirect_rewritten_sendsModifiedRequest() async throws {
        let server = try await Self.redirectingServer()
        defer { server.stop() }
        let elsewhere = server.url("/elsewhere")
        let delegate = SessionDelegate(trustEvaluator: nil, redirectHandler: RedirectHandler { request, _ in
            var rewritten = request
            rewritten.url = elsewhere
            return .modify(rewritten)
        })
        let service = URLSessionNetworkService(configuration: .ephemeral, delegate: delegate)

        let response = try await service.data(for: URLRequest(url: server.url("/start")))

        #expect(response.rawData == Data("elsewhere".utf8))
        #expect(server.requests.map(\.path) == ["/start", "/elsewhere"])
    }

    // MARK: - Metrics & Registry

    @Test("given a completed request, when the response returns, then it carries metrics and the task is unregistered")
    func completion_attachesMetricsAndUnregisters() async throws {
        let server = try await LocalHTTPServer.start { _ in .text("ok") }
        defer { server.stop() }
        let delegate = SessionDelegate(trustEvaluator: nil)
        let service = URLSessionNetworkService(configuration: .ephemeral, delegate: delegate)

        let refusedURL = try await Self.refusedURL()

        let response = try await service.data(for: URLRequest(url: server.url("/")))
        _ = await expectRequestError { () async throws(HTTPRequestError) in
            try await service.data(for: URLRequest(url: refusedURL))
        }

        #expect(response.metrics != nil)
        #expect(delegate.registeredTaskCount == 0)
    }

    // MARK: - Progress

    @Test("given updates that do not move forward, when reported, then they are dropped")
    func progress_dropsNonForwardUpdates() throws {
        let recorder = ProgressRecorder()
        let reporter = try #require(ProgressReporter(recorder.handler))

        reporter.report(completed: 10, total: 100)
        reporter.report(completed: 5, total: 100)
        reporter.report(completed: 10, total: 100)
        reporter.report(completed: 50, total: 100)

        #expect(recorder.updates.map(\.completedUnitCount) == [10, 50])
    }

    @Test("given a transfer that never reported 1.0, when finished, then a final 1.0 update is sent once")
    func progress_finish_reportsCompletionOnce() throws {
        let recorder = ProgressRecorder()
        let reporter = try #require(ProgressReporter(recorder.handler))

        reporter.report(completed: 40, total: -1)
        reporter.finish(completed: 64)
        reporter.finish(completed: 64)

        #expect(recorder.updates == [
            TransferProgress(completedUnitCount: 40, totalUnitCount: nil),
            TransferProgress(completedUnitCount: 64, totalUnitCount: 64),
        ])
    }

    @Test("given a transfer that already reported 1.0, when finished, then nothing more is sent")
    func progress_finish_afterCompletion_isSilent() throws {
        let recorder = ProgressRecorder()
        let reporter = try #require(ProgressReporter(recorder.handler))

        reporter.report(completed: 100, total: 100)
        reporter.finish(completed: 100)

        #expect(recorder.updates.count == 1)
    }

    @Test("given no handler, when a reporter is created, then there is none")
    func progress_noHandler_noReporter() {
        #expect(ProgressReporter(nil) == nil)
    }

    @Test(
        "given counts, when the fraction is read, then it is clamped and unknown totals read 0",
        arguments: [
            (TransferProgress(completedUnitCount: 25, totalUnitCount: 100), 0.25),
            (TransferProgress(completedUnitCount: 150, totalUnitCount: 100), 1.0),
            (TransferProgress(completedUnitCount: 25, totalUnitCount: nil), 0.0),
            (TransferProgress(completedUnitCount: 25, totalUnitCount: -1), 0.0),
            (TransferProgress(completedUnitCount: 0, totalUnitCount: 0), 1.0),
        ]
    )
    func progress_fractionCompleted(progress: TransferProgress, expected: Double) {
        #expect(progress.fractionCompleted == expected)
    }
}

// MARK: - Helpers

extension SessionDelegateTests {
    static func answer(
        _ delegate: SessionDelegate,
        trust: SecTrust,
        method: String = NSURLAuthenticationMethodServerTrust,
        task: URLSessionTask? = nil,
        session: URLSession = URLSession(configuration: .ephemeral)
    ) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let protectionSpace = TrustProtectionSpace(host: TrustFixtures.host, trust: trust, authenticationMethod: method)
        let challenge = URLAuthenticationChallenge(
            protectionSpace: protectionSpace,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: ChallengeSender()
        )
        let answer = OSAllocatedUnfairLock<(URLSession.AuthChallengeDisposition, URLCredential?)?>(initialState: nil)
        let challengedTask = task ?? session.dataTask(with: URLRequest(url: URL(filePath: "/")))
        delegate.urlSession(session, task: challengedTask, didReceive: challenge) { disposition, credential in
            answer.withLock { $0 = (disposition, credential) }
        }
        return answer.withLock { $0 } ?? (.rejectProtectionSpace, nil)
    }

    /// `/start` redirects to `/final`; every other path answers with its own name.
    static func redirectingServer() async throws -> LocalHTTPServer {
        try await LocalHTTPServer.start { request in
            guard request.path == "/start" else {
                return .text(String(request.path.dropFirst()))
            }
            return LocalHTTPServer.Response(status: 302, headers: ["Location": "/final"])
        }
    }

    /// A loopback URL nothing listens on.
    static func refusedURL() async throws -> URL {
        let server = try await LocalHTTPServer.start { _ in .text("") }
        server.stop()
        return server.url("/")
    }
}

/// A protection space that carries a fixture `SecTrust`, so trust challenges can be answered offline.
private final class TrustProtectionSpace: URLProtectionSpace, @unchecked Sendable {
    private let trust: SecTrust

    init(host: String, trust: SecTrust, authenticationMethod: String) {
        self.trust = trust
        super.init(host: host, port: 443, protocol: NSURLProtectionSpaceHTTPS, realm: nil, authenticationMethod: authenticationMethod)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var serverTrust: SecTrust? {
        trust
    }
}

private final class ChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}
