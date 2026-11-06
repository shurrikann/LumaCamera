# 2026-11-01 长焦导航倍率恢复与遗留项复验

最终iPhone17Pro（iPhone18,1）/iOS27.2（24B119）真机13方法全部通过，0失败/0跳过，执行81.725秒；Xcode27.1，Debug测试构建与Release构建通过，源码编译警告0，保留AppIntents工具链提示。普通App已恢复，诊断照片/录像未写系统照片。未重跑736项全量。

## 修正

进入导航后继续变焦，原实现退出时恢复进入导航那一刻的设备倍率。新增真机用例明确复现：8×进入、调到16×后，A挡照片等效焦距仍197mm、M挡仍200mm，关闭导航后实际硬件均回到8×；共四处断言失败，不是只检查界面数字。

现在先恢复原照片格式，再把导航最新逻辑倍率按虚拟设备显示倍率或物理镜头基准换算、限制在实际硬件范围内，应用于原照片设备。因此导航中拍照、关闭辅助及其他退出路径保持最新取景倍率。保留原照片会话和输出，不把照片输出搬进MultiCam，也不改变系统自动微距与虚拟镜头选择策略。

主路帧在预览队列开始渲染前再次检查导航修订号，退出/换图后不渲染旧导航帧；准备完成的主线程通知也检查修订号。导航180×240缩图使用自有像素，避免保留延迟渲染输出。没有新增切镜动画或移动控件。

苹果[videoZoomFactor](https://developer.apple.com/documentation/avfoundation/avcapturedevice/videozoomfactor)明确该属性控制设备裁切/放大，设置前须取得配置锁；[activeFormat](https://developer.apple.com/documentation/avfoundation/avcapturedevice/activeformat)说明格式与会话预设的关系；[AVMultiCamPiP](https://developer.apple.com/documentation/avfoundation/avmulticampip-capturing-from-multiple-cameras)为独立输入/输出配置参考。[AVCaptureSession](https://developer.apple.com/documentation/avfoundation/avcapturesession)要求避免主线程执行阻塞式启停。恢复最新倍率是本项目策略；具体文件焦距、成本和耗时为本机观测，不是平台保证。

## 原遗留项与实际文件

原FULL-014/015/016三个方法在本轮未修改生产代码的基线即全部通过，未再复现历史导航超时或视图移除异常；当前资源与基线修正已使这些路径恢复。本轮新修正的明确复现项是上述倍率回退。

- `testLiveAndRawPhotoPipelineRestoresAfterNavigation`：实际HEIF+配对MOV及DNG均交付，随后导航恢复，没有走跳过RAW分支。
- `testManualCaptureMetadataAndMovableNavigatorLayout`：M挡JPEG、HEIF实际编码资源EXIF均ISO200、1/120秒；28组布局（7比例×4控件方向）、252个拖动目标，固定3:4、边界及按钮/直方图避让通过；后台返回和15次快速辅助开关后最终关闭通过。
- `testPhotoNavigatorThresholdCaptureAndVideoExit`：7.9×不显示、8×进入，拍照后恢复、三次跨阈值进出、关闭、照片/视频往返通过。新增导航退出后实际录制，文件视频轨30fps，随后回拍照恢复导航。
- 新增`testNavigationZoomSurvivesCaptureAndExitInAutomaticAndManualModes`：A挡实际文件197→408mm，M挡200→400mm，退出后硬件逻辑倍率均16×。按约两倍变化验收，未要求不同路由的等效焦距恰好相同。

文件参数直接用ImageIO读取编码资源、AVAsset读取录制文件，不以应用详情文字代替。导航范围框仍按视场角估算，本轮没有验证近距跨镜头精确配准或所有方向元数据。

## 关联录像测试等待修正

第一轮扩展13方法中12通过、1失败：已有`BasicVideoPhysicalTests/testRepeatedVideoRecordingsAndPhotoModeReturn`再次未启动录制、未收到URL，导航四项全部通过。旧测试切视频仅固定等待450ms，没有等待实际按钮可用；生产`toggleVideoRecording`在`captureKindSwitching`时会忽略点击。

测试现在在每轮开始前等待现有`videoShutterEnabled`，保留原录制、停止、视频音轨/帧率及返回拍照断言，未修改生产录像实现。最终日志首次操作前`switch=true, ready=true, configuring=false, shutter=false`，再约43ms才就绪；最终三轮常规后置文件均1920×1080/30fps、带一条音轨，前置另录一段并返回后置拍照通过。FULL-004对应方法本轮关闭；不据此宣称其他遗留视频问题均已修复。

## 性能、稳定性与目视

| 指标 | 样本与结果 | 含义 |
|---|---|---|
| 导航进入 | n=4，0.694/0.609/0.609/0.597秒；中位0.609秒 | 含变焦请求合并、会话启停和首张导航图，非FPS |
| 低于8×退出 | n=3，0.548/0.523/0.559秒；中位0.548秒 | 到导航状态和小窗实际清除，非显示帧耗时 |
| 导航缩图 | n=95，累计0.095019秒，平均约1.000ms/帧 | 缩图与自有像素生成耗时，非整应用CPU或屏幕帧率 |
| 布局与拖动矩阵 | 28布局/252目标，8.561秒 | 含每组布局等待，非绘制耗时 |
| 实际MultiCam成本 | hardwareCost 0.5；pressureCost约0.915–0.999 | 系统配置估计值，不是独立功耗、内存或长期热稳定性 |

重复进出、后台返回、快速辅助开关、M挡拍照恢复、三轮普通录制、前后镜头与拍照返回均通过；实际会话运行错误审计通过，`AVFoundationErrorDomain/-11819`及`IOSurface creation failed`字符串均0次。日志仍有56次`MDB_MAP_FULL`及局部测试宿主Environment提示，来源未在本轮定位，未宣称系统日志清洁。

已目视本轮真机截图：导航图与白框可见，位于预览内，不遮挡焦段、按钮或直方图。截图取景较近、主路内容较暗，只用于布局验收，不据此验收跨镜头画面匹配、朝向或长焦暗光画质。长时热稳、其他机型、自然手持场景和近距视差精度仍未全面验收；视频模式继续不显示导航。

## 证据与复现

目录`/tmp/LumaCamera-NavigatorFix-20261101`：

- `Baseline.xcresult`：原三项3通过；`Probe.xcresult`：新增倍率用例1失败/四处断言；`FixQuick.xcresult`：倍率修正后1通过。
- `Final.xcresult`：第一轮扩展12通过/1录像方法失败，原失败日志保留；`Verified.xcresult`：最终13通过，0失败/0跳过。
- `Probe-build.log`、`Build.log`、`Final-build.log`、`Verified-build.log`、`Verified-build2.log`与`Release.log`。新增录像检查初次测试编译因异步读取置于断言自动闭包失败，分离异步读取后最终构建通过，保留失败日志。
- `Images/91F8CABA-07AB-45E5-B3BB-EBD5B1EA4150.png`：实际导航小窗截图；`Images/manifest.json`包含其余附件。
- [结构化摘要、逐方法、完整指标、复现断言及源码SHA256](2026-11-01-FocusNavigator-Fixes-results.json)。

使用`build-for-testing`后以`/tmp/LumaCamera-NightCancel-DD/Build/Products/Navigator-Final.xctestrun`执行`test-without-building`；设置`LUMA_DIAGNOSTIC_READ_ONLY_PHOTOS=1`，选择FocusNavigatorPhysicalTests、CameraFocalButtonTests、DualCaptureExpansionTests/testInsetNativeGestureConfigurationAndDispatch、BasicVideoPhysicalTests/testRepeatedVideoRecordingsAndPhotoModeReturn。保持真机解锁，无其他相机会话占用。
