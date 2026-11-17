import HangarCore
import Darwin
import Foundation

/// ProcessTable is the live process table as `ProcessSweep` reads it.
enum ProcessTable {
    /// read returns every process visible to this user, nil when the kernel refuses.
    static func read() -> [ProcessRecord]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        let stride = MemoryLayout<kinfo_proc>.stride
        // the table can grow between the sizing call and the read, which answers ENOMEM
        for margin in [64, 512] {
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + margin)
            size = procs.count * stride
            if sysctl(&mib, u_int(mib.count), &procs, &size, nil, 0) == 0 {
                return procs.prefix(size / stride).map { proc in
                    let started = proc.kp_proc.p_starttime
                    return ProcessRecord(pid: proc.kp_proc.p_pid,
                                         started: Int64(started.tv_sec) * 1_000_000 + Int64(started.tv_usec),
                                         group: proc.kp_eproc.e_pgid, foreground: proc.kp_eproc.e_tpgid)
                }
            }
            if errno != ENOMEM { return nil }
        }
        return nil
    }
}

/// ProcessSweeper hangs up the foreground job a killed daemon's shell leaves running, as closing a
/// terminal would have. Injected into `ZmxClient`, which has none by default: a test's fake listing
/// names pids that are real processes on the machine running it.
struct ProcessSweeper {
    /// table reads the process table, nil when it cannot be read.
    var table: () -> [ProcessRecord]? = ProcessTable.read
    var signal: (Int32, pid_t) -> Void = { _ = kill($1, $0) }
    /// endLater SIGKILLs what is left of a hung-up job after `killGrace`, so a closed pane's job that ignores
    /// SIGHUP (`nohup`, a trap) does not outlive it. It reads the real table, never `table`, and dies with the app.
    var endLater: ([ProcessRecord]) -> Void = ProcessSweeper.killAfterGrace
    static let killGrace: TimeInterval = 2

    private static func killAfterGrace(_ job: [ProcessRecord]) {
        DispatchQueue.global().asyncAfter(deadline: .now() + killGrace) { ProcessSweeper().send(SIGKILL, to: job) }
    }

    /// hangUp sends `job` the SIGHUP a closed terminal would, then ends it after `killGrace`.
    func hangUp(_ job: [ProcessRecord]) {
        send(SIGHUP, to: job)
        endLater(job)
    }

    /// group returns the members of process group `pgid`, empty when the table cannot be read.
    func group(_ pgid: pid_t) -> [ProcessRecord] {
        table()?.filter { $0.group == pgid } ?? []
    }

    /// capture returns each shell's foreground job, keyed like `shells`, omitting shells without one.
    func capture(shells: [String: pid_t]) -> [String: [ProcessRecord]] {
        guard let table = table() else { return [:] }
        return shells.mapValues { ProcessSweep.foregroundJob(of: $0, in: table) }.filter { !$0.value.isEmpty }
    }

    /// foregroundJob returns one shell's foreground job, nil when the table cannot be read. A caller that
    /// must wait for the job to end cannot treat "unknown" as "none".
    func foregroundJob(of shell: pid_t) -> [ProcessRecord]? {
        table().map { ProcessSweep.foregroundJob(of: shell, in: $0) }
    }

    /// isRunning is whether any process of `job` still runs. An unreadable table counts as running: a
    /// caller waiting for the job to end must not take a failed read as its end.
    func isRunning(_ job: [ProcessRecord]) -> Bool {
        guard let table = table() else { return !job.isEmpty }
        return !ProcessSweep.survivors(of: job, in: table).isEmpty
    }

    func send(_ signal: Int32, to job: [ProcessRecord]) {
        guard let table = table() else { return }
        for record in ProcessSweep.survivors(of: job, in: table) { self.signal(signal, record.pid) }
    }
}
