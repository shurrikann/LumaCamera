# 双拍小窗贴边切画幅保持位置（2026-10-26）

## 原因与修复

`resized`原先保持中心，已贴右边的横幅变窄时右边缘会跟随向内收，底边也有同样问题。现在检测距归一化安全边距0.01以内的贴边状态：左/右/上/下分别以对应边为缩放锚点，非贴边仍保持中心。保留既有安全边距，不改为零边距；原控件、直方图、声音/剩余时间避让优先，不能保证有控件占据的边仍可贴住。原图保持正向的处理路径、变焦和编码不变。

## 验证

设备iPhone17Pro/iOS27.0.1，正常项目签名；仅真机，无镜像/模拟器，不写临时媒体到系统相册。`Checks`4项通过：

- 五主比例×九种边缘/角落/中央位置×100次横竖往返，4500组往返断言；贴边位置不漂移，非贴边中央位置也保持。纯几何用例0.004秒，不是硬件切换性能或FPS。
- 真实会话中左右边缘各6次画幅切换，归一化边距始终分别为0.01/0.99；合计12次，前置倍率实际切换沿用原完成回调。
- 五画幅×四方向布局20组、250个拖动目标、录像中的150次辅助显示避让、显示关闭/恢复、后台/普通模式恢复及五段实际短片解码通过，共141帧。实际综合用例16.740秒，包含等待、布局和编码/解码，不是相机切换耗时。
- 250次模型投影/提交中位0.0646ms，最大0.1118ms；不含异步合成和显示，不当FPS。系统MDB/Fig文本仍存在，运行错误通知审计未失败，未判断根因。
- 测试一度由Xcode等待手机解锁，用户解锁后继续完成；不记为功能失败。没有全量回归，其他设备/旧系统、长时功耗和真实手指手感未验收。

## 对焦辅助技术讨论（未实现）

可以复用当前可移动小窗、按钮命中和辅助显示避让，但取景应来自后置长焦主画面+后置广角导航，而非把前置小窗画面当导航。此前同机公开枚举日志`/private/tmp/LumaCamera-DualCompatibility-20261026-Inventory.log`中的`supportedMultiCamDeviceSets`包含后置Wide+Telephoto组合；这只证明设备组合可同时使用，不代表任意分辨率/帧率/拍照格式可用。

优先沿用[Apple AVMultiCamPiP](https://developer.apple.com/documentation/avfoundation/avmulticampip-capturing-from-multiple-cameras)显式连接方式，按[supportedMultiCamDeviceSets](https://developer.apple.com/documentation/avfoundation/avcapturedevice/discoverysession/supportedmulticamdevicesets)和格式能力筛选，再检查hardwareCost及systemPressureCost。仍需专门验证后置双路预览、长焦取景范围框映射、模式/倍率切换和实际照片/视频规格。建议保留此前8倍及以上入口规则，导航画面仅辅助显示、不烧入媒体；尚未承诺规格，也未新增功能。

## 产物

- `/private/tmp/LumaCamera-DualInsetEdges-Checks.xcresult`及同名`.log`
- [结果JSON](2026-10-26-DualCapture-DockedEdges-results.json)

## 最终运行

正常签名Debug构建通过，安装序号12272，已由devicectl成功启动。
