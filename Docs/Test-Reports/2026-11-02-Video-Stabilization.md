# 2026-11-02 视频手持防抖

## 问题与实现

用户反馈预览和成片均明显抖动，拍摄规格不详。源码中普通视频输出未设置防抖；真机修复前检查确认录制连接支持防抖，但preferred/active均为off（0）；预览连接当时为previewOptimized（4）。不能由这一条基线推断用户那段未提供的影片全部参数。

configureOutputConnections在普通视频的录制和预览连接上，按当前activeFormat优先启用cinematic（2），不支持时尝试standard（1）；均不可用才off。切换规格/镜头和重建连接时沿用该入口。照片预览恢复previewOptimized（支持且为预览尺寸输出时）或off，照片输出本身不设置视频防抖。RAW保留原始缓冲，Open Gate保持全覆盖，双摄原有off策略未改。本次没有改动编码、旋转、变焦、自动物理镜头选择或手动曝光。

苹果明确说明[preferredVideoStabilizationMode默认off](https://developer.apple.com/documentation/avfoundation/avcaptureconnection/preferredvideostabilizationmode)，连接支持不等于当前格式支持所有档位，实际生效应读取[activeVideoStabilizationMode](https://developer.apple.com/documentation/avfoundation/avcaptureconnection/activevideostabilizationmode)。[cinematic相较standard缩小视场并增加延迟及内存需求](https://developer.apple.com/documentation/avfoundation/avcapturevideostabilizationmode/cinematic)；本项目没有把“电影级防抖”与电影景深模式混为一项功能。

初版尝试auto，真机后置实际选择cinematicExtendedEnhanced（5）、前置选择cinematicExtended（3）；6次模式切换中的3次进入视频，源帧恢复耗时2.273—2.357秒。改为cinematic后，3次进入视频约1.1秒，见原始日志和JSON，不声称零延迟。此取舍来自本机实际观测，不是所有设备的系统保证。

## 验证

设备iPhone17Pro，iOS27.2（24B119），Xcode27.1。证据`/tmp/LumaCamera-VideoStabilization-20261102`；xctestrun配置位于`/tmp/LumaCamera-NightCancel-DD/Build/Products/VideoStabilization-*.xctestrun`。基线1方法通过；auto版Core四方法通过71.449秒，最终档位Core2四方法通过57.235秒。两轮执行相同四方法，不能相加为八个不同方法。

最终7组真实配置覆盖M挡物理0.5×、1×、4×的1080p30/4K60及主摄4K120。录制和独立预览实际模式均为2；120fps复用录制输出预览，没有独立预览连接。设备帧周期、请求规格保持，6次照片/视频往返和一次快速切换通过，照片返回后未残留录像防抖请求。

三路HEVC SDR 1080p30实录：后置A/M、前置A均实际模式2，影片完整解码61/63/62帧，最大PTS间隔约1/30秒，录制前后设备与格式一致。开拍到videoRecording观察值约43/561/522ms，包含队列与轮询，不等于首帧上屏延迟。录像中实际变焦、轮盘3秒隐藏、20次快速倍率请求和10对开关关联回归通过。

性能样本：7次配置到快门就绪观察（每次含固定250ms稳定等待），中位574.432ms、最大767.333ms；6次模式切换记录源帧时间恢复，不是屏幕FPS、输入手感或真实呈现延迟。未测应用内存，不能用测试进程峰值替代。

用户配合正常手持10秒：1080p30 HEVC（1920×1080自然尺寸，90°矩阵竖向显示），完整解码301帧，最大PTS间隔约1/30秒，实际防抖模式2。源帧方向已目视检查。用户反馈“感觉画面还是有些抖动”，因此本次只确认配置缺失修复及编码连续性，不将手持观感优化记为完成。

PhotoReturn一方法通过69.529秒，Live/HDR/M挡6次真实照片文件与10次快速往返通过，实际EXIF含M挡0.5秒；返回就绪观察0.519—1.064秒，非成片总耗时。Release通过、源码警告0，仅AppIntents元数据工具提示。

## 电影、延时、慢动作补查

Submodes2一方法通过15.286秒。后置电影1080p30实际防抖2、完整解码62帧；延时1080p30采集路径防抖2、稀疏成片解码2帧；慢动作1080p240采集/30fps播放防抖回退标准1、完整解码485帧。电影与慢动作复用录制输出预览，延时独立预览模式2。以上为实际测试规格，并非所有镜头规格穷举。延时采集增稳不等同额外的长时间跨帧漂移校正。

首轮Submodes一方法有两条断言失败：测试错误地要求240fps也必须为2；实际标准档1符合格式回退策略。生产代码未改，仅修正测试按可用档位验证，随后通过。最终7个不同功能回归方法均有通过结果，另有基线诊断1方法。

本项目调用系统连接级增稳，没有另做成片二次裁切。苹果[设备兼容性归档文档](https://developer.apple.com/library/archive/documentation/DeviceInformation/Reference/iOSDeviceCompatibility/Cameras/Cameras.html)说明支持视频OIS的设备可由此接口协调光学与电子防抖；电影级电子增稳会缩窄视场。所读active模式不能单独证明当前光学执行机构的状态。

## 限制

本轮自动实录主要为1080p30；4K60/120是实际配置、帧周期及防抖模式检查，没有逐一录制所有规格。标准档回退在所测格式中未触发；全部色彩/编码、双摄、RAW外盘、Open Gate、电影景深及长期热稳没有全量复验。诊断不写系统照片。不以非同时同轨迹的两段手持片声称降抖百分比。
