# 2026-11-02 双拍录制变焦与视频预设变焦

## 修改

- 双拍待机和录制均开放当前主画面的有效倍率，焦段按钮、变焦轮和捏合使用双拍路径；普通录像的录制输入限制不再误拦双拍。前置主画面的宽窄切换也允许录像中使用。
- 双拍高频手势用 LatestValueThrottle 合并为最新请求，最多约30次/秒；不为纯倍率调整刷新 readingsGeneration 或整组预览状态。倍率与最近焦段选中状态及时发布，非24/35mm的实际倍率不再误标24mm。
- 主副交换、退出时取消旧请求；请求同时绑定双拍代次和主画面位置。会话队列明确传入要调整的设备，不跨队列读取合成器的主副标志；交换后读取新主画面的真实范围与倍率。
- 普通视频同输入变焦不再重复配置自动切镜策略；上方按需恢复逻辑及真正输入切换时的配置保留。没有更改分辨率、帧率、防抖、系统自动微距或按钮布局。
- 后置双拍仍是固定主摄输入上的数字变焦，不代表切换到另一物理长焦/超广角；副画面不随主画面倍率改变。

## 官方依据与边界

使用[Apple videoZoomFactor](https://developer.apple.com/documentation/avfoundation/avcapturedevice/videozoomfactor)及有效 min/max 范围、配置锁；这是传感器中心裁切/放大。Apple另提供[ramp平滑变焦](https://developer.apple.com/documentation/avfoundation/avcapturedevice/ramp(tovideozoomfactor:withrate:))；本轮保留既有连续手势和已有点按ramp行为，不声称平台保证无卡顿。双拍继续使用AVCaptureMultiCamSession及原一次编码管线。

## 真机记录

iPhone 17 Pro，iOS27.2（24B119），Xcode27.1，正常项目签名。所有测试启用 DIAGNOSTIC-PHOTOS-READONLY；录像回调拦截为临时文件，结束删除临时文件，无系统相册写入。未启动模拟器或镜像。

最终代码有8个不同相关方法通过：ZoomThrottleTests 5项、CinematicZoomPhysicalTests 1项、DualCaptureZoomPhysicalTests 2项。不是全量测试。

- Related.xcresult：7/7通过，18.400秒。双拍120次20ms间隔手势，77次采集时间戳更新，最大间隔38.941ms；电影16次倍率验证中位16.364ms、最大30.291ms（含队列flush），同设备、电影功能保留、实际1080p30临时文件可用，10种布局基础检查。
- FinalRelated.xcresult：双拍与延时两项通过；慢动作综合方法失败。240fps两段实收约215.753/209.830fps，未达到240±12；分别1/2帧writer未就绪。120fps、固定焦段切换、实际设备与倍率断言通过。保留失败，没有降低断言或静默降规格。
- Validated.xcresult：7通过、1失败。延时最大661.831ms间隔，发现测试只等ready，混入模式启动/电影级防抖初始缓冲；新增等待该路由实际新帧，不用固定休眠掩盖问题。
- WarmRelated.xcresult：最终双拍与延时2/2通过，13.016秒。双拍120次手势，77次采集时间戳更新，最大38.495ms；源帧计数4→96，主摄实际倍率等于末尾目标、副画面倍率不变，sourceID不变；录制中三次主副往返、停止及退出通过。
- 延时三次打开/拖动/关闭，共180次20ms间隔手势，107次采集时间戳更新，最大166.126ms（第3轮第6步），同一输入ID、退出恢复通过。该偶发间隔仍需后续优化，不写成完全流畅。

时间戳来自livePreviewState.latestFrameHostTime，表示应用采集/处理侧接收时间，不是屏幕呈现FPS；轮询可合并多帧，计数也不是实际显示帧数。没有修复前同场景性能基线，不能给出提升百分比；未测长期热稳和所有支持规格。

证据目录：/private/tmp/LumaDualZoom，保留各轮日志及xcresult。最终Release构建通过，仅AppIntents无依赖工具提示；已正常签名安装并打开普通App（不带诊断环境）。见同目录Release.log/Install.log/Launch.log。

## 剩余项

1. VIDEO-ZOOM-001：延时连续变焦偶发166ms采集间隔，尚未完全消除，需区分处理负载/系统采集行为。
2. VIDEO-HFR-001：240fps实际收帧低于目标，单独定位高帧率管线与系统负载；不能仅以格式显示240认定达标。
3. 没有逐一验收所有双拍规格的录制变焦，没有本轮人工屏幕流畅度验收或长时间热稳定性数据。
