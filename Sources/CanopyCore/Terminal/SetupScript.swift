/// Turns a repo's setup or teardown commands into one POSIX sh script. It shows each command before running
/// it, runs them in order in one shell so a `cd` carries over, and stops at the first failure with its exit code.
public enum SetupScript {
    public static func render(_ commands: [String], label: String) -> String {
        let runner = [
            "canopy_run() {",
            #"    printf '\033[1m$ %s\033[0m\n' "$1""#,
            #"    eval "$1" || {"#,
            "        canopy_status=$?",
            #"        printf '\n\033[31m%s failed with exit code %s.\033[0m\n' \#(quoted(label)) "$canopy_status""#,
            #"        exit "$canopy_status""#,
            "    }",
            "}",
        ]
        return (runner + commands.map { "canopy_run \(quoted($0))" }).joined(separator: "\n") + "\n"
    }

    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
