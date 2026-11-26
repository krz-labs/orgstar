import SwiftUI

/// "Use Face ID to Decrypt" and the files with a saved passphrase, for a settings form.
public struct DecryptSettings: View {
    @Bindable var passphrases: CryptPassphrases
    @State private var confirmingOff = false

    public init(passphrases: CryptPassphrases = .shared) {
        self.passphrases = passphrases
    }

    public var body: some View {
        Section {
            Toggle(CryptPassphrases.title, isOn: Binding {
                passphrases.setting == .on
            } set: { on in
                if on {
                    passphrases.turnOn()
                } else if passphrases.savedPaths.isEmpty {
                    passphrases.turnOff()
                } else {
                    confirmingOff = true
                }
            })
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(CryptPassphrases.explanation)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { passphrases.refresh() }
        .alert(String(localized: "Remove Saved Passphrases?"), isPresented: $confirmingOff) {
            Button("Cancel", role: .cancel) {}
            Button("Turn Off", role: .destructive) { passphrases.turnOff() }
        } message: {
            Text(CryptPassphrases.removal(passphrases.savedPaths.count))
        }
        if !passphrases.savedPaths.isEmpty {
            Section("Saved Passphrases") {
                ForEach(passphrases.savedPaths, id: \.self) { path in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text((path as NSString).lastPathComponent)
                            Text((path as NSString).deletingLastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button("Forget") { passphrases.forget(path) }.buttonStyle(.borderless)
                    }
                }
            }
        }
    }
}

/// Asks whether to use Face ID to decrypt, once, at launch, when an earlier version saved
/// passphrases and the setting is undecided.
public struct DecryptQuestion: ViewModifier {
    @Bindable var passphrases: CryptPassphrases

    public init(passphrases: CryptPassphrases = .shared) {
        self.passphrases = passphrases
    }

    public func body(content: Content) -> some View {
        content
            .task { passphrases.askIfSavedBefore() }
            .alert(CryptPassphrases.question, isPresented: Binding(get: { passphrases.asking }, set: { _ in })) {
                Button("Not Now", role: .cancel) { passphrases.answer(enable: false) }
                Button("Enable") { passphrases.answer(enable: true) }
            } message: {
                Text(CryptPassphrases.explanation)
            }
    }
}
