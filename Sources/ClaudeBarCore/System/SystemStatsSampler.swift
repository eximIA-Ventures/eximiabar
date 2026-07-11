import Darwin
import Foundation

/// A point-in-time reading of the local machine's memory plus the Claude CLI footprint.
/// Value type so the popover section stays a pure function of one immutable sample.
public struct SystemStats: Sendable, Equatable {
    /// Percentage of physical RAM not claimed by active + wired + compressed pages (0–100).
    /// Deliberately ignores purgeable/file cache, which macOS reclaims on demand — matching the
    /// "free percentage" mental model of `memory_pressure` rather than Activity Monitor's "used".
    public let memoryFreePercent: Double
    /// Total physical RAM (`hw.memsize`).
    public let memoryTotalBytes: UInt64
    /// Summed resident size of every process named exactly `claude` (the CLI sessions).
    public let claudeResidentBytes: UInt64
    /// Number of processes named exactly `claude`.
    public let claudeSessionCount: Int
    public let sampledAt: Date

    public init(
        memoryFreePercent: Double,
        memoryTotalBytes: UInt64,
        claudeResidentBytes: UInt64,
        claudeSessionCount: Int,
        sampledAt: Date)
    {
        self.memoryFreePercent = memoryFreePercent
        self.memoryTotalBytes = memoryTotalBytes
        self.claudeResidentBytes = claudeResidentBytes
        self.claudeSessionCount = claudeSessionCount
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
        let claude = Self.claudeSample()
        return SystemStats(
            memoryFreePercent: memory.freePercent,
            memoryTotalBytes: memory.totalBytes,
            claudeResidentBytes: claude.residentBytes,
            claudeSessionCount: claude.sessionCount,
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

    private static func claudeSample() -> (residentBytes: UInt64, sessionCount: Int) {
        let declaredCount = proc_listallpids(nil, 0)
        guard declaredCount > 0 else { return (0, 0) }

        // Over-allocate: processes can spawn between the count call and the fill call.
        var pids = [pid_t](repeating: 0, count: Int(declaredCount) * 2)
        let filledCount = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.size))
        }
        guard filledCount > 0 else { return (0, 0) }

        var residentBytes: UInt64 = 0
        var sessionCount = 0
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
            sessionCount += 1

            var taskInfo = proc_taskinfo()
            let infoSize = Int32(MemoryLayout<proc_taskinfo>.size)
            let read = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, infoSize)
            if read == infoSize {
                residentBytes += taskInfo.pti_resident_size
            }
        }
        return (residentBytes, sessionCount)
    }
}
