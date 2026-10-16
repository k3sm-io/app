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

/// TabStripLayout sizes the console's strip, the row above the tab: the tab
/// labels, the managed update's button while one is offered, the search
/// field at its minimum, and the three icon buttons, with the strip's gaps
/// and padding. Widths are estimated the way `PanelLayout` estimates them,
/// from character counts at the same conservative per-point advance, so the
/// estimate errs wide and a label never has to wrap or shorten at the
/// window's minimum width. A label is drawn on one line; only a label longer
/// than `labelCap` characters is shortened, at its tail.
public enum TabStripLayout {
    /// The tab labels' font size.
    public static let fontSize: Double = 13
    /// The gap between two tabs.
    public static let tabSpacing: Double = 16
    /// The gap between the strip's items: the tabs, the spacer, the update
    /// button, the search field and the icon buttons.
    public static let itemSpacing: Double = 12
    /// The spacer between the tabs and the controls, at its least.
    public static let spacerMinimum: Double = 8
    /// The details, tour and info buttons with the gaps between them.
    public static let controlsWidth: Double = 3 * 20 + 2 * itemSpacing
    /// The search field's minimum width.
    public static let searchMinimum: Double = 100
    /// The strip's horizontal padding, both sides together.
    public static let padding: Double = 32
    /// The longest label drawn in full; a longer one is shortened at its tail.
    public static let labelCap = 24
    /// The update button's font size (a small control).
    public static let buttonFontSize: Double = 11
    /// The update button's padding around its title, both sides together.
    public static let buttonPadding: Double = 24

    /// The window's minimum width before the strip decided it, with the
    /// panel and the inspector shown.
    public static let windowFloor: Double = 1180
    /// The inspector's fixed width.
    public static let inspectorWidth: Double = 320
    /// The divider beside the panel, and the one beside the inspector.
    public static let dividerWidth: Double = 1

    /// `label` as the strip draws it: whole up to `labelCap` characters,
    /// otherwise its first `labelCap - 1` characters and an ellipsis.
    public static func display(_ label: String) -> String {
        guard label.count > labelCap else { return label }
        return String(label.prefix(labelCap - 1)) + "…"
    }

    /// One label's estimated width at `fontSize`, as drawn (`display`).
    public static func labelWidth(_ label: String, fontSize: Double = Self.fontSize) -> Double {
        Double(display(label).count) * fontSize * PanelLayout.advance
    }

    /// The tabs alone: every label at its estimated width, `spacing` apart.
    public static func tabsWidth(labels: [String], fontSize: Double = Self.fontSize, spacing: Double = Self.tabSpacing) -> Double {
        guard !labels.isEmpty else { return 0 }
        return labels.map { labelWidth($0, fontSize: fontSize) }.reduce(0, +) + Double(labels.count - 1) * spacing
    }

    /// The update button's estimated width for `title`.
    public static func buttonWidth(title: String) -> Double {
        Double(title.count) * buttonFontSize * PanelLayout.advance + buttonPadding
    }

    /// The strip's minimum width: the tabs (`tabsWidth`), the spacer at its
    /// least, the update button when one is offered (`buttonWidth` non-nil),
    /// the search field's minimum, the icon buttons, the gaps between the
    /// items and the strip's `padding`.
    public static func minimumWidth(labels: [String], fontSize: Double = Self.fontSize, buttonWidth: Double?,
                                    searchWidth: Double = Self.searchMinimum, spacing: Double = Self.tabSpacing,
                                    padding: Double = Self.padding) -> Double {
        var width = tabsWidth(labels: labels, fontSize: fontSize, spacing: spacing)
        width += itemSpacing + spacerMinimum + itemSpacing
        if let buttonWidth { width += buttonWidth + itemSpacing }
        width += searchWidth + itemSpacing
        return width + controlsWidth + padding
    }

    /// The content pane's minimum width (the strip's column, and the
    /// inspector with its divider when shown): the larger of what the floor
    /// leaves after the panel and the width a `strip` that wide needs.
    public static func contentMinimumWidth(strip: Double, inspectorShown: Bool) -> Double {
        let inspector = inspectorShown ? inspectorWidth + dividerWidth : 0
        let floor = windowFloor - PanelLayout.minimum - dividerWidth - (inspectorShown ? 0 : inspectorWidth)
        return max(floor, strip + inspector)
    }

    /// The window's minimum width: the panel's minimum and its divider,
    /// nothing while the panel is collapsed, plus the content's minimum.
    public static func windowMinimumWidth(strip: Double, inspectorShown: Bool, panelCollapsed: Bool) -> Double {
        let panel = panelCollapsed ? 0 : PanelLayout.minimum + dividerWidth
        return panel + contentMinimumWidth(strip: strip, inspectorShown: inspectorShown)
    }
}
