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

import AppKit
import K3smStatus
import SwiftUI

/// DemoTourRunner walks the console through a tour file named by
/// `--demo-tour <file>` (`DemoTour`), for the release recording. It reads
/// the file only from the checkout's hack/demo or the bundle's
/// Resources/demo, refuses the whole tour before anything runs when a step
/// is unknown or not a read, then drives the console with its own state (the
/// tab, the sub-tab, the selected row, the inspector, the window frame), in
/// order, and quits: status 0 when the tour ends, 1 with the failed step on
/// standard error, 2 when the argument or the file was refused. It runs only
/// the steps `DemoTour` admits (navigation and reads) and calls no action or
/// root step through the model, so a tour changes nothing in the cluster and
/// asks for no administrator prompt. The user's stored layout is put back
/// before it quits.
@MainActor
final class DemoTourRunner {
    private let entries: [DemoTour.Entry]
    private let model: AppModel
    private let window: () -> NSWindow?
    /// The stored values the tour changes, read before it starts.
    private var saved: [String: Any?] = [:]

    init(entries: [DemoTour.Entry], model: AppModel, window: @escaping () -> NSWindow?) {
        self.entries = entries
        self.model = model
        self.window = window
    }

    /// The tour the launch arguments name, nil when they name none. A
    /// refused argument or file ends the process with status 2 here, before
    /// the app builds anything.
    static func load(arguments: [String] = CommandLine.arguments) -> [DemoTour.Entry]? {
        do {
            guard let path = try DemoTour.path(in: arguments) else { return nil }
            let file: URL
            if DemoTour.isBareName(path) {
                let resources = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.resourceURL?.resolvingSymlinksInPath() : nil
                file = try DemoTour.bundledTour(named: path, resources: resources) { FileManager.default.fileExists(atPath: $0.path) }
                    .resolvingSymlinksInPath()
                guard DemoTour.permits(file, in: allowedDirectories()) else { throw DemoTour.LaunchError.outside(path) }
            } else {
                file = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
                guard DemoTour.permits(file, in: allowedDirectories()) else { throw DemoTour.LaunchError.outside(path) }
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? nil
            guard let size else { refuse("cannot read \(StatusDisplay.clip(path))") }
            guard size <= DemoTour.maxBytes else { throw DemoTour.TourError.tooLarge }
            return try DemoTour.parse(Data(contentsOf: file))
        } catch let e as DemoTour.LaunchError {
            refuse(e.message)
        } catch let e as DemoTour.TourError {
            refuse(e.message)
        } catch {
            refuse("cannot read the tour file")
        }
    }

    /// The checkout's hack/demo above the running executable, and the
    /// bundle's Resources/demo when the app runs from a bundle, links resolved.
    private static func allowedDirectories() -> [URL] {
        let fm = FileManager.default
        let exe = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        let resources = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.resourceURL?.resolvingSymlinksInPath() : nil
        return DemoTour.allowedDirectories(executable: exe, resources: resources) { dir in
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: dir.appendingPathComponent("Package.swift").path)
                && fm.fileExists(atPath: dir.appendingPathComponent(DemoTour.checkoutDirectory).path, isDirectory: &isDir) && isDir.boolValue
        }.map { $0.resolvingSymlinksInPath() }
    }

    private static func refuse(_ message: String) -> Never {
        FileHandle.standardError.write(Data("k3sm demo tour: refused: \(message)\n".utf8))
        exit(2)
    }

    /// The stored keys a tour's steps change.
    private static var keys: [String] {
        [ConsoleTabs.sectionKey, WorkloadsView.key, AppModel.inspectorShownKey, WindowFrame.key,
         ConsoleTabs.selectedKey(.workloads), ConsoleTabs.selectedKey(.nodes),
         ConsoleTabs.queryKey(.workloads), ConsoleTabs.queryKey(.nodes)]
    }

    /// Runs the tour and quits.
    func start() {
        for key in Self.keys { saved[key] = UserDefaults.standard.object(forKey: key) }
        Task { @MainActor in
            guard await self.consoleShown() else {
                self.quit(failure: "k3sm demo tour: the console did not come on screen within \(Int(DemoTour.consoleWait)) s (is k3sm installed and running?)")
            }
            // A fresh walk: no guided tour, no status panel, and no search
            // hiding the rows the tour selects.
            self.model.tour.end()
            self.model.statusPanelShown = false
            self.model.workloads.query = ""
            self.model.nodesQuery = ""
            for (n, entry) in self.entries.enumerated() {
                if let reason = await self.run(entry.step) {
                    self.quit(failure: DemoTour.failureLine(index: n + 1, step: entry.step, reason: reason))
                }
                if entry.step == .end { break }
            }
            self.quit(failure: nil)
        }
    }

    /// Waits for the console screen, bounded.
    private func consoleShown() async -> Bool {
        let deadline = Date().addingTimeInterval(DemoTour.consoleWait)
        while Date() < deadline {
            if model.screen == .status, window()?.isVisible == true { return true }
            await sleep(0.5)
        }
        return false
    }

    /// Runs one step; nil when it succeeded, otherwise why it failed.
    private func run(_ step: DemoTour.Step) async -> String? {
        switch step {
        case .selectTab(let s):
            animate { self.model.section = s }
        case .selectWorkloadsView(let v):
            animate { self.model.workloadsView = v }
        case .selectRow(.pod(let match)):
            let found = await poll(DemoTour.rowWait) {
                guard let pod = DemoTour.pod(match, in: self.model.workloads.workloads?.pods ?? []) else {
                    await self.model.workloads.pods?.refresh()
                    return false
                }
                self.animate { self.model.workloads.select(pod) }
                return true
            }
            if !found { return "no pod matching the step is listed after \(Int(DemoTour.rowWait)) s" }
        case .selectRow(.node(let match)):
            let found = await poll(DemoTour.rowWait) {
                guard let node = DemoTour.node(match, in: self.model.workloads.nodes ?? []) else {
                    await self.model.workloads.nodeList.refresh()
                    return false
                }
                self.animate { self.model.select(.node(node.name)) }
                return true
            }
            if !found { return "no node matching the step is listed after \(Int(DemoTour.rowWait)) s" }
        case .openInspector:
            animate { self.model.inspectorShown = true }
        case .closeInspector:
            animate { self.model.inspectorShown = false }
        case .runRead(let read):
            switch read {
            case .refresh:
                await model.refreshTabs()
            case .logs:
                // The log opens in the log pane, as Open Log does.
                guard let pod = model.workloads.selectedPod else { return "no pod is selected" }
                model.openPodLog(pod)
                let read = await poll(20) { !self.model.workloads.logLoading }
                if !read { return "the read did not finish within 20 s" }
            case .events, .manifest:
                guard model.workloads.selectedPod != nil else { return "no pod is selected" }
                model.workloads.detail = read == .events ? .events : .manifest
                model.workloads.loadDetail()
                let read = await poll(20) { !self.model.workloads.detailLoading }
                if !read { return "the read did not finish within 20 s" }
            }
        case .waitFor(let condition, let timeout):
            let met = await poll(timeout) { await self.check(condition) }
            if !met { return "the condition did not hold within \(Int(timeout)) s" }
        case .pause(let s):
            await sleep(s)
        case .windowFrame(let f):
            guard let window = window(), let screen = NSScreen.screens.first else { return "the console window is not open" }
            let r = DemoTour.appKitFrame(f, screenHeight: Double(screen.frame.height))
            window.setFrame(NSRect(x: r.x, y: r.y, width: r.width, height: r.height), display: true, animate: false)
        case .end:
            break
        }
        return nil
    }

    /// Reads what a condition needs, through the console's own reads, and decides it.
    private func check(_ condition: DemoTour.Condition) async -> Bool {
        switch condition {
        case .podRunning:
            await model.workloads.podsLoader().refresh()
            return DemoTour.met(condition, pods: model.workloads.workloads?.pods, models: nil, nodes: nil)
        case .nodesReady:
            await model.workloads.nodeList.refresh()
            return DemoTour.met(condition, pods: nil, models: nil, nodes: model.workloads.nodes)
        case .modelReady:
            return DemoTour.met(condition, pods: nil, models: await model.readModelsOnce(), nodes: nil)
        }
    }

    /// Calls `body` until it returns true or `seconds` pass, every
    /// `DemoTour.pollInterval`; whether it returned true.
    private func poll(_ seconds: Double, _ body: @MainActor () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            if await body() { return true }
            if Date() >= deadline { return false }
            await sleep(min(DemoTour.pollInterval, max(0.1, deadline.timeIntervalSinceNow)))
        }
    }

    /// Applies a layout change, animated unless Reduce Motion is on.
    private func animate(_ change: () -> Void) {
        if let d = DemoTour.animation(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) {
            withAnimation(.easeInOut(duration: d), change)
        } else {
            change()
        }
    }

    private func sleep(_ seconds: Double) async {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    /// Puts the stored layout back and quits: status 0, or 1 with `failure`
    /// on standard error.
    private func quit(failure: String?) -> Never {
        for (key, value) in saved {
            if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        }
        UserDefaults.standard.synchronize()
        if let failure { FileHandle.standardError.write(Data((failure + "\n").utf8)) }
        exit(failure == nil ? 0 : 1)
    }
}
