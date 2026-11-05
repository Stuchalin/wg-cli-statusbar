import AppKit
import SwiftUI

/// NSTextView is needed to disable substitutions and undo retention explicitly.
/// SwiftUI TextEditor does not expose a reliable undo-manager cleanup boundary.
struct ConfigTextEditor: NSViewRepresentable {
    @Binding var text: String
    let isEditable: Bool

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ConfigTextEditor
        init(_ parent: ConfigTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard parent.isEditable, let view = notification.object as? NSTextView else { return }
            if !parent.text.utf8.elementsEqual(view.string.utf8) { parent.text = view.string }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        let view = Self.makeEditor(delegate: context.coordinator)
        scroll.documentView = view
        DispatchQueue.main.async { [weak view] in
            guard let view, let window = view.window, window.isKeyWindow, view.isEditable else { return }
            window.makeFirstResponder(view)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        view.isEditable = isEditable
        if !view.string.utf8.elementsEqual(text.utf8) { view.string = text }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        guard let view = scroll.documentView as? NSTextView else { return }
        view.delegate = nil
        view.undoManager?.removeAllActions()
        view.string = ""
        // Swift/AppKit do not promise physical erasure of all backing storage.
    }

    static func makeEditor(delegate: NSTextViewDelegate?) -> NSTextView {
        let view = NSTextView()
        view.isRichText = false
        view.allowsUndo = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.isGrammarCheckingEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        view.textContainerInset = NSSize(width: 12, height: 12)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.setAccessibilityLabel(L10n.string("config.editor.accessibility.text"))
        view.delegate = delegate
        return view
    }
}
