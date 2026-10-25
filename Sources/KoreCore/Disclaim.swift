import Darwin
import Foundation

/// The CLIs and terminal shells Kore starts run as their own as far as macOS counts energy.
/// Activity Monitor charges an app for every process it started and everything under them, so
/// a CLI's builds, tests and dev servers read as Kore's. Each starts through Kore's own binary
/// (`flag`), which becomes the program in place (same process, pipes and group) with its
/// responsibility disclaimed, as Terminal, VS Code and Chrome start theirs.
public enum Disclaim {
    public static let flag = "--disclaimed-exec"

    /// The binary that honours `flag`: Kore's, set at launch. Nil (tests, storylines,
    /// `kore-cli`): programs start directly.
    nonisolated(unsafe) public static var trampoline: String?

    /// `executable arguments` as they're started: through the trampoline when there is one.
    package static func wrap(_ executable: String, _ arguments: [String]) -> (executable: String, arguments: [String]) {
        guard let trampoline else { return (executable, arguments) }
        return (trampoline, [flag, executable] + arguments)
    }

    /// First thing in a binary that can be a trampoline: started with `flag`, it becomes the
    /// program and never returns; otherwise it returns at once.
    public static func execIfAsked() {
        let args = CommandLine.arguments
        guard args.count >= 3, args[1] == flag else { return }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        var none = sigset_t(), all = sigset_t()
        sigemptyset(&none)
        sigfillset(&all)
        posix_spawnattr_setsigmask(&attributes, &none)
        posix_spawnattr_setsigdefault(&attributes, &all)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETEXEC | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        _ = setDisclaim.map { $0(&attributes, 1) }
        var argv: [UnsafeMutablePointer<CChar>?] = args.dropFirst(2).map { strdup($0) } + [nil]
        var pid: pid_t = 0
        let error = posix_spawn(&pid, args[2], nil, &attributes, &argv, environ)
        // Only a failed exec returns.
        FileHandle.standardError.write(Data("\(args[2]): \(String(cString: strerror(error)))\n".utf8))
        exit(127)
    }

    /// The process macOS charges `pid`'s energy to: itself once disclaimed.
    package static func responsible(for pid: pid_t) -> pid_t? { responsibleFor.map { $0(pid) } }

    private typealias SetDisclaim = @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32
    private typealias ResponsibleFor = @convention(c) (pid_t) -> pid_t
    // Private libsystem calls, looked up rather than linked: without them a program starts as before.
    private static let setDisclaim = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_spawnattrs_setdisclaim")
        .map { unsafeBitCast($0, to: SetDisclaim.self) }
    private static let responsibleFor = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
        .map { unsafeBitCast($0, to: ResponsibleFor.self) }
}
