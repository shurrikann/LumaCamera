# 2026-11-01 录像变焦轮、焦段条及慢门预设颜色

最新交互和3秒自动隐藏见[后续验证](2026-11-01-Video-Zoom-Interaction.md)。下面的5秒计时、自动打开及24方法结果是首轮历史记录。

## 首轮行为（后续已调整）

- 顶部慢门按钮的已选预设名称使用主题橙色，取消选择后恢复原色；下方时长保留原有颜色规则，弹窗样式和按钮尺寸不变。
- 开始录像时显示变焦轮，焦段条隐藏；变焦轮收起后焦段条在原位置恢复，可以点焦段再次打开变焦轮并实际变焦。长按、拖动、缩放及固定焦段共用录制倍率处理，其他按钮不移位。
- 拖动持有时保持轮盘；松手后5秒无操作自动收起。再次操作取消旧计时并重新计时，停止录像、退出或关闭弹窗取消待执行任务。
- 录制中在当前输入和格式允许的倍率内设置videoZoomFactor或ramp，不替换相机输入、不重新配置拍照输出、不降视频规格。虚拟多摄的物理供图仍由系统决定；物理输入只更新该设备的逻辑焦段状态，避免把数字裁切标成另一颗物理镜头。焦段条按现有规格兼容性及实际录制倍率范围筛选；双摄录制仍不开放变焦。

## 实现与官方参考

CameraEngine在开始录像时发布当前输入的videoRecordingZoomRange并固定recordingZoomDeviceID。setContinuousZoom允许实际录制阶段通过，applyContinuousZoom在录制期间转入applyRecordingZoom，只锁定并调整原设备的变焦属性。CameraViewModel允许录像中的焦段点击和轮盘操作，以单个可取消Task执行5秒收起；录像状态结束共用endZoomDial清理。固定焦段原生按钮仍处理短按/长按；变焦轮出现时焦段条维持占位但隐藏及退出辅助功能访问，原变焦触摸面负责拖动。人物居中、双摄等不相关按钮继续沿用录像隐藏状态。

苹果明确要求调整变焦前取得配置锁，使用实际配置的[minAvailableVideoZoomFactor](https://developer.apple.com/documentation/avfoundation/avcapturedevice/minavailablevideozoomfactor)与[maxAvailableVideoZoomFactor](https://developer.apple.com/documentation/avfoundation/avcapturedevice/maxavailablevideozoomfactor)；[videoZoomFactor](https://developer.apple.com/documentation/avfoundation/avcapturedevice/videozoomfactor)直接设置倍率，[ramp](https://developer.apple.com/documentation/avfoundation/avcapturedevice/ramp(tovideozoomfactor:withrate:))进行平滑倍率变化。录像中保持同一输入和规格是本项目实现约束，下面的真机结果不扩大为每种编码和路由的保证。

## 验证结果

设备iPhone17Pro，iOS27.2（24B119），Xcode27.1。证据根目录 `/tmp/LumaCamera-RecordingZoom-20261101`；`RecordingZoom-Core/Video/Regression/Final.xctestrun`位于 `/tmp/LumaCamera-NightCancel-DD/Build/Products`。24个不同方法有通过结果；最终4个录制/布局方法全部通过，79.142秒，慢门颜色在Core2独立通过，另外19个关联方法在Regression通过。未重跑全项目或把重复方法叠加计数。

| 实际HEVC SDR 1080p30录像 | 硬件倍率变化 | 完整解码帧数 | 输入与规格 |
| --- | --- | --- | --- |
| 前置A | 1.000→1.436 | 51 | 保持 |
| 后置M | 2.000→2.873 | 68 | 保持 |
| 后置A | 2.000→2.873 | 451 | 保持 |

真实原生焦段按钮在轮盘收起后命中并触发2×变焦，查询相机会话队列实际videoZoomFactor，未仅断言提前发布的目标值。M挡另验证4.5×仍使用原物理设备的逻辑焦段。每段20个快速倍率请求、10对轮盘快速开关，停止时清理轮盘与任务；影片在测试结束后删除，不写系统照片。

后置A实录中持续拖动持有5.2秒，轮盘不消失；松手后再次操作重置计时，新的4.5秒时仍显示，约5.032秒后收起。该值包含轮询观察误差，不是精确系统计时保证。焦段条恢复后框与原框相同。

布局矩阵80组＝320/402点宽×A/M两挡×五种可选视频比例×四控件角度。使用真机界面与注入录像状态，核对轮盘显示时焦段不接收点击、轮盘仍有拖动区域、收起后按钮原位可点；不是80段实际录像。系统减弱动态效果沿用AppTheme时长，本轮未手动切换系统开关。

慢门五预设选择、六次未选择状态的实际像素颜色检查通过。11次截图绘制中位23.341ms、最大32.851ms；80组布局中20次截图中位28.495ms、最大35.136ms。以上是截图绘制成本，不是显示FPS或手指延迟。

19项关联覆盖焦段原生命中/短按/长按/取消/旋转标题/玻璃背景、连续倍率策略、节流5000次请求/刷新/取消/镜头边界、变焦触感及真机A/M拍照转盘重开。最终Release通过，源码警告0，仅AppIntents元数据工具提示无对应依赖；手机已恢复普通App。

## 早期结果保留及限制

Core首轮4方法失败：颜色测试未观察模型变更；前置按钮标签与普通焦段不同，随后用例未恢复后置基线。修正测试后Core2颜色/前置通过，两个后置触摸断言发现轮盘透明触摸层挡住了同时显示的焦段条；临时避让方案Video3仍两项失败，改为实时避让后Video4三实录通过。随后Regression共21方法，20通过，旧“轮盘与焦段条同时显示”矩阵1方法296条断言失败。用户进一步明确轮盘出现时隐藏焦段条，最终删除该临时避让方案，恢复原触摸面并验证互斥显示；Final四方法全部通过。所有旧日志保留，未覆盖失败结果。

真机实录只覆盖上述三路常规视频；全部帧率/编码、电影模式、人物居中、RAW外接盘和双摄录制未逐一实录验证，双摄仍保留原变焦限制。没有长期热稳、真实屏幕帧率或应用内存峰值结论。此前横拍保存方向专项独立见[记录](2026-11-01-Library-Upright-Fill.md)，旧错误方向文件未改写；慢门长期返回冻结和星轨尺寸元数据待办保持原状态。
