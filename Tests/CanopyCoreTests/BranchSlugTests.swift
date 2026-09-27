import Foundation
import Testing

@testable import CanopyCore

struct BranchSlugTests {
    @Test func replacesSlashes() {
        #expect(BranchSlug.slug(for: "fix/auth/login") == "fix-auth-login")
    }

    @Test func avoidsExistingFolders() {
        let parent = URL(fileURLWithPath: "/w")
        let taken: Set<String> = ["/w/fix-a", "/w/fix-a-2"]
        let folder = BranchSlug.folder(for: "fix/a", in: parent) { taken.contains($0.path) }
        #expect(folder.path == "/w/fix-a-3")
    }
}
