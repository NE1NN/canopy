import Foundation

public enum ChatMethod {
    public static let new = "chat.new"
}

public struct ChatNewParams: Codable, Sendable {
    public var target: TargetHint
    /// Sent as the chat's first message.
    public var prompt: String?
    public var model: String?
    /// A permission mode, as Claude Code names it: default, acceptEdits, plan, auto, or bypassPermissions.
    public var mode: String?
    /// A Claude Code session to go on with.
    public var resume: String?

    public init(
        target: TargetHint = TargetHint(), prompt: String? = nil, model: String? = nil, mode: String? = nil,
        resume: String? = nil
    ) {
        self.target = target
        self.prompt = prompt
        self.model = model
        self.mode = mode
        self.resume = resume
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        target = try container.decodeIfPresent(TargetHint.self, forKey: .target) ?? TargetHint()
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        mode = try container.decodeIfPresent(String.self, forKey: .mode)
        resume = try container.decodeIfPresent(String.self, forKey: .resume)
    }

    /// Claude Code's permission modes.
    public static let modes = ["default", "acceptEdits", "plan", "auto", "bypassPermissions"]
}

public struct ChatNewResult: Codable, Sendable, Equatable {
    public var pane: String
    public var tab: String
}
