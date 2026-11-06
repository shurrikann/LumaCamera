# 2026-10-24 冷启动恢复手动参数：生命周期隔离与定向验证

## 原问题及判断

原全量 FULL-20261024-001 等待相机就绪失败；期间旧可见引擎收到一次非注入 AVFoundation -11819（媒体服务重置）。旧日志打印的是该引擎最近操作与通知到达后的状态，无法证明哪一项配置触发了 Apple 内部服务重置。

本轮先未改代码复测原方法：单项通过（3.519 秒），再按设置持久化→冷启动顺序执行，亦通过。未复现生产功能中的冷启动参数丢失或真实服务重置，不将后续测试通过写成平台内部故障已根治。

## 确认并修正的测试边界

- `CameraViewModel.setCameraActive` 为避免 SwiftUI 更新期间发布状态，先异步派发主队列，再提交相机队列。旧用例调用它后直接等待 `afterPendingSessionTasks`，后者只覆盖已经提交的引擎工作，不能作为整个模型退出的完成信号。
- 原用例的每轮新模型没有异常收尾；`XCTUnwrap` 等抛错后可能跳过停机，影响后续硬件项目。
- `CaptureStatePhysicalTests.stopAndWait` 现在依次等待主队列生命周期提交、相机队列完成，并读取真实 `session.isRunning == false`；每轮正常和抛错都执行停机。测试使用临时独立 UserDefaults，不改变用户保存设置。
- 增加三轮照片/视频共六次新模型启动，实际核对 ISO、快门、设备曝光/白平衡/对焦模式及焦点位置；照片核对原保存焦段和 5× 倍率，视频实际录制三个 HEVC/P3 1080p30 临时片段并读取音视频轨。
- 增加三组冷启动快速取消/返回，每组 21 次生命周期请求（10 次开/关后最终打开）；模型会合并同一主队列回合的旧请求，不将其记成 63 次硬件启动。最终停机后再等 300ms，核对没有迟到重启。
- 正常恢复方法全程 `SessionRuntimeErrorAudit` 监听本进程所有会话；即使自动恢复成功，只要有真实错误通知也判失败。生产参数恢复、自动切镜和界面没有修改。

## 官方依据与应用边界

Apple 明确说明 [startRunning](https://developer.apple.com/documentation/avfoundation/avcapturesession/startrunning()) 和 [stopRunning](https://developer.apple.com/documentation/avfoundation/avcapturesession/stoprunning()) 为同步方法，启动失败通过运行错误通知报告。这里的同步保证限于实际执行这些方法；不意味着派发之前的 `setCameraActive(false)` 已完成。主队列→会话队列的等待是本项目测试生命周期策略，Apple 没有保证 -11819 绝不发生，也没有承诺固定启动耗时。

## 真机结果

设备 iPhone 17 Pro / iOS 27.0.1（24A446），正常项目签名，无镜像、无模拟器、不写系统相册；临时视频在测试后删除。

- 修正后设置与硬件组：8 项通过、0 失败、0 跳过，17.037 秒。6 项持久化测试，2 项真实硬件方法（6 次常规恢复、3 次快速请求后恢复）。正常操作未出现带错误对象的 AVFoundation 运行错误。
- 照片恢复可用且硬件参数匹配，3 次中位 1.554 秒，范围 1.549–1.581 秒；视频 3 次中位 0.723 秒，范围 0.718–0.723 秒。快速请求后的 3 次恢复 0.705–0.724 秒。
- ISO 目标 200，硬件读数照片约 200.074、视频约 199.716；快门目标 1/125 秒，实际约 0.007995/0.007997 秒；6 次设备曝光为 custom、白平衡与对焦为 locked，焦点位置在目标 0.7 ±0.03 内。
- 恢复补查：2 项通过、0 失败、0 跳过，8.363 秒。明确注入四次公开运行错误（两次 unknown、两次 mediaServicesWereReset）检查新帧恢复，中位 0.108 秒、最大 0.413 秒；另一次注入后立即退出，确认不重启。另一方法连续四次会话停机/恢复，核对真实 ISO 400 与 1/125 秒。注入验证不是复现 Apple 内部服务崩溃。
- 本轮最终共 10 个相关方法通过，原 FULL-20261024-001 定向通过；累计 11 个原失败方法有通过记录，其余 22 项未处理/未复测。原始全量 489/33/7 统计不改写。

指标为模型启动请求到相机 ready 且硬件参数匹配的轮询耗时（20ms 间隔），是同一测试进程中新建模型/会话，不是 9 次操作系统进程冷启动；不是屏幕帧率、功耗或独立 App 内存。原服务重置内部原因仍未确认，既有 MDB_MAP_FULL 缓存日志仍存在，未纳入本项修复。未改视频/照片其他规格，也不据此关闭其他失败项。

## 结果文件

- `/private/tmp/LumaCamera-ColdRestore-20261024-Baseline.xcresult`：原用例基线。
- `/private/tmp/LumaCamera-ColdRestore-20261024-Sequence.xcresult`：原有设置持久化及冷启动顺序基线。
- `/private/tmp/LumaCamera-ColdRestore-20261024-Verified.xcresult`：修正后 8 项。
- `/private/tmp/LumaCamera-ColdRestore-20261024-Recovery.xcresult`：恢复补查 2 项。
- 同前缀 `.log` 含原始指标；临时目录不保证永久保留。结构化摘要见 `2026-10-24-ColdRestore-Resolution-results.json`。
