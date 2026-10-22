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
import Synchronization
import Testing

@testable import K3smHost
@testable import K3smStatus

/// SpySource counts fetches and returns a scripted result.
final class SpySource: IndexSource {
    private let count = Mutex(0)
    private let result: Result<Data, IndexFetchError>
    init(_ result: Result<Data, IndexFetchError> = .success(Data("signed".utf8))) { self.result = result }
    var fetches: Int { count.withLock { $0 } }
    func fetch() async throws(IndexFetchError) -> Data {
        count.withLock { $0 += 1 }
        return try result.get()
    }
}

/// SpyVerify counts calls and returns scripted facts.
final class SpyVerify: Sendable {
    private let count = Mutex(0)
    let facts: AppIndexFacts?
    init(_ facts: AppIndexFacts?) { self.facts = facts }
    var calls: Int { count.withLock { $0 } }
    struct Refused: Error, CustomStringConvertible { var description: String { "the signature is not valid" } }
    func verify(_ data: Data) throws -> AppIndexFacts {
        count.withLock { $0 += 1 }
        guard let facts else { throw Refused() }
        return facts
    }
}

@Suite("the app update check's request and loop")
struct AppUpdateCheckerTests {
    static let t0 = Date(timeIntervalSince1970: 1_790_856_000)

    static func fresh() -> (UserDefaults, AppPreferences) {
        let name = "io.k3sm.app.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return (defaults, AppPreferences(defaults: defaults))
    }

    static func facts(_ tag: String, issued: Date = t0) -> AppIndexFacts {
        AppIndexFacts(tag: tag, issuedAt: issued, signedAt: t0, macOS: .supported)
    }

    static func checker(_ source: any IndexSource, _ spy: SpyVerify, _ prefs: AppPreferences,
                        ownTag: String? = "v0.2.0", pinned: Bool = true) -> AppUpdateChecker<AppIndexFacts> {
        AppUpdateChecker(source: source, verify: { try spy.verify($0) }, facts: { $0 }, preferences: prefs,
                         ownTag: ownTag, pinned: pinned, clock: { t0 })
    }

    /// The request golden: method, URL, exactly the fixed headers, no
    /// cookies, the cache bypassed; and the ephemeral configuration.
    @Test func requestGolden() throws {
        let request = URLSessionIndexSource.request(for: try #require(URL(string: ReleaseIndex.latestIndexURL)))
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://github.com/k3sm-io/k3sm/releases/latest/download/k3sm_release-index.p7m")
        #expect(request.url?.query == nil)
        #expect(request.allHTTPHeaderFields == [
            "User-Agent": "k3sm-app", "Accept": "*/*", "Accept-Language": "en", "Accept-Encoding": "identity",
        ])
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
        #expect(request.httpBody == nil)

        let config = URLSessionIndexSource.configuration()
        #expect(config.httpCookieStorage == nil)
        #expect(config.urlCache == nil)
        #expect(config.urlCredentialStorage == nil)
        #expect(config.httpShouldSetCookies == false)
        #expect(config.httpCookieAcceptPolicy == .never)
        #expect(config.requestCachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
        #expect(config.httpAdditionalHeaders == nil)
        #expect(config.timeoutIntervalForRequest == URLSessionIndexSource.requestTimeout)
        #expect(config.timeoutIntervalForResource == URLSessionIndexSource.resourceTimeout)

        let shipped = URLSessionIndexSource()
        #expect(shipped.url.absoluteString == ReleaseIndex.latestIndexURL)
        #expect(shipped.allowedHosts == ReleaseIndex.allowedHosts)
        #expect(shipped.maxBytes == 262_144)
        #expect(!shipped.loopbackHTTP)
    }

    /// Every hop is held to https on the allowed hosts.
    @Test func hopPolicy() {
        let hosts = ReleaseIndex.allowedHosts
        func ok(_ s: String, loopback: Bool = false, hosts: [String] = hosts) -> Bool {
            URLSessionIndexSource.permits(URL(string: s), allowedHosts: hosts, loopbackHTTP: loopback)
        }
        #expect(ok("https://github.com/k3sm-io/k3sm/releases/latest/download/k3sm_release-index.p7m"))
        #expect(ok("https://objects.githubusercontent.com/github-production-release-asset/1/2"))
        #expect(ok("https://release-assets.githubusercontent.com/a/b"))
        #expect(ok("https://GitHub.com/x"))
        #expect(ok("https://github.com:443/x"))
        #expect(!ok("http://github.com/x"))
        #expect(!ok("https://github.com:8443/x"))
        #expect(!ok("https://evil.example/x"))
        #expect(!ok("https://github.com.evil.example/x"))
        #expect(!ok("https://user:pw@github.com/x"))
        #expect(!ok("https://github.com/x?mac=1"))
        #expect(!ok("https://github.com/x#f"))
        #expect(!ok("ftp://github.com/x"))
        // The test source's loopback http is for 127.0.0.1 only, and never in the shipped source.
        #expect(ok("http://127.0.0.1:8080/x", loopback: true, hosts: ["127.0.0.1"]))
        #expect(!ok("http://127.0.0.1:8080/x", loopback: false, hosts: ["127.0.0.1"]))
        #expect(!ok("http://evil.example/x", loopback: true, hosts: ["127.0.0.1"]))
    }

    /// The bytes on the wire, captured by a loopback server: the request
    /// line, Host, the four fixed headers, and the two CFNetwork adds on its
    /// own (`Cache-Control: no-cache` from the cache policy, and
    /// `Connection: keep-alive`), and nothing else.
    /// No cookie, no credential, no query, no version, no language of the
    /// user's own.
    @Test func wireCapture() async throws {
        let server = try LoopbackServer(responses: [LoopbackServer.response("200 OK", body: Data("signed-index".utf8))])
        defer { server.stop() }
        let source = URLSessionIndexSource(loopbackTestURL: server.url("/k3sm_release-index.p7m"))
        let body = try await source.fetch()
        #expect(body == Data("signed-index".utf8))
        let captured = try #require(server.requests.first)
        let text = String(decoding: captured, as: UTF8.self)
        print("captured request bytes:\n" + text.replacingOccurrences(of: "\r\n", with: "\\r\\n\n"))
        let lines = text.components(separatedBy: "\r\n")
        #expect(lines.first == "GET /k3sm_release-index.p7m HTTP/1.1")
        #expect(text.hasSuffix("\r\n\r\n"))
        let headers = lines.dropFirst().filter { !$0.isEmpty }
        var fields: [String: String] = [:]
        for line in headers {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            #expect(parts.count == 2, "\(line)")
            fields[parts[0].lowercased()] = parts.count == 2 ? parts[1] : ""
        }
        #expect(fields == [
            "host": "127.0.0.1:\(server.port)",
            "user-agent": "k3sm-app",
            "accept": "*/*",
            "accept-language": "en",
            "accept-encoding": "identity",
            // CFNetwork's own two: the cache bypass and the connection.
            "cache-control": "no-cache",
            "connection": "keep-alive",
        ], "\(fields)")
        #expect(server.requests.count == 1)
    }

    /// A redirect to a foreign host, or to http, is refused before it is
    /// followed: one request reaches the server, none goes anywhere else.
    @Test(arguments: ["https://evil.example/index.p7m", "http://github.com/index.p7m", "https://github.com.evil.example/x"])
    func redirectToAForeignHostOrHTTPIsRefused(_ location: String) async throws {
        let server = try LoopbackServer(responses: [LoopbackServer.response("302 Found", headers: ["Location: \(location)"])])
        defer { server.stop() }
        let source = URLSessionIndexSource(loopbackTestURL: server.url("/k3sm_release-index.p7m"))
        await #expect(throws: IndexFetchError.redirectRefused) { _ = try await source.fetch() }
        #expect(server.requests.count == 1)
    }

    /// A non-200 answer is refused.
    @Test func a404IsRefused() async throws {
        let server = try LoopbackServer(responses: [LoopbackServer.response("404 Not Found")])
        defer { server.stop() }
        let source = URLSessionIndexSource(loopbackTestURL: server.url("/x"))
        await #expect(throws: IndexFetchError.status(404)) { _ = try await source.fetch() }
    }

    /// A body over the cap, with or without a Content-Length, is refused by
    /// the fetch, and the signature check is never called.
    @Test(arguments: [true, false])
    func overCapBodyIsRefusedBeforeVerify(_ sendsLength: Bool) async throws {
        let big = Data(repeating: 0x30, count: 262_144 + 1)
        let server = try LoopbackServer(responses: [LoopbackServer.response("200 OK", body: big, length: sendsLength)])
        defer { server.stop() }
        let (_, prefs) = Self.fresh()
        let spy = SpyVerify(Self.facts("v0.3.0"))
        let source = URLSessionIndexSource(loopbackTestURL: server.url("/x"))
        let result = await Self.checker(source, spy, prefs).check(userInitiated: true)
        #expect(spy.calls == 0)
        #expect(result.state == .couldNotCheck(reason: IndexFetchError.tooLarge.description))
        #expect(prefs.appIndexHighWater == .absent)
        // Exactly the cap is read whole and handed on.
        let atCap = try LoopbackServer(responses: [LoopbackServer.response("200 OK", body: Data(big.dropLast()), length: sendsLength)])
        defer { atCap.stop() }
        let data = try await URLSessionIndexSource(loopbackTestURL: atCap.url("/x")).fetch()
        #expect(data.count == 262_144)
    }

    /// With checks off, an automatic check constructs no request; Check Now
    /// still makes one. A development build never makes one.
    @Test func checksOffSendsNoRequest() async throws {
        let server = try LoopbackServer(responses: [LoopbackServer.response("404 Not Found")])
        defer { server.stop() }
        let (_, prefs) = Self.fresh()
        prefs.checkAppUpdates = false
        let spy = SpyVerify(Self.facts("v0.3.0"))
        let wire = URLSessionIndexSource(loopbackTestURL: server.url("/x"))
        let counted = SpySource()

        for source in [wire as any IndexSource, counted] {
            let result = await Self.checker(source, spy, prefs).check(userInitiated: false)
            #expect(result.state == .checksOff)
            #expect(result.outcome == nil)
        }
        #expect(counted.fetches == 0)
        #expect(server.requests.isEmpty)
        #expect(spy.calls == 0)

        // Check Now asks once, checks off or not.
        let now = await Self.checker(counted, spy, prefs).check(userInitiated: true)
        #expect(counted.fetches == 1)
        #expect(now.state == .available(tag: "v0.3.0"))

        // A development build (no pin, or no payload tag) never asks.
        prefs.checkAppUpdates = true
        let dev = SpySource()
        #expect(await Self.checker(dev, spy, prefs, pinned: false).check(userInitiated: true).state == .development)
        #expect(await Self.checker(dev, spy, prefs, ownTag: nil).check(userInitiated: true).state == .development)
        #expect(dev.fetches == 0)
    }

    /// The check starts no roll: its sources name no runner, driver or root
    /// step type, and a whole accepted check touches nothing but the three
    /// records it owns.
    @Test func appUpdateNeverStartsARoll() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let forbidden = ["UpdateDriver", "BundledRoll", "PrivilegedRunner", "AppleScriptPrivilegedRunner", "CopyOut",
                         "RootScript", "LifecycleDriver", "CLIProcess", "CLIStream", "K3smCLI", "Process(", "posix_spawn",
                         "SwapEngine", "HelperSpawner", "K3smSwap", "NSAppleScript", "UpdatePlan"]
        for file in ["Sources/K3smHost/AppUpdateChecker.swift", "Sources/K3smHost/ReleaseIndexFetcher.swift"] {
            let code = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line) }
                .joined(separator: "\n")
            #expect(code.count > 1000, "\(file) was not read")
            for word in forbidden {
                #expect(!code.contains(word), "\(file) names \(word)")
            }
        }

        let (defaults, prefs) = Self.fresh()
        let before = Set(defaults.dictionaryRepresentation().keys)
        let spy = SpyVerify(Self.facts("v0.3.0"))
        let source = SpySource()
        let result = await Self.checker(source, spy, prefs).check(userInitiated: false)
        #expect(result.state == .available(tag: "v0.3.0"))
        #expect(source.fetches == 1)
        #expect(spy.calls == 1)
        let written = Set(defaults.dictionaryRepresentation().keys).subtracting(before)
        #expect(written == [AppPreferences.appIndexHighWaterTagKey, AppPreferences.appIndexHighWaterIssuedAtKey,
                            AppPreferences.appUpdateLastCheckKey])
    }

    /// Fetch, verify, accept, store: the pair and the time are stored only
    /// on acceptance; a refusal or a failure stores nothing and is never an
    /// offer; a garbage stored pair is treated as absent.
    @Test func acceptStoreAndRefuse() async throws {
        let (defaults, prefs) = Self.fresh()
        let accepted = await Self.checker(SpySource(), SpyVerify(Self.facts("v0.3.0")), prefs).check(userInitiated: false)
        #expect(accepted.state == .available(tag: "v0.3.0"))
        #expect(accepted.verified == Self.facts("v0.3.0"))
        #expect(prefs.appIndexHighWater == .stored(AppIndexHighWater(tag: "v0.3.0", issuedAt: Self.t0)!))
        #expect(prefs.appUpdateLastCheck == Self.t0)

        // A replayed lower release is refused; the mark and the time stay.
        prefs.appUpdateLastCheck = Self.t0.addingTimeInterval(-1)
        let replay = await Self.checker(SpySource(), SpyVerify(Self.facts("v0.2.5")), prefs).check(userInitiated: false)
        #expect(replay.state == .couldNotCheck(reason: "the index names an older release than v0.3.0, already seen"))
        #expect(replay.verified == nil)
        #expect(prefs.appIndexHighWater == .stored(AppIndexHighWater(tag: "v0.3.0", issuedAt: Self.t0)!))
        #expect(prefs.appUpdateLastCheck == Self.t0.addingTimeInterval(-1))

        // An index dated past its signature by more than the skew is refused.
        let late = AppIndexFacts(tag: "v0.4.0", issuedAt: Self.t0.addingTimeInterval(601), signedAt: Self.t0, macOS: .supported)
        let skewed = await Self.checker(SpySource(), SpyVerify(late), prefs).check(userInitiated: false)
        #expect(skewed.state == .couldNotCheck(reason: "the index is dated 601 seconds after its signature"))

        // A signature failure and a network failure are could-not-check.
        let unsigned = await Self.checker(SpySource(), SpyVerify(nil), prefs).check(userInitiated: false)
        #expect(unsigned.state == .couldNotCheck(reason: "could not verify the release index: the signature is not valid"))
        let offline = await Self.checker(SpySource(.failure(.timedOut)), SpyVerify(Self.facts("v0.9.0")), prefs).check(userInitiated: false)
        #expect(offline.state == .couldNotCheck(reason: "the request timed out"))
        #expect(prefs.appIndexHighWater.pair?.tag == "v0.3.0")

        // A garbage stored pair: treated as absent, and replaced on acceptance.
        defaults.set(42, forKey: AppPreferences.appIndexHighWaterTagKey)
        #expect(prefs.appIndexHighWater == .garbage)
        let afterGarbage = await Self.checker(SpySource(), SpyVerify(Self.facts("v0.2.0")), prefs).check(userInitiated: false)
        #expect(afterGarbage.state == .upToDate(tag: "v0.2.0"))
        #expect(prefs.appIndexHighWater == .stored(AppIndexHighWater(tag: "v0.2.0", issuedAt: Self.t0)!))
    }
}
