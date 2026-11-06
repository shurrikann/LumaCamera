# 2026-11-01 视频六项处理与真实人物复验

六项对应FULL-004/017/018/076/077/081，本轮全部真机通过；关联三项也通过。最终共9个不同方法，0失败/0跳过，分7项自动回归、竖屏人物和横屏人物三批执行，方法耗时合计约200.933秒，人工就位时间另计。设备iPhone17Pro（iPhone18,1）、iOS27.2（24B119），Xcode27.1；Debug测试与Release构建通过，源码编译警告0，Debug构建保留一条AppIntents工具链提示。普通App已恢复，诊断照片/录像未写系统照片。未重跑736项全量。

## 修正与复现证据

无需人物配合的四项修正前基线：2通过、2失败。重复录像与Live/HDR/M挡往返已通过；自动照片/视频切换后录像、白平衡第一组录像未启动，随后无URL。其中白平衡当时尚未开启锁定偏好，原测试仍将等待超时计作启动延迟（5.234秒）。

`afterPendingSessionTasks`只等待会话队列，不代表主线程模式切换和实际按钮状态已完成。生产`toggleVideoRecording`在`captureKindSwitching`时会忽略调用。新增共用`FullDeviceRegressionFixture.waitForVideoShutter`，按现有`videoShutterEnabled`等待实际启用后再触发，分别记录准备与录制启动时间；接入自动路线、白平衡矩阵及前置人物/居中实录测试，保留原资源、方向、曝光、白平衡稳定和启动上限断言。

最终实际观测：自动路线首次`switch=true, ready=true, configuring=false, enabled=false`，再44.9ms才启用；白平衡首次同样状态，再64.8ms启用；竖/横人物首次分别106.3/106.5ms。说明仅按会话ready或队列排空就触发录制会早于可点击状态。

本轮修改落在4个真机测试文件。CameraEngine和FocusNavigatorGraph的源码SHA256与长焦导航专项一致；本轮没有新增生产录制修正。原照片解码/编码失败和重复完成问题在当前基线未复现，当前实际文件通过情况见下；保留原历史失败证据，不把本轮测试等待修正当成所有历史内部故障的根因。

## 六项逐一结果

| 原问题 | 方法 | 最终结果 / 方法耗时 |
|---|---|---|
| FULL-004 | BasicVideoPhysicalTests/testRepeatedVideoRecordingsAndPhotoModeReturn | 通过 / 8.707秒 |
| FULL-017 | FrontVideoCenteringPhysicalTests/testCenterStagePersonLandscapeRecording | 通过 / 15.443秒 |
| FULL-018 | FrontVideoCenteringPhysicalTests/testCenterStagePersonPortraitRecording | 通过 / 15.584秒 |
| FULL-076 | VideoModeTransitionTests/testAutomaticVideoRouteRestoresPhotoFormatAndLensSwitching | 通过 / 12.431秒 |
| FULL-077 | VideoModeTransitionTests/testLiveHDRAndManualPhotoRoutesSurviveVideoRoundTrips | 通过 / 64.535秒 |
| FULL-081 | VideoWhiteBalancePhysicalTests/testVideoWhiteBalanceLockIsOptionalAndRestoredAfterRecording | 通过 / 19.274秒 |

FULL编号均属20261030清单。FULL-004此前在导航专项已通过，本轮再次执行。关联通过：前置居中规格回退/快速恢复19.836秒、官方居中排他/实际录制34.997秒、重复模式切换预览延迟10.126秒；其中原FULL-019也完成复验。

## 实际录制与文件核对

- 重复录像：三轮后置1080p30文件、音轨、前置实录及返回后置拍照通过。
- 自动视频路线：原生照片格式返回4032×3024，保持系统虚拟多摄、完整fallback候选与原倍率；2/4/8/1倍照片/视频往返、视频中改3倍后回照片、20轮快速反向请求通过。
- Live/HDR/M挡：正反顺序各一轮，共六次录像后实际拍照。Live保留配对MOV，HDR为10位PQ；M挡实际编码EXIF ISO200、0.5秒，锁定白平衡与对焦状态恢复。六份资源的实际方向标签均1；每次完成后的照片任务计数均0，10轮快速往返后继续出帧。
- 白平衡：六种实际路线×开关两种状态，共12段视频全解码完成。覆盖HEVC SDR、4K60 HDR、H.264 P3、Apple Log、Apple Log 2/常规ProRes HQ，以及已有手动白平衡5400K/tint8。锁定时RGB增益在700ms采样内保持，关闭偏好时保留原模式，结束恢复录前模式；启动立即取消有取消回调、无成功URL、忙碌与白平衡模式恢复。
- 前置居中关联回归：12种当前支持规格、请求4K/HDR后的实际1080p SDR回退、五画幅×四控件方向布局、三次快速取消/恢复、后台和前后镜头切换通过；HEVC SDR、H.264 P3、ProRes SDR实际录制与逐帧解码通过。

上述照片参数来自ImageIO读取实际编码资源，录像来自AVAsset/AVAssetReader读取文件，不以界面显示代替。RAW外接录制端到端验证仍按项目原有未验收状态维护。

## 真人横竖手持验证

用户配合真实人物入镜与左右移动，先竖屏、再横屏，各实际录制约12秒。开拍姿态由UIDevice实测为1（竖屏）、3（横屏），系统Center Stage在录制采样期间保持激活。

- 竖屏文件：编码1080×1920，轨道变换`[-1,0,0,1,1080,0]`，实际显示1080×1920；1/3/5/7/9/11秒六帧均检测到人脸。
- 横屏文件：编码1080×1920，轨道变换`[0,1,1,0,0,0]`，实际显示1920×1080；同六个时间点均检测到人脸。
- 已目视两段实际视频按轨道变换抽出的1秒帧，人物直立，横竖显示方向正确。全套12帧附件保留；未将人物图复制到项目文档或系统相册。

单人各12秒是本轮场景样本。跟随平滑、响应延迟、多人场景和长期热稳定尚未量化。

## 性能与稳定性指标

| 指标 | 样本与观测 | 解释 |
|---|---|---|
| 白平衡录制启动 | n=12，测试p50 39.30ms，最大118.76ms | 从实际按钮就绪后的录制调用到检测到videoRecording；与模式准备时间分开 |
| 返回照片状态 | n=6，中位0.622秒、最大1.221秒 | 含会话配置、预览新帧和参数检查 |
| 返回后实际拍照 | n=6，中位3.574秒、最大3.821秒 | 含Live/HDR/0.5秒手动曝光及编码完成 |
| 重复切视频后的新预览 | n=3，0.858/0.832/0.839秒 | 会话配置加首个新预览发布时间，非屏幕FPS |
| 重复切照片后的新预览 | n=3，0.532/0.528/0.546秒 | 同上 |
| 前置居中激活 | n=3，0.443/0.365/0.442秒 | 到系统active且准备状态结束 |
| 人物录制预览发布 | 每段372次；竖屏最大间隔77.37ms，横屏59.42ms | 预览发布采样，非屏幕FPS或逐帧无掉帧保证 |

覆盖重复录像、快速模式切换、参数与原生照片往返、居中准备中重复点击、后台/前后镜头返回及立即取消；实际会话运行错误审计通过。最终三批日志`AVFoundationErrorDomain/-11819`、`IOSurface creation failed`字符串均0次；仍有86次`MDB_MAP_FULL`和局部测试宿主Environment提示。白平衡组后段thermalState为1，本轮未做持续高温耐久或独立App内存测量。

## 官方依据与证据

苹果[Center Stage启用属性](https://developer.apple.com/documentation/avfoundation/avcapturedevice/iscenterstageenabled)与[官方前置相机示例讲解](https://developer.apple.com/videos/play/wwdc2026/341/)说明按支持格式与应用控制模式启用；[白平衡锁定接口](https://developer.apple.com/documentation/avfoundation/avcapturedevice/setwhitebalancemodelocked%28with%3Acompletionhandler%3A%29)定义增益范围、完成处理和时钟语义；[videoRotationAngle](https://developer.apple.com/documentation/avfoundation/avcaptureconnection/videorotationangle)说明AVAssetWriter可使用轨道变换处理旋转。本轮具体就绪时间、文件变换与样本检测结果均为真机观测；测试等待条件采用项目现有实际按钮状态。

目录`/tmp/LumaCamera-VideoSix-20261101`：

- `Baseline.xcresult`及日志：无需人物四项2通过/2失败；`Automated.xcresult`：7通过；`Portrait.xcresult`与`Landscape.xcresult`：各1通过；对应`*-summary.json`保留。
- `Build.log`、`Release.log`；人物12张抽帧与清单位于`Portrait-Images`、`Landscape-Images`，只保存在本机测试目录。
- [完整阶段摘要、逐方法结果、原六项映射、指标及源码SHA256](2026-11-01-Video-Six-Fixes-results.json)。

构建后以`/tmp/LumaCamera-NightCancel-DD/Build/Products/VideoSix-Automated.xctestrun`执行自动组，真人就位后分别执行`VideoSix-Portrait.xctestrun`、`VideoSix-Landscape.xctestrun`；均设置`LUMA_DIAGNOSTIC_READ_ONLY_PHOTOS=1`。人物组需分别匹配真实握持方向和人物入镜，先完成竖屏再确认横屏。
