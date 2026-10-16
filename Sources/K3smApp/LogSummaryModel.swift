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
import K3smStatus
#if canImport(FoundationModels)
import FoundationModels
#endif

/// LogSummaryModel runs the Summarize Logs action, one request at a time:
/// it asks whether Apple's on-device model can run, reads the container's
/// log (and its previous instance's, after a restart) through the fixed
/// argument lists, reuses the summary it holds when that log is unchanged,
/// and otherwise builds the prompt (`LogSummaryPrompt`) and runs one
/// session on this Mac under a deadline. Nothing leaves the Mac. The answer
/// is only shown, as plain text; it is never parsed into an action, a
/// command or a link.
@MainActor
final class LogSummaryModel: ObservableObject {
    /// The container the last request was about, and where it stands.
    @Published private(set) var target: LogSummaryTarget?
    @Published private(set) var phase: LogSummaryPhase?

    /// How long the model may take to answer.
    static let modelDeadline: Duration = .seconds(60)

    private let environment: [String: String]
    private var cache = LogSummaryCache()
    private var task: Task<Void, Never>?
    /// Counts requests, so a cancelled one that finishes late changes nothing.
    private var generation = 0

    init(environment: [String: String]) {
        self.environment = environment
    }

    /// Whether a request is running, so another waits.
    var running: Bool { phase?.running ?? false }

    /// The request's state for the pod `podKey`, nil when the last
    /// request was about another pod.
    func phase(for podKey: String?) -> LogSummaryPhase? {
        guard let podKey, target?.podKey == podKey else { return nil }
        return phase
    }

    /// Summarizes `target`'s log; ignored while a request runs.
    func summarize(_ target: LogSummaryTarget) {
        guard !running else { return }
        self.target = target
        let availability = OnDeviceModel.availability()
        if let reason = availability.reason {
            phase = .unavailable(reason)
            return
        }
        phase = .reading
        generation += 1
        let request = generation
        let environment = environment
        task = Task { [weak self] in
            let current = await Self.readLog(target.currentArguments, environment: environment)
            var previous: LogReadOutcome?
            if let arguments = target.previousArguments {
                previous = await Self.readLog(arguments, environment: environment)
            }
            guard !Task.isCancelled, let self else { return }
            await self.finish(target, request: request, current: current, previous: previous)
        }
    }

    /// Cancels the running request; its panel closes.
    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        phase = nil
    }

    /// Closes the panel of a finished request.
    func close() {
        guard !running else { return }
        phase = nil
    }

    private func finish(_ target: LogSummaryTarget, request: Int, current: LogReadOutcome, previous: LogReadOutcome?) async {
        guard request == generation else { return }
        guard case .read(let currentData, let currentCut) = current else {
            if case .failed(let status) = current { phase = .failed(LogSummaryText.readFailed(exitStatus: status)) }
            return
        }
        var notes: [String] = []
        var previousRead: LogRead?
        var parts = [currentData]
        switch previous {
        case .read(let data, let cut)?:
            previousRead = LogRead.parse(data, cut: cut)
            parts.append(data)
            if cut { notes.append(LogSummaryText.cut) }
        case .failed?:
            notes.append(LogSummaryText.noPrevious)
        case nil:
            break
        }
        let currentRead = LogRead.parse(currentData, cut: currentCut)
        if currentCut { notes.insert(LogSummaryText.cut, at: 0) }
        let fingerprint = LogFingerprint.of(parts)
        if let cached = cache.summary(for: target.cacheKey, fingerprint: fingerprint) {
            phase = .done(cached)
            return
        }
        guard !currentRead.lines.isEmpty || !(previousRead?.lines.isEmpty ?? true) else {
            phase = .failed(LogSummaryText.noLines)
            return
        }
        phase = .summarizing
        let outcome = await OnDeviceModel.summarize(target: target, current: currentRead, previous: previousRead, deadline: Self.modelDeadline)
        guard !Task.isCancelled, request == generation else { return }
        switch outcome {
        case .answer(let text, let prompt):
            let answer = LogSummaryText.answer(text)
            guard !answer.isEmpty else {
                phase = .failed(LogSummaryText.noAnswer)
                return
            }
            let summary = LogSummary(text: answer, period: LogSummaryText.period(prompt.period),
                                     lines: LogSummaryText.lines(read: prompt.readLines, omitted: prompt.omittedLines),
                                     notes: notes, fingerprint: fingerprint)
            cache.store(summary, for: target.cacheKey)
            phase = .done(summary)
            log.notice("console: summarize-logs done")
        case .tooLong:
            phase = .failed(LogSummaryText.tooLong)
        case .timedOut:
            phase = .failed(LogSummaryText.timedOut(seconds: Int(Self.modelDeadline.components.seconds)))
        case .unavailable(let availability):
            phase = .unavailable(availability.reason ?? LogSummaryAvailability.unknown.reason!)
        case .failed(let why):
            phase = .failed(LogSummaryText.modelFailed(why))
            log.notice("console: summarize-logs failed")
        }
    }

    /// One log read: its bytes and whether it stopped at its limit, or the
    /// exit status of a run that failed (nil when the CLI did not answer).
    enum LogReadOutcome: Sendable {
        case read(Data, cut: Bool)
        case failed(Int32?)
    }

    nonisolated private static func readLog(_ arguments: [String], environment: [String: String]) async -> LogReadOutcome {
        let outcome = await CLIProcess.run(path: K3smCLI.path, arguments: arguments, environment: environment,
                                           deadline: PollSchedule.listDeadline, limit: OutputLimit.logSummary)
        switch outcome {
        case .exited(status: 0, let stdout): return .read(stdout, cut: false)
        case .truncated(let stdout): return .read(stdout, cut: true)
        case .exited(let status, _): return .failed(status)
        case .missing, .failedToLaunch, .killed, .refused: return .failed(nil)
        }
    }
}

/// OnDeviceModel is the app's one use of Apple's Foundation Models
/// framework: the system's on-device language model only, never a server
/// model, with plain-text answers (no generated types, so no macros).
enum OnDeviceModel {
    /// How one summary ended.
    enum Outcome: Sendable {
        case answer(String, LogSummaryPrompt)
        /// Not one log line fits the model's context.
        case tooLong
        case timedOut
        case unavailable(LogSummaryAvailability)
        case failed(String)
    }

    /// Whether the model can run on this Mac now.
    static func availability() -> LogSummaryAvailability {
        #if canImport(FoundationModels)
        switch model().availability {
        case .available: return .available
        case .unavailable(.deviceNotEligible): return .deviceNotEligible
        case .unavailable(.appleIntelligenceNotEnabled): return .appleIntelligenceNotEnabled
        case .unavailable(.modelNotReady): return .modelNotReady
        case .unavailable: return .unknown
        }
        #else
        return .unknown
        #endif
    }

    /// Builds the prompt to fit the model's context and asks for the
    /// summary, giving up at `deadline`. On a Mac whose model counts tokens
    /// (macOS 26.4 and later), the prompt is measured and rebuilt larger
    /// while it fits, up to three times; elsewhere the estimate's bound holds.
    static func summarize(target: LogSummaryTarget, current: LogRead, previous: LogRead?, deadline: Duration) async -> Outcome {
        #if canImport(FoundationModels)
        let model = model()
        if case .unavailable = model.availability { return .unavailable(availability()) }
        let context = model.contextSize
        let limit = context - LogSummaryPrompt.answerTokens - LogSummaryPrompt.frameTokens
        func build(_ scale: Double) -> LogSummaryPrompt {
            LogSummaryPrompt.build(container: target.container, pod: target.pod, namespace: target.namespace,
                                   current: current, previous: previous, contextSize: context, scale: scale)
        }
        var prompt = build(1)
        if #available(macOS 26.4, *) {
            var scale = 1.0
            for _ in 0..<3 {
                guard prompt.omittedLines > 0, let used = try? await tokens(prompt, model: model), used > 0 else { break }
                let grow = Double(limit) / Double(used) * 0.95
                guard grow > 1.1 else { break }
                let next = build(scale * grow)
                guard let measured = try? await tokens(next, model: model), measured <= limit else { break }
                scale *= grow
                prompt = next
            }
        }
        guard prompt.sentLines > 0 else { return .tooLong }
        let instructions = prompt.instructions
        let text = prompt.prompt
        let answerTokens = LogSummaryPrompt.answerTokens
        do {
            let answer = try await withThrowingTaskGroup(of: String?.self) { group in
                group.addTask {
                    let session = LanguageModelSession(model: OnDeviceModel.model(), instructions: instructions)
                    let options = GenerationOptions(temperature: 0.2, maximumResponseTokens: answerTokens)
                    return try await session.respond(to: text, options: options).content
                }
                group.addTask {
                    try await Task.sleep(for: deadline)
                    return nil
                }
                let first = try await group.next() ?? nil
                group.cancelAll()
                return first
            }
            guard let answer else { return .timedOut }
            return .answer(answer, prompt)
        } catch is CancellationError {
            return .failed("cancelled")
        } catch {
            return .failed(String(describing: error))
        }
        #else
        return .unavailable(.unknown)
        #endif
    }

    #if canImport(FoundationModels)
    /// The system's on-device model, with the guardrails Apple provides for
    /// transforming text the user supplies, since a log can quote anything.
    static func model() -> SystemLanguageModel {
        SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)
    }

    @available(macOS 26.4, *)
    private static func tokens(_ prompt: LogSummaryPrompt, model: SystemLanguageModel) async throws -> Int {
        let a = try await model.tokenCount(for: Instructions(prompt.instructions))
        let b = try await model.tokenCount(for: prompt.prompt)
        return a + b
    }
    #endif
}
