import Foundation

/// Branch names as git allows them, checked without running git, so the New Row sheet can check each keystroke.
public enum BranchName {
    /// git's rules for a name under refs/heads/, and Canopy's own: no leading `-`, which would read as an option, and
    /// neither `HEAD` nor `@`, which git reads as HEAD.
    public static func isValid(_ name: String) -> Bool {
        guard !name.isEmpty, name != "@", name != "HEAD", !name.hasPrefix("-"), !name.hasPrefix("/"),
            !name.hasSuffix("/"), !name.hasSuffix("."), !name.contains(".."), !name.contains("//"),
            !name.contains("@{")
        else { return false }
        let forbidden = Set(" ~^:?*[\\".unicodeScalars)
        guard !name.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || forbidden.contains($0) })
        else { return false }
        return name.split(separator: "/").allSatisfy { !$0.hasPrefix(".") && !$0.hasSuffix(".lock") }
    }
}
