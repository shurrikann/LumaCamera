# 2026-10-27 前置视频人物居中

## 实现与官方依据

前置视频新增人物居中图标，与广角、双拍作为一组居中，照片入口不变。开启选择同一前置超广角输入，由系统Center Stage自动构图；看到的视野仍由系统裁切和平移决定。手动切宽窄（包括点当前已选宽取景）、开启双拍、切到后置/照片或选择其他视频子模块时关闭。横竖拿均可用，录像期间仍遵循既有控件隐藏规则。

按格式的isCenterStageSupported和videoFrameRateRangeForCenterStage筛选，明确使用app控制模式，关闭照片深度/蒙版输出，开启必要畸变校正，观察实际isCenterStageActive。不以按钮变橙替代硬件激活；激活前阻止提前录制。默认关闭，保存拍摄设置时保存意图；冷启动保存恢复代码已接入，本轮未单独重启进程验收该字段。

参考[苹果前置Center Stage讲解](https://developer.apple.com/videos/play/wwdc2026/341/)、[实际激活及限制](https://developer.apple.com/documentation/avfoundation/avcapturedevice/iscenterstageactive)、[构图区域](https://developer.apple.com/documentation/avfoundation/avcapturedevice/centerstagerectofinterest)、[方向协调器](https://developer.apple.com/documentation/avfoundation/avcapturedevice/rotationcoordinator)。官方规定与本机枚举结果区分：本机兼容组合为SDR/P3、720p/1080p、24/25/30帧，共12组；不能据此断言所有设备的Center Stage都仅支持这些规格。

ROI使用实际自动输出尺寸，引导系统在最终成片裁切内构图，关闭前恢复整幅。MovieRecorder仅此新前置路径按官方重力方向写轨道变换，不按缓冲宽高猜旋转。滤镜缓冲池亦用实际输出大小，保持一次编码；视频描述记录开拍时实际系统居中状态。

## 真机结果

设备iPhone17 Pro，iOS27.2（24B119），正常项目签名，未启动模拟器。临时照片/视频不写系统相册。4个新方法与1个既有相关方法分别有通过记录，并非全量测试。

- `testOfficialCenterStageVideoFramingExclusionsAndRecording`：三轮开关、系统active/深度关闭/畸变校正、手动宽窄退出、五画幅×四控件方向布局、实际ROI值与退出整幅恢复、A/M挡录制、双拍互斥及退出照片通过。最终OutputFinal记录开启0.734/0.318/0.280秒，含点击到实际active与配置结束；不是屏幕动画耗时。三段30帧HEVC SDR、H.264 P3带滤镜、ProRes HQ SDR分别完整解码37/38/38帧，写入37/37、38/38、38/38，输入约29.99帧/秒；短样本不能代表长时稳定性。未逐个录制六种ProRes。
- `testCenterStageCapabilitiesFallbackAndRapidRecovery`：12组规格每组观察0.4秒、持续有预览，三轮快速重复点击、后台/前台、前后镜头及手动重开通过；4K HDR请求回退1080p SDR。新增激活前禁止提前开拍检查。CleanupFinal每组7–11次应用发布，最长发布间隔约61.8ms；发布时刻不等于显示FPS。更新后的ReadyFinal另见结果包。
- 两个Person方法按真实握持检查人物样本：方向修正后的LandscapeFinal轨道显示1920×1080、6/6抽帧检测到人物；PortraitFinal显示1080×1920、6/6检测到人物。各约12秒，应用发布369/370张，最大间隔92.1/68.6ms；附件目视人物朝上、比例自然。该实景样本在最终ROI尺寸修正前取得；后续以实际系统ROI值、最终预览截图及编码回归补查，不把人脸检测成功等同于量化的居中追踪精度。
- 既有`testCurrentOrientationFramingAndRecordingGuard`通过，普通前置宽窄与录像中方向切换门控未被新功能替代。
- 会话runtimeErrorNotification审计在通过方法内未记录错误，日志仍出现Fig内部assert（-12784）与测试宿主MDB_MAP_FULL等信息，不能声称所有系统日志零错误。

## 中间问题及保留限制

1. 首组在画幅重配时立即调用开关，动作按ready门控忽略；测试改为等待可点击状态。组合运行时镜头可能已在前置，原测试无条件翻转到后置导致失败；改为按实际位置准备。另有测试辅助代码的async/XCTest autoclosure编译错误，已修正。
2. 初期仅检查active与解码通过，但真实人物抽帧暴露竖屏偏转、横持仍竖幅的问题。新增轨道显示方向断言并修正原生方向路径；不能将早期“能播放”记为视觉通过。
3. 标称1920×1080与实际1080×1920对调，使初版ROI在预览产生黑边。已按输出实际尺寸修正ROI与滤镜缓冲，最终OutputFinal截图无该黑边，五画幅实际ROI检查及三种编码通过。16:9实际ROI为整幅，2.39:1的宽比例约0.74384；关闭后恢复1×1。
4. RegionRegression一次开启9.222秒，同期有Fig日志；随后CleanupFinal为0.293/0.367/0.361秒，OutputFinal为0.734/0.318/0.280秒。退出已补整幅ROI恢复，但尚未证明该单次异常的全部根因，不承诺彻底消除所有慢开启。
5. 多人快速出入、遮挡、极暗环境、相机压力下持续跟随、长时发热/功耗、iOS18及其他设备未验收。系统居中会裁切并调整倍率，按钮所选超广角表示输入来源，不能当作始终全超广角视野。照片Smart Framing未重新开放。

结果包均位于`/private/tmp/`：`LumaCamera-FrontVideoCentering-Checks2.xcresult`、`Stability.xcresult`、`LandscapeFinal.xcresult`、`PortraitFinal.xcresult`、`RegionRegression.xcresult`、`CleanupFinal.xcresult`、`FinalROI.xcresult`、`OutputFinal.xcresult`、`ReadyFinal.xcresult`（后八项均沿用前述LumaCamera-FrontVideoCentering-前缀）。各同名.log保留过程。机器指标见同名results.json。

最终正常Debug构建成功，已按项目签名安装并启动，真机安装序号1792。ReadyFinal的12组规格与激活前开拍保护最终16.364秒通过；该时长含整个方法，不是界面延迟。
