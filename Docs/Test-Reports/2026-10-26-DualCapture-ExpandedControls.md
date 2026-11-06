# 双拍规格开放、可移动小窗与双击交换（2026-10-26）

## 当前行为

双拍按本机公开MultiCam格式与已录制验证组合的交集开放。用户可在原选择器调整规格；不可组合的选项禁用，不把单摄能力当作双拍能力。前置小窗可切标准/超广角。支持范围：

| 编码与色彩 | 分辨率和帧率 |
| --- | --- |
| HEVC SDR | 720p/1080p：24/25/30/50/60；4K：24/25/30 |
| HEVC P3 | 720p/1080p/4K：30 |
| H.264 SDR/P3 | 1080p30 |
| ProRes SDR 六种常规规格 | 1080p30 |
| ProRes 422 HQ SDR | 4K30 |

比例支持4:3、1:1、16:9、2:1、2.39:1，共25种编码/色彩/分辨率/帧率组合。前置最多30帧，50/60帧主路会复用最近的前置帧；不是两路同步曝光。HDR、Log/Log2、RAW/RAW HQ、120帧及Open Gate暂不开放。当前仍为竖向合成文件，未新增横向双拍轨道输出。

小窗拖动位置同时用于预览及编码合成，并约束在画面边界内。单击不交换，双击交换主副画面；拖动不重建相机会话。保存拍摄设置开启时，位置与前置画幅一起恢复。规格替换失败尝试恢复上一套规格；准备中不能录制。关闭恢复普通规格（包括ProRes子规格）。

## 官方依据与实现边界

采用[Apple AVMultiCamPiP](https://developer.apple.com/documentation/avfoundation/avmulticampip-capturing-from-multiple-cameras)显式连接和最近副帧方式；可用格式依据`isMultiCamSupported`、原生尺寸、色彩与帧率枚举，启动后仍检查实际硬件/压力成本。UIKit的`UITapGestureRecognizer.numberOfTapsRequired=2`负责双击，`UIPanGestureRecognizer.translation(in:)`以窗口坐标计算累计位移，避免窗口自身移动产生坐标反馈。规格表是本设备实测开放范围，不是苹果对所有设备的保证。

## 实际验证

设备iPhone17Pro / iOS27.0.1，正常项目签名，未使用镜像或模拟器，诊断媒体未保存到系统相册。

- `FinalTests`四项通过，63.848秒。25组实际选择/录制/完整BGRA解码，共659帧，五种比例轮换；每组录像中20次位置提交，共500次，并双次交换。文件比例、会话互斥、前置帧率≤30、最后合成位置均断言通过。
- 各组约0.8秒短片；从提交规格到录制、解码结束的总耗时中位1.712秒，范围1.104–1.883秒，含固定等待与文件解码，不能作为切镜延迟或FPS。写入日志未见notReady/appendRejected/unscheduled背压丢帧。
- 三轮开关双拍，新帧就绪进入0.603/0.573/0.438秒，退出0.407/0.424/0.425秒。录制中交换、滤镜实际解码、手动实参、准备中取消、后台/照片恢复通过；冷启动恢复位置(0.1,0.55)和前置广角通过。
- `Pixels2`的像素用例通过：五种比例×三个位置共15次，合成图小窗中心为预期副路颜色。其手势用例因未挂载SwiftUI视图失败；挂入真实窗口后`Gestures`用例通过（0.270秒），确认1/2次点按识别器及拖动识别器配置、单击零动作、双击一次交换和100次拖动分派。识别器动作使用受控状态，不冒充真实手指轨迹/手感验收。
- 初次`Pixels`测试辅助代码缺少SwiftUI导入、只读覆盖可变state导致编译失败，修正后继续；保留原始日志，不抹除失败记录。
- 日志仍出现系统`MDB_MAP_FULL`及拆会话阶段Fig -12784断言文本；测试的会话运行错误通知审计未失败，未确认这些系统文本的根因，不宣称系统日志零错误。

共6个不同相关测试方法有通过记录，未做全量回归。短片不代表长时间热稳定性/功耗，未验其他机型、iOS18–26、电话中断/高温，真实手指拖动体验待现场确认。

## 复现产物

- `/private/tmp/LumaCamera-DualExpansion-20261026-FinalTests.xcresult`与同名`.log`
- `/private/tmp/LumaCamera-DualExpansion-20261026-Pixels2.xcresult`与同名`.log`
- `/private/tmp/LumaCamera-DualExpansion-20261026-Gestures.xcresult`与同名`.log`
- [逐组JSON](2026-10-26-DualCapture-ExpandedControls-results.json)

## 最终运行

正常签名Debug构建通过，已安装至同一iPhone（安装序号12176），`devicectl`启动成功。没有使用镜像检查。
