import AppKit
import SwiftUI

/// NSTextView-backed composer. Plain Enter sends. Shift+Enter inserts a
/// newline. Cmd+Enter also sends. Matches Slack/Conductor convention.
struct ComposerTextEditor: NSViewRepresentable {
  @Binding var text: String
  let onCommit: () -> Void

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  func makeNSView(context: Context) -> NSScrollView {
    let textView = ChatTextView()
    textView.delegate = context.coordinator
    textView.coordinator = context.coordinator
    textView.string = text
    textView.font = NSFont.systemFont(ofSize: 13)
    textView.textColor = NSColor(white: 0.929, alpha: 1)
    textView.backgroundColor = .clear
    textView.drawsBackground = false
    textView.insertionPointColor = NSColor.systemBlue
    textView.isRichText = false
    textView.isEditable = true
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.allowsUndo = true
    textView.textContainer?.widthTracksTextView = true

    let scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder
    scrollView.documentView = textView
    return scrollView
  }

  func updateNSView(_ nsView: NSScrollView, context: Context) {
    guard let textView = nsView.documentView as? ChatTextView else { return }
    if textView.string != text {
      textView.string = text
    }
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    let parent: ComposerTextEditor
    init(_ parent: ComposerTextEditor) { self.parent = parent }

    func textDidChange(_ notification: Notification) {
      guard let tv = notification.object as? NSTextView else { return }
      parent.text = tv.string
    }

    func send() {
      parent.onCommit()
    }
  }

  final class ChatTextView: NSTextView {
    weak var coordinator: Coordinator?

    override func keyDown(with event: NSEvent) {
      // Enter (no modifiers) → send. Shift+Enter or Option+Enter → newline.
      // Cmd+Enter → send.
      let isReturn = event.keyCode == 36 || event.keyCode == 76
      if isReturn {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.shift) || flags.contains(.option) {
          super.keyDown(with: event)
          return
        }
        // plain Enter or Cmd+Enter both send
        coordinator?.send()
        return
      }
      super.keyDown(with: event)
    }
  }
}
