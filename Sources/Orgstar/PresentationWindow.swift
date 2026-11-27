import AppKit
import OrgApp
import OrgCore
import OrgEditorAppKit
import OrgPresentation
import SwiftUI

/// Present (`app.present`): the open file one heading at a time in a full-screen window, as
/// org-present and org-tree-slide show it. →, ↓, Space, Page Down and Return go on; ←, ↑,
/// Delete and Page Up go back; Home and End go to the first and last slide; Escape or Done
/// leaves.
@MainActor
enum PresentationWindow {
    private static var window: NSWindow?

    static func show(_ deck: SlideDeck, theme: ThemeSpec, options: EditingOptions) {
        window?.close()
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        let frame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("presentation")
        window.title = String(localized: "Present")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.backgroundColor = SlideText.background(theme)
        window.contentView = NSHostingView(rootView: PresentationView(deck: deck, theme: theme, options: options) { close() })
        window.setFrame(frame, display: true)
        window.makeKeyAndOrderFront(nil)
        self.window = window
        window.toggleFullScreen(nil)
    }

    static func close() {
        window?.close()
        window = nil
    }
}

private struct PresentationView: View {
    let deck: SlideDeck
    let theme: ThemeSpec
    let options: EditingOptions
    let done: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { geometry in
            let size = SlideDeck.bodySize(for: geometry.size, themeSize: theme.fontSize)
            let margin = geometry.size.width * 0.07
            ZStack(alignment: .bottomTrailing) {
                SlideTextView(text: SlideText.attributed(deck.slide, tree: deck.tree, spec: theme, size: size, width: geometry.size.width - 2 * margin,
                                                         directory: deck.directory, options: options, highlighter: PaneView.highlighter),
                              inset: CGSize(width: margin, height: deck.slide.title != nil ? geometry.size.height * 0.28 : geometry.size.height * 0.08))
                HStack(spacing: 16) {
                    Text(deck.position).monospacedDigit().foregroundStyle(.secondary)
                    Button("Done", action: done)
                }
                .padding()
            }
        }
        .background(Color(nsColor: SlideText.background(theme)))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(keys: [.rightArrow, .downArrow, .space, .pageDown, .return, .leftArrow, .upArrow, .pageUp, .delete, .home, .end, .escape]) { press in
            switch press.key {
            case .rightArrow, .downArrow, .space, .pageDown, .return: deck.next()
            case .leftArrow, .upArrow, .pageUp, .delete: deck.previous()
            case .home: deck.first()
            case .end: deck.last()
            default: done()
            }
            return .handled
        }
    }
}

/// The slide's text, not editable, scrolling when it runs past the bottom.
private struct SlideTextView: NSViewRepresentable {
    let text: NSAttributedString
    let inset: CGSize

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        let view = scroll.documentView as! NSTextView
        view.isEditable = false
        view.isSelectable = false
        view.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let view = scroll.documentView as! NSTextView
        view.textContainerInset = inset
        view.textStorage?.setAttributedString(text)
        view.scroll(.zero)
    }
}
