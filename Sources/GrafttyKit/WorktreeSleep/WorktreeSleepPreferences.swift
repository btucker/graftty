import Darwin
import Foundation

public enum WorktreeSleepPreferences {
    public static let enabledKey = "worktreeAutoSleep"
    public static let minutesKey = "worktreeAutoSleepMinutes"
    public static let keepAwakeKey = "worktreeKeepAwakePaths"

    public static func duration(defaults: UserDefaults = .standard) -> TimeInterval {
        let value = defaults.double(forKey: minutesKey)
        let minutes = value.isFinite && value >= 1 ? min(value, 1440) : 15
        return minutes * 60
    }

    public static func keepsAwake(_ path: String, defaults: UserDefaults = .standard) -> Bool {
        (defaults.stringArray(forKey: keepAwakeKey) ?? []).contains(path)
    }

    public static func setKeepsAwake(_ enabled: Bool, path: String, defaults: UserDefaults = .standard) {
        var paths = Set(defaults.stringArray(forKey: keepAwakeKey) ?? [])
        if enabled { paths.insert(path) } else { paths.remove(path) }
        defaults.set(paths.sorted(), forKey: keepAwakeKey)
    }
}

/// Registration survives daemonization and expires on exact task exit or
/// PID reuse. Root identity binds it to the pane that verified the task.
public struct SleepKeepAwakeRegistration: Codable {
    public let path: String
    public let root: SleepProcessIdentity
    public let task: SleepProcessIdentity
    public init(path: String, root: SleepProcessIdentity, task: SleepProcessIdentity) {
        self.path = path; self.root = root; self.task = task
    }

    public func blocksSleep(path: String, startTime: (Int32) -> Int64?) -> Bool {
        guard self.path == path else { return false }
        guard let start = startTime(task.pid) else { return true }
        return start == task.startTime
    }

    public static let directory = AppState.defaultDirectory.appendingPathComponent("sleep-keep-awake")

    public static func hasLiveRegistration(path: String) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return false }
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return true }
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let record = try? JSONDecoder().decode(Self.self, from: data) else { return true }
            if kill(record.task.pid, 0) == -1 && errno == ESRCH {
                try? fm.removeItem(at: file)
                continue
            }
            if let start = ProcessIdentityReader.startTimeMicroseconds(ofPID: record.task.pid), start != record.task.startTime {
                try? fm.removeItem(at: file)
                continue
            }
            if record.blocksSleep(path: path, startTime: ProcessIdentityReader.startTimeMicroseconds) { return true }
        }
        return false
    }

    public func save() throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let file = Self.directory.appendingPathComponent(UUID().uuidString + ".json")
        try JSONEncoder().encode(self).write(to: file, options: .atomic)
    }
}
