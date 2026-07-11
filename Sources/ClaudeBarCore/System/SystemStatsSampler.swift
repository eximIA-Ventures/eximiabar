import Darwin
import Foundation

/// One live Claude CLI process: identity, where it runs, and what it costs.
public struct ClaudeSessionInfo: Sendable, Equatable, Identifiable {
    public var id: Int32 { self.pid }
    public let pid: Int32
    /// The process's current working directory — the repo/folder the session runs in.
    /// Empty when the vnode info could not be read.
    public let workingDirectory: String
    public let residentBytes: UInt64
    /// Total user+system CPU time in **nanoseconds** (converted from Mach time units).
    /// Only deltas between samples are meaningful; used for idle detection.
    public let cpuTotalNanos: UInt64

    public init(pid: Int32, workingDirectory: String, residentBytes: UInt64, cpuTotalNanos: UInt64) {
        self.pid = pid
        self.workingDirectory = workingDirectory
        self.residentBytes = residentBytes
        self.cpuTotalNanos = cpuTotalNanos
    }
}

/// A point-in-time reading of the local machine's memory plus the Claude CLI footprint.
/// Value type so the popover section stays a pure function of one immutable sample.
public struct SystemStats: Sendable, Equatable {
    /// Percentage of physical RAM not claimed by active + wired + compressed pages (0–100).
    /// Deliberately ignores purgeable/file cache, which macOS reclaims on demand — matching the
    /// "free percentage" mental model of `memory_pressure` rather than Activity Monitor's "used".
    public let memoryFreePercent: Double
    /// Total physical RAM (`hw.memsize`).
    public let memoryTotalBytes: UInt64
    /// Every live Claude CLI session, sorted by resident size descending.
    public let sessions: [ClaudeSessionInfo]
    public let sampledAt: Date

    /// Summed resident size of every Claude CLI session.
    public var claudeResidentBytes: UInt64 { self.sessions.reduce(0) { $0 + $1.residentBytes } }
    /// Number of live Claude CLI sessions.
    public var claudeSessionCount: Int { self.sessions.count }

    public init(
        memoryFreePercent: Double,
        memoryTotalBytes: UInt64,
        sessions: [ClaudeSessionInfo],
        sampledAt: Date)
    {
        self.memoryFreePercent = memoryFreePercent
        self.memoryTotalBytes = memoryTotalBytes
        self.sessions = sessions
        self.sampledAt = sampledAt
    }
}

/// Samples memory + Claude process stats through Mach/libproc syscalls only — no `ps`/`top`
/// subprocess, no file I/O. A full sample is a few milliseconds; callers still run it off the
/// main thread (anti-freeze invariant) because `proc_listallpids` cost scales with process count.
public enum SystemStatsSampler {
    /// The process name that counts as a Claude CLI session.
    static let claudeProcessName = "claude"

    public static func sample(now: Date = Date()) -> SystemStats? {
        guard let memory = Self.memorySample() else { return nil }
        return SystemStats(
            memoryFreePercent: memory.freePercent,
            memoryTotalBytes: memory.totalBytes,
            sessions: Self.claudeSessions(),
            sampledAt: now)
    }

    // MARK: - Memory (Mach)

    private static func memorySample() -> (freePercent: Double, totalBytes: UInt64)? {
        var totalBytes: UInt64 = 0
        var totalSize = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &totalBytes, &totalSize, nil, 0) == 0, totalBytes > 0 else {
            return nil
        }

        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS, pageSize > 0 else {
            return nil
        }

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let usedPages = UInt64(stats.active_count)
            + UInt64(stats.wire_count)
            + UInt64(stats.compressor_page_count)
        let usedBytes = usedPages * UInt64(pageSize)
        let freePercent = 100 - (Double(usedBytes) / Double(totalBytes)) * 100
        return (min(100, max(0, freePercent)), totalBytes)
    }

    // MARK: - Claude processes (libproc)

    /// Whether an executable path/name belongs to a Claude CLI session. The CLI installs as a
    /// versioned binary (`~/.local/share/claude/versions/2.1.207`), so the *process name* is the
    /// version number — matching by name alone counts zero sessions. Path is the reliable signal;
    /// name is the fallback for processes whose path could not be read.
    static func isClaudeCLI(path: String, name: String) -> Bool {
        if path.isEmpty { return name == Self.claudeProcessName }
        if path.contains("/claude/versions/") { return true }
        return (path as NSString).lastPathComponent == Self.claudeProcessName
    }

    /// Mach time units → nanoseconds (`pti_total_user`/`pti_total_system` are Mach units on arm64).
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    private static func machToNanos(_ value: UInt64) -> UInt64 {
        guard Self.timebase.denom > 0 else { return value }
        return value * UInt64(Self.timebase.numer) / UInt64(Self.timebase.denom)
    }

    private static func claudeSessions() -> [ClaudeSessionInfo] {
        let declaredCount = proc_listallpids(nil, 0)
        guard declaredCount > 0 else { return [] }

        // Over-allocate: processes can spawn between the count call and the fill call.
        var pids = [pid_t](repeating: 0, count: Int(declaredCount) * 2)
        let filledCount = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.size))
        }
        guard filledCount > 0 else { return [] }

        var sessions: [ClaudeSessionInfo] = []
        var nameBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        for pid in pids.prefix(Int(filledCount)) where pid > 0 {
            nameBuffer[0] = 0
            pathBuffer[0] = 0
            _ = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
            _ = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            guard Self.isClaudeCLI(
                path: String(cString: pathBuffer),
                name: String(cString: nameBuffer)) else { continue }

            var residentBytes: UInt64 = 0
            var cpuNanos: UInt64 = 0
            var taskInfo = proc_taskinfo()
            let infoSize = Int32(MemoryLayout<proc_taskinfo>.size)
            if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, infoSize) == infoSize {
                residentBytes = taskInfo.pti_resident_size
                cpuNanos = Self.machToNanos(taskInfo.pti_total_user &+ taskInfo.pti_total_system)
            }

            sessions.append(ClaudeSessionInfo(
                pid: pid,
                workingDirectory: Self.workingDirectory(of: pid),
                residentBytes: residentBytes,
                cpuTotalNanos: cpuNanos))
        }
        return sessions.sorted { $0.residentBytes > $1.residentBytes }
    }

    private static func workingDirectory(of pid: pid_t) -> String {
        var vnodeInfo = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnodeInfo, size) == size else {
            return ""
        }
        return withUnsafePointer(to: &vnodeInfo.pvi_cdir.vip_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }
}
