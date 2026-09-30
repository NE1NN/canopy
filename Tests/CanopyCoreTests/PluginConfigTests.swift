import Foundation
import Testing

@testable import CanopyCore

struct PluginConfigTests {
    @Test func aPluginIsOnWhenItsSectionIsThereAndNotDisabled() throws {
        let dir = try TempDir()
        let file = URL(fileURLWithPath: dir.sub("config.json"))
        try
            #"{"minPaneColumns": 90, "plugins": {"a": {}, "b": {"enabled": false, "url": "x"}, "c": {"enabled": true}}}"#
            .write(to: file, atomically: true, encoding: .utf8)

        let sections = try PluginConfig.sections(in: file)

        #expect(PluginConfig.isOn(sections["a"]))
        #expect(!PluginConfig.isOn(sections["b"]))
        #expect(PluginConfig.isOn(sections["c"]))
        #expect(!PluginConfig.isOn(sections["d"]))
    }

    @Test func noFileMeansNoPlugins() throws {
        let dir = try TempDir()
        #expect(try PluginConfig.sections(in: URL(fileURLWithPath: dir.sub("config.json"))).isEmpty)
    }

    @Test func aFileThatIsNotJSONCannotStartPlugins() throws {
        let dir = try TempDir()
        let file = URL(fileURLWithPath: dir.sub("config.json"))
        try "{not json".write(to: file, atomically: true, encoding: .utf8)

        #expect { try PluginConfig.sections(in: file) } throws: { ($0 as? WorkspaceError)?.code == "config_invalid" }
    }

    @Test func setWritesOneKeyAndKeepsTheRest() throws {
        let dir = try TempDir()
        let file = URL(fileURLWithPath: dir.sub("config.json"))
        try #"{"zeta": 1, "plugins": {"tickets": {"enabled": false, "url": "u", "repo": "old"}}}"#
            .write(to: file, atomically: true, encoding: .utf8)
        let config = PluginConfigFile(url: file)

        #expect(
            try config.set("tickets", key: "repo", to: "new")
                == .object(["enabled": false, "url": "u", "repo": "new"]))
        #expect(try config.set("tickets", key: "repo", to: nil) == .object(["enabled": false, "url": "u"]))
        #expect(try PluginConfig.sections(in: file)["tickets"] == .object(["enabled": false, "url": "u"]))
        #expect(try String(contentsOf: file, encoding: .utf8).contains(#""zeta": 1"#))
    }

    @Test func enableKeepsEveryOtherKeyAndItsOrder() throws {
        let dir = try TempDir()
        let file = URL(fileURLWithPath: dir.sub("config.json"))
        let original = """
            {
              "logCommands": false,
              "plugins": {
                "other": {"x": 1e2},
                "tickets": {"enabled": false, "run": "claude"}
              },
              "zeta": [1, 2]
            }
            """
        try original.write(to: file, atomically: true, encoding: .utf8)

        let section = try PluginConfigFile(url: file).enable("tickets", fields: ["url": "https://a.convex.site"])

        #expect(section == .object(["run": "claude", "url": "https://a.convex.site"]))
        #expect(
            try String(contentsOf: file, encoding: .utf8) == """
                {
                  "logCommands": false,
                  "plugins": {
                    "other": {
                      "x": 1e2
                    },
                    "tickets": {
                      "run": "claude",
                      "url": "https://a.convex.site"
                    }
                  },
                  "zeta": [
                    1,
                    2
                  ]
                }
                """)
    }

    @Test func disableKeepsTheRestOfTheSection() throws {
        let dir = try TempDir()
        let file = URL(fileURLWithPath: dir.sub("config.json"))
        try #"{"plugins": {"tickets": {"url": "u"}}}"#.write(to: file, atomically: true, encoding: .utf8)

        let section = try PluginConfigFile(url: file).disable("tickets")

        #expect(section == .object(["url": "u", "enabled": false]))
        #expect(try PluginConfig.sections(in: file)["tickets"] == .object(["url": "u", "enabled": false]))
    }

    @Test func aSectionThatIsNotAnObjectIsReplacedByOne() throws {
        let dir = try TempDir()
        let file = URL(fileURLWithPath: dir.sub("config.json"))
        try #"{"plugins": {"fixture": true}}"#.write(to: file, atomically: true, encoding: .utf8)

        #expect(try PluginConfigFile(url: file).enable("fixture", fields: [:]) == .object([:]))
    }

    @Test func enablingMakesTheFileWhenThereIsNone() throws {
        let dir = try TempDir()
        let file = URL(fileURLWithPath: dir.sub("config.json"))

        _ = try PluginConfigFile(url: file).enable("fixture", fields: [:])

        #expect(try PluginConfig.sections(in: file)["fixture"] == .object([:]))
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
        #expect(try String(contentsOf: file, encoding: .utf8).hasSuffix("}\n"))
    }

    @Test func aFileThatIsNotJSONIsLeftAlone() throws {
        let dir = try TempDir()
        let file = URL(fileURLWithPath: dir.sub("config.json"))
        try "{not json".write(to: file, atomically: true, encoding: .utf8)

        #expect { try PluginConfigFile(url: file).enable("fixture", fields: [:]) } throws: {
            ($0 as? WorkspaceError)?.code == "config_invalid"
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "{not json")
    }

    @Test func aFolderThatCannotBeWrittenFailsWithTheFileSystemsMessage() throws {
        let dir = try TempDir()
        let folder = dir.sub("locked")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try #"{"a": 1}"#.write(toFile: folder + "/config.json", atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder) }

        #expect {
            try PluginConfigFile(url: URL(fileURLWithPath: folder + "/config.json")).enable("fixture", fields: [:])
        } throws: { error in
            (error as? WorkspaceError)?.code == "config_write_failed"
        }
        #expect(try String(contentsOfFile: folder + "/config.json", encoding: .utf8) == #"{"a": 1}"#)
    }

    @Test func pluginRowsCodeWhatAgentsRead() throws {
        var row = PluginRow(plugin: "tickets", item: "k5", title: "0853-sam", path: "/h/plugins/tickets/0853-sam")
        row.look = PluginRowLook(label: "#0853", accessories: [.dot(.orange, help: "Waiting")])
        let json = try JSONValue.from(row)
        #expect(
            json
                == .object([
                    "plugin": "tickets", "item": "k5", "title": "0853-sam", "path": "/h/plugins/tickets/0853-sam",
                    "label": "#0853", "missing": false,
                ]))
        #expect(try json.decode(PluginRow.self).look.label == "#0853")
    }

    @Test func accessoriesCodeAsPlainObjects() throws {
        #expect(
            try JSONValue.from(PluginAccessory.initials("HI", color: .blue, help: "Owned by Hindie"))
                == .object(["kind": "initials", "text": "HI", "color": "blue", "help": "Owned by Hindie"]))
        #expect(
            try JSONValue.from(PluginAccessory.tag("closed", help: "Closed"))
                == .object(["kind": "tag", "text": "closed", "color": "gray", "help": "Closed"]))
    }
}
