# 2026-10-24 M 挡主摄 HEIF 人像入口修复

## 复现与原因

iPhone 17 Pro / iOS 27.0.1（24A446），后置物理主摄 M 挡、HEIF、标准分辨率、Live 关闭。入口实际报“当前镜头没有可用的兼容拍摄规格”。

`/private/tmp/LumaCamera-PortraitM-EntryBaseline.xcresult` 复现 1 个失败方法：活动路线支持 HEIF/JPG、12MP/48MP，但 supportsPortraitCapture=false；原代码把 photoOutput 的原生 depth/matte 能力合取值直接当作应用人像入口能力，并传播到所有焦段表。进入 M 挡物理主摄后原生管线不可用，因此 preparePhotoSubmode 找不到兼容镜头。另一个问题是单张提交前即便已有可用 Vision 后备流程，原代码仍将 portraitMode 清除并回调关闭人像。

这是本机当前路线的实际观测；不是“苹果禁止所有设备 M 挡人像”的官方结论。Apple [深度交付能力](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/isdepthdatadeliverysupported) 随设备/格式变化；[原生人像蒙版配置](https://developer.apple.com/documentation/avfoundation/configuring-camera-capture-to-collect-a-portrait-effects-matte) 要求按实际支持开启，且不保证每张有蒙版。独立的 [Vision 人物分割](https://developer.apple.com/documentation/vision/vngeneratepersonsegmentationrequest) 不以该照片原生深度交付开关为前提。

## 修正

- 分开“应用人像可用”和“原生 depth/matte 管线支持”：有兼容 JPG/HEIF 标准照片输出时允许既有软件人物分割入口。镜头表逐路线计算，不借用当前输出的原生支持值禁用所有其他镜头。
- supportsPortraitCapture 现在明确为应用能力；原生输出开启和每张 PhotoSettings 的 depth/matte 仍按真实系统属性判断，未伪造硬件支持或调用不支持的开关。
- 原生管线不可用但照片规格兼容时，保留 portraitMode 请求，交给已有 finishCapture 的 Vision 静态人物后备处理；有原生蒙版继续优先使用原生结果，无可用人物蒙版继续保存清晰照片并记录实际诊断。
- 不把 M 挡切成 A 挡，不强制换成虚拟镜头，不改动按钮布局。HEIF/Live 关闭组合可用；人像开启时仍按既有规则关闭 Live，不全局禁用普通 HEIF 的 Live。
- RAW/ProRAW 沿用既有格式判断、原生辅助数据和原文件保存逻辑，不能据此宣称 M 挡 DNG 已产生蒙版或已烧录虚化。本轮修复与验证重点为 HEIF。

## 实际验证

设备正常项目签名、真实相机，未使用镜像或模拟器。临时捕获替换回调，不写入系统相册。

- `...-EntryFix.xcresult`：4 项通过。原有失败入口变为可用，M 挡 HEIF 实际出片约 0.556 秒；快门后人像仍开启，模式仍为 M。
- `...-EntryVerified.xcresult`：最终定向 **4 项通过、0 失败，12.254 秒**。软件入口策略、原有人像格式策略、6 次 A 挡人像开关维持虚拟多摄 auto、M 挡实际捕获与恢复均通过，未记录会话 runtime error 或视图更新期间 Publishing changes 警告。
- M 挡共 4 次 HEIF 出片：0.496、0.673、0.717、0.386 秒，中位约 0.584 秒；前 3 张为 M 挡自动曝光，最后 1 张为手动曝光。测量为捕获提交到临时结果回调，30 ms 轮询，含观察延迟，不含系统相册写入。
- 覆盖 3 轮人像关闭/开启、3 轮 A→M 往返，HEIF 保持、Live 关闭、人像不自动退出、主摄焦段仍可选。最后手动参数设为 ISO 200 / 1/125 秒，等待真实传感器读数后拍摄，在实际编码文件 EXIF 中核对到相同数值，没有仅依赖应用详情文字。
- 本轮取景没有可用人物，诊断为“未生成可用人物遮罩，保留清晰原片”。因此证明的是入口、请求保留、文件和模式恢复，不将本轮写成 M 挡真实人物虚化质量已验收；人物分割与渲染的既有人物样片验证见前一份人像优化报告。

上述结果前缀均为 `/private/tmp/LumaCamera-PortraitM`，同名 .log 保存具体参数与阶段。

## 中间测试与保留问题

扩大运行 PhotoOptionsTests 的 `...-EntryFinal.xcresult` 共 22 项，2 个方法产生 5 条失败断言：

1. 手动参数检查在异步自定义曝光尚未生效时立即按快门，读到上一自动曝光帧。测试现在先等待真实读数再验证本次人像文件；最终 EXIF 检查通过，没有为通过断言而修改生产曝光数值。**快速调参后立即拍摄能否沿用旧曝光仍是独立时序边界，本轮未改全局捕获同步。**
2. `PhotoOptionsTests.testNewRatiosAreCenteredAndXPANUsesFilmGateRatio` 的奇数像素裁切中心为 60.5，旧断言要求 60.0，共 3 条；本次未改 FrameRatio。已单独记录到待办，未改界面或裁切算法来消除该测试，不影响入口修复的最终 4 项通过结论。

未对所有 M 挡焦段、画幅、RAW/HDR/Live 组合或长期热功耗做全量验证，也未将本次描述为全量测试全部通过。

正常版 `/private/tmp/LumaCamera-PortraitM-FinalApp.log` 构建成功，已用项目原签名安装并在连接的 iPhone 启动。
