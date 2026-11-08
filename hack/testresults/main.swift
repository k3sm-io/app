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

// testresults applies the flake quarantine registry (hack/quarantine.txt) to a
// swift-testing event stream (`swift test --experimental-event-stream-output`).
// It is this repository's copy of the shared k3sm quarantine rules, the ones the
// Go repositories carry as hack/lib/testresults.go and the workspace as
// hack/lib/quarantine.py: a lone clone gates itself, and a change to the rules
// updates every copy in the same change. It is built with swiftc alone
// (Foundation, no package) by hack/testresults.sh, whose --self-test runs the
// cases under hack/testdata/testresults.
//
// Usage:
//
//	testresults --events <events.jsonl> --tier fast|full [--registry hack/quarantine.txt]
//	            [--log <console log>] [--today YYYY-MM-DD] [--edited <target>]...
//
// A test's id is <TestTarget>/<Suite>[/<NestedSuite>...]/<function>, the
// function written as swift-testing names it, argument labels included:
// K3smStatusTests/LogColumnsTests/contentWidth(). The PACKAGE of the shared
// rules is the test target. --edited names a target the change edits
// directly; it covers that target and its test target (<target>Tests).
//
// The registry is validated on every run, whatever the tier: a malformed line,
// a refused entry (a K3smInstall* target or another trust surface, a race or
// sanitizer signature, a sig shorter than 12 characters or one that occurs in
// the test id or the Go harness lines, an 11th entry) or an entry past its
// deadline reds. The full tier reds on every failure. The fast tier
// (`affected` is accepted as its other name) excuses a failure only when the
// test is listed, its target is not an edited one, every iteration of it that
// failed carries the recorded signature in its failing issues' messages, and
// that text carries no race or sanitizer report.
//
// The stream fails closed: a line that is not JSON, a record that is not a
// test or an event, an event kind this reader does not know, a run that
// started and never ended, a test that started and never ended or was declared
// and never ran, and a failing issue recorded outside any test function each
// red. A race or sanitizer report in the console log (--log) reds whatever is
// listed. Ids built for such failures hold a space, so no registry line can
// name them.
//
// Exit status: 0 green with no failing test; 3 green because every failure was
// excused by the registry (so swift test itself exited 1); 1 red; 2 usage.

import Foundation

let maxEntries = 10
let minSigChars = 12
let exitGreen: Int32 = 0
let exitRed: Int32 = 1
let exitUsage: Int32 = 2
let exitExcused: Int32 = 3

let requiredKeys = ["sig", "owner", "filed", "deadline", "fix", "reason"]

// A race or sanitizer report is never quarantinable.
let raceMarkers = [
    "WARNING: DATA RACE",
    "race detected during execution of test",
    "ThreadSanitizer",
    "AddressSanitizer",
    "UndefinedBehaviorSanitizer",
    "LeakSanitizer",
    "MemorySanitizer",
]

// Trust surfaces: never quarantined. Over-refusal is the safe direction. The
// Go-path rules never match a Swift target; they are kept so that every copy
// refuses the same lines.
let protectedPathSegments: [(String, String)] = [("pkg", "certs"), ("pkg", "bootstrap"), ("pkg", "rbac")]
let protectedPackages = ["k3sm.io/runtimed/pkg/image"]
let protectedPackagePrefixes = ["K3smInstall"] // the app's checked root step
let protectedNameKeywords = ["signaturepolicy", "sigpolicy", "cosign", "rbac", "k3sminstall"]

// The event kinds this reader knows, the same list as
// hack/acceptance/lib/test-passed.sh. Any other kind fails the read.
let knownEventKinds: Set<String> = [
    "runStarted", "runEnded", "iterationStarted", "iterationEnded", "testStarted", "testEnded",
    "testCaseStarted", "testCaseEnded", "testSkipped", "issueRecorded", "valueAttached",
]

// MARK: - text helpers (Go's semantics, so every copy reads a line alike)

// Go's unicode.IsSpace set, which strings.TrimSpace trims.
let goSpace: Set<Unicode.Scalar> = Set(
    "\t\n\u{0B}\u{0C}\r \u{85}\u{A0}\u{1680}\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}"
        .unicodeScalars)
// RE2's \s: [\t\n\f\r ].
let re2Space: Set<Unicode.Scalar> = ["\t", "\n", "\u{0C}", "\r", " "]

func scalars(_ s: String) -> [Unicode.Scalar] { Array(s.unicodeScalars) }
func string(_ s: ArraySlice<Unicode.Scalar>) -> String {
    var v = String.UnicodeScalarView()
    v.append(contentsOf: s)
    return String(v)
}
func string(_ s: [Unicode.Scalar]) -> String { string(s[...]) }

func trimSpace(_ s: String) -> String {
    let a = scalars(s)
    var lo = 0, hi = a.count
    while lo < hi, goSpace.contains(a[lo]) { lo += 1 }
    while hi > lo, goSpace.contains(a[hi - 1]) { hi -= 1 }
    return string(a[lo..<hi])
}

// splitLF splits on LF only, after CRLF becomes LF: a lone CR, or any other
// separator, stays inside its line, as in the Go copy.
func splitLF(_ s: String) -> [String] {
    var lines: [String] = []
    var cur = String.UnicodeScalarView()
    let a = scalars(s)
    var i = 0
    while i < a.count {
        let c = a[i]
        if c == "\r", i + 1 < a.count, a[i + 1] == "\n" {
            i += 1
            continue
        }
        if c == "\n" {
            lines.append(String(cur))
            cur = String.UnicodeScalarView()
        } else {
            cur.append(c)
        }
        i += 1
    }
    lines.append(String(cur))
    return lines
}

func isDigit(_ c: Unicode.Scalar) -> Bool { c >= "0" && c <= "9" }
func isIdentStart(_ c: Unicode.Scalar) -> Bool { (c >= "A" && c <= "Z") || (c >= "a" && c <= "z") || c == "_" }
func isIdent(_ c: Unicode.Scalar) -> Bool { isIdentStart(c) || isDigit(c) }

// collapseSpace is Go's spaceRE.ReplaceAllString(s, " ") then TrimSpace.
func norm(_ s: String) -> String {
    var out = String.UnicodeScalarView()
    var inRun = false
    for c in s.unicodeScalars {
        if re2Space.contains(c) {
            if !inRun { out.append(" ") }
            inRun = true
        } else {
            out.append(c)
            inRun = false
        }
    }
    return trimSpace(String(out))
}

// dropDuration is Go's durationRE `\(\d+(?:\.\d+)?s\)?\s*$` replaced by "(".
func dropDuration(_ s: String) -> String {
    let a = scalars(s)
    var end = a.count
    while end > 0, re2Space.contains(a[end - 1]) { end -= 1 }
    // Try every "(" from the right whose tail matches; the regex's leftmost
    // match is the earliest start that matches through to the end.
    var best: Int? = nil
    for start in 0..<a.count where a[start] == "(" {
        var i = start + 1
        var n = 0
        while i < end, isDigit(a[i]) { i += 1; n += 1 }
        if n == 0 { continue }
        if i < end, a[i] == "." {
            var j = i + 1, m = 0
            while j < end, isDigit(a[j]) { j += 1; m += 1 }
            if m > 0 { i = j }
        }
        guard i < end, a[i] == "s" else { continue }
        i += 1
        if i < end, a[i] == ")" { i += 1 }
        if i == end { best = start; break }
    }
    guard let b = best else { return s }
    return string(a[0..<b]) + "("
}

// MARK: - the registry

struct Entry {
    let line: Int
    let test: String
    let pkg: String
    let sig: String
    let owner: String
    let fix: String
    let deadline: String
}

func validDate(_ s: String) -> Bool {
    let a = scalars(s)
    guard a.count == 10, a[4] == "-", a[7] == "-" else { return false }
    for (i, c) in a.enumerated() where i != 4 && i != 7 { if !isDigit(c) { return false } }
    guard let y = Int(string(a[0..<4])), let m = Int(string(a[5..<7])), let d = Int(string(a[8..<10])) else { return false }
    guard (1...12).contains(m), d >= 1 else { return false }
    let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
    let dim = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m - 1]
    return d <= dim
}

// splitTestID returns (target, suite/test) for a Swift <Target>/<Suite>/<test>
// id. A Go id (<import path>::<TestName>) names no test this repository runs, so
// this copy refuses it.
func splitTestID(_ test: String) -> (String, String)? {
    if test.contains("::") { return nil }
    let a = scalars(test)
    var i = 0
    func ident() -> String? {
        guard i < a.count, isIdentStart(a[i]) else { return nil }
        let s = i
        while i < a.count, isIdent(a[i]) { i += 1 }
        return string(a[s..<i])
    }
    guard let target = ident(), i < a.count, a[i] == "/" else { return nil }
    i += 1
    guard let suite = ident(), i < a.count, a[i] == "/" else { return nil }
    i += 1
    let rest = a[i...]
    guard !rest.isEmpty, !rest.contains(where: { re2Space.contains($0) }) else { return nil }
    return (target, suite + "/" + string(rest))
}

func raceMarker(_ text: String) -> String? { raceMarkers.first { text.contains($0) } }

func harnessReason(_ test: String, _ name: String, _ sig: String) -> String? {
    let s = norm(dropDuration(sig))
    if s.isEmpty { return nil }
    if test.contains(s) || test.contains(norm(sig)) { return "the test id" }
    for h in ["=== RUN " + name, "--- FAIL: " + name + " ("] where h.contains(s) {
        return "the harness line " + (h.hasSuffix(" (") ? String(h.dropLast(2)) : h)
    }
    return nil
}

func protectedReason(_ pkg: String, _ name: String) -> String? {
    let segs = pkg.components(separatedBy: "/")
    for (a, b) in protectedPathSegments where segs.count >= 2 {
        for i in 0..<(segs.count - 1) where segs[i] == a && segs[i + 1] == b {
            return "trust surface \(a)/\(b)"
        }
    }
    for p in protectedPackages where pkg == p || pkg.hasPrefix(p + "/") {
        return "trust surface \(p) (signature policy)"
    }
    for p in protectedPackagePrefixes where pkg.hasPrefix(p) {
        return "trust surface " + p
    }
    let low = name.lowercased()
    for k in protectedNameKeywords where low.contains(k) {
        return "trust surface: test name names \(quote(k))"
    }
    return nil
}

// quote renders s the way Go's %q does for the printable ASCII this report uses.
func quote(_ s: String) -> String {
    var out = "\""
    for c in s.unicodeScalars {
        switch c {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if c.value < 0x20 || c.value == 0x7F {
                out += String(format: "\\x%02x", c.value)
            } else {
                out.unicodeScalars.append(c)
            }
        }
    }
    return out + "\""
}

// stripComment drops a `#` comment that starts the line or follows whitespace,
// outside quotes.
func stripComment(_ line: String) -> String {
    let a = scalars(line)
    var q: Unicode.Scalar? = nil
    var prevSpace = true
    for (i, ch) in a.enumerated() {
        if let qq = q {
            if ch == qq { q = nil }
        } else if ch == "\"" || ch == "'" {
            q = ch
        } else if ch == "#" && prevSpace {
            return string(a[0..<i])
        }
        prevSpace = ch == " " || ch == "\t" || ch == "\r" || ch == "\n" || ch == "\u{0B}" || ch == "\u{0C}"
    }
    return line
}

struct SplitError: Error { let why: String }

// shellSplit splits a line into words the way a POSIX shell lexer does: blanks
// separate words, single quotes are literal, double quotes allow \" and \\, and
// a backslash outside quotes escapes the next character.
func shellSplit(_ s: String) throws -> [String] {
    var words: [String] = []
    var cur = String.UnicodeScalarView()
    var inWord = false
    let rs = scalars(s)
    var i = 0
    while i < rs.count {
        let ch = rs[i]
        switch ch {
        case " ", "\t", "\r", "\n":
            if inWord {
                words.append(String(cur))
                cur = String.UnicodeScalarView()
                inWord = false
            }
        case "\\":
            if i + 1 >= rs.count { throw SplitError(why: "no escaped character") }
            i += 1
            cur.append(rs[i])
            inWord = true
        case "'":
            var j = i + 1
            while j < rs.count, rs[j] != "'" { j += 1 }
            if j >= rs.count { throw SplitError(why: "no closing quotation") }
            cur.append(contentsOf: rs[(i + 1)..<j])
            i = j
            inWord = true
        case "\"":
            var j = i + 1
            while j < rs.count, rs[j] != "\"" {
                if rs[j] == "\\", j + 1 < rs.count, rs[j + 1] == "\"" || rs[j + 1] == "\\" { j += 1 }
                cur.append(rs[j])
                j += 1
            }
            if j >= rs.count { throw SplitError(why: "no closing quotation") }
            i = j
            inWord = true
        default:
            cur.append(ch)
            inWord = true
        }
        i += 1
    }
    if inWord { words.append(String(cur)) }
    return words
}

// keyValue is Go's keyRE `(?s)^([a-z]+)=(.*)$`.
func keyValue(_ t: String) -> (String, String)? {
    let a = scalars(t)
    var i = 0
    while i < a.count, a[i] >= "a", a[i] <= "z" { i += 1 }
    guard i > 0, i < a.count, a[i] == "=" else { return nil }
    return (string(a[0..<i]), string(a[(i + 1)...]))
}

// parseRegistry returns the valid entries and every error; any error makes the
// registry invalid.
func parseRegistry(_ text: String) -> ([Entry], [String]) {
    var entries: [Entry] = []
    var errs: [String] = []
    var seen: [String: Int] = [:]
    var listed = 0
    for (n, raw) in splitLF(text).enumerated() {
        let lineno = n + 1
        let line = trimSpace(stripComment(raw))
        if line.isEmpty { continue }
        listed += 1
        let at = "line \(lineno)"
        let toks: [String]
        do { toks = try shellSplit(line) } catch let e as SplitError {
            errs.append("\(at): unparseable (\(e.why))")
            continue
        } catch { continue }
        guard let test = toks.first else { continue }
        guard let (pkg, name) = splitTestID(test) else {
            errs.append("\(at): \(quote(test)) is not a Swift <Target>/<Suite>/<test> id")
            continue
        }
        var fields: [String: String] = [:]
        var bad = false
        for t in toks.dropFirst() {
            guard let (k, v) = keyValue(t) else {
                errs.append("\(at): token \(quote(t)) is not key=value")
                bad = true
                continue
            }
            if !requiredKeys.contains(k) {
                errs.append("\(at): unknown key \(quote(k))")
                bad = true
            } else if fields[k] != nil {
                errs.append("\(at): key \(quote(k)) repeats")
                bad = true
            } else if trimSpace(v).isEmpty {
                errs.append("\(at): key \(quote(k)) is empty")
                bad = true
            } else {
                fields[k] = v
            }
        }
        let missing = requiredKeys.filter { fields[$0] == nil }
        if !missing.isEmpty {
            errs.append("\(at): missing \(missing.joined(separator: ", "))")
            bad = true
        }
        if bad { continue }
        let filed = fields["filed"]!, deadline = fields["deadline"]!, sig = fields["sig"]!
        if !validDate(filed) {
            errs.append("\(at): filed=\(quote(filed)) is not a YYYY-MM-DD date")
            continue
        }
        if !validDate(deadline) {
            errs.append("\(at): deadline=\(quote(deadline)) is not a YYYY-MM-DD date")
            continue
        }
        if deadline < filed {
            errs.append("\(at): deadline \(deadline) is before filed \(filed)")
            continue
        }
        if sig.unicodeScalars.count < minSigChars {
            errs.append("\(at): sig is shorter than \(minSigChars) characters, so it would match nearly any failure")
            continue
        }
        if let rm = raceMarker(sig) {
            errs.append("\(at): refused, a race or sanitizer report is never quarantinable (sig carries \(quote(rm)))")
            continue
        }
        if let hr = harnessReason(test, name, sig) {
            errs.append("\(at): sig occurs in \(hr), so it matches the harness's own lines, not a failure (harness)")
            continue
        }
        if let pr = protectedReason(pkg, name) {
            errs.append("\(at): refused, \(test) can never be quarantined (\(pr))")
            continue
        }
        if let prev = seen[test] {
            errs.append("\(at): \(test) is already listed on line \(prev)")
            continue
        }
        seen[test] = lineno
        entries.append(Entry(line: lineno, test: test, pkg: pkg, sig: sig, owner: fields["owner"]!,
                             fix: fields["fix"]!, deadline: deadline))
    }
    if listed > maxEntries {
        errs.append("registry lists \(listed) entries; at most \(maxEntries) are allowed")
    }
    return (entries, errs)
}

// MARK: - the verdict

struct Result {
    let test: String
    let target: String
    let status: String? // pass, fail, skip; nil when the test has no result
    let why: String // for a nil status: what is missing
    let failedRuns: [String] // the failing issues' text of each iteration that failed
}

func carriedByEveryRun(_ runs: [String], _ sig: String) -> Bool {
    !runs.isEmpty && runs.allSatisfy { $0.contains(sig) }
}

func evaluate(_ registry: String, _ results: [Result], _ tier: String, _ edited: [String], _ today: String)
    -> (red: Bool, excused: Int, lines: [String]) {
    var red = false, excused = 0
    var lines: [String] = []
    let (entries, errs) = parseRegistry(registry)
    for e in errs {
        lines.append("RED registry: " + e)
        red = true
    }
    var byID: [String: Entry] = [:]
    for e in entries {
        if e.deadline < today {
            lines.append("RED \(e.test): quarantine expired \(e.deadline) (owner \(e.owner), fix \(e.fix))")
            red = true
        }
        byID[e.test] = e
    }
    var editedSet = Set<String>()
    for t in edited {
        editedSet.insert(t)
        editedSet.insert(t + "Tests")
    }
    for r in results {
        switch r.status {
        case "pass", "skip":
            if byID[r.test] != nil { lines.append("ok  \(r.test): quarantined test \(r.status!)ed") }
            continue
        case "fail":
            break
        default:
            lines.append("RED \(r.test): no result (\(r.why))")
            red = true
            continue
        }
        guard let e = byID[r.test] else {
            lines.append("RED \(r.test): failed")
            red = true
            continue
        }
        if let rm = raceMarker(r.failedRuns.joined(separator: "\n")) {
            lines.append("RED \(r.test): failed with a race or sanitizer report (\(quote(rm))); quarantine never applies")
            red = true
        } else if tier == "full" {
            lines.append("RED \(r.test): quarantined test failed; the full tier reds on it (fix \(e.fix), deadline \(e.deadline))")
            red = true
        } else if editedSet.contains(e.pkg) {
            lines.append("RED \(r.test): quarantined, but the change edits \(e.pkg) directly")
            red = true
        } else if !carriedByEveryRun(r.failedRuns, e.sig) {
            lines.append("RED \(r.test): quarantined, but the failure does not match the recorded signature")
            red = true
        } else {
            excused += 1
            lines.append("QUARANTINED \(r.test): failed with its recorded signature; reported, not red (owner \(e.owner), fix \(e.fix), deadline \(e.deadline))")
        }
    }
    return (red, excused, lines)
}

// MARK: - the event stream

// registryID turns a swift-testing function id,
// <Module>.<Suite>[/<Nested>...]/<name>/<file>:<line>:<column>, into the
// registry's <Target>/<Suite>[/<Nested>...]/<name>. A function outside any
// suite, or an id of another shape, has none.
func registryID(_ id: String, _ name: String) -> String? {
    let comps = id.components(separatedBy: "/")
    guard comps.count >= 3, comps[comps.count - 2] == name, let dot = comps[0].firstIndex(of: ".") else { return nil }
    let module = comps[0][..<dot], top = comps[0][comps[0].index(after: dot)...]
    guard !module.isEmpty, !top.isEmpty else { return nil }
    return ([String(module), String(top)] + comps[1..<(comps.count - 1)]).joined(separator: "/")
}

final class Collector {
    var errs: [String] = []
    var functions: [(id: String, name: String)] = []
    var kinds: [String: String] = [:] // test id -> suite | function
    var started: [String: Set<String>] = [:] // function id -> iterations started
    var ended: [String: Set<String>] = [:]
    var skipped = Set<String>()
    var failures: [String: [String: [String]]] = [:] // function id -> iteration -> failing issue texts
    var iterationOrder: [String: [String]] = [:]
    var outside: [(String, String)] = [] // (id, text) of failing issues outside any function
    var runsStarted = 0, runsEnded = 0

    func line(_ n: Int, _ raw: Data) {
        if raw.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) { return }
        guard let obj = try? JSONSerialization.jsonObject(with: raw, options: []) else {
            errs.append("line \(n): not JSON")
            return
        }
        guard let rec = obj as? [String: Any], let kind = rec["kind"] as? String,
              let payload = rec["payload"] as? [String: Any], kind == "test" || kind == "event" else {
            errs.append("line \(n): an unrecognised record")
            return
        }
        if kind == "test" {
            guard let id = payload["id"] as? String, let k = payload["kind"] as? String else {
                errs.append("line \(n): a test record without an id or kind")
                return
            }
            if kinds[id] == nil && k == "function" {
                functions.append((id, payload["name"] as? String ?? ""))
            }
            kinds[id] = k
            return
        }
        guard let ek = payload["kind"] as? String else {
            errs.append("line \(n): an event without a kind")
            return
        }
        guard knownEventKinds.contains(ek) else {
            errs.append("line \(n): an unrecognised event kind \(quote(ek))")
            return
        }
        let tid = payload["testID"] as? String
        let iter = (payload["iteration"] as? NSNumber).map { $0.stringValue } ?? "-"
        switch ek {
        case "runStarted": runsStarted += 1
        case "runEnded": runsEnded += 1
        case "testStarted":
            if let t = tid { started[t, default: []].insert(iter) }
        case "testEnded":
            if let t = tid { ended[t, default: []].insert(iter) }
        case "testSkipped":
            if let t = tid { skipped.insert(t) }
        case "issueRecorded":
            let issue = payload["issue"] as? [String: Any] ?? [:]
            let failing: Bool
            if let f = issue["isFailure"] as? Bool {
                failing = f
            } else {
                failing = (issue["isKnown"] as? Bool) != true && (issue["severity"] as? String) != "warning"
            }
            guard failing else { return }
            let msgs = (payload["messages"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
            let text = msgs.joined(separator: "\n")
            guard let t = tid, kinds[t] == "function" else {
                outside.append((tid ?? "", text))
                return
            }
            if failures[t]?[iter] == nil { iterationOrder[t, default: []].append(iter) }
            failures[t, default: [:]][iter, default: []].append(text)
        default: break
        }
    }

    func results() -> [Result] {
        var rs: [Result] = []
        var index: [String: Int] = [:]
        for f in functions {
            let raw = registryID(f.id, f.name)
            let test = raw ?? "\(f.id) (outside any suite)"
            let target = raw.map { String($0.prefix { $0 != "/" }) } ?? ""
            let st = started[f.id] ?? [], en = ended[f.id] ?? []
            let runs = (iterationOrder[f.id] ?? []).map { (failures[f.id]?[$0] ?? []).joined(separator: "\n") }
            var status: String?
            var why = ""
            if !st.subtracting(en).isEmpty {
                status = nil
                why = "started, never ended: its test process stopped"
            } else if !runs.isEmpty {
                status = "fail"
            } else if skipped.contains(f.id) {
                status = "skip"
            } else if !en.isEmpty {
                status = "pass"
            } else {
                status = nil
                why = "declared, never ran"
            }
            let r = Result(test: test, target: target, status: status, why: why, failedRuns: runs)
            // Two functions with one registry id: a failure or a missing result sticks.
            if let i = index[test] {
                let old = rs[i]
                let worse: Result
                if old.status == nil { worse = old } else if r.status == nil { worse = r } else if old.status == "fail" { worse = old } else { worse = r }
                rs[i] = Result(test: test, target: target, status: worse.status, why: worse.why,
                               failedRuns: old.failedRuns + r.failedRuns)
            } else {
                index[test] = rs.count
                rs.append(r)
            }
        }
        for (id, text) in outside {
            let what = id.isEmpty ? "(run) outside any test" : "\(id) (outside any test function)"
            rs.append(Result(test: what, target: "", status: "fail", why: "", failedRuns: [text]))
        }
        if runsStarted != runsEnded {
            rs.append(Result(test: "(run) stopped", target: "", status: nil,
                             why: "\(runsStarted) runs started, \(runsEnded) ended: a test process stopped", failedRuns: []))
        }
        return rs
    }
}

// MARK: - main

func usage() -> Int32 {
    FileHandle.standardError.write(Data(
        "usage: testresults --events <events.jsonl> --tier fast|full [--registry <file>] [--log <file>] [--today YYYY-MM-DD] [--edited <target>]...\n".utf8))
    return exitUsage
}

func run(_ args: [String]) -> Int32 {
    var registryPath = "hack/quarantine.txt"
    var tier = "", eventsPath = "", logPath = "", todayArg = ""
    var edited: [String] = []
    var i = 0
    while i < args.count {
        let k = args[i]
        guard ["--events", "--tier", "--registry", "--log", "--today", "--edited"].contains(k), i + 1 < args.count else {
            return usage()
        }
        let v = args[i + 1]
        switch k {
        case "--events": eventsPath = v
        case "--tier": tier = v
        case "--registry": registryPath = v
        case "--log": logPath = v
        case "--today": todayArg = v
        default: edited.append(v)
        }
        i += 2
    }
    switch tier {
    case "fast", "affected": tier = "fast"
    case "full": break
    default:
        FileHandle.standardError.write(Data("testresults: --tier must be fast or full\n".utf8))
        return exitUsage
    }
    if eventsPath.isEmpty { return usage() }
    var today: String
    if todayArg.isEmpty {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: Date())
        today = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    } else {
        guard validDate(todayArg) else {
            FileHandle.standardError.write(Data("testresults: --today is not a YYYY-MM-DD date\n".utf8))
            return exitUsage
        }
        today = todayArg
    }

    var registry = ""
    if FileManager.default.fileExists(atPath: registryPath) {
        guard let d = FileManager.default.contents(atPath: registryPath), let s = String(data: d, encoding: .utf8) else {
            print("RED registry \(registryPath) unreadable")
            return exitRed
        }
        registry = s
    }
    guard let stream = FileManager.default.contents(atPath: eventsPath) else {
        print("RED test stream \(eventsPath) unreadable")
        return exitRed
    }
    var logText = ""
    if !logPath.isEmpty {
        guard let d = FileManager.default.contents(atPath: logPath) else {
            print("RED console log \(logPath) unreadable")
            return exitRed
        }
        logText = String(decoding: d, as: UTF8.self)
    }

    let c = Collector()
    var n = 0
    for raw in stream.split(separator: 0x0A, omittingEmptySubsequences: false) {
        n += 1
        c.line(n, Data(raw))
    }
    var results = c.results()
    if let rm = raceMarker(logText) {
        results.append(Result(test: "(console log) race report", target: "", status: "fail", why: "",
                              failedRuns: ["the console log carries a race or sanitizer report: " + rm]))
    }
    var (red, excused, lines) = evaluate(registry, results, tier, edited, today)
    lines = c.errs.map { "RED test stream: " + $0 } + lines
    if !c.errs.isEmpty { red = true }
    if c.runsEnded == 0 && c.errs.isEmpty {
        lines.append("RED test stream holds no completed run")
        red = true
    }
    if c.functions.isEmpty && c.errs.isEmpty {
        lines.append("RED test stream holds no results")
        red = true
    }

    let failed = results.filter { $0.status == "fail" }
    let entries = parseRegistry(registry).0
    print("==> test results: tier \(tier), \(results.count) tests, \(failed.count) failed, \(entries.count) quarantine entr\(entries.count == 1 ? "y" : "ies")")
    if !failed.isEmpty {
        print("    failing tests:")
        for r in failed {
            let first = (r.failedRuns.first ?? "").split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
            print("    \(r.test): \(first.prefix(200))")
        }
    }
    for l in lines { print(l) }
    if red {
        print("RED")
        return exitRed
    }
    if excused > 0 {
        print("ok (\(excused) failure\(excused == 1 ? "" : "s") excused by the registry)")
        return exitExcused
    }
    if !failed.isEmpty {
        print("RED")
        return exitRed
    }
    print("ok")
    return exitGreen
}

exit(run(Array(CommandLine.arguments.dropFirst())))
