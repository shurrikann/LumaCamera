# 视频与拍摄控件旋转：暂停于 2026-10-16

用户要求先更新稳定版，视频和其他功能明天继续。这里是未完成草稿，不属于 App target，不应当作已实现功能。相机中的视频入口仍是预留入口。

## 已确认需求

- 视频 A/M 两挡；M 包含快门、ISO、对焦、EV、白平衡、色调，与照片的手动操作一致。
- 顶部五项：帧率/分辨率；比例；色彩空间；编码规格；同照片的应用设置。
- 分辨率 720/1080/4K，帧率 24/25/30/60/120，按实际设备格式筛选合法组合。
- 比例 4:3、16:9、2:1、2.35:1。
- 色彩 SDR、P3、HDR、Apple Log、Apple Log 2；本次 HEVC 录制，H.264 与不同 ProRes 规格先入口。SDR/P3 接现有 LUT，Log 滤镜以后再做，HDR 本次不套现有 SDR 滤镜。
- 横拿手机采用原生相机式：拍摄控件位置不变，只旋转图标/文字；照片和视频拍摄界面都适配。相册和照片详情后续也采用控件内容旋转；这些照片界面适配现已完成，视频继续延后。编辑刻度以用户实际横屏视角为竖向。

## 草稿情况与待完成

三个 Swift 草稿：配置/能力匹配，独立采集引擎，HEVC 后处理。尚无 ViewModel、UI、保存流程或入口接线。引擎首轮构建有 async 授权表达式错误，已改为顺序 await；还未完成再次构建。AVFoundation 新 SDK 中的 Sendable 警告初步用 @preconcurrency import 处理，须复核。不要将草稿直接混入稳定版 target 后安装。

设计方向：独立 AVCaptureSession 保持照片路径不受影响；AVCaptureMovieFileOutput 原始录制，停止后逐帧滤镜/裁剪/输出 HEVC，再自动保存。避免复杂滤镜拖慢原生录制 fps。需要验证 Log/HDR 后处理的 10-bit、色域、传递函数与附件保持，不能只改标签；Audio 当前草稿打算 AAC 原码流通过。草稿的 VideoPostProcessor 使用 AVAssetReader/Writer 和 CoreImage，对于 Apple Log 的无色彩管理几何处理、半浮点输出附件、AVVideoLogTransferFunctionKey 的 iOS27 可用性都尚未真机验证。iOS26 AppleLog2 需沿用原缓冲区颜色附件，不得静默转 SDR。

引擎草稿仍需完善：摄像头模式路由、配置回退同步 UI、镜像偏好、预览帧过期丢弃、权限/后台/录制重复点击/导出失败重试、手动快门限制到帧周期、持续自动对焦。读数、A/M 物理镜头路由的实现也待核对。不要破坏已有照片 A/M、Live、过滤器或相册功能。

## 稳定版边界

当前 App source 中只有已完成并测试的照片修复：编辑信息保留、Live 文件导入、当前滤镜/浓度显示。当前滤镜回归 `/private/tmp/LumaCurrentFilterSim.xcresult` 5 项通过，`/private/tmp/LumaCurrentFilterNative.xcresult` 11 项通过；对应版本已安装过。用户真机系统相册不允许新增诊断照片，后续视频诊断也只保存临时文件，Photos 写入可用模拟器测试。

项目 AGENTS.md 要求保留正常功能、用户切换动画及按钮内进度；系统自动换镜不加过渡。最低 iOS18。
