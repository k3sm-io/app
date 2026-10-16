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

import K3smInstall
import K3smStatus
import SwiftUI

/// UpdateProgressPanel is the managed update's progress in the console, under
/// the strip: the title, a detail and remedy, one row per node, and Cancel
/// while the roll runs or Dismiss once it is over. It renders `UpdatePanel`,
/// whose strings are already clipped; the read behind it is `AppModel`'s.
struct UpdateProgressPanel: View {
    @ObservedObject var app: AppModel
    let panel: UpdatePanel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(Palette.navy)
                Text(panel.title).font(.system(size: 13, weight: .semibold))
                Spacer()
                if panel.showsCancel {
                    let reason = app.updateCancelReason
                    Button(LifecycleVerb.updateCancel.title + "…") { app.cancelUpdate() }
                        .controlSize(.small)
                        .disabled(reason != nil)
                        .help(Help.Update.cancel(reason: reason))
                }
                if panel.showsDismiss {
                    Button("Dismiss") { app.dismissUpdate() }.controlSize(.small)
                        .help(Help.Update.dismiss)
                }
            }
            if let detail = panel.detail {
                Text(detail).font(.system(size: 12)).foregroundStyle(Palette.ink2)
            }
            if let remedy = panel.remedy {
                Text(remedy).font(.system(size: 12, weight: .medium))
            }
            ForEach(Array(panel.nodes.enumerated()), id: \.offset) { _, node in
                HStack(spacing: 12) {
                    Text(node.name).font(.system(size: 12, weight: .medium)).frame(width: 160, alignment: .leading)
                    Text(node.versions).font(.system(size: 12).monospacedDigit()).frame(width: 150, alignment: .leading)
                    Text(node.phase).font(.system(size: 12)).frame(width: 90, alignment: .leading)
                    Text(node.message).font(.system(size: 12)).foregroundStyle(Palette.ink2).lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.wash)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
    }
}
