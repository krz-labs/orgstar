import OrgApp
import OrgDocument
import SwiftUI

/// Above the mode line while the focused file isn't saved because it would put text on disk
/// unencrypted: why, and the button that asks for the passphrase. Stays while it applies.
struct CryptHoldBar: View {
    let session: DocumentSession
    let encrypt: () -> Void

    var body: some View {
        if let path = session.path, let hold = session.held[path] {
            HStack(spacing: 8) {
                Image(systemName: "lock.trianglebadge.exclamationmark").foregroundStyle(.orange)
                Text(hold.notice(for: path)).lineLimit(3)
                Spacer(minLength: 8)
                Button(hold == .file ? "Set Passphrase…" : "Encrypt…", action: encrypt)
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12))
            .accessibilityElement(children: .combine)
        }
    }
}

/// The session follows the org-crypt settings, and asks for the passphrase of an encrypted file
/// it was asked to open.
struct CryptSettings: ViewModifier {
    let session: DocumentSession
    let cryptBeforeSave: Bool
    let cryptTagMatcher: String
    let unlock: (String) -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: cryptBeforeSave, initial: true) { _, on in session.encryptsTaggedEntries = on }
            .onChange(of: cryptTagMatcher, initial: true) { session.cryptTag = OrgPreferences.cryptTag() }
            .onChange(of: session.unlockRequest, initial: true) { _, path in
                if let path { unlock(path) }
            }
    }
}
