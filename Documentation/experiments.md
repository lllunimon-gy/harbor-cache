# 恢复与容量实验

## 两个提交边界

运行 testContentFailurePreservesPreviousVersionAndRecoversOrphan：contentWritten 处抛错，
旧值应可读，重开后 recoveredFiles 增加。再运行 testIndexCommitFailureKeepsNewVersion：
indexCommitted 处抛错，重开后新值可读。解释为什么两次错误的结果不同。

这些是错误注入测试，不等于真实进程终止。真机或 macOS 宿主实验可以在相同位置设置断点，
从外部结束进程后重启，核对文件与索引。系统掉电仍是另一类实验。

## LRU 写放大

准备 100 个 key，按固定序列读取 1 万次。先测当前批量访问时间策略，再改为每次都 UPDATE。
记录总时长与数据库/WAL 写入变化。保持同步设置和输入一致，不能只比较 API 返回耗时。

## 失效预览

生成清理预览后，读取原本最旧的 key，再执行清理。最终淘汰应按新顺序重新计算。
练习：为预览增加生成时间与配置版本，但不要直接复用预览文件名删除。

## 低空间错误

在可控测试卷或注入文件写入器中制造 ENOSPC，验证旧缓存保持可读，错误能传到调用方。
首版未自动建立测试卷；禁止通过填满日常开发磁盘来测试。
