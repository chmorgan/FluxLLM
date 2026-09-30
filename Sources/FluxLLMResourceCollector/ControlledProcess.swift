import Darwin
import Foundation

/// Anonymous pipes are the only control/reporting transport in the measured app.
/// Descriptors are moved above 9 before spawn actions, avoiding FD3/FD4 collisions.
final class ControlledProcess {
    let pid: Int32
    let commandDescriptor: Int32
    let eventDescriptor: Int32
    let stdoutDescriptor: Int32
    let stderrDescriptor: Int32
    private(set) var reaped = false

    init(executable: String, environment: [String: String]) throws {
        var owned: [Int32] = []
        func pipePair() throws -> (Int32, Int32) {
            var pair: [Int32] = [0, 0]
            guard pipe(&pair) == 0 else {
                throw CollectorFailure.message("Cannot create control pipe")
            }
            var moved: [Int32] = []
            for fd in pair {
                let replacement = fcntl(fd, F_DUPFD_CLOEXEC, 10)
                close(fd)
                guard replacement >= 0 else {
                    for existing in moved { close(existing) }
                    throw CollectorFailure.message("Cannot reserve control descriptors")
                }
                moved.append(replacement)
            }
            owned += moved
            return (moved[0], moved[1])
        }
        do {
            let commands = try pipePair()
            let events = try pipePair()
            let output = try pipePair()
            let errors = try pipePair()
            let input = open("/dev/null", O_RDONLY | O_CLOEXEC)
            guard input >= 0 else { throw CollectorFailure.message("Cannot open app input") }
            owned.append(input)
            var actions: posix_spawn_file_actions_t?
            var attributes: posix_spawnattr_t?
            guard posix_spawn_file_actions_init(&actions) == 0,
                posix_spawnattr_init(&attributes) == 0
            else {
                throw CollectorFailure.message("Cannot initialize process launch")
            }
            defer {
                posix_spawn_file_actions_destroy(&actions)
                posix_spawnattr_destroy(&attributes)
            }
            for (source, destination) in [
                (input, Int32(0)), (output.1, Int32(1)), (errors.1, Int32(2)),
                (commands.0, Int32(3)), (events.1, Int32(4)),
            ] {
                guard posix_spawn_file_actions_adddup2(&actions, source, destination) == 0 else {
                    throw CollectorFailure.message("Cannot configure child pipe")
                }
            }
            for fd in owned where fd > 4 { posix_spawn_file_actions_addclose(&actions, fd) }
            posix_spawnattr_setflags(
                &attributes, Int16(POSIX_SPAWN_START_SUSPENDED | POSIX_SPAWN_SETPGROUP))
            posix_spawnattr_setpgroup(&attributes, 0)
            let argumentStrings: [String] = [executable, "--performance-control"]
            let arguments: [UnsafeMutablePointer<CChar>?] =
                argumentStrings.map { strdup($0) } + [nil]
            let entries: [UnsafeMutablePointer<CChar>?] =
                environment.sorted { $0.key < $1.key }
                .map { strdup("\($0.key)=\($0.value)") } + [nil]
            defer { for item in arguments + entries { free(item) } }
            var child: pid_t = 0
            let status = arguments.withUnsafeBufferPointer { argv in
                entries.withUnsafeBufferPointer { envp in
                    posix_spawn(
                        &child, executable, &actions, &attributes,
                        UnsafeMutablePointer(mutating: argv.baseAddress!),
                        UnsafeMutablePointer(mutating: envp.baseAddress!))
                }
            }
            guard status == 0 else {
                throw CollectorFailure.message(
                    "posix_spawn failed: \(String(cString: strerror(status)))")
            }
            pid = child
            commandDescriptor = commands.1
            eventDescriptor = events.0
            stdoutDescriptor = output.0
            stderrDescriptor = errors.0
            let retained = Set([
                commandDescriptor, eventDescriptor, stdoutDescriptor, stderrDescriptor,
            ])
            for fd in owned where !retained.contains(fd) { close(fd) }
            owned = []
            for fd in [eventDescriptor, stdoutDescriptor, stderrDescriptor] {
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            }
        } catch {
            for fd in owned { close(fd) }
            throw error
        }
    }

    func resume() throws {
        guard kill(pid, SIGCONT) == 0 else {
            throw CollectorFailure.message("Cannot resume measured process")
        }
    }

    func hasExited() throws -> Bool {
        var info = siginfo_t()
        guard waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 else {
            throw CollectorFailure.message(
                "Cannot observe process exit without reaping (errno \(errno))")
        }
        return info.si_pid == pid
    }

    func reap() throws -> (status: Int32, cpuSeconds: Double) {
        var status: Int32 = 0
        var usage = rusage()
        guard wait4(pid, &status, 0, &usage) == pid else {
            throw CollectorFailure.message("Cannot reap measured process")
        }
        reaped = true
        let cpu =
            Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        let exitStatus: Int32 =
            (status & 0x7f) == 0 ? ((status >> 8) & 0xff) : 128 + (status & 0x7f)
        return (exitStatus, cpu)
    }

    func terminate() {
        guard !reaped else { return }
        kill(-pid, SIGKILL)
        var status: Int32 = 0
        _ = waitpid(pid, &status, 0)
        reaped = true
    }

    deinit {
        terminate()
        for fd in [commandDescriptor, eventDescriptor, stdoutDescriptor, stderrDescriptor] {
            close(fd)
        }
    }
}

func readAvailable(_ fd: Int32) throws -> Data {
    var result = Data()
    var bytes = [UInt8](repeating: 0, count: 16_384)
    while true {
        let count = read(fd, &bytes, bytes.count)
        if count > 0 {
            result.append(contentsOf: bytes.prefix(count))
            guard result.count <= 1_048_576 else {
                throw CollectorFailure.message("Control pipe exceeded its bounded buffer")
            }
        } else if count == 0 {
            break
        } else if errno == EINTR {
            continue
        } else if errno == EAGAIN || errno == EWOULDBLOCK {
            break
        } else {
            throw CollectorFailure.message("Control pipe read failed (errno \(errno))")
        }
    }
    return result
}

func writeAll(_ bytes: Data, to fd: Int32) throws {
    try bytes.withUnsafeBytes { buffer in
        guard let address = buffer.baseAddress else { return }
        var written = 0
        while written < bytes.count {
            let count = write(fd, address.advanced(by: written), bytes.count - written)
            if count > 0 {
                written += count
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                throw CollectorFailure.message("Control pipe write failed (errno \(errno))")
            }
        }
    }
}

func jsonLine(_ value: [String: Any]) throws -> Data {
    var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    data.append(10)
    return data
}
