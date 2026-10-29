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
import K3smInstall
import K3smStatus
import SwiftUI

/// AlertsSection is the Alerts tab: the issues behind the status headline
/// (`ClusterIssues`), one card per listed check, grouped worst first, then
/// the report's next commands. A card with an alert leads with its cause,
/// then its evidence, numbered fix steps (Copy only, never run) and guide
/// link. While the update plan offers Update its card comes first
/// (`UpdateCard`); the Nodes tab's Update controls run the same plan
/// through `AppModel.performUpdate`. When the report is clean
/// and there is no card to show, the tab rests: one sentence saying
/// everything is healthy with the report's age, over the butterfly's field
/// (`FieldScene`), with any check that could not tell or needs an
/// administrator listed under it. While a failed read is covered by the
/// last good report, a line under the headline says so with its age
/// (`ReportHold.staleLine`). It reads only `AppModel.report`, its hold and
/// the update plan, so it has no loader of its own.
struct AlertsSection: View {
    @ObservedObject var app: AppModel

    var body: some View {
        let issues = ClusterIssues.of(app.report)
        let card = UpdateCard.of(plan: app.updatePlan, report: app.report)
        return TimelineView(.periodic(from: .now, by: 5)) { context in
            ScrollView {
                if issues.rests(withCard: card != nil) {
                    VStack(spacing: 18) {
                        HStack(spacing: 7) {
                            Image(systemName: RowTone.healthy.symbolName)
                                .foregroundStyle(Palette.row(.healthy))
                                .accessibilityHidden(true)
                            Text(verbatim: issues.healthyLine(now: context.date)).font(.system(size: 15, weight: .semibold))
                        }
                        if let stale = app.reportHold.staleLine(now: context.date) {
                            Text(verbatim: stale).font(.caption).foregroundStyle(Palette.ink2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        FieldScene()
                        IssueGroups(groups: issues.groups)
                    }
                    .padding(.horizontal, 20).padding(.vertical, 28)
                    .frame(maxWidth: .infinity, alignment: .top)
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 7) {
                                Image(systemName: issues.isClean ? RowTone.healthy.symbolName : RowTone.attention.symbolName)
                                    .foregroundStyle(Palette.row(issues.isClean ? .healthy : .attention))
                                    .accessibilityHidden(true)
                                Text(verbatim: issues.headline).font(.system(size: 15, weight: .semibold))
                            }
                            if let summary = issues.summary {
                                Text(verbatim: summary).font(.callout).foregroundStyle(Palette.ink2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if app.report != nil {
                                Text(verbatim: issues.checkedLine(now: context.date)).font(.caption).foregroundStyle(Palette.ink2)
                            }
                            if let stale = app.reportHold.staleLine(now: context.date) {
                                Text(verbatim: stale).font(.caption).foregroundStyle(Palette.ink2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        if let card {
                            UpdateCardView(app: app, card: card)
                        }
                        IssueGroups(groups: issues.groups)
                        if !issues.next.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(verbatim: ClusterIssues.nextTitle).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink2)
                                ForEach(Array(issues.next.enumerated()), id: \.offset) { _, step in
                                    RemedyLine(step: step)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
        .background(Palette.surface)
    }
}

/// UpdateCardView is the update plan's card, drawn like an issue card: its
/// title, the plan's line, Update (or Updating…) with the plan's state and
/// help tag, and Abort while the managed update's panel offers it.
private struct UpdateCardView: View {
    @ObservedObject var app: AppModel
    let card: UpdateCard

    var body: some View {
        let plan = app.updatePlan
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(Palette.navy).accessibilityHidden(true)
                Text(verbatim: card.title).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                if app.updateProgress.panel?.showsAbort == true {
                    let reason = app.updateActionReason
                    Button(LifecycleVerb.updateAbort.title + "…") { app.abortUpdate() }
                        .controlSize(.small)
                        .disabled(reason != nil)
                        .help(Help.Update.abort(reason: reason))
                }
                Button(card.buttonTitle) { app.performUpdate() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(Palette.blue)
                    .disabled(!card.isEnabled)
                    .help(Help.Strip.update(plan))
            }
            if let detail = card.detail {
                Text(verbatim: detail).font(.callout).foregroundStyle(Palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.raised))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line, lineWidth: 1))
    }
}

/// IssueGroups is the listed checks, a heading over each level's cards.
private struct IssueGroups: View {
    let groups: [ClusterIssueGroup]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: group.heading).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.ink2)
                    ForEach(Array(group.issues.enumerated()), id: \.offset) { _, issue in
                        IssueCard(issue: issue)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// IssueCard is one listed check: its name and state badge, then its alert
/// (`AlertBody`), or, from a k3sm that prints none, its detail; then its
/// remedy's lines (`ClusterIssue.remedyLines`: all without an alert, and
/// under an alert only when it has no fix step).
private struct IssueCard: View {
    let issue: ClusterIssue

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(verbatim: issue.name).font(.system(size: 13, weight: .semibold))
                Text(verbatim: issue.state)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Self.colour(issue.level))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().stroke(Self.colour(issue.level), lineWidth: 1))
                    .help(Help.Alerts.stateBadge)
                    .accessibilityLabel(Text(verbatim: issue.level.title + ": " + issue.state))
            }
            if let alert = issue.alert {
                AlertBody(alert: alert)
            } else if !issue.detail.isEmpty {
                Text(verbatim: issue.detail).font(.callout).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(issue.remedyLines.enumerated()), id: \.offset) { _, step in
                RemedyLine(step: step)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.raised))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line, lineWidth: 1))
    }

    /// The badge's colour for a level: red failing, amber for the other
    /// faults, grey for a check that could not tell or needs an administrator.
    static func colour(_ level: IssueLevel) -> Color {
        switch level {
        case .failing: return Palette.bad
        case .warning, .reported: return Palette.warn
        case .unknown, .needsAdmin: return Palette.unknown
        }
    }
}

/// AlertBody is a card's alert: the cause as the lead line, when it began,
/// the evidence behind a disclosure, the numbered fix steps, and the guide
/// link. It shows and copies; nothing here runs a step.
private struct AlertBody: View {
    let alert: IssueAlert

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: alert.cause).font(.callout).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if let since = alert.since {
                Text(verbatim: since).font(.caption).foregroundStyle(Palette.ink2)
            }
            if !alert.evidence.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(alert.evidence.enumerated()), id: \.offset) { _, line in
                            Text(verbatim: line).font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let more = alert.moreEvidence {
                            Text(verbatim: more).font(.caption).foregroundStyle(Palette.ink2)
                        }
                    }
                    .padding(.top, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text(verbatim: alert.evidenceTitle).font(.caption).foregroundStyle(Palette.ink2)
                }
                .help(Help.Alerts.evidence)
            }
            ForEach(Array(alert.steps.enumerated()), id: \.offset) { _, step in
                FixStepLine(step: step)
            }
            if let more = alert.moreSteps {
                Text(verbatim: more).font(.caption).foregroundStyle(Palette.ink2)
            }
            if let url = alert.docs {
                Button(IssueAlert.docsTitle) { NSWorkspace.shared.open(url) }
                    .buttonStyle(.link)
                    .controlSize(.small)
                    .help(Help.Alerts.docs)
            }
        }
    }
}

/// FixStepLine is one numbered fix step: its text, its administrator and
/// confirm marks, and its command in the monospaced well with a Copy button
/// when the command may be copied (`IssueStep.copy`). There is no Run.
private struct FixStepLine: View {
    let step: IssueStep

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: step.numberText).font(.callout.monospacedDigit()).foregroundStyle(Palette.ink2)
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: step.text).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if step.needsAdmin || step.confirm {
                    HStack(spacing: 10) {
                        if step.needsAdmin {
                            Label { Text(verbatim: IssueAlert.adminMark) } icon: { Image(systemName: "lock.fill") }
                                .font(.caption).foregroundStyle(Palette.ink2)
                                .help(Help.Alerts.adminMark)
                        }
                        if step.confirm {
                            Label { Text(verbatim: IssueAlert.confirmMark) } icon: { Image(systemName: "exclamationmark.triangle.fill") }
                                .font(.caption.weight(.semibold)).foregroundStyle(Palette.warn)
                                .help(Help.Alerts.confirmMark)
                        }
                    }
                }
                if let command = step.command {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: command)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Palette.wash)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        if let copy = step.copy {
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(copy, forType: .string)
                            }
                            .controlSize(.small)
                            .help(Help.Alerts.copyStep)
                        }
                    }
                }
            }
        }
    }
}

/// RemedyLine is one remedy step or next command in the monospaced well the
/// first run's review shows its command in, with a Copy button when the step
/// is a whole command.
private struct RemedyLine: View {
    let step: RemedyStep

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: step.text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.wash)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            if let command = step.command {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
                .controlSize(.small)
                .help(Help.Alerts.copyCommand)
            }
        }
    }
}

/// OpensClusterTab makes the panel's status headline a plain button that
/// selects the Alerts tab, the way the tab strip selects one
/// (`AppModel.section`).
struct OpensClusterTab: ViewModifier {
    let app: AppModel

    func body(content: Content) -> some View {
        Button { app.section = .cluster } label: { content.contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .help(Help.Status.headline)
    }
}

extension View {
    /// Selects the Alerts tab when clicked (`OpensClusterTab`).
    func opensClusterTab(_ app: AppModel) -> some View {
        modifier(OpensClusterTab(app: app))
    }
}
