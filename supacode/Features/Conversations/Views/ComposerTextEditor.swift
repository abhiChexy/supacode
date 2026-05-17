import AppKit
import SwiftUI

/// NSTextView-backed composer. Plain Enter sends. Shift+Enter (or Option+
/// Enter) inserts a newline. Cmd+Enter also sends. Auto-grows to fit
/// content up to `maxHeight`; scrolls after.
struct ComposerTextEditor: NSViewRepresentable {
  @Binding var text: String
  @Binding var measuredHeight: CGFloat
  let onCommit: () -> Void
  let maxHeight: CGFloat

  init(
    text: Binding<String>,
    measuredHeight: Binding<CGFloat>,
    maxHeight: CGFloat = 200,
    onCommit: @escaping () -> Void
  ) {
    self._text = text
    self._measuredHeight = measuredHeight
    self.maxHeight = maxHeight
    self.onCommit = onCommit
  }

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
    textView.textContainerInset = NSSize(width: 0, height: 2)
    textView.textContainer?.widthTracksTextView = true

    let scrollView = NSScrollView()
    scrollView.hasVerticalScroller = true
    scrollView.drawsBackground = false
    scrollView.borderType = .noBorder
    scrollView.documentView = textView
    context.coordinator.scrollView = scrollView
    context.coordinator.recomputeHeight()
    return scrollView
  }

  func updateNSView(_ nsView: NSScrollView, context: Context) {
    guard let textView = nsView.documentView as? ChatTextView else { return }
    if textView.string != text {
      textView.string = text
    }
    context.coordinator.recomputeHeight()
  }

  final class Coordinator: NSObject, NSTextViewDelegate {
    let parent: ComposerTextEditor
    weak var scrollView: NSScrollView?

    init(_ parent: ComposerTextEditor) { self.parent = parent }

    func textDidChange(_ notification: Notification) {
      guard let tv = notification.object as? NSTextView else { return }
      parent.text = tv.string
      recomputeHeight()
    }

    func send() {
      parent.onCommit()
    }

    /// Re-measure the text view's used height and write it into the
    /// `measuredHeight` binding so the parent can resize the composer card.
    func recomputeHeight() {
      guard
        let textView = scrollView?.documentView as? NSTextView,
        let layoutManager = textView.layoutManager,
        let container = textView.textContainer
      else { return }
      layoutManager.ensureLayout(for: container)
      let used = layoutManager.usedRect(for: container).size.height
      let inset = textView.textContainerInset.height * 2
      let target = min(parent.maxHeight, max(20, used + inset))
      if abs(target - parent.measuredHeight) > 0.5 {
        DispatchQueue.main.async {
          self.parent.measuredHeight = target
        }
      }
    }
  }

  final class ChatTextView: NSTextView {
    weak var coordinator: Coordinator?

    override func keyDown(with event: NSEvent) {
      let isReturn = event.keyCode == 36 || event.keyCode == 76
      if isReturn {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.shift) || flags.contains(.option) {
          super.keyDown(with: event)
          return
        }
        coordinator?.send()
        return
      }
      super.keyDown(with: event)
    }
  }
}
