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

/// LogSummaryPanel is the inspector's Summarize Logs block for the
/// selected pod: the running note with Cancel, the reason the model cannot
/// run, the failure, or the summary as plain text with the period it
/// covers, the line counts, the notes, the line that says where it came
/// from, and Copy. The answer is shown with `Text(verbatim:)`, so nothing in
/// it is read as Markdown or a link. Nothing while no request ran on this pod.
struct LogSummaryPanel: View {
    @ObservedObject var summaries: LogSummaryModel
    let podKey: String

    var body: some View {
        if let phase = summaries.phase(for: podKey) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(heading).font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    if phase.running {
                        Button("Cancel") { summaries.cancel() }.controlSize(.small)
                    } else {
                        if case .done(let summary) = phase {
                            Button("Copy") { copy(summary) }.controlSize(.small)
                        }
                        Button("Close") { summaries.close() }.controlSize(.small)
                    }
                }
                content(phase)
            }
            .padding(.horizontal, 18).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
        }
    }

    private var heading: String {
        guard let container = summaries.target?.container.value else { return "Log summary" }
        return "Log summary: \(container)"
    }

    @ViewBuilder
    private func content(_ phase: LogSummaryPhase) -> some View {
        switch phase {
        case .reading:
            note(LogSummaryText.reading, color: Palette.dimText)
        case .summarizing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                note(LogSummaryText.summarizing, color: Palette.dimText)
            }
        case .unavailable(let reason):
            note(reason, color: Palette.ink2)
        case .failed(let text):
            note(text, color: Palette.bad)
        case .done(let summary):
            ScrollView {
                Text(verbatim: summary.text)
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 180)
            note(summary.period + " " + summary.lines, color: Palette.dimText)
            ForEach(summary.notes, id: \.self) { note($0, color: Palette.warn) }
            note(LogSummaryText.footnote, color: Palette.dimText)
        }
    }

    private func note(_ text: String, color: Color) -> some View {
        Text(verbatim: text)
            .font(.system(size: 11.5))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The summary, its period and its source line on the pasteboard.
    private func copy(_ summary: LogSummary) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString([summary.text, summary.period + " " + summary.lines, LogSummaryText.footnote].joined(separator: "\n\n"),
                                       forType: .string)
    }
}
