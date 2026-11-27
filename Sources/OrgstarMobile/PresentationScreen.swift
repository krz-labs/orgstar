#if os(iOS)
import OrgApp
import OrgCore
import OrgPresentation
import SwiftUI
import UIKit

/// A slide of `SlideShow` as styled text: the theme with its body at `size` points, the
/// heading at the size of a first-level heading, images on lines of their own.
@MainActor
enum MobileSlideText {
    static func attributed(_ slide: SlideShow.Slide, deck: SlideDeck, spec: ThemeSpec, size: CGFloat, width: CGFloat, options: EditingOptions) -> NSAttributedString {
        var scaled = spec
        scaled.fontSize = max(6, Int(size.rounded()))
        scaled.headingSizeStep = max(1, Int((size * 0.2).rounded()))
        scaled.lineSpacing = max(0, Int((CGFloat(spec.lineSpacing) * size / CGFloat(max(6, spec.fontSize))).rounded()))
        let theme = MobileTheme(scaled)
        let display = ReadingText.Display(options: options, highlighter: MobileEditor.highlighter)
        let out = NSMutableAttributedString()
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        centered.paragraphSpacing = size * 0.4

        func styled(_ range: Range<Int>, heading: Bool) -> NSAttributedString {
            let storage = NSTextStorage()
            for segment in ReadingText.segments(deck.tree, in: range, display: display) {
                let start = storage.length
                storage.append(NSAttributedString(string: segment.text, attributes: theme.base))
                let r = NSRange(location: start, length: storage.length - start)
                guard r.length > 0 else { continue }
                if heading { theme.apply(.heading(level: 1), to: storage, range: r) }
                for role in segment.roles.sorted(by: { depth($0) < depth($1) }) {
                    if case .heading = role { continue }
                    theme.apply(role, to: storage, range: r)
                }
                if let superscript = segment.superscript, let font = storage.attribute(.font, at: r.location, effectiveRange: nil) as? UIFont {
                    storage.addAttribute(.baselineOffset, value: (superscript ? 0.3 : -0.3) * font.pointSize, range: r)
                    storage.addAttribute(.font, value: font.withSize(font.pointSize * 0.7), range: r)
                }
            }
            return storage
        }
        func newline() {
            if out.length > 0, !out.string.hasSuffix("\n") { out.append(NSAttributedString(string: "\n", attributes: theme.base)) }
        }

        if let title = slide.title {
            out.append(NSAttributedString(string: title + "\n", attributes: [
                .font: MobileTheme.adding(.traitBold, to: theme.body.withSize(size * 2)),
                .foregroundColor: theme.color("heading-1") ?? theme.foreground, .paragraphStyle: centered,
            ]))
        }
        if !slide.byline.isEmpty {
            out.append(NSAttributedString(string: slide.byline.joined(separator: "\n") + "\n\n",
                                          attributes: [.font: theme.body, .foregroundColor: theme.color("metadata") ?? theme.foreground, .paragraphStyle: centered]))
        }
        if let heading = slide.heading {
            out.append(styled(heading, heading: true))
            out.append(NSAttributedString(string: "\n\n", attributes: theme.base))
        }
        for piece in slide.pieces {
            newline()
            switch piece {
            case .text(let range):
                out.append(styled(range, heading: false))
            case .image(let path, let wanted):
                guard let image = MobileEditor.loadImage(path, relativeTo: deck.directory, remote: .skip) else {
                    out.append(NSAttributedString(string: path, attributes: theme.base))
                    continue
                }
                let attachment = NSTextAttachment()
                attachment.image = image
                attachment.bounds = CGRect(origin: .zero, size: Presentation.imageSize(natural: image.size, width: wanted, maxWidth: width))
                out.append(NSAttributedString(attachment: attachment))
            }
        }
        return out
    }

    static func background(_ spec: ThemeSpec) -> Color {
        Color(uiColor: MobileTheme(spec).color("background") ?? .systemBackground)
    }

    /// How deep a role's text usually nests, so inner roles are applied last.
    static func depth(_ role: StyleRole) -> Int {
        switch role {
        case .heading: 0
        case .metadata, .keyword, .comment, .block, .table, .rule: 1
        case .blockDelimiter, .link, .bold, .italic, .underline, .strikeThrough, .timestamp, .footnote, .target, .macro, .latex: 2
        default: 3
        }
    }
}

/// One slide filling the view, as the external display and the device show it.
struct SlideView: View {
    let deck: SlideDeck
    let slide: SlideShow.Slide
    let theme: ThemeSpec
    let options: EditingOptions
    /// Taps and swipes on the slide.
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?

    var body: some View {
        GeometryReader { geometry in
            let size = SlideDeck.bodySize(for: geometry.size, themeSize: theme.fontSize)
            let margin = max(16, geometry.size.width * 0.06)
            SlideTextView(text: MobileSlideText.attributed(slide, deck: deck, spec: theme, size: size, width: geometry.size.width - 2 * margin, options: options),
                          inset: UIEdgeInsets(top: slide.title != nil ? geometry.size.height * 0.25 : geometry.size.height * 0.06, left: margin, bottom: margin, right: margin),
                          onNext: onNext, onPrevious: onPrevious)
        }
        .background(MobileSlideText.background(theme).ignoresSafeArea())
    }
}

/// The slide's text, not editable, scrolling when it runs past the bottom. A tap on the right
/// two thirds or a swipe to the left goes on; a tap on the left third or a swipe to the right
/// goes back.
private struct SlideTextView: UIViewRepresentable {
    let text: NSAttributedString
    let inset: UIEdgeInsets
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = false
        view.backgroundColor = .clear
        view.textContainer.lineFragmentPadding = 0
        let coordinator = context.coordinator
        view.addGestureRecognizer(UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.tapped(_:))))
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: coordinator, action: #selector(Coordinator.swiped(_:)))
            swipe.direction = direction
            view.addGestureRecognizer(swipe)
        }
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        view.textContainerInset = inset
        view.attributedText = text
        view.setContentOffset(.zero, animated: false)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject {
        var parent: SlideTextView
        init(parent: SlideTextView) { self.parent = parent }

        @objc func tapped(_ tap: UITapGestureRecognizer) {
            guard let view = tap.view as? UIScrollView else { return }
            if tap.location(in: view).x - view.contentOffset.x < view.bounds.width / 3 { parent.onPrevious?() } else { parent.onNext?() }
        }

        @objc func swiped(_ swipe: UISwipeGestureRecognizer) {
            if swipe.direction == .left { parent.onNext?() } else { parent.onPrevious?() }
        }
    }
}

/// Present: the open file one heading at a time, full screen. With an external display (an
/// iPad's, with Stage Manager off), the slide shows there and this screen shows the next slide,
/// the notes and the buttons.
struct PresentationScreen: View {
    let deck: SlideDeck
    let theme: ThemeSpec
    let options: EditingOptions
    @Environment(\.dismiss) private var dismiss
    private var external: ExternalDisplay { .shared }

    var body: some View {
        Group {
            if external.connected {
                presenter
            } else {
                SlideView(deck: deck, slide: deck.slide, theme: theme, options: options, onNext: deck.next, onPrevious: deck.previous)
                    .overlay(alignment: .bottomTrailing) { controls.padding() }
            }
        }
        .background { keys }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear { external.show(deck, theme: theme, options: options) }
        .onDisappear { external.show(nil, theme: theme, options: options) }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Text(deck.position).monospacedDigit().foregroundStyle(.secondary)
            Button("Done") { dismiss() }
                .buttonStyle(.bordered)
        }
        .font(.callout)
    }

    /// The presenter's screen: the next slide, the notes, the slide number and the buttons.
    private var presenter: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Next").font(.headline)
                if let upcoming = deck.upcoming {
                    SlideView(deck: deck, slide: upcoming, theme: theme, options: options)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                } else {
                    Text("End of the slides").foregroundStyle(.secondary)
                }
                if !deck.slide.notes.isEmpty {
                    Text("Notes").font(.headline)
                    ScrollView { Text(deck.slide.notes).frame(maxWidth: .infinity, alignment: .leading) }
                }
                Spacer(minLength: 0)
                HStack {
                    Button("Previous", systemImage: "chevron.left", action: deck.previous)
                        .disabled(deck.index == 0)
                    Spacer()
                    Text(deck.position).monospacedDigit().font(.title3)
                    Spacer()
                    Button("Next", systemImage: "chevron.right", action: deck.next)
                        .disabled(deck.upcoming == nil)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding()
            .navigationTitle("Present")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    /// A hardware keyboard's keys: →, ↓, Space, Page Down and Return go on; ←, ↑, Delete and
    /// Page Up go back; Home and End go to the first and last slide; Escape leaves.
    private var keys: some View {
        ZStack {
            ForEach([KeyEquivalent.rightArrow, .downArrow, .space, .pageDown, .return], id: \.character) { key in
                Button { deck.next() } label: { EmptyView() }.keyboardShortcut(key, modifiers: [])
            }
            ForEach([KeyEquivalent.leftArrow, .upArrow, .pageUp, .delete], id: \.character) { key in
                Button { deck.previous() } label: { EmptyView() }.keyboardShortcut(key, modifiers: [])
            }
            Button { deck.first() } label: { EmptyView() }.keyboardShortcut(.home, modifiers: [])
            Button { deck.last() } label: { EmptyView() }.keyboardShortcut(.end, modifiers: [])
            Button { dismiss() } label: { EmptyView() }.keyboardShortcut(.escape, modifiers: [])
        }
        .opacity(0)
        .accessibilityHidden(true)
    }
}

/// The external display while presenting: the slide on a non-interactive external display
/// scene. Without a presentation the scene has no window, and the display mirrors the device.
@MainActor @Observable
final class ExternalDisplay {
    static let shared = ExternalDisplay()
    private(set) var deck: SlideDeck?
    private(set) var theme = ThemeSpec.default
    private(set) var options = EditingOptions.org
    /// Scenes on external displays now.
    var scenes = 0
    var connected: Bool { scenes > 0 }
    /// Called when a presentation starts or ends, for each scene's window.
    @ObservationIgnored var changed: [ObjectIdentifier: () -> Void] = [:]

    func show(_ deck: SlideDeck?, theme: ThemeSpec, options: EditingOptions) {
        self.deck = deck
        self.theme = theme
        self.options = options
        for update in changed.values { update() }
    }
}

/// The scene iOS connects for an external display (`UIWindowSceneSessionRoleExternalDisplayNonInteractive`
/// in Info.plist): a window with the slide while a presentation is showing.
@objc(ExternalDisplaySceneDelegate)
final class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let display = ExternalDisplay.shared
        display.scenes += 1
        display.changed[ObjectIdentifier(self)] = { [weak self, weak scene] in
            guard let self, let scene else { return }
            self.update(scene)
        }
        update(scene)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        let display = ExternalDisplay.shared
        display.scenes = max(0, display.scenes - 1)
        display.changed[ObjectIdentifier(self)] = nil
        window = nil
    }

    private func update(_ scene: UIWindowScene) {
        guard ExternalDisplay.shared.deck != nil else {
            window?.isHidden = true
            window = nil
            return
        }
        guard window == nil else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: ExternalSlide())
        window.isHidden = false
        self.window = window
    }
}

private struct ExternalSlide: View {
    private var display: ExternalDisplay { .shared }

    var body: some View {
        if let deck = display.deck {
            SlideView(deck: deck, slide: deck.slide, theme: display.theme, options: display.options)
                .ignoresSafeArea()
        }
    }
}
#endif
