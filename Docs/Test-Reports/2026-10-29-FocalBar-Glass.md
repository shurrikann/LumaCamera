# 2026-10-29 焦段条去除重复背景

## 修正

实际层级为焦段条的 `PreviewSurface.glassEffect` 加选中 `CameraFocalControl` 内部的 `UIGlassEffect`，因此点选后叠加两层。将已有 `usesEnclosingGlassBackground` 标志完整传入原生控件，在创建与 SwiftUI 更新时同步；共同背景存在时不再显示内部选中玻璃或旧系统半透明填充。公共液态玻璃容器、交互配置、描边、尺寸和位置保持原实现。橙色选中文字保留；独立按钮默认仍显示原来的选中玻璃。

未更改镜头路由、触感、长按/拖动或手势优先级。并非删除所有玻璃，也不以普通透明色替代条背景。官方API说明：[UIGlassEffect](https://developer.apple.com/documentation/uikit/uiglasseffect) 与 [UIVisualEffectView](https://developer.apple.com/documentation/uikit/uivisualeffectview)。重复层级是本项目实现观测，不描述为平台缺陷。

## 验证

已连接 iPhone 17 Pro 真机，正常签名；正式 xcresult 为 **7通过、0失败、0跳过**。诊断相册只读隔离启用，本轮没有拍照或系统相册写入。

- 共同容器/独立按钮两种配置各100次布局，共200次，交替选中/取消、按压与24/40点尺寸；共同容器按钮可见内部effect数始终0，独立选中按钮仍为1个UIGlassEffect；视图未累计增加。
- 原点击、长按与拖动、取消/禁用、短/长标题在0°和±90°的布局用例通过。
- 实际相机布局覆盖7种照片画幅、5个后置焦段槽位、20次快速开关和退出重进；焦段条宽度212点，按钮边界和槽位保持稳定，预览继续更新。
- 200次原生布局CPU墙钟约3.62ms，单个样本；这是未呈现每一帧的程序化布局工作量，不能当作屏幕FPS、GPU耗时或触摸延迟。20次快速模式开关脚本0.449秒，7画幅及退出重进检查2.345秒（含固定等待）。没有独立功耗、温度或长期泄漏结论。
- 该真机记录不代表iOS18实机视觉验收；旧系统分支只随相同标志清除重复填充，未启动额外模拟器。

证据：`/private/tmp/LumaCamera-1029-FocalGlass/Related.xcresult`、`Related.log`及`Summary.json`；构建日志`/private/tmp/LumaCamera-1029-FocalGlass-build.log`。结构化汇总另存[FocalBar-Glass.json](2026-10-29-FocalBar-Glass.json)。
