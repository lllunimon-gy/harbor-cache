import SwiftUI
import Harbor

@main struct HarborExample: App { var body: some Scene { WindowGroup { ContentView() } } }
struct ContentView: View {
    @State private var cache: DiskCache?
    @State private var message = "正在打开缓存"
    @State private var serial = 0
    @State private var busy = false
    var body: some View {
        NavigationView { List {
            Text(message).textSelection(.enabled)
            Button("写入 64 KiB，TTL 30 秒") { action { cache in
                serial += 1
                try await cache.put(Data(repeating: UInt8(serial % 255), count: 65536), forKey: "item-\(serial)", ttl: 30)
                return "写入 item-\(serial)，当前 \(try await cache.usage()) B"
            }}
            Button("读取最新一项") { action { cache in
                let value = try await cache.get("item-\(serial)")
                return value.map { "命中 \($0.count) B" } ?? "未命中或已过期"
            }}
            Button("预览清理到 128 KiB") { action { cache in
                let plan = try await cache.previewTrim(to: 131072)
                return plan.map { "\($0.key)：\($0.reason)" }.joined(separator: "\n").isEmpty ? "无需清理" : plan.map { "\($0.key)：\($0.reason)" }.joined(separator: "\n")
            }}
            Button("执行清理到 128 KiB") { action { cache in
                let result = try await cache.trim(to: 131072)
                return "删除 \(result.removedEntries) 项，逻辑字节 \(result.removedLogicalBytes)，文件删除失败 \(result.fileDeletionFailures.count)"
            }}
        }.disabled(cache == nil || busy).navigationTitle("Harbor · gy") }
        .task {
            guard cache == nil else { return }
            let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("HarborExample")
            let result = await Task.detached { Result { try DiskCache(directory: root, capacity: 524288) } }.value
            switch result { case .success(let value): cache = value; message = "容量预算 512 KiB"
            case .failure(let error): message = String(describing: error) }
        }
    }
    private func action(_ body: @escaping (DiskCache) async throws -> String) {
        guard let cache else { return }; busy = true
        Task { do { message = try await body(cache) } catch { message = String(describing: error) }; busy = false }
    }
}
