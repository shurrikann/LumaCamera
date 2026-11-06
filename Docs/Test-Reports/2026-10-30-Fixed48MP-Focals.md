# 48MP三固定焦段、M挡曝光与切换提速

## 当前行为

- 本机A/M挡48MP焦段条仅显示支持高像素的0.5×、1×、4×原生物理镜头，切换保留48MP；从裁切倍率进入时回到对应传感器原生倍率。1×不轮换35mm。
- 按钮保留普通条40×40点，共同背景由212点收至128点并居中；A/M及工具按钮不移动。局部焦段条淡化/宽度过渡180ms，减弱动态效果分支80ms，不在全页加动画。
- 转盘、长按变焦、预览捏合、A挡实体控制连续滑块和引擎连续变焦均禁用。回12MP恢复普通焦段与变焦。
- 用户确认的M挡规则：选择48MP时使用自动曝光实际数值，手动白平衡和焦点继续可用；用户调整ISO/快门或切到手动曝光时，先降12MP再按手动值拍摄。不伪造48MP或只修改EXIF标签。
- 用官方setPreparedPhotoSettingsArray为高像素JPG/HEIF预分配资源并等待完成，替代额外预拍/丢弃；等待期间对应焦段内显示小加载圈。回普通规格清空prepared设置。没有增加定时AF、距离切镜或改变普通系统微距。

## 平台依据与曝光边界

Apple在[高分辨率采集说明](https://developer.apple.com/videos/play/wwdc2026/304/)明确48MP处理照片使用balanced或quality优先级；[手动曝光说明](https://developer.apple.com/documentation/avfoundation/avcapturedevice/setexposuremodecustom(duration:iso:completionhandler:))要求speed才能严格保留自定义ISO与快门。真机实验中M挡speed实际交付12MP；改quality可交付48MP，但设定1/125秒实际变成约1/33秒，故没有把quality包装成严格手动曝光的解决办法。

最终48MP自动曝光使用balanced；用户操作ISO/快门触发12MP的严格speed路径。高像素手动WB快照有效色温/tint，正式提交前等setWhiteBalanceModeLocked完成，避免快切后的首张仍以自动WB状态交付。这里验证手动WB状态及EXIF，不替代色卡色度准确性测试。

[官方资源准备API](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/setpreparedphotosettingsarray(_:completionhandler:))预分配后续照片所需资源，不是拍摄；可跨会话配置保留资源，清空数组可回收。照片最大尺寸仍为上限请求，不能因此承诺所有环境均交付48MP，实际输出继续核对。

## 最终真机验证

设备iPhone17Pro / iOS27.2（24B119），Xcode27.1 / iOS27.1 SDK。最终18项通过、0失败、0跳过，86.591秒；不是全量测试。

- 日志`/tmp/LumaCamera-Fixed48-AllFinal.log`；结果`/tmp/LumaCamera-WarningAudit-DD/Logs/Test/Test-LumaCamera-2026.10.30_09-47-04-+0800.xcresult`。
- A/M×三个原生镜头正反向共12次操作，交付12份实际JPG/HEIF，均6000×8000。每次核对物理设备身份、virtual=false、physicalZoom=1、responsive=false；即换镜后首张正式请求，不先拍正式照片来掩盖首次回落。
- M挡6份高像素文件均保留手动WB标记；ISO及快门两条真实参数编辑入口分别验证进入手动并降12MP，另2份成片核对尺寸及约ISO200、1/125秒的实际EXIF。诊断资源直接接管引擎回调，未写系统相册。
- 9次实际物理输入切换（排除重复选当前镜头、排除测试前固定120ms等待）从原生UIButton动作至会话/资源准备完成0.437–0.836秒，中位0.626秒。不是光学合焦时间、屏幕完全稳定时间或FPS。
- 早期额外预拍方案同类9次换镜，减去固定120ms测试等待后中位约1.103秒；当前约0.626秒。此为开发过程观测，期间同时调整过质量策略，不是只改变一个变量的严格A/B实验，不承诺所有设备同等百分比收益。
- 7种照片比例×0°/90°内容方向共14配置、42个焦段中心实际窗口命中，按钮40×40不变，背景128点，A/M及工具坐标不变。当前设备“减弱动态效果”关闭；80ms分支按代码处理，本轮没有切系统设置做真机逐帧验证。窗口命中和原生控件动作不等同于手指完整UI事件注入。
- 200次原生选中/高亮/布局工作约3.70ms，不是帧率。测试覆盖短按/长按互斥、取消、回普通分辨率后转盘/连续变焦恢复、快速48→12回退及A/M转盘反复重开。
- 48MP智拍仍保持当前固定倍率，HDR建议遇到实际12MP RAW会回落真实规格，退出夜景恢复48MP通过；普通白平衡三轮M/A切换、旧自定义WB事件到虚拟路由安全通过。
- 最终Release成功，源码警告0；日志`/tmp/LumaCamera-Fixed48-Release-Verified.log`。Xcode无App Intents依赖的元数据工具提示仍有，不关闭编译器检查。

## 过程记录与限制

- 首轮测试错误地写入系统只读accessibilityReduceMotion环境值，编译失败；改为记录真实系统状态，不把人为布尔值当作系统设置已覆盖。
- 启动时照片能力原先在lensCatalog建立前发布，导致新固定焦段ID列表为空；改为完整目录建立后发布静态能力，不在每帧扫描设备格式。
- 初版虽切到物理镜头且请求48MP，换镜首张仍返回12MP；扩展预拍后A挡恢复。随后发现M挡严格手动曝光的speed限制，并经用户确认采用“48MP自动曝光、调整曝光回12MP”的规则。最终以官方资源预分配替代预拍，通过首张文件核对。
- 更快准备暴露手动WB首张状态未就绪，补充高像素提交前的官方WB锁定回调等待，最终6份M挡EXIF手动WB通过。
- 旧测试假定选48MP必回主摄，以及白平衡虚拟路由测试继承前一项高像素状态，分别修正为显式测试主摄基线和统一fresh fixture。另发现35mm进入高像素时continuousZoomActive遗留导致显示倍率未归位，已在高像素路由切换清理旧节流和连续标志，最终智拍1×检查通过。
- ISO/快门回退成片最初在上一个超宽画幅下测试，实际裁切约5.9MP；改为回4:3再核对12MP，未以放宽尺寸阈值掩盖画幅裁切。
- 本轮三固定焦段完整产品验证为SDR JPG/HEIF；先前RAW审计可证明传感器能力，但不代表本轮六格式及所有HDR/人像/Live/长曝光组合均验收。低光、热负载、多机型和完整冷启动持久化仍需专项；没有将测试进程内存当成应用内存，也未测应用内存峰值。

代码主要位于CameraEngine（能力发布、物理路由、资源准备、变焦门控、WB提交）、CameraViewModel（48MP固定焦段与曝光状态）、CameraViewfinder/CameraFocalButton（槽宽与局部进度）。旧“切其他焦段统一回12MP、48MP只主摄”记录属于历史，当前规则以本节为准。
