// Copyright The k3sm Authors.
// SPDX-License-Identifier: Apache-2.0
// NSWorkspace within the console user's Aqua session. No System Events or Apple Events.
ObjC.import('AppKit')
function run(args) {
    const [action, bundleID, path, pid] = args
    const apps = $.NSRunningApplication.runningApplicationsWithBundleIdentifier(bundleID)
    if (apps.count === 0) return 'none'
    if (apps.count !== 1) return 'ambiguous'
    const app = apps.objectAtIndex(0)
    if (ObjC.unwrap(app.bundleURL.URLByResolvingSymlinksInPath.path) !== path) return 'foreign'
    if (action === 'terminate') {
        if (String(app.processIdentifier) !== pid || !app.terminate) throw Error('GUI quit refused')
        return 'requested'
    }
    if (app.isTerminated) return 'none'
    if (action !== 'identity' && !app.isFinishedLaunching) return 'starting'
    return String(app.processIdentifier)
}
