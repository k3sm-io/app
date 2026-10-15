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

/// GeneralPasteboard adapts the general NSPasteboard to `Pasteboard`. One
/// write prepares the pasteboard for this Mac only (`.currentHostOnly`, so
/// Universal Clipboard never offers it to another device), then puts the
/// text under the string type and an empty marker under every other type
/// (the concealed type). The change count it returns is the one
/// `prepareForNewContents` returned; setting the item's data does not move it.
@MainActor
final class GeneralPasteboard: K3smInstall.Pasteboard {
    private let pasteboard = NSPasteboard.general

    var changeCount: Int { pasteboard.changeCount }

    func write(_ text: String, types: [PasteboardType], options: PasteboardOptions) -> Int {
        var prepare: NSPasteboard.ContentsOptions = []
        if options.contains(.currentHostOnly) {
            prepare.insert(.currentHostOnly)
        }
        let count = pasteboard.prepareForNewContents(with: prepare)
        for type in types {
            if type == .string {
                pasteboard.setString(text, forType: .string)
            } else {
                pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType(type.rawValue))
            }
        }
        return count
    }

    func clearContents() {
        pasteboard.clearContents()
    }

    var types: [PasteboardType] {
        (pasteboard.types ?? []).map { PasteboardType(rawValue: $0.rawValue) }
    }

    func string() -> String? {
        pasteboard.string(forType: .string)
    }
}
