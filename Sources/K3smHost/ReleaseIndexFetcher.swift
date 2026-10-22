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
import Synchronization

/// AppUpdateLog is the unified-log home of the app's self-update: one event
/// per check, refusal and state change, under the subsystem
/// `io.k3sm.app.update`, category `check`. Each message is a fixed sentence;
/// the only values in it are the app's own refusal descriptions and tags
/// from a verified index or the sealed bundle.
public enum AppUpdateLog {
    public static let subsystem = "io.k3sm.app.update"
    public static let category = "check"
    public static let logger = Logger(subsystem: subsystem, category: category)

    /// A state change, logged by whoever publishes the state.
    public static func stateChanged(_ state: AppUpdateState) {
        logger.notice("app update: state \(state.line, privacy: .public)")
    }
}

/// IndexSource fetches the signed release index's bytes. The shipped source
/// is `URLSessionIndexSource`; tests count and script fetches through it.
public protocol IndexSource: Sendable {
    /// The `.p7m` bytes, at most `ReleaseIndexVerifier.maxSignedBytes`.
    func fetch() async throws(IndexFetchError) -> Data
}

/// Why a fetch of the release index failed. Every case reaches the user as
/// "Could not check for updates", never as an offer.
public enum IndexFetchError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A URL, on the first request or a redirect, that is not https on an
    /// allowed host with no query, credentials or other port.
    case urlRefused
    /// A redirect to a URL that is not allowed.
    case redirectRefused
    /// The final response is not 200.
    case status(Int)
    /// The body is over the cap (refused before the signature check reads it).
    case tooLarge
    /// The request timed out.
    case timedOut
    /// Any other transport failure (its URLError code).
    case network(Int)

    public var description: String {
        switch self {
        case .urlRefused: "the update URL is not an allowed https address"
        case .redirectRefused: "the download was redirected to a host that is not allowed"
        case .status(let code): "the server answered \(code)"
        case .tooLarge: "the signed index is over \(ReleaseIndexVerifier.maxSignedBytes) bytes"
        case .timedOut: "the request timed out"
        case .network(let code): "the network request failed (\(code))"
        }
    }
}

/// URLSessionIndexSource is the app's only network request: a plain `GET`
/// of `ReleaseIndex.latestIndexURL` that sends nothing about the Mac, the
/// user, the cluster or the app's version.
///
/// - An ephemeral session with no cookie store, URL cache or credential
///   storage, cookies off, and the cache bypassed on every request.
/// - https only, on `ReleaseIndex.allowedHosts` only, on the first request
///   and every redirect hop (the delegate refuses a hop that is not); the
///   final response must be a 200 from an allowed host.
/// - Fixed headers (`headers`): the user agent `k3sm-app` with no version,
///   and the language and encoding pinned so CFNetwork does not send the
///   user's own. No query string, no credentials.
/// - The body is read as it streams and the request is cancelled at
///   `ReleaseIndexVerifier.maxSignedBytes` plus one byte, before any CMS
///   decoder sees it.
/// - A request timeout and a whole-fetch timeout.
public struct URLSessionIndexSource: IndexSource {
    /// Every header the request sets, in this order. CFNetwork adds `Host`,
    /// `Cache-Control: no-cache` (the cache policy) and `Connection:
    /// keep-alive` itself; nothing else is sent (a wire-capture test holds it).
    public static let headers: [(name: String, value: String)] = [
        ("User-Agent", "k3sm-app"),
        ("Accept", "*/*"),
        ("Accept-Language", "en"),
        ("Accept-Encoding", "identity"),
    ]
    /// The wait for each response or chunk of data.
    public static let requestTimeout: TimeInterval = 30
    /// The whole fetch, redirects included.
    public static let resourceTimeout: TimeInterval = 60

    let url: URL
    let allowedHosts: [String]
    let maxBytes: Int
    /// Test only (`init(loopbackTestURL:)`): plain http to 127.0.0.1 on any
    /// port, which the shipped source never allows.
    let loopbackHTTP: Bool

    /// The shipped source: the fixed URL, the fixed hosts, the fixed cap.
    public init() {
        // The literal is a valid URL (a test holds it), so this cannot fail.
        self.url = URL(string: ReleaseIndex.latestIndexURL) ?? URL(fileURLWithPath: "/")
        self.allowedHosts = ReleaseIndex.allowedHosts
        self.maxBytes = ReleaseIndexVerifier.maxSignedBytes
        self.loopbackHTTP = false
    }

    /// The test initializer: a loopback server on 127.0.0.1 over plain http,
    /// so a test can capture the bytes on the wire. It is internal and no
    /// shipped path reaches it.
    init(loopbackTestURL url: URL, maxBytes: Int = ReleaseIndexVerifier.maxSignedBytes) {
        self.url = url
        self.allowedHosts = ["127.0.0.1"]
        self.maxBytes = maxBytes
        self.loopbackHTTP = true
    }

    /// The session configuration: ephemeral, with no store of any kind.
    public static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = nil
        config.httpMaximumConnectionsPerHost = 1
        return config
    }

    /// The request for `url`: a GET with exactly `headers`.
    public static func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: requestTimeout)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        for header in headers {
            request.setValue(header.value, forHTTPHeaderField: header.name)
        }
        return request
    }

    /// Whether `url` may be requested: https (or, for the test source only,
    /// http to 127.0.0.1), a host in `allowedHosts` exactly, no user,
    /// password, query or fragment, and the default port.
    static func permits(_ url: URL?, allowedHosts: [String], loopbackHTTP: Bool) -> Bool {
        guard let url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = parts.host?.lowercased(), allowedHosts.contains(host),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil
        else { return false }
        if loopbackHTTP, host == "127.0.0.1", parts.scheme == "http" { return true }
        return parts.scheme == "https" && (parts.port == nil || parts.port == 443)
    }

    public func fetch() async throws(IndexFetchError) -> Data {
        guard Self.permits(url, allowedHosts: allowedHosts, loopbackHTTP: loopbackHTTP) else { throw .urlRefused }
        let guardian = HopGuard(allowedHosts: allowedHosts, loopbackHTTP: loopbackHTTP)
        let session = URLSession(configuration: Self.configuration(), delegate: guardian, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: Self.request(for: url))
        } catch {
            throw Self.mapped(error, guardian)
        }
        if guardian.refused { throw .redirectRefused }
        guard let http = response as? HTTPURLResponse else { throw .status(0) }
        guard http.statusCode == 200 else { throw .status(http.statusCode) }
        guard Self.permits(http.url, allowedHosts: allowedHosts, loopbackHTTP: loopbackHTTP) else { throw .redirectRefused }
        if http.expectedContentLength > Int64(maxBytes) {
            bytes.task.cancel()
            throw .tooLarge
        }
        var data = Data()
        data.reserveCapacity(min(maxBytes + 1, max(0, Int(http.expectedContentLength))))
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxBytes {
                    bytes.task.cancel()
                    throw IndexFetchError.tooLarge
                }
            }
        } catch let error as IndexFetchError {
            throw error
        } catch {
            throw Self.mapped(error, guardian)
        }
        return data
    }

    private static func mapped(_ error: any Error, _ guardian: HopGuard) -> IndexFetchError {
        if guardian.refused { return .redirectRefused }
        guard let error = error as? URLError else { return .network(URLError.Code.unknown.rawValue) }
        return error.code == .timedOut ? .timedOut : .network(error.code.rawValue)
    }
}

/// HopGuard is the session's delegate: it refuses a redirect to any URL the
/// source does not permit, and answers every authentication challenge but
/// the server's TLS trust by cancelling it, so no credential is ever sent.
final class HopGuard: NSObject, URLSessionTaskDelegate, Sendable {
    private let allowedHosts: [String]
    private let loopbackHTTP: Bool
    private let refusedHop = Mutex(false)

    init(allowedHosts: [String], loopbackHTTP: Bool) {
        self.allowedHosts = allowedHosts
        self.loopbackHTTP = loopbackHTTP
    }

    /// Whether a redirect was refused.
    var refused: Bool { refusedHop.withLock { $0 } }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let next = request.url,
              URLSessionIndexSource.permits(next, allowedHosts: allowedHosts, loopbackHTTP: loopbackHTTP)
        else {
            refusedHop.withLock { $0 = true }
            AppUpdateLog.logger.notice("app update: refused a redirect to a host that is not allowed")
            return nil
        }
        // A fresh request carries exactly the fixed headers, never what the
        // system copied from the previous hop.
        return URLSessionIndexSource.request(for: next)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            return (.performDefaultHandling, nil)
        }
        return (.cancelAuthenticationChallenge, nil)
    }
}
