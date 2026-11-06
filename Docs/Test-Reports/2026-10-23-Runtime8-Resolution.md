# 2026-10-23 八条相机会话错误定向处理

设备：iPhone 17 Pro，iOS 27.0.1（24A446），正常项目签名；单真机串行，不使用镜像或模拟器，不向系统相册保存诊断媒体。本记录对应全量测试的八条日志，不等同于八个独立产品故障。

## 定位及修改

1. 原七个相关方法定向基线：6 通过、1 失败，3 条真实会话错误。前后切换、照片/视频跨挡切换均再次产生 -11800 / -12780；前置广角测试另产生 -11800 / -12785 并切换失败。
2. 额外的前后切换诊断再次复现 -12780。有界配置历史显示，A 挡视频虚拟三摄转 M 挡物理主摄时，旧实现先提交输入替换，随后才调用目标格式/输出配置；到后者进入时 session 已停止。修复普通视频的中间提交后，同一用例不再出现错误，证据支持此配置顺序是本次可复现分支的触发因素；没有公开文档把私有 OSStatus -12780 唯一对应到这一原因。
3. `applyContinuousZoom` 的视频输入替换统一保留外层事务，直到目标格式、输出、倍率准备完毕才提交；固定焦段视频切换也统一采用完整事务。保留原有过渡动画、自动微距 .auto、音频与编码逻辑。
4. 前置广角测试不再创建第二个 `CameraViewModel`/相机会话，改用唯一可见引擎的 fixture，避免测试自己争用硬件。首轮修复验证发现白平衡测试假定上一项留下后置；现在显式选择后置 1×，再测试过期手动白平衡事件到达虚拟路由，不删除断言。
5. 七个原始相关用例新增 `SessionRuntimeErrorAudit`，监听本进程所有会话的带 error key 通知；即使自动恢复后功能断言通过，真实运行错误也会使该用例失败。无 error key 的既有通知注入不计为真实错误。
6. DEBUG 保留最多 32 条配置历史，错误时按条输出引擎标识与模式/输入/格式，避免单条长日志截断；不是逐帧日志。另为恢复注入辅助方法增加可选 NSError，测试真实通知分支，不改变生产恢复策略。

## 八条逐项对照

以下“通过”指修复后原方法的定向运行与真实错误审计通过，不能回溯证明每一条历史日志都由同一原因产生。

| 原时间 | 相关方法 | 最新处理与证据 |
|---|---|---|
| 17:43:33 | CameraControlMenuTests/testPhysicalMenusAndManualBindingsWithoutSavingPhotos | 通过，无真实会话错误；本次基线未复现该条，历史单条根因未独立确认。 |
| 17:44:08 | CameraFacingLatencyPhysicalTests/testPhotoAndVideoFacingDirectionLatency | 本次两轮复现配置错误；视频完整事务修复后通过，24 次前后切换无真实错误。 |
| 17:44:59 | CaptureKindModeLatencyPhysicalTests/testCrossModePhotoVideoLatencyAndRestoration | 本次基线复现配置错误；修复后 48 次跨模式/挡位切换通过，无真实错误。 |
| 17:49:04.280033 | FrontWideSelectionTests/testFrontWideSwitchDoesNotCrashAndTogglesBack | 改为单一可见引擎后通过；本次基线观察到竞争相关 -12785 和切换失败，不能据此把历史 -12780 私有码作唯一归因。 |
| 17:49:04.280318 | 同上 | 与上一条相隔约 0.3 ms，保留原始两条，不冒充两个独立故障；同一方法最新审计通过。 |
| 18:01:14 | VideoColorPhysicalTests/testEveryAvailableColorSpaceRecordsRealTagsAndRestoresPhotos | 色彩空间录制及照片恢复通过，无真实错误。历史 -11819 是公开的 mediaServicesWereReset；本次没有真实重现系统服务重置，其内部根因无法由旧日志确定。已补通知恢复与退出验证。 |
| 18:05:11 | WhiteBalanceRouteSafetyTests/testStaleCustomWhiteBalanceDuringRouteChangesDoesNotCrashVirtualCamera | 显式后置 1× 后通过，3 轮过期手动 WB 路由事件被正确处理，无真实错误；历史该条未独立复现。 |
| 18:05:15 | ZoomWheelReopenPhysicalTests/testReopeningKeepsActualZoomAndAnchorAcrossBothModes | A/M 变焦轮关闭重开通过，倍率/锚点保持，无真实错误；历史该条未独立复现。 |

## 结果包与性能稳定性

- `/private/tmp/LumaCamera-Runtime8-Baseline2.xcresult` / `.log`：7 项，6 通过、1 失败；3 条真实运行错误。第一次尝试 Baseline 因正常构建移除了测试插件而未执行用例，不计入该结果。
- `/private/tmp/LumaCamera-Runtime8-Trace2.xcresult` / `.log`：前后切镜方法功能断言通过，但仍有 1 条真实运行错误，证明原“测试通过”不足以验收。
- `/private/tmp/LumaCamera-Runtime8-Atomic.xcresult` / `.log`：7 项，6 通过、1 失败；0 条真实运行错误。失败是白平衡测试未建立后置路线前提，随后修正。
- `/private/tmp/LumaCamera-Runtime8-Final.xcresult` / `.log`：**10 项全部通过，121.312 秒；0 条非注入会话错误**。其中原七方法均有通知审计，另外包括快速跨模式/退出恢复、迟到通知启动竞争、带 error key 的错误恢复。
- 最终前后切镜 24 次：至目标路由新帧标记 P50 **0.497 秒**，最大 **0.866 秒**；基线 P50 0.495、最大 1.010 秒。最终跨模式 48 次：P50 **0.480 秒**，最大 **0.637 秒**；基线 P50 0.488、最大 1.093 秒。前后运行场景/负载不完全一致，不能据此宣称统计显著的速度提升；这些不是屏幕 FPS 或触屏响应时间。
- 快速操作用例包含 4 轮、每轮 5 次视频→挡位→照片操作，隔轮退出再回来，最终保持可用。前置宽窄、硬件参数菜单、白平衡、变焦轮、SDR/P3/HDR/可用 Log 文件标记均按原用例检查。
- 错误恢复用例主动停止会话，再注入 -11800（带底层 -12780）与 -11819，各 2 次；4 次恢复均获得新预览帧，P50 **0.109 秒**、最大 **0.386 秒**。另注入一次 -11819 后退出，0.5 秒后实际 session 未运行。共 **5 条预期注入日志**，与真实错误区分计数。通知注入不等于实际让系统媒体服务崩溃；未测真实服务重置时的全部系统状态。
- 正常版构建日志 `/private/tmp/LumaCamera-Runtime8-FinalApp.log`。测试目标仍有既有诊断并发/未使用变量警告，本次未扩展修复范围。系统 MDB_MAP_FULL 和 Fig 私有断言仍有出现，不把它们直接当作相机会话错误或已知根因。未做长录、功耗/温升、外接盘测试，也未重跑 494 项全量。

## 官方依据与结论

- Apple [beginConfiguration](https://developer.apple.com/documentation/avfoundation/avcapturesession/beginconfiguration()) 说明输入、输出和设备属性可批量原子提交，嵌套事务以最外层 commit 生效；此次修复遵循该方式。
- [runtimeErrorNotification](https://developer.apple.com/documentation/avfoundation/avcapturesession/runtimeerrornotification) 要求从 AVCaptureSessionErrorKey 取得错误；审计及诊断保留底层信息。
- [mediaServicesWereReset](https://developer.apple.com/documentation/avfoundation/averror-swift.struct/mediaserviceswerereset) 表示媒体服务不可用；不能通过压制日志或将其改名为镜头不支持来处理。

本次可复现的配置提交错误和测试争用已处理，原八条记录对应方法全部定向验收通过。历史每条日志的内部因果并未全部重演，尤其不能保证系统未来不会重置媒体服务；后续如再次出现，用引擎标识、配置历史及明确失败的测试继续定位，不再以自动恢复掩盖错误。
