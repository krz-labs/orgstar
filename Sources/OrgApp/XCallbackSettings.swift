import SwiftUI

/// The apps allowed to capture, clock and read through x-callback-url links, each with
/// Forget, for a settings form.
public struct XCallbackSettings: View {
    @Bindable var approvals: XCallbackApprovals

    public init(approvals: XCallbackApprovals = .shared) {
        self.approvals = approvals
    }

    public var body: some View {
        Section {
            if approvals.sources.isEmpty {
                Text("None").foregroundStyle(.secondary)
            }
            ForEach(approvals.sources) { source in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(XCallbackApprovals.name(source))
                        Text(XCallbackApprovals.destination(source)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Forget") { approvals.forget(source) }.buttonStyle(.borderless)
                }
            }
        } header: {
            Text("Apps Allowed to Use Links")
        } footer: {
            Text("Apps that may capture, clock in and out, and read your agenda and clock through orgstar:// x-callback-url links without asking.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension XCallbackApprovals {
    /// The name the app gave, or a stand-in when it gave none.
    public static func name(_ source: Source) -> String {
        source.name.isEmpty ? String(localized: "An app that doesn't give its name") : source.name
    }

    /// Where results go: `Results go to shortcuts:`.
    public static func destination(_ source: Source) -> String {
        source.schemes.isEmpty
            ? String(localized: "No results are sent back")
            : String(localized: "Results go to \(source.schemes.map { $0 + ":" }.joined(separator: ", "))")
    }

    /// The question asked before an app's first link that writes to files or reads them.
    public static func question(_ source: Source) -> String {
        source.name.isEmpty ? String(localized: "Allow links from an app that doesn't give its name?") : String(localized: "Allow “\(source.name)” to use orgstar?")
    }

    public static func explanation(_ source: Source) -> String {
        String(localized: "Its links will be able to capture, clock in and out, and read your agenda and clock without asking again. \(destination(source)). You can forget it in Settings.")
    }
}
