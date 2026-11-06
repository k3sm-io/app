/*
Copyright The k3sm Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

import Foundation
import K3smInstall
import K3smStatus
import os

/// The unified-log channel of the app's own update: every check, refusal
/// and state change logs one event under the subsystem `io.k3sm.app.update`.
public let appUpdateLog = Logger(subsystem: "io.k3sm.app.update", category: "check")

/// AppIndexFetcher fetches the signed release index; the app's is
/// `EphemeralIndexFetcher`, a test's counts what it is asked.
public protocol AppIndexFetcher: Sendable {
    func fetch(_ request: URLRequest) async throws -> Data
}

/// AppIndexFetchError is why a fetch returned no index.
public enum AppIndexFetchError: Error, Equatable, CustomStringConvertible {
    case refusedHop
    case status(Int)
    case tooLarge
    case transport(String)

    public var description: String {
        switch self {
        case .refusedHop: "the server redirected to a host that is not pinned"
        case .status(let code): "the server answered \(code)"
        case .tooLarge: "the index is larger than the cap"
        case .transport(let text): text
        }
    }
}

/// AppUpdateFetch builds the one request the check sends
/// (`AppUpdateRequest`): no cookie, no cache, no credential, no header but
/// the fixed user agent.
public enum AppUpdateFetch {
    public static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 30)
        request.httpMethod = AppUpdateRequest.method
        request.httpShouldHandleCookies = false
        request.allHTTPHeaderFields = AppUpdateRequest.headers
        return request
    }

    /// The request for `kind`'s document; nil for a tag outside the candidate
    /// grammar, or if the URL fails to parse.
    public static func indexRequest(_ kind: ReleaseIndexKind) -> URLRequest? {
        AppUpdateRequest.url(for: kind).flatMap { URL(string: $0) }.map(request)
    }

    /// The session configuration: ephemeral, with nothing stored and no
    /// header added.
    public static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpAdditionalHeaders = [:]
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        return configuration
    }
}

/// EphemeralIndexFetcher is the shipped fetcher: an ephemeral session whose
/// redirect delegate holds every hop to `AppUpdateRequest.allowsHop` and
/// rebuilds each redirected request with the same fixed headers, so nothing
/// a server sends is carried forward. The body is capped at
/// `ReleaseIndexVerifier.maxSignedBytes`.
public final class EphemeralIndexFetcher: NSObject, AppIndexFetcher, URLSessionTaskDelegate, @unchecked Sendable {
    override public init() {}

    public func fetch(_ request: URLRequest) async throws -> Data {
        guard let url = request.url, AppUpdateRequest.allowsHop(url) else { throw AppIndexFetchError.refusedHop }
        let session = URLSession(configuration: AppUpdateFetch.configuration(), delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw AppIndexFetchError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, let final = http.url, AppUpdateRequest.allowsHop(final) else {
            throw AppIndexFetchError.refusedHop
        }
        guard http.statusCode == 200 else { throw AppIndexFetchError.status(http.statusCode) }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > ReleaseIndexVerifier.maxSignedBytes { throw AppIndexFetchError.tooLarge }
            }
        } catch let error as AppIndexFetchError {
            throw error
        } catch {
            throw AppIndexFetchError.transport(error.localizedDescription)
        }
        return data
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest) async -> URLRequest? {
        Self.redirect(to: request)
    }

    /// The request to follow a redirect with, or nil to stop at a host that
    /// is not pinned.
    static func redirect(to request: URLRequest) -> URLRequest? {
        guard let url = request.url, AppUpdateRequest.allowsHop(url) else {
            appUpdateLog.notice("app update: redirect refused")
            return nil
        }
        return AppUpdateFetch.request(url)
    }
}

/// AppUpdateChecker runs one check of one document kind: whether it may send at
/// all (`AppUpdateSchedule.mayRequest`), the fetch, the signature
/// (`ReleaseIndexVerifier`, passed in as `verify`), and that kind's own floor
/// (`AppUpdateRecord.accept` or `AppUpdateCandidateRecord.accept`). A candidate
/// with no document falls back to the stable kind, so removing one asset cannot
/// silence a stable update. It returns the result and the records to store; it
/// holds no CLI runner and starts nothing else.
public struct AppUpdateChecker: Sendable {
    public typealias Verify = @Sendable (Data, ReleaseIndexKind) throws -> (index: ReleaseIndex, signedAt: Date)

    let fetcher: any AppIndexFetcher
    let verify: Verify

    public init(fetcher: any AppIndexFetcher, verify: @escaping Verify) {
        self.fetcher = fetcher
        self.verify = verify
    }

    /// The shipped checker for this build's pinned team; nil for a
    /// development build.
    public static var pinned: AppUpdateChecker? {
        ReleaseIndexVerifier.pinned.map { checker(fetcher: EphemeralIndexFetcher(), verifier: $0) }
    }

    /// The checker over `verifier`: the document kind the check asks for is the
    /// kind the signature is held to. Internal so a test can run this closure;
    /// the only verifier outside a test is `ReleaseIndexVerifier.pinned`, as the
    /// initializer that takes other roots is internal to `K3smInstall`.
    static func checker(fetcher: any AppIndexFetcher, verifier: ReleaseIndexVerifier) -> AppUpdateChecker {
        AppUpdateChecker(fetcher: fetcher) { data, kind in
            let verified = try verifier.verified(p7m: data, expected: kind)
            return (verified.index, verified.signedAt)
        }
    }

    public struct Outcome: Equatable, Sendable {
        /// Nil when nothing was sent.
        public let result: AppUpdateResult?
        /// The stable floor to store; the old one unless a stable index was accepted.
        public let record: AppUpdateRecord
        /// The candidate floor to store; the old one unless a candidate was accepted.
        public let candidateRecord: AppUpdateCandidateRecord
    }

    public func check(_ trigger: AppUpdateSchedule.Trigger, checksOn: Bool, own: AppUpdateOwn, firstRun: Bool,
                      kind: ReleaseIndexKind, record: AppUpdateRecord, candidateRecord: AppUpdateCandidateRecord) async -> Outcome {
        guard AppUpdateSchedule.mayRequest(trigger, checksOn: checksOn, own: own, firstRun: firstRun) else {
            appUpdateLog.notice("app update: check skipped")
            return Outcome(result: nil, record: record, candidateRecord: candidateRecord)
        }
        return await fetchAndAccept(kind, record: record, candidateRecord: candidateRecord)
    }

    /// The fetch, the signature and the floor of one kind. A candidate's missing
    /// document is answered by the stable kind, which has no such fallback.
    private func fetchAndAccept(_ kind: ReleaseIndexKind, record: AppUpdateRecord, candidateRecord: AppUpdateCandidateRecord) async -> Outcome {
        let unchanged = { (result: AppUpdateResult?) in Outcome(result: result, record: record, candidateRecord: candidateRecord) }
        let refused = { (reason: String) in
            appUpdateLog.notice("app update: refused: \(reason, privacy: .public)")
            return unchanged(.failed(reason))
        }
        guard let request = AppUpdateFetch.indexRequest(kind) else { return unchanged(.failed("no index URL")) }
        appUpdateLog.notice("app update: checking")
        let data: Data
        do {
            data = try await fetcher.fetch(request)
        } catch {
            if case .status(let status)? = error as? AppIndexFetchError, kind.hasNoDocument(status: status),
               case .candidate(let tag) = kind {
                appUpdateLog.notice("app update: no index at \(tag, privacy: .public), checking stable")
                let stable = await fetchAndAccept(.stable, record: record, candidateRecord: candidateRecord)
                guard case .verified(let latest)? = stable.result else { return stable }
                return Outcome(result: .noCandidateDocument(tag, stable: latest), record: stable.record, candidateRecord: candidateRecord)
            }
            return refused(String(describing: error))
        }
        let verified: (index: ReleaseIndex, signedAt: Date)
        do {
            verified = try verify(data, kind)
        } catch {
            return refused(String(describing: error))
        }
        guard let latest = AppUpdateLatest(index: verified.index) else {
            return refused("the index names no release tag")
        }
        switch kind {
        case .stable:
            switch AppUpdateRecord.accept(latest, signedAt: verified.signedAt, record: record) {
            case .refused(let reason):
                return refused(reason)
            case .accepted(let stored):
                appUpdateLog.notice("app update: index accepted for \(latest.tag, privacy: .public)")
                return Outcome(result: .verified(latest), record: stored, candidateRecord: candidateRecord)
            }
        case .candidate:
            switch AppUpdateCandidateRecord.accept(latest, signedAt: verified.signedAt, record: candidateRecord, stable: record) {
            case .refused(let reason):
                return refused(reason)
            case .accepted(let stored):
                appUpdateLog.notice("app update: candidate index accepted for \(latest.tag, privacy: .public)")
                return Outcome(result: .verified(latest), record: record, candidateRecord: stored)
            }
        }
    }
}
