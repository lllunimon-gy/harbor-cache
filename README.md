# Harbor

一个有容量预算的磁盘缓存。内容存文件，索引存 SQLite；恢复逻辑明确处理两者无法原子提交的问题。
作者 **gy** · MIT · iOS 15+ / macOS 12+ · Swift actor + Objective-C 文件锁 + SQLite。

## 使用

Mac 上 `swift test`，Xcode 打开 `Examples/HarborExample.xcodeproj`。
示例可以写入、读取、预览清理、执行清理并展示命中与占用。

```swift
let cache = try DiskCache(directory: cacheURL, capacity: 32 * 1024 * 1024)
try await cache.put(data, forKey: "feed", ttl: 3600)
let cached = try await cache.get("feed")
let plan = try await cache.previewTrim(to: 8 * 1024 * 1024)
let result = try await cache.trim(to: 8 * 1024 * 1024)
try await cache.close()
```

## 已实现

不可变内容文件、SQLite 索引、TTL、LRU、写入后容量收敛、清理预览、批量访问时间更新、
启动时孤儿文件与失效索引恢复、互斥目录租约、故障注入、统计计数。
预览在执行时重新计算，不能拿旧预览盲删。

## 边界

使用应用自有的独立目录；目录级隔离就是命名空间。容量按索引中的逻辑字节计，
不含数据库、WAL、临时内容和删除失败的孤儿文件，不承诺实际磁盘占用硬上限。
缓存允许丢失。普通文件写入没有抗断电承诺；数据库事务不能替内容文件作此保证。
缓存不提供加密、跨进程共享、后台任务续期或 stale-while-revalidate。

首版为可读性使用 `Index.all()` 查询；get 是 O(条目数)，不应未经优化用于十万级热缓存。
LRU 访问时间积累到 64 个不同 key、预览/清理或 close 时持久化；崩溃可能丢掉最近的访问排序。
缓存目录应排除备份；示例放在 Library/Caches。文件保护策略由集成方按业务配置并做真机验证。

[一致性设计](Documentation/design.md) · [故障实验](Documentation/experiments.md) · [验证](Documentation/validation.md)
