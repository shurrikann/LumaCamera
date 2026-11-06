# 2026-10-30 人像与虚拟光圈顶部调节

## 最终范围

保留调节按钮在照片顶部工具栏原Live位置，人像显示ƒ及虚化百分比，虚拟光圈显示光圈图标及数值。模式关闭恢复原槽位选择；照片HEIF Pro时，模式调节优先于Pro影调按钮，格式弹窗补充Pro影调入口，避免原先HEIF Pro分支挡住调节按钮。

按用户最新要求，滑条完全恢复修改前的位置/尺寸：工具栏下方居中，宽190、高32、底部overlay向下偏移42；保留原先两种滑条背景，不采用本轮尝试的右侧230×44布局。只对滑条浮层淡入淡出，遵循减弱动态效果，不重排焦段或其他固定控件。原居中位置在极窄取景等情况下不保证与直方图永不交叠，本轮遵从恢复要求，不据此宣称全面消除遮挡。

## 逻辑修正

- 打开调节先收起其他功能弹窗；打开格式/画幅/影调、辅助、功能、模式、手动参数时关闭调节，避免叠层冲突。工具栏切到参数读数页关闭调节，切回不自动重开。
- 非相册流程离开相机、设置/后台时，两类滑条统一收起，取消自动收起任务并结束编辑；相册沿用生命周期例外。
- 持续拖动期间取消五秒计时，拖动结束重新计时，避免长按超过五秒时滑条突然消失；虚拟光圈与人像浮层消失均释放编辑状态。
- 清理CameraView里重复的DEBUG人像QA恢复分支。视频虚拟光圈保持底部现有调节入口，此次顶部替换仅照片模式。

## HEIF Pro

两个模式原有格式/编码策略已支持HEIF Pro，没有把格式回落为普通HEIF。本轮确认模式切换保留HEIF Pro，拍摄PhotoOptions.usesRAWCapture为true，完成实际拍摄与HEIC编码。人像HDR/高动态仍按原有兼容规则，不因为HEIF Pro格式可用就额外开放。没有更改RAW解码、人像渲染或星芒算法。

## 验证

设备iPhone17Pro / iOS27.2（24B119），Xcode27.1。`/tmp/LumaCamera-DepthToolbar-Restored.log`：21项0失败/0跳过，29.672秒，包含本次真机专项1项26.546秒与PhotoOptionsTests20项3.126秒。

32布局为2模式×8画幅×2内容角度（0°/90°）；实际安装CameraView验证入口存在、浮层190×32且相对工具栏位置一致，数值不旋转，截图已人工核对。每个模式持续编辑5.25秒不消失、20次快速开关（共40次）、格式/辅助互斥、翻页、停止重启相机、模式退出恢复通过。

人像与虚拟光圈各拍摄一次HEIF Pro：请求保持RAW输入，实际资源类型public.heic，Exif字典存在，字节数分别300270/770430；通过测试回调取回数据，不加入系统照片相册。该结果确认格式请求和文件交付，不代表复杂人物分割或星芒效果质量验收，也没有从HEIC容器本身推导RAW来源。

性能为20次真机快照drawHierarchy同步绘制：中位33.37ms，最大37.49ms，非真实显示FPS/拖动延迟，不将测试进程内存作为App内存。

此前 `/tmp/LumaCamera-DepthToolbar-Verified.log` 中21项有2条直方图不交叠断言失败，发生在已撤销的右侧布局；不能写成该方案验证通过。最初测试引用不存在的CapturedPhoto.format已在编译阶段修正为PhotoOptions请求与真实文件容器检查。最终恢复布局未保留原方案的“直方图不交叠”断言。

Release真机构建通过：`/tmp/LumaCamera-DepthToolbar-Release.log`，源码警告0；工具链仍提示未依赖AppIntents而跳过元数据提取。

## 官方参考与限制

布局遵循SwiftUI的[overlay](https://developer.apple.com/documentation/swiftui/view/overlay(alignment:content:))浮层机制和[accessibilityReduceMotion](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion)。这些API不是本App位置/动画性能的保证；上述位置及稳定性来自本机检查。未全量回归，未验证所有机型、48MP/HDR组合或真实人物/点光源主观画质。
