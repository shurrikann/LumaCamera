# 2026-10-30 电影模式焦段与 M 挡参数

## 当前行为

后置电影模式 A/M 挡均只显示主摄和 2× 两个焦段按钮。主摄选中时点击在 24mm（1×）与 35mm（35/24≈1.458×）之间循环；从 2× 点击主摄先回到 1×。35mm 是同一路线的数字取景，不新增物理镜头。连续变焦轮限制 1–3×，同时受当前设备格式实际电影变焦上下限约束。退出电影模式恢复普通焦段和变焦范围。前置仍按实际电影格式能力提供取景，不强行开放后置范围。

电影模式 M 挡仅显示曝光、白平衡、色调，三个按钮居中，圆形视觉尺寸仍为42点；快门、ISO、手动对焦入口隐藏且禁止程序入口打开。隐藏期间使用自动曝光与系统电影主体跟踪对焦，保留手动标志/设置，退出后恢复六项入口和相应参数。仅参数行局部动画，遵循减弱动态效果，不移动焦段条及其他固定控件。

## 实现与官方边界

CameraViewModel 负责按钮过滤、主摄24/35mm循环、参数可见性与自动曝光策略。CameraEngine 在 A/M 连续变焦时保留兼容的系统电影采集设备，不落回普通虚拟多摄或 M 挡单摄；publishCapabilities 与实际变焦都使用格式声明的电影范围。按钮不创建虚假的35mm设备ID，能力矩阵继续用真实焦段目录。

苹果提供的是格式级 [videoMinZoomFactorForCinematicVideo](https://developer.apple.com/documentation/avfoundation/avcapturedevice/format/videominzoomfactorforcinematicvideo) / [videoMaxZoomFactorForCinematicVideo](https://developer.apple.com/documentation/avfoundation/avcapturedevice/format/videomaxzoomfactorforcinematicvideo)，不能据此保证所有设备都有相同范围。本机后置电影路线为系统双广角，显示倍率乘数0.5；实测物理倍率2–6对应界面1–3×。M挡电影对焦继续沿用系统tracking focus API。

## 真机结果

设备 iPhone17Pro，iOS27.2（24B119），Xcode27.1。

- 最终组合回归8项0失败/0跳过，电影专项10.402秒及连续变焦7项；日志 `/tmp/LumaCamera-Cinematic35-Verified.log`。同轮前一批前置子模式取景专项单项35.773秒通过，`/tmp/LumaCamera-Cinematic35-Test.log`（该批电影旧测试断言仍按重复1×不切35mm，12条断言失败，已更新初始化与循环断言并最终复测通过）。
- 补充硬件曝光专项1项0失败/0跳过，10.430秒；`/tmp/LumaCamera-Cinematic35-Hardware.log`。A/M 每种8个倍率样本（含0.5/4越界请求）共16样本，均保持同一实际电影采集设备及cinematic input启用，实际物理倍率符合显示倍率/0.5，M挡手动曝光标志保留但硬件customExposure=false。
- 35mm重复点击/回到24mm、2×及A/M往返；5视频画幅×0°/90°内容方向共10布局，焦段按钮40点且处于自适应背景内，WB中心与屏幕中心误差≤1点，EV/TINT等距；真机截图已人工核对。使用实际安装的CameraView，未再出现抽取子视图引起的SwiftUI Environment默认值警告。
- 3轮电影开关恢复六参数并重开、每轮20个快速倍率请求（共60次）、转盘正反极限拖动、关闭/重开、真实3×1080p30短片，实际文件1920×1080、帧率30±1通过。临时视频直接回调到测试并删除，不写系统相册。
- 性能：最终硬件专项16样本，倍率请求到串行队列清空/就绪的中位16.31ms，最大31.63ms。指标包括flush/settle，不代表用户点击到屏幕首帧，也不代表实际显示帧率；不报告测试进程内存为App内存。

- Release 真机构建通过：`/tmp/LumaCamera-Cinematic35-Release.log`，源码编译警告0；保留工具链“未依赖AppIntents，跳过元数据提取”提示。

## 限制

未全量回归，未重新跑所有4K/HDR/外盘组合，也未量测实际显示帧率、热稳定或连续长录像。本轮仅本机确认后置1–3×，其他机型与前置继续服从实际格式能力。系统日志仍有Motion/LMDB缓存消息，非源码编译警告，相关功能断言通过。
