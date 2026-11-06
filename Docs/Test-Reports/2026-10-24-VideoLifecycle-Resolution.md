# 2026-10-24 录像生命周期、计时与取消收尾

对应原全量失败 **FULL-20261024-032**。原失败是录制启动/恢复没有返回视频文件。本次独立基线已通过，增强重复生命周期检查也通过；不把这些结果当作已经确认历史系统内部故障原因。另发现并修复白平衡锁定等待期间取消会漏回调、残留忙碌状态的真实边界问题。

## 修复

- 原来白平衡锁定只有 pending 布尔值，取消时依赖之后的硬件回调恢复。新用例在真机复现：等待8秒仍无完成回调，`videoBusy` 未清除。
- 等待状态改用请求 UUID。停止时主动清除令牌、释放该请求的安全作用域、恢复录制前白平衡，然后交付一次 `CancellationError`，不再等待设备回调。
- 迟到的白平衡回调必须匹配原令牌，不能创建旧写入器、恢复下一请求的白平衡或清掉新请求状态。重复停止在录制队列发现没有写入器时，还会检查是否已经有新录制令牌，避免清掉新请求的忙碌状态。
- 普通已开始录像仍沿用录制专用队列结束写入，计时在停止请求时冻结。未修改 UI、按钮布局、镜头选择或影片编码设置。

苹果官方说明：[`setWhiteBalanceModeLocked`](https://developer.apple.com/documentation/avfoundation/avcapturedevice/setwhitebalancemodelocked(with:completionhandler:)) 的回调表示锁定完成；应用的取消收尾策略由本项目实现，不是系统自动取消该调整的保证。[`finishWriting`](https://developer.apple.com/documentation/avfoundation/avassetwriter/finishwriting(completionhandler:)) 必须在 append 返回后调用，并在结束回调查询写入状态。现有串行录制队列继续遵循这一要求。

## 真机记录

设备：iPhone 17 Pro / iOS27.0.1，普通项目签名。只在真机运行相关测试，无镜像、无模拟器，未向系统相册保存诊断视频。

| 运行 | 结果 |
| --- | --- |
| Baseline | 原032方法通过，4.754秒；100请求1次重配，停止后计时增量0 |
| Verified | 新增强测试编译失败：异步读取放入 XCTest 自动闭包；已拆开读取与断言，没有开始硬件测试 |
| Enhanced | 增强032方法通过，17.317秒，三轮退出/恢复与文件完整解码 |
| WBCancelBaseline | 新取消用例失败，10.148秒；等待结束回调的8秒期限内0回调、busy未释放 |
| Fixed | 取消防护初版与增强032均通过；保留中间结果 |
| Final | **2方法通过，20.211秒**；包含白平衡恢复、取消后实际新片与重复停止隔离 |
| Resource | **3方法通过，2.774秒**；最终安全收尾版本再测白平衡取消，另查资源只释放一次及创建失败释放 |

修复后共 **4个不同相关方法有通过记录**：

- `VideoWorkflowTests/testLifecycleStopFreezesClockAndRapidModeRequestsCoalesce`：17.476秒。
- `VideoWorkflowTests/testImmediateCancelDuringWhiteBalanceStartupCompletesExactlyOnce`：Final 2.734秒；最终 Resource 2.772秒。
- `VideoEncodingPolicyTests/testExternalRecordingAccessCanBeReleasedAtWriterCompletionAndOnlyOnce`：0.001秒。
- `VideoEncodingPolicyTests/testExternalRecordingAccessReleasesScopeWhenRecorderSetupFails`：0.001秒。

### 重复与取消覆盖

增强032检查三轮（A/M/A）正常录像→生命周期退出→恢复新帧→立即取消；每轮包括100个积压模式请求、重复停止、延迟检查回调没有重复，以及实际 `session.isRunning == false`。共3段正常文件，每段16帧、1920×1080、约0.533秒，全部完整解码且PTS递增；3次立即取消均完成，共6个结果回调。停止后观察650毫秒，三轮计时增量均0。

白平衡新用例连取消3次，检查恰好3次回调、busy/recording归零、计时为0、设备白平衡模式恢复；随后再真实录制并停止，文件完整解码12帧，总计4次回调。额外等待500毫秒未重复交付。Resource再测同一路径通过。该检查不是031白平衡规格矩阵的完整验收，031继续待办。

### 可重复指标

Final增强032：

- 100请求积压至最终配置完成，每轮重配1次，耗时2.636、2.733、3.397秒。此指标含人为阻塞队列与100次模型调用，不代表用户单次切换延迟。
- 停止请求至文件回调：3样本34.99、45.66、33.85毫秒；短视频场景，不能外推到长片/高码率。
- 生命周期恢复请求至新预览帧：3样本300.77、257.06、305.45毫秒；通过应用入口测试，不是操作系统进程冷启动或显示FPS。
- 白平衡等待取消至完成：Final 3样本21.56、21.20、24.30毫秒；Resource 3样本21.62、21.57、21.12毫秒。200毫秒静默检查不计入这个时间。

## 限制与剩余项

本轮调用与 scenePhase/离开相机相同的 `setCameraActive(false/true)` 入口，读取真实相机会话和媒体文件；没有用 Home/锁屏实际驱动系统后台、来电中断，也没有后台保活验收。不做独立App功耗、内存或显示帧率结论。安全作用域检查是可重复释放单元测试，不代表外接 RAW 实盘验证。

审计未收到携带 error 对象的相机会话运行错误通知；日志仍有 MDB_MAP_FULL 等平台输出及同帧大量请求造成的 SwiftUI onChange/Geometry 循环警告，不声明底层零警告。

原全量529/489/33/7及原始断言保留。此项定向关闭后，累计26个原失败方法有通过记录，余7项待处理/未复测（017、026–031）。

证据：`/private/tmp/LumaCamera-VideoLifecycle-20261024-{Baseline,Verified,Enhanced,WBCancelBaseline,Fixed,Final,Resource}.xcresult` 及对应日志；普通App构建日志 `/private/tmp/LumaCamera-VideoLifecycle-20261024-FinalApp.log`。
