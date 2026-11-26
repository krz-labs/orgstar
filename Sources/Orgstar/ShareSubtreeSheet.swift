import AppKit
import OrgApp
import SwiftUI

/// Share Subtree…: the entry at the caret as an org file, with its attachments if chosen, or as
/// text, through the sharing services (AirDrop, Mail, Messages).
struct ShareSubtreeSheet: View {
    let share: SubtreeShare
    let report: (String) -> Void
    @State private var asFile = true
    @State private var withAttachments = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Share Subtree").font(.headline)
            Picker("Share as", selection: $asFile) {
                Text("Org file (\(share.fileName))").tag(true)
                Text("Text").tag(false)
            }
            .pickerStyle(.radioGroup)
            if asFile, !share.attachments.isEmpty {
                Toggle("Include \(share.attachments.count) attachments", isOn: $withAttachments)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                SharingButton(title: String(localized: "Share…"), items: items) { dismiss() }
                    .fixedSize()
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    /// The text, or the written file and the attachments chosen.
    private func items() -> [Any] {
        guard asFile else { return [share.text] }
        do {
            return share.files(file: try share.writeFile(), withAttachments: withAttachments)
        } catch {
            report(String(localized: "Can't share \(share.fileName): \(error.localizedDescription)"))
            return []
        }
    }
}

/// A button that opens the sharing services picker under itself with `items`; `chose` runs once
/// a service is chosen.
struct SharingButton: NSViewRepresentable {
    let title: String
    let items: () -> [Any]
    let chose: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: title, target: context.coordinator, action: #selector(Coordinator.click(_:)))
        button.bezelStyle = .push
        button.keyEquivalent = "\r"
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.parent = self
        button.title = title
    }

    @MainActor
    final class Coordinator: NSObject, NSSharingServicePickerDelegate, NSSharingServiceDelegate {
        var parent: SharingButton

        init(_ parent: SharingButton) {
            self.parent = parent
        }

        @objc func click(_ sender: NSButton) {
            let items = parent.items()
            guard !items.isEmpty else { return }
            let picker = NSSharingServicePicker(items: items)
            picker.delegate = self
            picker.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }

        /// The sheet stays while a service such as AirDrop shows its own sheet on it.
        nonisolated func sharingServicePicker(_ picker: NSSharingServicePicker, delegateFor sharingService: NSSharingService) -> (any NSSharingServiceDelegate)? {
            self
        }

        nonisolated func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
            MainActor.assumeIsolated { parent.chose() }
        }
    }
}
