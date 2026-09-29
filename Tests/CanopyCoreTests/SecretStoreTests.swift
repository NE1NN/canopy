import Foundation
import Testing

@testable import CanopyCore

struct SecretStoreTests {
    @Test func secretsAreKeptPerPluginAndPerHome() throws {
        let store = MemorySecretStore()
        let dev = PluginSecrets(
            store: store, bundleID: "com.ne1nn.Canopy.dev", plugin: "tickets", home: CanopyHome(path: "/h/dev"))
        let other = PluginSecrets(
            store: store, bundleID: "com.ne1nn.Canopy.dev", plugin: "tickets", home: CanopyHome(path: "/h/other"))
        let otherPlugin = PluginSecrets(
            store: store, bundleID: "com.ne1nn.Canopy.dev", plugin: "fixture", home: CanopyHome(path: "/h/dev"))

        try dev.write("secret", for: "token")

        #expect(dev.service == "com.ne1nn.Canopy.dev.plugins.tickets")
        #expect(dev.account("token") == "token@/h/dev")
        #expect(try dev.read("token") == "secret")
        #expect(try other.read("token") == nil)
        #expect(try otherPlugin.read("token") == nil)
    }

    @Test func writingAgainReplacesTheSecretAndDeletingTwiceIsFine() throws {
        let secrets = PluginSecrets(
            store: MemorySecretStore(), bundleID: "b", plugin: "p", home: CanopyHome(path: "/h"))

        try secrets.write("one", for: "token")
        try secrets.write("two", for: "token")
        #expect(try secrets.read("token") == "two")

        try secrets.delete("token")
        try secrets.delete("token")
        #expect(try secrets.read("token") == nil)
    }

    @Test func theTrashTestsUseMovesFoldersAsideAndSaysWhere() throws {
        let dir = try TempDir()
        let folder = dir.sub("row")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try "note".write(toFile: folder + "/note.txt", atomically: true, encoding: .utf8)
        let trash = FolderMovingTrash(into: dir.sub("trash"))

        let first = try #require(try trash.trash(URL(fileURLWithPath: folder)))
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let second = try #require(try trash.trash(URL(fileURLWithPath: folder)))

        #expect(!FileManager.default.fileExists(atPath: folder))
        #expect(try String(contentsOf: first.appending(path: "note.txt"), encoding: .utf8) == "note")
        #expect(first != second)
    }
}
