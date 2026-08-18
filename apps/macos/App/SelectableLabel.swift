import AppKit
import SwiftUI

/// A selectable, copyable label backed by `NSTextField`. Unlike SwiftUI `Text`,
/// this participates in the standard responder chain, so right-click Copy/Select All,
/// Edit-menu shortcuts, and ⌘C/⌘A all work for status, error, and diagnostic text.
struct SelectableLabel: NSViewRepresentable {
    let text: String
    var font: NSFont = .systemFont(ofSize: NSFont.smallSystemFontSize)
    var textColor: NSColor = .labelColor
    var maximumNumberOfLines: Int = 0
    var lineBreakMode: NSLineBreakMode = .byWordWrapping

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.isSelectable = true
        field.isEditable = false
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.maximumNumberOfLines = maximumNumberOfLines
        field.lineBreakMode = lineBreakMode
        field.font = font
        field.textColor = textColor
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        field.stringValue = text
        field.font = font
        field.textColor = textColor
        field.maximumNumberOfLines = maximumNumberOfLines
        field.lineBreakMode = lineBreakMode
    }
}

extension SelectableLabel {
    func font(_ value: NSFont) -> SelectableLabel {
        var copy = self
        copy.font = value
        return copy
    }

    func foregroundStyle(_ color: NSColor) -> SelectableLabel {
        var copy = self
        copy.textColor = color
        return copy
    }
}
