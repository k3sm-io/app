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

import Darwin
import Foundation
import K3smInstall
import K3smSwap
import Security

// k3sm-app-update: the swap helper. It takes exactly one argument, --swap,
// --go-back or --relaunch, and no path: every location comes from the
// account's passwd entry (SwapPaths) and the request file is checked against
// it. It runs only as the verified copy in the private directory, only when
// its own code satisfies the compiled helper requirement (a developer build
// pins no team and refuses), and never as root. It builds the engine from
// the compiled requirements and the real adapters only; nothing selects
// another requirement or a seam.
//
// The copy it runs from is in a directory the user owns. A root mode, when
// one is added, must never exec this copy or any file a user can write: root
// runs only a copy it made itself into a root-owned directory and verified
// there.

func refuse(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("k3sm-app-update: refused: " + message + "\n").utf8))
    exit(SwapExit.refusedRequest.rawValue)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 1, let mode = HelperMode(rawValue: arguments[0]) else {
    refuse("usage: k3sm-app-update --swap | --go-back | --relaunch")
}
guard getuid() != 0, geteuid() != 0 else { refuse("runs as the user, never as root") }
guard let team = TeamIDPin.teamID else { refuse("a developer build pins no team and never updates itself") }
guard let paths = SwapPaths.forCurrentUser() else { refuse("no home directory for this account") }

/// The path of this process's own executable, resolved.
func ownExecutable() -> String? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    guard proc_pidpath(getpid(), &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

/// The private directory's helper copy, resolved the same way.
func expectedExecutable(_ paths: SwapPaths) -> String? {
    guard let dir = realpath(paths.privateDirectory, nil) else { return nil }
    defer { free(dir) }
    return String(cString: dir) + "/" + SwapPaths.helperName
}

guard let own = ownExecutable(), let expected = expectedExecutable(paths), own == expected else {
    refuse("runs only from its copy in the private directory")
}

/// Whether this process's own code satisfies the helper requirement.
func selfSatisfies(_ requirement: String) -> Bool {
    var code: SecCode?
    var req: SecRequirement?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
          SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess, let req
    else { return false }
    return SecCodeCheckValidity(code, [], req) == errSecSuccess
}

guard selfSatisfies(AppUpdateTrust.helperRequirement(teamID: team)) else {
    refuse("this helper does not satisfy the helper requirement")
}

let appRequirement = AppUpdateTrust.appRequirement(teamID: team)
let engine = SwapEngine(
    requirement: appRequirement,
    clock: SystemSwapClock(),
    watcher: KqueueProcessWatcher(),
    renamer: SystemRenamer(),
    launcher: WorkspaceLauncher(),
    verifier: StaticCodeVerifier(requirement: appRequirement, runningTeam: team),
    paths: paths,
    timeouts: .standard)

let result: SwapExit
switch mode {
case .swap: result = engine.swap()
case .goBack: result = engine.goBack()
case .relaunch: result = engine.relaunch()
}
exit(result.rawValue)
