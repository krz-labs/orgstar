import Foundation
import OrgCore

/// Where new org-roam nodes go, and their slugs.
public enum RoamNode {
    /// `org-roam-directory`: the setting, else the first folder.
    public static func directory(roots: [String], defaults: UserDefaults = .standard) -> String? {
        let roam = OrgPreferences.roamDirectory(defaults)
        return roam.isEmpty ? roots.first : OrgAttach.expand(roam, in: roots.first ?? OrgPaths.home)
    }

    /// `org-roam-node-slugify`: without the combining marks org-roam drops, everything but
    /// letters and digits as one `_`, none at either end, lower case.
    public static func slug(_ title: String) -> String {
        let trimmed: Set<UInt32> = [0x300, 0x301, 0x302, 0x303, 0x304, 0x306, 0x307, 0x308, 0x309, 0x30A, 0x30B, 0x30C,
                                    0x31B, 0x323, 0x324, 0x325, 0x327, 0x32D, 0x32E, 0x330, 0x331]
        let decomposed = title.decomposedStringWithCanonicalMapping.unicodeScalars.filter { !trimmed.contains($0.value) }
        let composed = String(String.UnicodeScalarView(decomposed)).precomposedStringWithCanonicalMapping
        var out = ""
        for character in composed {
            if character.isLetter || character.isNumber {
                out.append(character)
            } else if out.last != "_" {
                out.append("_")
            }
        }
        while out.first == "_" { out.removeFirst() }
        while out.last == "_" { out.removeLast() }
        return out.lowercased()
    }
}
