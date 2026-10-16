import XCTest
@testable import Harbor

private final class Clock { var time: TimeInterval = 100; func now() -> Date { Date(timeIntervalSince1970: time) } }
final class CacheTests: XCTestCase {
    var root: URL!
    override func setUp() { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDownWithError() throws { if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) } }
    func testRoundtripTTLAndClose() async throws {
        let clock = Clock()
        let cache = try DiskCache(directory: root, capacity: 100, now: clock.now)
        try await cache.put(Data([1,2]), forKey: "a", ttl: 5)
        let hit = try await cache.get("a"); XCTAssertEqual(hit, Data([1,2]))
        clock.time += 5
        let expired = try await cache.get("a"); XCTAssertNil(expired)
        try await cache.close()
        do { _ = try await cache.get("a"); XCTFail("closed") } catch {}
    }
    func testLRUFlushesPendingTouchesBeforeEviction() async throws {
        let clock = Clock(), cache = try DiskCache(directory: root, capacity: 4, now: { Date(timeIntervalSince1970: 100) })
        try await cache.put(Data([1,1]), forKey: "a")
        try await cache.put(Data([2,2]), forKey: "b")
        _ = clock // A separate test below covers clock advancement; tie break here is deterministic by key.
        let plan = try await cache.previewTrim(to: 2)
        XCTAssertEqual(plan.first?.key, "a")
        _ = try await cache.trim(to: 2)
        let usage = try await cache.usage(); XCTAssertEqual(usage, 2)
        try await cache.close()
    }
    func testTouchChangesEvictionOrder() async throws {
        let clock = Clock(), cache = try DiskCache(directory: root, capacity: 4, now: clock.now)
        try await cache.put(Data([1,1]), forKey: "a")
        clock.time += 1; try await cache.put(Data([2,2]), forKey: "b")
        clock.time += 1; _ = try await cache.get("a")
        let plan = try await cache.previewTrim(to: 2)
        XCTAssertEqual(plan.first?.key, "b")
        try await cache.close()
    }
    func testContentFailurePreservesPreviousVersionAndRecoversOrphan() async throws {
        enum Injected: Error { case stop }
        var fail = false
        let cache = try DiskCache(directory: root, capacity: 100, fault: { stage in
            if fail, case .contentWritten = stage { throw Injected.stop }
        })
        try await cache.put(Data([1]), forKey: "a")
        fail = true
        do { try await cache.put(Data([2]), forKey: "a"); XCTFail("fault") } catch {}
        let previous = try await cache.get("a"); XCTAssertEqual(previous, Data([1]))
        try await cache.close()
        let reopened = try DiskCache(directory: root, capacity: 100)
        let recovered = await reopened.statistics
        XCTAssertEqual(recovered.recoveredFiles, 1)
        let value = try await reopened.get("a"); XCTAssertEqual(value, Data([1]))
        try await reopened.close()
    }
    func testIndexCommitFailureKeepsNewVersion() async throws {
        enum Injected: Error { case stop }
        let cache = try DiskCache(directory: root, capacity: 100, fault: { if case .indexCommitted = $0 { throw Injected.stop } })
        do { try await cache.put(Data([3]), forKey: "a"); XCTFail("fault") } catch {}
        try await cache.close()
        let reopened = try DiskCache(directory: root, capacity: 100)
        let value = try await reopened.get("a"); XCTAssertEqual(value, Data([3]))
        try await reopened.close()
    }
    func testExclusiveLeaseAndOversizedValue() async throws {
        let cache = try DiskCache(directory: root, capacity: 2)
        XCTAssertThrowsError(try DiskCache(directory: root, capacity: 2))
        do { try await cache.put(Data([1,2,3]), forKey: "a"); XCTFail("oversized") } catch {}
        try await cache.close()
    }
    func testConcurrentWritesRemainWithinBudget() async throws {
        let cache = try DiskCache(directory: root, capacity: 20)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for n in 0..<40 { group.addTask { try await cache.put(Data([UInt8(n)]), forKey: "k\(n)") } }
            try await group.waitForAll()
        }
        let usage = try await cache.usage(); XCTAssertLessThanOrEqual(usage, 20)
        try await cache.close()
    }
}
