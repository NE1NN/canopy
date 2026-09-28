import Foundation

/// A program that puts its terminal in raw mode, asks for bracketed paste if told to, then prints each read it gets
/// as a line "read <time> <bytes>", with the time in seconds since 1970 and bytes outside printable ASCII written as
/// <hex>, such as <0d> for Return.
enum ReadRecorder {
    static let script = #"""
        use Time::HiRes qw(time);
        system("stty raw -echo");
        $| = 1;
        print "\e[?2004h" if $ARGV[0] eq "paste";
        print "ready\r\n";
        while (sysread(STDIN, my $bytes, 65536)) {
            my $when = time;
            $bytes =~ s/([^ -~])/sprintf("<%02x>", ord $1)/ge;
            printf "read %.6f %s\r\n", $when, $bytes;
        }
        """#

    /// Writes the script into `dir` and returns its path.
    static func install(in dir: TempDir) throws -> String {
        let path = dir.sub("read-recorder.pl")
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    /// A shell command that runs the recorder at `path`.
    static func command(_ path: String, paste: Bool) -> String {
        "exec /usr/bin/perl '\(path)' \(paste ? "paste" : "plain")"
    }

    /// Each read, in order, with when the program got it.
    static func timedReads(in output: String) -> [(bytes: String, time: Date)] {
        output.components(separatedBy: "\r\n").compactMap { line in
            guard line.hasPrefix("read ") else { return nil }
            let fields = line.dropFirst(5).split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, let seconds = Double(fields[0]) else { return nil }
            return (String(fields[1]), Date(timeIntervalSince1970: seconds))
        }
    }

    /// What each read held, in order.
    static func reads(in output: String) -> [String] {
        timedReads(in: output).map(\.bytes)
    }

    /// `text` as the recorder prints it.
    static func escaped(_ text: String) -> String {
        text.utf8.map { (0x20...0x7e).contains($0) ? String(UnicodeScalar($0)) : String(format: "<%02x>", $0) }
            .joined()
    }
}
