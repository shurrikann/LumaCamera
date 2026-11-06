# 2026-10-30 真机全量测试

## 结果

**736项：641通过、82失败、13跳过；整体Failed，退出码65。** 结果包与逐项清单已核对。另5个需要实际相册写入、外接盘或人工姿态配合的方法单独排除。

- 设备：iPhone17Pro（iPhone18,1），iOS27.2（24B119），arm64e；CoreDevice当前连接为localNetwork。
- 时间：2026-10-30 20:07:46–21:15:47，4081.606秒，约68分钟。
- 当前真机构建枚举741个方法；14个simulator条件编译后的空类不算测试方法。736个方法全部有最终结果，未配置失败重试。
- 后段视频虚拟光圈用例期间出现一次宿主异常退出，Xcode重启宿主继续剩余方法。此方法无控制台结束行，按xcresult补入失败统计。
- 测试构建通过，源码编译警告0；AppIntents元数据提取跳过提示2条（App与测试包工具链）。
- 373份Swift源码、测试及项目配置文件的运行前后SHA-256一致。本轮仅测试、记录，未修改功能或测试断言。
- 测试结束后手机解锁，普通`com.shurrikann.LumaCamera`已重新启动。

## 重点问题

1. **图像资源分配失败与异常退出。** 最早IOSurface失败在日志L7520，发生于`HEIFHDRPhysicalTests/testHEIFHDRUsesTenBitLivePreviewAndRestoresRAWPhotoQualityWithoutSaving`；其后有解码失败、像素缓冲创建失败和空图。`0xe00002bd`在当前Apple SDK的`IOReturn.h`映射为`kIOReturnNoMemory`。视频虚拟光圈期间宿主异常退出，随后Xcode续跑。日志有5872条IOSurface相关行（含属性展开）、15条`NULL _blockArray`。优先检查大图资源生命周期与连续运行资源占用；退出的具体系统原因仍需崩溃/内存诊断定位。
2. **连续拍摄回调与合成失效。** HDR/RAW、人像、夜景多条用例未在30/35/45/55秒收到成片；慢门多预设报“逐帧合并失败”，中间累积预览为0，独立累积预览测试亦返回空图。完整证据按方法保留。
3. **未保存队列积累影响后续测试。** 日志明确出现2、3、4张未保存照片。`PhotoLibraryViewModel.canAcceptNewCapture`要求`pendingSaveCount + failedSaveCount < 4`；达到4张后，后续拍摄受到背压。此组单独归为连续测试状态清理问题，重点检查迟到回调和默认保存回调的归属。
4. **实际视频规格不匹配。** 文件核对中，50fps请求出现30/33.33fps，60fps请求出现25.71fps；120fps用例出现18.95/24fps。镜头与规格筛选专项通过，实际文件帧率仍有失败。
5. **独立功能与交互问题。** 人像切换后HEIF Pro回落为HEIF；高像素用例某张文件为2376×3168（约753万），同用例也有6000×8000文件；流水筛选接受了预期应拒绝的第5帧；自动取景计数2而预期1；自动白平衡读数超容差、录像白平衡恢复、设置记忆、双拍入口/布局及视频虚拟光圈滑条宽度断言失败。

失败按方法计数；跟进按问题组组织，方便先解决连锁状态再定位具体功能。

| 跟进组 | 失败方法数 |
| --- | ---: |
| 慢门合成／累积预览 | 21 |
| 照片回调／解码编码 | 19 |
| 会话／路由恢复 | 12 |
| 连续测试未保存队列／拍摄受阻 | 7 |
| 拍摄／交互状态 | 4 |
| 曝光／白平衡／锁定恢复 | 3 |
| 设置记忆／格式兼容 | 3 |
| 智拍状态／重复取景 | 3 |
| 双拍状态／布局 | 2 |
| 实际视频帧率／规格 | 2 |
| 帧筛选 | 1 |
| 录音期间触感许可 | 1 |
| 实际文件像素 | 1 |
| 滤镜编辑压力／宿主内存 | 1 |
| 微距现场条件 | 1 |
| 资源分配／宿主异常退出 | 1 |

## 性能与稳定性

- A/M切换8个样本，新帧0.960–1.110秒，过渡结束1.139–1.294秒。
- 电影模式1–3×变焦16样本，请求到队列清空/就绪中位17.06ms、最大46.44ms；包含队列同步，非屏幕首帧或显示帧率。
- 格式/景深浮层32布局、20次同步快照绘制，中位34.55ms、最大40.40ms。该用例最终因格式回落失败，布局与性能样本仍保留。
- 滤镜编辑2040次更新、30.710秒，486次预览发布；宿主footprint日志为基线486、峰值726、收起后624 MB，收起后内存超过测试门限。此为含XCTest的宿主指标，未测独立正式App内存。
- XCTest共7个方法收集性能数据；下表按原始样本计算均值，单位ms。快照绘制与640×360渲染循环均非屏幕FPS。

| 方法 | 样本数 | 均值ms | 范围ms |
| --- | ---: | ---: | --- |
| `PhotoOptionsTests/testNightEnvironmentGateRepeatedReadingsPerformance` | 5 | 1.429 | 1.405–1.493 |
| `PopupAppearanceAndOrientationTests/testParameterSheetDrawPerformance` | 5 | 102.326 | 77.555–127.454 |
| `PopupAppearanceAndOrientationTests/testPopupGlassDrawPerformance` | 5 | 99.133 | 78.107–117.400 |
| `PopupAppearanceAndOrientationTests/testPopupOrientationSwitchDrawPerformance` | 5 | 154.580 | 123.923–165.771 |
| `PopupAppearanceAndOrientationTests/testTopToolbarPopupDrawPerformance` | 5 | 107.145 | 96.936–122.564 |
| `VideoFrameFilterRendererTests/testFoodCubeRendersThirty640pFramesForPerformanceSample` | 5 | 19.096 | 18.155–21.112 |
| `VideoFrameFilterRendererTests/testLogLUTRenderPerformanceAt640x360ForThirtyFrames` | 10 | 60.307 | 51.748–105.133 |

## 运行事件与覆盖

- 7条带错误信息的相机会话事件：5条来自显式注入恢复测试；另2条实际事件分别是前置Center Stage的`-11819`、Live照片参数停止重启用例中的`-11800 / -12785`。另有4条无error key的注入通知。
- `MDB_MAP_FULL`日志2786条。Environment默认值运行警告21条、1类，来源包含若干测试宿主抽取子视图。
- 单机串行覆盖照片/视频、各镜头、格式/曝光/对焦、夜景/慢门/人像/光圈/智拍、滤镜、弹窗/方向/画幅、取消/返回及文件元数据。复杂人物、自然暗光和外接盘条件未补设；13个跳过原因逐项记录。
- [相册隔离与排除清单](2026-10-30-FullDevice-SafetyAudit.md)：诊断默认服务只读，实际写库用例排除；诊断媒体走内存、临时文件或xcresult。

## 与10月28日同名方法对照

共同方法668个：旧失败本轮通过26个，两轮均失败50个，旧通过本轮失败20个。本轮新增方法68个。逐项对照保存在JSON，测试集合及运行状态差异随记录保留。

## 文件与后续入口

- [82项逐项问题清单](2026-10-30-FullDevice-TODO.md)
- [736项状态、断言、跳过、指标和跨轮对照](2026-10-30-FullDevice-results.json)
- 结果包：`/tmp/LumaCamera-FullDevice-20261030/FullSuite.xcresult`
- 日志、正式summary、枚举、allowlist、源码哈希：`/tmp/LumaCamera-FullDevice-20261030/`

本轮未做修复或失败项独立复测；下一轮优先资源分配/会话恢复与未保存队列清理。
