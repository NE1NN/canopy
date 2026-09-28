import Testing

@testable import CanopyCore

/// Real stderr from gh 2.101 and git 2.50.
struct ToolOutputTests {
    @Test func skipsGHsOwnLineAfterGitFails() {
        let output = """
            fatal: destination path 'full' already exists and is not an empty directory.
            failed to run git: exit status 128
            """

        #expect(ToolOutput.reason(output) == "destination path 'full' already exists and is not an empty directory.")
    }

    @Test func takesTheReasonAboveGitsRemoteTrailer() {
        let local = """
            Cloning into 'out'...
            fatal: '/nonexistent/acme/app.git' does not appear to be a git repository
            fatal: Could not read from remote repository.

            Please make sure you have the correct access rights
            and the repository exists.
            """
        let ssh = """
            Cloning into 'app'...
            git@github.com: Permission denied (publickey).
            fatal: Could not read from remote repository.

            Please make sure you have the correct access rights
            and the repository exists.
            """
        let missing =
            "Cloning into 'app'...\nERROR: Repository not found.\nfatal: Could not read from remote repository.\n"

        #expect(ToolOutput.reason(local) == "'/nonexistent/acme/app.git' does not appear to be a git repository")
        #expect(ToolOutput.reason(ssh) == "git@github.com: Permission denied (publickey).")
        #expect(ToolOutput.reason(missing) == "Repository not found.")
    }

    @Test func takesGitsLastFatalLineAfterProgress() {
        let output =
            "Cloning into 'x'...\rReceiving objects:  10% (1/10)\rremote: Repository not found.\n"
            + "fatal: repository 'https://github.com/acme/nope/' not found\n"

        #expect(ToolOutput.reason(output) == "repository 'https://github.com/acme/nope/' not found")
    }

    @Test func fallsBackToTheLastLine() {
        #expect(
            ToolOutput.reason("GraphQL: Could not resolve to a Repository with the name 'acme/nope'. (repository)\n")
                == "GraphQL: Could not resolve to a Repository with the name 'acme/nope'. (repository)")
        #expect(ToolOutput.reason("gh: Bad credentials (HTTP 401)") == "Bad credentials (HTTP 401)")
        #expect(ToolOutput.reason(" \n\r ") == nil)
    }
}
