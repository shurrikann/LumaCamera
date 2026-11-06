# 2026-10-24 照片/视频往返后的 Live、HDR 与手动参数

对应原全量失败 **FULL-20261024-025**。原全量断言是 Live 转视频后无法录制；本次独立基线通过，不能据此确认历史系统错误的内部根因。增强实际成片检查另发现一次 M 挡读数与成片曝光不一致，已加固手动照片提交，并通过相关真机回归。

## 实现与官方依据

- 照片与视频仍各自保存 A/M 挡；返回照片先退出视频输出及帧周期限制，再恢复照片的快门、ISO、对焦和白平衡。现有 UI、镜头选择和过渡不变。
- 普通 M 挡现在也在拍摄请求中保存手动曝光快照，在原生 `setExposureModeCustom` 完成回调后提交照片；原来只有预览辅助临时长曝光走此等待路径。预览辅助恢复、手动包围曝光、夜景和视频各自保留原路径。
- 苹果[手动曝光文档](https://developer.apple.com/documentation/avfoundation/avcapturedevice/setexposuremodecustom(duration:iso:completionhandler:))说明完成回调对应设置应用后的时间，并要求照片采用 `.speed` 才能保证自定义曝光被尊重；本项目已设置该优先级，本次保留。等待回调是同步防护，不把历史曝光偏差的系统内部原因写成已经确证。

## 测试过程与证据

设备：iPhone 17 Pro，iOS 27.0.1，正常项目签名；无模拟器、无镜像。媒体仅临时文件/内存回调，不写系统相册。

| 运行 | 结果 | 用途 |
| --- | --- | --- |
| Baseline | 原方法通过，17.171 秒 | 独立基线，尚未检查返回后的实际照片 |
| Verified | 3 方法中 1 方法失败，共 2 断言 | 第二张 M 挡成片 EXIF 为 0.025 秒、ISO 1000；拍前实际读数为约 0.499895 秒、ISO 199.72 |
| Trace | 原增强方法通过，59.299 秒 | 间歇性：两张 M 挡都正确；提交时 custom、speed，不能当作稳定修复 |
| Fixed | **5 方法通过，0 失败/跳过，86.421 秒** | 实施回调防护后的验收 |

最终相关方法：

- `VideoModeTransitionTests/testLiveHDRAndManualPhotoRoutesSurviveVideoRoundTrips`：64.158 秒。
- `CaptureStatePersistenceTests/testIndependentVideoModePersistsWhilePhotoIsSelected`：0.126 秒。
- `CaptureStatePersistenceTests/testPhotoManualExposureSurvivesVideoClampAndModelRecreation`：0.060 秒。
- `PreviewExposureAssistPhysicalTests/testSmoothPreviewKeepsRequestedStillExposureAndSurvivesRapidToggles`：13.960 秒，包含连续开关及拍摄中关闭辅助后的成片核对。
- `SlowShutterSequencePhysicalTests/testSingleFramePresetsCaptureRequestedExposureWithoutStartingSequence`：8.117 秒，单帧慢门预设实拍回归。

主用例按 Live→HDR→M→M→HDR→Live 两轮往返，共 6 段 1920×1080 临时视频及 6 张返回后的真实照片：

- 两张 Live 都有静图与 pairedVideo；两张 HDR 均为 10-bit PQ。
- 两张 M 挡文件 EXIF 均为 0.5 秒、ISO 200；设备曝光 custom、对焦 locked（0.65±0.03）、白平衡 locked，模型仍保存 5200K/色调12。
- 各张成片方向为1，四类拍摄任务计数均归零；媒体库待保存计数未增加。
- 再立即提交 10 对视频→照片请求，最终返回照片且继续发布新帧。保留快速切换时的 SwiftUI onChange/Geometry 循环警告，未将其写成零警告或已修复。
- 正常组未收到携带 error 对象的相机会话运行错误通知。日志仍有 MDB_MAP_FULL、FigApplicationStateMonitor 等平台输出；并非所有底层错误文本都已排除。

## 性能与限制

切回照片请求至配置结束、新帧及该组参数断言全部满足（**不等于纯预览延迟**）：6 样本为 0.462、0.453、1.032、1.040、0.458、0.486 秒；A 挡四次约 0.453–0.486 秒，M 挡两次约 1.032–1.040 秒。

快门请求至成片回调：6 样本 4.004、5.224、2.551、2.542、5.751、3.710 秒；依次为 Live/HDR/M/M/HDR/Live。含曝光、系统处理及应用编码，不是单张硬件曝光时间，也没有足够同场景样本证明出片提速。M 挡两张约2.54–2.55秒，本次优先保证参数一致。

仅验证上述设备、短录像、选定照片格式和参数，不替代长时录制、所有镜头/曝光/格式或功耗内存验收；未覆盖外接 RAW 实盘。原全量 529/489/33/7 保留不变；本项定向关闭后，累计25个原失败方法有通过记录，余8项待处理/未复测。

原始证据位于 `/private/tmp/LumaCamera-LiveHDRManualRestore-20261024-{Baseline,Verified,Trace,Fixed}.xcresult` 及各自 `.log`。普通 App 构建日志：`/private/tmp/LumaCamera-LiveHDRManualRestore-20261024-FinalApp.log`。
