# 2026-10-28 真机全量测试

本次记录独立于 2026-10-24 和此前待办；只测试与记录，未修改生产代码或测试断言、未重跑失败项。

## 范围与结论

- 设备：iPhone 17 Pro，iOS 27.2（24B119），正常项目签名；单台有线真机串行，无手机镜像、无线配对或模拟器。
- 时间：2026-10-28 12:35:44–13:31:25，3340.31 秒（约 55.7 分钟）。
- **671 项：579 通过、78 失败、14 跳过；整体 Failed，退出码 65。**以测试方法计数，同一方法多个断言不重复计数。xcresult 与日志统计一致。
- 真机枚举 676 个方法，另有 5 个明确排除项，见文末；排除项不计入 14 个跳过。
- 生产代码、测试代码及项目构建配置的运行前后 SHA-256 对照无变化（哈希快照保存在本次临时结果目录）。本轮未修复、未复测，不能将 78 个失败解释为 78 个独立产品缺陷。
- 所有真正写入/删除系统相册的用例已排除；其余保存用例采用内存服务/临时结果回调。[相册副作用审计](2026-10-28-FullDevice-SafetyAudit.md)。诊断媒体仅在临时目录/xcresult，未加入用户系统相册。
- 测试结束后使用正常 bundle `com.shurrikann.LumaCamera` 重新启动成功；仅启动成功，不等于启动后预览与所有功能重新验收通过。

## 主要发现与后续优先顺序

1. **先定位相机会话/新帧停止及测试隔离问题。**前半段已有局部失败，后半段大量出现相机未就绪、没有新预览帧、相机已停止或“当前镜头无法启用慢动作/电影效果”。慢门序列 17 个方法均在诊断相机启动出帧前失败，未进入合成阶段；不能据此断言 17 种合成算法都错误。视频后半段同样无法完成实际录制或帧率验收。共享状态污染、硬件服务问题等尚未定位，不能作为已确定根因。
2. **布局与交互独立核对。**双拍小窗与声音/容量 HUD 重叠；入口按钮未取得布局框；智拍白点/圆圈渲染像素断言失败；退出微距后景深滑块未收起。这些需区分真实视觉回归和测试定位/快照前提。
3. **滤镜编辑压力。**2040 次参数修改，峰值超过当前用例的相对内存门限，见性能记录。单次超门限不能证明内存泄漏。
4. **独立参数/边界断言。**手动 ISO 扫描期间自动白平衡读数偏差；延时短片 3 帧/0.1 秒而用例要求至少 4 帧且大于 0.1 秒；夜景焦距元数据约 7.2×10^-10 mm 差异导致精确相等断言失败。先核对测试契约及数值容差，再判断产品修改。
5. **有条件的效果验收。**人物居中/人像测试没有检出人物，近距微距测试未观察到系统切超广角；这轮没有事先安排这些现场条件，不将其直接判定为效果失效。自然夜景两项因环境不够暗跳过，不能以注入曝光计划的通过代替暗光画质验收。

高动态 RAW 捕获/再次显影、深暗部曲线、A挡48MP多格式、电影效果专项及多项双拍规格矩阵本轮有通过记录；但对应模块仍有其他失败方法，不能写成模块全部通过。人像头顶、镜框与绿叶最终画质沿用此前人物入镜专项记录，本轮不更新为再次验收通过。

## 性能与稳定性实测

- 前后镜头手动切换：12 个新路由预览样本，0.604–1.107 秒，未清空旧预览 0/12（`MANUAL-FACING-PREVIEW`）；这是新帧到达延迟，不是拍摄或动画完整耗时。
- A挡自适应夜景真实硬件采集：注入曝光计划，3/3/6 张源帧，出片回调 3.099/3.169/4.851 秒（n=3）；源文件快门为 1/16 与 1/8 秒、ISO200。此组不代表真实场景自然触发。
- M挡夜景：三组 6/9/3 张源帧，回调 2.925/2.572/3.565 秒（n=3），实际源曝光 400×1/15、800×1/8、100×1秒；取消/返回检查有通过记录。
- 滤镜编辑压力：2040 次更新、31.255 秒、440 次预览发布；宿主进程（含 XCTest）footprint 基线约405 MiB、采样峰值696 MiB、收起后531 MiB。峰值比基线约291 MiB，超过 +256 MiB 门限，故该方法失败；不是独立正式 App 内存、不是泄漏证明，发布次数也不是屏幕呈现帧率。
- 人像连续拖动前/后置各180次，无空预览；发布间隔P95约71.1/37.5毫秒。但两路 acceptedMasks=0，未检出人物，方法失败；不能据此声称实际人物边缘/实时虚化已通过。
- 夜景融合 320×240 固定样本：12次，含渲染中位0.1016秒/P95 0.1057秒；含自动影调12次中位0.1030秒/P95 0.1095秒。不是全尺寸出片延迟或预览帧率。
- XCTest 性能方法7项，详见下表与结构化文件。快照绘制耗时不能解释为真实界面帧率；XCTMemoryMetric/footprint包含测试宿主与测试资源，不能解释为独立 App 内存。没有功耗、温度或电池消耗的独立仪器数据，不作“降低发热/功耗”结论。

| 方法 | 样本数 | 耗时均值 | 范围 | 含义 |
| --- | ---: | ---: | --- | --- |
| `PhotoOptionsTests/testNightEnvironmentGateRepeatedReadingsPerformance` | 5 | 1.594 ms | 1.557–1.678 ms | 固定循环运行耗时 |
| `PopupAppearanceAndOrientationTests/testParameterSheetDrawPerformance` | 5 | 96.899 ms | 74.744–113.246 ms | 快照绘制；非实际帧率 |
| `PopupAppearanceAndOrientationTests/testPopupGlassDrawPerformance` | 5 | 109.762 ms | 93.232–117.439 ms | 快照绘制；非实际帧率 |
| `PopupAppearanceAndOrientationTests/testPopupOrientationSwitchDrawPerformance` | 5 | 143.627 ms | 102.508–170.130 ms | 快照绘制；非实际帧率 |
| `PopupAppearanceAndOrientationTests/testTopToolbarPopupDrawPerformance` | 5 | 117.892 ms | 113.398–121.803 ms | 快照绘制；非实际帧率 |
| `VideoFrameFilterRendererTests/testFoodCubeRendersThirty640pFramesForPerformanceSample` | 5 | 10.438 ms | 10.264–10.812 ms | 640×360、30帧渲染循环；非相机帧率 |
| `VideoFrameFilterRendererTests/testLogLUTRenderPerformanceAt640x360ForThirtyFrames` | 10 | 145.357 ms | 123.210–167.664 ms | 640×360、30帧渲染循环；非相机帧率 |

## 运行异常与限制

- 日志共6条带 error key 的相机会话错误：5条发生在明确注入错误的恢复测试中，不作为真实系统故障；另1条在 `LivePhotoPhysicalTests/testManualParametersSurviveRepeatedSessionStopsAndRestarts` 期间出现 AVFoundation -11800 / underlying -12785。该方法随后通过，仍单独保留待定位，不能因通过忽略错误，也不能认定它就是所有后续失败根因。
- 4条无 `AVCaptureSessionErrorKey` 的测试通知单独保留，不按真实AVFoundation错误计数。
- `mdb_txn_commit / MDB_MAP_FULL` 共2344条；仅确认日志出现频繁，来源/对测试的影响未定位，不把它直接归因为用户照片空间不足。
- xcresult记录1类运行警告：`SmartCompositionGeometryTests` 在View外读取Environment，取默认值；未发现日志中的“Publishing changes”警告。本轮未见测试进程崩溃或自动重启的日志标记，但这不等于所有功能稳定。
- 14个跳过方法包括：历史RAW样本不可访问2项、模拟器专用布局/中断路径4项、自然暗光触发2项、慢门/延时真实路线未就绪6项。逐项原因见下列文件；另有录像白平衡方法内部发出skip但此前已有失败断言，其最终状态仍是失败，未重复计入跳过。
- 未做外接T7实盘、长时间真实星轨/流水移动场景、自然暗光、人像多人边缘、人物实际跟随、独立功耗温度等验收。相册真实写入/删除端到端也未在本轮验证。

## 排除项（5）

- `LumaCameraTests/AdaptiveDynamicPhysicalTests/testExplicitlyAuthorizedRAWArchiveRoundTrip`
- `LumaCameraTests/FrontPhotoAspectRatioPhysicalTests/testRealLandscapeToPortraitThenAspectFraming`
- `LumaCameraTests/LiveAudioSavePhysicalTests/testAudioSurvivesFrontRearAndAMSwitchesWithoutBlockingPreview`
- `LumaCameraTests/LiveAudioSavePhysicalTests/testOrdinaryJPEGAndAudibleLiveActuallySaveAsCorrectAssetTypes`
- `LumaCameraTests/ProResRAWPhysicalTests/testRealSensorRAWAndRAWHQStorageCompatibility`

## 文件

- [独立失败待办（78项）](2026-10-28-FullDevice-TODO.md)
- [全部671项状态、断言、跳过原因与指标](2026-10-28-FullDevice-results.json)
- 结果包：`/private/tmp/LumaCamera-FullDevice-20261028/FullSuite.xcresult`。
- 完整日志：`/private/tmp/LumaCamera-FullDevice-20261028/run.log`；枚举、安全清单和源码哈希亦在该目录。临时目录不保证永久保留。
