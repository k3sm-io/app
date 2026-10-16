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

import K3smStatus
import SwiftUI

/// BuildsSection is the Builds tab: one card for the build engine, decided by
/// `BuildEngine`, and the build history below it. The CLI records no build
/// history yet, so the tab says so rather than listing anything.
struct BuildsSection: View {
    @ObservedObject var loader: TabLoader<BuildEngine>

    static let noHistory = "No build history recorded."

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    card
                    Text(verbatim: Self.noHistory).font(.system(size: 13)).foregroundStyle(Palette.ink2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            TabFooter(load: loader.load)
        }
    }

    @ViewBuilder private var card: some View {
        switch loader.load {
        case .failed(let text): note(text)
        case .unavailable(let reason): note(reason)
        default:
            if let engine = loader.value {
                EngineCard(engine: engine)
            } else {
                note("Reading the build engine…")
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(verbatim: text).foregroundStyle(Palette.ink2)
    }
}

/// EngineCard is the build engine at a glance: its state with a dot, the
/// reason line, then the pod, its node and the cache claim. Every string was
/// clipped by the decoder.
struct EngineCard: View {
    let engine: BuildEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Build engine").font(.system(size: 14, weight: .semibold))
                Spacer()
                Circle().fill(Palette.health(engine.state.severity)).frame(width: 9, height: 9)
                Text(verbatim: engine.state.word).font(.system(size: 12, weight: .medium))
            }
            Text(verbatim: engine.state.detail).font(.system(size: 12)).foregroundStyle(Palette.ink2).lineLimit(2)
            if let pod = engine.podName {
                fact("Pod", pod)
            }
            if let node = engine.nodeName {
                fact("Node", node)
            }
            if let cache = engine.cache {
                fact("Cache", [cache.name, cache.phase, WorkloadsDisplay.bytes(cache.capacityBytes)]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
            }
        }
        .padding(16)
        .frame(maxWidth: 460, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.wash))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.line))
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).font(.system(size: 11.5)).foregroundStyle(Palette.dimText).frame(width: 44, alignment: .leading)
            Text(verbatim: value).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
        }
    }
}
