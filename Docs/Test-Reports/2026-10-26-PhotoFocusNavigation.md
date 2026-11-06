# 拍照8倍广角导航对焦辅助（2026-10-26）

## 当前功能

入口：应用设置→拍摄设置→对焦辅助，默认关闭，开关独立保存。仅拍照：后置逻辑倍率8倍及以上自动显示实时广角导航小窗，低于8倍、关闭设置或切到视频时退出。小窗可拖动，避开预览内按钮、子模块视觉位置和直方图；不包含横竖切换按钮，也不交换主副画面，不写进照片。其固定3:4画面内的白框按视场角和主画幅比例估计当前取景范围，近距视差未标定，不是精确像素配准。

导航时独立MultiCam图用长焦1440×1080/30帧和广角640×480/15帧，主路用于现有取景渲染，辅助缩至180×240。主路真实长焦倍率为逻辑倍率除原生长焦倍率，本机8倍对应2倍长焦裁切；不能只保持UI数字8而硬件回1。若预算不满足，可尝试超广角或较低辅助帧率；本机通过路径为广角15帧。硬件/压力成本均要求≤1，运行错误、中断或压力critical/shutdown会退出辅助。预算为系统估计值，不是实测功耗/温度。

正常照片会话和其原始输出保留，仅暂停采集，不跨会话搬运AVCaptureOutput。按快门先停止导航图、还原设备格式/倍率并回到原拍照会话，再按既有流程实际拍照；原手动曝光缓存重发，锁定白平衡/对焦按安全范围恢复。拍摄完成恢复导航。进入人像、夜景、慢门或HDR实时取景时暂停辅助，保留原功能。视频由用户明确暂缓，界面与引擎双重排除，未接入任何视频导航功能。

## 官方基础与实现边界

参考Apple [AVMultiCamPiP示例](https://developer.apple.com/documentation/avfoundation/avmulticampip-capturing-from-multiple-cameras)，以`supportedMultiCamDeviceSets`、`isMultiCamSupported`、实际原生尺寸/帧率/颜色选择后置设备和格式。输入以`videoMinFrameDurationOverride`声明真实周期，主/辅助输出各归属其自身会话；按官方AVCaptureSession头文件约定，begin/commit配置须成对，start/stop不可位于未结束的配置事务内。

原照片图不变是保留Live与RAW能力的设计，不声称MultiCam本身支持这些照片功能，也不把以前3.57配置压力估计当成本轮运行结果。图像只做实时取景，不增加录后或照片二次编码。导航图的色彩/分辨率是临时预览，不等于真实照片编码规格。

## 最终真机验证

设备iPhone17Pro/iOS27.0.1，正常项目签名，无镜像/模拟器，不向系统相册保存诊断媒体。

`ReleaseChecks`共5个不同相关方法通过，47.452秒含所有等待：

- `testPhotoNavigatorThresholdCaptureAndVideoExit`：7.9倍不显示，8倍显示，实际拍照后恢复；三次跨阈值进出，照片/视频往返、开关关闭恢复普通会话通过。最终第一张导航图等待0.627秒（n=1，含150ms请求合并及取景启动，不是FPS，也不是长期保证）。
- `testManualCaptureMetadataAndMovableNavigatorLayout`：M挡JPEG和HEIF真实文件EXIF均为ISO200、1/120秒；七种照片画幅×四控件方向28组，252个拖动目标的边界、固定3:4及按钮/子模块/直方图避让通过。后台返回与15次快速开关最终关闭通过。布局矩阵8.594秒含等待；95个导航帧处理累计0.12053秒，平均约1.269ms/帧，只是缩图和CGImage生成耗时，不是屏幕FPS或全应用CPU指标。
- `testLiveAndRawPhotoPipelineRestoresAfterNavigation`：实际HEIF+配对MOV资源和DNG均交付，原生拍摄后导航恢复；不是只改应用详情文字。
- `BasicVideoPhysicalTests.testRepeatedVideoRecordingsAndPhotoModeReturn`：普通三轮录像与返回拍照回归通过，导航没有接入视频。
- `DualCaptureExpansionTests.testInsetNativeGestureConfigurationAndDispatch`：共享小窗手势分派回归通过；实际手指体验仍待现场确认。

当前配置hardwareCost0.5、systemPressureCost约0.99861；主路硬件2倍、UI逻辑8倍、广角导航180×240实际出图。压力预算余量较小，未做高温、电话中断、长时热稳或独立功耗验收，不能据短测保证长期持续开启。其他机型/iOS18–26、48MP专项、极慢快门/所有白平衡对焦组合、近距导航框精度与真实手指手感尚未全面验收；未全量回归。

真机截图已目视确认：导航内容、白色范围框可见，无画幅切换按钮，与直方图及操作按钮不重叠。截图设备未固定，不用它判断内容自然朝向或跨镜头精确几何配准。

## 保留失败与范围变更记录

- `Initial`测试调用了不存在的flushZoom/照片data接口，编译失败；改用现有节流变焦与resources接口。
- `Initial2`能出图，但试图跨会话搬运同一输出，恢复时触发系统detach断言崩溃。改为独立输出。
- `IndependentOutputs`在切视频时仍触发MultiCam未闭合配置事务内stopRunning异常；随后取消替换引擎普通session，采用完全独立的导航图，普通session及outputs不动。
- `SeparateGraphs`、`InputBudget`、`LowerCostFormats`、`NavigationBudget`：照片出图/出片恢复已过，1080p视频压力估计1.607，辅助超广角估计1.513，按预算拒绝，相关视频断言失败。未通过提高上限绕过。用户后续明确视频暂不做，删除视频导航接入和音频路径。
- `PhotoOnly`一项通过。`PhotoAcceptance`M挡文件EXIF通过，但切主画幅有一组小窗变方形；改为绘制/移动第一帧直接计算当前比例后`LayoutFix`两项通过。
- `FinalChecks`测试读错照片能力属性编译失败，改为availablePhotoFormats；`FinalChecks2`三项及最终`ReleaseChecks`五项通过，没有删除或放宽EXIF/避让断言。
- 系统MDB_MAP_FULL/Fig文本仍出现，最终运行错误通知审计未失败，不宣称系统日志零错误或已解释根因。

## 产物

- `/private/tmp/LumaCamera-FocusNavigator-ReleaseChecks.xcresult`及同名`.log`
- `/private/tmp/LumaCamera-FocusNavigator-FinalChecks2.xcresult`及同名`.log`
- 前述各阶段日志以`/private/tmp/LumaCamera-FocusNavigator-`为前缀，保留原始失败和崩溃诊断。
- 截图：`/private/tmp/LumaCamera-FocusNavigator-Images/4B40DBB7-5579-44D6-8658-A64CEF127FFA.png`
- [结构化结果](2026-10-26-PhotoFocusNavigation-results.json)

## 最终安装

正常签名Debug最终构建通过，安装序号12448，已通过devicectl成功启动。最后补齐引擎析构时在会话队列释放导航图；没有加入视频导航入口。
