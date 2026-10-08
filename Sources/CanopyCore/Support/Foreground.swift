import Darwin
import Foundation

/// The terminal's foreground, for the attach loop: ssh runs in it, and Return is read from it.
public enum Foreground {
    /// Runs a program on this terminal and returns its exit status. It shares the terminal's process group, so it
    /// gets the window size changes and keys as a program run from a shell does. Keys typed before it starts are
    /// dropped: they were meant for a message on the screen, not for the program.
    public static func run(_ argv: [String]) async -> Int32 {
        await withCheckedContinuation { continuation in
            Thread {
                var pid: pid_t = 0
                let arguments = argv.map { strdup($0) } + [nil]
                defer { for pointer in arguments { free(pointer) } }
                // The concurrency pool's threads, and threads they start, block most signals, which a child inherits.
                var attributes: posix_spawnattr_t?
                posix_spawnattr_init(&attributes)
                defer { posix_spawnattr_destroy(&attributes) }
                var none = sigset_t()
                sigemptyset(&none)
                posix_spawnattr_setsigmask(&attributes, &none)
                var every = sigset_t()
                sigfillset(&every)
                posix_spawnattr_setsigdefault(&attributes, &every)
                posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
                if isatty(STDIN_FILENO) != 0 { tcflush(STDIN_FILENO, TCIFLUSH) }
                guard posix_spawn(&pid, argv[0], nil, &attributes, arguments, environ) == 0 else {
                    continuation.resume(returning: 255)
                    return
                }
                var status: Int32 = 0
                while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
                let signal = status & 0x7f
                continuation.resume(returning: signal == 0 ? (status >> 8) & 0xff : 128 + signal)
            }.start()
        }
    }

    public static func readLine() async -> String? {
        await withCheckedContinuation { continuation in
            Thread { continuation.resume(returning: Swift.readLine()) }.start()
        }
    }
}
