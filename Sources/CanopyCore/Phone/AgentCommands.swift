import Foundation

extension Workspace {
    /// Shows, sets, or with `reset` forgets what a task from the phone runs, on this Mac or on an upgraded host, whose
    /// canopy-box gets the change now when its link is up and at its next connect otherwise.
    public func agentCommand(_ params: PhonesAgentParams) async throws -> PhonesAgentResult {
        var command = params.command?.trimmingCharacters(in: .whitespacesAndNewlines)
        if params.reset {
            command = nil
        } else if command?.isEmpty == true {
            throw ControlError(
                code: "bad_params",
                message: "The agent command is empty. Pass --default to go back to the standard one.")
        }
        let changes = params.reset || command != nil
        guard let alias = params.on else {
            if changes {
                try ConfigFile(url: home.configFile).change { $0["agentCommand"] = command.map { .string($0) } }
            }
            let saved = GlobalConfig.load(from: home.configFile).agentCommand
            return PhonesAgentResult(command: PhoneAgentCommand.chosen(saved), isDefault: saved == nil)
        }
        let hosts = self.hosts.hosts
        guard var entry = hosts[alias] else { throw WorkspaceError.hostNotFound(alias, known: hosts.keys.sorted()) }
        guard entry.box else {
            throw ControlError(
                code: "host_not_upgraded",
                message:
                    "\(alias) does not run canopy-box, which starts tasks from the phone. Run `canopy host upgrade \(alias)` first."
            )
        }
        if changes {
            entry.agentCommand = command
            try HostsConfigFile(url: home.configFile).save(alias, entry)
            if let link = boxLinks[alias] { _ = try? await link.reconfigure() }
        }
        return PhonesAgentResult(
            command: PhoneAgentCommand.chosen(entry.agentCommand), isDefault: entry.agentCommand == nil, on: alias)
    }
}
