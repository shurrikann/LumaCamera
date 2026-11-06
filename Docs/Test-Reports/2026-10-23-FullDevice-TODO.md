# 2026-10-23 真机全量测试：独立待办清单

> 本文件独立保留今日全量运行及后续修复状态，不合并此前待办。原始 494 项结果保持不变；用户随后要求修复，最新处理结果见各条及文末。

## 本次结果

- 设备：iPhone 17 Pro，iOS 27.0.1（24A446），正常项目签名；真机单设备串行执行。
- 时间：2026-10-23 17:41:25 至 2026-10-23 18:05:16（Asia/Shanghai），结果包时间窗口约 1430.6 秒。
- XCTest 汇总：**494 项，469 通过、19 失败、6 跳过；整体结果 Failed**。失败数按测试方法，不按重复断言条数。
- 发生一次测试进程被 kill，Xcode 自动恢复进程并续跑剩余用例；没有人工重跑失败项，没有修改生产代码或测试代码。仅凭 kill 不能确认内存不足、看门狗或其他根因。
- 结果包：`/private/tmp/LumaCamera-FullDevice-20261023-RecordOnly.xcresult`；原始日志：`/private/tmp/LumaCamera-FullDevice-20261023-RecordOnly.log`。
- 本清单与同目录 JSON 保留失败摘要和断言，不依赖临时目录永久存在；完整结果包及原始日志仍在临时目录。
- 未向系统相册写入或删除诊断媒体；未启动/操作模拟器，未使用镜像。

## 范围与排除项

以下选择器在命令中显式排除，**不计入上面的 6 项运行时跳过**：

- `LiveAudioSavePhysicalTests`
- `SystemGalleryRefreshTests`
- `BasicVideoSaveIntegrationTests`
- `LivePhotoSaveIntegrationTests`
- `CommittedGallerySaveIntegrationTests`
- `FocusLockModeTests`
- `ProResRAWPhysicalTests/testRealSensorRAWAndRAWHQStorageCompatibility`
- `FrontPhotoAspectRatioPhysicalTests/testRealLandscapeToPortraitThenAspectFraming`

前五类含真实 Photos 写入/删除集成；部分本就只在模拟器编译。FocusLockModeTests 因构造真实相册服务而保守排除，不声称其中一定会执行写入。外接 RAW 实录和需用户配合姿态的测试未执行。临时文件、相册替身、RAW 锁定后元数据查询仍在本次范围内。

## 本次失败待办

以下原始断言保留作历史证据；处理状态区分产品修复、平台契约与测试前提修正。通过是对应定向真机用例通过，不代表全部场景保证。

### FULL-20261023-001 — A/M、前后切换后的近距回退能力断言

- [x] 已处理，定向真机通过：`AutomaticLensStabilityPhysicalTests/testAutomaticRouteRestoresAfterModeAndFrontSwitches()`

- 处理分类：产品修复
- 处理说明：A/M 路线通过连续变焦路径重建后，最终提交会重置 fallback；在提交后恢复系统 supportedFallbackPrimaryConstituentDevices 全集。移除把临时子集缓存为默认的逻辑；依旧由系统 .auto 选择镜头，无距离阈值、定时重对焦或切镜动画。

- 结果摘要：`XCTAssertTrue failed - Normal close-focus fallback must remain available`
- 日志断言（重复内容去重）：
  - `/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/AutomaticLensStabilityPhysicalTests.swift:83: XCTAssertTrue failed - Normal close-focus fallback must remain available`
  - `/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/AutomaticLensStabilityPhysicalTests.swift:102: XCTAssertTrue failed - Normal close-focus fallback must remain available`

### FULL-20261023-002 — 录像期间系统触感许可断言

- [x] 已处理，定向真机通过：`BasicVideoPhysicalTests/testRepeatedVideoRecordingsAndPhotoModeReturn()`

- 处理分类：产品修复
- 处理说明：录像触感许可移至照片/视频最外层事务提交完成后恢复，保留系统自动音频路由。

- 结果摘要：`XCTAssertTrue failed - Video preview with microphone input must allow level and button haptics`
- 日志断言（重复内容去重）：
  - `/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/BasicVideoPhysicalTests.swift:144: XCTAssertTrue failed - Video preview with microphone input must allow level and button haptics`
  - `/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/BasicVideoPhysicalTests.swift:165: XCTAssertTrue failed - Recording must retain the system haptics permission`

### FULL-20261023-003 — 延时录像未启动、未返回临时文件

- [x] 已处理，定向真机通过：`BasicVideoPhysicalTests/testTimeLapseRecordingCreatesSparseSilentMovie()`

- 处理分类：测试前提修正
- 处理说明：延时开关会异步准备规格，原测试在 videoConfiguring 时提前按快门；现在等待与 UI 快门一致的就绪状态，再核对实际无声延时文件。

- 结果摘要：`XCTAssertTrue failed - 延时视频未开始`
- 日志断言（重复内容去重）：
  - `/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/BasicVideoPhysicalTests.swift:68: XCTAssertTrue failed - 延时视频未开始`
  - `/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/BasicVideoPhysicalTests.swift:76: XCTUnwrap failed: expected non-nil value of type "URL"`

### FULL-20261023-004 — 前置横幅预览垂直居中位置

- [x] 已处理，定向真机通过：`CameraPreviewLayoutTests/testLandscapeSelfieRatiosStayInsidePreviewAndCenterVertically()`

- 处理分类：测试预期修正
- 处理说明：方形与 4:3 都保留顶部 62 点避让，横幅居中断言补上方形；没有改变页面布局。

- 结果摘要：`XCTAssertEqualWithAccuracy failed: ("361.0") is not equal to ("330.0") +/- ("0.01")`
- 日志断言（重复内容去重）：
  - `/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/CameraPreviewLayoutTests.swift:29: XCTAssertEqualWithAccuracy failed: ("361.0") is not equal to ("330.0") +/- ("0.01")`
  - `/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/CameraPreviewLayoutTests.swift:29: XCTAssertEqualWithAccuracy failed: ("292.0") is not equal to ("261.0") +/- ("0.01")`
  - `/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/CameraPreviewLayoutTests.swift:29: XCTAssertEqualWithAccuracy failed: ("387.0") is not equal to ("356.0") +/- ("0.01")`

### FULL-20261023-005 — 照片/视频画幅矩阵中的视频文件比例

- [x] 已处理，定向真机通过：`CinemaAspectRatioTests/testPhoto239AndAllVideoRatiosHaveMatchingFileDimensions()`

- 处理分类：测试范围修正
- 处理说明：普通视频画幅使用 aspectOptions，不把需独立开启采集规格的 Open Gate 当作普通裁切；额外运行真实 Open Gate 4:3/1:1 录制检查。

- 结果摘要：`XCTAssertEqualWithAccuracy failed: ("0.5625") is not equal to ("0.75") +/- ("0.003")`
- 日志断言（重复内容去重）：
  - `/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/CinemaAspectRatioTests.swift:80: XCTAssertEqualWithAccuracy failed: ("0.5625") is not equal to ("0.75") +/- ("0.003")`

### FULL-20261023-006 — 前置宽窄取景跟随当前方向

- [x] 已处理，定向真机通过：`FrontWideSelectionTests/testCurrentOrientationFramingAndRecordingGuard()`

- 处理分类：测试隔离修正
- 处理说明：复用唯一可见引擎，清除上个测试的内存拍摄规格；保留同方向不覆盖手动宽窄取景、录制中不自动换构图的规则。

- 结果摘要：`XCTAssertEqual failed: ("com.apple.avfoundation.avcapturedevice.built-in_video:8:1.6000") is not equal to ("com.apple.avfoundation.avcapturedevice.built-in_video:8:1.0000") - Front framing should match the device's current orientation`
- 日志断言（重复内容去重）：
  - `/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/FrontWideSelectionTests.swift:64: XCTAssertEqual failed: ("com.apple.avfoundation.avcapturedevice.built-in_video:8:1.6000") is not equal to ("com.apple.avfoundation.avcapturedevice.built-in_video:8:1.0000") - Front framing should match the device's current orientation`

### FULL-20261023-007 — 前置原始与最终照片的宽高方向断言

- [x] 已处理，定向真机通过：`FrontWideSelectionTests/testFrontPhotoFilesKeepUprightPixelsAndSystemFocalLengths()`

- 处理分类：测试前提与元数据契约修正
- 处理说明：显式选择竖幅，避免继承合法横幅；系统普通前置可返回 30/31mm，最终文件必须精确保留原始文件的真实焦距和方向，不伪写为 31mm。

- 结果摘要：`XCTAssertGreaterThan failed: ("3024.0") is not greater than ("4032.0")`
- 日志断言（重复内容去重）：
  - `/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/FrontWideSelectionTests.swift:409: XCTAssertGreaterThan failed: ("3024.0") is not greater than ("4032.0")`
  - `/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/FrontWideSelectionTests.swift:422: XCTAssertGreaterThan failed: ("3000.0") is not greater than ("4000.0")`

### FULL-20261023-008 — 前置手动曝光/镜像捕获的预览宽高断言

- [x] 已处理，定向真机通过：`FrontWideSelectionTests/testFrontSwitchManualExposureMirrorCaptureAndCancellation()`

- 处理分类：测试前提修正
- 处理说明：显式关闭前置横幅后再检查竖幅预览；继续核对手动曝光、实际倍率、镜像捕获及取消。

- 结果摘要：`XCTAssertGreaterThan failed: ("1800.0") is not greater than ("2400.0")`
- 日志断言（重复内容去重）：
  - `/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/FrontWideSelectionTests.swift:361: XCTAssertGreaterThan failed: ("1800.0") is not greater than ("2400.0")`

### FULL-20261023-009 — 前置宽窄箭头符号存在性

- [x] 已处理，定向真机通过：`FrontWideSelectionTests/testFrontWideArrowSymbolsExist()`

- 处理分类：测试符号修正
- 处理说明：移除不存在的 rectangle.landscape 符号预期，使用有效 rectangle；未改按钮视觉样式。

- 结果摘要：`XCTAssertNotNil failed`
- 日志断言（重复内容去重）：
  - `/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/FrontWideSelectionTests.swift:17: XCTAssertNotNil failed`

### FULL-20261023-010 — 横幅裁切比例误差

- [x] 已处理，定向真机通过：`ImagingTests/testLandscapeCropsAreReciprocalAndStayInsideSource()`

- 处理分类：产品修复
- 处理说明：画幅裁切预先选择源图内的整数像素尺寸与居中位置，避免 Core Image 两侧向外取整放大比例误差。测试按最多半像素居中和尺寸量化误差判断。

- 结果摘要：`XCTAssertEqualWithAccuracy failed: ("2.380952380952381") is not equal to ("2.39") +/- ("0.0039682738095238096")`
- 日志断言（重复内容去重）：
  - `/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Imaging/ImagingTests.swift:28: XCTAssertEqualWithAccuracy failed: ("2.380952380952381") is not equal to ("2.39") +/- ("0.0039682738095238096")`
  - `/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Imaging/ImagingTests.swift:28: XCTAssertEqualWithAccuracy failed: ("2.7027027027027026") is not equal to ("2.708333333333333") +/- ("0.004504527027027027")`

### FULL-20261023-011 — 横幅渲染比例误差

- [x] 已处理，定向真机通过：`ImagingTests/testLandscapeLookRendersTheRequestedOrientation()`

- 处理分类：产品修复
- 处理说明：共用整数像素裁切，核对真实渲染后的横幅方向与比例，不靠拉伸纠正比例。

- 结果摘要：`XCTAssertEqualWithAccuracy failed: ("1.7716535433070866") is not equal to ("1.7777777777777777") +/- ("0.002")`
- 日志断言（重复内容去重）：
  - `/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Imaging/ImagingTests.swift:72: XCTAssertEqualWithAccuracy failed: ("1.7716535433070866") is not equal to ("1.7777777777777777") +/- ("0.002")`
  - `/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Imaging/ImagingTests.swift:72: XCTAssertEqualWithAccuracy failed: ("2.380952380952381") is not equal to ("2.39") +/- ("0.002")`
  - `/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Imaging/ImagingTests.swift:72: XCTAssertEqualWithAccuracy failed: ("2.694610778443114") is not equal to ("2.708333333333333") +/- ("0.002")`

### FULL-20261023-012 — 切换挡位后未取得恢复的预览帧

- [x] 已处理，定向真机通过：`ModeSwitchLatencyTests/testModeSwitchFrameAndOverlayLatencyOnDevice()`

- 处理分类：测试观测修正
- 处理说明：用最终路线帧代次记录首帧，不再等待被刻意保留的预览先变 nil；增加切换期间不清空预览的断言。

- 结果摘要：`XCTAssertNotNil failed - Live frames must resume after route change`
- 日志断言（重复内容去重）：
  - `/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/ModeSwitchLatencyTests.swift:51: XCTAssertNotNil failed - Live frames must resume after route change`

### FULL-20261023-013 — 人像 HEIF 高像素输出不足预期 40MP

- [x] 已处理，定向真机通过：`PortraitCapturePhysicalTests/testPortraitProcessedAndProRAWCapturesWithoutSaving()`

- 处理分类：平台契约校正及尺寸刷新
- 处理说明：逐张确认活动格式尺寸缓存，验证高像素确实请求 8064×6048；Apple maxPhotoDimensions 是上限，允许系统交付较小文件。HEIF 编码需保留系统实际交付的像素量，DNG 原样保留。远景场景实际重复获得 48MP；近距 A 挡超时另列，未宣称修复。

- 结果摘要：`XCTAssertGreaterThanOrEqual failed: ("12192768") is less than ("40000000") - Portrait HEIF should retain 48MP on the active M route.`
- 日志断言（重复内容去重）：
  - `/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/PortraitCapturePhysicalTests.swift:236: XCTAssertGreaterThanOrEqual failed: ("12192768") is less than ("40000000") - Portrait HEIF should retain 48MP on the active M route.`
  - `/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/PortraitCapturePhysicalTests.swift:265: XCTAssertGreaterThanOrEqual failed: ("12192768") is less than ("40000000")`

### FULL-20261023-014 — 人像预览蒙版边缘处理输出未改变

- [x] 已处理，定向真机通过：`PortraitDepthControlTests/testPreviewRefinesPersonMaskBeforeApplyingBlur()`

- 处理分类：测试蒙版修正
- 处理说明：测试背景原本是透明黑，与实际不透明灰度蒙版不同；改成整幅不透明黑白蒙版，核对边缘扩展与羽化确实影响输出像素。

- 结果摘要：`XCTAssertNotEqual failed: ("16384 bytes") is equal to ("16384 bytes") - 实时预览应使用边缘扩展和羽化后的人物蒙版，减轻分割边缘突兀感。`
- 日志断言（重复内容去重）：
  - `/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/PortraitDepthControlTests.swift:127: XCTAssertNotEqual failed: ("16384 bytes") is equal to ("16384 bytes") - 实时预览应使用边缘扩展和羽化后的人物蒙版，减轻分割边缘突兀感。`

### FULL-20261023-015 — 慢门预览辅助的真实快门与预期不符

- [x] 已处理，定向真机通过：`PreviewExposureAssistPhysicalTests/testSlowShutterPresetAutomaticallyOptimizesSlowPreviewAndRestoresStillExposure()`

- 处理分类：测试预期修正
- 处理说明：反复重选动态模糊预设后，最新快门为 1/8 秒；退出需保留最新请求，不能再要求先前的 1/15 秒。

- 结果摘要：`XCTAssertEqualWithAccuracy failed: ("0.124895") is not equal to ("0.06666666666666667") +/- ("0.002")`
- 日志断言（重复内容去重）：
  - `/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/PreviewExposureAssistPhysicalTests.swift:236: XCTAssertEqualWithAccuracy failed: ("0.124895") is not equal to ("0.06666666666666667") +/- ("0.002")`

### FULL-20261023-016 — 视频编码矩阵中的输出比例

- [x] 已处理，定向真机通过：`VideoCodecPhysicalTests/testActualCodecsAndColorsRepeatedRecording()`

- 处理分类：测试范围与准备状态修正
- 处理说明：普通比例矩阵排除需独立启用的 Open Gate，等待最终视频规格与快门就绪后再开始；核对实际编码、方向、画幅和解码帧率。

- 结果摘要：`XCTAssertEqualWithAccuracy failed: ("0.5625") is not equal to ("0.75") +/- ("0.003")`
- 日志断言（重复内容去重）：
  - `/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VideoCodecPhysicalTests.swift:87: XCTAssertEqualWithAccuracy failed: ("0.5625") is not equal to ("0.75") +/- ("0.003")`

### FULL-20261023-017 — 照片/视频往返后的路线、倍率及候选恢复

- [x] 已处理，定向真机通过：`VideoModeTransitionTests/testAutomaticVideoRouteRestoresPhotoFormatAndLensSwitching()`

- 处理分类：产品修复
- 处理说明：按显示倍率保存最外层媒体切换事务，在最终输入提交后重新换算并恢复焦段，修复 8× 回照片变 1×；照片 M 挡单独保存视频帧周期钳制前的手动参数，冷启动存档也保留该快照。普通 A 视频基线排除旧子模块状态。

- 结果摘要：`XCTAssertTrue failed - video=true input=AVCaptureDeviceTypeBuiltInWideAngleCamera virtual=false primary=AVCaptureDeviceTypeBuiltInWideAngleCamera switching=unsupported conditions=0 fallback= format=1920x1080-875704438-1.00-30.00 color=0 autoWideColor=false zoom=1.0 focus=0.0 primaryFocus=0.0 AF=2 AE=2 adjusting=false point=(0.5, 0.5)`
- 日志断言（重复内容去重）：
  - `/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VideoModeTransitionTests.swift:61: XCTAssertTrue failed - video=true input=AVCaptureDeviceTypeBuiltInWideAngleCamera virtual=false primary=AVCaptureDeviceTypeBuiltInWideAngleCamera switching=unsupported conditions=0 fallback= format=1920x1080-875704438-1.00-30.00 color=0 autoWideColor=false zoom=1.0 focus=0.0 primaryFocus=0.0 AF=2 AE=2 adjusting=false point=(0.5, 0.5)`
  - `/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VideoModeTransitionTests.swift:90: XCTAssertTrue failed - A mode must retain the close-focus ultra-wide fallback`
  - `/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VideoModeTransitionTests.swift:108: XCTAssertTrue failed - video=true input=AVCaptureDeviceTypeBuiltInWideAngleCamera virtual=false primary=AVCaptureDeviceTypeBuiltInWideAngleCamera switching=unsupported conditions=0 fallback= format=1920x1080-875704438-1.00-30.00 color=0 autoWideColor=false zoom=2.0 focus=0.0 primaryFocus=0.0 AF=2 AE=2 adjusting=false point=(0.5, 0.5)`
  - `/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VideoModeTransitionTests.swift:109: XCTAssertTrue failed - video=true input=AVCaptureDeviceTypeBuiltInWideAngleCamera virtual=false primary=AVCaptureDeviceTypeBuiltInWideAngleCamera switching=unsupported conditions=0 fallback= format=1920x1080-875704438-1.00-30.00 color=0 autoWideColor=false zoom=2.0 focus=0.0 primaryFocus=0.0 AF=2 AE=2 adjusting=false point=(0.5, 0.5)`
  - `/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VideoModeTransitionTests.swift:108: XCTAssertTrue failed - video=true input=AVCaptureDeviceTypeBuiltInTelephotoCamera virtual=false primary=AVCaptureDeviceTypeBuiltInTelephotoCamera switching=unsupported conditions=0 fallback= format=1920x1080-875704438-1.00-30.00 color=0 autoWideColor=false zoom=1.0 focus=0.5294118 primaryFocus=0.5294118 AF=2 AE=2 adjusting=false point=(0.5, 0.5)`
  - `/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VideoModeTransitionTests.swift:109: XCTAssertTrue failed - video=true input=AVCaptureDeviceTypeBuiltInTelephotoCamera virtual=false primary=AVCaptureDeviceTypeBuiltInTelephotoCamera switching=unsupported conditions=0 fallback= format=1920x1080-875704438-1.00-30.00 color=0 autoWideColor=false zoom=1.0 focus=0.5294118 primaryFocus=0.5294118 AF=2 AE=2 adjusting=false point=(0.5, 0.5)`
  - `/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VideoModeTransitionTests.swift:110: XCTAssertEqualWithAccuracy failed: ("1.0") is not equal to ("4.0") +/- ("0.005") - video=true input=AVCaptureDeviceTypeBuiltInTelephotoCamera virtual=false primary=AVCaptureDeviceTypeBuiltInTelephotoCamera switching=unsupported conditions=0 fallback= format=1920x1080-875704438-1.00-30.00 color=0 autoWideColor=false zoom=1.0 focus=0.5294118 primaryFocus=0.5294118 AF=2 AE=2 adjusting=false point=(0.5, 0.5)`
  - `/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VideoModeTransitionTests.swift:108: XCTAssertTrue failed - video=true input=AVCaptureDeviceTypeBuiltInTelephotoCamera virtual=false primary=AVCaptureDeviceTypeBuiltInTelephotoCamera switching=unsupported conditions=0 fallback= format=1920x1080-875704438-1.00-30.00 color=0 autoWideColor=false zoom=2.0 focus=0.5294118 primaryFocus=0.5294118 AF=2 AE=2 adjusting=false point=(0.5, 0.5)`
  - `/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VideoModeTransitionTests.swift:109: XCTAssertTrue failed - video=true input=AVCaptureDeviceTypeBuiltInTelephotoCamera virtual=false primary=AVCaptureDeviceTypeBuiltInTelephotoCamera switching=unsupported conditions=0 fallback= format=1920x1080-875704438-1.00-30.00 color=0 autoWideColor=false zoom=2.0 focus=0.5294118 primaryFocus=0.5294118 AF=2 AE=2 adjusting=false point=(0.5, 0.5)`
  - `/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VideoModeTransitionTests.swift:110: XCTAssertEqualWithAccuracy failed: ("2.0") is not equal to ("8.0") +/- ("0.005") - video=true input=AVCaptureDeviceTypeBuiltInTelephotoCamera virtual=false primary=AVCaptureDeviceTypeBuiltInTelephotoCamera switching=unsupported conditions=0 fallback= format=1920x1080-875704438-1.00-30.00 color=0 autoWideColor=false zoom=2.0 focus=0.5294118 primaryFocus=0.5294118 AF=2 AE=2 adjusting=false point=(0.5, 0.5)`
  - `/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VideoModeTransitionTests.swift:110: XCTAssertEqualWithAccuracy failed: ("1.0") is not equal to ("8.0") +/- ("0.005") - video=false input=AVCaptureDeviceTypeBuiltInTripleCamera virtual=true primary=AVCaptureDeviceTypeBuiltInWideAngleCamera switching=auto conditions=0 fallback=AVCaptureDeviceTypeBuiltInWideAngleCamera format=4032x3024-875704422-1.00-30.00 color=1 autoWideColor=true zoom=1.0 focus=0.0 primaryFocus=0.0 AF=2 AE=2 adjusting=false point=(0.5, 0.5)`
  - `/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VideoModeTransitionTests.swift:108: XCTAssertTrue failed - video=true input=AVCaptureDeviceTypeBuiltInWideAngleCamera virtual=false primary=AVCaptureDeviceTypeBuiltInWideAngleCamera switching=unsupported conditions=0 fallback= format=1920x1080-875704438-1.00-30.00 color=0 autoWideColor=false zoom=1.0 focus=0.0 primaryFocus=0.0 AF=2 AE=2 adjusting=false point=(0.5, 0.5)`
  - `/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VideoModeTransitionTests.swift:109: XCTAssertTrue failed - video=true input=AVCaptureDeviceTypeBuiltInWideAngleCamera virtual=false primary=AVCaptureDeviceTypeBuiltInWideAngleCamera switching=unsupported conditions=0 fallback= format=1920x1080-875704438-1.00-30.00 color=0 autoWideColor=false zoom=1.0 focus=0.0 primaryFocus=0.0 AF=2 AE=2 adjusting=false point=(0.5, 0.5)`

### FULL-20261023-018 — 1080p120、4K120 的文件轨道帧率不足

- [x] 已处理，定向真机通过：`VideoSpecificationTests/testAllSupportedVideoSpecificationsWriteMatchingTracks()`

- 处理分类：产品修复
- 处理说明：普通 >60 帧与慢动作一样复用录制输出供预览，避免双输出高帧率带宽负担；先更新 input.videoMinFrameDurationOverride，再设设备 min/max 帧周期，退出视频清除输入上限。核对实际采集时间戳及轨道帧率。

- 结果摘要：`XCTAssertEqualWithAccuracy failed: ("61.621620178222656") is not equal to ("120.0") +/- ("6.0")`
- 日志断言（重复内容去重）：
  - `/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VideoSpecificationTests.swift:705: XCTAssertEqualWithAccuracy failed: ("61.621620178222656") is not equal to ("120.0") +/- ("6.0")`
  - `/Users/shurrikann/MyProject/iOS/LumaCamera/LumaCameraTests/Camera/VideoSpecificationTests.swift:705: XCTAssertEqualWithAccuracy failed: ("62.04081726074219") is not equal to ("120.0") +/- ("6.0")`
- 规格上下文：1080p/120 实际轨道约 61.62162 fps、时长 1.2333 秒；4K/120 约 62.04082 fps、时长 1.225 秒，均含音轨。尚未确认采集、负载、暗光或时间戳哪一环导致差异。

### FULL-20261023-019 — 全部滤镜×画幅渲染测试进程被 kill

- [x] 已处理，定向真机通过：`ImagingTests/testAllFiltersRenderEveryRatioAndBorderAddsCanvas()`

- 处理分类：测试负载修正
- 处理说明：保留全部滤镜×画幅×边框覆盖，逐项 autoreleasepool、关闭 CI 中间缓存并释放缓存，使用设备 GPU 上下文；复测不再 kill。原 signal kill 的系统根因仍未证实，不宣称已确认为 OOM 或产品泄漏。

- 结果摘要：`Test crashed with signal kill.`
- Xcode 明确记录 `Test crashed with signal kill.`；最后活动用例即本项，随后自动续跑。未另行运行该用例或检查设备 kill 原因。

## 相机服务错误日志（额外观测）

共记录 8 条带错误信息的相机会话 runtime error，主要为 AVFoundation -11800 / OSStatus -12780。部分对应测试本身通过，不能把这些日志直接当作额外失败方法，也不能据此推定其他断言的根因。测试主动注入、缺少 error key 的通知未混入此计数。

最新处理：普通视频换输入改为最终格式/输出准备完毕后一次提交，修复本次复现的 -12780 分支；前置广角测试改用唯一可见引擎，原七个方法新增真实运行错误审计。最终 10 项真机通过，0 条非注入会话错误。历史 -11819 未再次真实发生，已验证同类通知恢复及退出，不宣称系统服务重置的内部根因已被确定。逐条映射、原始复现与完整边界见 [八条会话错误专项记录](2026-10-23-Runtime8-Resolution.md)。

- [x] 定向验收通过（历史归因边界见专项记录）；时间关联测试：`LumaCameraTests.CameraControlMenuTests testPhysicalMenusAndManualBindingsWithoutSavingPhotos`
  - `2026-10-23 17:43:33.479841+0800 LumaCamera[3689:1273581] Camera capture session runtime error: AVFoundationErrorDomain (-11800): The operation could not be completed userInfo=["NSUnderlyingError": Error Domain=NSOSStatusErrorDomain Code=-12780 "(null)", "NSLocalizedFailureReason": An unknown error occurred (-12780), "NSLocalizedDescription": The operation could not be completed]`
- [x] 定向验收通过（历史归因边界见专项记录）；时间关联测试：`LumaCameraTests.CameraFacingLatencyPhysicalTests testPhotoAndVideoFacingDirectionLatency`
  - `2026-10-23 17:44:08.588370+0800 LumaCamera[3689:1273581] Camera capture session runtime error: AVFoundationErrorDomain (-11800): The operation could not be completed userInfo=["NSUnderlyingError": Error Domain=NSOSStatusErrorDomain Code=-12780 "(null)", "NSLocalizedFailureReason": An unknown error occurred (-12780), "NSLocalizedDescription": The operation could not be completed]`
- [x] 定向验收通过（历史归因边界见专项记录）；时间关联测试：`LumaCameraTests.CaptureKindModeLatencyPhysicalTests testCrossModePhotoVideoLatencyAndRestoration`
  - `2026-10-23 17:44:59.705058+0800 LumaCamera[3689:1273581] Camera capture session runtime error: AVFoundationErrorDomain (-11800): The operation could not be completed userInfo=["NSLocalizedDescription": The operation could not be completed, "NSUnderlyingError": Error Domain=NSOSStatusErrorDomain Code=-12780 "(null)", "NSLocalizedFailureReason": An unknown error occurred (-12780)]`
- [x] 定向验收通过（历史归因边界见专项记录）；时间关联测试：`LumaCameraTests.FrontWideSelectionTests testFrontWideSwitchDoesNotCrashAndTogglesBack`
  - `2026-10-23 17:49:04.280033+0800 LumaCamera[3689:1273581] Camera capture session runtime error: AVFoundationErrorDomain (-11800): The operation could not be completed userInfo=["NSLocalizedDescription": The operation could not be completed, "NSLocalizedFailureReason": An unknown error occurred (-12780), "NSUnderlyingError": Error Domain=NSOSStatusErrorDomain Code=-12780 "(null)"]`
- [x] 定向验收通过（历史归因边界见专项记录）；时间关联测试：`LumaCameraTests.FrontWideSelectionTests testFrontWideSwitchDoesNotCrashAndTogglesBack`
  - `2026-10-23 17:49:04.280318+0800 LumaCamera[3689:1273581] Camera capture session runtime error: AVFoundationErrorDomain (-11800): The operation could not be completed userInfo=["NSLocalizedDescription": The operation could not be completed, "NSLocalizedFailureReason": An unknown error occurred (-12780), "NSUnderlyingError": Error Domain=NSOSStatusErrorDomain Code=-12780 "(null)"]`
- [x] 定向验收通过（历史归因边界见专项记录）；时间关联测试：`LumaCameraTests.VideoColorPhysicalTests testEveryAvailableColorSpaceRecordsRealTagsAndRestoresPhotos`
  - `2026-10-23 18:01:14.498628+0800 LumaCamera[3705:1297133] Camera capture session runtime error: AVFoundationErrorDomain (-11819): Cannot Complete Action userInfo=["NSLocalizedRecoverySuggestion": Try again later., "NSLocalizedDescription": Cannot Complete Action]`
- [x] 定向验收通过（历史归因边界见专项记录）；时间关联测试：`LumaCameraTests.WhiteBalanceRouteSafetyTests testStaleCustomWhiteBalanceDuringRouteChangesDoesNotCrashVirtualCamera`
  - `2026-10-23 18:05:11.195171+0800 LumaCamera[3705:1297133] Camera capture session runtime error: AVFoundationErrorDomain (-11800): The operation could not be completed userInfo=["NSLocalizedDescription": The operation could not be completed, "NSUnderlyingError": Error Domain=NSOSStatusErrorDomain Code=-12780 "(null)", "NSLocalizedFailureReason": An unknown error occurred (-12780)]`
- [x] 定向验收通过（历史归因边界见专项记录）；时间关联测试：`LumaCameraTests.ZoomWheelReopenPhysicalTests testReopeningKeepsActualZoomAndAnchorAcrossBothModes`
  - `2026-10-23 18:05:15.302872+0800 LumaCamera[3705:1297133] Camera capture session runtime error: AVFoundationErrorDomain (-11800): The operation could not be completed userInfo=["NSLocalizedFailureReason": An unknown error occurred (-12780), "NSUnderlyingError": Error Domain=NSOSStatusErrorDomain Code=-12780 "(null)", "NSLocalizedDescription": The operation could not be completed]`

## 运行时跳过的 6 项

- `CameraRulerMappingTests/testAMToToolsDoesNotMovePreviewForAnyRatio()`：Test skipped - Layout regression is exercised in the simulator
- `CameraSessionRecoveryTests/testTemporaryInterruptionIsSilentAndEndedCannotRestartStoppedCamera()`：Test skipped - Use the shared visible engine for physical recovery tests
- `PopupAppearanceAndOrientationTests/testPopupOpenCloseDuringOrientationChangesRemainsResponsive()`：Test skipped - Full camera UI stress runs in the simulator; the device runs the harness orientation stress
- `SlowShutterPresetTests/testAutomaticModeKeepsApertureModeAndPresetOnlyCapsAutomaticExposure()`：Test skipped - Requires a live camera route; A-mode cap policy is covered by the model tests
- `SlowShutterPresetTests/testSelectingPresetsConstrainsManualExposureAndRepeatedTogglingClearsState()`：Test skipped - Requires a live camera route; range/support logic is covered above
- `ToolbarHistogramLayoutTests/testAllRatioTransitionsKeepToolbarFixedAndHistogramClear()`：Test skipped - Ratio layout is tested in simulator

## 性能观测与验证边界

- 滤镜压力用例记录 2040 次参数更新，31.777 秒内发布 433 次预览；宿主进程 footprint 基线/峰值/稳定后约 239/419/284 MiB。发布次数不是屏幕显示 FPS，宿主包含 XCTest，不能直接写成纯应用内存或泄漏结论。
- 慢门完整序列在本轮按既有不同方法覆盖 3 组 A/M 组合、共 6 段：光轨约 46.46–47.07 秒、流水约 37.16–38.34 秒，所有源帧按用例检查真实 1 秒曝光。全量环境的宿主峰值最高约 698 MiB，包含其他测试留下的缓存和测试对象，不与独立专项的基线直接比较。
- 视频规格矩阵 18 组短片约 25.63 秒；其中 120fps 的两项轨道帧率断言失败，详见待办。最后相关视频用例报告 thermalState=1（fair），不等于实测温度，也不能证明长录热稳定性。
- 快照绘制、逻辑耗时与预览发布时间不视为触屏延迟或屏幕帧率。未做外接盘实录、长期录像/功耗/温升测试，也没有进行一次用户操作式的全功能目视验收。

## 修复期间额外发现（不计入原 19 项）

- [ ] **FOLLOWUP-20261023-001：近距离场景 A 挡人像完成回调超时**。本次复现到的“系统超广角微距仍请求人像深度/遮罩”分支已修复并真机通过；历史主摄状态快照对应的超时未独立重现，保留观察，不能宣称所有历史超时同根因。详见 Validation 的“近距微距与人像请求互斥修复”。
- 近距人像诊断进展：已加入仅 DEBUG 测试启用的系统拍摄回调、分割和编码阶段日志。用户准备近处场景后，定向真机 1 项 / 8 次临时捕获全部完成（`/private/tmp/LumaCamera-PortraitPhase-Near.xcresult`）；A 挡 HEIF 12MP 约 1.300 秒且收到系统人像遮罩。本轮未复现超时，不能确定根因或标为修复；没有改动拍摄策略。详细阶段与指标见 Validation。
- 原始 8 条会话 runtime error 已完成逐项对照、定向审计和恢复验证，见专项记录；原始日志保留，未逐条因果重演的边界仍明确记录。

## 后续修复验收汇总

原 19 个失败方法最新定向状态均为通过。最终 21 项组合组为 20 通过、1 失败（视频编码测试早于规格就绪）；修正等待后，人像→慢门辅助→视频编码连续 3 项全部通过。补充 15 项相关真机回归全部通过，有范围重叠，不直接相加为独立总数。未再次执行 494 项全量。完整指标、结果包、平台约束及近距人像超时边界见 [验证记录](../Validation.md#2026-10-23-全量失败项修复与定向真机回归)。
