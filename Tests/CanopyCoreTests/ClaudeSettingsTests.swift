import Foundation
import Testing

@testable import CanopyCore

extension Fixture {
    /// A settings file in the temporary folder. Tests must never resolve the real one: every agent on the machine
    /// runs with it.
    static func claudeSettings(_ dir: TempDir, _ name: String = "claude/settings.json") -> ClaudeSettingsFile {
        let file = ClaudeSettingsFile.resolve(
            explicit: dir.sub(name), environment: [:], homeDirectory: dir.sub("user-home"))
        let real = NSHomeDirectory() + "/.claude/settings.json"
        if file.url.path == real || file.url.resolvingSymlinksInPath().path == real {
            Issue.record("A test resolved the real Claude Code settings file.")
            return ClaudeSettingsFile(url: URL(fileURLWithPath: dir.sub("refused.json")))
        }
        return file
    }
}

struct ClaudeSettingsTests {
    /// Settings as Claude Code writes them: JSON.stringify with two-space indentation.
    static let written = """
        {
          "model": "opus",
          "permissions": {
            "allow": [
              "Bash(git status)",
              "Read(//tmp/**)"
            ],
            "deny": []
          },
          "hooks": {
            "Stop": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "say \\"done\\" && echo '✓ 完了'",
                    "timeout": 1.5
                  }
                ]
              }
            ],
            "PreToolUse": [
              {
                "matcher": "Bash",
                "hooks": [
                  {
                    "type": "command",
                    "command": "~/bin/check\\tbash"
                  }
                ]
              }
            ]
          },
          "cleanupPeriodDays": 1e2,
          "feedbackSurveyState": {
            "lastShownTime": 1759000000000
          },
          "enabledPlugins": {},
          "statusLine": null,
          "includeCoAuthoredBy": false
        }

        """

    func write(_ text: String, to file: ClaudeSettingsFile) throws {
        try FileManager.default.createDirectory(
            at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file.url)
    }

    func text(_ file: ClaudeSettingsFile) throws -> String {
        String(decoding: try Data(contentsOf: file.url), as: UTF8.self)
    }

    @Test func jsonComesBackTheWayItWasWritten() throws {
        let parsed = try OrderedJSON.parse(Data(Self.written.utf8))
        #expect(parsed.formatted() + "\n" == Self.written)
        #expect(parsed["model"] == .string("opus"))
        #expect(parsed["cleanupPeriodDays"] == .number("1e2"))

        let escapes = try OrderedJSON.parse(Data(#"{"a":"é😀\/\b\f\n\r\t\u0001\"\\","b":[],"c":{}}"#.utf8))
        #expect(escapes["a"] == .string("é😀/\u{8}\u{c}\n\r\t\u{1}\"\\"))
        #expect(
            escapes.formatted() == """
                {
                  "a": "é😀/\\b\\f\\n\\r\\t\\u0001\\"\\\\",
                  "b": [],
                  "c": {}
                }
                """)
    }

    @Test func invalidJSONIsRefused() {
        for text in [
            "", "{", #"{"a": 1,}"#, "{\"a\": 1} // note", "[1] 2", "{a: 1}", "tru", "01", "1.", "-", #"{"a":"\x"}"#,
            "\"unterminated",
        ] {
            #expect(throws: OrderedJSONError.self, "\(text)") { try OrderedJSON.parse(Data(text.utf8)) }
        }
    }

    @Test func installIntoAMissingFileCreatesItWithEveryHook() throws {
        let dir = try TempDir()
        let file = Fixture.claudeSettings(dir)

        #expect(try file.status() == .notInstalled)
        #expect(try file.install())
        #expect(try file.status() == .installed)

        let settings = try OrderedJSON.parse(try Data(contentsOf: file.url))
        guard case .object(let events) = settings["hooks"] else {
            Issue.record("no hooks")
            return
        }
        #expect(
            events.map(\.key) == [
                "SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse",
                "PostToolUseFailure", "Notification", "Elicitation", "ElicitationResult", "Stop", "StopFailure",
                "SessionEnd",
            ])
        let text = try text(file)
        #expect(text.hasSuffix("}\n"))
        #expect(
            text.contains(
                """
                    "PreToolUse": [
                      {
                        "matcher": "AskUserQuestion|ExitPlanMode",
                        "hooks": [
                          {
                            "type": "command",
                            "command": "[ -z \\"$CANOPY_CLI\\" ] || \\"$CANOPY_CLI\\" agent-hook >/dev/null 2>&1 || true",
                            "async": true
                          }
                        ]
                      }
                    ],
                """))
        #expect(
            text.contains(
                """
                    "Stop": [
                      {
                        "hooks": [
                          {
                            "type": "command",
                            "command": "[ -z \\"$CANOPY_CLI\\" ] || \\"$CANOPY_CLI\\" agent-hook >/dev/null 2>&1 || true",
                            "timeout": 5
                          }
                        ]
                      }
                    ],
                """))
        #expect(
            text.contains(
                """
                    "SessionEnd": [
                      {
                        "hooks": [
                          {
                            "type": "command",
                            "command": "[ -z \\"$CANOPY_CLI\\" ] || \\"$CANOPY_CLI\\" agent-hook >/dev/null 2>&1 || true"
                          }
                        ]
                      }
                    ]
                """))
    }

    @Test func installKeepsEverythingElseAndUninstallGivesBackTheSameBytes() throws {
        let dir = try TempDir()
        let file = Fixture.claudeSettings(dir)
        try write(Self.written, to: file)

        #expect(try file.install())
        let installed = try OrderedJSON.parse(try Data(contentsOf: file.url))
        #expect(installed["model"] == .string("opus"))
        guard case .object(let keys) = installed, case .object(let events) = installed["hooks"],
            case .array(let stop) = installed["hooks"]?["Stop"]
        else {
            Issue.record("no hooks")
            return
        }
        #expect(keys.map(\.key).first == "model")
        #expect(events.map(\.key).prefix(2) == ["Stop", "PreToolUse"])
        #expect(stop.count == 2)

        let before = try Data(contentsOf: file.url)
        #expect(try !file.install())
        #expect(try Data(contentsOf: file.url) == before)

        #expect(try file.uninstall())
        #expect(try text(file) == Self.written)
        #expect(try !file.uninstall())
        #expect(try file.status() == .notInstalled)
    }

    @Test func olderOrMissingCanopyHooksAreOutdatedAndReplaced() throws {
        let dir = try TempDir()
        let file = Fixture.claudeSettings(dir)
        try write(
            """
            {
              "hooks": {
                "Stop": [
                  {
                    "hooks": [
                      {
                        "type": "command",
                        "command": "\\"$CANOPY_CLI\\" agent-hook"
                      },
                      {
                        "type": "command",
                        "command": "afplay /System/Library/Sounds/Hero.aiff"
                      }
                    ]
                  }
                ]
              }
            }
            """, to: file)
        #expect(try file.status() == .outdated)

        #expect(try file.install())
        #expect(try file.status() == .installed)
        let text = try text(file)
        #expect(!text.contains(#""\"$CANOPY_CLI\" agent-hook""#))
        #expect(text.contains("afplay"))

        // One hook taken out by hand makes the rest outdated.
        try file.update { settings in
            var settings = settings
            settings["hooks"]?["Elicitation"] = nil
            return settings
        }
        #expect(try file.status() == .outdated)
        #expect(try file.install())
        #expect(try file.status() == .installed)
    }

    @Test func aLinkedSettingsFileIsWrittenThrough() throws {
        let dir = try TempDir()
        let target = Fixture.claudeSettings(dir, "dotfiles/claude-settings.json")
        try write("{\n  \"model\": \"opus\"\n}\n", to: target)
        let link = Fixture.claudeSettings(dir, "claude/settings.json")
        try FileManager.default.createDirectory(
            at: link.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link.url, withDestinationURL: target.url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.url.path)

        #expect(try link.install())
        let attributes = try FileManager.default.attributesOfItem(atPath: link.url.path)
        #expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink)
        #expect(try target.status() == .installed)
        let targetAttributes = try FileManager.default.attributesOfItem(atPath: target.url.path)
        #expect(targetAttributes[.posixPermissions] as? Int == 0o600)
    }

    @Test func aFileThatIsNotAJSONObjectIsLeftAlone() throws {
        let dir = try TempDir()
        let file = Fixture.claudeSettings(dir)
        for text in ["{ \"model\": \"opus\", }", "[]", "{\"hooks\": []}", "{\"hooks\": {\"Stop\": {}}}"] {
            try write(text, to: file)
            #expect(throws: WorkspaceError.self) { try file.install() }
            #expect(try self.text(file) == text)
        }
        try write("[]", to: file)
        do {
            try file.install()
        } catch let error as WorkspaceError {
            #expect(error.code == "settings_invalid")
        }
    }

    @Test func aFileChangedWhileWritingIsReadAgain() throws {
        let dir = try TempDir()
        let file = Fixture.claudeSettings(dir)
        try write("{\n  \"model\": \"opus\"\n}\n", to: file)
        var attempts = 0
        try file.update { settings in
            attempts += 1
            if attempts == 1 {
                // Claude Code saves a setting of its own at the same moment.
                try Data("{\n  \"model\": \"sonnet\"\n}\n".utf8).write(to: file.url)
            }
            return ClaudeHooks.installing(into: try settings.validSettings())
        }
        #expect(attempts == 2)
        let settings = try OrderedJSON.parse(try Data(contentsOf: file.url))
        #expect(settings["model"] == .string("sonnet"))
        #expect(ClaudeHooks.status(of: settings) == .installed)
    }

    @Test func disablingAllHooksIsNoticed() throws {
        let dir = try TempDir()
        let file = Fixture.claudeSettings(dir)
        try write("{\n  \"disableAllHooks\": true\n}\n", to: file)
        #expect(try file.disablesAllHooks())
        try write("{\n  \"disableAllHooks\": false\n}\n", to: file)
        #expect(try !file.disablesAllHooks())
    }

    @Test func theFileIsFoundLikeClaudeCodeFindsIt() {
        let home = "/Users/someone"
        #expect(
            ClaudeSettingsFile.resolve(
                explicit: "/tmp/s.json", environment: ["CLAUDE_CONFIG_DIR": "/x"], homeDirectory: home
            )
            .url.path == "/tmp/s.json")
        #expect(
            ClaudeSettingsFile.resolve(
                explicit: nil, environment: ["CLAUDE_CONFIG_DIR": "/x/claude"], homeDirectory: home
            )
            .url.path == "/x/claude/settings.json")
        #expect(
            ClaudeSettingsFile.resolve(explicit: nil, environment: ["CLAUDE_CONFIG_DIR": ""], homeDirectory: home).url
                .path == "/Users/someone/.claude/settings.json")
        #expect(
            ClaudeSettingsFile.configFolder(environment: [:], homeDirectory: home).path == "/Users/someone/.claude")
        #expect(
            ClaudeSettingsFile.resolve(explicit: "~/s.json", environment: [:], homeDirectory: home).url.path
                == NSString(string: "~/s.json").expandingTildeInPath)
    }
}
