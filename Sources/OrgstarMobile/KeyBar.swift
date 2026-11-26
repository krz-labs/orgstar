#if os(iOS)
import OrgApp
import OrgCore
import SwiftUI
import UIKit

/// Org's keys for a touch keyboard: each button does what its key does at the caret, as the
/// Emacs keymap binds it (M-→ demotes a heading, indents an item, moves a table column), or
/// runs a command. The buttons are `[key-bar]` in config.toml, or the default; they share the
/// width without scrolling, and those that don't fit go under More.
struct KeyBar: View {
    let editor: MobileEditor
    let palette: () -> Void
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage(KeyBarLayout.Width.iphone.defaultsKey) private var iphone: String?
    @AppStorage(KeyBarLayout.Width.ipad.defaultsKey) private var ipad: String?
    @State private var width: CGFloat?

    /// A button the bar can hold.
    struct Item {
        enum Action {
            /// What the keys are bound to at the caret.
            case keys(String)
            case command(String)
            case palette
            /// Schedule, Deadline and Tags in a menu.
            case plan
            case hideKeyboard
        }

        let label: String
        /// Nil shows `face` as text.
        let symbol: String?
        let action: Action
        /// The text on the button without a symbol; the label when nil.
        var face: String? = nil

        var text: String { face ?? label }
        var slots: Int { KeyBarLayout.slots(symbol: symbol != nil, face: text) }
    }

    /// The bar's own buttons, by id.
    static let items: [String: Item] = [
        "commands": Item(label: String(localized: "Commands"), symbol: "command", action: .palette),
        "fold": Item(label: String(localized: "Fold", comment: "Key bar button"), symbol: "arrow.right.to.line", action: .keys("TAB")),
        "overview": Item(label: String(localized: "Overview", comment: "Key bar button"), symbol: "arrow.left.to.line", action: .keys("S-TAB")),
        "promote": Item(label: String(localized: "Promote", comment: "Key bar button"), symbol: "decrease.indent", action: .keys("M-<left>")),
        "demote": Item(label: String(localized: "Demote", comment: "Key bar button"), symbol: "increase.indent", action: .keys("M-<right>")),
        "move-up": Item(label: String(localized: "Move Up", comment: "Key bar button"), symbol: "arrow.up.square", action: .keys("M-<up>")),
        "move-down": Item(label: String(localized: "Move Down", comment: "Key bar button"), symbol: "arrow.down.square", action: .keys("M-<down>")),
        "new-heading": Item(label: String(localized: "New Heading or Item", comment: "Key bar button"), symbol: "plus", action: .keys("M-RET")),
        "todo": Item(label: "TODO", symbol: nil, action: .keys("C-c C-t")),
        "act": Item(label: String(localized: "Act at Point", comment: "Key bar button"), symbol: "checkmark.square", action: .keys("C-c C-c")),
        "plan": Item(label: String(localized: "Plan", comment: "Key bar button: a menu of Schedule, Deadline and Tags"), symbol: "calendar.badge.clock", action: .plan),
        "schedule": Item(label: String(localized: "Schedule", comment: "Key bar button"), symbol: "calendar", action: .keys("C-c C-s")),
        "deadline": Item(label: String(localized: "Deadline", comment: "Key bar button"), symbol: "calendar.badge.exclamationmark", action: .keys("C-c C-d")),
        "tags": Item(label: String(localized: "Tags", comment: "Key bar button"), symbol: "tag", action: .keys("C-c C-q")),
        "open-link": Item(label: String(localized: "Open Link", comment: "Key bar button"), symbol: "link", action: .keys("C-c C-o")),
        "bold": Item(label: String(localized: "Bold", comment: "Key bar button"), symbol: "bold", action: .command("org.emphasize.bold")),
        "italic": Item(label: String(localized: "Italic", comment: "Key bar button"), symbol: "italic", action: .command("org.emphasize.italic")),
        "code": Item(label: String(localized: "Code", comment: "Key bar button"), symbol: "chevron.left.forwardslash.chevron.right", action: .command("org.emphasize.code")),
        "hide-keyboard": Item(label: String(localized: "Hide Keyboard"), symbol: "keyboard.chevron.compact.down", action: .hideKeyboard),
    ]

    /// Commands with a symbol of their own; others show their title.
    static let commandSymbols: [String: String] = [
        KeyBarLayout.nextField: "forward.end", KeyBarLayout.previousField: "backward.end",
        "edit.undo": "arrow.uturn.backward", "edit.redo": "arrow.uturn.forward", "edit.isearch-forward": "magnifyingglass",
        "org.cycle": "arrow.right.to.line", "org.cycle-global": "arrow.left.to.line",
        "org.emphasize.bold": "bold", "org.emphasize.italic": "italic", "org.emphasize.underline": "underline",
        "org.emphasize.code": "chevron.left.forwardslash.chevron.right", "org.emphasize.strike-through": "strikethrough",
        "org.link.insert": "link.badge.plus", "org.link.open": "link",
        "app.clock.in": "clock", "app.clock.out": "clock.badge.checkmark",
    ]

    /// The editor's commands by id, with English titles.
    private static let commandTitles = Dictionary(CommandPalette.viewCommands + Commands.everything.map { ($0.id, $0.title) }) { first, _ in first }

    /// The button for an id: one of the bar's own, a command, a named macro (its name) or a
    /// snippet (its trigger); nil for an id that is none of these here.
    static func item(_ id: String) -> Item? {
        if let item = items[id] { return item }
        if let trigger = Snippets.trigger(ofCommand: id) {
            guard let snippet = SnippetLibrary.shared.snippets.first(where: { $0.trigger == trigger }) else { return nil }
            return Item(label: Snippets.label(snippet), symbol: nil, action: .command(id), face: trigger)
        }
        if id.hasPrefix(NamedMacros.commandPrefix) {
            let name = String(id.dropFirst(NamedMacros.commandPrefix.count))
            return NamedMacros.shared.names.contains(name) ? Item(label: name, symbol: nil, action: .command(id)) : nil
        }
        guard !AppStoreCommands.hidden.contains(id), let title = commandTitles[id].map(CommandTitle.localized) else { return nil }
        return Item(label: title, symbol: commandSymbols[id], action: .command(id), face: KeyBarLayout.face(title: title))
    }

    /// Ids in `[key-bar]` that are no button here.
    static func problems() -> [String] {
        KeyBarLayout.Width.allCases.flatMap { width in
            KeyBarLayout.problems(KeyBarLayout.stored(width, in: .standard) ?? [], width) { item($0) != nil }
        }
    }

    /// The bar's buttons are at least 44 points tall, scaled with the text size up to here.
    static let largestSize = DynamicTypeSize.accessibility2
    static let target: CGFloat = 44
    static let padding: CGFloat = 4
    /// The widest a one-slot button gets where the bar has room.
    nonisolated static let widest: CGFloat = 64
    @ScaledMetric(relativeTo: .body) private var size = KeyBar.target

    var body: some View {
        let layout = sizeClass == .regular ? KeyBarLayout.Width.ipad : .iphone
        var ids = ((layout == .ipad ? ipad : iphone).map(KeyBarLayout.ids) ?? layout.defaultIDs).filter { Self.item($0) != nil }
        if editor.fields.active { ids = KeyBarLayout.withSnippetFields(ids) }
        let available = width.map { KeyBarLayout.availableSlots(width: $0 - 12, scale: symbolScale) } ?? .max
        let (shown, more) = KeyBarLayout.fit(ids, available: available) { Self.item($0)?.slots ?? 1 }
        return SlotRow {
            ForEach(shown, id: \.self) { id in
                if let item = Self.item(id) { button(item).layoutValue(key: Slots.self, value: item.slots) }
            }
            if !more.isEmpty { moreButton(more) }
        }
        .labelStyle(.iconOnly)
        .padding(.horizontal, 6)
        .padding(.vertical, Self.padding)
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background(.bar)
    }

    @ViewBuilder
    private func button(_ item: Item) -> some View {
        switch item.action {
        case .plan:
            Menu {
                planEntries()
            } label: {
                label(item).modifier(KeyShape(size: size))
            }
            .accessibilityLabel(item.label)
        default:
            Button {
                run(item)
            } label: {
                label(item)
            }
            .buttonStyle(KeyStyle(size: size, slots: item.slots))
            .accessibilityLabel(item.label)
        }
    }

    private func planEntries() -> some View {
        ForEach(["schedule", "deadline", "tags"], id: \.self) { id in
            if let entry = Self.items[id], case .keys(let keys) = entry.action {
                Button(entry.label, systemImage: entry.symbol ?? "") { editor.run(keys: keys) }
            }
        }
    }

    /// The buttons that don't fit, in a menu in their order.
    private func moreButton(_ ids: [String]) -> some View {
        Menu {
            ForEach(ids, id: \.self) { id in
                if let item = Self.item(id) {
                    switch item.action {
                    case .plan:
                        Menu(item.label, systemImage: item.symbol ?? "") { planEntries() }
                    default:
                        if let symbol = item.symbol {
                            Button(item.label, systemImage: symbol) { run(item) }
                        } else {
                            Button(item.label) { run(item) }
                        }
                    }
                }
            }
        } label: {
            Label(String(localized: "More"), systemImage: "ellipsis")
                .dynamicTypeSize(...Self.largestSymbolSize)
                .modifier(KeyShape(size: size))
        }
        .menuOrder(.fixed)
        .accessibilityLabel(String(localized: "More"))
    }

    private func run(_ item: Item) {
        switch item.action {
        case .keys(let keys): editor.run(keys: keys)
        case .command(let id): editor.run(id)
        case .palette: palette()
        case .hideKeyboard: editor.textView.resignFirstResponder()
        case .plan: break
        }
    }

    /// The buttons grow taller with the text size, but their symbols stop growing here.
    static let largestSymbolSize = DynamicTypeSize.xxxLarge

    /// How much larger than at the default size the symbols are drawn, which the slots follow.
    private var symbolScale: CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(min(typeSize, Self.largestSymbolSize)))
        return UIFontMetrics(forTextStyle: .body).scaledValue(for: 1, compatibleWith: traits)
    }

    @ViewBuilder
    private func label(_ item: Item) -> some View {
        Group {
            if let symbol = item.symbol {
                Label(item.label, systemImage: symbol)
            } else if item.slots == 1 {
                // A word is wider than a symbol, so it stays at the default size.
                Text(item.text).font(.callout.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.5)
                    .dynamicTypeSize(...DynamicTypeSize.large)
            } else {
                Text(item.text).font(.caption.weight(.semibold)).lineLimit(2).minimumScaleFactor(0.6)
                    .multilineTextAlignment(.center).padding(.horizontal, 2)
                    .dynamicTypeSize(...DynamicTypeSize.large)
            }
        }
        .dynamicTypeSize(...Self.largestSymbolSize)
    }
}

/// A button's width in slots.
private struct Slots: LayoutValueKey {
    static let defaultValue = 1
}

/// The bar's buttons in a row, each as wide as its share of the slots.
private struct SlotRow: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let slots = subviews.reduce(0) { $0 + $1[Slots.self] }
        let width = proposal.width ?? CGFloat(slots) * KeyBar.widest
        let unit = width / CGFloat(max(slots, 1))
        let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: unit * CGFloat($0[Slots.self]), height: proposal.height)).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let unit = bounds.width / CGFloat(max(subviews.reduce(0) { $0 + $1[Slots.self] }, 1))
        var x = bounds.minX
        for view in subviews {
            let width = unit * CGFloat(view[Slots.self])
            view.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width
        }
    }
}

/// A key bar button's look: a tinted label on a rounded tile, `size` tall, sharing the bar's
/// width with the others. The whole share is the touch target.
private struct KeyShape: ViewModifier {
    let size: CGFloat
    var slots = 1
    var pressed = false

    func body(content: Content) -> some View {
        content
            .foregroundStyle(.tint)
            .frame(maxWidth: KeyBar.widest * CGFloat(slots), minHeight: size)
            .background(.fill.tertiary, in: .rect(cornerRadius: 10))
            .opacity(pressed ? 0.5 : 1)
            .padding(.horizontal, 2)
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
    }
}

private struct KeyStyle: ButtonStyle {
    let size: CGFloat
    let slots: Int

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(KeyShape(size: size, slots: slots, pressed: configuration.isPressed))
    }
}
#endif
