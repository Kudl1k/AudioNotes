import AppKit
import SwiftUI

/// Text input only. Chat actions, context and persistence remain with the caller.
struct ChatTextEditorRepresentable: NSViewRepresentable {
    @Binding var text: String
    @Binding var isComposing: Bool
    var canSend: Bool
    var focusRequest: Int
    var placeholder: String
    var onSend: () -> Void
    var onCancel: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ChatEditorScrollView {
        let scroll = ChatEditorScrollView()
        let editor = ChatInputTextView(frame: .zero)
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.font = .preferredFont(forTextStyle: .body)
        editor.textColor = .textColor
        editor.backgroundColor = .textBackgroundColor
        editor.textContainerInset = NSSize(width: 5, height: 6)
        editor.isVerticallyResizable = false
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.heightTracksTextView = false
        editor.setAccessibilityIdentifier("chat.composer")
        editor.delegate = context.coordinator
        scroll.documentView = editor
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        editor.string = text
        updateEditor(editor, coordinator: context.coordinator)
        return scroll
    }

    func updateNSView(_ scroll: ChatEditorScrollView, context: Context) {
        guard let editor = scroll.documentView as? ChatInputTextView else { return }
        context.coordinator.parent = self
        // Never replace marked text or reset selection on unrelated stream updates.
        if editor.string != text && !editor.hasMarkedText() {
            let selection = editor.selectedRange()
            editor.string = text
            let length = (text as NSString).length
            editor.setSelectedRange(NSRange(location: min(selection.location, length), length: min(selection.length, max(0, length - selection.location))))
            editor.undoManager?.removeAllActions()
            scroll.needsLayout = true
            scroll.needsRevealSelection = true
            scroll.invalidateIntrinsicContentSize()
        }
        updateEditor(editor, coordinator: context.coordinator)
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            let request = focusRequest
            Task { @MainActor [weak editor, weak coordinator = context.coordinator] in
                await Task.yield()
                guard let editor, coordinator?.lastFocusRequest == request else { return }
                editor.window?.makeFirstResponder(editor)
            }
        }
    }

    private func updateEditor(_ editor: ChatInputTextView, coordinator: Coordinator) {
        editor.canSend = canSend
        editor.onSend = { [weak coordinator] in coordinator?.parent.onSend() }
        editor.onCancel = onCancel
        editor.onCompositionChange = { [weak coordinator] marked in
            guard let coordinator, coordinator.parent.isComposing != marked else { return }
            coordinator.parent.isComposing = marked
        }
        editor.setAccessibilityLabel("Message")
        editor.setAccessibilityPlaceholderValue(placeholder)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ChatEditorScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return CGSize(width: width, height: nsView.editorHeight(width: width))
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatTextEditorRepresentable
        var lastFocusRequest: Int
        init(_ parent: ChatTextEditorRepresentable) {
            self.parent = parent
            lastFocusRequest = parent.focusRequest
        }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
            (editor.enclosingScrollView as? ChatEditorScrollView)?.needsRevealSelection = true
            editor.enclosingScrollView?.needsLayout = true
            editor.enclosingScrollView?.invalidateIntrinsicContentSize()
        }
    }
}

/// Native interpretation handles selection, undo, clipboard, arrows and input methods.
/// Only unmodified, unmarked Return is intercepted; modified Return stays native.
@MainActor final class ChatInputTextView: NSTextView {
    override init(frame frameRect: NSRect) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: 1, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        super.init(frame: frameRect, textContainer: container)
    }

    required init?(coder: NSCoder) { super.init(coder: coder) }

    var canSend = false
    var onSend: (() -> Void)?
    var onCancel: (() -> Void)?
    var onCompositionChange: ((Bool) -> Void)?

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        onCompositionChange?(hasMarkedText())
    }
    override func unmarkText() {
        super.unmarkText()
        onCompositionChange?(hasMarkedText())
    }

    override func insertTab(_ sender: Any?) { window?.selectNextKeyView(self) }
    override func insertBacktab(_ sender: Any?) { window?.selectPreviousKeyView(self) }
    override func cancelOperation(_ sender: Any?) {
        if hasMarkedText() { inputContext?.discardMarkedText() }
        else { onCancel?() }
    }

    @discardableResult
    func handleReturn(modifiers: NSEvent.ModifierFlags, isRepeat: Bool = false) -> Bool {
        guard !hasMarkedText(), modifiers.intersection([.shift, .option, .command, .control]).isEmpty else { return false }
        if canSend && !isRepeat && !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { onSend?() }
        return true
    }

    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 36 || event.keyCode == 76), handleReturn(modifiers: event.modifierFlags, isRepeat: event.isARepeat) { return }
        super.keyDown(with: event)
    }
}

@MainActor final class ChatEditorScrollView: NSScrollView {
    static let minimumHeight: CGFloat = 34
    static let maximumHeight: CGFloat = 140

    var needsRevealSelection = false
    private var measurement: (text: String, width: CGFloat, height: CGFloat)?

    func editorHeight(width: CGFloat) -> CGFloat {
        guard let editor = documentView as? NSTextView else { return Self.minimumHeight }
        if let measurement, measurement.text == editor.string, measurement.width == width { return measurement.height }
        // Measuring a SwiftUI proposal must not resize/invalidate the displayed
        // text container. A separate text layout has no view or constraints.
        let font = editor.font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let storage = NSTextStorage(string: editor.string, attributes: [.font: font])
        let layout = NSLayoutManager()
        let container = NSTextContainer(containerSize: NSSize(width: max(1, width - editor.textContainerInset.width * 2), height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)
        let lineHeight = layout.defaultLineHeight(for: font)
        let height = max(lineHeight, max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY)) + editor.textContainerInset.height * 2
        let bounded = min(Self.maximumHeight, max(Self.minimumHeight, ceil(height)))
        measurement = (editor.string, width, bounded)
        return bounded
    }
    override func layout() {
        super.layout()
        guard let editor = documentView as? NSTextView,
              let container = editor.textContainer, let layout = editor.layoutManager else { return }
        container.containerSize = NSSize(width: max(1, contentView.bounds.width - editor.textContainerInset.width * 2), height: CGFloat.greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        let height = max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY) + editor.textContainerInset.height * 2
        let size = NSSize(width: contentView.bounds.width, height: max(contentView.bounds.height, ceil(height)))
        if editor.frame.size != size { editor.setFrameSize(size) }
        if needsRevealSelection {
            needsRevealSelection = false
            editor.scrollRangeToVisible(editor.selectedRange())
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: editorHeight(width: max(1, bounds.width)))
    }
}
