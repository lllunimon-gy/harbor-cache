import Foundation
import HarborObjC

public enum CacheError: Error {
    case invalidConfiguration, directoryInUse, unsafeDirectory, invalidKey, oversizedEntry
    case database(String), invalidIndex, closed
}
public enum CacheWriteStage { case contentWritten, indexCommitted }
public struct CacheStatistics {
    public internal(set) var hits = 0
    public internal(set) var misses = 0
    public internal(set) var evictions = 0
    public internal(set) var recoveredFiles = 0
    public internal(set) var recoveredEntries = 0
    public internal(set) var bytesRead: Int64 = 0
    public internal(set) var bytesWritten: Int64 = 0
}
public struct EvictionCandidate {
    public let key: String
    public let bytes: Int64
    public let reason: String
}
public struct TrimResult {
    public let removedEntries: Int
    public let removedLogicalBytes: Int64
    public let fileDeletionFailures: [String]
}
private final class DirectoryLease {
    var fd: Int32
    init(_ root: URL) throws {
        fd = root.appendingPathComponent(".harbor.lock").path.withCString { HBLockDirectory($0) }
        if fd < 0 { throw CacheError.directoryInUse }
    }
    deinit { HBUnlockDirectory(fd) }
}

/// Actor isolation serializes index and content mutations; use a dedicated directory per namespace.
public actor DiskCache {
    private let root: URL
    private let content: URL
    private var lease: DirectoryLease?
    private var index: Index?
    private let budget: Int64
    private let now: () -> Date
    private let fault: ((CacheWriteStage) throws -> Void)?
    private var touches: [String: Double] = [:]
    public private(set) var statistics = CacheStatistics()

    public init(directory: URL, capacity: Int64, now: @escaping () -> Date = Date.init,
                fault: ((CacheWriteStage) throws -> Void)? = nil) throws {
        guard capacity > 0 else { throw CacheError.invalidConfiguration }
        let fm = FileManager.default
        let root = directory.standardizedFileURL
        if (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw CacheError.unsafeDirectory }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let lease = try DirectoryLease(root)
        let content = root.appendingPathComponent("content", isDirectory: true)
        if (try? content.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw CacheError.unsafeDirectory }
        try fm.createDirectory(at: content, withIntermediateDirectories: true)
        for name in ["index.sqlite", "index.sqlite-wal", "index.sqlite-shm"] {
            if (try? root.appendingPathComponent(name).resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw CacheError.unsafeDirectory
            }
        }
        let index = try Index(url: root.appendingPathComponent("index.sqlite"))
        var recovered = CacheStatistics()
        for entry in try index.all() {
            guard Self.validFileName(entry.file) else { throw CacheError.invalidIndex }
            let file = content.appendingPathComponent(entry.file)
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            if values?.isRegularFile != true || values?.isSymbolicLink == true || Int64(values?.fileSize ?? -1) != entry.bytes {
                try index.remove(entry.key); recovered.recoveredEntries += 1
            }
        }
        let referenced = Set(try index.all().map(\.file))
        for file in try fm.contentsOfDirectory(at: content, includingPropertiesForKeys: nil) {
            let name = file.lastPathComponent
            if Self.validFileName(name), !referenced.contains(name) {
                try fm.removeItem(at: file); recovered.recoveredFiles += 1
            } else if file.pathExtension == "tmp", UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil {
                try fm.removeItem(at: file); recovered.recoveredFiles += 1
            }
        }
        self.root = root; self.content = content; self.lease = lease; self.index = index
        self.budget = capacity; self.now = now; self.fault = fault; self.statistics = recovered
    }

    private static func validFileName(_ name: String) -> Bool {
        name.hasSuffix(".blob") && UUID(uuidString: String(name.dropLast(5))) != nil && !name.contains("/")
    }
    private func db() throws -> Index { guard let index else { throw CacheError.closed }; return index }
    private func validate(_ key: String) throws {
        guard !key.isEmpty, key.utf8.count <= 1024, !key.utf8.contains(0) else { throw CacheError.invalidKey }
    }
    public func put(_ data: Data, forKey key: String, ttl: TimeInterval? = nil) throws {
        try validate(key)
        guard Int64(data.count) <= budget else { throw CacheError.oversizedEntry }
        if let ttl, !ttl.isFinite || ttl <= 0 { throw CacheError.invalidConfiguration }
        let index = try db()
        let old = try index.all().first { $0.key == key }
        let name = UUID().uuidString
        let temporary = content.appendingPathComponent(name + ".tmp")
        let destination = content.appendingPathComponent(name + ".blob")
        try data.write(to: temporary, options: .withoutOverwriting)
        try FileManager.default.moveItem(at: temporary, to: destination)
        try fault?(.contentWritten)
        let time = now().timeIntervalSince1970
        try index.upsert(Entry(key: key, file: destination.lastPathComponent, bytes: Int64(data.count),
                               expires: ttl.map { time + $0 }, accessed: time))
        touches[key] = nil
        statistics.bytesWritten += Int64(data.count)
        try fault?(.indexCommitted)
        if let old { try? FileManager.default.removeItem(at: content.appendingPathComponent(old.file)) }
        _ = try trim(to: budget)
    }
    public func get(_ key: String) throws -> Data? {
        try validate(key)
        let index = try db()
        guard let entry = try index.all().first(where: { $0.key == key }) else { statistics.misses += 1; return nil }
        if let expires = entry.expires, expires <= now().timeIntervalSince1970 {
            try remove(key); statistics.misses += 1; return nil
        }
        let file = content.appendingPathComponent(entry.file)
        let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
            try remove(key); statistics.misses += 1; return nil
        }
        let data = try Data(contentsOf: file)
        guard Int64(data.count) == entry.bytes else { try remove(key); statistics.misses += 1; return nil }
        touches[key] = now().timeIntervalSince1970
        if touches.count >= 64 { try flushAccessTimes() }
        statistics.hits += 1; statistics.bytesRead += Int64(data.count)
        return data
    }
    public func remove(_ key: String) throws {
        let index = try db()
        guard let entry = try index.all().first(where: { $0.key == key }) else { return }
        try index.remove(key); touches[key] = nil
        // Index removal first. Failure leaves an orphan that startup recovery can collect.
        let file = content.appendingPathComponent(entry.file)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
    public func flushAccessTimes() throws { try db().touch(touches); touches.removeAll() }
    public func previewTrim(to target: Int64) throws -> [EvictionCandidate] {
        guard target >= 0 else { throw CacheError.invalidConfiguration }
        try flushAccessTimes()
        let entries = try db().all()
        var total = entries.reduce(Int64(0)) { $0 + $1.bytes }
        let time = now().timeIntervalSince1970
        var selected: [EvictionCandidate] = []
        var keys: Set<String> = []
        for e in entries where e.expires.map({ $0 <= time }) == true {
            selected.append(EvictionCandidate(key: e.key, bytes: e.bytes, reason: "expired"))
            keys.insert(e.key); total -= e.bytes
        }
        for e in entries where !keys.contains(e.key) && total > target {
            selected.append(EvictionCandidate(key: e.key, bytes: e.bytes, reason: "capacity")); total -= e.bytes
        }
        return selected
    }
    /// Recomputes candidates; a preview isn't a permanent deletion authorization.
    public func trim(to target: Int64) throws -> TrimResult {
        let candidates = try previewTrim(to: target)
        var failures: [String] = []
        var removed = 0
        var bytes: Int64 = 0
        for item in candidates {
            let index = try db()
            guard let entry = try index.all().first(where: { $0.key == item.key }) else { continue }
            try index.remove(entry.key); touches[entry.key] = nil
            do { try FileManager.default.removeItem(at: content.appendingPathComponent(entry.file)) }
            catch { failures.append(entry.file) }
            removed += 1; bytes += entry.bytes; statistics.evictions += 1
        }
        return TrimResult(removedEntries: removed, removedLogicalBytes: bytes, fileDeletionFailures: failures)
    }
    public func usage() throws -> Int64 { try db().all().reduce(0) { $0 + $1.bytes } }
    public func close() throws {
        guard index != nil else { return }
        try flushAccessTimes(); index = nil; lease = nil
    }
}
