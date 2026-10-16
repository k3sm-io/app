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

extension View {
    /// Attaches a catalog help tag (`Help`), the only way a view gets one.
    nonisolated func help(_ tag: HelpTag) -> some View {
        help(Text(verbatim: tag.text))
    }

    /// Attaches `tag` when there is one (a column header with a tag of its own).
    @ViewBuilder
    nonisolated func help(optional tag: HelpTag?) -> some View {
        if let tag {
            help(tag)
        } else {
            self
        }
    }
}
