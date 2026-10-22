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

// k3sm-app-update: the swap helper. Its user modes take exactly one
// argument, --swap, --go-back, --relaunch or --relaunch-failed, and no path:
// every location comes from the account's passwd entry (SwapPaths) and the
// request file is checked against it. They run only as the verified copy in
// the private directory, only when the helper's own code satisfies the
// compiled helper requirement (a developer build pins no team and refuses),
// and never as root. The engine is built from the compiled requirements and
// the real adapters only; nothing selects another requirement or a seam.
//
// Its root mode (--root-swap or --root-swap-detached, then the console
// user's uid, the app's pid and its start time: three integers, no path)
// runs only as root, only from a root-owned 0500 copy named helper.<random>
// directly in the root work directory, which the root step made from the
// installed bundle and verified there, and only when its own code satisfies
// the helper requirement. Root never executes the user's copy, which is in a
// directory the user owns: the root path's user side runs that copy as the
// user (ConsoleSessionRunner), never as root.

/// Writes a refusal and exits with `status`.
func refuse(_ message: String, status: Int32 = SwapExit.refusedRequest.rawValue) -> Never {
    FileHandle.standardError.write(Data(("k3sm-app-update: refused: " + message + "\n").utf8))
    exit(status)
}

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

/// Whether this process's own code satisfies the helper requirement.
func selfSatisfies(_ requirement: String) -> Bool {
    var code: SecCode?
    var req: SecRequirement?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
          SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess, let req
    else { return false }
    return SecCodeCheckValidity(code, [], req) == errSecSuccess
}

/// The root mode. Every refusal after the location check removes this copy,
/// which only the root step made; a hand-off leaves it to the detached half,
/// which removes it when it ends.
func runRoot(_ request: RootSwapArguments) -> Never {
    guard getuid() == 0, geteuid() == 0 else {
        refuse("the root mode runs only as root", status: AppSwapExit.refusedRequest.rawValue)
    }
    guard let own = ownExecutable(), RootSwapCopy.isTrusted(path: own) else {
        refuse("the root mode runs only from its root-owned copy in the work folder", status: AppSwapExit.refusedRequest.rawValue)
    }
    func refuseAndRemove(_ message: String, _ status: AppSwapExit) -> Never {
        unlink(own)
        refuse(message, status: status.rawValue)
    }
    guard let team = TeamIDPin.teamID else { refuseAndRemove("a developer build pins no team", .refusedRequest) }
    guard selfSatisfies(AppUpdateTrust.helperRequirement(teamID: team)) else {
        refuseAndRemove("this helper does not satisfy the helper requirement", .refusedRequest)
    }
    guard let layout = RootSwapLayout.forAccount(uid: request.uid) else {
        refuseAndRemove("no home directory for the account", .refusedRequest)
    }
    let appRequirement = AppUpdateTrust.appRequirement(teamID: team)
    let engine = RootSwapEngine(
        layout: layout,
        owner: .root,
        account: request.uid,
        app: request.app,
        verifier: StaticCodeVerifier(requirement: appRequirement, runningTeam: team),
        watcher: KqueueProcessWatcher(),
        renamer: SystemRenamer(),
        userSide: ConsoleSessionRunner(uid: request.uid, helperPath: layout.user.helperCopyPath),
        timeouts: .standard)
    switch request.mode {
    case .prepare:
        switch engine.prepare(keepHelper: (own as NSString).lastPathComponent) {
        case .failure(let refusal):
            refuseAndRemove("the update was refused", refusal.exit)
        case .success(let lock):
            let detached = RootSwapArguments(mode: .detached, uid: request.uid, app: request.app)
            guard let words = detached.words, RootSwapSpawner.spawnDetached(executable: own, arguments: words, lockFD: lock.fd) else {
                engine.discardStage()
                refuseAndRemove("the detached half could not start", .startFailed)
            }
            lock.handOff()
            exit(AppSwapExit.committed.rawValue)
        }
    case .detached:
        guard let lock = engine.adoptLock(fd: RootSwapSpawner.lockDescriptor) else {
            // Without the lock no file is touched; the app comes back.
            unlink(own)
            exit(engine.relaunchAfterExit().rawValue)
        }
        let result = engine.complete(lock: lock)
        unlink(own)
        exit(result.rawValue)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
if let rootRequest = RootSwapArguments(arguments: arguments) { runRoot(rootRequest) }
guard arguments.count == 1, let mode = HelperMode(rawValue: arguments[0]) else {
    refuse("usage: k3sm-app-update --swap | --go-back | --relaunch | --relaunch-failed")
}
guard getuid() != 0, geteuid() != 0 else { refuse("runs as the user, never as root") }
guard let team = TeamIDPin.teamID else { refuse("a developer build pins no team and never updates itself") }
guard let paths = SwapPaths.forCurrentUser() else { refuse("no home directory for this account") }
guard let own = ownExecutable(), let expected = expectedExecutable(paths), own == expected else {
    refuse("runs only from its copy in the private directory")
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
case .relaunchFailed: result = engine.relaunchFailed()
}
exit(result.rawValue)
