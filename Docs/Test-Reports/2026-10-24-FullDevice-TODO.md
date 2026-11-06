# 2026-10-24 真机全量测试：独立问题与失败清单

> 最新：**2026-10-25 剩余五项定向通过**：按序完成视频规格矩阵、Open Gate、录像白平衡、慢动作切镜和电影路线。修复HDR白平衡锁定阻塞/增益固定与慢动作重定时写入反压；13个相关方法有通过记录，42段临时视频完整解码。原33个失败方法现均有后续定向通过记录，未重新全量测试，7个跳过项及外接RAW等限制仍保留。[专项报告](2026-10-25-RemainingVideoFive-Resolution.md)。

> 最新：**高帧率规格与预览节奏定向通过**：两轮后置三种分辨率120帧及前置1080p30/4K60共10段文件、739帧完整解码，实际PTS与名义帧率匹配；120帧预览图像发布约116.5–119.9次/秒，快速升降帧率及停机恢复通过。4项相关检查通过，未改正式采集或UI；累计28个原失败方法通过，余5项未处理/未复测。[专项记录](2026-10-24-HighRatePreview-Resolution.md)。

> 最新：**录像退出/恢复与取消收尾定向通过**：三轮A/M/A退出/恢复、300次模式请求合并、计时冻结及视频完整解码通过；另修复白平衡锁定等待时立即取消漏回调和busy残留，并隔离迟到回调、重复停止。修复后4个不同相关方法通过，未写系统相册；累计26个原失败方法通过，其余7项未处理/未复测。[专项记录](2026-10-24-VideoLifecycle-Resolution.md)。

> 最新：**照片/视频往返恢复定向通过**：Live/HDR/M 两轮共6段视频、6张真实照片及10次快速反向切换通过。增强检查曾发现 M 挡读数正确但成片曝光偏差，现普通手动照片也等待官方曝光完成回调；修复后5项相关检查通过。累计25个原失败方法通过，其余8项未处理/未复测。[专项记录](2026-10-24-LiveHDRManualRestore-Resolution.md)。

> 原始全量运行仅记录，与 2026-10-23 及此前待办分开。用户随后要求处理两项容易项，最新定向结果见下；原全量结果、断言及其余状态保留。

## 结果

- 设备：iPhone 17 Pro / iOS 27.0.1 (24A446)；正常项目签名，单真机串行执行。
- 时间：2026-10-24 12:35:40 至 2026-10-24 13:11:39（Asia/Shanghai），2159.2 秒，约 36.0 分钟。
- **529 项：489 通过、33 失败、7 跳过；整体 Failed，xcodebuild 退出码 65。**失败按方法计数，同一方法多个断言不重复计数。
- 本轮未改生产代码或测试代码；没有人工复测、自动失败重试或修复；日志未见测试进程被 kill / 自动重启。
- 未启动或操作模拟器、未使用手机镜像；诊断媒体不写入/删除系统相册。
- 结果包：`/private/tmp/LumaCamera-FullDevice-20261024-Run1.xcresult`；完整日志：`/private/tmp/LumaCamera-FullDevice-20261024-Run1.log`。
- [结构化结果](2026-10-24-FullDevice-results.json) 保存全部方法状态、失败断言、耗时、跳过原因和指标；临时目录不保证永久保留。

## 需要后续处理的主要现象

- 冷启动手动设置恢复期间出现一次非注入的 AVFoundation -11819 错误，随后就绪/读数断言失败。仅确认时间相关，未定位根因。
- 前置方向/宽窄构图、文件宽高断言失败；本轮未要求用户固定手机朝向，因此应先区分实际方向问题和用例前提，不直接认定文件已经旋转错误。
- 人像 HEIF 等待原生捕获 55 秒超时，后续前后置人像、预览辅助、Pro 影调和静音快门等出现缺少成片/参数、任务未清空。
- 后段视频日志出现 `capturing=true pending=4`，多个编码、色彩空间、Open Gate、电影/慢动作、白平衡及生命周期用例未录出文件。可能存在共享会话状态污染或连锁失败；本轮没有复测，不能将 33 个失败直接解释为 33 个独立产品缺陷。
- 慢动作切镜存在镜头 ID、倍率、新路由帧未更新断言；另有画幅中心 0.5 像素差、慢门布局未取得焦段框、变焦轮倍率不变断言。

## 本次失败待办

### FULL-20261024-001 — CaptureStatePhysicalTests

- [x] **测试生命周期等待与异常收尾修正后定向真机通过；历史服务重置内部原因未确认**：`CaptureStatePhysicalTests/testColdRestorationAppliesManualValuesToRealLensAndVideoPipeline()`
- 方法耗时：18.556 秒。
- 结果摘要：XCTAssertTrue failed
- 原始断言（相同文本去重；行号为完整日志位置）：

  - 日志 2017：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/CaptureStatePhysicalTests.swift:40: error: -[LumaCameraTests.CaptureStatePhysicalTests testColdRestorationAppliesManualValuesToRealLensAndVideoPipeline] : XCTAssertTrue failed`
  - 日志 2018：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/CaptureStatePhysicalTests.swift:41: error: -[LumaCameraTests.CaptureStatePhysicalTests testColdRestorationAppliesManualValuesToRealLensAndVideoPipeline] : XCTUnwrap failed: expected non-nil value of type "CameraReadings"`

### FULL-20261024-002 — FrontWideSelectionTests

- [x] **前提修正及前置方向修复后定向真机通过**：`FrontWideSelectionTests/testCurrentOrientationFramingAndRecordingGuard()`
- 方法耗时：42.462 秒。
- 结果摘要：XCTAssertEqual failed: ("com.apple.avfoundation.avcapturedevice.built-in_video:8:1.6000") is not equal to ("com.apple.avfoundation.avcapturedevice.built-in_video:8:1.0000") - Front framing should match the device's current orientation
- 原始断言（相同文本去重；行号为完整日志位置）：

  - 日志 2616：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/FrontWideSelectionTests.swift:64: error: -[LumaCameraTests.FrontWideSelectionTests testCurrentOrientationFramingAndRecordingGuard] : XCTAssertEqual failed: ("com.apple.avfoundation.avcapturedevice.built-in_video:8:1.6000") is not equal to ("com.apple.avfoundation.avcapturedevice.built-in_video:8:1.0000") - Front framing should match the device's current orientation`

后续：原三项在横持/竖持回归通过；修正画幅准备与姿态读取前提，另修复目视发现的前置横拿照片内容侧转。快门使用官方旋转协调器并同步裁切轴，保留实际焦距和方向元数据；见[专项报告](2026-10-24-FrontThree-Resolution.md)。

### FULL-20261024-003 — FrontWideSelectionTests

- [x] **前提修正及前置方向修复后定向真机通过**：`FrontWideSelectionTests/testFrontPhotoFilesKeepUprightPixelsAndSystemFocalLengths()`
- 方法耗时：5.415 秒。
- 结果摘要：XCTAssertGreaterThan failed: ("3024.0") is not greater than ("4032.0")
- 原始断言（相同文本去重；行号为完整日志位置）：

  - 日志 2665：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/FrontWideSelectionTests.swift:413: error: -[LumaCameraTests.FrontWideSelectionTests testFrontPhotoFilesKeepUprightPixelsAndSystemFocalLengths] : XCTAssertGreaterThan failed: ("3024.0") is not greater than ("4032.0")`
  - 日志 2666：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/FrontWideSelectionTests.swift:427: error: -[LumaCameraTests.FrontWideSelectionTests testFrontPhotoFilesKeepUprightPixelsAndSystemFocalLengths] : XCTAssertGreaterThan failed: ("3000.0") is not greater than ("4000.0")`

后续：原三项在横持/竖持回归通过；修正画幅准备与姿态读取前提，另修复目视发现的前置横拿照片内容侧转。快门使用官方旋转协调器并同步裁切轴，保留实际焦距和方向元数据；见[专项报告](2026-10-24-FrontThree-Resolution.md)。

### FULL-20261024-004 — FrontWideSelectionTests

- [x] **前提修正及前置方向修复后定向真机通过**：`FrontWideSelectionTests/testFrontSwitchManualExposureMirrorCaptureAndCancellation()`
- 方法耗时：2.708 秒。
- 结果摘要：XCTAssertGreaterThan failed: ("1800.0") is not greater than ("2400.0")
- 原始断言（相同文本去重；行号为完整日志位置）：

  - 日志 2680：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/FrontWideSelectionTests.swift:364: error: -[LumaCameraTests.FrontWideSelectionTests testFrontSwitchManualExposureMirrorCaptureAndCancellation] : XCTAssertGreaterThan failed: ("1800.0") is not greater than ("2400.0")`

后续：原三项在横持/竖持回归通过；修正画幅准备与姿态读取前提，另修复目视发现的前置横拿照片内容侧转。快门使用官方旋转协调器并同步裁切轴，保留实际焦距和方向元数据；见[专项报告](2026-10-24-FrontThree-Resolution.md)。

### FULL-20261024-005 — PhotoOptionsTests

- [x] **测试修正后定向真机通过**：`PhotoOptionsTests/testNewRatiosAreCenteredAndXPANUsesFilmGateRatio()`
- 方法耗时：0.001 秒。
- 结果摘要：XCTAssertEqualWithAccuracy failed: ("60.5") is not equal to ("60.0") +/- ("0.001")
- 原始断言（相同文本去重；行号为完整日志位置）：

  - 日志 5615：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/PhotoOptionsTests.swift:258: error: -[LumaCameraTests.PhotoOptionsTests testNewRatiosAreCenteredAndXPANUsesFilmGateRatio] : XCTAssertEqualWithAccuracy failed: ("60.5") is not equal to ("60.0") +/- ("0.001")`

处理说明：修正整数像素量化断言/共享相机布局测试前提；未改产品布局或裁切。见[两项专项记录](2026-10-24-EasyTwo-Resolution.md)。

### FULL-20261024-006 — PhysicalCameraSwitchingTests

- [x] **构图预期修正、前置方形冻结修复后定向真机通过**：`PhysicalCameraSwitchingTests/testManualPresetsThenAutomaticModeOnPhysicalCamera()`
- 方法耗时：24.332 秒。
- 结果摘要：XCTAssertLessThan failed: ("900.0") is not less than ("675.0")
- 原始断言（相同文本去重；行号为完整日志位置）：

  - 日志 5726：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/CameraReadingsSafetyTests.swift:174: error: -[LumaCameraTests.PhysicalCameraSwitchingTests testManualPresetsThenAutomaticModeOnPhysicalCamera] : XCTAssertLessThan failed: ("900.0") is not less than ("675.0")`

### FULL-20261024-007 — PortraitCapturePhysicalTests

- [x] **收尾/恢复修复后定向真机通过**：`PortraitCapturePhysicalTests/testPortraitProcessedAndProRAWCapturesWithoutSaving()`
- 方法耗时：55.592 秒。
- 结果摘要：Asynchronous wait failed: Exceeded timeout of 55 seconds, with unfulfilled expectations: "Portrait capture: HEIF 12MP portrait matte".
- 原始断言（相同文本去重；行号为完整日志位置）：

  - 日志 5907：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/PortraitCapturePhysicalTests.swift:344: error: -[LumaCameraTests.PortraitCapturePhysicalTests testPortraitProcessedAndProRAWCapturesWithoutSaving] : Asynchronous wait failed: Exceeded timeout of 55 seconds, with unfulfilled expectations: "Portrait capture: HEIF 12MP portrait matte".`
  - 日志 5908：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/PortraitCapturePhysicalTests.swift:346: error: -[LumaCameraTests.PortraitCapturePhysicalTests testPortraitProcessedAndProRAWCapturesWithoutSaving] : XCTUnwrap failed: expected non-nil value of type "CapturedPhoto" - 相机暂时无法恢复，请点击重试重新连接。`

后续处理：已增加原生回调超时保护、唯一 token 终结、按序交付解堵及照片输出重建；真实人像/ProRAW/M挡和后续视频检查通过，另有漏回调与四请求注入恢复验证。系统内部未返图原因未确证。见[专项报告](2026-10-24-Portrait-Timeout-Recovery.md)。

### FULL-20261024-008 — PortraitOptimizationPhysicalTests

- [x] **真实人物复测及拍后/元数据检查定向通过**：`PortraitOptimizationPhysicalTests/testFrontPortraitContinuousAdjustmentAndCapture()`
- 方法耗时：20.587 秒。
- 结果摘要：XCTAssertTrue failed - 人像测试等待条件超时
- 原始断言（相同文本去重；行号为完整日志位置）：

  - 日志 5942：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/PortraitOptimizationPhysicalTests.swift:258: error: -[LumaCameraTests.PortraitOptimizationPhysicalTests testFrontPortraitContinuousAdjustmentAndCapture] : XCTAssertTrue failed - 人像测试等待条件超时`
  - 日志 5943：`<unknown>:0: error: -[LumaCameraTests.PortraitOptimizationPhysicalTests testFrontPortraitContinuousAdjustmentAndCapture] : failed: caught error: "InvalidTransition { `

### FULL-20261024-009 — PortraitOptimizationPhysicalTests

- [x] **收尾/恢复修复后定向真机通过**：`PortraitOptimizationPhysicalTests/testManualMainHEIFPortraitCanBeEnabledAndCaptured()`
- 方法耗时：0.701 秒。
- 结果摘要：XCTAssertTrue failed - 相机暂时无法恢复，请点击重试重新连接。
- 原始断言（相同文本去重；行号为完整日志位置）：

  - 日志 5950：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/PortraitOptimizationPhysicalTests.swift:43: error: -[LumaCameraTests.PortraitOptimizationPhysicalTests testManualMainHEIFPortraitCanBeEnabledAndCaptured] : XCTAssertTrue failed - 相机暂时无法恢复，请点击重试重新连接。`
  - 日志 5951：`<unknown>:0: error: -[LumaCameraTests.PortraitOptimizationPhysicalTests testManualMainHEIFPortraitCanBeEnabledAndCaptured] : failed: caught error: "InvalidTransition { `

后续处理：已增加原生回调超时保护、唯一 token 终结、按序交付解堵及照片输出重建；真实人像/ProRAW/M挡和后续视频检查通过，另有漏回调与四请求注入恢复验证。系统内部未返图原因未确证。见[专项报告](2026-10-24-Portrait-Timeout-Recovery.md)。

### FULL-20261024-010 — PortraitOptimizationPhysicalTests

- [x] **真实人物复测及拍后/元数据检查定向通过**：`PortraitOptimizationPhysicalTests/testRearPortraitContinuousAdjustmentAndCapture()`
- 方法耗时：15.718 秒。
- 结果摘要：XCTAssertTrue failed - 人像测试等待条件超时
- 原始断言（相同文本去重；行号为完整日志位置）：

  - 日志 5957：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/PortraitOptimizationPhysicalTests.swift:258: error: -[LumaCameraTests.PortraitOptimizationPhysicalTests testRearPortraitContinuousAdjustmentAndCapture] : XCTAssertTrue failed - 人像测试等待条件超时`
  - 日志 5958：`<unknown>:0: error: -[LumaCameraTests.PortraitOptimizationPhysicalTests testRearPortraitContinuousAdjustmentAndCapture] : failed: caught error: "InvalidTransition { `

### FULL-20261024-011 — PortraitOptimizationPhysicalTests

- [x] **真实人物复测及拍后/元数据检查定向通过**：`PortraitOptimizationPhysicalTests/testRearPortraitSameFrameReference()`
- 方法耗时：1.549 秒。
- 结果摘要：XCTUnwrap failed: expected non-nil value of type "CapturedPhoto" - 相机暂时无法恢复，请点击重试重新连接。
- 原始断言（相同文本去重；行号为完整日志位置）：

  - 日志 5964：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/PortraitOptimizationPhysicalTests.swift:153: error: -[LumaCameraTests.PortraitOptimizationPhysicalTests testRearPortraitSameFrameReference] : XCTUnwrap failed: expected non-nil value of type "CapturedPhoto" - 相机暂时无法恢复，请点击重试重新连接。`

### FULL-20261024-012 — PreviewExposureAssistPhysicalTests

- [x] **独立基线与增强EXIF/生命周期检查后定向真机通过**：`PreviewExposureAssistPhysicalTests/testAutomaticSlowShutterCapsOnlyTheLivePreviewAndRestoresOnExit()`
- 方法耗时：5.466 秒。
- 结果摘要：XCTAssertTrue failed
- 原始断言（相同文本去重；行号为完整日志位置）：

  - 日志 5977：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/PreviewExposureAssistPhysicalTests.swift:53: error: -[LumaCameraTests.PreviewExposureAssistPhysicalTests testAutomaticSlowShutterCapsOnlyTheLivePreviewAndRestoresOnExit] : XCTAssertTrue failed`
  - 日志 5978：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/PreviewExposureAssistPhysicalTests.swift:54: error: -[LumaCameraTests.PreviewExposureAssistPhysicalTests testAutomaticSlowShutterCapsOnlyTheLivePreviewAndRestoresOnExit] : XCTUnwrap failed: expected non-nil value of type "Double"`
  - 日志 5979：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/PreviewExposureAssistPhysicalTests.swift:54: error: -[LumaCameraTests.PreviewExposureAssistPhysicalTests testAutomaticSlowShutterCapsOnlyTheLivePreviewAndRestoresOnExit] : XCTAssertEqual failed: threw error "UnwrappingOptional(errorCode: 105, errorUserInfo: ["XCTestErrorUserInfoKeyShouldIgnore": true])"`
  - 日志 5980：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/PreviewExposureAssistPhysicalTests.swift:61: error: -[LumaCameraTests.PreviewExposureAssistPhysicalTests testAutomaticSlowShutterCapsOnlyTheLivePreviewAndRestoresOnExit] : XCTAssertTrue failed - A-mode preview optimization should engage after AE needs slower than 1/30 s`
  - 日志 5981：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/PreviewExposureAssistPhysicalTests.swift:64: error: -[LumaCameraTests.PreviewExposureAssistPhysicalTests testAutomaticSlowShutterCapsOnlyTheLivePreviewAndRestoresOnExit] : XCTAssertTrue failed`
  - 日志 5982：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/PreviewExposureAssistPhysicalTests.swift:66: error: -[LumaCameraTests.PreviewExposureAssistPhysicalTests testAutomaticSlowShutterCapsOnlyTheLivePreviewAndRestoresOnExit] : XCTAssertLessThanOrEqual failed: ("0.06666666666666667") is greater than ("0.035333333333333335")`

### FULL-20261024-013 — PreviewExposureAssistPhysicalTests

- [x] **独立基线与增强EXIF/生命周期检查后定向真机通过**：`PreviewExposureAssistPhysicalTests/testSlowShutterPresetAutomaticallyOptimizesSlowPreviewAndRestoresStillExposure()`
- 方法耗时：42.672 秒。
- 结果摘要：XCTAssertEqual failed: ("AVCaptureExposureMode(rawValue: 2)") is not equal to ("AVCaptureExposureMode(rawValue: 3)")
- 原始断言（相同文本去重；行号为完整日志位置）：

  - 日志 5985：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/PreviewExposureAssistPhysicalTests.swift:162: error: -[LumaCameraTests.PreviewExposureAssistPhysicalTests testSlowShutterPresetAutomaticallyOptimizesSlowPreviewAndRestoresStillExposure] : XCTAssertEqual failed: ("AVCaptureExposureMode(rawValue: 2)") is not equal to ("AVCaptureExposureMode(rawValue: 3)")`
  - 日志 5986：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/PreviewExposureAssistPhysicalTests.swift:163: error: -[LumaCameraTests.PreviewExposureAssistPhysicalTests testSlowShutterPresetAutomaticallyOptimizesSlowPreviewAndRestoresStillExposure] : XCTAssertEqualWithAccuracy failed: ("1027.6875") is not equal to ("400.0") +/- ("5.0")`
  - 日志 5987：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/PreviewExposureAssistPhysicalTests.swift:164: error: -[LumaCameraTests.PreviewExposureAssistPhysicalTests testSlowShutterPresetAutomaticallyOptimizesSlowPreviewAndRestoresStillExposure] : XCTAssertEqualWithAccuracy failed: ("0.040009") is not equal to ("0.06666666666666667") +/- ("0.002")`
  - 日志 5988：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/PreviewExposureAssistPhysicalTests.swift:183: error: -[LumaCameraTests.PreviewExposureAssistPhysicalTests testSlowShutterPresetAutomaticallyOptimizesSlowPreviewAndRestoresStillExposure] : XCTAssertTrue failed`
  - 日志 5989：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/PreviewExposureAssistPhysicalTests.swift:185: error: -[LumaCameraTests.PreviewExposureAssistPhysicalTests testSlowShutterPresetAutomaticallyOptimizesSlowPreviewAndRestoresStillExposure] : XCTAssertLessThanOrEqual failed: ("0.06666666666666667") is greater than ("0.035333333333333335")`
  - 日志 5990：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/PreviewExposureAssistPhysicalTests.swift:186: error: -[LumaCameraTests.PreviewExposureAssistPhysicalTests testSlowShutterPresetAutomaticallyOptimizesSlowPreviewAndRestoresStillExposure] : XCTUnwrap failed: expected non-nil value of type "Float"`
  - 日志 5991：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/PreviewExposureAssistPhysicalTests.swift:186: error: -[LumaCameraTests.PreviewExposureAssistPhysicalTests testSlowShutterPresetAutomaticallyOptimizesSlowPreviewAndRestoresStillExposure] : XCTAssertEqual failed: threw error "UnwrappingOptional(errorCode: 105, errorUserInfo: ["XCTestErrorUserInfoKeyShouldIgnore": true])"`
  - 日志 5992：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/PreviewExposureAssistPhysicalTests.swift:187: error: -[LumaCameraTests.PreviewExposureAssistPhysicalTests testSlowShutterPresetAutomaticallyOptimizesSlowPreviewAndRestoresStillExposure] : XCTUnwrap failed: expected non-nil value of type "Double"`
  - 日志 5993：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/PreviewExposureAssistPhysicalTests.swift:187: error: -[LumaCameraTests.PreviewExposureAssistPhysicalTests testSlowShutterPresetAutomaticallyOptimizesSlowPreviewAndRestoresStillExposure] : XCTAssertEqual failed: threw error "UnwrappingOptional(errorCode: 105, errorUserInfo: ["XCTestErrorUserInfoKeyShouldIgnore": true])"`
  - 日志 5995：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/PreviewExposureAssistPhysicalTests.swift:199: error: -[LumaCameraTests.PreviewExposureAssistPhysicalTests testSlowShutterPresetAutomaticallyOptimizesSlowPreviewAndRestoresStillExposure] : Asynchronous wait failed: Exceeded timeout of 30 seconds, with unfulfilled expectations: "automatic slow-shutter preview still capture".`
  - 日志 5996：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/PreviewExposureAssistPhysicalTests.swift:200: error: -[LumaCameraTests.PreviewExposureAssistPhysicalTests testSlowShutterPresetAutomaticallyOptimizesSlowPreviewAndRestoresStillExposure] : XCTUnwrap failed: expected non-nil value of type "CapturedPhoto" - 相机暂时无法恢复，请点击重试重新连接。`

### FULL-20261024-014 — PreviewExposureAssistPhysicalTests

- [x] **独立基线与增强EXIF/生命周期检查后定向真机通过**：`PreviewExposureAssistPhysicalTests/testSmoothPreviewKeepsRequestedStillExposureAndSurvivesRapidToggles()`
- 方法耗时：45.778 秒。
- 结果摘要：XCTAssertEqual failed: ("AVCaptureExposureMode(rawValue: 2)") is not equal to ("AVCaptureExposureMode(rawValue: 3)")
- 原始断言（相同文本去重；行号为完整日志位置）：

  - 日志 5999：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/PreviewExposureAssistPhysicalTests.swift:313: error: -[LumaCameraTests.PreviewExposureAssistPhysicalTests testSmoothPreviewKeepsRequestedStillExposureAndSurvivesRapidToggles] : XCTAssertEqual failed: ("AVCaptureExposureMode(rawValue: 2)") is not equal to ("AVCaptureExposureMode(rawValue: 3)")`
  - 日志 6000：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/PreviewExposureAssistPhysicalTests.swift:314: error: -[LumaCameraTests.PreviewExposureAssistPhysicalTests testSmoothPreviewKeepsRequestedStillExposureAndSurvivesRapidToggles] : XCTAssertEqualWithAccuracy failed: ("1035.8653564453125") is not equal to ("400.0") +/- ("5.0")`
  - 日志 6001：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/PreviewExposureAssistPhysicalTests.swift:315: error: -[LumaCameraTests.PreviewExposureAssistPhysicalTests testSmoothPreviewKeepsRequestedStillExposureAndSurvivesRapidToggles] : XCTAssertEqualWithAccuracy failed: ("0.040009") is not equal to ("0.06666666666666667") +/- ("0.002")`
  - 日志 6002：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/PreviewExposureAssistPhysicalTests.swift:333: error: -[LumaCameraTests.PreviewExposureAssistPhysicalTests testSmoothPreviewKeepsRequestedStillExposureAndSurvivesRapidToggles] : XCTAssertLessThanOrEqual failed: ("0.06666666666666667") is greater than ("0.035333333333333335")`
  - 日志 6003：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/PreviewExposureAssistPhysicalTests.swift:334: error: -[LumaCameraTests.PreviewExposureAssistPhysicalTests testSmoothPreviewKeepsRequestedStillExposureAndSurvivesRapidToggles] : XCTUnwrap failed: expected non-nil value of type "Float"`
  - 日志 6004：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/PreviewExposureAssistPhysicalTests.swift:334: error: -[LumaCameraTests.PreviewExposureAssistPhysicalTests testSmoothPreviewKeepsRequestedStillExposureAndSurvivesRapidToggles] : XCTAssertEqual failed: threw error "UnwrappingOptional(errorCode: 105, errorUserInfo: ["XCTestErrorUserInfoKeyShouldIgnore": true])"`
  - 日志 6005：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/PreviewExposureAssistPhysicalTests.swift:335: error: -[LumaCameraTests.PreviewExposureAssistPhysicalTests testSmoothPreviewKeepsRequestedStillExposureAndSurvivesRapidToggles] : XCTUnwrap failed: expected non-nil value of type "Double"`
  - 日志 6006：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/PreviewExposureAssistPhysicalTests.swift:335: error: -[LumaCameraTests.PreviewExposureAssistPhysicalTests testSmoothPreviewKeepsRequestedStillExposureAndSurvivesRapidToggles] : XCTAssertEqual failed: threw error "UnwrappingOptional(errorCode: 105, errorUserInfo: ["XCTestErrorUserInfoKeyShouldIgnore": true])"`
  - 日志 6008：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/PreviewExposureAssistPhysicalTests.swift:347: error: -[LumaCameraTests.PreviewExposureAssistPhysicalTests testSmoothPreviewKeepsRequestedStillExposureAndSurvivesRapidToggles] : Asynchronous wait failed: Exceeded timeout of 30 seconds, with unfulfilled expectations: "manual exposure photo with smooth preview".`
  - 日志 6009：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/PreviewExposureAssistPhysicalTests.swift:348: error: -[LumaCameraTests.PreviewExposureAssistPhysicalTests testSmoothPreviewKeepsRequestedStillExposureAndSurvivesRapidToggles] : XCTUnwrap failed: expected non-nil value of type "CapturedPhoto" - 相机暂时无法恢复，请点击重试重新连接。`

### FULL-20261024-015 — ProToneCapturePhysicalTests

- [x] **四种影调8张实际HDR文件及增强检查后定向真机通过**：`ProToneCapturePhysicalTests/testAllProTonesAreUsedByActualHDRHEIFProCaptureWithoutSaving()`
- 方法耗时：35.381 秒。
- 结果摘要：Asynchronous wait failed: Exceeded timeout of 35 seconds, with unfulfilled expectations: "HDR HEIF Pro 自然影调".
- 原始断言（相同文本去重；行号为完整日志位置）：

  - 日志 6726：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/ProToneCapturePhysicalTests.swift:34: error: -[LumaCameraTests.ProToneCapturePhysicalTests testAllProTonesAreUsedByActualHDRHEIFProCaptureWithoutSaving] : Asynchronous wait failed: Exceeded timeout of 35 seconds, with unfulfilled expectations: "HDR HEIF Pro 自然影调".`
  - 日志 6727：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/ProToneCapturePhysicalTests.swift:35: error: -[LumaCameraTests.ProToneCapturePhysicalTests testAllProTonesAreUsedByActualHDRHEIFProCaptureWithoutSaving] : XCTUnwrap failed: expected non-nil value of type "CapturedPhoto" - 相机暂时无法恢复，请点击重试重新连接。`

### FULL-20261024-016 — SilentShutterPhysicalTests

- [x] **普通/Live增强复测通过，另修复夜景静音遗漏**：`SilentShutterPhysicalTests/testNativeShutterSuppressionAcrossFormatsAndLiveWithoutSaving()`
- 方法耗时：56.259 秒。
- 结果摘要：XCTAssertEqual failed: ("4") is not equal to ("0")
- 原始断言（相同文本去重；行号为完整日志位置）：

  - 日志 6763：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/SilentShutterPhysicalTests.swift:33: error: -[LumaCameraTests.SilentShutterPhysicalTests testNativeShutterSuppressionAcrossFormatsAndLiveWithoutSaving] : XCTAssertEqual failed: ("4") is not equal to ("0")`
  - 日志 6764：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/SilentShutterPhysicalTests.swift:42: error: -[LumaCameraTests.SilentShutterPhysicalTests testNativeShutterSuppressionAcrossFormatsAndLiveWithoutSaving] : XCTAssertEqual failed: ("4") is not equal to ("1") - Capture must be accepted before waiting for completion`
  - 日志 6765：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/SilentShutterPhysicalTests.swift:43: error: -[LumaCameraTests.SilentShutterPhysicalTests testNativeShutterSuppressionAcrossFormatsAndLiveWithoutSaving] : Asynchronous wait failed: Exceeded timeout of 45 seconds, with unfulfilled expectations: "Shutter sound capture JPG".`
  - 日志 6766：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/SilentShutterPhysicalTests.swift:44: error: -[LumaCameraTests.SilentShutterPhysicalTests testNativeShutterSuppressionAcrossFormatsAndLiveWithoutSaving] : XCTUnwrap failed: expected non-nil value of type "CapturedPhoto" - 相机暂时无法恢复，请点击重试重新连接。`

### FULL-20261024-017 — SlowMotionLensTransitionPhysicalTests

- [x] **2026-10-25增强定向通过**：`SlowMotionLensTransitionPhysicalTests/testSlowMotionFocalSwitchLatencyAndRecording()`
- 方法耗时：237.336 秒。
- 结果摘要：XCTAssertEqual failed: ("com.apple.avfoundation.avcapturedevice.built-in_video:0:1.0000") is not equal to ("com.apple.avfoundation.avcapturedevice.built-in_video:5:1.0000")
- 原始断言（相同文本去重；行号为完整日志位置）：

  - 日志 6772：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/SlowMotionLensTransitionPhysicalTests.swift:92: error: -[LumaCameraTests.SlowMotionLensTransitionPhysicalTests testSlowMotionFocalSwitchLatencyAndRecording] : XCTAssertEqual failed: ("com.apple.avfoundation.avcapturedevice.built-in_video:0:1.0000") is not equal to ("com.apple.avfoundation.avcapturedevice.built-in_video:5:1.0000")`
  - 日志 6773：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/SlowMotionLensTransitionPhysicalTests.swift:93: error: -[LumaCameraTests.SlowMotionLensTransitionPhysicalTests testSlowMotionFocalSwitchLatencyAndRecording] : XCTAssertNotEqual failed: ("Optional(782A09E7-2D9A-446D-996E-34B015118772)") is equal to ("Optional(782A09E7-2D9A-446D-996E-34B015118772)")`
  - 日志 6774：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/SlowMotionLensTransitionPhysicalTests.swift:92: error: -[LumaCameraTests.SlowMotionLensTransitionPhysicalTests testSlowMotionFocalSwitchLatencyAndRecording] : XCTAssertEqual failed: ("com.apple.avfoundation.avcapturedevice.built-in_video:0:1.0000") is not equal to ("com.apple.avfoundation.avcapturedevice.built-in_video:0:2.0000")`
  - 日志 6776：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/SlowMotionLensTransitionPhysicalTests.swift:92: error: -[LumaCameraTests.SlowMotionLensTransitionPhysicalTests testSlowMotionFocalSwitchLatencyAndRecording] : XCTAssertEqual failed: ("com.apple.avfoundation.avcapturedevice.built-in_video:0:1.0000") is not equal to ("com.apple.avfoundation.avcapturedevice.built-in_video:2:1.0000")`
  - 日志 6778：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/SlowMotionLensTransitionPhysicalTests.swift:92: error: -[LumaCameraTests.SlowMotionLensTransitionPhysicalTests testSlowMotionFocalSwitchLatencyAndRecording] : XCTAssertEqual failed: ("com.apple.avfoundation.avcapturedevice.built-in_video:0:1.0000") is not equal to ("com.apple.avfoundation.avcapturedevice.built-in_video:2:2.0000")`
  - 日志 6780：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/SlowMotionLensTransitionPhysicalTests.swift:121: error: -[LumaCameraTests.SlowMotionLensTransitionPhysicalTests testSlowMotionFocalSwitchLatencyAndRecording] : XCTAssertEqualWithAccuracy failed: ("1.0") is not equal to ("1.4583333333333333") +/- ("0.02")`
  - 日志 6791：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/SlowMotionLensTransitionPhysicalTests.swift:93: error: -[LumaCameraTests.SlowMotionLensTransitionPhysicalTests testSlowMotionFocalSwitchLatencyAndRecording] : XCTAssertNotEqual failed: ("Optional(CF44498C-DAA0-4337-AD5B-FF902BB69FC8)") is equal to ("Optional(CF44498C-DAA0-4337-AD5B-FF902BB69FC8)")`
  - 日志 6823：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/SlowMotionLensTransitionPhysicalTests.swift:149: error: -[LumaCameraTests.SlowMotionLensTransitionPhysicalTests testSlowMotionFocalSwitchLatencyAndRecording] : XCTAssertTrue failed - 相机暂时无法恢复，请点击重试重新连接。`
  - 日志 6824：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/SlowMotionLensTransitionPhysicalTests.swift:156: error: -[LumaCameraTests.SlowMotionLensTransitionPhysicalTests testSlowMotionFocalSwitchLatencyAndRecording] : XCTUnwrap failed: expected non-nil value of type "URL"`

后续处理：按序增强真机通过，正式修复为白平衡阻塞与重定时反压；未据此确认历史所有系统内部故障原因。见[专项报告](2026-10-25-RemainingVideoFive-Resolution.md)。

### FULL-20261024-018 — SlowShutterPresetTests

- [x] **测试修正后定向真机通过**：`SlowShutterPresetTests/testPresetSlotsAlignWithFocalSlotsAndSurviveRapidToggleOnDevice()`
- 方法耗时：2.931 秒。
- 结果摘要：failed - Visible camera layout did not report all preset/focal frames: ["preset.lightTrails", "preset.silkyWater", "preset.motionBlur", "preset.panning", "preset.starTrails"]
- 原始断言（相同文本去重；行号为完整日志位置）：

  - 日志 6847：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/SlowShutterPresetTests.swift:161: error: -[LumaCameraTests.SlowShutterPresetTests testPresetSlotsAlignWithFocalSlotsAndSurviveRapidToggleOnDevice] : failed - Visible camera layout did not report all preset/focal frames: ["preset.lightTrails", "preset.silkyWater", "preset.motionBlur", "preset.panning", "preset.starTrails"]`

处理说明：修正整数像素量化断言/共享相机布局测试前提；未改产品布局或裁切。见[两项专项记录](2026-10-24-EasyTwo-Resolution.md)。

### FULL-20261024-019 — SlowShutterPresetTests

- [x] **测试基线修正后定向真机通过**：`SlowShutterPresetTests/testSlowShutterAllowsSwitchingRearLenses()`
- 方法耗时：10.043 秒。
- 结果摘要：XCTAssertEqual failed: ("nil") is not equal to ("Optional(LumaCamera.SlowShutterPreset.lightTrails)")
- 原始断言（相同文本去重；行号为完整日志位置）：

  - 日志 6861：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/SlowShutterPresetTests.swift:274: error: -[LumaCameraTests.SlowShutterPresetTests testSlowShutterAllowsSwitchingRearLenses] : XCTAssertEqual failed: ("nil") is not equal to ("Optional(LumaCamera.SlowShutterPreset.lightTrails)")`
  - 日志 6862：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/SlowShutterPresetTests.swift:286: error: -[LumaCameraTests.SlowShutterPresetTests testSlowShutterAllowsSwitchingRearLenses] : XCTAssertEqual failed: ("com.apple.avfoundation.avcapturedevice.built-in_video:0:1.0000") is not equal to ("com.apple.avfoundation.avcapturedevice.built-in_video:5:1.0000")`
  - 日志 6863：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/SlowShutterPresetTests.swift:287: error: -[LumaCameraTests.SlowShutterPresetTests testSlowShutterAllowsSwitchingRearLenses] : XCTAssertEqual failed: ("nil") is not equal to ("Optional(LumaCamera.SlowShutterPreset.lightTrails)")`

后续处理：独立相机基线、真实出帧与设备倍率检查补齐；24 次切镜、6 次重开及两次拖动后重开通过。未改产品代码，原共享会话问题未定位。见[专项报告](2026-10-24-PresetZoom-Resolution.md)。

### FULL-20261024-020 — VideoCodecPhysicalTests

- [x] **实际文件/像素/解码及增强基线后定向真机通过**：`VideoCodecPhysicalTests/testActualCodecsAndColorsRepeatedRecording()`
- 方法耗时：32.817 秒。
- 结果摘要：XCTAssertFalse failed
- 原始断言（相同文本去重；行号为完整日志位置）：

  - 日志 8431：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VideoCodecPhysicalTests.swift:78: error: -[LumaCameraTests.VideoCodecPhysicalTests testActualCodecsAndColorsRepeatedRecording] : XCTAssertFalse failed`
  - 日志 8432：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VideoCodecPhysicalTests.swift:79: error: -[LumaCameraTests.VideoCodecPhysicalTests testActualCodecsAndColorsRepeatedRecording] : XCTAssertEqual failed: ("4") is not equal to ("0")`
  - 日志 8433：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VideoCodecPhysicalTests.swift:83: error: -[LumaCameraTests.VideoCodecPhysicalTests testActualCodecsAndColorsRepeatedRecording] : XCTAssertTrue failed - 相机暂时无法恢复，请点击重试重新连接。`
  - 日志 8434：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VideoCodecPhysicalTests.swift:87: error: -[LumaCameraTests.VideoCodecPhysicalTests testActualCodecsAndColorsRepeatedRecording] : XCTUnwrap failed: expected non-nil value of type "URL"`

### FULL-20261024-021 — VideoColorPhysicalTests

- [x] **实际文件/像素/解码及增强基线后定向真机通过**：`VideoColorPhysicalTests/testAppleLogLUTBurnKeepsLogVideoTagsAndTenBitPixels()`
- 方法耗时：22.406 秒。
- 结果摘要：XCTAssertTrue failed - 相机暂时无法恢复，请点击重试重新连接。
- 原始断言（相同文本去重；行号为完整日志位置）：

  - 日志 8440：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VideoColorPhysicalTests.swift:177: error: -[LumaCameraTests.VideoColorPhysicalTests testAppleLogLUTBurnKeepsLogVideoTagsAndTenBitPixels] : XCTAssertTrue failed - 相机暂时无法恢复，请点击重试重新连接。`
  - 日志 8441：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VideoColorPhysicalTests.swift:182: error: -[LumaCameraTests.VideoColorPhysicalTests testAppleLogLUTBurnKeepsLogVideoTagsAndTenBitPixels] : XCTUnwrap failed: expected non-nil value of type "URL"`

### FULL-20261024-022 — VideoColorPhysicalTests

- [x] **实际文件/像素/解码及增强基线后定向真机通过**：`VideoColorPhysicalTests/testEveryAvailableColorSpaceRecordsRealTagsAndRestoresPhotos()`
- 方法耗时：26.976 秒。
- 结果摘要：XCTAssertTrue failed - mode=auto color=SDR before=ready=true busy=false configuring=false capturing=true pending=4: 相机暂时无法恢复，请点击重试重新连接。
- 原始断言（相同文本去重；行号为完整日志位置）：

  - 日志 8446：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VideoColorPhysicalTests.swift:89: error: -[LumaCameraTests.VideoColorPhysicalTests testEveryAvailableColorSpaceRecordsRealTagsAndRestoresPhotos] : XCTAssertTrue failed - mode=auto color=SDR before=ready=true busy=false configuring=false capturing=true pending=4: 相机暂时无法恢复，请点击重试重新连接。`
  - 日志 8447：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VideoColorPhysicalTests.swift:93: error: -[LumaCameraTests.VideoColorPhysicalTests testEveryAvailableColorSpaceRecordsRealTagsAndRestoresPhotos] : XCTUnwrap failed: expected non-nil value of type "URL"`

### FULL-20261024-023 — VideoColorPhysicalTests

- [x] **实际文件/像素/解码及增强基线后定向真机通过**：`VideoColorPhysicalTests/testSDRAndP3FiltersAreBakedIntoRecordedPixelsWithStableFrameDelivery()`
- 方法耗时：21.965 秒。
- 结果摘要：XCTAssertTrue failed - 相机暂时无法恢复，请点击重试重新连接。
- 原始断言（相同文本去重；行号为完整日志位置）：

  - 日志 8454：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VideoColorPhysicalTests.swift:255: error: -[LumaCameraTests.VideoColorPhysicalTests testSDRAndP3FiltersAreBakedIntoRecordedPixelsWithStableFrameDelivery] : XCTAssertTrue failed - 相机暂时无法恢复，请点击重试重新连接。`
  - 日志 8455：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VideoColorPhysicalTests.swift:259: error: -[LumaCameraTests.VideoColorPhysicalTests testSDRAndP3FiltersAreBakedIntoRecordedPixelsWithStableFrameDelivery] : XCTUnwrap failed: expected non-nil value of type "URL"`

### FULL-20261024-024 — VideoModeTransitionTests

- [x] **收尾/恢复修复后定向真机通过**：`VideoModeTransitionTests/testAutomaticVideoRouteRestoresPhotoFormatAndLensSwitching()`
- 方法耗时：15.915 秒。
- 结果摘要：XCTAssertTrue failed - 相机暂时无法恢复，请点击重试重新连接。
- 原始断言（相同文本去重；行号为完整日志位置）：

  - 日志 8626：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VideoModeTransitionTests.swift:66: error: -[LumaCameraTests.VideoModeTransitionTests testAutomaticVideoRouteRestoresPhotoFormatAndLensSwitching] : XCTAssertTrue failed - 相机暂时无法恢复，请点击重试重新连接。`
  - 日志 8627：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VideoModeTransitionTests.swift:70: error: -[LumaCameraTests.VideoModeTransitionTests testAutomaticVideoRouteRestoresPhotoFormatAndLensSwitching] : XCTUnwrap failed: expected non-nil value of type "URL"`

后续处理：已增加原生回调超时保护、唯一 token 终结、按序交付解堵及照片输出重建；真实人像/ProRAW/M挡和后续视频检查通过，另有漏回调与四请求注入恢复验证。系统内部未返图原因未确证。见[专项报告](2026-10-24-Portrait-Timeout-Recovery.md)。

### FULL-20261024-025 — VideoModeTransitionTests

- [x] **曝光同步加固后定向通过**：`VideoModeTransitionTests/testLiveHDRAndManualPhotoRoutesSurviveVideoRoundTrips()`
- 方法耗时：22.595 秒。
- 结果摘要：XCTAssertTrue failed - Video shutter must become ready for live
- 原始断言（相同文本去重；行号为完整日志位置）：

  - 日志 8630：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VideoModeTransitionTests.swift:198: error: -[LumaCameraTests.VideoModeTransitionTests testLiveHDRAndManualPhotoRoutesSurviveVideoRoundTrips] : XCTAssertTrue failed - Video shutter must become ready for live`
  - 日志 8631：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VideoModeTransitionTests.swift:201: error: -[LumaCameraTests.VideoModeTransitionTests testLiveHDRAndManualPhotoRoutesSurviveVideoRoundTrips] : XCTAssertTrue failed - variant=live: 相机暂时无法恢复，请点击重试重新连接。`
  - 日志 8632：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VideoModeTransitionTests.swift:206: error: -[LumaCameraTests.VideoModeTransitionTests testLiveHDRAndManualPhotoRoutesSurviveVideoRoundTrips] : XCTUnwrap failed: expected non-nil value of type "URL"`

后续处理：原独立基线通过；增强真实照片检查发现一次曝光不一致，普通 M 挡加入曝光完成回调等待。修复后5项相关方法通过，Live/HDR/M实际文件及快速反向切换核对通过，未改UI。见[专项记录](2026-10-24-LiveHDRManualRestore-Resolution.md)。

### FULL-20261024-026 — VideoSpecificationTests

- [x] **2026-10-25增强定向通过**：`VideoSpecificationTests/testAllSupportedVideoSpecificationsWriteMatchingTracks()`
- 方法耗时：24.328 秒。
- 结果摘要：XCTAssertTrue failed - 相机暂时无法恢复，请点击重试重新连接。
- 原始断言（相同文本去重；行号为完整日志位置）：

  - 日志 8725：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VideoSpecificationTests.swift:699: error: -[LumaCameraTests.VideoSpecificationTests testAllSupportedVideoSpecificationsWriteMatchingTracks] : XCTAssertTrue failed - 相机暂时无法恢复，请点击重试重新连接。`
  - 日志 8726：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VideoSpecificationTests.swift:703: error: -[LumaCameraTests.VideoSpecificationTests testAllSupportedVideoSpecificationsWriteMatchingTracks] : XCTUnwrap failed: expected non-nil value of type "URL"`

后续处理：按序增强真机通过，正式修复为白平衡阻塞与重定时反压；未据此确认历史所有系统内部故障原因。见[专项报告](2026-10-25-RemainingVideoFive-Resolution.md)。

### FULL-20261024-027 — VideoSpecificationTests

- [x] **高帧率与预览增强验证后定向通过**：`VideoSpecificationTests/testHighFrameRateAndFrontCameraRestoreSupportedSpecifications()`
- 方法耗时：21.237 秒。
- 结果摘要：XCTAssertFalse failed - This iPhone main camera should expose high-frame-rate SDR
- 原始断言（相同文本去重；行号为完整日志位置）：

  - 日志 8742：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VideoSpecificationTests.swift:614: error: -[LumaCameraTests.VideoSpecificationTests testHighFrameRateAndFrontCameraRestoreSupportedSpecifications] : XCTAssertFalse failed - This iPhone main camera should expose high-frame-rate SDR`
  - 日志 8744：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VideoSpecificationTests.swift:643: error: -[LumaCameraTests.VideoSpecificationTests testHighFrameRateAndFrontCameraRestoreSupportedSpecifications] : XCTAssertTrue failed - 相机暂时无法恢复，请点击重试重新连接。`
  - 日志 8745：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VideoSpecificationTests.swift:647: error: -[LumaCameraTests.VideoSpecificationTests testHighFrameRateAndFrontCameraRestoreSupportedSpecifications] : XCTUnwrap failed: expected non-nil value of type "URL"`

后续处理：独立基线通过；增强设备帧周期、真实新帧、文件完整解码PTS、前后往返及预览升降帧率恢复后通过。未改正式采集实现，不把当前通过写成历史系统内部根因确证。见[专项记录](2026-10-24-HighRatePreview-Resolution.md)。

### FULL-20261024-028 — VideoSpecificationTests

- [x] **2026-10-25增强定向通过**：`VideoSpecificationTests/testOpenGateSwitchRecordsOnlyFourByThreeOrSquareOnDevice()`
- 方法耗时：23.092 秒。
- 结果摘要：XCTAssertTrue failed - 相机暂时无法恢复，请点击重试重新连接。
- 原始断言（相同文本去重；行号为完整日志位置）：

  - 日志 8752：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VideoSpecificationTests.swift:573: error: -[LumaCameraTests.VideoSpecificationTests testOpenGateSwitchRecordsOnlyFourByThreeOrSquareOnDevice] : XCTAssertTrue failed - 相机暂时无法恢复，请点击重试重新连接。`
  - 日志 8753：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VideoSpecificationTests.swift:577: error: -[LumaCameraTests.VideoSpecificationTests testOpenGateSwitchRecordsOnlyFourByThreeOrSquareOnDevice] : XCTUnwrap failed: expected non-nil value of type "URL"`

后续处理：按序增强真机通过，正式修复为白平衡阻塞与重定时反压；未据此确认历史所有系统内部故障原因。见[专项报告](2026-10-25-RemainingVideoFive-Resolution.md)。

### FULL-20261024-029 — VideoSpecificationTests

- [x] **高帧率与预览增强验证后定向通过**：`VideoSpecificationTests/testRenderedVideoPreviewCadenceTracksSupportedRates()`
- 方法耗时：12.024 秒。
- 结果摘要：XCTAssertFalse failed - M mode should expose the available 120 fps SDR route on iPhone 17 Pro
- 原始断言（相同文本去重；行号为完整日志位置）：

  - 日志 8762：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VideoSpecificationTests.swift:502: error: -[LumaCameraTests.VideoSpecificationTests testRenderedVideoPreviewCadenceTracksSupportedRates] : XCTAssertFalse failed - M mode should expose the available 120 fps SDR route on iPhone 17 Pro`

后续处理：独立基线通过；增强设备帧周期、真实新帧、文件完整解码PTS、前后往返及预览升降帧率恢复后通过。未改正式采集实现，不把当前通过写成历史系统内部根因确证。见[专项记录](2026-10-24-HighRatePreview-Resolution.md)。

### FULL-20261024-030 — VideoSpecificationTests

- [x] **2026-10-25增强定向通过**：`VideoSpecificationTests/testSlowMotionAndCinematicRoutesOnDevice()`
- 方法耗时：21.376 秒。
- 结果摘要：XCTAssertTrue failed - 相机暂时无法恢复，请点击重试重新连接。
- 原始断言（相同文本去重；行号为完整日志位置）：

  - 日志 8788：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VideoSpecificationTests.swift:384: error: -[LumaCameraTests.VideoSpecificationTests testSlowMotionAndCinematicRoutesOnDevice] : XCTAssertTrue failed - 相机暂时无法恢复，请点击重试重新连接。`
  - 日志 8789：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VideoSpecificationTests.swift:391: error: -[LumaCameraTests.VideoSpecificationTests testSlowMotionAndCinematicRoutesOnDevice] : XCTUnwrap failed: expected non-nil value of type "URL" - Cinematic movie did not finish`

后续处理：按序增强真机通过，正式修复为白平衡阻塞与重定时反压；未据此确认历史所有系统内部故障原因。见[专项报告](2026-10-25-RemainingVideoFive-Resolution.md)。

### FULL-20261024-031 — VideoWhiteBalancePhysicalTests

- [x] **2026-10-25增强定向通过**：`VideoWhiteBalancePhysicalTests/testVideoWhiteBalanceLockIsOptionalAndRestoredAfterRecording()`
- 方法耗时：19.777 秒。
- 结果摘要：XCTAssertTrue failed - 相机暂时无法恢复，请点击重试重新连接。
- 原始断言（相同文本去重；行号为完整日志位置）：

  - 日志 8800：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VideoWhiteBalancePhysicalTests.swift:98: error: -[LumaCameraTests.VideoWhiteBalancePhysicalTests testVideoWhiteBalanceLockIsOptionalAndRestoredAfterRecording] : XCTAssertTrue failed - 相机暂时无法恢复，请点击重试重新连接。`
  - 日志 8801：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VideoWhiteBalancePhysicalTests.swift:99: error: -[LumaCameraTests.VideoWhiteBalancePhysicalTests testVideoWhiteBalanceLockIsOptionalAndRestoredAfterRecording] : XCTAssertLessThan failed: ("5.2271502500079805") is not less than ("3.0") - WB preference must not delay recording startup beyond 3 seconds`
  - 日志 8802：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VideoWhiteBalancePhysicalTests.swift:123: error: -[LumaCameraTests.VideoWhiteBalancePhysicalTests testVideoWhiteBalanceLockIsOptionalAndRestoredAfterRecording] : XCTUnwrap failed: expected non-nil value of type "URL" - Recording completion failed; lock=false`

后续处理：按序增强真机通过，正式修复为白平衡阻塞与重定时反压；未据此确认历史所有系统内部故障原因。见[专项报告](2026-10-25-RemainingVideoFive-Resolution.md)。

### FULL-20261024-032 — VideoWorkflowTests

- [x] **生命周期/启动取消加固后定向真机通过**：`VideoWorkflowTests/testLifecycleStopFreezesClockAndRapidModeRequestsCoalesce()`
- 方法耗时：15.880 秒。
- 结果摘要：XCTAssertTrue failed
- 原始断言（相同文本去重；行号为完整日志位置）：

  - 日志 8828：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VideoWorkflowTests.swift:501: error: -[LumaCameraTests.VideoWorkflowTests testLifecycleStopFreezesClockAndRapidModeRequestsCoalesce] : XCTAssertTrue failed`
  - 日志 8829：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VideoWorkflowTests.swift:505: error: -[LumaCameraTests.VideoWorkflowTests testLifecycleStopFreezesClockAndRapidModeRequestsCoalesce] : XCTAssertTrue failed`
  - 日志 8830：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VideoWorkflowTests.swift:507: error: -[LumaCameraTests.VideoWorkflowTests testLifecycleStopFreezesClockAndRapidModeRequestsCoalesce] : XCTUnwrap failed: expected non-nil value of type "URL"`

后续处理：独立原用例通过；增强300次请求、三轮退出/恢复、实际文件解码与计时检查通过。另修复白平衡启动等待取消漏回调/busy残留，迟到回调及重复停止不会覆盖新请求。修复后4个不同相关方法通过；未据此确认原历史系统错误内部原因。见[专项记录](2026-10-24-VideoLifecycle-Resolution.md)。

### FULL-20261024-033 — ZoomWheelReopenPhysicalTests

- [x] **测试基线修正后定向真机通过**：`ZoomWheelReopenPhysicalTests/testReopeningKeepsActualZoomAndAnchorAcrossBothModes()`
- 方法耗时：1.707 秒。
- 结果摘要：XCTAssertLessThan failed: ("1.0") is not less than ("1.0")
- 原始断言（相同文本去重；行号为完整日志位置）：

  - 日志 8910：`/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/ZoomWheelReopenPhysicalTests.swift:37: error: -[LumaCameraTests.ZoomWheelReopenPhysicalTests testReopeningKeepsActualZoomAndAnchorAcrossBothModes] : XCTAssertLessThan failed: ("1.0") is not less than ("1.0")`

## 运行时错误与构建警告

- XCTest 文本汇总为 133 条 failure（其中 8 条 unexpected），对应 xcresult 中 **33 个失败方法**；这两种计数口径不同，不将 133 条断言记成 133 个独立缺陷。全部失败方法和断言见上表与 JSON。

- 带错误对象的相机会话通知共 6 条：其中 5 条由恢复测试主动注入，不记为真实新增会话故障；其余 1 条发生在冷启动恢复用例。

- 日志 1305，预期注入，`CameraSessionRecoveryTests/testReportedRuntimeErrorsRecoverAndCannotRestartAfterExit()`：`2026-10-24 12:38:20.326793+0800 LumaCamera[5466:1901163] Camera capture session runtime error: AVFoundationErrorDomain (-11800): The operation couldn’t be completed. (AVFoundationErrorDomain error -11800.) userInfo=["NSUnderlyingError": Error Domain=NSOSStatusErrorDomain Code=-12780 "(null)"]`
- 日志 1339，预期注入，`CameraSessionRecoveryTests/testReportedRuntimeErrorsRecoverAndCannotRestartAfterExit()`：`2026-10-24 12:38:20.336238+0800 LumaCamera[5466:1901163] Camera capture session runtime error: AVFoundationErrorDomain (-11819): The operation couldn’t be completed. (AVFoundationErrorDomain error -11819.) userInfo=[:]`
- 日志 1373，预期注入，`CameraSessionRecoveryTests/testReportedRuntimeErrorsRecoverAndCannotRestartAfterExit()`：`2026-10-24 12:38:20.958305+0800 LumaCamera[5466:1901163] Camera capture session runtime error: AVFoundationErrorDomain (-11800): The operation couldn’t be completed. (AVFoundationErrorDomain error -11800.) userInfo=["NSUnderlyingError": Error Domain=NSOSStatusErrorDomain Code=-12780 "(null)"]`
- 日志 1374，预期注入，`CameraSessionRecoveryTests/testReportedRuntimeErrorsRecoverAndCannotRestartAfterExit()`：`2026-10-24 12:38:20.958409+0800 LumaCamera[5466:1901163] Camera capture session runtime error: AVFoundationErrorDomain (-11819): The operation couldn’t be completed. (AVFoundationErrorDomain error -11819.) userInfo=[:]`
- 日志 1375，预期注入，`CameraSessionRecoveryTests/testReportedRuntimeErrorsRecoverAndCannotRestartAfterExit()`：`2026-10-24 12:38:20.958428+0800 LumaCamera[5466:1901163] Camera capture session runtime error: AVFoundationErrorDomain (-11819): The operation couldn’t be completed. (AVFoundationErrorDomain error -11819.) userInfo=[:]`
- 日志 1977，非注入，待查，`CaptureStatePhysicalTests/testColdRestorationAppliesManualValuesToRealLensAndVideoPipeline()`：`2026-10-24 12:39:36.790200+0800 LumaCamera[5466:1901163] Camera capture session runtime error: AVFoundationErrorDomain (-11819): Cannot Complete Action userInfo=["NSLocalizedRecoverySuggestion": Try again later., "NSLocalizedDescription": Cannot Complete Action]`

- `MDB_MAP_FULL` 缓存日志出现 1766 次；未确认对应缓存归属或是否影响功能，单独待查。
- 未见 `Publishing changes from within view updates` 日志；xcresult runtimeWarnings 为空不代表没有其他运行时问题。
- 构建含测试代码 Sendable 捕获警告（FrontNativeFramingDiagnosticTests）、未使用变量警告（PopupAppearanceAndOrientationTests），以及 App Intents 元数据提取提示；本轮均未改动。

## 性能与稳定性观测

- A/M 切换 8 次：按钮调用至新预览发布约 1.00–1.29 秒，遮罩退出约 1.18–1.47 秒；是测试观测时间，不是显示扫描延迟。
- 受控夜景 5 次：实际融合 3/6/9/6/9 帧，耗时 1.242/2.845/3.878/2.814/4.106 秒。运动停止追加、提交第二批后取消、返回普通拍摄路径通过。自然触发夜景因当前环境不足跳过，不能写成自然暗光验证通过。
- 夜景固定 320×240 夹具 12 次：中位 98.1 ms、P95 103.7 ms；3/6/9 帧各 1200 个像素样本与原配方基线最大码值差 0。该绘制耗时不是预览 FPS 或全尺寸出片耗时。
- 光轨：旧路径 48.506 秒；优化路径 13.900/12.261/12.174 秒。完整星轨 120 帧用例 155.585 秒通过。其他原始指标见下方。
- 测试覆盖重复点按、快速切换、取消/提前完成、后台/返回及恢复路径；其中失败路径按上表保留，不能据部分通过宣称整体稳定。
- XCTest 内存指标包含测试宿主、夹具及缓存；不作为正式 App 内存或节能量。未测电池功耗、热成像或真实屏幕帧率。

后续处理：独立相机基线、真实出帧与设备倍率检查补齐；24 次切镜、6 次重开及两次拖动后重开通过。未改产品代码，原共享会话问题未定位。见[专项报告](2026-10-24-PresetZoom-Resolution.md)。

### 原始性能指标摘录

```text
RUNTIME-RECOVERY-INJECTED samples=4 p50=0.10698350000893697 max=0.5384063750097994 fresh-frame=true noPhotosWrites=true
FLIP-SPEED index=0 to=1 fresh=0.48470000000088476 visible=0.6098303750040941
FLIP-SPEED index=1 to=2 fresh=0.6032355833303882 visible=0.7737694999959785
FLIP-SPEED index=2 to=1 fresh=0.48761912500776816 visible=0.6170442916627508
FLIP-SPEED index=3 to=2 fresh=0.5755394583393354 visible=0.7476035416621016
FLIP-SPEED index=4 to=1 fresh=0.4571375000086846 visible=0.585468083343585
FLIP-SPEED index=5 to=2 fresh=0.5753250833367929 visible=0.7478575833374634
FLIP-SPEED index=6 to=1 fresh=0.6081013750081183 visible=0.7423008333425969
FLIP-SPEED index=7 to=2 fresh=0.5724437083408702 visible=0.7437968750018626
MODE-LATENCY 0 manual frame=1.0042079999984708 overlay=1.182162208322552 maxGap=0.9425471249996917
MODE-LATENCY 1 auto frame=1.2446084999974119 overlay=1.418622958328342 maxGap=0.6191728333214996
MODE-LATENCY 2 manual frame=1.1525844583375147 overlay=1.3403608749940759 maxGap=1.1042107499961276
MODE-LATENCY 3 auto frame=1.2537708333256887 overlay=1.433494333323324 maxGap=0.6263179583329475
MODE-LATENCY 4 manual frame=1.1597859999892535 overlay=1.3431973333208589 maxGap=1.105972416655277
MODE-LATENCY 5 auto frame=1.2734785833308706 overlay=1.4577889583306387 maxGap=0.6500834166799905
MODE-LATENCY 6 manual frame=1.132684333337238 overlay=1.3049436666624388 maxGap=1.0754103749932256
MODE-LATENCY 7 auto frame=1.2917180416698102 overlay=1.4730520416633226 maxGap=0.6156916249892674
NIGHT-ADAPTIVE-STABILITY motion-stops-at=3 cancel-at-submitted=6 cancelled-deliveries=0 ordinary-return=true
NIGHT-ADAPTIVE target=3 captured=3 帧 merged=3 batches=[3] seconds=1.2419842916715425 hostFootprintMiB=676.8167037963867 injected-scene=true
NIGHT-ADAPTIVE target=6 captured=6 帧 merged=6 batches=[3, 6] seconds=2.8445162499992875 hostFootprintMiB=811.5667266845703 injected-scene=true
NIGHT-ADAPTIVE target=9 captured=9 帧 merged=9 batches=[3, 6, 9] seconds=3.878459125000518 hostFootprintMiB=851.7386016845703 injected-scene=true
NIGHT-ADAPTIVE target=6 captured=6 帧 merged=6 batches=[3, 6] seconds=2.8135935833270196 hostFootprintMiB=851.7386016845703 injected-scene=true
NIGHT-ADAPTIVE target=9 captured=9 帧 merged=9 batches=[3, 6, 9] seconds=4.105896541674156 hostFootprintMiB=851.7386016845703 injected-scene=true
NIGHT-RENDER fixture=320x240 n=12 median-seconds=0.09814495833416004 p95=0.10373729167622514; includes CPU masks and CI render; not preview FPS/full-resolution latency
NIGHT-PIXEL-PARITY frames=3 samples=1200 maxCodeDifference=0
NIGHT-PIXEL-PARITY frames=6 samples=1200 maxCodeDifference=0
NIGHT-PIXEL-PARITY frames=9 samples=1200 maxCodeDifference=0
/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/PhotoOptionsTests.swift:149: Test Case '-[LumaCameraTests.PhotoOptionsTests testNightEnvironmentGateRepeatedReadingsPerformance]' measured [Clock Monotonic Time, s] average: 0.002, relative standard deviation: 11.314%, values: [0.001545, 0.001462, 0.001823, 0.001964, 0.001567], performanceMetricID:com.apple.dt.XCTMetric_Clock.time.monotonic, baselineName: "", baselineAverage: , polarity: prefers smaller, maxPercentRegression: 10.000%, maxPercentRelativeStandardDeviation: 10.000%, maxRegression: 0.000, maxStandardDeviation: 0.000
/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/PopupAppearanceAndOrientationTests.swift:238: Test Case '-[LumaCameraTests.PopupAppearanceAndOrientationTests testParameterSheetDrawPerformance]' measured [Clock Monotonic Time, s] average: 0.084, relative standard deviation: 15.541%, values: [0.070095, 0.071703, 0.078483, 0.100929, 0.097645], performanceMetricID:com.apple.dt.XCTMetric_Clock.time.monotonic, baselineName: "", baselineAverage: , polarity: prefers smaller, maxPercentRegression: 10.000%, maxPercentRelativeStandardDeviation: 10.000%, maxRegression: 0.000, maxStandardDeviation: 0.000
/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/PopupAppearanceAndOrientationTests.swift:24: Test Case '-[LumaCameraTests.PopupAppearanceAndOrientationTests testPopupGlassDrawPerformance]' measured [Clock Monotonic Time, s] average: 0.067, relative standard deviation: 15.620%, values: [0.058976, 0.057016, 0.060554, 0.083807, 0.074733], performanceMetricID:com.apple.dt.XCTMetric_Clock.time.monotonic, baselineName: "", baselineAverage: , polarity: prefers smaller, maxPercentRegression: 10.000%, maxPercentRelativeStandardDeviation: 10.000%, maxRegression: 0.000, maxStandardDeviation: 0.000
/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/PopupAppearanceAndOrientationTests.swift:41: Test Case '-[LumaCameraTests.PopupAppearanceAndOrientationTests testPopupOrientationSwitchDrawPerformance]' measured [Clock Monotonic Time, s] average: 0.111, relative standard deviation: 11.553%, values: [0.088075, 0.105887, 0.121270, 0.119048, 0.121071], performanceMetricID:com.apple.dt.XCTMetric_Clock.time.monotonic, baselineName: "", baselineAverage: , polarity: prefers smaller, maxPercentRegression: 10.000%, maxPercentRelativeStandardDeviation: 10.000%, maxRegression: 0.000, maxStandardDeviation: 0.000
/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/PopupAppearanceAndOrientationTests.swift:319: Test Case '-[LumaCameraTests.PopupAppearanceAndOrientationTests testTopToolbarPopupDrawPerformance]' measured [Clock Monotonic Time, s] average: 0.086, relative standard deviation: 4.664%, values: [0.085450, 0.085182, 0.082531, 0.084787, 0.094229], performanceMetricID:com.apple.dt.XCTMetric_Clock.time.monotonic, baselineName: "", baselineAverage: , polarity: prefers smaller, maxPercentRegression: 10.000%, maxPercentRelativeStandardDeviation: 10.000%, maxRegression: 0.000, maxStandardDeviation: 0.000
SLOW-SPEED preset=lightTrails baseline=[48.505912583335885] optimized=[13.899624208337627, 12.261008500005119, 12.17394758334558]
SLOW-SPEED preset=silkyWater baseline=[37.57619274999888] optimized=[11.931749916664558, 10.502640000006068, 12.667130791669479]
SLOW-SPEED preset=motionBlur baseline=[6.1808260416582925] optimized=[3.177141833337373, 3.17798187500739, 3.066905333340401]
SLOW-PANNING-SPEED assist=false oldPath=true seconds=[0.5259480833337875, 0.21003295831906144, 0.3191462916583987]
SLOW-PANNING-SPEED assist=false oldPath=false seconds=[0.2655442916729953, 0.2647223333333386, 0.3147000416647643]
SLOW-PANNING-SPEED assist=true oldPath=true seconds=[0.5828083749947837, 0.8915645416709594, 0.9021352499985369]
SLOW-PANNING-SPEED assist=true oldPath=false seconds=[0.31727349999709986, 0.3187596250063507, 0.3179960833367659]
SLOW-STREAM-ALGORITHM samples=120 size=128x32 seconds=0.049243125002249144
/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Imaging/VideoFrameFilterRendererTests.swift:59: Test Case '-[LumaCameraTests.VideoFrameFilterRendererTests testFoodCubeRendersThirty640pFramesForPerformanceSample]' measured [Clock Monotonic Time, s] average: 0.018, relative standard deviation: 8.535%, values: [0.016310, 0.020143, 0.016369, 0.016497, 0.018184], performanceMetricID:com.apple.dt.XCTMetric_Clock.time.monotonic, baselineName: "", baselineAverage: , polarity: prefers smaller, maxPercentRegression: 10.000%, maxPercentRelativeStandardDeviation: 10.000%, maxRegression: 0.000, maxStandardDeviation: 0.000
```

## 跳过与未覆盖

运行时跳过 7 项（不计为通过）：

- `CameraRulerMappingTests/testAMToToolsDoesNotMovePreviewForAnyRatio()`：Layout regression is exercised in the simulator
- `CameraSessionRecoveryTests/testTemporaryInterruptionIsSilentAndEndedCannotRestartStoppedCamera()`：Use the shared visible engine for physical recovery tests
- `NightAdaptiveCapturePhysicalTests/testNaturallyTriggeredNightUsesActualMeteringAndFrameCount()`：实际场景尚未触发夜景，不能记成自然触发通过
- `PopupAppearanceAndOrientationTests/testPopupOpenCloseDuringOrientationChangesRemainsResponsive()`：Full camera UI stress runs in the simulator; the device runs the harness orientation stress
- `SlowShutterPresetTests/testAutomaticModeKeepsApertureModeAndPresetOnlyCapsAutomaticExposure()`：Requires a live camera route; A-mode cap policy is covered by the model tests
- `SlowShutterPresetTests/testSelectingPresetsConstrainsManualExposureAndRepeatedTogglingClearsState()`：Requires a live camera route; range/support logic is covered above
- `ToolbarHistogramLayoutTests/testAllRatioTransitionsKeepToolbarFixedAndHistogramClear()`：Ratio layout is tested in simulator

命令显式排除（不计入上述 7 项）：

- `LiveAudioSavePhysicalTests`
- `SystemGalleryRefreshTests`
- `BasicVideoSaveIntegrationTests`
- `LivePhotoSaveIntegrationTests`
- `CommittedGallerySaveIntegrationTests`
- `FocusLockModeTests`
- `ProResRAWPhysicalTests/testRealSensorRAWAndRAWHQStorageCompatibility`
- `FrontPhotoAspectRatioPhysicalTests/testRealLandscapeToPortraitThenAspectFraming`

前五类包含真实 Photos 写入/删除；FocusLockModeTests 构造真实相册服务而保守排除。外接盘 RAW/RAW HQ 实录、真实删除授权交互、指定横拿→竖拿姿态未测试；其他临时文件、内存相册及元数据测试仍在范围内。人物复杂边缘、主观虚化质量和真实手持微距行为不由自动用例保证。

## 执行说明

- 首次命令误用了重试选项的参数格式，未启动测试；随后命令因已有空结果目录退出，也未启动测试。修正启动命令、换用 Run1 结果目录后只执行了本次一轮；没有测试失败项重跑。
- 测试结束后仅重新构建、安装正常签名的普通 App，恢复日常运行版本；不代表失败功能已经恢复或通过。

## 后续定向处理（2026-10-24）

用户要求先处理画幅量化与慢门布局两项；005、018 测试修正后真机 2 项通过。其余 31 个失败方法本轮未处理、未复测。原始全量 489/33/7 统计不变，详见[专项记录](2026-10-24-EasyTwo-Resolution.md)。

### 慢门预设与变焦轮后续定向处理

019、033 测试基线及硬件观测前提修正后真机 2 项通过；连同此前 005、018，共四个失败方法定向通过。其他 29 个失败方法未处理、未复测；原始全量统计不变。见[专项报告](2026-10-24-PresetZoom-Resolution.md)。

### 前置三项后续处理

002、003、004 已定向通过，含实际横拿成片侧转修复及文件/内容验收；当前累计七个原失败方法定向通过，其他 26 项未处理、未复测。历史全量 489/33/7 不改写。详见[专项报告](2026-10-24-FrontThree-Resolution.md)。

### 人像超时与任务占用后续处理

007、009、024 已经定向真机通过；原生无最终回调时的永久占用链路已修复并注入验证。累计十个原失败方法定向通过，其他 23 项未处理/未复测；原全量统计不变。见[专项报告](2026-10-24-Portrait-Timeout-Recovery.md)。

### 冷启动手动设置恢复后续处理

001 定向通过：修正测试跨主队列/相机队列的停机等待与异常清理，9 次新模型启动和相关恢复共 10 方法通过，正常操作无运行错误；未改生产参数，历史 -11819 内部原因未确认。累计 11 个原失败方法定向通过，其余 22 项未处理/未复测。见[专项记录](2026-10-24-ColdRestore-Resolution.md)。

### 预览尺寸后续处理

006 原断言在前后切镜阶段将合法前置横幅当异常，并非 M→A 阶段尺寸失败。修正实际新帧/构图检查，另在七画幅回归中定位并修复前置横幅切 1:1 后新帧过滤错误。最终 8 方法真机通过；累计 12 项原失败方法通过，其余 21 项未处理/未复测。见[专项记录](2026-10-24-ModePreviewSize-Resolution.md)。

### 预览辅助三项后续处理

012/013/014独立运行和增强回归均通过，补充JPEG/HEIF实际EXIF与恢复、拍摄中关闭等检查；另复现并修复辅助偏好影响视频M挡实际曝光的问题。最终5方法真机通过，累计15个原失败方法通过，其余18项未处理/未复测。A挡自然暗光本轮未安排，触发函数为固定输入。见[专项记录](2026-10-24-PreviewAssist-Resolution.md)。

### 人像三项后续验收

008/010/011真实人物场景及增强拍后清空/退出新帧/同帧EXIF检查通过，原片/结果已目视核对。3硬件+8渲染/状态方法有通过记录，中间无人物/微距轮失败保留。累计18个原失败方法通过，其余15项未处理/未复测。见[专项记录](2026-10-24-PortraitThree-Resolution.md)。

### HDR HEIF Pro影调后续验收

015真实四种影调正反8次拍摄、PQ/位深/EXIF/任务清空/退出恢复及HDR固定夹具像素回归通过，共6相关方法。原超时未复现，未改生产算法。累计19个原失败方法有通过记录，其余14项未处理/未复测。见[专项记录](2026-10-24-ProToneHDR-Resolution.md)。

### 静音快门后续处理

016普通/Live10次增强复测通过，原积压未复现；另复现并修复夜景批次静音遗漏，6帧两批及中途改偏好、退出返回验证通过。3个不同方法有通过记录，验证系统设置未测声音。累计20个原失败方法通过，其余13项未处理/未复测。见[专项记录](2026-10-24-SilentShutter-Resolution.md)。

### 视频编码与色彩四项后续验收

020/021/022/023独立基线及增强录制验证通过。9相关方法、39段临时视频、10次照片恢复，包含完整解码PTS帧率和Log1/2仅预览/烧录像素对照；未改生产录制。累计24个原失败方法通过，其余9项未处理/未复测，原全量统计不改。见[专项记录](2026-10-24-VideoCodecColor-Resolution.md)。
