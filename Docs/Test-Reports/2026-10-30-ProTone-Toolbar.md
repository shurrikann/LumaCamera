# 2026-10-30 Pro影调独立按钮与滑条锚定

## 当前行为

HEIF Pro照片模式的顶部顺序为格式、Pro影调、比例、闪光、Live/模式调节、设置。六项均等宽、同高32点；Pro影调图形17点，与其他工具按钮保持轻量视觉。人像/虚拟光圈均保留调节按钮，Pro影调不再被模式按钮替代，也不再放在格式弹窗内。其他格式保留原五项工具栏。格式切换只在工具栏内部动画，弹窗继续淡入淡出并遵循减弱动态效果。

按用户最新要求，景深/光圈滑条横向跟随对应调节按钮；使用真实按钮bounds的Anchor Preference转换到工具栏坐标，不按屏幕比例猜位置。190×32尺寸和工具栏下方10点的纵向间隔保持，靠近边缘时中心限制在109…宽度−109，保证14点边距。横拿仍是竖屏弹窗布局，数值不旋转，不推动焦段条和其他固定控件。此段替代上一轮报告中的“整条工具栏下方居中”。

## 官方依据与实现

使用SwiftUI [anchorPreference](https://developer.apple.com/documentation/swiftui/view/anchorpreference(key:value:transform:)) / [overlayPreferenceValue](https://developer.apple.com/documentation/swiftui/view/overlaypreferencevalue(_:alignment:_:))传递按钮实际边界。CameraToolbar新增DepthToolbarButtonAnchorKey，Pro影调独立于Live/模式分支，CameraToolbarPanels移除上轮临时补充入口。没有变更图像算法、编码或模式兼容条件。

## 验证范围

设备iPhone17Pro / iOS27.2（24B119）、Xcode27.1。定向检查包括人像/光圈×8画幅×0°/90°内容角度共32布局，六按钮等宽同高且影调紧接格式；滑条按调节按钮实际中心或边界限位对齐。20次同步快照绘制不作为真实显示FPS；未测App实际内存峰值。

实际两个模式HEIF Pro拍摄、Exif及HEIC容器检查不写系统相册，保留RAW请求；不由HEIC容器推断RAW来源。重复调节开关、长按超过5秒、格式/影调弹窗互斥、前后台恢复，以及320点/原生宽度格式往返按实际测试结果记录。真实人物画质、HDR/48MP全组合与所有设备未全量验收。

## 诊断记录

第一次给TabView工具行额外设置id时，真机发现切换后滑条状态异常，已去掉该identity改动。窄屏测试的前后台两个CameraView共用同一model，条件按钮几何归属可能落到后台原窗口；测试改为格式切换后重新挂载前台宿主再采样，并显式恢复测试相机会话。中间失败不能记作通过。

Release最终构建通过：`/tmp/LumaCamera-ProToneToolbar-Anchored-Release.log`，源码警告0；工具链仍保留未依赖AppIntents而跳过元数据提取的提示。

## 最终结果

最终专项1项0失败/0跳过，40.323秒，`/tmp/LumaCamera-ProToneToolbar-Verified.log`，结果包 `Test-LumaCamera-2026.10.30_16-16-18-+0800.xcresult`。32种模式/画幅/内容方向布局通过；320点与原生宽度各4轮HEIF/HEIF Pro往返共8轮，确认五/六项宽度、自适应等宽、按钮邻接及影调开关/关闭通过。此前同版业务代码PhotoOptionsTests20项3.013秒通过，未重复全量。

实际人像/虚拟光圈HEIC分别378870/779006字节，Exif存在，RAW请求保持；40次滑条开关、长按5.25秒、翻页/退出恢复及弹窗互斥通过。20快照中位32.32ms、最大37.51ms，仅同步drawHierarchy绘制，不代表显示FPS。最终截图已导出核对，诊断文件未入系统相册。
