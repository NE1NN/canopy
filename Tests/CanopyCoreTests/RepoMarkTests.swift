import Testing

@testable import CanopyCore

struct RepoMarkTests {
    @Test func theLetterIsTheFolderNamesFirstLetterOrDigit() {
        #expect(RepoMark(name: "web-app", path: "/x/web-app").letter == "W")
        #expect(RepoMark(name: "work/client/app", path: "/work/client/app").letter == "A")
        #expect(RepoMark(name: ".dotfiles", path: "/x/.dotfiles").letter == "D")
        #expect(RepoMark(name: "2048", path: "/x/2048").letter == "2")
        #expect(RepoMark(name: "ärger", path: "/x/ärger").letter == "Ä")
        #expect(RepoMark(name: "straße", path: "/x/straße").letter == "S")
        #expect(RepoMark(name: "---", path: "/x/---").letter == "?")
    }

    @Test func theHueComesFromAHashThatIsTheSameInEveryLaunch() {
        // FNV-1a's published test values. Swift's Hasher is seeded per process, so it would change hues on relaunch.
        #expect(RepoMark.stableHash("") == 0xcbf2_9ce4_8422_2325)
        #expect(RepoMark.stableHash("a") == 0xaf63_dc4c_8601_ec8c)
        #expect(RepoMark.stableHash("foobar") == 0x8594_4171_f739_67e8)

        let mark = RepoMark(name: "web", path: "/a/web")
        #expect(mark.hue == Int(RepoMark.stableHash("/a/web") % UInt64(RepoMark.hueCount)))
    }

    @Test func reposWithTheSameNameSpreadAcrossTheHues() {
        let hues = Set((0..<40).map { RepoMark(name: "app", path: "/p\($0)/app").hue })
        #expect(hues == Set(0..<RepoMark.hueCount))
    }
}
