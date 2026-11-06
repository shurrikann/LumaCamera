# 2026-11-06 夜景触发、A挡约束与逐帧曝光

- 独立夜景：`syncIndependentNightRoute` 改为仅在 `nightModeEnabled && captureKind == .photo && mode == .auto && nightEnvironmentTriggered` 时启用；环境触发前保持普通夜景/预览路线。实验设置新增默认关闭且不持久化的“强制独立夜景（测试）”，打开后跳过环境触发，方便逐项试拍；重启自动关闭。
- 夜景与M挡互斥：`toggleNightMode` 在M挡先切A；`setMode(.manual)` 在夜景开启时先退出夜景并清理环境触发/独立路线；状态恢复也强制A。
- 移除“亮度优先影调”：删除设置开关、`PhotoOptions.nightBrightTone`、合并器/影调规划中的brightTone分支；保留自适应基础影调。
- 独立夜景逐帧：`setExposureModeCustom` completion 后才 `capturePhoto`；settings/prepared priority 由 `.quality` 改为 `.speed`；每帧读取文件 EXIF 的 exposureTime/ISO，与计划超出容差则失败，不把错误曝光送进合成。
- 普通夜景 `NightCapturePolicy.qualityPriority` 也改为 speed，避免质量优先改变帧时序。
- 元数据：独立夜景解码帧不再丢弃 ImageIO 属性；`NightCompositeMetadata` 以参考帧 EXIF/TIFF 为底写 composite 统计，保留曝光、ISO、光圈、焦距和镜头信息。NightPhotoMergerTests 增加对应断言并通过。
- `NightAdaptiveCapturePolicyTests` 与夜景设置页加载测试在模拟器通过（含新的 speed 规则）。
- 真机测试：设备当前 Xcode 连接不可用，夜景M挡/A挡、独立触发、逐帧曝光、崩溃复现尚未执行；不能记为真机通过。

# 2026-11-06 调色盘浓度共用线性1.3曲线

- 调色盘浓度直接绑定 `filterParameterBinding(.strength)`，写入同一个 `intensity`（0–100 显示映射），渲染走 `FilmStyle.apply`，不存在第二条曲线。
- 新增 `testDialPadStrengthUsesUniformLinearStrength`：80→1.0、100→1.3、0→0。
- 调色盘布局测试同时通过。

# 2026-11-06 浓度为线性1.3倍，80%=参考LUT

- effectStrength改为分段线性：0–80%=0→1，80–100%=1→1.3；取消80%后的二次加速。
- 80%=参考LUT不变；90%=1.15；100%=1.3。外推仍走filterStrength负值钳制，保留>1高光。
- FilterStrengthTests全通过；ImportedFilterTables interpolation测试通过。
- 旧1.5倍/加速实现不再生效，文档已更新。

# 2026-11-06 HDR滤镜按钮仅禁用不改文字

- HDR开启时滤镜按钮展示当前选中滤镜的名称/装备/无障碍值：原片显示“原片”，Leica显示Leica；HDR只负责禁用和dimmed，不覆盖文字。
- 不再显示“HDR/滤镜互斥”；按钮active仍按effectiveLook判断（HDR期间为原片，故不高亮但保留文字）。
- testHDRSuppressesFilterTemporarilyAndRestoresIt增加按钮名断言并通过。

# 2026-11-06 连续微距对焦核查（当前虚拟多摄路线）

- iPhone17Pro / iOS27.2 固定近距静止纹理场景，连续普通HEIF三张、HDR HEIF三张，共六张；快门前后均虚拟三摄、UltraWide供图、连续AF（AF=2），虚拟输入lensPosition约0.776–0.788，constituent读数一直1.0。本轮未看到焦点丢失，不能只凭后者推断失焦。
- 中央256×256区域（源图缩至512宽）的红通道相邻像素平均梯度：普通7.730/7.389/7.291，HDR7.637/7.688/7.660；普通组相对首张最低约94%，HDR基本稳定。此指标受噪点、曝光、构图影响，仅用于同场景异常下降报警，不能换算对焦准确率。目视检查缩略图中的第1、3、6张，主体纹理和文字没有后续明显模糊；未做所有原片100%人工评级。
- 单张完成约0.57–1.83秒，含测试计算开销，不代表快门延迟或帧率。新增定向用例1/1通过，临时媒体未加入系统相册；未验证近物移动、全部格式、全部倍率和长时间连拍。产品对焦逻辑未因本轮核查改变。
- 证据：Test-LumaCamera-2026.11.06_10-39-29-+0800.xcresult；六张附件保存在测试结果与临时导出目录。

# 2026-11-06 微距预切换 + 快门前锁焦（历史方案，A挡已停用）

- 在 macroActive 变真时预切物理超广角；用户构图后快门不再切 input。
- 快门前锁当前 lensPosition，交给 PhotoOutput；第一张前后 focus 0.541→0.541，input 均 UltraWide。
- 连续第二张前仍 UltraWide；第二张后系统可能恢复一次 AF，属于后续独立问题。
- 待用户录屏确认拍照后不再二次放大。

# 2026-11-06 微距触发即切物理超广角

- 用户第二次录屏仍看到拍照后轻微放大；抽帧确认不是查看页，而是快门时虚拟超广角→物理超广角切换/对焦呼吸。
- 改为 macroActive 一变为真就在相机队列切物理超广角、设置显示倍率与连续AF；之后构图和快门都使用同一输入。
- 真机连续两张：拍摄前 input=UltraWide/virtual=false，第一张后仍 UltraWide，第二张仍 UltraWide；快门阶段不再切输入。
- 用户仍可能看到微距触发瞬间的一次系统/预切换，这是预期；拍照后不再二次变化。待用户录屏复验。

# 2026-11-06 微距第一张后预览放大修复

- 根因：第一张拍后系统把虚拟多摄主 constituent 从超广角切回主摄；优先走 virtual constituent 时没有进入物理超广角保持路径。
- 修复：微距路线始终切物理超广角；拍完保持输入，macroActive 期间每5秒续期，离开微距才恢复虚拟多摄。
- 连续真机日志：第一张后 input=UltraWide/virtual=false，第二张仍 UltraWide；不再出现第一张后切回主摄。
- `HDRSequentialDiagnosticsTests` 通过；用户录屏观感待复验。

# 2026-11-06 HDR实验代码清理与用例

- 删除 `HDRFilterLabView.swift`、`HDRMetalPreviewPrototype.swift`、`HDRMetalPrototypeTests.swift`。
- 移除 `CapturePreferences.hdrFilterEnabled`、`CameraEngine.hdrMetalPreviewFrame/setHDRMetalPreviewEnabled`、未使用的 `hdrResidual`/`hdrTintResidualV2` Metal内核。
- 保留调色盘、HDR正式编码路径、A/M临时滤镜抑制、微距修复。
- 新增测试：`testJPEGDisablesHDRAndManualHDRRestoresFilter`；保留 `testHDRSuppressesFilterTemporarilyAndRestoresIt`、调色盘切换、微距策略测试。
- 构建通过；真机锁屏恢复后执行：JPG关闭HDR/M挡恢复滤镜、HDR临时抑制、调色盘切换、微距策略测试全部通过。

# 2026-11-05 HDR预览SDR与滤镜临时抑制

- HEIF/HEIF Pro开启HDR：预览强制SDR，右上角HDR标识；关闭HDR不改变滤镜选择。
- HDR期间effectiveCaptureLook临时回原片（style original、adjustments neutral、virtual aperture nil），滤镜入口禁用；关闭HDR后自动恢复原滤镜/浓度/调色。
- JPG无增益图HDR：切到JPG会关闭HDR，HDR开关仍只对HEIF/HEIF Pro开放。
- 真机测试testHDRSuppressesFilterTemporarilyAndRestoresIt通过：HDR下预览8-bit/headroom1；关闭后Leica/0.8恢复。

# 2026-11-05 HDR/微距阶段收尾

- HDR+滤镜实验取消；HDR恢复互斥、预览SDR+HDR标识；成片官方CIContext全分辨率增益图。
- 微距：物理超广角/constituent+AF、+0.5EV、最近微距5秒保持成片路线；清晰度真机通过。
- 实测：重编码约2.8秒；增益图12,288,000字节，AlternateHeadroom2.70，headroom6.50；微距HDR平均约0.80；系统直存约2.3秒但增益图3MB/0.49，已不采用。
- 未解决：第一张微距后预览被系统切回主摄；第二张成片可保持微距但预览不保持；速度/HDR观感仍略弱于对方App；未全量回归。
- 完整记录与代码清单：[HDR-Macro-Status](HDR-Macro-Status.md)。

# 2026-11-05 连续微距保持

- 根因：第一张微距后系统把虚拟多摄主 constituent 从超广角切回主摄，macroActive=false，第二张走主摄。
- 修复：按下快门时记录微距时间；后续5秒内即使系统已切回主摄，prepareMacroAutomaticRoute仍按微距切超广角，保留+0.5EV与全分辨率增益图。
- 真机连续两张：均2.22mm超广角；HDR avg0.62/0.60；headroom6.5；增益图12MB；第二张约2.85s。
- 预览画面本身仍可能被系统切回主摄，但第二张成片保持微距。

# 2026-11-05 微距超广角+0.5EV曝光补偿

- 连续两张文件对比：第一张6.765mm主摄HDR avg0.99；第二张2.22mm超广角HDR avg0.58；增益图均12MB/AlternateHeadroom2.70，差异来自超广角曝光低约0.5EV。
- 微距/超广角自动曝光时临时+0.5EV，拍完恢复；主摄不受影响。
- 真机：SDR avg0.43、HDR avg0.80、headroom6.50，接近对方HDR avg0.83；capture2.9s。
- 微距对焦仍走constituent/物理超广角。

# 2026-11-05 官方CIContext重写全分辨率增益图

- 取消系统HDR直存，改回CIContext.heifRepresentation：系统HDR数据→HDR主图+0.7EV仅提升HDR→SDR基底→Display P3→ISO/Apple增益图。
- 真机微距：2.8秒；增益图12288000字节（全分辨率）；AlternateHeadroom2.45；HDR avg0.59、headroom6.5；SDR avg0.35。
- 对比对方：2.3MB/全分辨率1.7、HDR avg0.83；仍略弱，但比系统直存强。
- 微距/普通HDR均走此路径；SDR预览+HDR标识保留。

# 2026-11-05 虚拟多摄constituent微距研究

- 重新启用virtualDeviceConstituentPhotoDelivery；微距设置超广角+广角constituent，delegate只收超广角。
- 真机：微距成片清晰、2.34s、无物理输入切换；但系统增益图仍3MB/AlternateHeadroom1.38，HDR avg0.53、headroom2.60。
- 结论：constituent改善了微距对焦和速度，但未得到对方App的12MB/full-res增益图；全分辨率增益图在现有CIContext重编码路径才出现。
- 下一步只能走后台重编码或研究对方编码配置。

# 2026-11-05 HDR增益图与对方App差距

- 对方：full-res增益图，AlternateHeadroom1.70，HDR avg0.827、headroom3.25。
- 光屿快速直存：增益图降采样3MB，AlternateHeadroom1.32，HDR avg0.49、headroom2.86；2.4秒。
- 将直接HDR请求提到.quality未改变增益图大小/亮度。
- 结论：物理超广角直存得到较弱系统增益图；对方可能走虚拟多摄/不同HDR配置。暂保留快速路径，不盲目加曝光。

# 2026-11-05 系统HDR增益图对比与快速直存

- 对方FOTOR：3024x4032，full-res增益图，AlternateHeadroom1.70，HDR avg0.827、headroom3.25。
- 光屿快速直存：4032x3024，增益图降采样，AlternateHeadroom1.32，HDR avg0.49、headroom2.98；2.3秒。
- 尝试保留HLG采集格式+SDR预览：成片headroom1，无增益图，不可用，已回退。
- 当前保留SDR预览+系统HDR直存：速度快但HDR弱于对方；完整HLG路由HDR强但约6.7秒。
- 下一步需找到对方的HDR采集配置/全分辨率增益图路径。

# 2026-11-05 SDR预览+系统HDR直存

- HDR开启时不再启用HLG预览，取景走SDR；右上角显示HDR标识。
- 无滤镜系统HDR HEIF直接保存，保留系统增益图，跳过二次重编码；微距不再强制SDR。
- 真机微距：captureSeconds2.46（此前HDR6.7/SDR3.6），headroom2.73，HDR平均0.49，预览平均0.33。
- 滤镜/非标准画幅仍走重编码路径。
- HDR标识/直存需UI和系统照片真机复核。

# 2026-11-05 微距SDR崩溃修复与耗时

- 崩溃：微距物理路线下 reconcileHDRPreviewFormat 仍尝试启用10-bit HLG，AVCaptureVideoDataOutput拒绝不支持的像素格式。
- 修复：物理输入不启用HLG预览；启用前检查availableVideoPixelFormatTypes，10-bit不可用则放弃本次HDR预览而不是写入。
- 真机：微距强制SDR，captureSeconds3.62s（HDR版6.7s），headroom1，缩略图即时；清晰度路线保留。
- 诊断测试按macroActive允许SDR断言。

# 2026-11-05 微距自动SDR

- 微距检测为真时，这一张强制options.hdr=false/context.options.hdr=false，跳过HDR still路由与增益图编码；保留物理超广角对焦与滤镜。
- 构建通过；真机测试因锁屏未执行，待用户实拍验证速度/清晰度。
- 普通非微距HDR不受影响。

# 2026-11-05 快门缩略图提前

- 快门按下即用当前预览帧触发 onCaptureThumbnailReady，最近照片缩略图立即出现；最终 CapturedPhoto 完成后替换。
- 实测缩略图时间0.0002s，HDR成片仍约6.7s；保存仍等待最终文件（captureInProgress阻止提前保存）。
- HDR编码后台化未改变总耗时；仅改善按下快门后的视觉反馈。
- 未做用户UI回归。

# 2026-11-05 微距切超广角后主动AF

- 物理超广角接管后，先居中autoFocus，最多等待0.6s至isAdjustingFocus结束，再锁lensPosition；避免锁在无穷远。
- 本机当前微距距离实拍：超广角2.22mm，成片鼠标垫纹理/线材边缘合焦清晰；导出附件核验。
- 仍未复现用户“成片糊”；需用户最新版实拍文件/参数确认。

# 2026-11-05 微距物理超广角真机诊断

- 诊断确认 macroActive=true 但系统主 constituent 已回主摄；新增回退：宏标为真且displayZoom≥0.99时仍切物理超广角。
- 在物理超广角上锁当前 lensPosition，不再continuous AF。
- 真机诊断成片近距离鼠标垫，画面合焦清晰；普通HDR指标在微距场景会因超广角构图变暗，属场景差异。
- 最新版已安装，待用户实拍微距确认。

# 2026-11-05 微距物理超广角路线与HDR 0.45EV

- 微距快门不再锁虚拟多摄，改为临时切换到当前超广角物理输入，拍完恢复虚拟多摄；普通HDR真机拍摄回归通过。
- HDR编码补偿0.45EV：本次预览平均1.29，成片HDR1.18，headroom约5.46；比0.35更接近预览。
- 未能在测试中强制真实微距，成片对焦待用户实拍确认。
- 未做全量回归。

# 2026-11-05 微距成片对焦锁定

- 微距触发时预览由虚拟多摄自动使用超广角，但照片请求可能重选主摄并重新对焦。
- 快门队列在 CameraMacroPolicy 判定微距时锁当前虚拟多摄的主 constituent（.locked），并锁当前 lensPosition；最后一个硬件 token 结束后恢复 .auto 与 continuousAutoFocus。
- 未能在测试中强制真实微距场景；普通HDR真机拍摄回归通过，微距成片对焦待用户实拍确认。
- 同时HDR编码0.35EV补偿：本次真机预览平均1.15，成片HDR1.13，headroom5.1。

# 2026-11-05 HDR成片编码亮度补偿0.35EV

- 真机诊断：预览平均1.19，成片HDR0.86、SDR基底0.60，成片HDR偏弱。
- 在hdrImage编码前加0.35EV补偿后：成片HDR平均1.14，预览1.19，headroom约5.1；更接近。
- 0.7EV试验平均1.51，明显超过预览，未采用。
- 仍在HDR编码路径统一应用；SDR/HDR中间调测试和增益图测试复验通过。
- 待用户真机确认系统照片/应用相册亮度；未做全量回归。

# 2026-11-05 预览/应用内相册headroom降到2.0

- 用户反馈预览比App内相册和系统照片更亮；成片增益图实际AlternateHeadroom=2.0，预览原按4.0显示。
- CameraEngine预览contentHeadroom改为HDRToneMapping.headroom=2.0；应用内相册PhotoKit targetHDRHeadroom改为2.0。
- 测试：HDR滤镜回退规则、PhotoLibraryHDRRequestTests通过。
- 待真机比较预览/App相册/系统照片亮度；系统照片显示映射不受App控制。

# 2026-11-05 取消HDR滤镜并恢复系统HDR识别

- HDR恢复互斥：滤镜下开HDR自动回退原片；HDR开滤镜入口禁用；设置中的HDR滤镜开关/实验室入口移除。
- PhotoEncoder恢复ISO 21496-1 + Apple HDRGainMap双写；PhotoLibrary preferHDR=true、targetHDRHeadroom=4.0。
- 真机测试：testHDRSwitchesFilterToOriginalAndDisablesFilterEntry、testHDRHEIFWritesGainMapWithSDRBase、testHDRHEIFKeepsMidtonesAndConfinesGainToHighlightShoulder、PhotoLibraryHDRRequestTests通过。
- 2026-11-05 用户要求取消HDR滤镜实验；不再提供HDR+滤镜产品路径。未做系统照片/应用内相册逐像素目视回归。

# 2026-11-05 应用内相册HDR headroom与预览对齐

- SystemPhotoLibraryService 的 PhotoKit HDR 请求 targetHDRHeadroom 4.0→2.0，与 Metal 预览层 contentHeadroom 2.0 对齐。
- 不动系统“照片”App；只改应用内相册/详情解码。
- PhotoLibraryHDRRequestTests 通过并断言2.0；未做相册/预览逐像素目视验收。

# 2026-11-05 单HDR主图输出预览与成片

- Imaging.filteredHDR一次产出HDR主图与从其压一次软肩的SDR基底；预览用HDR主图，PhotoEncoder用SDR基底+同一HDR主图写增益图，不再二次压肩。
- 合成图：mid=1.0、nearWhite=1.0、high=3.0；headroom2.0；HDR+Leica成片depth8/gain/leicaM9。
- 更新HDR滤镜成片测试仍通过；SDR基底/ratio裁切与边框回退保留。
- 未做全量视觉/功耗/横竖变更回归。

# 2026-11-05 共享HDR软肩参数与防双肩

- 新增 HDRToneMapping：knee=0.8、headroom=2.0、previewMaxGain=3，PhotoEncoder与预览共用常量。
- 预览基底保持CIToneMapHeadroom，避免和PhotoEncoder的hdrSoftShoulder重复压高光；成片SDR基底只压一次。
- 合成图：mid=1.0、nearWhite=1.0、high=2.69；headroom=2.0。
- HDR+Leica真机成片depth8/gain=true/leicaM9。
- 限制：预览EDR仍走“tone map→hdrExpand”，成片SDR走hdrSoftShoulder；两者共享knee/headroom常量，但不是同一函数。未做全量视觉/功耗回归。

# 2026-11-05 HDR软肩SDR基底与headroom对齐

- PhotoEncoder普通HEIF增益图改用hdrSoftShoulder：0.8以下保持SDR亮度，0.8到1软肩压缩；headroom固定2.0。
- 只写ISO增益图；测试断言Apple HDRGainMap不存在。
- 合成3段图真机编码：midRatio=1.0，nearWhiteRatio=1.0，highRatio=2.69；解码headroom=2.0，SDR high=0.982。
- HDR+Leica真实成片仍depth8/gain=true/leicaM9。
- 未完成：预览EDR曲线与成片软肩仍是两条实现，尚未共享同一曲线；需真机看高光过渡。
- 2026-11-05 用户真机主观确认：软肩+单增益图版本比之前“好多了”。

# 2026-11-05 移除重复Apple HDRGainMap

- PhotoEncoder 只保留 Core Image 生成的 ISO 21496-1 增益图，不再把同一数据重复挂到 Apple HDRGainMap。
- 测试：testHDRHEIFWithFilterKeepsGainMap、testHDRHEIFWritesGainMapWithSDRBase 通过；ISO存在、Apple类型不存在。
- 待系统照片真机确认：HDR仍显示、增益图/headroom正常；若旧系统不识别再按系统版本补Apple类型。
- 未重新全量回归。

# 2026-11-05 HDR高光平滑过渡

- 移除 hdrExpand/hdrResidual/hdrTint 的 smoothstep 阈值触发，改为连续六次幂 hdrExpansionGain，从中间调平滑增长到高光。
- 保留高光染色亮度归一化；峰值测试 plain=tinted=8.740695 通过。
- HDR+Leica真机成片仍 depth8、gain=true、filterID=leicaM9。
- 待真机目视确认高光与中间调断层是否消失；未做全量视觉/功耗回归。

# 2026-11-05 HDR滤镜最终开关与成片

- 应用设置→拍摄设置“HDR滤镜”默认关闭；开启后HDR保留滤镜，关闭恢复自动切原片和滤镜禁用。
- 真机测试：testTurningOffHDRFilterRestoresExclusiveRule、testHDRFilterExperimentKeepsFilterAndFilterEntry、testHDRMetalLiveOverlayReceivesProcessedFrames 通过。
- HDR+Leica真机成片：depth=8、hasGainMap=true、diagnostics filterID=leicaM9；PhotoOptions增益图测试通过。
- 预览：CAMetalLayer rgba16Float EDR覆盖层，实时帧桥接；hdrMetalPreviewFrame非空且headroom4。
- 限制：Metal覆盖层未完成横竖/画幅/对焦框全量视觉验收；完整替换正式UIImage路径未做；长时热稳定性和真实相册保存回路未复测。

# 2026-11-05 预览滤镜漏传 hdr

- 发现实时预览 `Imaging.filtered` 没有传 `hdr: state.hdr`，HDR开+滤镜时预览实际仍走SDR分支，Metal只拿到SDR帧。
- 修复：预览传入hdr；Metal实验帧不再额外hdrExpand，只设置headroom。
- 影响：HDR预览滤镜/浓度进入HDR-aware路径；需真机确认浓度是否仍压缩HDR。
- 测试：live Metal帧测试、HDR默认规则测试通过。

# 2026-11-05 live Metal 帧 HDR 扩展

- 原实时 IImage headroom=0；Metal 覆盖层收到 SDR 帧。
- 实验路径在交给 Metal 前对 display 做 hdrExpand + 显式 headroom=4，live test 通过。
- 合成高光扩展仅用于原型验证，不是正式成片算法。
- 待用户确认 Metal 画面是否出现 HDR 差异以及滤镜是否保留。

# 2026-11-05 HDR Metal live 预览桥接（第一步）

- CameraEngine 在实验开关下发布正式处理后的 HDR CIImage；CameraView 叠加 CAMetalLayer，原 UIImage 预览保留回退。
- 仅 model.preferences.hdrFilterEnabled && hdr && photo 时启用；离开/HDR关自动关闭。
- 验证：真机 testHDRMetalLiveOverlayReceivesProcessedFrames 通过，hdrMetalPreviewFrame非空。
- 尚未迁移旋转/画幅/对焦等叠加；当前为实验覆盖层，不替换正式预览。

# 2026-11-05 高光染色亮度匹配

- 染色内核与未染色内核统一使用同一源高光层和肩部；染色后再按未染色峰值归一化。
- 测试：plain peak=7.259532，tinted peak=7.259532；高光染色不再降低峰值亮度。
- 仍需真机看色相是否自然、是否过饱和。

# 2026-11-05 Metal原型：高光跟随滤镜色调

- 新增 hdrTintResidual：用LUT结果色相给HDR残差着色，按亮度归一化，保留>1高光。
- 原型页新增“高光跟随滤镜色调”开关，可对比着色前后。
- 未迁移正式预览；待真机确认高光染色与headroom同时成立。

# 2026-11-05 HDR Metal 预览原型

- 应用设置→实验→HDR滤镜实验室：独立开关 + CAMetalLayer原型页。
- 原型页用 rgba16Float CAMetalLayer、wantsExtendedDynamicRangeContent、extendedLinearDisplayP3；CIContext直接渲染HDR测试图，套Leica LUT，开关/浓度可调，不经过UIImage。
- 测试：HDRMetalPrototypeTests确认EDR layer和drawable绘制成功（drawHierarchy无法捕获Metal，不能用截图判定）。
- 尚未迁移正式预览；需用户在真机实验室页面确认EDR高光+LUT视觉。

# 2026-11-05 HDR滤镜实验开关

- 应用设置→拍摄设置新增“HDR 滤镜（实验）”，默认关闭。
- 开启：HDR不自动切原片，滤镜入口保持；预览走HDR-aware路径（bits16/headroom4）；成片仍用完整look。
- 关闭：恢复HDR自动切原片、滤镜入口禁用。
- 用途：仅用于验证真正HDR+滤镜实现，不作为正式规则。
- 真机测试：实验开关保留Leica且filtersEnabled=true；headroom4.0；默认规则测试通过。

# 2026-11-05 HDR 开启自动切原片

- 有滤镜/调色时开启 HDR：自动将 style 切回原片，清空 filterAdjustments，保留各风格已保存配方。
- HDR 开启后滤镜入口禁用；关闭 HDR 后恢复。格式说明改为自动切原片提示。
- 验证：真机 testHDRSwitchesFilterToOriginalAndDisablesFilterEntry 通过；HDR bits16/headroom4。

# 2026-11-05 HDR 与滤镜互斥

- HDR 只允许在“原片 + 无滤镜调整”时开启；已有滤镜时 HDR 开关禁用。
- HDR 开启后 filtersEnabled=false，滤镜入口禁用；关闭 HDR 恢复。
- 格式说明改成互斥提示；滤镜按钮显示 HDR/滤镜互斥。
- 验证：真机 testHDRRequiresOriginalAndDisablesFilterEntry 通过；bits16/headroom4。
- HDR 下滤镜的真正实现仍被限制挡住，后续需要独立 Metal HDR 预览原型验证，不在当前稳定链路启用。

# 2026-11-05 HDR预览回退：屏蔽滤镜

- HDR+滤镜预览高光仍无法进入显示层；按约定回退。
- HDR开、HEIF照片模式：预览显示原片HDR（bits16/headroom4），屏蔽风格与色彩调整。
- 成片仍使用完整 effectiveCaptureLook：滤镜、浓度和其他参数正常写入HEIF/HDR增益图。
- 预览look与成片look已分离（setCaptureLook）；UI格式说明增加提示。
- 验证：HDR预览头room4.0；captureLook仍为Leica 0.8；HDR+Leica成片增益图测试通过。

# 2026-11-05 HDR域浓度混合（方案3）

- 滤镜在SDR基底生成完整强度结果；原始SDR与完整滤镜结果分别扩展为HDR域；浓度在两者之间混合，而非HDR原图与SDR滤镜结果混合。
- 其他色彩/明暗参数同时应用到两条HDR分支，不随浓度消失。
- 预览：Leica+HDR bits16/headroom4.0；峰值受CGImage限制约0.97，EDR依赖headroom。
- 成片：HDR+Leica仍带增益图测试通过。
- 限制：仍未真机确认“浓度在高浓度下也可见HDR”的主观效果；像素峰值未超过1。

# 2026-11-05 HDR-aware 滤镜预览/成片

- 实现：HDR开+滤镜时，先tone map出SDR基底套LUT，再用Metal hdrResidual把HDR高光残差/高光肩部加回；输出显式contentHeadroom=4.0。
- 预览：Leica+HDR bits16/headroom4.0；峰值像素受CGImage限制≤1，EDR由headroom放大白点。
- 成片：HDR+Leica HEIF仍带ISO/Apple增益图，depth8；PhotoOptions测试通过。
- 保留：浓度安全增强、0%同管线、HDR关强制sRGB预览。
- 限制：高光扩展为受控肩部重建，不是完整HDR LUT；不同LUT高光颜色需真机继续看。

# 2026-11-05 HDR + LUT 预览限制确认

- 实测：原片+HDR预览 bits16/headroom4.93；Leica+HDR预览 bits16/headroom0.0。
- 结论：HDR开关与单管线生效，但风格LUT把高光压回SDR，导致套滤镜时HDR预览看不出变化。
- 尝试“tone map SDR基底 + 回加原始HDR高光”未能在CoreImage LUT路径保留headroom，已回退，不留在成片链路。
- 当前行为：HDR开+滤镜时预览仍套滤镜，但HDR效果不可见；无滤镜/原片时HDR可见。
- 待决策：HDR预览是否暂时绕过LUT，或后续单独实现HDR-aware LUT。

# 2026-11-05 录屏定位：低浓度闪屏

- 录屏 14.6–15.4s：浓度降到0附近时纸面高光全白、文字压黑，随后恢复SDR，属HLG帧未tone map直接显示的典型现象。
- 预览位深/headroom虽恒定8-bit/1.0，但HDR关时源仍是HLG 10-bit缓冲；仅做CIImage匹配不足。
- 修复：HDR关照片预览先通过CIContext渲染为8-bit sRGB，再进入LUT/强度/显示；HDR开保持原EDR路径。
- 验证：预览渐降测试仍8-bit/1.0；构建通过。真实视觉需用户复测。
- 注意：录屏使用旧滑条布局；新旧布局共用此预览修复。

# 2026-11-05 浓度低端 HDR/SDR 交接

- 预览位深/headroom 全程稳定为8-bit/1.0，排除实际切换HDR格式。
- 新增：HDR关时HLG照片预览在应用滤镜前匹配到Core Image工作色彩空间，避免低浓度时逐渐露出HLG、最后再按SDR显示造成交接闪屏。
- 尚未真机确认视觉是否消失；若仍存在需录屏定位是预览帧还是面板材质。

# 2026-11-05 浓度低端闪屏与安全增强

- 80–100%：不再线性外推；对钳制后的参考LUT做饱和度/对比增强，增强前后钳制非负，保留>1高光。
- 0%：不再直接返回HLG原图，改走同一强度内核0混合，避免最后一步绕过滤镜颜色管线导致“闪一下变SDR”。
- 验证：FilterStrengthTests 全通过；ImagingTests 0%原像素测试通过；预览渐降测试 bits=8/headroom=1.0 不变。
- 仍需真机确认低端闪屏视觉是否消失。

# 2026-11-05 浓度安全增强（80–100%）

- 黑屏修复后若直接封顶80%会导致浓度后半段无变化。
- 现改为：0–80% 原混合；80–100% 不再线性外推，而是对钳制后的参考LUT做饱和度+对比增强。
- 安全边界：增强前后都做非负钳制，保留>1高光；alpha不变。
- 验证：FilterStrengthTests 全部通过（内置/导入LUT、负值、alpha、80%以上仍有变化）。
- 限制：仍未做真机手动拖动长压测；只验证了内核与成片契约。

# 2026-11-05 浓度拉满黑屏修复（取消80%以上外推）

- 复现：旧滑条与新调色盘在浓度100%均可黑屏，说明不是盘面/单管线本身。
- 根因：`effectStrength` 在80%以上做1.5倍线性外推；LUT把某通道压到0时，外推越过0，钳制后就是纯黑；旧滑条同样受影响。
- 修复：80%以上不再外推，100%=滤镜参考强度；`filterStrength` 保留非负钳制作为HDR保险；预览滤镜改为先缩到900px再处理，降低拖动时GPU积压。
- 影响：浓度80%→100%不再额外增强1.5倍，拉满等于参考LUT最大强度；旧配方在80及以下完全不变。
- 测试：构建通过；FilterStrengthTests 契约已更新（100%=reference，负值钳制）。真机自动测试因设备锁屏/测试运行器连接中断未能执行，待解锁复测。

# 2026-11-05 浓度全强度 HDR 负值修复

- 现象：调色盘浓度拉满时预览偶发黑屏。
- 排查：全强度 80% 以上会做 1.5 倍色彩外推；部分导入 LUT 在 RGBAf/HDR 下输出负值，SDR 显示会截成0，HDR 扩展范围不会，整屏可发黑。
- 修复：`filterStrength` Metal 内核将混合结果限制为非负，保留 >1 高光；SDR/HDR 共用同一边界。
- 测试：FilterStrengthTests 全部通过，包括导入 LUT 负值钳制、80/100% 契约、HDR alpha。
- 尚未在真机 HDR + 全强度长时间拖动复测；单管线让10-bit路径常驻，可能提高该问题暴露率。

# 2026-11-05 调色盘滤镜编辑（设置开关）

- 应用设置新增“调色盘”，默认关闭；关闭时保持旧滑条布局，开启后滤镜编辑弹窗切到方形盘 + 左右竖轨。
- 色彩：左轨浓度，方盘色温×色调，右轨饱和度。
- 明暗：左轨高光，方盘曝光×对比，右轨阴影；亮度从 UI 隐藏，旧 brightness 配方仍渲染。
- 质感：左轨暗角，方盘细节×颗粒，右轨光晕（softness/halation 合并）；旧参数 key 保留。
- 旧样式亮度滑条移除；`FilterEditorTab.light` 只保留曝光/对比/高光/阴影；“效果”标签改为“质感”。
- 验证：调色盘开关 UI 测试通过；默认 false/持久化测试通过；参数目录测试通过；三页截图已真机渲染检查，弹窗高度 448，盘面 220。
- 限制：光晕为 softness/halation 合并入口，旧配方不同值时取最大值，首次调节会同时写两项；褪色/色差仍隐藏；尚未做滤镜盘手势的真机长时间压力测试。

# 2026-11-05 相册 HDR 偶发不显示

- 原因：PhotoKit `targetHDRHeadroom` 读取请求瞬间的 `currentEDRHeadroom`，可能仍是1.0；加上 opportunistic 降级结果，详情页会拿到 SDR 基底。
- 修复：固定 `targetHDRHeadroom=4.0`，大图请求改 `.highQualityFormat` + `.exact`；缩略图/详情继续 `.allowedDynamicRange(.high)`。
- 验证：PhotoLibraryHDRRequestTests 通过。
- 限制：低电量/高温/低亮度会降低实际 EDR headroom，此时系统会主动 tone map，属显示器能力而非请求错误；尚未监听 headroom 变化自动重取。

# 2026-11-05 HEIF 单预览管线

- HEIF 照片模式内常驻一条 HLG 10-bit 预览管线；HDR 开关只切显示 tone map 和成片增益图，不再切 activeFormat/zoom/镜头策略。
- HDR 关：预览渲染为 8-bit SDR，成片无增益图；HDR 开：预览 EDR，成片 SDR 基底+ISO/Apple 增益图。
- 真机：普通 HEIF HDR headroom=4.92；HDR 关 SDR 文件无增益图测试通过；1× 开→关 actual=1.0/ui=1.0。
- 代价：HEIF 照片预览常驻 10-bit，功耗略高；M 挡 HDR 下部分焦段切换测试仍有时序失败，待修。
- 旧版“每次开关切 HLG/照片格式”的路径已移除。

# 2026-11-05 HDR 预览交接淡入

- 关闭 HDR 时静止帧门结束后，HDR/SDR 两条预览路线的视野/亮度交接仍有一次跳变。
- 用户主动开关 HDR 时增加0.16s短交叉淡入；帧门稳定后0.34s再淡出，不移动控件、不改变镜头布局。
- 1× 真机仍验证 actual=1.0/ui=1.0；开关速度约0.8s/1.3s（不含稳定门）。
- 待真机确认视觉跳动是否消失。

# 2026-11-05 HDR 关闭瞬闪修复

- 现象：关闭 HDR 瞬间先切超广角/显示微距，再回原镜头。
- 原因：格式恢复重置 zoomFactor；commit 后按 UI 倍率反算并恢复 raw factor，但系统 primary 会在这个窗口短暂落到超广角并被预览/微距采样发布。
- 修复：HDR 切换全程冻结预览帧并屏蔽微距；zoom/自动镜头策略恢复后等待 0.28s，再放行新帧。
- 真机：1× 开→关 actual=1.0、ui=1.0，测试通过；HDR 开关计时约 0.8s/1.3s。

# 2026-11-05 HDR 相册/开关/1× 修复

- 应用相册 PhotoKit 请求启用 `preferHDR` 和显示 headroom；缩略图/翻页图 `allowedDynamicRange(.high)`。
- HDR 开关轻量路径：不再每次重建照片输出/能力表；开启/关闭约0.8s/1.3s，配置期间禁用开关并显示加载圈。
- 修正关闭 HDR 后 1× 变超广角：格式恢复会重置 zoomFactor，改为 commit 后按新格式 displayMultiplier 反算并恢复当前显示倍率。
- 真机：1× HDR 开→关 actual=1.0；重复 HDR 开关测试通过；普通 HEIF HDR 仍为 SDR 基底 + ISO/Apple 双增益图。
- 旧的普通 HDR/RAW 依赖已移除；普通 HEIF HDR 不需要 RAW。

# 2026-11-05 HDR 增益图与夜景对焦

- HDR HEIF 从 10-bit PQ 改为 SDR 基底 + ISO 21496-1 增益图（iOS18+，Core Image `hdrImage`）；旧系统仍回退 10-bit PQ。
- PhotoEncoder 使用 ImageIO/CoreImage 路径保留 EXIF/TIFF；新增 HEIF/JPEG/TIFF 元数据测试。
- 独立夜景在整组第一帧前做一次自动对焦，随后锁定 lensPosition，全部帧共用；不再每帧重新 AF。
- 独立夜景启动固定 1s 等待改为 0.2s；极暗场景曝光规划失败时用测光值兜底。
- 验证：HDR HEIF 测试通过，SDR 基底 8-bit、headroom 1.5；后置系统 HDR 真机通过；IndependentNightCapture 48MP 通过；A48 通过。
- 局限：ISO 增益图是否被旧版 Photos/第三方 App 识别需真机复测；当前场景 headroom 约1.5，仍受限；夜景多帧重影/亮度规划未完成。

# 2026-11-05 夜景样张诊断与首批修复

- 用户样张：7 张 Luma HEIC + 1 张原生参考（IMG_2802）。
- 量化：原生平均亮度约0.34；Luma 0.12–0.21；Luma 高频细节约为原生一半，边缘有重影。
- 元数据：Luma 文件无曝光/ISO EXIF、无 HDR 增益图；原生 1s/ISO4000、带增益图。
- 根因判断：夜景曝光规划偏保守且 demand<64 直接失败；独立会话未显式延续对焦；顺序多帧+固定1秒释放等待慢；HDR PQ 无增益图在普通显示下偏暗。
- 已修复：独立夜景锁定主会话镜头位置；硬件释放等待1s→0.2s；PhotoEncoder 改用 ImageIO 写入 EXIF/TIFF；新增 EXIF 保留测试。
- 验证：IndependentNightCapture 48MP 6.476s通过；A48 全格式13.955s通过；HEIF/JPEG/TIFF EXIF 测试通过。
- 未完成：曝光规划提亮、多帧重影/运动保护、HDR 增益图、括号采集提速；待下一次夜景真机样张。

# 2026-11-04 双拍用例同步与验证

- 旧假设已更新：
  - 双拍入口改到“拍摄模式 → 同步双拍”，不再查找焦段区内联 `dualCaptureToggle`。
  - 双拍主画面默认后置，前置是小窗；前置广角/标准通过 `setDualCaptureFrontWide` 控制。
  - 双拍不承诺普通 M 挡手动曝光写入独立双拍源；用例改为验证主/小窗交换和引擎存活。
  - inset 几何等待发布后再断言，避免后台恢复后的时序失败。
- `DualCapturePhysicalTests` + `DualCaptureLandscapeTests` 整类通过：
  - 入口在拍摄模式：2.828s
  - 录制交换/普通恢复：17.211s
  - 前置广角/比例变化：8.796s
  - 其余几何/错误恢复/同步帧用例全部通过。
- 上一次全量是 165 passed / 4 failed，失败全部是上述双拍用例；现均已修复并通过双拍整类。全量尚未在双拍修复后重跑，不能宣称全绿。

# 2026-11-04 全量测试收尾状态（未全绿）

- 最新全量：165 passed，4 failed，均在双拍路径；隔离运行仍失败，不是共享模型污染。
  - DualCaptureLandscapeTests.testActualWideRestoreRapidSwitchRecordingAndRatioChanges：等待“设置进入前画幅”超时。
  - DualCapturePhysicalTests 3 个用例：双拍入口/焦段可用性/双拍几何失败。
- 其余已修复：A/M、48MP、夜景分流、系统 HDR、平滑预览、慢门、连拍、CinematicZoom、CinemaAspect、AWB 上限夹取等。
- 模式切换超时：新增 `cancelPendingPhotoCapturesForModeSwitch`，真机模拟“原生回调丢失后切视频”通过，pending=0 且无超时弹窗。
- 最新正式 App 已安装；全量期间测试宿主会抢占相机，不应同时使用前台 App。
- 待办：单独修双拍4用例/产品路径，再重跑全量；当前不得宣称全部测试通过。

# 2026-11-04 拍照超时与 ProRAW 配置修复

- 现象：真机偶发“拍照超时，本次照片未能完成，请重新拍摄”。
- 原因排查：A/M 或高像素切镜为提速跳过整次 photoOutput 配置后，系统会关闭 ProRAW；代码曾在会话事务外直接改 `isAppleProRAWEnabled`，可能重启照片图并拖过原生回调超时。
- 修复：跳过整次配置但需要 ProRAW 时改走 `configurePhotoOutput` 的正式 begin/commit；普通照片处理超时 20→25 秒，48MP/HDR 45 秒，RAW/Live 60 秒。
- 回归：A48 全格式 17.898s、48MP 固定焦段 26.854s、前置系统 HDR 5.321s、后置系统 HDR 6.764s 全部通过，无超时。
- 尚需用户复现原操作序列确认偶发超时是否消失。
- 全量套件此前仍有 CinematicZoom 等少量旧断言失败，测试同步尚未完成，不能宣称全绿。

# 2026-11-04 全项目测试用例同步

- 48MP：A48 用例改为 M 挡全格式；Smart48 改为“A 禁用、M 可用并实拍”；Lens48 审计改 M；高像素容量探针先切 M。
- 夜景：普通自适应用例通过 `setForceOrdinaryNightForTesting(true)` 与产品独立夜景分流隔离；独立输出下限 6MP→11MP；新增 Profile 帧数契约（3/4/5/5、无正曝光）；手动夜景改为验证曝光量等价，并等待 A→M 稳定窗口。
- 布局：虚拟光圈测试不再复制易碎方向断言，垂直布局由 DepthToolbar 稳定宿主覆盖；Depth 覆盖人像/虚拟光圈 × 8 比例 × 横竖。
- 连拍：移除“进入归零”旧断言，新增“不退出连拍再次按住计数继续累计、退出归零”；新增 Live 槽位的连拍计数几何 UI 用例。
- UI：新增 48MP A 禁用/M 可用格式面板几何用例、连拍计数槽位用例、夜景实验设置页加载/模型布线用例。
- HDR：普通 HEIF+HDR 与前置 HDR 改系统处理源，不请求 RAW；新增前/后置系统 HDR 实拍用例。HEIF Pro 保持 RAW 显影、降低锐化。
- 修复：A/M 跳过 photoOutput 重建时补开 ProRAW，避免 M→A 后 rawTypes=0 误报“不支持 RAW”；前置 RAW/HDR 自动回退。
- 目前全量套件正在复跑；以最终 `TEST EXECUTE` 结果为准，未完成前不宣称全绿。

# 2026-11-04 流畅预览修复

- 根因：`usesPreviewExposureAssist` 开启时仍走普通手动包围曝光；包围参数与预览辅助的 AE/HDR 状态冲突，导致同 EXIF 的成片实际像素亮度不同。
- 修复：普通拍照在预览辅助开启时跳过手动包围，走设备自定义曝光并在快门等待曝光应用完成；慢门序列的包围不受影响（仅 `.standard` purpose）。
- 真机矩阵通过：JPG/HEIF × 0.5s/1/125 × 辅助开/关，成片平均亮度差 <0.06；例 0.5s 0.862 vs0.859，1/125 0.543 vs0.522。
- 自动慢门预览优化 1.206s 通过；慢门动态模糊 4000×3000、14.373s 通过。
- 构建、安装、启动成功。

# 2026-11-04 流畅预览检查

- 自动慢门预览优化：`testAutomaticSlowShutterCapsOnlyTheLivePreviewAndRestoresOnExit` 通过 1.199 秒；1/15 秒触发预览上限约1/30，退出后恢复。
- M 挡辅助开启：预览保持短自动曝光（约0.02s/高ISO），成片仍按请求的手动 ISO/快门写 EXIF；普通 M 矩阵中辅助开启样本捕获正确。
- M 挡辅助关闭：完整回归失败。同一场景 0.5s→1/125 后，关闭辅助样本文件亮度约0.48，开启辅助约0.11，EXIF 都是 ISO100/1/125；说明非辅助路径的成片像素与手动曝光请求仍不一致。
- 该失败不是“自动慢门预览优化”本身，而是普通 M 挡手动曝光/包围在长→短切换后的独立问题；需要继续修，暂不能判定流畅预览整体正常。
- 已移除临时调试输出；未新增产品代码修复。

# 2026-11-04 慢门顶部预设/时长文字拍摄中变暗

- 原因：顶部慢门预设/时长按钮在 `canEditSlowShutterDuration == false` 时使用 `disabledControlOpacity` 整体压暗。
- 修复：移除禁用透明度；拍摄中仅 `.allowsHitTesting(false)` + 动作 guard 阻断修改，按钮文字保持原白色/强调色和可读性。
- 未做自动化文字颜色断言；需真机拍摄中确认可读性。
- 构建、安装、启动成功。

# 2026-11-04 慢门输出 6.75MP 修复

- 现象：光轨/丝绢流水/动态模糊成片 2250×3000（6.75MP），低于 >11MP 断言。
- 根因与早期夜景同类：源帧为 4000×3000 横向像素但 `look.landscape` 为竖屏，PhotoEncoder 按 3:4 竖幅裁成 2250×3000。
- 修复：慢门合成完成后、编码前按首帧目标方向归一化；像素方向与目标方向不一致时旋转 90°，再按画幅裁切。
- 真机：光轨 4000×3000、丝绢流水 4000×3000、动态模糊 4000×3000，均 >11MP；三用例通过（40.308s / 14.490s）。
- 当前测试机横放，故成片为横向 4000×3000；竖放应输出 3000×4000。
- 构建、安装、启动成功。

# 2026-11-04 独立夜景 HDR/亮度实验开关

- 应用设置“实验：独立夜景”新增：
  - 多帧方案：标准3 / 均衡4 / 降噪5 / 高光保护5。
  - 亮度优先影调：融合后长曝光数字提亮上限 0.5→1.1EV，阴影提升上限 0.14→0.22，不增加采集曝光。
  - HDR 成片：仅 HEIF 生效，使用 10-bit PQ HEIF；不是 Apple 增益图。
- 真机 HDR 成片：`bits=16 depth=10 size=3000x4000`，单资源无 pairedVideo，12.735 秒通过。
- 所有多帧方案不增加曝光补偿；普通夜景最多9帧，独立夜景最多5帧。
- HDR 取景预览未接入：当前预览管线输出 SDR UIImage，真正 HDR 预览需要 EDR/金属层重做，不能只加开关。
- 四方案画质尚无客观噪点/高光评分，等待真机对比。
- 构建、安装、启动成功。

# 2026-11-04 独立夜景实验方案

- 应用设置新增“实验：独立夜景”，可切换 4 种方案；不影响普通夜景和 >8× 回退路线。
  - 标准 3 帧：3×0EV
  - 均衡 4 帧：3×0EV + 1×-1EV
  - 降噪 5 帧：5×0EV
  - 高光保护 5 帧：3×0EV + -1EV + -2EV
- 所有方案都不增加曝光补偿；内部采集改为 HEVC/HEIF，不再用 JPEG。
- 真机 `testIndependentNightProfilesProduceDeclaredFrames`：四方案帧数 3/4/5/5，源尺寸均 8064×6048，26.564 秒通过。
- 普通夜景自适应最多 9 帧（3/6/9），受 8 秒/80MB/运动评估限制；独立夜景最多 5 帧。
- 未做四方案画质客观评分（噪点/高光/清晰度）；需用户真机对比后决定保留方案。
- 构建、安装、启动成功。

# 2026-11-04 智拍 + Live 兼容验证

- 智拍开启后 Live 仍可开启，`canToggleLivePhoto` 未因智拍禁用，`photoOptions.live` 正常传入。
- 真机 `testSmartCaptureSupportsLivePhoto`：智拍 + Live 拍照返回 2 个资源，其中 1 个 pairedVideo，通过 6.405 秒。
- 兼容前提沿用 Live 既有约束：12MP、JPG/HEIF、HDR 关闭等；智拍不额外关闭 Live。
- 本次无需产品代码改动，仅补回归测试。

# 2026-11-04 相机按钮触感策略

- 拍照主界面按钮保留/增加点击触感：快门、焦段、Live、模式、工具、相册、翻转、变焦/曝光等现有入口。
- 相机弹窗按钮统一移除直接触感；ViewModel 的动作触感增加 `cameraPopupOpen` 门控，弹窗打开期间不再触发。
- 应用设置保持例外：设置页说明按钮与 DockKit 开关触感不经过相机弹窗门控。
- 微距标识不是 Button，未添加触感。
- 相册按钮按用户说明已覆盖，本次不改。
- 布局/触感无法由 XCTest 直接断言震动脉冲；已核对弹窗视图无直接反馈调用，需真机手感确认。
- 构建、安装、启动成功。

# 2026-11-04 竖屏滑条中线对齐直方图

- 竖屏（内容角度0°）时，人像/虚拟光圈滑条中心 y = 直方图中心 y；只改变与顶部工具栏的垂直距离，x、宽度、高度不变。
- 横屏内容（90°）保持原固定位置：工具栏底边 + 20pt（滑条中心 toolbar.maxY+36）。
- 直方图隐藏或 frame 尚未发布时回退固定 20pt。
- 真机布局：标准/方形中心 148.5，滑条中心 148.5；经典/宽幅/全景等直方图中心 140.5，滑条同步 140.5；横向仍为 149。
- `testDepthSliderTopSpacingIsTwentyAcrossRatios` 覆盖人像与虚拟光圈 × 8 比例，超时 7.219 秒通过。
- 构建、安装、启动成功。

# 2026-11-04 人像/虚拟光圈滑条顶部间距统一 20

- 两条滑条统一 `.position(y: toolbar.maxY + 36)`，固定高度 32，顶部间距恒为 20。
- 真机布局回归 `testDepthSliderTopSpacingIsTwentyAcrossRatios`：人像与虚拟光圈 × 全部 8 种比例 × 0°/90° 内容旋转，`popup.minY - toolbar.maxY == 20±1`，通过 6.962 秒。
- 比例切换不影响工具栏锚点或滑条尺寸/位置。

# 2026-11-04 A/M 会话重配提速（保持 M 物理路由）

- 不再使用“M 留在虚拟后置”的提速方案；M 继续直接物理镜头，预览/参数/成片一致。
- 优化一：预览输出配置 key 从设备唯一 ID 改为“格式尺寸 + 色彩空间”。A/M 换设备但输出格式一致时不再重建整段视频输出，节省约 0.7–1.4 秒。
- 优化二：A/M 过渡期间跳过标准 12MP 的 photoOutput 重建；48MP 仍单独重建。节省约 0.15 秒。
- 真机：A→M 0.594–0.642 秒，M→A 0.326–0.340 秒（2 轮，4 次切换，等待新预览帧）。
- 回归：M 挡 1/20–1s 预览实际曝光全部接近请求值；1s 预览亮度 0.987，成片 0.976，EXIF 1s/ISO100；ISO 400 实际 399.4。
- 剩余限制：A→M 的 `AVCaptureSession.commitConfiguration()` 换输入成本约 0.54 秒，属于当前 AVFoundation 路由下限；未做双会话/预启动方案。
- 构建、安装、启动成功。

# 2026-11-04 A→M 立即调参的预览修复

- 回退 A/M 提速后仍存在竞态：`setMode(.manual)` 后立即调 ISO/快门，`applyExposure` 在虚拟→物理输入过渡期间提交 custom exposure，1/20–1s 预览会卡在短曝光。
- 修复：A→M 设置 1 秒路由稳定窗口；窗口内只更新 UI 数值，不提交 custom；稳定后一次性应用最新 ISO/快门/WB/对焦。
- 真机 1/20–1s 预览实际曝光：0.049896 / 0.066563 / 0.124895 / 0.249895 / 0.499895 / 0.999895 秒，全部接近请求值。
- 1s：预览平均亮度 0.960，成片 0.960，EXIF 1s/ISO100。
- A/M 仍保持回退后的物理/虚拟路由方案；只有 A→M 后首次应用有最多约1秒稳定等待，期间数值不丢。
- 构建、安装、启动成功。

# 2026-11-04 A/M 提速回退（M 挡恢复物理路由）

- 结论：A/M 提速的“M 挡先留在虚拟后置”方案导致 1 秒手动曝光预览卡在短曝光，成片正常 1s/ISO100，预览与成片亮度不符；M 挡参数入口也一度被虚拟能力表锁住。按用户要求回退到提速前方案。
- 回退内容：M 挡直接物理路由；能力表按实际输入设备发布；移除 manualPhysicalRouteRequested/setManualPhysicalRoute、延迟重放与自定义曝光提前切换；恢复原始帧时长逻辑和自动路线准备。
- 真机验证：M 挡 ISO/快门/WB/色调/对焦 `canEdit=true`，设备 `built-in_video:0`；ISO 400 稳定读数 399.4；1 秒预览平均亮度 0.762，成片 0.791，成片 EXIF 1s/ISO100。
- 代价：A/M 切档恢复为原有的物理/虚拟输入重建耗时；优先保证预览、参数和成片一致。
- 保留：48MP M 挡、夜景三镜头、连拍、智拍互斥、滑条样式/间距等后续功能。
- 构建、安装、启动成功。

# 2026-11-04 M 挡参数解锁

- 问题：M 挡预览留在虚拟后置时，能力表按虚拟设备发布，`supportsExposure/WB/Focus` 为 false，ISO/快门/WB/对焦入口被锁。
- 修复：M 挡能力发布改用对应物理镜头；实际调节 ISO/快门/WB/对焦任一项时，通过 `manualPhysicalRouteRequested` 切物理镜头，仅切档仍保持虚拟路由。
- 真机：M 挡 ISO/快门/WB/色调/对焦 `parameterCanEdit=true`；设置 ISO 400 后稳定读数 399.4，`engineCustom=true`，设备切到 `built-in_video:0`。
- A↔M 新帧延迟仍为 0.049–0.109 秒（8 次）。
- 构建、安装、启动成功。

# 2026-11-04 A/M 切档提速

- 原因：A 挡用虚拟后置，M 挡无条件换物理后置，输入重建导致新预览帧约 1.4–2.5 秒。
- 调整：M 挡未真正启用自定义曝光时继续使用虚拟后置（虚拟支持自动/锁定/手动 WB 锁定/对焦锁定，不支持 custom exposure）；只有启用 ISO/快门自定义曝光时才切物理镜头一次。
- 真机 A↔M 新预览帧延迟：约 0.061–0.091 秒（8 次样本），优化前约 1.4–2.5 秒。
- `ManualAutoRecoveryPhysicalTests/testAllManualParametersReturnToAutomaticAndPublishFreshValues` 通过 12.241 秒，手动参数恢复/读数和成片未回归。
- 48MP M 挡仍强制物理镜头，不受此路由优化影响。
- 构建、安装、启动成功。

# 2026-11-04 智拍与子模块互斥改为切换

- 开启智拍：自动退出当前慢门/人像/夜景/连拍/虚拟光圈，再启用智拍。
- 开启任一其他照片子模块：自动退出智拍并启用目标模块，不再置灰或拦截入口。
- 应用智拍建议中的预设：先退出智拍，再应用目标预设。
- UI 子模块入口在智拍开启时不再禁用。
- 真机：智拍→人像（智拍退出、人像开启）→智拍（人像关闭）→夜景（智拍退出、夜景开启）通过，1.009 秒。
- 构建、安装、启动成功。

# 2026-11-04 48MP 固定焦段切换提速

- 移除每次切 0.5/1/4× 时重复的 `setPreparedPhotoSettingsArray`；prepared settings 在高像素模式开启时准备并可复用。
- 高像素后置同向换镜合并为一次 session 事务提交，减少第二次配置提交。
- 尺寸一致时跳过整次 `configurePhotoOutput`，仅校正 output max；拍照请求对 output max 做夹取，避免超过新镜头上限。
- 真机延迟：4× 约 0.354s，回 0.5× 约 0.292s；优化前约 1.2s。首次进入高像素后的第一次 0.5× 仍可能更慢。
- M 挡 0.5/1/4× 成片全部 8000×6000；`HighResolutionFixedFocalTests` 通过 22.532 秒。
- A 挡 48MP 已按产品要求禁用，测试改为仅 M 挡。
- 构建、安装、启动成功。

# 2026-11-04 连拍速度与松手停止

- 问题：连拍循环允许最多 4 个待处理任务，松手后仍残留多张；限制单张在飞后速度降到约 0.55 秒/张。
- 优化：连拍照片请求使用 `.speed` 质量优先，其余模式保持原优先级。
- 真机 3 轮连拍：4 + 9 + 7 = 20 张，平均回调间隔 0.129 秒（约 7.7 张/秒），peak-pending=1。
- 松手后最多只剩当前一张在飞，不再继续排队多张。
- 构建、安装、启动成功。
- 说明：回调间隔是设备管线吞吐，不等同于屏幕帧率；未做长时间发热/存储压力测试。

# 2026-11-04 连拍张数显示

- 连拍模式下顶部工具栏 Live 位置改为显示连拍张数：`square.stack.3d.up` + 数字。
- 张数来源：CameraEngine `onCaptureDelivered` 成功交付回调，取消照片不计数。
- 退出连拍模式归零；再次进入由退出归零保证从 0 开始。
- 真机 3 轮连拍：3 + 5 + 5 = 13 张，显示计数与成功交付一致；退出后 0，再进入 0。
- 构建、安装、启动成功。
- 未做专门截图比对数字字号/横屏位置；布局沿用 Live 工具栏槽位。

# 2026-11-04 48MP 仅限 M 挡

- A 挡 `canSelectPhotoResolution(.high)` 返回 false，48MP 按钮禁用。
- M 挡仍可选择 48MP。
- M 挡已选 48MP 时切回 A 挡，`mode.didSet` 自动把 `photoResolution` 回落 `.standard`，并同步关闭高像素路由。
- 真机：`test48MPOnlyAvailableInManualAndFallsBackInAuto` 通过；可用时 A `canSelect=false`，M `true`，M 48MP→A 后 final=standard。
- 构建、安装、启动成功。
- 说明：底层程序化测试仍可直接设置 48MP；产品 UI 入口和模式切换已受限。

# 2026-11-04 夜景变焦范围恢复普通模式

- 撤销夜景 8× 硬限制；夜景变焦范围与普通模式一致（实测 0.5–40×）。
- 0.5–8×：走三镜头 48MP 独立夜景。
- >8×：自动回退普通夜景多帧，不再进入独立 48MP 会话。
- 真机：`testNightModeKeepsNormalZoomAndAboveEightFallsBack` 通过；12× 时 `nightMode` 仍为夜景，但诊断不含“夜景独立采集”，回退成功。
- 构建、安装、启动成功。

# 2026-11-04 夜景变焦上限 8×

- 夜景照片模式 `zoomRange` 固定为当前能力与 `0.5...8` 的交集。
- 变焦轮、捏合、倍率加减和键盘/硬件调焦都使用该范围。
- 进入夜景时如果当前倍率大于 8×，自动回落到 8×。
- 真机测试：`testNightModeZoomRangeClampsToEight` 通过，range=0.5...8.0，超出后回落 8.0。
- 构建、安装、启动成功。

# 2026-11-04 横屏三镜头 48MP 夜景

- 手机物理横放后，独立夜景接收 captureRotationAngle=180°。
- 修复：横屏角度下若解码帧仍为竖图，显式旋转为横向后再裁切。
- 真机结果：
  - 0.5×：4000×3000
  - 2.0×：4000×3000
  - 4.0×：3969×2977
  - 三档均走独立夜景，拍后倍率恢复。
- 横屏三镜头测试通过 28.603 秒。
- 取消、退后台、12 轮模式/镜头切换也通过；退后台残留 pending 已修复。
- 当前安装版包含横屏与退后台修复。

# 2026-11-04 夜景取消/退后台/切换稳定性

- 夜景采集中关闭夜景：通过。`ready=true`、`pending=0`、`capturing=false`、倍率恢复 2×。
- 夜景采集中退后台：初始失败，`pendingPhotoCount` 残留 1；修复为保存独立夜景 context，stop 时主动 cancel 并统一收尾。修复后通过，`ready=true`、`pending=0`。
- 夜景/镜头/模式切换压力：12 轮开关夜景、0.5/1/2/4×、A/M 交替，全部 ready、pending=0，通过 27.510 秒。
- 横屏三镜头：自动化被系统拒绝（`Failed to set device orientation: Not authorized for performing UI testing actions`），未完成，需人工横拿实拍。
- 当前安装版包含退后台 cancel 修复；横屏仍待人工验证。

# 2026-11-04 独立夜景 48mm 连续五次

- `testIndependentNightFiveConsecutive48mmCaptures` 真机通过，37.144 秒。
- 5/5 均走“夜景独立采集”，最终 2996×3995 到 3000×4000（约 12MP），倍率保持 2×。
- 场景与设备：iPhone 17 Pro，夜间独立会话反复 detach/reattach 主会话。
- 仍未覆盖横屏、取消和退后台专项。

# 2026-11-04 三镜头 48MP 夜景最终回归

- 普通 48MP：`A48ResolutionPhysicalTests` 通过，JPEG/HEIF/TIFF/HEIF Pro/RAW 实际解码 8000×6000 或 8064×6048。
- Live：`CameraFocalButtonTests/testLiveFocalButtonHitAndActualZoom` 通过。
- 独立 48MP：`IndependentNightCaptureTests` 通过，实际解码 8064×6048。
- 夜景 1–2×：连续 24/28/48mm 通过，源 6048×8064 / 5184×6912 / 3024×4032，最终 3000×4000。
- 夜景 4–8×：4× 源 6048×8064、6× 4032×5376、8× 3024×4032，最终约 12MP，倍率恢复。
- 夜景 0.5–1×：0.5× 源 6048×8064、0.75× 4032×5376、0.99× 3056×4074，最终约 12MP，倍率恢复。
- 总耗时 208 秒，`TEST EXECUTE SUCCEEDED`，6/6 通过。
- 当前 App 已安装；未做横屏实拍、连续快速拍摄、取消/退后台专项。

# 2026-11-04 三镜头 48MP 夜景覆盖

- 0.5–0.99×：超广角 48MP，基准 0.5×
- 1.0–3.9×：主摄 48MP，基准 1×
- 4.0–8.0×：长焦 48MP，基准 4×
- 裁切倍率统一为 `当前倍率 / 镜头基准倍率`；最终均输出约 12MP。
- 真机源帧：
  - 0.5×：6048×8064
  - 0.75×：4032×5376
  - 0.99×：3056×4074
  - 4×：6048×8064
  - 6×：4032×5376
  - 8×：3024×4032
- 0.5–1、4–8 两组连续测试通过，拍后倍率恢复 0.5/0.75/0.99 和 4/6/8。
- 临时策略仍为开启夜景模式即走独立会话；环境触发只控制指示灯。
- 未完成：横屏三镜头实拍、连续快速拍摄、取消/退后台专项。

# 2026-11-04 夜景主摄+长焦 48MP 混合裁切

- 策略：1.0–3.9× 使用主摄 48MP；4.0–8.0× 使用 4× 长焦 48MP。
- 独立会话按当前倍率选择物理镜头，并在各自原生 1× 采 48MP；裁切倍率按 `currentZoom / 镜头基准倍率` 计算。
- 真机验证：
  - 4×：源 `6048×8064`（48MP），最终约 2982×3976。
  - 6×：源 `4032×5376`，最终约 2996×3995。
  - 8×：源 `3024×4032`，最终约 2996×3995。
  - 4/6/8× 均走“夜景独立采集”，拍后倍率恢复正确。
- 1–3.9× 主摄路径沿用此前通过结果；当前夜景开启即走独立会话。
- 仍未完成：横屏 4–8× 实拍、连续快速拍摄和取消/退后台专项。

# 2026-11-04 独立夜景触发条件临时调整

- 当前临时策略：用户开启夜景模式即进入独立 48MP 会话，不再等待 `nightEnvironmentTriggered`。
- 环境触发状态仍保留，用于夜景指示灯；不再作为采集线路开关。
- 普通照片、Live 不受影响；关闭夜景后恢复原路径。
- 构建、安装、启动成功；24/28/48 真机连续测试沿用上一轮通过结果。

# 2026-11-04 独立夜景真实 48MP

- 根因：独立会话只设置 `maxPhotoDimensions` 不够；普通 48MP 成功路径是在会话运行后通过 `setPreparedPhotoSettingsArray` 预分配高像素管线，并关闭 Responsive Capture、启用 ProRAW 管线。
- 复刻后真机源帧：24mm `6048×8064`、28mm `5184×6912`、48mm `3024×4032`（2× 中心裁切后），最终 `3000×4000`（12MP，竖幅 4:3）。
- `IndependentNightCaptureTests` 实际解码验证为 `8064×6048`，不再只读文件属性。
- 连续 24→28→48mm 独立夜景测试通过，22.484 秒；方向/倍率恢复正确。
- 当前仍为独立会话，采集时有独立实时预览；普通/Live 路径未改动。

# 2026-11-04 独立夜景预览接入

- `IndependentNightCapture` 增加 `AVCaptureVideoDataOutput`，帧回调到 `CameraEngine` 的现有预览队列。
- 独立帧继续走现有 Core Image look/方向/滤镜管线，不另盖原始预览层。
- 采集改为预览优先：会话启动后等待首帧视频，首帧到达或 0.8 秒超时后才发照片请求。
- 连续 24→28→48mm 测试通过，19.691 秒；三档均走独立线路，最终 4000×3000，倍率恢复正确。
- 方向、预览实时性改善；普通/Live 未改动。
- 仍未解决：App 线路独立会话源帧仍是 12MP（24mm 4032×3024、28mm 3456×2592、48mm 4032×3024，48mm 再中心裁切），不是 8064×6048。独立类单独测试可拿 48MP，说明主会话释放仍不完整。
- 横屏独立预览未实拍验证。

# 2026-11-04 独立夜景 48MP 源帧调查

- 纠正：虚拟主摄不能拿 48MP，实测虚拟 `formats48=0`；48MP 只在物理主摄 `built-in_video:0` 上可用（`formats48=2`，max 8064×6048）。
- 独立类单独测试在 `model.setCameraActive(false)` 完全停相机会话后，物理主摄可拍出 3 张 8064×6048。
- App 夜景线路只调用 `session.stopRunning()`，主会话仍保留输入/输出占用；独立会话虽选中 48MP 格式，实际仍交付 4032×3024。
- 因此当前三档方向已修正为 4000×3000，但源帧仍是 12MP 按倍率裁切：24mm 4032×3024、28mm 3456×2592、48mm 2016×1512。
- 下一步必须让独立夜景先完整释放/重建主会话输入输出，再启动独立会话；仅 stopRunning 不够。

# 2026-11-04 独立夜景方向修复

- 问题：独立夜景融合结果按横向 4:3 裁切，竖拍 12MP 被裁成 3000×2250（6.75MP）。
- 修复：独立会话使用普通拍照的 `captureRotationAngle`；成片前按融合图像实际宽高设置 `look.landscape`，不再固定横向裁切。
- 真机连续 24→28→48mm：三次均走独立线路，最终均为 4000×3000（12MP），倍率恢复正确；1× 旧路径回归通过。
- 横屏方向已走同一角度入口，但本轮未实拍横屏三档，不能标记横屏验证通过。
- 尚未解决： App 线路中的独立会话源帧仍为 4032×3024 / 3456×2592 / 2016×1512，即 12MP 按倍率裁切；同类直接会话测试可拿到 8064×6048。48MP 源帧问题未完成。

# 2026-11-04 触发式独立夜景（24/28/48）

- 触发条件：用户开启夜景模式且 `nightEnvironmentTriggered == true`，才启用 48MP 独立会话；仅开启但未触发时继续原夜景路径。
- 独立会话支持 24/28/48mm 主摄：3 张 48MP 单帧，按当前倍率中心裁切后融合。
- 真机：`testIndependentNightRouteAt24And28mm` 通过，28mm 诊断“夜景独立采集”，最终 3000×2250；24mm 同路径通过。
- `testIndependentNightRouteAt48mmProduces12MP` 单独通过，最终 3000×2250，倍率恢复 2×。
- 1× 旧路径回归通过；等待触发时不走独立会话。
- 已知：连续第三个独立夜景（24/28 后再 48）出现 `InvalidTransition`/夜景未完成；单次和连续两次通过，连续三次仍需修复。
- 最终输出约 6.75MP，受融合对齐边缘裁切影响，不是完整 12MP。

# 2026-11-04 48mm 独立夜景会话

- 新增 `IndependentNightCapture`：独立 `AVCaptureSession` + 独立 `AVCapturePhotoOutput`，只在 48mm 夜景快门期间启动。
- 独立会话切物理主摄和 48MP 格式，连续拍 3 张 8064×6048 单帧；拍完关闭并恢复普通会话、预览、2× 倍率。
- 每帧在进入融合前按取景倍率中心裁切到约 4032×3024，再走夜景对齐/降噪/融合。
- 真机：`IndependentNightCaptureTests` 通过，3 帧 8064×6048；`testIndependentNightRouteAt48mmProduces12MP` 通过，最终 3000×2250，倍率恢复 2×。
- 1× 夜景回归通过：注入 0.125s/200、1s/3200、三/六帧融合和虚拟路线归还正常。
- 当前边界：独立会话只用于 ≥1.8× 的 48mm 夜景；24/28mm 仍走原夜景路径。最终像素受融合对齐边缘裁切影响，约 6.75MP，未达到完整 12MP。

# 2026-11-04 夜景稳定状态与 48MP 尝试

- 保留：A 挡夜景单帧上限 2 秒；长曝光成片数字提亮上限 0.5EV；暗部多帧降噪加强。
- 修复：夜景拍完后虚拟多摄可能停留在物理主摄；开始前保存原虚拟输入，结束后恢复并重置自动镜头选择。
- 真机：`testAutomaticNightUsesPlannedExposureAndRepeatedCaptureReleasesTasks` 通过 21.984 秒；注入 0.125s/200、1s/3200 均按计划执行，三帧/六帧融合和路线归还通过。
- 普通 48MP 拍照、Live 回归通过。
- 48MP 夜景尝试失败并已撤回：同一 `AVCaptureSession` 只能有一个 `AVCapturePhotoOutput`；动态替换输出导致第二次夜景连接失效；直接切 48MP 物理格式被 AVFoundation 以 Unsupported format 拒绝。
- 当前 48mm 仍是 12MP 数字裁切上采样；未实现原生 48MP 裁切，不能标记完成。

# 2026-11-04 48MP 夜景裁切能力探测

- iPhone 17 Pro 真机：普通路线 `maxBracketedCapturePhotoCount=8`，可用尺寸 `4032×3024 / 5712×4284`。
- 48MP 高像素路线：同样 `maxBracketedCapturePhotoCount=8`，尺寸增加 `8064×6048`。
- 说明：48MP 包围曝光在硬件/API 上可行，可支持多帧夜景；尚需实现“48mm 在高像素路线按 2× 中心裁切、输出 12MP”的专用采集与还原路径。
- 新增 `HighResolutionFixedFocalTests/testHighResolutionRouteBracketCapacityProbe` 记录该能力；未改用户拍摄行为。
- 当前 48mm 仍走 12MP 数字裁切上采样，不能宣称原生 48MP 裁切已完成。

# 2026-11-04 夜景噪点优化（第一阶段）

对比文件：原相机 `IMG_2692/2693`，光屿 `Luma-28795664…`、`Luma-C1AF6FF2…`。

- 原相机：1s、ISO5000/6400、4 帧合成，含 3.4s 长曝光帧。
- 光屿：1s、ISO3200、6/9 帧合成，但暗部明显更脏；48mm 输出约 2998×3997，来自约 3MP 数字裁切上采样。

已修改：
- A 挡自动夜景单帧上限 1s → **2s**（`handheldMaximumExposureSeconds`）。
- 夜景自动影调：有真实长曝光 EXIF（≥1.5s）时，数字提亮上限 2.5EV → **0.5EV**；无 EXIF/短曝光后备仍保留原上限，避免深暗场景发黑。
- 多帧融合：暗部降噪门限提高，低信号二次降噪提高（0.095 → 0.11），暗部色彩抑制更积极。
- 新增 `NightAdaptiveCapturePolicyTests.testAutomaticExposureUsesTwoSecondHandheldCeiling`。

验证：
- `NightAdaptiveCapturePolicyTests` 7 条通过。
- `NightPhotoMergerTests` 24 条通过。
- `NightAdaptiveCapturePhysicalTests`：自动计划、M 挡、取消、重复采集、三六九帧等通过；`testNaturalDarkRoomHandheldUltraWideAndMainWithSourceAttachments` 因当前亮室未触发暗景而失败，属于测试环境前置条件。
- 构建、安装、启动成功。

未完成/限制：
- 48mm 仍由系统数字裁切后输出约 12MP；未实现 48MP 传感器原生裁切，不能宣称 48mm 噪点已彻底解决。
- 尚未用同一暗房场景重拍四张对比图，实际噪点改善需复拍确认。

# 2026-11-04 Open Gate 顶部工具栏

- Open Gate 开启时，视频格式弹窗隐藏“分辨率”整行，只保留帧率。
- 帧率列表由 `videoFrameRateOptions` 按 `openGateVideoSettings` 过滤，不支持的帧率不创建按钮。
- 顶部工具栏原“分辨率/帧率”位置只显示当前帧率，例如 `30 fps`，不再显示分辨率。
- `PopupAppearanceAndOrientationTests/testOpenGateVideoFormatPopupHidesResolutionAndUnsupportedRates` 真机通过 2.979 秒。
- 构建、安装、启动成功；未做逐像素截图核对。

# 2026-11-04 照片文件格式弹窗高度

- 问题：照片模式顶部最左侧“文件格式”弹窗与普通弹窗共用 360pt 高度上限和 ScrollView，内容变化时高度被拉伸/裁切。
- 修复：`.format` 使用内容自适应容器，不再套固定 maxHeight；上下各 16pt 内边距，高度随说明文字和 HEIF Pro 状态变化。其他顶部弹窗保持原滚动上限。
- `PopupAppearanceAndOrientationTests/testTopToolbarPopupStaysPortraitAtLandscapeAngle` 与 `testTopToolbarPopupRapidOpenCloseRotationStress` 真机通过。
- 构建、安装、启动成功；未做逐像素截图比对。

# 2026-11-03 顶部弹窗按钮左对齐

- 选项内容占满弹窗内容区并左对齐，帧率及视频编码按钮行保留右侧空白，固定按钮尺寸和玻璃背景保持不变。
- iPhone 17 Pro / iOS 27.2 真机定向用例 1/1 通过：注入仅一个 1080p30 规格，分别核对两种宽度下分辨率、帧率单按钮距左边 16 pt 和原宽度；共检查 16 组弹窗布局、40 次快速切换及关闭。测试包含等待时间，未测量实际渲染帧率；未逐项目视核对横屏和所有规格。

# 2026-11-03 顶部弹窗统一宽度

- 顶部八种照片/视频选项面板使用同一可用宽度，不再根据选项数量缩窄；保留按钮现有宽度、玻璃背景和弹窗过渡。
- iPhone 17 Pro / iOS 27.2 真机定向测试 1/1 通过：304 pt 和设备宽度两组共 16 个面板布局，检查弹窗宽度及视频分辨率按钮 70 pt；连续切换 40 次后关闭正常。全程约 1.38 秒包含人为测试等待，不能代表实际帧率或动画性能。
- 本轮未逐一目视核查所有比例、方向及单按钮规格的真机画面，未测长时间动画流畅度。

# 2026-11-03 Open Gate 全尺寸输出

- Open Gate 编码基准改为实际 activeFormat 像素尺寸，4:3 保留完整画面，1:1 从短边居中裁切；关闭后仍遵循普通视频选定尺寸。规格列表继续用于设备与帧率兼容性判断，说明弹窗已注明全尺寸输出。
- iPhone 17 Pro、iOS 27.2，1080p30 SDR HEVC 定向真机用例 1/1 通过：使用 4032×3024 源，4:3 两段输出 4032×3024，1:1 两段输出 3024×3024，解码帧率约 30 fps（每段 34–36 帧）；20 次快速开关后普通 16:9 输出 1920×1080。测试短片存临时目录并清理。
- 四段短片无法代表长时间发热、存储或其他规格、帧率、镜头的表现；尚未逐项实测。输出像素可能高于所选的标称视频分辨率，实际尺寸取决于设备格式。

# 2026-11-03 Open Gate 格式回退定向复核（修改前）

- 当前 HEVC 格式选择分支已传递 `openGateRequested`；本轮检查时该代码已经存在，没有重复修改拍摄路径。
- 旧测试先在 16:9 下启用 Open Gate，与当前须先选择 4:3 或 1:1 的规则不一致。已修正顺序，并在每段 Open Gate 录像前检查实际源格式。
- iPhone 17 Pro、iOS 27.2，1080p30 SDR HEVC 定向真机用例 1/1 通过：四段 Open Gate 使用 4032×3024 源；两段 4:3 输出 1920×1440，两段 1:1 输出 1440×1440，解码帧率约 30 fps。20 次快速开关后，普通 16:9 输出 1920×1080；临时视频已由测试清理。
- 未覆盖其他分辨率、帧率和镜头；测试数据仅反映本次设备和设置。

# 2026-11-03 Open Gate 崩溃与比例筛选

- 崩溃原因：视频输出被写入超过当前 activeFormat 的宽高，AVFoundation 抛 `NSInvalidArgumentException`。
- 修复：所有预览/录制 VideoDataOutput 写入前统一经过 `safeVideoOutputSettings`；超尺寸宽高被移除，回到 activeFormat 原生尺寸。Open Gate、4:3、1:1 共用安全路径。
- `VideoSpecificationTests.testOpenGateSwitchRecordsOnlyFourByThreeOrSquareOnDevice` 真机通过 10.480 秒；4:3/1:1 实际编码完成。
- Open Gate 比例选项由 `videoRatioOptions` 过滤为 4:3/1:1；其他比例 `supportsVideoRatio` 返回 false。
- 构建、安装、启动成功；未对 Open Gate 比例弹窗做截图级核对。

# 2026-11-03 普通视频画幅源格式

- 普通视频不再让所有画幅先选 16:9 再裁切：`VideoCaptureSettings.format` 接收 `FrameRatio`。
- 4:3、1:1 优先选择原生 4:3 源；16:9、2:1、2.39 保持 16:9 源；Open Gate、双拍、电影、慢动作路径不变。
- 1080 实测源格式：4:3 → **1440×1080**，1:1 → **1440×1080**，16:9/2:1/2.39 → **1920×1080**。
- 4K 4:3 实测源格式：**3264×2448**（原生 4:3，不是 3840×2160 再裁）。
- 修正预览/录制输出尺寸：录制输出使用实际 activeFormat 尺寸；预览重配前清空旧宽高，避免 1440 源写入 1920 约束导致 AVFoundation 异常。
- `VideoSpecificationTests/testOrdinaryFourThreeUsesNativeFourThreeFormat` 真机通过 4.233 秒；构建、安装、启动成功。
- 未对每种比例逐段录制并检查最终文件像素尺寸；4K 4:3 最终编码尺寸仍需实测确认。

# 2026-11-03 主摄 1× 循环 24/28/35mm

- 后置主摄 1× 点击顺序改为 **24 → 28 → 35 → 24mm**，全部通过 `nextMainFocalZoom` 统一计算；A/M/Live/双拍后置主画面共用。
- 28mm 对应 28/24≈1.1667× 数字裁切；35mm 仍为 35/24≈1.4583×。
- 焦段标题同步显示 24mm/28mm/35mm；高像素 48MP 仍禁止 1× 的 24/28/35 轮换。
- `MainFocalPresetPhysicalTests` 单独真机通过 1.214 秒；`CameraFocalButtonTests` 全类通过；`LivePhotoPhysicalTests` 全类通过，Live 下 A/M 循环通过。
- `CinematicZoomPhysicalTests`、`SlowMotionLensTransitionPhysicalTests` 已同步断言但本次未逐项复跑。
- 构建、安装、启动成功。

# 2026-11-03 M 挡 1× 支持 24/35mm

- 现象：普通 M 挡（未开 Live）点击 1× 不切换 24/35mm；A 挡和 Live 下正常。
- 原因：`selectFocalLength` 和 `focalButtonTitle` 的 24/35mm 分支只包含 A 挡、电影和 Live，遗漏普通 M 挡。
- 修复：两个条件都加入 `mode == .manual`；M 挡点击 1× 仍调用 `setContinuousZoom`，不切换物理镜头。
- 构建、安装、启动成功；未单独跑 M 挡无 Live 的自动化用例，需真机点击核对。

# 2026-11-03 固定焦段条加宽与命中扩展

- 所有固定焦段条的按钮宽度上限由 40pt 调到 42pt；仍由可用宽度和数量计算，窄屏不会被强行塞满。
- 所有 `CameraFocalControl` 命中区域横向外扩 1pt、纵向外扩 4pt；横向只占 2pt 间距中的 1pt，避免相邻焦段互相抢点击。
- `CameraFocalButtonTests` 全类通过：真实窗口焦段命中、Live 下焦段、长按拖动、隐藏/禁用拒绝触摸等；`testHostedFocalStripHitTargetsAfterRepeatedSelections` 21.324 秒，`testLiveFocalButtonHitAndActualZoom` 13.414 秒。
- 构建、安装、启动成功；未做精确像素级边界统计。

# 2026-11-03 A/M、拍摄辅助、子模块按钮扩大点击范围

- 三者的图标、视觉直径、位置和 HStack 间距不变；命中形状用 `Rectangle().inset(by: -8)` 向外扩展 8pt。
- 共享常量 `CameraControlLayout.buttonHitExpansion = 8`。
- 构建、安装、启动成功；未做精确命中边界截图/点击统计。

# 2026-11-03 Live 开启后 24/35mm 预览不更新

- 现象：A 挡、后置 1×，Live 开启后点击 1× 在 24mm/35mm 间切换，硬件倍率和选中态变化，但预览画面不变。
- 原因方向：Live 开启后预览使用 `videoOutput.deliversPreviewSizedOutputBuffers` 代理；代理在 1→1.458 数字裁切变化后可能沿用旧裁剪。
- 修复：A 挡 Live 变焦改走物理镜头路径，避免虚拟多摄代理固定裁切；随后强制重建一次 Live 预览代理，并恢复本次请求的目标倍率（而不是配置前倍率），避免 35→1× 回退时写回 1.458×；RAW 视频仍保留代理路径。
- 回归：`CameraFocalButtonTests.testLiveFocalButtonHitAndActualZoom` 13.883 秒通过；`LivePhotoPhysicalTests` 全类通过，`testNativeJPEGAndHEIFLivePairsDecodeWithoutWritingPhotos` 14.036 秒、`testRearLiveTogglePreserves24mmAnd35mmFraming` 4.779 秒。截图对照确认 24/35mm 预览画面有变化；未做逐像素质量评价。
- 构建、安装成功。

# 2026-11-03 夜景单帧上限恢复 1 秒

- 应要求把手持自动夜景单帧上限从 1/4 秒改为 **1 秒**（中间曾试 0.5 秒，未落盘验证）。
- 目的：恢复暗光进光量，避免 1/4 秒把 ISO 推到约 12500；手持稳定性仍由镜头防抖、多帧配准和运动保护承担。
- 构建、安装、启动成功。夜景计划曝光专项在 1 秒版本已通过：HEIF 实测 0.5s/3200 + 1s/3200 + 1s/3200，结束后路由归还断言也通过。全量测试仍是 1/4 秒版本的结果，1 秒版本尚未重跑全量。
- 慢门手动包围专项复跑仍失败：三个预设输出均为 2250×3000（6.75MP），速度断言通过；与曝光上限修改无关。

# 2026-11-03 全量测试

- 800 个设备可见方法：727 通过、47 失败、22 跳过、4 未完成；4 次测试宿主重启；约 77 分钟。
- 高分辨率首拍、夜景手持曝光/帧数、慢门长序列、双拍快速切换、Live/RAW 连续状态、视频虚拟光圈为失败集中区。
- 压力组 3 轮：156 启动、154 通过、1 失败、1 跳过，夜景全尺寸渲染重复时宿主重启。
- 测试使用只读相册诊断；Description profile 中途到期导致首轮 302 项中止，刷新后重跑。
- Release 构建通过；不把 800 个设备方法写成 845 个源码方法全部通过。
- 完整分类、问题、功能完成度和证据：[2026-11-03-Full-Test.md](Test-Reports/2026-11-03-Full-Test.md)。
- 11:38 两项专项复跑仍 2/2 失败：夜景计划曝光 0.25s/ISO12500、结束后路由未归还；慢门三预设输出均 2250×3000（6.75MP），速度断言通过。证据 `/tmp/TwoFailedItems.xcresult`。

# 2026-11-03 夜景高ISO残余颗粒

原图均1秒/ISO3200，分别9帧及6帧合成；本轮按源ISO增强暗部处理，显式传递配准后拍摄元数据。最终30/30夜景方法通过11.801秒，固定噪声样本标准差下降38.8%–41.9%，并非实景SNR。视频滑块完整页面方法通过13.048秒（5种比例、快速操作/持有/录像回退）。未验收同等暗室新成片或全尺寸性能。[报告](Test-Reports/2026-11-03-Night-HighISO.md)。

# 2026-11-02 视频虚拟光圈入口

新入口定向真机方法通过11.653秒，5种比例最大动作到布局登记25.157ms（非显示FPS），持续持有、重置3秒计时、10次取消及实际录像中调节/停止回退通过。复用实际窗口，临时录像未写相册；附带人像首次持有3条断言失败，不能将整组写成通过。未全量测试。[报告](Test-Reports/2026-11-02-Video-Aperture-Entry.md)。

# 2026-11-02 双拍与视频预设变焦

最终代码8个不同相关方法有通过记录。双拍120次手势最大采集间隔38.495ms，录像实际倍率、副画面不变、三次主副往返、停止退出均通过；延时180次手势最大166.126ms，偶发间隔仍待优化。电影16次倍率验证通过；慢动作240fps实收约210–216未达标，保留失败。指标是采集侧时间戳，不是显示FPS；无修复前同场景基线或长期热稳。[完整记录](Test-Reports/2026-11-02-DualCapture-Zoom.md)。

# 2026-11-02 智拍未对齐点位稳定性

最终相关31个不同方法有通过记录：FinalRelated27项全部通过34.632秒，对齐后对焦/自动取景2项、模型能力1项、用户现场1项通过。现场12.214秒、58次200ms有效观察均有点，无新UUID与观察到的无点间隔；处理时间尾段中位21.435ms、发布间隔66.856ms，非显示FPS。UI32组合绘制最大27.615ms，合成平移24次中位8.530ms/P95 8.961ms，均不是实际帧率。前轮4.316/1.637/1.646秒无点失败、无候选与范围不足跳过、结构筛选实验撤下全部保留。Release通过，仅AppIntents工具提示；系统模型deviceNotEligible，未验收其生成能力。未写系统相册、未全量或测长期热稳；[完整记录](Test-Reports/2026-11-02-Smart-Point-Stability.md)。

# 2026-11-02 主要功能回归

iPhone17Pro/iOS27.2，21结果包与日志逐一核对。287个不同方法最后状态282通过/1失败/4跳过；296次执行共282通过/10失败/4跳过。9个首次串行失败方法独立复验通过，未改代码，不视为修复。剩余失败是自然暗景前置门限未触发；真人智拍完整对齐闭环亦未完成。确认视频虚拟光圈菜单入口缺失，内部处理和编码测试仍通过；关于及夜景无障碍说明过时。383份源码、测试和项目配置SHA-256无变化，仅测试和记录，已恢复普通App。人像55次有效分割、180次调节；微距3照片；按住连拍三轮13张；真实4K60/120编码与解码；真实相册首批60项查询通过。性能与显示链/截图/发布频率的含义、初始失败和未覆盖范围均见[完整报告](Test-Reports/2026-11-02-Main-Functions.md)、[问题清单](Test-Reports/2026-11-02-Main-Functions-Issues.md)。

# 2026-11-02 慢门与码率颜色

iPhone17Pro/iOS27.2，3个不同定向方法有通过结果。慢门71次截图分上/下行核对五预设、十时长、两宽度及弹窗开关，20对快速取消通过；56组全比例/四方向关联布局通过。设置码率26次截图覆盖四档、两宽度、重复选择、20对快速切换及重新显示，通过且默认/高档截图目视检查。截图中位/最大分别35.691/41.757ms、49.005/59.519ms、44.161/57.093ms，非FPS。Core两项通过38.911秒；Final慢门两项通过/设置一项18断言失败，Settings2仍失败，显式菜单标签后Settings3通过9.127秒。Release通过、源码警告0，仅AppIntents工具提示；不写系统照片。[完整证据](Test-Reports/2026-11-02-Control-Selection-Colors.md)。

# 2026-11-02 普通视频防抖

电影/延时/慢动作补查最终1方法通过15.286秒，实际防抖2/2/1、完整解码62/2/485帧；慢动作为1080p240采集、30fps播放。首轮两条断言错误要求240fps也为电影级，改为验证标准回退后通过，生产代码未改。Live/HDR/M挡6实际文件关联返回通过69.529秒，Release通过、源码警告0，普通App已恢复。用户仍感有些抖动，观感优化未关闭。最终7个不同功能方法有通过结果，另有基线诊断1方法。

iPhone17Pro/iOS27.2。基线1方法确认录制连接支持防抖却实际off，预览为previewOptimized。初版auto四项通过但进入视频源帧恢复2.273—2.357秒；最终cinematic优先四项通过57.235秒，七组物理镜头/规格、6次往返和一次快速切换、前后A/M三路实录通过，实际模式2、解码61/63/62帧，PTS最大约1/30秒。用户手持10秒专项通过，解码301帧、模式2、最大PTS间隔约1/30秒。7配置就绪观察（含250ms等待）中位574.432ms/最大767.333ms；恢复源帧时间非屏幕FPS，未量化同输入降抖率。诊断不写系统照片。[完整记录与边界](Test-Reports/2026-11-02-Video-Stabilization.md)。

# 2026-11-02 变焦入口及3秒隐藏

iPhone17Pro/iOS27.2，14个不同方法定向有通过记录：ThreeSeconds首批12通过/2失败（4条断言）、147.561秒；改为等待实际倍率及淡入后命中就绪后，Retry两方法全部通过、57.168秒。人像景深/虚拟光圈6次计时4秒档待复测（旧记录为3.016—3.031秒），待机轮盘3.035秒、后置A录像轮盘3.032秒；持有、重置、快速开关和取消重开通过。80组UI布局及隐藏按钮新触摸拒绝/进行中长按延续通过。实际前置A/后置M复验/后置A录像完整解码55/68/363帧，实际倍率变化、输入规格保持。20次布局截图中位28.632ms/最大34.848ms，非FPS；诊断不写系统照片。2026-11-02 Release通过、源码警告0，仅AppIntents元数据工具提示；普通App已恢复。[证据、失败及限制](Test-Reports/2026-11-01-Video-Zoom-Interaction.md)。

# 2026-11-01 录像变焦轮及慢门预设颜色

iPhone17Pro/iOS27.2，24个不同方法有通过记录；最终4个新录制/布局方法全部通过79.142秒，颜色与19项关联分别通过。前置A、后置M、后置A实际HEVC SDR1080p30影片完整解码51/68/451帧，硬件倍率查询确认变化，输入与规格不变；M挡4.5×仍原物理设备。轮盘持有5.2秒不收起，操作后重新计时约5.032秒自动隐藏并恢复焦段条；各20个快速倍率请求、10对快速开关及停止清理通过。80真机UI状态组合覆盖两宽度、A/M、五比例、四角度的隐藏/恢复/点击/拖动及固定位置，非80次实录。五预设/六未选颜色检查通过，11次截图中位23.341ms/最大32.851ms；布局20次截图中位28.495ms/最大35.136ms，非FPS。早期测试基线/观察修正、旧同时显示阶段触摸与布局失败保留；最终按用户最新互斥要求通过。Release通过、源码警告0，普通App已恢复；未逐一验证所有编码、电影/居中、RAW外盘和双摄，双摄变焦仍禁用。[完整记录](Test-Reports/2026-11-01-Recording-Zoom.md)。

# 2026-11-01 后置横拍文件方向及铺满封面

用户实际打开的两份资源确认：竖屏持机/页面、额外显示角度0°，但照片本体2250×4000/EXIF1内容侧转，视频1440×1080/90°矩阵内容侧转。仅改显示侧的首次用户验收失败，随后修正后置保存方向。真实横拿新照片4000×2250/EXIF1、视频1920×1080/矩阵0°；竖拿2250×4000/EXIF1、视频自然1920×1080/矩阵90°显示1080×1920，均通过，横拍新文件目视正向。UI33个不同方法通过，Rear-Core18方法/20个编码方向画幅文件通过，同一实拍方法两姿态通过，Live/夜景3方法通过，合计55个不同回归方法；非全项目重跑。相册按钮32像素方向/铺满检查，封面18次变向仅2请求/2取消；截图成本及轮询指标非FPS或真实手持延迟。旧文件保留，需单独旋转；RAW外接/双摄/慢门视频帧合成未新增物理方向验收。[完整记录、失败保留与指标](Test-Reports/2026-11-01-Library-Upright-Fill.md)。

# 2026-11-01 相册照片与视频方向（首版记录）

iPhone17Pro/iOS27.2，最终30个不同方法有通过结果：联合批次29通过/1旧手势数量断言失败，更新为四本地方向、只启用屏幕左右两种后定向复验通过。照片112组全画幅/横竖图片/受控方向布局、同一视图缩放后旋转与40次快速变向、退出重开通过；照片/视频缩略图18次方向设置仅2次请求/2次取消。视频10组画布/播放条/固定按钮布局及40次快速变向退出通过。照片4截图中位40.012ms、最大44.610ms；缩略图18截图中位41.159ms、最大51.283ms；视频10截图含附件均值122.732ms、最大206.757ms，均非FPS。8个生成JPEG EXIF方向值保留，未写系统照片；未新增真实手持转向、系统减弱动态效果开关及长期热稳验收。前期动画采样断言和只读环境注入编译失败均保留。Release通过、源码警告0，普通App已恢复。[完整证据](Test-Reports/2026-11-01-Library-Media-Rotation.md)。

# 2026-11-01 顶部预设弹窗与前置广角

iPhone17Pro/iOS27.2，最终15方法全部通过、0失败/0跳过，86.291秒。慢门56布局、重复专项8、延时40布局，含320/402点与四控件角度注入；固定五列、选项32点高、少项留空、焦段不移动、退出关闭与重复开关通过。H.264两色彩与五预设同槽宽；慢门预设切换窗口38次实际预览发布/1.247秒，非屏幕FPS。慢门20快照绘制中位55.19ms/最大71.04ms，延时10次中位50.35ms/最大61.01ms，非显示帧率。前置视频广角6状态，选中/按下背景alpha=0、无内部玻璃、原生命中通过；相关截图已目视检查。延时实际2.2秒采集、解码3帧、成片0.1秒/30fps/无音轨；两张关联48MP文件6000×8000。扩展首轮9通过/6失败保留：延时旧测试未从清理基线开始且快门切换未结束就开拍；改为实际快门等待后观测switch=true时额外22.09ms就绪，再串行全通过。生产录像链未改。Release通过、源码警告0，普通App已恢复，诊断未写系统照片；非全量、未测长期热稳或真实手指延迟。SLOW-RESUME-001仍开放。[完整记录](Test-Reports/2026-11-01-Preset-Toolbar.md)。

# 2026-11-01 慢门长期返回卡住：未关闭

iPhone17Pro/iOS27.2，诊断及关联恢复最终11方法全通过，84.398秒；并未复现用户所述长期退出后预览/按钮同时卡死。五个实际HEIF Pro/2×/16:9存档冷重建及出片通过，恢复完成中位9.364秒；10次显式停启恢复中位0.566秒/最大0.651秒，20对快速停启保留预设、pending=0，非真实OS挂起。真实后台186.005秒返回0.432秒有新帧，用户确认可点；自动按钮状态断言未捕获并失败，保留记录。普通App进程冷启动后用户确认时长/设置可操作。新增本地20秒、每路单个探针、64事件上限诊断；受控主线程探针阻塞、缺帧区分、恢复/迟到回调、持久化重建通过；100次入队中位0.000917ms/最大0.03946ms，含磁盘完成0.2785秒，非FPS。原UserState测试错误按16:9裁切结果要求大于1000万像素，实际900万，修正后复验通过；未改输出像素策略。最终字段版4个关联方法再通过8.018秒，合计仍为11个不同方法；Release2通过、源码警告0，普通App已恢复。实际日志64条/28572字节，最终main.zoomTarget=2.0、ready=true；后续窗口preset=none仅核对日志落盘，不追加车流复现结论。[排查及完整限制](Test-Reports/2026-11-01-SlowShutter-Resume.md)。

# 2026-11-01 其他六项定向复验

iPhone17Pro/iOS27.2，最终4批12个不同方法全通过、0失败/0跳过，执行合计163.627秒；六项FULL-002/035/039/072/073/082全部定向通过。修正顶部滑条完整浮层及测试计数/路由等待/窗口生命周期；真实手指160次变化覆盖全范围，3×90次受控更新预览48/47/47次、最大间隔44.19ms，非显示FPS。自动镜头7倍率观察中位34.34ms/最大52.21ms；实际48MP恢复6000×8000，HDR回标准10bit PQ；32顶部布局、28光圈布局、重复/快速切换/取消/后台返回、主长焦文件EXIF通过。真人后置180次调节无空白、两张通过；分割55样本接受3/无可用52，不宣称稳定识别率；自动微距实际超广角供图三张通过。Release通过、源码警告0，普通App已恢复，未写系统照片。保留此前所有失败；一条人像摘要导出被自动审批拒绝，结果据原始日志。未全量重跑或长期热稳。[证据与限制](Test-Reports/2026-11-01-Other-Six-Fixes.md)。

# 2026-11-01 视频六项与真人横竖录像

iPhone17Pro/iOS27.2，最终三批9个不同方法全部通过、0失败/0跳过，原FULL-004/017/018/076/077/081均通过，关联FULL-019亦通过。基线无需人物四项2通过/2失败，自动路线和白平衡首次点击仍在模式切换中；补实际快门启用等待后分别约45/65ms就绪，生产录制源码未改。12组白平衡录像全解码，锁定增益稳定、结束恢复及立即取消通过，开拍p50 39.30ms/最大118.76ms。六次视频后真实照片保留Live配对、10位PQ、M挡ISO200/0.5秒和方向标签1；返回状态中位0.622秒。用户配合单人横竖各12秒实录，实际显示1080×1920和1920×1080，12个抽样帧均检出人脸，1秒帧已目视方向；预览发布间隔非显示FPS。12前置规格、五画幅/四方向、重复/快速切换/后台与取消通过。Release通过、源码警告0，普通App已恢复，未写系统照片；跟随平滑/多人及持续热稳未量化，未全量重跑。[证据与原失败保留](Test-Reports/2026-11-01-Video-Six-Fixes.md)。

# 2026-11-01 长焦导航倍率与恢复

iPhone17Pro/iOS27.2，最终13方法0失败/0跳过、81.725秒，原FULL-014/015/016通过。新增真机先复现A/M导航8→16倍仍以旧焦距拍摄、退出硬件回8倍，再修正为照片格式恢复后应用最新倍率；实际文件A挡197→408mm、M挡200→400mm，退出均16倍。Live配对MOV、DNG、M挡JPEG/HEIF的ISO200及1/120秒、28布局/252拖动目标、后台与15次快速辅助开关通过。导航进入n=4中位0.609秒、退出n=3中位0.548秒；95帧缩图平均1.000ms，非屏幕FPS。导航退出后实际录像30fps；关联普通录像首次快门仍在切换的等待已修正，三轮1080p30/音轨、前置与返回拍照通过，FULL-004方法关闭，未改生产录像。第一轮扩展12通过/1失败和倍率复现失败均保留。Release通过、源码警告0，普通App已恢复，诊断未写系统照片；长时热稳、近距视差与自然场景画质仍有验收边界，未全量重跑。[结果与证据](Test-Reports/2026-11-01-FocusNavigator-Fixes.md)。

# 2026-11-01 慢门剩余九项

iPhone17Pro/iOS27.2，最终45方法：43通过、0失败、2旧夹具因会话未启动跳过，执行905.130秒；原FULL-001/054/055/058/060/063/064/065/071全部通过。35次完整序列实际编码尺寸均3000×4000；两条完整星轨61.438/61.528秒，实际融合181/174帧。571次中间预览最短发布间隔0.502790秒；40次受控位移画布不缩小、无黑边。16次配准/检查点渲染中位105.38ms；12次原生尺寸累积预览渲染中位2.25ms，均非显示FPS。真实M挡曝光、四次采集/回退交替、提前结束、取消、重拍、迟到源帧及快速切换通过；长序列保留源帧≤1，宿主内存不可当作普通App内存。Release通过，源码警告0，保留工具链及运行日志观察；普通App已恢复，未写系统照片。另记录源EXIF尺寸字段未更新，未做自然流水/夜空画质验收及全量重跑。[完整记录](Test-Reports/2026-11-01-SlowShutter-Fixes.md)。

# 2026-11-01 双摄错误恢复与布局

iPhone17Pro/iOS27.2，14方法全部通过、0失败/0跳过，103.415秒。覆盖25规格实际录制解码、五画幅、横竖小窗、反复交换/退出/后台返回；3次旧错误注入不退出新会话，当前错误后保留视频并恢复原帧率，普通文件30fps与音轨通过。HUD用显示后的最新框验证并核对合成位置，两个原失败方法通过；真实会话运行错误0。进入/退出各3样本中位0.554/0.586秒，实际图替换3样本中位0.561秒；25组全流程中位1.615秒，非单纯切换或显示FPS。Release通过，源码编译警告0，保留工具链AppIntents及局部测试宿主Environment提示；普通App已恢复，诊断媒体未写系统照片。未全量重跑。[证据与局限](Test-Reports/2026-11-01-DualCapture-Recovery.md)。

# 2026-10-31 A挡夜景真实暗房验证

最终iPhone17Pro/iOS27.2：45方法全部通过、152.894秒；真实暗房另1方法通过，0.5×/1×各9帧采集/融合，JPEG元数据核对；自然单张11.398/15.013秒。低信号补充修正后以同源PNG复算检查：固定区域亮度+1.19%，高频残差-46.18%、色度差-82.64%，不代表整图SNR。12次320×240渲染中位95.87ms、p95 98.14ms，非FPS；4轮取消与返回、A/M保留、真实6帧未知评估及慢门关联通过。Release通过、源码警告0，保留工具链AppIntents提示。极暗超广角仍有颗粒，完整736项未重跑。[证据与边界](Test-Reports/2026-10-31-Night-Quality.md)。

# 2026-10-30 夜景取消与完成回调

iPhone17Pro/iOS27.2：17方法全部通过、0失败/0跳过，155.244秒；原FULL-027/FULL-030通过。4轮A/M采集/后台合成取消均0交付，重拍均恰好1次完成，活动/取消集合归零；任务释放中位0.850秒/最大0.995秒，重拍中位2.568秒/最大3.952秒。覆盖曝光保留、追加批次取消、快速返回、预览全画幅与超时/迟到恢复；42夜景快照中位45.56ms，非FPS。Release通过，源码警告0，保留AppIntents工具链提示；普通App已恢复。未做自然暗室画质A/B或全量重跑。[结果与局限](Test-Reports/2026-10-30-Night-Cancellation.md)。

# 2026-10-30 原82项失败复验

第一轮原失败52通过、30失败（含关联共91方法，61通过/30失败）。最新Quick3真机8方法7通过、1失败，46.798秒；流水异常帧剔除、焦段点击及8倍导航往返方法通过，重复录像仍失败。120次900×675渲染中位0.588ms/最大1.255ms，非FPS。4项人物/微距场景待配合；夜景取消、星轨长序列及剩余回归未闭环，不标记全部修复。[逐项明细及局限](Test-Reports/2026-10-30-Priority-Fixes.md)。

# 2026-10-30 优先级修复：第一组

36项真机检查0失败/0跳过、46.080秒，日志`/tmp/LumaCamera-PriorityFix-Core.log`。请求回调归属/失败一次、超时与退出恢复、慢门累积预览、HDR/SDR/P3像素元数据及诊断隔离通过；120渲染样本中位1.05ms/最大4.29ms，非显示FPS。对应原FULL-034、FULL-050通过。[修复进度](Test-Reports/2026-10-30-Priority-Fixes.md)。

# 2026-10-30 真机全量测试

iPhone17Pro / iOS27.2单机串行完成736项：**641通过、82失败、13跳过**，约68分钟。记录IOSurface内存分配失败及一次宿主异常退出、成片回调/解码编码与慢门合成失败、未保存队列达到4张后的拍摄背压、实际视频帧率不达标，以及格式/状态/布局问题。代码未改，373份文件哈希一致；普通App已恢复启动。[完整报告](Test-Reports/2026-10-30-FullDevice.md) · [82项问题清单](Test-Reports/2026-10-30-FullDevice-TODO.md)。5个相册写入/外盘/人工姿态方法另行排除；XCTest性能样本及13个跳过原因见JSON。

# 2026-10-30 Pro影调格式弹窗入口（最终澄清）

iPhone17Pro/iOS27.2真机21项0失败/0跳过，47.898秒。覆盖32布局、顶部五项恢复、滑条保持按钮下方、320点及原生宽度共8轮格式往返；弹窗HEIF Pro右侧Pro影调按钮与其他格式按钮同宽同高。两个模式实际HEIF Pro/Exif及退出恢复通过；20快照中位32.91ms、最大41.24ms，非显示FPS。最终Release构建通过，源码警告0，保留AppIntents工具链提示。未全量或主观画质验收。[报告](Test-Reports/2026-10-30-ProTone-FormatPopup.md)。以下顶部六项记录为历史，已被本轮澄清替代。

# 2026-10-30 Pro影调独立入口与滑条锚定

最终真机专项1项0失败/0跳过，40.323秒；相关PhotoOptionsTests20项通过。32布局核对HEIF Pro后影调按钮、六项等宽、滑条跟随模式按钮；320点/原生宽度共8轮格式往返及影调开关通过。两个模式HEIF Pro实际HEIC/Exif、长按、40次滑条开关及退出恢复通过，无相册写入。20快照中位32.32ms/最大37.51ms，非显示FPS；Release通过，源码警告0，保留AppIntents工具链提示。未全量、未做主观画质验收。[报告](Test-Reports/2026-10-30-ProTone-Toolbar.md)。本次按钮下方定位替代上一轮工具栏居中要求。

# 2026-10-30 顶部景深／光圈调节

iPhone17Pro/iOS27.2真机21项0失败/0跳过、29.672秒；Release构建通过，源码警告0（保留AppIntents元数据跳过提示）；32布局确认原190×32居中位置及HEIF Pro按钮入口，两个模式实际HEIC文件/Exif检查通过。覆盖40次快速开关、持续编辑5.25秒、弹窗互斥、工具栏翻页及停止重启恢复。20快照同步绘制中位33.37ms/最大37.49ms，非显示FPS。滑条按用户要求恢复原位置，不声明所有画幅与直方图无交叠；未全量或主观画质验收。[详细报告](Test-Reports/2026-10-30-Depth-Toolbar.md)。

# 2026-10-30 电影模式焦段与 M 挡布局

最终组合8项0失败/0跳过，补充硬件专项1项0失败/0跳过，前置子模式专项单项通过。覆盖A/M的24/35mm循环与1–3×硬件倍率、电影input保持、隐藏期间自动曝光、10种布局、3轮退出恢复与60次快速倍率请求、转盘边界/关闭及真实3×1080p30文件。Release真机构建通过，源码警告0（保留工具链AppIntents元数据跳过提示）。16个倍率队列清空样本中位16.31ms/最大31.63ms，非首帧或显示FPS。设备iPhone17Pro/iOS27.2，未全量回归或验证所有4K/HDR组合；详见[报告](Test-Reports/2026-10-30-Cinematic-Zoom.md)。

# 2026-10-30 慢门手持稳定与真实累积预览

iPhone17Pro / iOS27.2（24B119）：五预设端到端15项0失败/0跳过、230.197秒，含175源帧星轨完整长序列、流水A/M、光轨/动态模糊/摇拍、实际文件EXIF/曝光、提前结束/取消及快速重开。几何/曝光/预览收尾34项0失败/0跳过、57.456秒。稳定区域对齐、小幅旋转/透视、摇拍失跟恢复与短单帧偏好已接入，手动数值/既有时长保持；七画幅×两成片方向14份JPEG编码核对通过。日志`/tmp/LumaCamera-SlowHandheld-Physical.log`、`/tmp/LumaCamera-SlowHandheld-Clean.log`，详细指标见[专项报告](Test-Reports/2026-10-30-SlowShutter-Handheld.md)。

随后接入真实累积结果预览，7项真机0失败/0跳过、71.731秒，光轨/动态模糊/摇拍/流水中间更新及正式成片衔接、取消晚到帧清理通过；M挡参数保留、星轨提前结束/取消和10轮切换复测通过。最终5项0失败/0跳过、10.474秒，包含七画幅×两内容方向14布局/28关键帧、渲染预览不改变完整结果和真实亮部累积。4032×3024→900像素中性预览12次中位2.84ms/最大11.00ms；UI快照28次中位40.38ms/最大49.58ms，不作FPS或应用内存。日志`/tmp/LumaCamera-SlowAccumulation-Physical.log`、`/tmp/LumaCamera-SlowAccumulation-Verified.log`。最终Release成功、源码警告0，保留AppIntents工具提示：`/tmp/LumaCamera-SlowAccumulation-Release.log`。

未在用户原鱼缸同条件复拍自然手持A/B，室内星轨流程不代表夜空画质；复杂滤镜、长期热负载和系统减弱动态效果开启状态未另行测量。过程中的旧M范围/旧预览断言、UIKit导入及性能夹具画幅问题均在专项报告中记录，不把初次失败或跳过记为通过。

# 2026-10-30 夜景手持容错与渐亮预览

最终27项定向真机测试通过，0失败/0跳过、73.517秒，iPhone17Pro / iOS27.2（24B119）。修正Vision参考/待对齐图传反，已知9/−6像素位移实际补偿−9/+6、3帧融合平均像素误差0；小角度旋转与位移、部分帧保留、局部运动保护、自动暗部噪声、曝光归一、单帧回退及历史非自适应像素基准通过。真实3/6帧JPG/HEIF、1秒ISO3200源曝光与合成元数据、重复拍摄、6帧追加时取消及普通拍摄返回通过，不写系统相册。

夜景取景独立提亮、拍摄按帧渐亮并衔接真实成片；两次真实拍摄+一次取消共16状态发布，固定控件不移动。七画幅×两个方向14配置42亮度关键帧递增，实际截图核对。320×240自动融合及渲染12次中位98.2ms/P95 100.8ms，UI快照绘制42次中位44.9ms/最大52.5ms，均不是实际预览FPS或应用内存。人工三帧RGB噪声亮度38.07→76.57，归一化亮度标准差0.2664→0.0433，仅代表人工单帧输入对照，不能当作用户房间或旧版实拍降噪百分比。

日志`/tmp/LumaCamera-NightHandheld-Clean.log`，结果`/tmp/LumaCamera-WarningAudit-DD/Logs/Test/Test-LumaCamera-2026.10.30_14-41-06-+0800.xcresult`；Release成功、源码警告0（保留AppIntents元数据工具提示），`/tmp/LumaCamera-NightHandheld-Release-Final.log`。TIFF当前ImageIO会丢弃合成张数字段，曝光数组/通用合成标志已回读；JPG/HEIF三字段已核对。未复拍用户原房间自然手持对照，未测试系统减弱动态效果开关、长期热负载或功耗，不宣称与原相机画质相同。过程失败、测试画布/生命周期修正、指标定义和剩余范围见[专项报告](Test-Reports/2026-10-30-Night-Handheld-Preview.md)。

# 2026-10-29 焦段条重复玻璃层修正

7项相关真机检查通过，0失败/跳过。共同玻璃容器内的按钮不再生成额外选中玻璃；独立按钮保持玻璃。200次状态/尺寸布局工作约3.62ms（程序化CPU布局，非显示FPS），并覆盖点击/长按/取消和真实相机7种画幅、20次快速开关。未测试独立功耗/温度或iOS18实机。[详细记录](Test-Reports/2026-10-29-FocalBar-Glass.md)。

# 2026-10-29 慢门 A/M 时长与预设恢复

3项相关真机方法全部通过：五预设及有效时长往返、M默认1s、无预设A默认1s、10次快速往返、取消/重开、存档迁移和后置切镜。五轮完整操作脚本约2.45–2.63秒，包含队列/覆盖层等待及M内修改，不是单次切挡速度或实际FPS。未保存诊断媒体，未全量重测；[详细记录](Test-Reports/2026-10-29-SlowShutter-ModeMemory.md)。

# 2026-10-28 遗留失败修正与关联真机回归

12项定向通过，横屏人物效果仍待有效场景验收。共33个不同定向方法，最后结果32通过、1未通过；不代表重新全量通过。原78项与本轮过程中的失败/崩溃证据全部保留。详见[Test-Reports/2026-10-28-FailureResolution.md](Test-Reports/2026-10-28-FailureResolution.md)。

# 2026-10-28 原78项失败逐项复验

- **65通过、11断言仍失败、2崩溃，78个方法均执行。** 042初次180秒预算超时，给足420秒补测187.319秒通过；010两次未通过横屏姿态前置判断，未进入录制。原结果全部保留。
- 每个方法独立进程，源码与原断言未改（仅增加DEBUG显式只读相册依赖注入和两项自检），诊断媒体不写/删系统相册；所有78项确认隔离标记。正常App/Release不启用隔离。测试过程中源码哈希未变化。
- 优先事项：033/041慢门手动包围曝光真实崩溃；064的720p/1080p 30→24、60→50实际帧率；049的HEIF HDR48MP请求实际12.2MP。其余先核对新版契约、异步回调和现场前提。
- 前后人像有人入镜有效分割54/54、56/56，前置竖屏CenterStage6/6帧检出人脸，真实智拍1次自动取景及成片通过；横屏和微距目标分支未完成，复杂边缘画质不因此全面验收。
- 滤镜2040次压力及三预设各1+3次速度样本见报告；宿主内存和发布间隔均不是独立App内存/实际屏幕FPS，没有功耗温度结论。正常App自动重开在结束后因锁屏/连接超时未完成。
- [复验报告与逐项表](Test-Reports/2026-10-28-FailureRecheck.md)、[结构化原始结果](Test-Reports/2026-10-28-FailureRecheck-results.json)。旧全量记录不覆盖，独立通过不等于原顺序下问题已修复。

# 2026-10-28 真机全量测试

- 设备iPhone 17 Pro / iOS27.2（24B119），正常项目签名，有线单机串行；12:35:44–13:31:25，3340.31秒。
- **671项：579通过、78失败、14跳过，整体Failed**；另有5项明确排除。无失败重试，代码/测试/项目文件哈希未变，不写入或删除用户系统相册，不启动模拟器。
- 后段大量未就绪/无新帧失败可能有连锁关系，根因未定位；先记录，不将78项直接解释为独立缺陷。真实非注入会话错误1条另行保留。人物/自然夜景条件不足不算效果通过。
- 性能与稳定性：12次手动前后切镜新帧0.604–1.107秒；2040次滤镜编辑宿主内存峰值超过相对门限；7项XCTest性能方法有原始指标。快照耗时不当实际FPS，含测试资源的宿主内存不当独立App内存；未测独立功耗温度。测试结束后正常App启动成功，未因此宣称预览全面复验通过。
- [完整记录](Test-Reports/2026-10-28-FullDevice.md)、[独立失败清单](Test-Reports/2026-10-28-FullDevice-TODO.md)、[逐方法结果与指标](Test-Reports/2026-10-28-FullDevice-results.json)。本次独立于10月24日历史待办。

# 2026-10-28 视频顶部延时摘要

- 延时启用时顶部画面比例按钮第二行显示当前间隔和张数（如 `3s·300张`），字号 8；非延时模式隐藏。数值直接读取状态，预设取消/切 M/自定义后同步更新。
- 构建、安装、启动成功；已用真机截图核对布局，未在真实录制中逐项切换所有预设/自定义组合。

# 2026-10-28 延时拍摄间隔与张数

功能说明见 [Architecture](../Docs/Architecture.md) 与 README 当前智拍/视频段落。以下记录包含本轮最终行为。

- `TimeLapseSettingsTests` 3 项模拟器测试通过：7 个间隔和 9 个张数选项（含 ∞）、五预设推荐组合、调度器在第 3 帧达到上限并停止。
- 构建、安装、启动成功；未做真实延时录制到有限张数自动停止的端到端镜头回归，也未截图核对比例弹窗的两组 5 列布局。有限张数只按已接受帧计数，不按实际耗时估算。
- 比例弹窗新增内容只在 `timeLapseEnabled` 时显示；非延时模式隐藏。预设取消和 A/M 默认 1s/120 的真机用例本次被跳过（延时路由未就绪），未把跳过写成通过。

# 2026-10-28 慢门 A/M 行为

- `SlowShutterPresetTests.testMKeepsSlowModeButClearsAndHidesPreset` 在 iPhone 17 Pro 真机通过（0.837 秒）：从 M 开启慢门会切到 A；选中光轨后切 M，`slowShutterEnabled` 仍为 true，`selectedSlowShutterPreset` 变为 nil，mode 为 manual；再回 A 慢门仍开启、预设仍未选。
- 预设条显示条件改为 `slowShutterEnabled && mode == .auto`；M 挡仅保留慢门状态，不显示五个预设，参数用完整手动范围。
- 设备构建、安装、启动成功；未做实际 M 挡参数滑杆和预设条隐藏的截图/手势回归。

# 2026-10-29 真机全量测试（未完成）

- 第一轮全量：单测/物理用例混跑至 `LiveAudioSavePhysicalTests`，该用例超过 10 分钟无新日志，进程被终止。终止前记录 272 个通过、18 个失败、9 个跳过；结果包未完整，不能作为全量结论。失败含本轮门禁导致的 `CameraViewModelTests.testVideoModeReturnsToPhotoRatioAndRememberedManualSettings` 与 `CaptureKindModeLatencyPhysicalTests.testRapidCrossModeSwitchAndStopRecovery`。
- 修复门禁为“最新切换优先”后，两项定向真机回归均通过：快速跨模式切换 8.680 秒、照片→视频→照片实际拍照及视频开始/停止 3.724 秒；`CameraViewModelTests` 同项通过。
- 第二轮全量排除 `LiveAudioSavePhysicalTests`，跑至 `PhysicalCameraSwitchingTests` 时会话无法恢复，连续物理用例超时，手动终止。终止前记录 418 个通过、28 个失败、7 个跳过；失败集中在相机会话恢复、夜景、HDR/RAW、双拍、对焦导航等需要连续独占相机的用例，不能据此判定产品回归。
- 会话恢复测试单独运行：`CameraSessionRecoveryTests` 3 项通过（1.806/0.689/6.386 秒）、1 项跳过；紧接着在同一进程追加 `PhysicalCameraSwitchingTests`，2 项均通过（20.304/21.093 秒）。因此不能把全量卡死归因于单个恢复用例“毒化”会话，当前证据更符合长时间串行测试后的系统相机/测试宿主累积资源问题。
- 全量套件尚未完整跑完；不写“全量通过”。后续应按物理组拆分、每组重启测试宿主后再跑。

# 2026-11-02 子模块长按焦段同指转轮

- 夜景/人像/连拍 1×/2× 顶层命中层由 SwiftUI 长按改为 UIKit `UILongPressGestureRecognizer`，`allowableMovement` 设为极大值；打开轮盘后同一根手指的 `.changed` 位移继续调用 `dragZoomDial`，松手调用 `finishZoomDrag`。
- 首次修复仍无效的原因：命中层条件带 `!zoomDialVisible`，长按打开轮盘时整层被移出视图树，手势识别器随之销毁；现保持命中层常驻到子模块关闭/弹窗打开。
- 原 SwiftUI 长按在打开轮盘后不跟踪拖动，导致必须抬手再转；普通拍照走原生 `CameraFocalButton` 长按，故正常。
- 构建、安装、启动成功；未真机验证同一根手指长按后连续转动。

# 2026-11-02 变焦轮显示时打开子模块

- 变焦轮显示时，子模块按钮仍可点击；顶层增加子模块按钮位置的透明命中层，点击调用 `openShootingModes()`，该路径先 `endZoomDial()` 再打开预设弹窗。
- 同时扩大 `CameraZoomPanSurface` 右侧排除区，覆盖子模块按钮，避免变焦触摸层吞掉点击。
- 构建、安装、启动成功；未实际在轮盘显示时点击子模块验证弹窗和收起。

# 2026-11-02 滑动条统一 4 秒自动隐藏

- 变焦轮、顶部人像景深、虚拟光圈滑条统一为松手/开启后 4 秒无操作隐藏；操作重新计时，持续拖动不隐藏，关闭/退出取消旧任务。
- 构建、安装、启动成功；未真机逐项计时四秒及持续拖动边界。

# 2026-11-02 夜景噪点优化

- 用户样片显示夜景暗部高ISO颗粒明显。当前自动夜景策略把中等暗度曝光分配为约 ISO 1600 的短帧；改为同等曝光量优先延长快门（目标 ISO 约 640），并把自动夜景单帧快门上限收紧到 1/4 秒，避免手持长曝光模糊；更暗场景依靠更多帧（最多9帧）、配准和降噪，而不是继续拉长单帧。M 挡仍可用硬件允许的更长曝光。
- `NightPhotoMerger` 的暗部 `CINoiseReduction` 强度由 0.085 提高到最高 0.098，极低信号半尺度降噪由 0.06 提高到 0.095；亮部纹理策略未改。
- 构建成功；安装/启动与真机样片复拍待验证。尚未证明所有暗景都能降低噪点而不增加手抖模糊。

# 2026-11-02 变焦轮 4 秒自动隐藏

- 变焦轮打开即启动 4 秒计时，不再只限视频模式；拍照/视频/夜景/人像/连拍共用。
- 拖动持有期间不隐藏；松手后重新计 4 秒；关闭或退出取消旧任务。
- 构建、安装、启动成功；未真机计时四秒及持续拖动边界。

# 2026-11-02 夜景/人像/连拍焦段与变焦轮

- 真机 DEBUG 审计确认 0.5×/1×/2×/4×/8× 在夜景、人像、连拍下全部 `enabled=true`，能力表不是禁用来源；1×/2× 位于焦段条中央，被透明合成层截获点击。
- 变焦轮第二次拖动：拍照子模块中拖动后 `selectedLens` 可能落到能力表不支持的数码裁切档，`canAdjustCurrentLens` 会拦截下一次 `beginZoomDial`；现子模块内跳过 selectedLens 能力判断，允许继续拖动。
- 1×/2× 增加顶层命中覆盖，只覆盖这两个焦段，点击调用 `selectFocalLength`，长按打开变焦轮；其他焦段保留原按钮。变焦轮显示时覆盖层隐藏。
- 构建、安装、启动成功；未实际逐一点击 1×/2× 和连续两次拖动变焦轮验证。

# 2026-11-02 同步双拍变焦预览卡顿（待处理）

- 现象：同步双拍开启、后置主画面时，通过变焦轮/捏合连续变焦，预览明显卡顿。
- 当前实现：每个变焦事件调用 `setDualCaptureMainZoom`，逐次锁主镜头并直接设置 `videoZoomFactor`，同时递增 readings generation、刷新预览状态。双拍还有两路采集、前后合成和独立预览队列，设备锁竞争会放大掉帧。
- 尚未实现优化；建议顺序：30/60Hz 最新值节流；使用 `ramp(toVideoZoomFactor:withRate:)`；变焦中不刷新整条预览状态，稳定后再同步；变焦期间锁 AE/AWB；观察 `AVCaptureSession.systemPressure` 并在严重压力时提示。
- 验证待办：1080p30 双拍下从 1×→8×→1× 连续变焦，记录预览发布间隔、掉帧数、系统压力与主观跟手度；与普通单摄视频同操作对比。未完成前不写成已修复。

# 2026-11-02 同步双拍子模块与主画面控件

- 专项记录：[2026-11-02-DualCapture-Submode.md](Test-Reports/2026-11-02-DualCapture-Submode.md)
- 构建、安装、启动成功；三列子模块截图确认。真实双拍录制、双击交换主画面、后置 24/35mm、变焦轮/捏合画面与高亮均未验收；不写成已通过。

# 2026-11-02 同步双拍主画面控件

- `dualCaptureMainIsFront` 和主画面变焦范围发布到 UI；双拍时隐藏人物居中。
- 前置主画面：焦段条切换为前置超广角/标准切换（复用 `setDualCaptureFrontWide`）。
- 后置主画面：`displayedFocalPosition` 固定为后置，焦段条不再沿用进入双拍时的前置位置；长按焦段条可打开变焦轮，捏合/拖轮/焦段按钮都走双拍后置主画面数字变焦，不重建会话。
- 双拍前置主画面仍显示前置超广角切换；双拍开启时隐藏人物居中。焦段选中态改为按当前有效主画面计算，后置数字变焦不再固定选中 1×；前置/后置双拍均允许长按打开变焦轮，双拍主画面变焦走数字变焦。
- 构建、安装、启动成功；未实际开启双拍并双击交换主画面验证控件切换和变焦画面。

# 2026-11-02 录制中虚拟光圈实时写入

- 原因：`MovieRecorder.filterLook` 在开始录制时复制一次，之后预览 look 更新不会传给编码器，导致预览星芒变化但成片不变。
- 现将 `filterLook` 改为录制队列可更新，并在 `CameraEngine.updateLook` 中把当前 look 投递到录制队列；虚拟光圈滑杆变化会作用于后续编码帧。
- 构建、安装、启动成功；未实际录制并逐帧解码验证星芒变化；文件元数据仍记录录制开始时的虚拟光圈值。

# 2026-11-02 视频虚拟光圈移到子模块上方

- 视频开启虚拟光圈后，色彩空间按钮恢复原内容和颜色；色彩空间弹窗移除 P3 右侧滑杆。
- 子模块按钮上方新增无背景 `ƒ + 数值` 控制按钮，点击后向上展开竖向虚拟光圈滑杆和值；滑杆沿用 5 秒自动隐藏。按钮与子模块按钮的间距改为与子模块按钮/拍摄辅助按钮相同的 `upperButtonGap`。控制按钮最初挂在拍摄辅助按钮的 overlay 上，超出父按钮可点击范围导致点不到；移到 `fixedCameraControls` 根层仍被合成层遮挡，最终提升到 `CameraView` 顶层 ZStack，并在视觉按钮上叠加独立 56×56 透明点击层。
- 构建、安装、启动成功；未截图核对按钮与滑杆的层级、遮挡和点击状态。

# 2026-11-02 视频虚拟光圈移入色彩空间

- 视频开启虚拟光圈后，顶部色彩空间按钮第二行常驻显示虚拟光圈值，色彩空间标题和值整体用主题橙色。
- 色彩空间弹窗中在 P3 右侧增加虚拟光圈滑杆和当前值；滑杆仅虚拟光圈开启时显示。
- 移除了视频焦段条上方的旧虚拟光圈滑块。
- 构建、安装、启动成功；未截图核对 P3 右侧滑杆在 H.264 双项布局下的宽度/遮挡。

# 2026-11-02 前置隐藏虚拟光圈入口

- 子模块面板在前置模式下过滤“虚拟光圈”，照片/视频共用；后置仍显示。构建、安装成功；启动时设备锁屏，未截图核对前置四/五项布局。

# 2026-11-02 移除独立同步双拍按钮

- 固定控制栏中前置人物居中右侧的同步双拍独立按钮已移除；同步双拍只保留视频子模块入口。
- 构建、安装、启动成功；未截图核对移除后的固定控制栏布局。

# 2026-11-02 同步双拍/虚拟光圈子模块图标

- 子模块入口图标补齐：同步双拍显示 `rectangle.on.rectangle`，虚拟光圈显示 `camera.aperture`；两者开启时入口用强调色，无障碍状态同步。
- 构建、安装、启动成功；未截图核对开启后的图标切换。

# 2026-11-02 视频子模块三列与同步双拍

- 视频子模块恢复为三列；视频项为延时、慢动作、电影、同步双拍、虚拟光圈。同步双拍复用现有前后 MultiCam 合成，小窗为前置镜头；可从后置直接开启。
- 真机截图 [LumaSubmode3Col.png](../Preview/LumaSubmode3Col.png) 确认三列与五个入口显示；构建、安装、启动成功。未实际开启同步双拍录制验证小窗合成与帧同步。

# 2026-11-02 虚拟光圈焦段限制

- 照片虚拟光圈下 `displayedFocalLenses` 过滤掉超广角，只保留主摄/长焦；焦段组水平居中。变焦轮范围下限已夹到 1×，0.5× 刻度不显示。构建成功；安装/启动命令在后台执行，未做真机截图核对。

# 2026-11-02 视频防抖设置

- 拍摄设置新增视频防抖菜单（关闭/低延迟/标准/电影），默认低延迟；说明使用与其他设置相同的 info 按钮弹窗。设置持久化，关闭“保存拍摄设置”时恢复低延迟。
- 预览与录制连接使用同一模式；不支持时回退。构建、安装、启动成功；未做真机走动防抖/延迟对比，也未核对设置弹窗截图。

# 2026-10-30 夜景月亮标识移到顶部工具栏

- 夜景月亮标识从预览右上角移到顶部工具栏 Live 所在列；移除黑色圆形底和描边，触发/等待/不可用颜色、点击关闭夜景、无障碍标识和提示保持原逻辑。
- 构建、安装、启动成功；未在真实低照度下截图核对触发态。

# 2026-10-30 HEIF Pro 影调快捷按钮默认隐藏

- 顶部 Pro 影调按钮仅在 `photoFormat == .heifPro` 时显示，与影调/测光选择无关；非 HEIF Pro 时隐藏。格式弹窗里的 Pro 影调入口保持不变。
- 构建、安装、启动成功；未截图核对各影调状态下的顶部切换。

# 2026-10-30 视频隐藏虚拟光圈入口

- 视频子模块面板移除“虚拟光圈”选项，视频面板只保留延时、慢动作、电影；照片入口不变。
- 构建、安装、启动成功；未截图核对视频子模块布局。

# 2026-10-30 H.264 色彩空间弹窗宽度

- H.264 只有 SDR/P3 两个选项时，色彩空间弹窗曾按选项数量缩窄；现改为固定使用视频工具栏弹窗完整可用宽度，不再随选项数量变化。
- 色彩空间选项行显式占满宽度并左对齐，与分辨率/编码弹窗内容起点一致；iPhone 17 Pro 构建、安装、启动成功，未截图核对 H.264 弹窗视觉。

# 2026-10-30 滑杆五秒自动隐藏

- 顶部人像 ƒ 和虚拟光圈按钮的当前数值常驻显示，滑杆展开/收起/自动隐藏都不影响该数值。
- 人像景深/虚拟光圈滑杆展开后 5 秒无操作自动收起；展开、拖动开始/结束、数值变化都会取消并重新计时。
- 手动收起或模式关闭会取消计时任务；构建、安装、启动成功，未做 5 秒计时的真机秒表验收。

# 2026-10-30 微距互斥与滑杆玻璃

- 微距激活时不再禁用顶部人像 ƒ 与虚拟光圈按钮，允许展开和调节滑杆。
- 已撤销人像/虚拟光圈的自动微距抑制和强制退出主摄逻辑；两种模式均允许系统继续进入微距。
- 景深/虚拟光圈横向滑杆背景改用 `PreviewSurface` 液态玻璃，尺寸/位置不变。
- iPhone 17 Pro 构建、安装、启动成功；未在真实近景下验证自动微距锁定/恢复，也未点击核对玻璃质感。

# 2026-10-30 顶部景深/虚拟光圈点击无响应

- 原因：两个顶部按钮的 toggle 都有 `!camera.macroActive` 静默 guard；在近景/微距状态下点击直接 return，没有动画和反馈，看起来像点不到。
- 已移除该 guard：微距期间仍允许展开滑杆；景深预览分割仍由 `synchronizePortraitPreview` 暂停。构建、安装、启动成功；未在微距状态下做实际点击回溯。

# 2026-10-30 顶部景深/虚拟光圈触控区域

- 人像 ƒ 与虚拟光圈 `camera.aperture` 顶部按钮的触控区域与顶部工具栏其他四个按钮等宽、同高（32pt），不额外外扩。
- iPhone 17 Pro 构建、安装、启动成功；未做触控命中自动化或实际点击采样。

# 2026-10-30 人像景深移到顶部工具栏

- 人像模式顶部 Live 按钮改为景深按钮，点按后显示横向弱—强滑杆；原 A/M 上方 ƒ 按钮与竖向景深滑块已移除，微距标识保留。
- 模拟器 `VideoMacroIndicatorTests` 2 项通过（13.427 秒）：旧 `portraitDepth`/`portraitDepthPanel` 不再出现，微距激活时仅保留 `macro`，退出微距也不恢复旧控件。
- 顶部景深入口改用与旧景深按钮一致的 `ƒ` 字形；iPhone 17 Pro 构建、安装、启动成功；截图 [PortraitDepthFIcon.png](../Preview/PortraitDepthFIcon.png) 确认顶部 ƒ 入口和微距位置旧控件已移除。未实际点开顶部横向滑杆截图，需后续补触控验收。

# 2026-10-30 四个相机控件移除背景

- 移除 A/M 切换、拍摄辅助、子模块入口、焦段条的背景，保留原尺寸、位置、字体/图标、颜色状态和点击热区；其他按钮、参数条、底部拍摄控件不变。
- iPhone 17 Pro 构建、安装、强制重启成功；截图 [NoControlBackgrounds.png](../Preview/NoControlBackgrounds.png) 确认四个控件无背景，焦段条选中项也不再叠加内部玻璃。竖屏视频模式已核对；照片模式共用同一组件，未另截图。
- 微距标识（`camera.macro`）同步移除背景，保留原尺寸、位置和可访问性；构建、安装、启动成功。未进入真实微距距离截图核对。

# 2026-10-29 实体控制回退与焦段双层背景

- 撤销 M 挡实体 Camera Control 的变焦项，M 挡恢复六个手动参数；A 挡实体变焦保留，M 挡屏幕焦段/捏合变焦不变。
- `CameraControlMenuTests` 模拟器 2 项通过，M 挡菜单标识恢复 `M.S/M.ISO/M.MF/M.EV/M.WB/M.TINT`；未重跑物理菜单，不宣称 M 挡七项仍通过。
- 焦段控件已回退到修改前实现：外层 `PreviewSurface` 液态玻璃 + 选中项内部 `UIGlassEffect`。真机截图确认双层背景恢复存在；未继续修复。构建、安装、启动成功。

# 2026-10-29 照片/视频切换后拍摄

- 新增 `CaptureKindSwitchCapturePhysicalTests`，iPhone 17 Pro 真机通过（4.239 秒）：照片→视频→照片后实际拍照成功；再切视频后开始/停止录像成功。测试等待 `captureKindSwitching` 解除，不把旧路由下的失败点击算作通过。
- 改动仅增加切换门禁：切换期间快门/录像入口禁用，`takePhoto`/`toggleVideoRecording` 同门禁；最长 2 秒后强制解除，避免页面永久卡住。未做连续 100 次随机切换、后台打断或所有格式组合回归。

# 2026-10-29 快门倒计时

- 删除慢门刻度环；`SlowShutterCountdownTests` 2 项模拟器通过：有限时长剩余秒数（含 <10 秒一位小数）、∞ 已拍时钟。
- 延时剩余张数/∞ 已拍时长移至预览底部；快门白圈外新增主体色圆弧，按实际接受帧数每帧转一圈。帧数来自 `MovieRecorder.onTimeLapseFrameAccepted`，不是按时间估算。有限张数达到后仍由现有 scheduler 停止。
- `slowShutterCaptureHidesControls` 已在构建中接入：所有慢门序列隐藏 A/M、辅助拍摄、子模块入口、预设条、镜头条；顶栏、滤镜、翻转、相册、网格/直方图和快门保留；停止/合成时恢复。构建、安装、启动成功；未在真实慢门序列中截图核对隐藏/恢复时机。

# 2026-10-28 慢门预设时长范围

- `SlowShutterDurationTests.testPresetDurationRangesAndDefaults` 模拟器通过：光轨可选 10/15/30s、流水 5/10/15s、动态模糊 1/3s、摇拍 0.5/1s、星轨 60s/∞；默认分别为 15/10/3/1/60s。
- 预设时长选择会过滤顶部弹窗，并在选中预设时写入顶部显示；A 挡取消预设时恢复 1s。`slowShutterDuration` 已加入拍摄状态持久化；恢复时按预设范围校正，避免“预设选中但顶部显示 1s/其他预设值”。设备构建、安装、启动成功。未做五预设逐项真机点按和长时结束回归。
- 未选预设时按顶部时长启动通用平均融合慢门序列；慢门时长已随拍摄状态持久化并按预设范围校正。该通用路径和长时结束尚未做真实端到端拍摄回归。

# 2026-10-28 慢门预设开关

- `SlowShutterPresetTests.testSelectingSamePresetAgainTurnsItOff` 在 iPhone 17 Pro 真机通过（0.691 秒）：开启慢门、选中光轨，再次点击同一预设后 `selectedSlowShutterPreset` 变为 nil，`slowShutterEnabled` 仍为 true。
- 设备构建、安装、启动成功；未重跑五预设逐项开关或 M 挡滑杆手势矩阵。
- `SlowShutterPresetTests.testMShutterSliderUsesSelectedPresetRange` 在 iPhone 17 Pro 真机通过（0.707 秒）：选中摇拍追焦并切 M 后，硬件快门范围 `-13.9658...0.0`（log2 秒），预设范围 `-13.9658...-3.9069`，`parameterRange` 与预设范围完全一致；证明快门滑杆只在预设启用时收紧，未选预设才回到硬件范围。

# 2026-10-28 慢门预设 M 挡范围

- `SlowShutterPresetTests.testManualISORangeUsesPresetSuggestionAndHardwareIntersection` 通过：流水 50–200、星轨 100–800、摇拍与较窄硬件范围求交为 50–400。
- 范围收紧门槛显式改为“慢门已开启且已选预设”；未选预设时 ISO/快门仍返回当前硬件范围。序列曝光规划继续使用硬件 ISO，不因 UI 范围收窄而拒绝暗光合成。
- 设备构建、安装、启动成功；未做 M 挡滑杆逐档真机手势和五个预设完整切换回归，不把单测当作完整手感受验收。

# 2026-10-28 视频 ProRes 规格双行

- 视频顶部格式按钮在 ProRes 下显示两行：`ProRes` 与 `422 HQ` 等规格；其他编码保持单行，按钮高度仍为 32，其他顶部项位置不变。
- iPhone 17 Pro 真机运行截图核对 [ProRes 双行](../Preview/ProRes-SecondLine.png)；构建、安装、启动成功。未执行 ProRes 实际录制或规格切换矩阵，未把 UI 截图当成编码能力验收。

# 2026-10-28 慢门拍摄时长

- 新增 `SlowShutterDurationTests` 3 项模拟器测试通过：10 档名称/默认 1s、1s 对预设帧数与最短帧数的覆盖、5 列两行分布。
- 真机截图核对弹窗玻璃样式、默认选中 1s、10 个档位 5 列两行；随后按用户要求移除弹窗底部“∞ 表示持续拍摄…”描述，构建、安装、启动成功。
- 代码路径：有限时长到达后 `advanceSlowShutterSequence` 自动结束；序列中再次按快门 `finishSlowShutterSequenceEarly`；∞ 使用 36,000 帧上限，等待再次按快门。未做实际长时/∞ 拍摄结束回归，不能把截图和单测当作时长边界已验收。

# 2026-10-28 慢门与 Live 互斥

- `LivePhotoOptionsTests.testSlowShutterDisablesLiveAndCannotBeReenabled` 在 iPhone 17 Pro 真机通过（0.552 秒）：真实相机就绪后开启慢门，确认 `livePhotoAvailable`、`canToggleLivePhoto`、`capturesLivePhoto` 均为 false；再次调用 `toggleLivePhoto()` 也不会打开。模拟器因无实时相机路由跳过该用例（0.127 秒）。
- 改动仅影响慢门/Live 互斥：慢门开启清空 Live 并同步相机请求，退出慢门不自动恢复 Live；其他模式原有 HDR、夜景、人像、连拍互斥未改。未重跑全量 Live/慢门回归。

# 2026-10-27 高动态逆光与DNG相册验证补充

iPhone17 Pro/iOS27.2，3项相关显影/曲线方法通过，另1项用户明确授权的真实相册保存与二次编辑回路通过。固定逆光样本HEIF/预览线性中位数0.13892/0.15547，约0.162挡差异；288万像素GPU实际渲染6次5.63–7.48ms，RAW小图12次19.23–26.01ms，不是显示帧率。DNG入库后逐字节一致，RAW编辑覆盖再打开、详情底片标记通过；测试资产已清理。此前未验收中的“保存/覆盖后重开”现仅在本机此次配置完成，另存/iCloud/其他设备未验收。[完整报告](Test-Reports/2026-10-27-AdaptiveDynamic-Backlit.md)。

# 2026-10-28 人像脸侧绿叶虚化修正

11项组件检查和最终前置人物回归通过。54次人物分割全部有效、180次调节无空预览；两次出片0.948/1.066秒，任务及退出恢复正常。本轮附件目视绿叶连续虚化、主体头顶和外镜框保留。两张不是同帧精确对比，未扩展为任意背景或多人景深保证；首轮外镜框变软的过程记录保留。[最终报告](Test-Reports/2026-10-28-Portrait-BackgroundExclusion.md)。

# 2026-10-28 人像头顶/镜框补充

最终10项组件方法通过；首轮前置因无有效人物分割失败，未伪装为效果通过。用户人物入镜后，已编译包前置方法通过：67次分割全部有效，180次调节无空预览，0/最大强度出片0.858/1.142秒，任务及退出恢复正常。样片目视主体头顶和镜框保留，但不是同帧精确对比；远处人物小脸仍可被保留清晰，距离景深区分未解决。已有20次渲染中位3.26ms不含新静态分割，不能作为新流程总耗时。未保存Photos。[完整记录](Test-Reports/2026-10-28-Portrait-HeadRepair.md)。

# 2026-10-28 HEIF Pro 深暗部专项

iPhone17 Pro/iOS27.2：两项像素/性能检查和五组RAW拍摄/编辑方法有最终通过记录。新增小暗区合成图保持中位/明亮墙面，深暗红通道0.00200→0.01461；不当作真实样片增益。288万像素6次分析渲染约5.36–6.65ms，非预览FPS；五组出片约1.10–1.89秒。保留初版透明边缘导致p2=0的失败、测试相机生命周期等待失败及修复；用户DNG匹配跳过，实际同场景画质待验收。第五组没有验证48MP且实际为12MP，未计高像素通过。无Photos写入。[完整记录](Test-Reports/2026-10-28-HEIFPro-DeepShadow.md)。

# 2026-10-28 人像脸部误虚化保护

iPhone17 Pro/iOS27.2，10项相关方法通过，包含确定性蒙版漏脸修补、背景虚化、原EXIF和前置调节/拍摄恢复。Mac用户样片检出可靠脸框，完整渲染确认脸颊保护值255；无法重建已丢失细节。20次既有渲染中位3.50ms/p95 4.54ms不含新增检测，不当作新成片总耗时或FPS；实际前置180次调节无空预览，但60次分割只有12次接受，未将其写成轮廓效果验收。相同姿态新拍对照和复杂场景仍待测，未写入Photos。[完整记录](Test-Reports/2026-10-28-Portrait-FaceProtection.md)。

# 2026-10-28 夜景曝光与融合专项

本次仅测试夜景相关路径，未启动模拟器、未写入Photos。iPhone17 Pro正常签名：14项策略/融合检查、新增12次自适应曲线性能方法、显式M挡3组真实曝光及A挡/取消方法有通过记录。最终A挡三次均真实融合（3/3/6帧）、来源及最终EXIF一致、拍后设备身份恢复，出片2.623/3.082/4.611秒；运动停止追加和取消再拍通过。曲线320×240、12次中位93.00ms/p95 102.62ms，不是预览FPS/全尺寸速度。保留初版虚拟路线未采纳计划、诊断覆盖、代次断言和单帧回退记录。真实暗光与系统相机画质对照待用户具备条件，不将注入曝光检查当作画质改善证明。[完整报告](Test-Reports/2026-10-28-Night-Exposure.md)。

# 2026-10-27 智拍补充代码检查：未关闭项

- 复核现有真机日志 `/private/tmp/LumaCamera-Smart48-Check3.log`（iPhone17Pro/iOS27.2）：48MP组合方法失败，另三项通过。JPG智拍后6000×8000/1.393秒，HEIF HDR建议后3024×4032/3.033秒，关闭夜景/HDR恢复HEIF为6000×8000/6.056秒。各路径各一张临时照片，未写入系统相册；这些耗时为单次出片观察，不代表性能分布。HDR实际降至约12MP而UI仍为48MP，待查原因。
- 固定纹理锚点移动及空白拒绝、候选批次冻结两项合成测试通过（0.300/0.174秒）；不代表真实移动跟踪精度。实际主体漂移、复杂场景推荐质量和新增跟踪开销仍待验收。本次为代码与已有记录复核，未重新启动全量测试。

# 2026-10-27 智拍多候选自动取景

替代早期单一中心点/点击应用倍率流程。iPhone17Pro/iOS27.2：21项定向组、真实多候选闭环1项、最终白点白圈样式1项、主体焦点投影1项，共24个不同方法有通过记录；未全量测试。实际桌面场景看到2个候选，目标UUID连续保持，对齐后完成一次评估/对焦并输出3000×4000临时JPG，保留1×；不能把它记成真实模型自动选择了放大。确定推荐的硬件自动变焦、30次重复对齐、弹窗取消和M挡保护另行验证。评分3轮/12候选20.74–57.96ms，实时分析12次中位29.1ms/p95 40.2ms，非FPS。3目标静止合成图12次跟踪最大归一化漂移0，非真实场景准确率；16组真实组件渲染检查点/圈窄缝通过。早期测试宿主停机、画面未对齐跳过及宿主安全区采样失败均保留，未伪装通过。[完整报告](Test-Reports/2026-10-27-SmartAutoComposition.md)。

# 2026-10-27 A 挡 48MP 六格式真机

- iPhone 17 Pro/iOS27.2，正常签名、真实相机，测试照片只走内存回调，不写系统相册。A 挡选择 48MP 后临时切后置主摄物理 1×；A 挡自动曝光保持。
- `A48ResolutionPhysicalTests` 1 项通过，13.213 秒：HEIF、JPG、TIFF、HEIF Pro 输出 6000×8000，RAW 输出 8064×6048，RAW+JPG 同时返回 JPG 和 DNG，均超过 40MP；前置未开放 48MP。
- 切换 48MP 的内部预热捕获会丢弃；预热期间快门显示加载圈。专项未做全量回归、长时热稳定、48MP 前置/其他设备或 48MP 下切换镜头的完整回归；不把测试文件写入当作系统相册保存已验收。

# 2026-10-27 格式弹窗 HDR/高动态说明分栏

- HDR 与高动态开关仍在同一行；两段说明分别位于各自开关下方，左右等宽列、自适应多行显示。HDR 文案按 HEIF/HEIF Pro/不可用格式切换，高动态文案固定。
- `AdaptiveDynamicPhysicalTests.testFormatPanelLayoutAndRepeatedSwitching` 真机通过：6 种格式×4 方向布局、连续 60 次开关，耗时 8.008 秒；面板高度未超 360 点。
- 运行截图 [Format-HDR-Descriptions.png](../Preview/Format-HDR-Descriptions.png) 已目视检查；未新增其他功能改动。

# 2026-10-27 前置视频按钮透明背景

- 视频前置的“人物居中”和“同步双拍”按钮移除圆形 `PreviewSurface` 玻璃底，保留图标、强调色、圆形热区、按钮直径和整组布局；其他按钮与后置/照片模式未改。
- iPhone 17 Pro 构建、安装、启动成功；未取得运行截图，未重跑前置视频专项；现有几何记录和点击逻辑保持不变。

# 2026-10-27 高动态与RAW重新显影

iPhone17 Pro/iOS27.2（24B119），定向12个不同方法有通过记录，未全量测试。后置A/M、前置、SDR/HDR临时捕获，M挡1/120秒实际EXIF、8/10-bit和PQ标记、底片原字节及显影配方读取通过；独立主摄M挡RAW请求8064×6048，输出48,000,000像素，重新显影尺寸一致。SDR同配方64×64对照RMSE为0；最终HDR含曝光、色温及电影影调约0.0014。24组格式/方向布局、60次开关、RAW编辑HDR预览、30次快速调节及退出取消通过。未向Photos写入，保存/覆盖/另存后重开完整回路待验收；长时功耗、复杂场景画质和其他设备未测。[指标、范围及过程问题](Test-Reports/2026-10-27-AdaptiveDynamic.md)。

# 2026-10-27 前置视频人物居中

iPhone17 Pro/iOS27.2（24B119），4项新硬件方法及1项既有前置方向方法有通过记录。原生active、12种色彩/分辨率/帧率组合、20组按钮布局、手动宽窄和双拍互斥、快速点击与后台恢复通过；HEVC、带滤镜的P3 H.264及ProRes HQ短片完整解码。最终一次三轮开启约0.734/0.318/0.280秒；横竖持实际人物抽帧方向正确。保留早期方向偏转、标称/实际尺寸引起的ROI黑边、一次9.22秒等待及测试准备错误，不将系统日志全部视为无错误。未做长时功耗/多人追踪定量验收。[完整记录](Test-Reports/2026-10-27-FrontVideo-CenterStage.md)。

# 2026-10-27 光圈滑块背景专项

两项不同真机方法最终通过，启用状态的普通/高亮轨道一致且截图仅保留一层外框；270次原生控件valueChanged及三种结束事件、180次视频参数更新、28+20组布局与实际成片/录制恢复通过。保留首次异步look读取过早的失败及近景禁用截图不作为高亮验收的说明；UIControl模拟不等于真实手指触摸。[完整记录](Test-Reports/2026-10-27-ApertureSlider-Background.md)。

# 2026-10-27 视频虚拟光圈真机验证

iPhone17 Pro/iOS27.2（24B119），7个不同相关方法有通过记录。SDR/P3编码像素包含星芒；四组30帧实际短片完整解码，接收/写入60/60、38/38、37/37、37/37。视频20组布局、180次持续调节、停止恢复及子模块互斥通过，照片28组布局与实际文件回归通过。保留几何位置缺失、连接/签名阻断及过渡截图不作为最终状态的记录，未全量、高帧率或长时验收。[完整报告](Test-Reports/2026-10-27-VideoVirtualAperture.md)。

# 2026-10-27 八角星芒核对

一项相关真机测试通过，默认/满档八方向均有能量，最大/最小比1.019/1.026；附件已目视检查。仅合成光点，不代表用户真实场景验收，生产算法未改变。[详情](Test-Reports/2026-10-27-EightRay-Check.md)。

# 2026-10-26 点光源筛选专项

3项真机方法通过。灯板/横竖长亮边新增能量为0，圆面与斜亮边残余很小，点光源保持星芒；三轮270次更新持续出帧，最大间隔约48–52ms。原强度、微小灯点、28组布局和实际文件回归通过。空间孤立性是近似分类，复杂灯群与长时热稳未验收。[完整记录](Test-Reports/2026-10-26-VirtualAperture-PointOnly.md)。

# 2026-10-26 虚拟光圈对焦检查

专项方法最终20.851秒通过，6组锁焦/360次光圈更新、12次点按及3轮A挡开关，硬件焦点模式与坐标未被改写。8×部分样本未在0.8秒观察窗收敛，未作清晰度或最终合焦保证；首轮枚举数量断言失败保留。[详细记录](Test-Reports/2026-10-26-VirtualAperture-Focus.md)。

# 2026-10-26 虚拟光圈上限与数值复位

新ƒ/16对应上一版ƒ/6.0，点按数值恢复ƒ/5.6。两项真机方法通过，3轮共270次调节持续发布24/25/25张预览，最大间隔66–82ms；28组布局、实际主摄/长焦文件通过。模型复位验证不等于真实触感验收，真实夜景及长时热稳未测。[完整指标](Test-Reports/2026-10-26-VirtualAperture-Reduced.md)。

# 2026-10-26 星芒增强与连续预览

最终2项专项真机方法通过。三轮各90次更新分别持续发布46张预览，最大间隔约47.6–50.1ms；这是应用发布时刻，不是屏幕FPS。28组布局、主摄/长焦文件与元数据通过；保留首轮重建布局后0帧失败，真实夜景和长时热稳未验收。[完整记录](Test-Reports/2026-10-26-VirtualAperture-Responsive.md)。

# 2026-10-26 虚拟光圈专项真机验证

最终3项相关方法通过，100次连续模型更新、28组布局及主摄/长焦临时成片通过；真实EXIF保留ƒ/1.78、ƒ/2.799，虚拟ƒ/8、ƒ/16独立记录。微小光源与均匀区域合成检查、对焦辅助回归通过。模型提交耗时不当FPS，夜景观感/长时功耗未验收。[完整指标、失败及限制](Test-Reports/2026-10-26-VirtualAperture.md)。

# 2026-10-26 拍照8倍导航对焦辅助

最终5个不同相关真机方法通过（47.452秒含等待）：实际M挡JPEG/HEIF EXIF为ISO200、1/120秒，Live HEIF+MOV及DNG资源通过，7.9/8倍阈值、三轮进出、后台/照片视频往返与快速开关通过；28组画幅/方向布局和252个拖动目标、共享手势及普通录像回归通过。导航首图0.627秒n=1，95帧缩图生成平均约1.269ms不当FPS。保留输出迁移、会话事务、视频资源预算及比例修正等失败记录。视频已按用户要求移出范围，人像/夜景/慢门/HDR实时预览不启用；未全量回归、长时热稳/多机型及精确导航配准未验收。[完整报告](Test-Reports/2026-10-26-PhotoFocusNavigation.md)。

# 2026-10-26 双拍冷启动默认关闭

一项专项真机方法通过（4.773秒整项墙钟）：旧开启存档不启动双拍，保存标志始终false，手动开启/小窗偏好/同进程前后台往返正常；仅临时模型与独立存储，无诊断媒体。保留镜头枚举及完整设置恢复等待不足的两轮测试失败记录。未全量回归，未把用例耗时当启动性能或FPS。[验证记录](Test-Reports/2026-10-26-DualCapture-DefaultOff.md)。

# 验证记录

> 本文件按日期倒序记录。顶部为最新双拍与慢门记录；10-23 的 42–47 秒慢门测量、固定 10×1 秒和速度优先失败均为历史阶段，当前以 10-24/10-25 的静态单帧包围与自适应多帧记录为准。

## 当前结论索引（2026-10-26）

- 双拍：正式入口仍为 HEVC SDR 1080p30、16:9；25 种组合是能力验证，不代表已在正式选择器开放。小窗拖动、双击交换、横竖画幅和位置保存已有真机记录；HDR/Log/RAW、长时热稳定性和其他机型未验收。
- 慢门：光轨/流水/动态模糊/星轨已从固定帧数改为按测光自适应曝光与帧数，摇拍保留单帧；M 挡标准分辨率手动单帧包围样本约光轨 12 秒、流水 10 秒、动态模糊 2.9 秒、完整星轨 153 秒。较早的 42–47 秒记录和速度优先失败仅代表旧路径。
- 夜景：当前按暗度/稳定性使用 3/6/9 帧自适应包围，两帧有效保留双帧，失败回退单帧；详情按实际融合帧数记录。
- 顶部工具栏：与预览重叠层已改为纯透明；测试预期已同步，但真机透明效果仍待解锁后目视复核。

## 2026-10-26 双拍贴边切画幅

4个相关真机方法通过：五比例/九位置/100次共4500组几何往返，真实左右贴边12次切换保持既有安全边距；20组布局、辅助显示避让和五段实际短片完整解码回归通过。未全量回归，CPU几何耗时不当FPS。对焦辅助仅确认旧枚举有后置主摄+长焦设备组合，实际功能与规格未验证。[完整记录](Test-Reports/2026-10-26-DualCapture-DockedEdges.md)。

## 2026-10-26 小窗样式和辅助显示避让

3个相关真机方法有通过记录：20组五画幅/四方向布局、250个拖动目标、录像中150次顶部移动、五段完整解码，直方图和容量/声音及计时持续避让，开关恢复通过。最终截图已目视检查；未全量测试，未将模型计算耗时当FPS。保留只读环境属性赋值导致的测试编译失败及修正通过记录。[完整报告](Test-Reports/2026-10-26-DualCapture-HUDAvoidance.md)。

## 2026-10-26 小窗右下角按钮与控件避让

3个相关真机方法通过：五画幅×四控件方向20组，250个拖动目标及4410个纯几何目标，五段实际短片解码。初次截图发现子模块offset未计入障碍，已按共享布局常量修正，并新增视觉框断言后复测通过。未把CPU投影耗时当FPS，未全量回归，真实手指体验与长时热稳定性未验收。[专项报告](Test-Reports/2026-10-26-DualCapture-InsetAvoidance.md)。

## 2026-10-26 双拍横幅小窗

5个不同相关真机方法有通过记录：五主比例×标准/广角恢复，横幅16:9及原主比例实际文件完整解码；20组四方向控件布局和30个合成像素位置、后台/冷启动恢复通过。10次操作提交至下一预览帧约46–79ms，中位约69ms（轮询指标，不是FPS或完整动画耗时）。未全量回归，长时热/功耗及真实手指手感尚未验收。[完整指标及限制](Test-Reports/2026-10-26-DualCapture-Landscape.md)。

## 2026-10-26 双拍规格开放与可移动小窗

25种有效组合实际录制并完整解码659帧；五种比例、前置标准/广角、录像中500次位置提交、冷启动位置恢复及取消/后台路径通过。三轮进入中位0.573秒、退出中位0.424秒；该指标为新帧就绪等待。15次合成像素位置及UIKit手势配置/分派检查通过，累计6个不同相关方法有通过记录。真实手指手感、长时间功耗和其他设备未验收，保留测试辅助代码与视图未挂载的失败记录。系统MDB/Fig日志仍存在，未据此认定零系统错误。[完整报告](Test-Reports/2026-10-26-DualCapture-ExpandedControls.md)。以下旧基础规格限制仅代表当时阶段。

## 2026-10-26 双拍兼容性、前置按钮居中与录像边缘布局

- iPhone17Pro/iOS27.0.1正常签名。公开设备集合与格式枚举后，51个候选短片中42个录制/解码完成；4组双路50/60被压力预算拒绝，5组没有匹配的MultiCam格式。后置720p/1080p/4K各24/25/30、后置720p/1080p50/60配前置30、五种比例、官方前置超广角小窗、P3/H.264/六种常规ProRes及4K30 ProRes HQ有实际通过记录。
- 上述是能力验证，不等于已经开放到正式按钮；当前基础入口仍锁定HEVC SDR 1080p30/16:9。HDR/Log/RAW和Open Gate未完成合成端到端验证，不把单路能力枚举当成双拍支持。
- 前置按钮整组居中：照片/视频×A/M×四个方向共16组；五种视频比例×四个方向共20组录像边缘布局，直方图、计时、容量不重叠并停止恢复。真实录像约0.744秒核对顶部5点位置；布局用例约27.31秒含等待，不是FPS。没有镜像/模拟器，不保存诊断媒体到系统相册。
- 本轮9个不同相关方法有通过记录，未全量回归。每个候选只有约1.3秒短片，不代表长时间热稳定性或独立功耗；其他设备与高温/外接存储仍有限制。[专项报告及逐项JSON](Test-Reports/2026-10-26-DualCompatibility-and-RecordingLayout.md)。

## 2026-10-26 前后同步双拍基础版

- 入口可见性后续修复：EntryFinal两项通过。前置视频尚未开启双拍时，A/M各一份真机截图均能看到独立玻璃按钮；均为40×40点、位置(229,574)，在266×44点的焦段父区域内，未与A/M及辅助按钮重叠。窗口命中检查仅确认可交互视图，不等同于人工触摸验收；10次模型动作连点、退出和原录制/交换回归通过。含相机切换的可见性用例约4.60秒，不是FPS。未使用镜像、未保存诊断媒体到系统相册。累计不同相关方法有通过记录增至12项。

- iPhone17Pro/iOS27.0.1正常签名，累计11个不同相关方法有通过记录；ControlsFinal七项、Orientation2一项、PortraitCompare一项、ReleaseChecks三项（有重叠），未做全量测试，不写系统相册，不启动模拟器。
- HEVC SDR 1080p30、16:9竖向1080×1920画中画文件，带声音；默认后置主画面、前置小窗，点按交换。92帧/约3.067秒样本全部写入并解码，最大配对PTS差约18.81ms；4.18ms合成中位耗时不是屏幕FPS。三轮新帧就绪进入中位0.687秒、退出0.711秒。
- 准备中退出/重复点击、录制中交换、A/M实参、黑白滤镜实际编码、后台恢复、冷启动设置、普通视频/前置六种照片画幅通过。保留无合成帧、前置方向、照片格式恢复、保存焦段ID及未固定姿态主体对照的原始失败记录；固定姿态复测未放宽断言。
- 其他格式/色彩/帧率不开放；当前未增加横向双拍输出。iOS18–26、其他机型、长时热稳定性/独立功耗与系统高温/电话中断尚未现场验收。[专项报告](Test-Reports/2026-10-26-DualCapture.md)。

## 2026-10-26 前置宽高比联动超广角与还原

- iPhone17Pro/iOS27.0.1正常签名，WarmFrames五项39.466秒、FinalChecks三项19.031秒通过，累计7个不同相关方法；未写系统相册、未启动模拟器。
- 两轮A/M各18张实际文件EXIF：普通约31→19/20→31mm，自定义1.25倍约38→19/20→38mm，原本广角保持原状态；六种非方形比例、连点/取消、视频迟到回调隔离通过。24个匹配帧发布延迟约94–167毫秒，中位数约114毫秒，不是屏幕FPS。
- 保留提前倍率实验造成焦距偏差、测试起点/取整和编译失败记录；最终先画幅后倍率、暖帧门控后通过。临时还原快照不跨冷启动保存，未做全部姿态、功耗或长期热稳定性验收。[专项报告](Test-Reports/2026-10-26-FrontWideAspect-Return.md)。

## 2026-10-26 普通M挡长曝光恢复自动：定向优化通过

- iPhone17Pro/iOS27.0.1正常签名，保留真实曝光预览。同场景3对交替新旧路径，新自动读数中位数2.644秒→0.899秒（约减少66%）；不是AE最终收敛或屏幕帧率保证。四物理路线保留输入/倍率/预览尺寸，约1.36–1.46秒恢复新帧和自动读数。
- 13个不同相关方法有通过记录；实际JPG/HEIF EXIF、WB/对焦锁、20轮三组参数/5轮反向、取消返回、流畅预览/慢门/夜景/视频回归通过，不写系统相册、不启动模拟器。修复测试偏好隔离后此前失败用例通过，原始失败保留。
- 原生对照观察长帧过渡，但不宣称已知ISP内部队列根因。半秒及以上空闲M挡才走同会话恢复，在途拍摄/人像/HDR原生预览/视频等保持既有路径；极暗最终收敛、独立功耗内存及长期热稳定性未验证。[专项报告](Test-Reports/2026-10-26-SlowestShutterAuto-Recovery.md)。

## 2026-10-25 普通M挡最低快门恢复自动：历史调查，见上方后续优化

- 稳定1秒真实曝光后，3个关闭流畅预览样本的新自动读数约2.15–2.86秒；开启时约33–43毫秒。六次最终恢复通过不代表延迟已优化。用户明确要求保留真实曝光预览，不自动启用流畅预览。
- HDR延后/隔离、配置事务、短曝光交接、连接刷新及iOS27组合解锁等试验未取得足够收益，均已撤回；仅保留诊断测试和阶段追踪。[调查记录](Test-Reports/2026-10-25-SlowestShutterAuto-Investigation.md)。

## 2026-10-25 M挡夜景

- iPhone17Pro/iOS27.0.1正常签名，43个不同相关方法有通过记录；手动6/9/3帧两轮6次、逐张源EXIF与最终文件曝光核对，自动M/A往返、取消恢复及A挡回归通过。不写系统相册、不启动模拟器。
- ISO400/1/15秒6帧约2.70–2.76秒，ISO800/1/8秒9帧约4.82–4.88秒，ISO100/1秒3帧约4.24–4.28秒，每组2次；为提交至结果回调总耗时，不是显示帧率。受控矩阵注入帧数/稳定性，另有真实暗光自然触发并融合6帧通过。
- 保留设备不可用、取消测试等待条件错误和硬件标识断言错误的原始失败记录；取消语义未改成回调成功。未验证全部镜头、独立功耗/热稳定性及运动夜景视觉效果。[专项报告](Test-Reports/2026-10-25-NightManual.md)。

## 2026-10-25 M挡参数恢复自动响应

- iPhone17Pro/iOS27.0.1正常签名，Final四项47.789秒通过。10个曝光/WB/色调/对焦恢复样本；无辅助半秒曝光硬件恢复约1.42秒→0.84–0.85秒，多数其他新读数约25–48毫秒，一次WB约315毫秒。数据均为真实模式/数值观测，不等于AE/AWB/AF最终收敛。
- 快速20轮三组参数切换、退出返回、普通/慢门流畅预览、拍摄中关闭和视频M挡曝光恢复通过；真实JPG/HEIF文件参数仍有效，未写系统相册，会话运行错误审计通过。快传窗口结束后1.2秒只发布3次读数，未永久提高采样频率。
- 预览时间仅验证时间戳继续更新的上界，非首个自动像素显示延迟；未量化独立App功耗/内存或全部镜头/强暗光收敛。保留初次测试构建失败和局部Fix阶段未加快长曝光恢复的记录。[专项报告](Test-Reports/2026-10-25-ManualAuto-Recovery.md)。

## 2026-10-25 四种慢门预设自适应多帧

- iPhone17Pro/iOS27.0.1正常签名，Final八项225.537秒通过、SelectionGuard单项23.614秒通过；Algorithm2十项0.695秒通过，共16个不同相关方法有通过记录，未全量重跑。9张完整3000×4000结果，源ISO/快门、实际文件EXIF和任务清空核对；未写系统相册。
- A挡光轨31帧/11.502秒、动态模糊7帧/3.347秒、摇拍4帧/2.333秒；M挡ISO200/1/125秒三种分别32/8/4帧、10.668/2.744/1.495秒。星轨完整343帧，源帧跨度120.141秒，成片121.484秒；流水A/M22/26帧回归。总耗时包含首帧等待/编码，不等于采样跨度或累计传感器曝光。
- 中央纹理对齐夹具4帧保留清晰主体，无关纹理回退单帧，真实A/M静止纹理摇拍均融合4帧。稳定性含提前结束/取消/10轮快速开关/采集中误点预设保护，真实会话错误审计通过。修复了最末合并耗时被计入采样终止的问题，未放宽断言。
- 星轨测试宿主峰值约502MiB，摇拍约540–609MiB；这是XCTest宿主，不能称独立App内存。室内静止场景不等于星空或运动摇拍美术效果验收，未测独立功耗/长时热稳定性。原生离散采样有空档，中央平移不能校正旋转、透视及景深变化。[专项报告](Test-Reports/2026-10-25-AdaptiveSlowPresets.md)。

## 2026-10-25 流畅预览成片交接

- iPhone17Pro/iOS27.0.1，普通M挡JPG/HEIF 12MP、ISO100、1/2和1/125秒，辅助关/开八文件EXIF一致；修前短曝光平均sRGB码值差约0.203/0.204，修后约0.015/0.022。四对像素检查通过，长曝光仍有约0.027–0.056残差；0.06是测试容差，不是苹果保证。
- Handoff单项23.540秒，八次照片回调约0.234–2.658秒；Recovery三项37.332秒，覆盖20次开关、拍摄中关闭、慢门辅助、视频及生命周期恢复。最终4个相关方法通过，运行错误审计通过，未写系统相册。3×1秒窗口预览发布关闭15次/秒、开启30次/秒，不能当作显示帧率。
- 静止场景像素对照不等于拖影标定；前后轮构图变化，统计仅用于各轮内部的开关比较，不推导跨轮统一改善比例。所有镜头/高像素/Live/RAW/HEIF Pro/HDR和闪光组合未逐项验收。保留最初仅EXIF通过和像素失败记录；未做独立App功耗热稳定性。[专项报告](Test-Reports/2026-10-25-SmoothPreview-Handoff.md)。

## 2026-10-25 子模块入口图标

- iPhone17Pro/iOS27.0.1，正常签名，`ShootingModeButtonTests`两项9.526秒通过，未拍摄照片/视频。真实启闭慢门、夜景、人像、连拍、延时、慢动作、电影，检查入口图标、选中状态、关闭弹窗后保留、再次关闭恢复及照片/视频往返；智拍占位点击不改变入口。会话运行错误审计通过。
- 7次开启至模型/相机就绪观测约9–519毫秒，含子模块原有的规格适配/路线配置，不代表单纯图标绘制速度。9个默认/选中符号各两轮、18次真实SwiftUI宿主渲染，覆盖0°/90°/-90°/180°；外框始终36×36点且坐标一致，系统符号均存在。
- 快速900次符号赋值后回退默认正常；同一主线程内可能合并渲染，不视为900次屏幕呈现。18次截图绘制耗时约38–78毫秒，属于测试截图开销，不是显示帧率。减弱动态效果沿用现有系统感知的短淡入淡出，未另外切换系统偏好验收；本次未做功耗/热稳定性或全量测试。
- 结果：`/private/tmp/LumaCamera-SubmodeIcon-20261025.xcresult`，日志同前缀`.log`。采用SwiftUI官方[opacity过渡](https://developer.apple.com/documentation/swiftui/transition/opacity)，动画仅作用于固定图标区域。

## 2026-10-25 流水曝光自适应

- 正常光线A挡ISO80/1/4秒16帧10.069秒完成，较暗A挡ISO64/1/2秒12帧9.907秒完成；M挡保留ISO200/1/125秒24帧8.988秒完成。三张3000×4000，52张源帧曝光/ISO及最终EXIF核对，覆盖JPEG/HEIF。
- 最终13个不同相关方法有通过记录，包含稳定亮度像素检查、规划亮暗边界、动态模糊、流水结束/取消再拍，以及光轨在途帧结束/退出返回/10次快速选择。NormalFinal整组10项通过，Dark中的流水/动态模糊两项通过，旧取消断言更新后CancelFinal单项通过；中间失败原样保留。
- iPhone17Pro/iOS27.0.1，未写系统相册；宿主内存峰值约471–510MiB，不是独立App内存。未验证真实流水视觉连续感、强日照/极暗、全部镜头或长时功耗热稳定性。原生静态采样有帧间空档，不等同ND连续曝光。[专项报告](Test-Reports/2026-10-25-AdaptiveWater.md)。

## 2026-10-25 电影实际景深效果

- iPhone17Pro/iOS27.0.1用户准备人物场景，1个定向方法9.957秒通过；四段1080p30 SDR HEVC，默认f/2.8、f/2、f/16、再次f/2，各段约0.775–0.803秒。四次原生元数据都检测到face/humanBody等对象。
- 实际预览与编码帧目视确认：f/2下人物相对清晰、前后景变模糊，f/16恢复更多纹理，再次f/2复现。人物/手机有移动，不做百分比锐度结论；默认片段运动模糊不能作为默认画质验收。新增仅DEBUG诊断钩子和测试，未修改正式电影管线。
- 未验证多主体自动焦点过渡、所有边缘/场景、4K美术效果或长时性能；9.957秒不是显示帧率。诊断媒体未写系统相册，图像附件仅本地保留。[实际效果记录](Test-Reports/2026-10-25-Cinematic-ActualEffect.md)。

## 2026-10-25 剩余五项视频问题

- **2026-10-25 剩余五项定向通过**：按序完成视频规格矩阵、Open Gate、录像白平衡、慢动作切镜和电影路线。修复HDR白平衡锁定阻塞/增益固定与慢动作重定时写入反压；13个相关方法有通过记录，42段临时视频完整解码。原33个失败方法现均有后续定向通过记录，未重新全量测试，7个跳过项及外接RAW等限制仍保留。
- iPhone17Pro/iOS27.0.1正常签名：最终五组共13个不同相关方法、112.541秒（不含构建/中间诊断）。18组HEVC SDR文件1134帧；Open Gate五文件170帧；六组白平衡开关12文件373帧；取消恢复另12帧；慢动作三文件939帧；电影三规格70帧，共2698帧完整解码，未写系统相册。
- 白平衡4K60HDR原等待回调无法启动，现普通录像固定有效当前增益且不等待增益回调，RAW仍保持专用元数据同步；12次启动最大约0.306秒，增益稳定、停止恢复原模式。
- 慢动作原149收到/104写入；仅重定时路径关闭实时提示后，120帧75/74、240短片148/145、240三秒片723/720，播放均30帧。24次切镜新帧36–344毫秒；电影两轮新帧约0.820/0.871秒，实际4K24/4K30/1080p30完整解码。不是显示扫描帧率，也未做独立App功耗/内存或分钟级热稳定性测试。
- 仍有启动1–3帧丢弃；慢动作提示调整是本机实测选择，不宣称为苹果对所有重定时输入的保证。保留中间失败/无效试验及平台/SwiftUI日志；无携带error的会话运行错误通知不等于底层零警告。[专项报告](Test-Reports/2026-10-25-RemainingVideoFive-Resolution.md)。

## 2026-10-24 高帧率规格与预览节奏

- **高帧率规格与预览节奏定向通过**：两轮后置三种分辨率120帧及前置1080p30/4K60共10段文件、739帧完整解码，实际PTS与名义帧率匹配；120帧预览图像发布约116.5–119.9次/秒，快速升降帧率及停机恢复通过。4项相关检查通过，未改正式采集或UI；累计28个原失败方法通过，余5项未处理/未复测。
- iPhone17Pro / iOS27.0.1，普通签名：基线2项30.731秒，增强4项56.455秒。核对设备最小/最大帧周期、实际文件尺寸、完整解码与递增PTS；后置720p/1080p/4K实测均120帧，前置30/60帧。诊断短片未写系统相册。
- 12个预览发布测量窗口：A挡24–60帧约23.9–59.3次/秒，M挡三分辨率120帧共6窗口约116.5–119.9次/秒；30次快速请求后约29.878次/秒并停机恢复。此为主线程图像发布，非屏幕实际刷新帧率；无独立App功耗/内存结论。
- 本次SDR HEVC短片不替代HDR/Log/ProRes高帧率、所有镜头、慢动作240或长时热稳定性；A/M不同路由按实际能力开放。无携带error对象的会话运行错误通知，保留Fig/MDB及onChange日志，不声明底层零警告。原历史根因尚未确认；026/028/030/031等未顺带关闭。[专项记录](Test-Reports/2026-10-24-HighRatePreview-Resolution.md)。

## 2026-10-24 录像生命周期与启动取消

- **录像退出/恢复与取消收尾定向通过**：三轮A/M/A退出/恢复、300次模式请求合并、计时冻结及视频完整解码通过；另修复白平衡锁定等待时立即取消漏回调和busy残留，并隔离迟到回调、重复停止。修复后4个不同相关方法通过，未写系统相册；累计26个原失败方法通过，其余7项未处理/未复测。
- iPhone17Pro / iOS27.0.1普通签名：最终2方法20.211秒，资源检查3方法2.774秒（含重测的取消方法）；原032方法17.476秒。每100请求重配1次；三轮正常片段均16帧、约0.533秒，完整解码/PTS递增；停止650毫秒后计时增量0。
- 白平衡等待取消修复前8秒无回调且busy残留；修复后最终两轮各3次取消约21–24毫秒完成、白平衡恢复，各接一段可解码12帧的新片，延迟无重复回调。短片收尾3样本约34–46毫秒、恢复新帧约257–305毫秒；非长片或显示FPS结论。无携带error的会话运行错误通知，保留平台及SwiftUI快速调用警告。
- 生命周期测试使用与后台/离开页面共用的入口，未实际按Home或锁屏；资源单测不代表外接RAW实盘。031白平衡规格矩阵仍待办。详见[专项记录](Test-Reports/2026-10-24-VideoLifecycle-Resolution.md)。

## 2026-10-24 照片/视频往返恢复

- **照片/视频往返恢复定向通过**：Live/HDR/M 两轮共6段视频、6张真实照片及10次快速反向切换通过。增强检查曾发现 M 挡读数正确但成片曝光偏差，现普通手动照片也等待官方曝光完成回调；修复后5项相关检查通过。累计25个原失败方法通过，其余8项未处理/未复测。
- iPhone 17 Pro / iOS27.0.1，正常签名，5项86.421秒。实际Live配对、HDR 10-bit PQ、M挡EXIF 0.5秒/ISO200、对焦/白平衡锁定与任务清空通过；预览辅助开关/拍摄中关闭和单帧慢门同步回归。切回照片及断言完成6样本约0.453–1.040秒，含配置/新帧/参数等待，不是纯预览延迟。保留间歇失败证据及SwiftUI/平台警告，不声明底层零警告或历史系统根因确证。未写系统相册。详见[专项报告](Test-Reports/2026-10-24-LiveHDRManualRestore-Resolution.md)。

## 2026-10-24 视频编码、色彩与滤镜四项

- **视频编码/色彩四项定向通过**：22组编码完整解码及真实PTS帧率、A/M五种色彩10轮拍照恢复、Log/Log2仅预览/烧录像素对照和SDR/P3滤镜文件检查通过。共9相关方法、39段临时短片，另10次临时照片恢复；本轮未改生产录制实现，补强测试隔离与断言。累计24个原失败方法通过，其余9项未处理/未复测。
- iPhone17Pro / iOS27.0.1正常签名：增强6项93.859秒、固定像素3项0.156秒，0失败/跳过；原四方法基线已通过，70.839秒。22组文件fourCC/比例/名义与解码PTS帧率匹配，实际30/60/120；10种A/M色彩组合标签及8/10位正确，切回JPEG全部成功。
- Log与Log2各两段诊断LUT：仅预览时预览已变洋红、文件洋红采样0%；烧录时文件100%，都保留原Log标记/10位。SDR/P3黑白视频各34帧、约30帧/秒、编码平均通道差约0.158/0.145，完整解码；3项固定彩色输入测试补查黑白/美食效果与Log缓冲格式。
- 不含外接RAW、长时4K120、逐帧DolbyVision元数据、所有LUT美术效果或独立App功耗/内存验收。正常组无带error对象的运行错误通知，但保留MDB_MAP_FULL和一次Fig断言日志，不声称底层零警告；未写系统相册，未关闭原032取消用例。[专项报告](Test-Reports/2026-10-24-VideoCodecColor-Resolution.md)含矩阵、原始指标和边界。

## 2026-10-24 静音快门与夜景多批次

- **静音快门夜景遗漏修复**：静音设置移到统一原生提交入口，夜景首批和追加批次沿用快门快照。真机10次普通/RAW/HEIF Pro/TIFF及JPEG、HEIF Live捕获、真实6帧夜景、中途改偏好与退出返回通过，共3个相关方法有通过记录；验证系统请求，未做声学测量。累计20个原失败方法通过，其余13项未处理/未复测。
- iPhone17Pro / iOS27.0.1正常签名：修复后3项通过，18.933秒；增强后的最终夜景再通过，4.273秒（不重复计不同方法）。原普通组合独立基线已通过，新增夜景先复现两批enabled=false，现每个原生提交按系统支持设置，最终两批均true。夜景中途关闭偏好不改当前组，返回后下一请求为false。
- 10次普通/Live方法15.412秒，各次任务归零，两个Live实际有pairedVideo资源；静图回调约0.35–1.11秒，Live约3.34–3.60秒；受控6帧夜景回调约2.83秒。非曝光时间/显示FPS/功耗指标，未录音测声；未写系统相册。详见[专项记录](Test-Reports/2026-10-24-SilentShutter-Resolution.md)的官方依据、失败证据和限制。

## 2026-10-24 HDR HEIF Pro四种影调

- **HDR HEIF Pro影调定向通过**：四种影调正反两轮真实拍摄8张，文件均为10-bit PQ HEIF，EXIF有效、任务清空；固定HDR夹具确认影调改变像素且保留扩展高光。6项相关方法真机通过，本轮未改生产影调算法，原超时未复现。累计19个原失败方法有通过记录，其余14项未处理/未复测。
- iPhone17Pro / iOS27.0.1，正常签名：6项通过、0失败、0跳过，10.338秒。实际8张均3000×4000、10-bit、Rec. ITU-R BT.2100 PQ；成片预览16位，实际EXIF ISO/快门/焦距有效且方向1。每张上下文/token/顺序缓冲归零，40次快速影调切换和退出/返回新帧检查通过。
- 8次请求至成片回调排序上中位0.879秒，最大2.582秒（首张），非曝光时间/显示FPS。固定HDR夹具编码后解码保留亮度大于1的高光、影调像素方向检查通过；不把不同时间真实照片直接当作同帧比较。未写系统相册，未做实际高反差场景显示亮度/功耗测试。[报告](Test-Reports/2026-10-24-ProToneHDR-Resolution.md)含全部范围和限制。

## 2026-10-24 人像前后置与同帧三项

- **人像三项定向通过**：真实人物场景下前后置各180次景深更新、0%/100%拍摄及后置同帧对照正常；补强拍后任务清空、退出后新帧和文件EXIF保留断言。本轮未改生产人像算法，3项硬件及8项渲染/状态方法有通过记录。累计18个原失败方法通过，其余15项未处理/未复测。
- iPhone17Pro / iOS27.0.1正常签名：前置11.884秒、后置11.034秒、同帧2.391秒，最终真实人物用例全部通过。前后置各180次强度更新，预览无清空，接受63/57个人物蒙版；每次仅创建1个分割请求；发布间隔P95约61.70/50.88ms（非屏幕FPS）。原片/结果目视保留人物并虚化背景，同帧实际文件ISO、曝光及焦距一致、方向1。
- 8项渲染/状态回归通过，20次900×1200合成图实际渲染中位3.71ms、P95约5.64ms，非硬件帧率。中间一次环境变为微距/无人物，acceptedMasks=0使人物用例失败；用户重新准备后验证通过，未把空场景算作效果验收。[报告](Test-Reports/2026-10-24-PortraitThree-Resolution.md)保留全部结果及限制。未写入系统相册，未改UI/算法；不能由当前单人正常证明全部复杂轮廓/运动场景无缺陷。

## 2026-10-24 预览辅助三项及视频隔离

- **预览辅助三项定向通过**：补查 JPEG/HEIF 文件 EXIF、快速开关、拍摄中关闭及生命周期恢复；另修复照片辅助偏好开启后误覆盖视频 M 挡实际曝光的问题，偏好保留但仅照片生效。真机5项相关方法通过，成片保留请求的ISO400、1/15秒，视频实际按ISO400、1/125秒工作。累计15个原失败方法通过，其余18项未处理/未复测。
- iPhone 17 Pro / iOS27.0.1，正常签名：最终5项通过、0失败、0跳过，38.665秒。修改前原三项已独立通过；补测复现视频请求ISO400、1/125秒却进入自动曝光，现由照片限定条件修复。JPEG两张、HEIF一张实际编码资源EXIF均ISO400、1/15秒；拍摄中关闭后不重新启用。视频录制中实际ISO399.43124、0.007997秒，返回照片与退出重进恢复正常。
- 每组3×1秒图像发布：设置辅助关闭15–16次/秒、开启25次/秒；慢门自动辅助24–25次/秒。是应用图像发布，非屏幕FPS/功耗指标。6次慢门往返、20次辅助快速开关、任务计数归零通过；A挡1/15触发为固定输入验证，不是自然暗光验收。未写系统相册；结果包和未覆盖边界见[专项报告](Test-Reports/2026-10-24-PreviewAssist-Resolution.md)。

## 2026-10-24 M→A 预览尺寸与前置 1:1

- **预览尺寸与前置方形冻结**：原 006 的失败来自前后切镜时误把合法横幅当竖幅；已修正新帧/实际构图检查。七画幅补测另定位并修复前置横幅切 1:1 后新帧被误丢弃的问题，传感器方向与裁切方向现独立记录。真机 8 项通过，含后置七画幅、前置 28 次 M→A 画幅检查及反复构图回归。累计 12 个原失败方法通过，其余 21 项未处理/未复测。
- iPhone 17 Pro / iOS 27.0.1，正常签名：8 项通过、0 失败、0 跳过，53.641 秒。原切镜回归 20.791 秒、新七画幅矩阵 20.652 秒；后置 7 次请求至匹配新预览/读数中位 0.984 秒、最大 1.104 秒（含队列排空、20ms 轮询，不是显示 FPS）。前置竖/横四轮×七画幅共 28 次 M→A，包含横幅输入切方形，不再停留旧横幅。既有 A/JPG、M/HEIF 动态构图和四项方向处理回归通过。未出现会话运行错误，未保存系统相册。
- [报告](Test-Reports/2026-10-24-ModePreviewSize-Resolution.md)含真实问题、测试前提修正、中间失败与最终结果；当前传感器方向独立于最终裁切，旧帧过滤/旋转/界面布局保留。未人工固定手机姿态，未据尺寸验收宣称实际人物朝向已目视核对。

## 2026-10-24 冷启动恢复手动参数定向处理

- 原用例单独及按设置测试顺序均未复现历史 -11819；确认旧测试没有等待主队列提交的退出生命周期，且抛错可能跳过新模型停机。已修正测试等待和异常收尾，未改生产参数恢复或界面。
- iPhone 17 Pro / iOS 27.0.1 正常签名：设置与硬件 8 项（17.037 秒）、错误恢复 2 项（8.363 秒），共 10 项通过、0 失败、0 跳过。正常操作无真实运行错误；注入组错误独立统计。六次常规新模型启动、三次快速请求后启动、三段临时视频及退出检查通过，实际 ISO/快门与曝光、白平衡、对焦模式一致。
- 照片三次恢复参数就绪中位 1.554 秒，视频三次 0.723 秒；三组快速请求后 0.705–0.724 秒。是同进程新模型启动到实际参数匹配，含 20ms 轮询，不是进程冷启动/FPS/功耗。历史系统服务重置内部根因未确认，未写系统相册。结果包、原始指标和限制见[专项记录](Test-Reports/2026-10-24-ColdRestore-Resolution.md)。原 001 定向通过，累计 11 项原失败方法有通过记录，其余 22 项未处理/未复测。

## 2026-10-24 人像原生超时与拍摄任务清空

- 原全量请求 209 曝光已结束，但未见处理结果/最终回调；应用仅在最终回调释放上下文，恢复又等待上下文清空，形成永久占用和后段 pending=4。已增加原生请求截止、一次性 token 收尾、有序交付解堵及旧照片输出替换。正常回调仍按 Apple 生命周期处理；超时预算是应用策略，标准处理格式人像 12s、其他处理格式 20s、RAW/Live 45s，夜景逐原生批次检查，批次间处理不计入原生等待。
- 设备 iPhone 17 Pro / iOS 27.0.1（24A446），正常签名；四组共 9 个不同方法通过、0 失败、0 跳过：真实远景人像/ProRAW/M挡及后续视频 3 项，实际微距优先与返回 1 项，最终漏回调恢复/退出、Live、夜景 4 项，四请求占满后恢复 1 项。结果包及原始方法耗时见[专项报告](Test-Reports/2026-10-24-Portrait-Timeout-Recovery.md)和[结构化结果](Test-Reports/2026-10-24-Portrait-Timeout-Recovery-results.json)。
- 注入在真实硬件最终回调已发生后丢弃应用收尾，不故意让相机服务卡死。6s 测试预算在约 6.159s 释放计数并交付后序成功照片；旧 token 重放两次不重复交付，后续后备人像与录像完成。原生蒙版后备标志确为 true。退出期间超时不重启，返回可再拍照；四个上下文/token/名额均达到 4 后被一次清空，输出重建并拍出新照片，总计约 11.993s（10s 测试预算，含重建及新捕获）。
- 真实近距三次拍摄 p50 0.599s、最大 1.077s；真实远景 HEIF 12MP 约 1.244s，48MP 请求、HEIF 6000×8000 和 ProRAW 8064×6048 检查通过。该场景无人物蒙版，不作为抠图画质验收。夜景实际 3/6/9/6/9 帧和 JPEG/HEIF Live 正常路径通过；未扩大自然暗光验证结论。
- 系统仍可能没有返回某张原生照片，此时提示重拍，不伪造成功；发生过原生人像超时的设备在本进程后续走已有 Vision 人物分割后备，不宣称等同系统景深或任意物体抠图。精确的旧主摄近焦挂起本轮未自然复现；无带错误对象的会话运行错误，既有缓存日志仍在。
- 未保存诊断媒体到系统相册、未使用镜像或模拟器。未测屏幕 FPS、纯 App 内存或电池功耗；不把原生完成后的普通后期处理强行纳入短截止。原全量 489/33/7 统计保留，007/009/024 有定向通过记录，累计十项、其余 23 项未处理/未复测。

## 2026-10-24 相册按钮缩略图旋转

- 相机快门栏中照片、视频缩略图及占位图标接入既有控件旋转，固定外层圆形背景/玻璃与加载标记，源 UIImage 和文件方向不变。普通动画沿用 0.22 秒局部旋转，系统减弱动态效果继续依既有环境值处理。
- iPhone 17 Pro / iOS 27.0.1 正常签名；9 项通过、0 失败、0 跳过，合计 10.770 秒。两种媒体替身共 32 次方向检查，包含 0°、±90°、180°反复往返，逐像素确认色标旋转并检查按钮外框固定、源图不变、缩略图请求数不增加。快门栏设置覆盖七种照片画幅值；8 项既有缩略图刷新状态回归通过。
- 32 次窗口快照绘制耗时见[专项记录](Test-Reports/2026-10-24-AlbumThumbnail-Rotation.md)，不能换算为实际 FPS、动画延迟或 App 功耗。未强制更改只读的系统减弱动态环境，未分别验收系统开/关两种状态；未使用镜像/模拟器、未拍摄或写真实相册。结果包 `/private/tmp/LumaCamera-AlbumRotation-20261024-Verified.xcresult`；中间测试前提修正亦保留在专项记录。

## 2026-10-24 前置构图、成片方向三项处理

- 原 002/003/004 的准备前提已修正：前置真正就绪后关闭横幅并等待实际应用，方向用例在前置就绪后读取姿态；仍检查宽窄逻辑、录像禁止自动构图、M 挡曝光/镜像、取消恢复和真实文件元数据。
- 仅修正前提时 8 项虽通过，目视附件发现横拿照片内容仍侧转约 90°，因此没有将其作为产品验收。已修复 CameraEngine 新前置照片固定 0° 的处理：快门按官方 RotationCoordinator 设置 photoOutput 方向，四分之一圈时同步裁切轴；预览、控件、视频、后置和旧前置路径不变。解码后归一化 EXIF/TIFF，实际焦距保留。
- iPhone 17 Pro / iOS 27.0.1（24A446），正常签名：修复后横持 9 项通过、0 失败、0 跳过，22.689 秒；竖持/Live 4 项通过、0 失败、0 跳过，27.204 秒。共 13 次方法执行、10 个不同方法，原三项两种姿态均通过。横持实际角度 90°，JPG/HEIF 标准画幅成片 4000×3000；竖持角度 0°，成片 3000×4000；宽窄取景原片/最终 EXIF 31/20mm 一致。目视附件确认内容朝上，不只验宽高。
- A/JPG、M/HEIF 各 8 次画幅切换，中位约 44.4/65.9ms，范围 21.4–88.7ms，是模型调用到匹配预览发布，含轮询；各 12 次快速请求后持续出帧，最大发布间隔 101.8/120.8ms。不是实际屏幕 FPS、功耗或单张快门指标。M 挡重复点按、实际拍摄和取消恢复方法 2.767 秒；文件四组合方法 6.002 秒。
- 两组修复后未见带错误对象的会话运行错误，既有 MDB_MAP_FULL 日志仍存在。未写系统相册，未用镜像或模拟器。另一横持方向、倒置姿态未真机目视；Live 只验证了竖持配对，横持动态片段尚未逐帧核对；未扩大到前置 HDR/人像和其他设备。
- 结果包：`/private/tmp/LumaCamera-FrontThree-20261024-Rotation.xcresult`、`/private/tmp/LumaCamera-FrontThree-20261024-PortraitLive.xcresult`。中间阶段、原始指标、官方依据及限制见[专项报告](Test-Reports/2026-10-24-FrontThree-Resolution.md)。原全量统计不变，剩余 26 个失败方法未处理、未复测。

## 2026-10-24 慢门切镜预设与变焦轮重开定向核对

- 对应 FULL-20261024-019、033：建立独立照片基线并检查实际慢门启用、最终路由新帧与设备倍率；仅改测试，未改产品逻辑或按钮样式。原全量日志中，019 切镜前预设已为 nil，033 的 6× 请求未生效；不能将其直接视为切镜/重开的独立回退。
- iPhone 17 Pro / iOS 27.0.1（24A446），正常项目签名；增强用例 2 项通过、0 失败、0 跳过，合计 14.912 秒。A/M 挡光轨、流水在全部五个后置焦段间往返，共 24 次，最终预设保持；关闭/重新进入按既有规则清空预设。调用到新路由预览发布约 0.066–1.022 秒，含 20ms 轮询；不是实际屏幕显示延迟，也未进行优化前后对比。
- A/M 挡各先确认实际 6×，再各重开三次；倍率、锚点及物理输入一致。实际拖动后各重开一次仍保持新倍率。6 次队列刷新与硬件回读约 0.011–0.030 秒；不是弹窗动画时间或 FPS。两方法分别用时 12.791 / 2.121 秒。
- 第一轮独立基线的两个用例通过后，追加上述重复操作及硬件读数检查；中间一次启动请求因额度致自动审批未完成而未执行，用户继续后正常提交。最终结果包 `/private/tmp/LumaCamera-PresetZoom-20261024-Continue.xcresult`；日志 `/private/tmp/LumaCamera-PresetZoom-20261024-Continue.log`。
- 运行错误审计通过，未见带错误对象的会话运行错误；未拍摄、未写系统相册、未启动模拟器、未使用镜像。仅测相关状态与硬件回读，未测电池功耗、纯 App 内存或完整剩余失败项；原全量统计不变，其他 29 个失败方法未处理、未复测。[专项报告及官方参考](Test-Reports/2026-10-24-PresetZoom-Resolution.md)。

## 2026-10-24 画幅量化与慢门布局两项定向处理

- 对应 FULL-20261024-005、018：仅修正测试断言与基线，未修改生产代码、裁切或界面。iPhone 17 Pro / iOS 27.0.1 正常签名，2 项通过、0 失败、0 跳过，测试方法合计 3.713 秒；结果包 `/private/tmp/LumaCamera-EasyTwo-20261024-1.xcresult`。
- 画幅覆盖 4 个奇偶源尺寸 × 2 个方向 × 8 个比例，共 64 组；检查最多半像素居中、整数边界、源图内裁切、比例和真实渲染尺寸。用时 0.041 秒，是小图组合检查总耗时，不是完整照片处理延迟。
- 慢门测试重置同一共享引擎，确认实际启用并等待异步路由完成，仍严格检查五槽对齐与边界。真机焦段/预设条背景同为 212 点；20 次快速开关含等待耗时 0.466 秒；全部 7 比例及关闭/恢复含等待耗时 2.337 秒；方法总计 3.672 秒。未出现带错误对象的相机会话错误；未测实际屏幕 FPS、正式 App 独立内存或功耗。
- 未拍照或操作系统相册，未使用镜像或模拟器。原始全量 33 个失败方法保留历史记录，其他 31 项本轮未处理。说明、官方参考和限制见[专项报告](Test-Reports/2026-10-24-EasyTwo-Resolution.md)。

## 2026-10-24 真机全量测试：仅记录问题

- iPhone 17 Pro / iOS 27.0.1（24A446），项目正常签名，单设备串行；2026-10-24 12:35:40–13:11:39，约 2159.2 秒。**529 项：489 通过、33 失败、7 跳过；整体 Failed。**未修改产品/测试代码，未人工重跑失败项，未启动或操作模拟器、未使用镜像，未向系统相册写入或删除诊断媒体。
- 失败逐项保存为 [今日独立待办](Test-Reports/2026-10-24-FullDevice-TODO.md) 和 [结构化结果](Test-Reports/2026-10-24-FullDevice-results.json)，不覆盖此前报告。包含冷启动恢复、前置构图、画幅居中、人像超时、预览辅助、慢动作切镜、慢门布局及视频编码/色彩/规格等断言。后段观察到 `capturing=true pending=4`，多个失败可能互相影响；本轮不定位或确认根因。
- 会话带错误对象日志共 6 条，其中 5 条为恢复用例主动注入；非注入 -11819 出现在冷启动恢复用例。另有 1766 条 `MDB_MAP_FULL` 缓存日志，影响未确认。未见进程 kill/重启或 `Publishing changes from within view updates` 日志，不等于所有稳定性问题已经排除。
- 性能样本：A/M 8 次新预览发布约 1.00–1.29 秒；受控夜景 3/6/9/6/9 帧约 1.242/2.845/3.878/2.814/4.106 秒；光轨优化路径 3 次 13.900/12.261/12.174 秒；完整 120 帧星轨用例 155.585 秒。包含取消、快速切换及返回路径，失败按清单保留。指标为方法内采集/处理或发布耗时，不是实际屏幕 FPS；内存数值包含 XCTest 宿主，不视作正式 App 内存或功耗。
- 自然夜景未触发而跳过；系统相册真实写入/删除、外接 RAW 硬盘端到端及指定手持姿态明确排除；复杂人物边缘主观画质未验收。具体 7 项跳过原因和 8 个排除选择器见报告。
- 原始结果包：`/private/tmp/LumaCamera-FullDevice-20261024-Run1.xcresult`；日志：`/private/tmp/LumaCamera-FullDevice-20261024-Run1.log`。测试后普通 App 构建成功，重新安装并启动 `com.shurrikann.LumaCamera`；这是恢复日常运行版本，不计为失败项复测通过。

## 2026-10-21 启动闪退递归观察器修复

- iPhone 17 Pro / iOS 27.0.1 上直接启动应用复现 `SIGSEGV`。设备崩溃报告显示调用链从 `CameraViewModel.restoreCaptureState(_:)` 进入 `portraitBlurStrength` 的 `didSet`，观察器无条件给该属性再次赋值，形成无限递归并在 Swift 元数据检查期间崩溃。
- 新增纯归一化函数，将有限值限制到 0–1、非有限值回退到 0.5；属性观察器只在数值确实需要归一化时再赋值一次，并立即返回。有效的持久化值不再二次触发赋值。增加越界、无穷与 NaN 的定向断言。
- iPhone 17 Pro / iOS 27.0.1，`PortraitDepthControlTests` 3 项通过、0 失败、0 跳过；包含强度映射、非法值归一化、保存 JPEG 的强度差异和关闭滑块后的蒙版失效。随后安装修复版并连续 3 次强制结束后冷启动，三次均在约 1.2 秒后确认应用进程仍存活。该指标只确认启动进程存活，不代表首帧显示时间或其他相机功能全面回归。没有拍摄或写入系统相册。
- 初次复现报告：iPhone 17 Pro，`LumaCamera-2026-10-21-152831.ips`；修复后真机测试结果包：`/tmp/LumaCameraPortraitDeviceDerived/Logs/Test/Test-LumaCamera-2026.10.21_15-33-57-+0800.xcresult`。

## 2026-10-21 慢门预设与固定焦段按钮背景

- 慢门模式的五个预设按钮分别增加克制的圆形玻璃背景，选中状态仍由原有橙色文字与字重区分；按钮尺寸、文字和位置没有改变。固定焦段条增加覆盖五个按钮的共享背景，当前焦段继续保留单独圆形背景，其他焦段只显示共享底、不增加各自的背景。设置项说明仍只通过标题旁的说明按钮查看，设置列表内不重复显示说明段落。
- 固定焦段 Liquid Glass 定向真机 XCTest `testFocalPresetSelectionGlassStabilityAndDrawCost` 在 iPhone 17 Pro / iOS 27.0.1 通过，1 项、0 失败、0 跳过。五按钮夹具反复改变选中项 60 次，按钮始终可用且仅选中项有独立玻璃背景；最后截图目视确认整组共享底加选中圆形底。XCTest 用时 1.659 秒；5 组、每组 6 张 `drawHierarchy` 的耗时为 114.75、60.80、65.03、59.36、59.86 ms，平均 71.96 ms/6 张。该指标只代表视图更新与层级快照绘制时间，不是屏幕帧率或触控延迟。
- 慢门预设范围、名称排版、五档槽位宽度、A 挡自动曝光约束及重复选预设/开关清理的相机独立测试已通过。首轮相机视图用例失败来自测试结构：它创建了第二个 CameraEngine，没有复用 App 已运行的相机会话；ready 要等到新预览帧且最多可能经过多轮恢复，5 秒等待过短。用例在 ready 断言失败后仍继续执行。另一个状态断言先开启慢门再切换 20 次，偶数次后预期仍是开启，原断言却要求关闭。
- 修正后的用例复用 `AppDependencies.runningAppCameraModel` 唯一真实相机会话，等待相机就绪及新预览帧后才检查；ready 超时会立即结束用例。完整慢门定向测试组在 iPhone 17 Pro / iOS 27.0.1 上通过：6 项、0 失败、0 跳过，XCTest 用时 0.840 秒。其中覆盖五种预设的快门/ISO范围与硬件裁切、M 挡参数约束及反复开关清理、A 挡保持自动曝光并按预设限制最大曝光时长、五个预设与后置焦段触控槽位对齐，以及真实相机界面 20 次快速开关。真实界面用例用时 0.765 秒；20 次切换和 350 ms 稳定等待共 0.463 秒。
- 此轮没有拍摄样张，因此未核对慢门参数对应的实际成片、元数据或低照度观感；也未验证预览实际帧率和设备旋转布局。现有慢门预设控制单帧快门/ISO范围，硬件可用上限会裁切预设；多帧累积的灯轨、流水或星轨合成尚未实现。测试运行期间记录到 CoreMotion 权限提示及 `MDB_MAP_FULL` 系统日志，未见与失败测试关联的项目调用栈，来源未确认。
- 结果包：完整慢门定向测试组 `/tmp/LumaCameraSlowShutterSuiteDerivedData/Logs/Test/Test-LumaCamera-2026.10.21_12-15-16-+0800.xcresult`；单项真实相机会话布局/切换 `/tmp/LumaCameraSlowShutterRetestDerivedData/Logs/Test/Test-LumaCamera-2026.10.21_12-10-11-+0800.xcresult`；五按钮样式夹具与快照绘制指标见前两项记录。

### 定向真机复测：慢门预设背景与焦段背景左右对齐

- 撤销焦段条额外的固定宽度，让它恢复为焦段按钮组自然宽度（按钮槽位、间距及原有 2 pt 内边距）；移除慢门预设背景的整行固定宽度，让它按五个按钮槽位自然定宽。两条背景各自对齐到本行最左、最右按钮槽位，保留 2 pt 内边距，不再互相作为宽度基准。
- 第一轮几何断言发现慢门背景仍被 `lensWidth` 撑宽，超出两端预设按钮槽位约 27 pt；移除该宽度约束后，背景端点均恢复到各自按钮槽位外沿 2 pt。随后 iPhone 17 Pro / iOS 27.0.1、Xcode 27.1 真机 XCTest 定向运行 2 项，0 失败、0 跳过：`SlowShutterPresetTests.testPresetCellsAlignWithFiveLensButtonSlots` 与 `SlowShutterPresetTests.testPresetSlotsAlignWithFocalSlotsAndSurviveRapidToggleOnDevice`。真实相机页慢门开关 20 次后，继续检查两组背景与按钮端点对齐；测试组用时 0.806 秒。结果包：`/tmp/LumaCameraPresetAlignmentCorrected/Logs/Test/Test-LumaCamera-2026.10.21_13-47-01-+0800.xcresult`。
- 本轮没有启动模拟器、没有拍摄或写入系统 Photos。控制台仍记录 `MDB_MAP_FULL` 与 CoreMotion 受保护配置文件读取警告；没有与测试失败关联的项目调用栈，来源未确认，不据此断言其无害。

### 定向真机复测：快门刻度、流畅预览与照片详情

- iPhone 17 Pro / iOS 27.0.1 上定向运行 5 项，全部通过、0 失败、0 跳过：`CameraRulerMappingTests.testShutterTickValuesSnapToStandardFractions`、`SlowShutterPresetTests.testPreviewOptimizationOnlyActivatesWhenSlowShutterWouldExceedPreviewCadence`、`PopupAppearanceAndOrientationTests.testSlowShutterPresetGroupGlassStabilityAndDrawCost`、`PhotoLocationTests.testPhotoInfoPresentsExposureFieldsAndRecordedShootingType`、`PhotoDetailHeaderTests.testPhotoInfoParameterGridLayoutAndRepeatedDrawCost`。结果包：`/private/tmp/LumaCameraFocusedSignedFinal.xcresult`。没有拍照或写入系统照片图库。
- 刻度回归修正：当当前设备快门范围内没有可用的标准分母档位时，输入值保持在硬件范围内的连续值，不再被错误吸附到范围端点；存在标准档位时仍选择最近档，刻度标题与显示快门值共用同一档位映射。
- 慢门预设背景用例执行 60 次选中项切换并保持窗口边界不变；5 组、每组 6 张层级快照耗时为 97.71、61.43、60.02、57.97、57.61 ms，平均 66.95 ms/6 张。照片详情用例断言七项参数字段与拍摄类型，并检查卡片区域布局；5 组、每组 6 张快照耗时为 76.19、45.69、49.78、50.70、49.03 ms，平均 54.28 ms/6 张。上述数据只表示测试窗口中的视图更新和快照绘制耗时，不是屏幕帧率、触控延迟或相机预览吞吐。
- 此轮使用定向测试，不运行全量回归。快照由 XCTest 生成；测试结果包的附件导出在当前环境被 `xcresulttool` 的 TestReport 写入权限拒绝，因此本记录只引用测试断言和数值，不声称已人工目视截图。此前慢门 6 项相机定向组的实测结果仍按上文记录。

## 2026-10-21 A 挡手动切焦时清除旧微距状态

- 用户主动切换焦段时，立即隐藏前一路由的微距标识，并通过 `LivePreviewState` 的路由代次丢弃切换前排队的微距采样；新路由建立后再按当前虚拟多摄状态更新标识。系统自动微距判定、近远对焦与切镜规则未改。
- iPhone 17 Pro / iOS 27.0.1 真机 XCTest `testExplicitFocalSwitchClearsPreviousMacroBadgeImmediately` 通过：超广角与主摄往返 6 轮，6 轮均在焦段选择返回时断言旧标识已清除；1 项通过、0 失败。单项 XCTest 用时 0.795 秒。测试运行在真机相机路由上，以测试钩子注入上一条路由的微距状态；这项耗时是整组 XCTest 用时，不是镜头切换或屏幕帧率指标。结果包：`/private/tmp/LumaCameraDeviceTestDerivedData/Logs/Test/Test-LumaCamera-2026.10.21_11-26-56-+0800.xcresult`。
- 本轮未启动模拟器、未拍摄或写入 Photos。真机测试覆盖明确焦段切换后的旧状态清理，不覆盖手动近远移动触发系统自动微距的主观视觉表现。

## 2026-10-21 顶部工具栏画幅重叠背景 Liquid Glass

- 仅将画幅变化时覆盖预览上沿的工具栏重叠带换成 Liquid Glass；工具栏按钮依旧无独立背景，透明命中拦截面不变。iOS 26 及以上使用 UIKit `UIGlassEffect(style: .regular)`，叠加轻微蓝色主题染色；重叠高度为零时保持透明。iOS 18–25 沿用原 `popupColor.opacity(0.2)` 填充；系统开启“降低透明度”时使用高不透明度实底。
- Xcode 27.1 / iOS 27.1 SDK generic iOS 构建通过（禁用签名）；真机测试构建、安装与运行通过。iPhone 17 Pro / iOS 27.1 定向 XCTest：`testToolbarOverlapGlassStabilityAndDrawCost`、`testToolbarOverlapGlassTracksEveryPhotoRatioOnDevice` 和 `testTopToolbarPopupRapidOpenCloseRotationStress` 共 3 项通过、0 失败、0 跳过。真机逐一切换 7 种照片画幅，玻璃视图只在几何上与预览重叠时存在，工具栏顶部位置偏差不超过 1 点；另执行 60 次重叠层显示/隐藏并确认玻璃视图不接收触控。没有启动模拟器或写入 Photos。
- 绘制样本为 5 组、每组 6 次视图层级快照，总耗时 110.08、54.70、58.40、61.09、63.61 ms，平均 69.58 ms/6 张，约 11.60 ms/张。它只代表测试窗口中的布局与 `drawHierarchy` 快照耗时，不是屏幕帧率、触控延迟或真实相机预览吞吐。测试截图来自条纹/文字合成背景，不是相机画面截图。
- iPhone 17 Pro 上已验证 iOS 27.1 Liquid Glass 分支；iOS 18–25 旧外观与系统“降低透明度”回退分支未做运行时视觉验收。结果包：`/private/tmp/LumaCamera-ToolbarGlass-Final4-20261021.xcresult`，测试截图：`/private/tmp/LumaCamera-ToolbarGlass-Final4-Attachments/1E8A59C2-1FAE-467B-BDEB-C8C0F5D13318.png`。

## 2026-10-21 Log 视频滤镜名称左对齐

- 将 Log LUT 弹窗底部信息栏扩展容器的对齐方式明确设为 leading，修复滤镜名称被整行宽度居中推移的问题；名称、设备名和状态提示沿用原字号与截断方式，收藏和烧录按钮位置不变。
- iPhone 17 Pro / iOS 27.1 定向真机 XCTest `testLogVideoFilterNameStaysLeadingAlignedOnDevice` 通过（1 项、0 失败）。测试打开实际相机页面的 Log 视频滤镜面板，断言滤镜名称文本左边缘与信息栏左边缘相差不超过 1 点，并重复关闭/重开面板 10 次后复查对齐；没有拍照或写入 Photos。
- 5 次 `drawHierarchy` 快照耗时为 59.94、16.62、15.53、14.61、12.35 ms，平均 23.81 ms/张；这是测试窗口快照绘制时间，不是屏幕帧率、触控延迟或实际相机预览吞吐。结果包：`/private/tmp/LumaCamera-LogFilterAlign-Final2-20261021.xcresult`。

## 2026-10-21 焦段与工具栏背景精简（早期状态，焦段背景由本日后续更新覆盖）

- 固定焦段条移除了覆盖整组按钮的玻璃底；iOS 26 及以上仅当前选中按钮显示圆形 `UIGlassEffect`，未选中按钮无背景。iOS 18–25 继续用原有选中浅底。前置广角/普通切换组也不再绘制整组背景。顶部拍照与视频工具栏的格式、比例、影调、状态图标按钮移除单按钮玻璃底，保持文字/图标的选中颜色和原尺寸；透明触控拦截层与弹窗背景保留。
- iPhone 17 Pro / iOS 27.0.1（build 24A446）真机 XCTest 定向回归：`testFocalPresetSelectionGlassStabilityAndDrawCost` 与 `testTopToolbarPopupRapidOpenCloseRotationStress`，2 项通过、0 失败、0 跳过。选中焦段测试快速更换状态 60 次，每次检查三个按钮中仅选中项有玻璃效果且全部仍可交互；截图目视确认仅当前项有圆形背景。工具栏弹窗测试快速开合并切换方向状态，弹窗最终保持可见。
- 性能样本取自最终真机回归：5 组，每组 6 次焦段状态更新、布局和 `drawHierarchy` 截图；总耗时为 99.08、53.13、52.45、50.25、48.45 ms，平均 60.67 ms/组（约 10.11 ms/次）。这是 UI 状态更新与视图层级截图的组合耗时，不代表实际显示帧率或手指交互延迟。
- Xcode 27.1 / iOS 27.1 SDK generic iOS 构建通过；测试未启动模拟器。iOS 18 旧样式分支参与构建，但没有 iOS 18 设备运行时外观验证。真机测试期间还出现 `MDB_MAP_FULL` 系统日志，未关联到该控件的项目调用栈，来源未确认。
- 结果包：`/private/tmp/LumaCamera-ToolbarFocalGlass-Final-20261021.xcresult`。未向系统 Photos 写入诊断媒体。

## 2026-10-21 Live 三秒选区与剪辑面板开合

- 编辑页初始不显示工具面板；点剪辑显示，再点收起。其他工具通过同一入口打开，底部工具栏保持位置，沿用局部淡入淡出及减弱动态效果分支。
- Live 时长现在显示 min(3 秒, 源视频时长)，开启后以当前预览位置为中心（边缘限位）选择整个源视频中的三秒。短视频全选。Live 选中时拖动选区或两端均整体移动，不改变长度；再次点击恢复开启前的视频裁剪范围，重置裁切退出 Live 选区。保存仍使用既有视频 / Live 选择，不改原视频；未开启 Live 选区时的原保存行为保留。
- 按钮布局区域高 32 点，上方留白 7 点、下方至胶片留白 7 点，胶片 48 点、底部 5 点，总高 99 点。此前 112 点布局记录保留在下方作为历史。官方手势入口使用 SwiftUI [DragGesture](https://developer.apple.com/documentation/swiftui/draggesture)，三秒固定选区是应用产品规则，不声称是系统 Live Photo 时长上限。
- iPhone 17 Pro / iOS 27.0.1，Xcode 27.1：首轮十项定向用例中九项通过，旧高度断言仍为 112 导致一项失败；修正期望值为 99 后，单独重测高度及新增界面开合用例，两项通过。无模拟器启动，无诊断媒体保存到 Photos。
- 1 秒与 16 秒、160×90 H.264 临时素材各重复 20 次 Live 开关、边缘拖动、范围恢复；覆盖超界限位、短视频全选、重置、取消和默认收起。每种素材另做三轮、每轮 20 次快速移动更新。16 秒素材三次从输入突发开始到 AVPlayer seek 完成并落在 0.12 秒容差内分别 84.19 / 21.63 / 20.38 ms，平均 42.07 ms。1 秒素材因全选后无移动空间，后两轮无实际 seek，不作为拖动性能数据。普通截点回归三轮平均 22.0 ms、最大 24.1 ms；这些不是实际屏幕帧率或高分辨率长素材性能保证。
- 真机托管编辑页 20 轮快速开合（每次间隔 30 ms），状态与三秒范围保持正确；导出并目视核对初始隐藏、Live 选中截图，未发现按钮文字遮挡。截图中的 AVPlayerLayer 为黑色，截图只用于核对 UI，不能证明画面渲染或真人手势流畅度；本轮未重新向 Photos 导出 Live。
- 结果包：`/private/tmp/LumaCameraLiveSelection20261021.xcresult`（首轮含一项旧断言失败）；`/private/tmp/LumaCameraLiveLayout20261021.xcresult`（最终两项通过）。截图在 `/private/tmp/LumaCameraLiveLayoutAttachments/`，性能文本在 `/private/tmp/LumaCameraLiveSelectionAttachments/`。

## 2026-10-21 视频编辑裁剪面板与截点预览优化

- 时长裁剪卡片固定为 112 点高；时长标识靠面板上沿，胶片轨道贴近卡片底边。滤镜/调色面板仍为 186 点高，底部工具栏布局不变。
- 截点拖动预览改为单路串行 seek：高频输入只覆盖待处理位置，快速 seek 的开始间隔至少约 33 ms（上限约 30 次/秒）；seek 本身较慢时不再叠加额外等待。播放器每次 seek 完成后再更新播放头。拖动期间不重复设置 `forwardPlaybackEndTime`，松手时提交所选范围，开始播放时也会同步范围。
- 官方 `AVPlayer.seek(to:toleranceBefore:toleranceAfter:)` 文档说明非零容差可让播放器在允许时间范围内选取帧以提高 seek 效率；样本精确 seek 可能增加解码延迟。本实现保留 1/15 秒容差，未改成逐帧精确 seek：[Apple AVPlayer seek 文档](https://developer.apple.com/documentation/avfoundation/avplayer/seek%28to%3Atolerancebefore%3Atoleranceafter%3A%29?changes=_1)。这是 API 行为说明；是否改善实际手势观感仍须真机复测。
- 优化前连接到 iPhone 17 Pro 的定向 XCTest 3 项通过，覆盖编辑页打开、截点预览定位和裁剪面板高度。优化后 `xcrun swiftc -frontend -parse` 对 ViewModel、编辑页及相关测试通过；Xcode 27.1 / iOS 27.1 generic iOS `build-for-testing` 通过（禁用签名，Metal Toolchain 已安装）。
- 优化后 iPhone 17 Pro / iOS 27.0.1 定向 XCTest 3 项通过、0 失败、0 跳过：裁剪面板高度、快速截点更新与最终落点、视频编辑页打开。快速更新回归使用本地生成的 1 秒、160×90 H.264 测试视频，重复 3 轮、每轮同步提交 20 次截点变化，共 60 个输入事件；播放器实际启动 3 次 seek（每轮 1 次），平均从输入突发开始到最终 seek 完成并落在目标 0.12 秒容差内为 21.4 ms，最大 21.6 ms。此数据衡量本地测试资产上的 AVPlayer seek 完成时延，不是屏幕显示帧率、视频解码到屏幕的延迟，也不代表真实长视频或高分辨率素材的表现。
- `xcrun swiftc -frontend -parse` 对 ViewModel、编辑页及相关测试通过；Xcode 27.1 / iOS 27.1 generic iOS `build-for-testing` 通过（禁用签名，Metal Toolchain 已安装）。测试期间未向系统 Photos 保存诊断媒体，也未启动模拟器。自动回归验证了编辑器呈现与面板尺寸，但未做真人手指连续拖动的观感评分；正式视频素材、不同编码/帧率下的流畅度仍应在实际编辑时复核。

## 2026-10-21 夜景环境触发状态与指示器

- 夜景开关、规格兼容和环境触发被拆成独立状态：关闭时月亮和圆形底板移除；开启但不兼容时显示斜线月亮；兼容但未达到低照度门限时为白色月亮；触发后为橙色可点按月亮，点击调用现有夜景开关。状态改变沿用预览局部淡入淡出，不移动控件。
- 当前应用判据为 `ISO × exposureDurationSeconds ÷ 2^EV`：达到 64 且连续两个有效读数后触发；降到 40 或以下且连续三个有效读数后解除。40–64 之间保留状态作为迟滞区。示例：EV 0、ISO 1600、1/25 秒的值约为 64。相机读数管线最多每 0.4 秒更新一次，单个状态判定最坏需等待两个读数周期进入、三个周期退出；进入/退出所需实际时间还受自动曝光稳定速度影响。
- 这不是苹果公开的夜景阈值。Apple 文档公开 `AVCaptureDevice.iso`、`exposureDuration` 等当前曝光读数，但没有公布系统相机夜景模式的通用照度触发阈值。Apple 的 `automaticallyEnablesLowLightBoostWhenAvailable`/`isLowLightBoostEnabled` 是设备低光增强状态：设备自行决定何时启用，且只适用于部分格式/分辨率，切换可能丢视频帧；它不代表本应用的多帧照片夜景模式，本实现没有读取该属性。`AVCaptureSceneMonitoringStatus.notEnoughLight` 公开状态目前对应 Cinematic Video 场景监测，不是通用拍照夜景条件。
- iPhone 17 Pro / iOS 27.0.1 定向真机 XCTest：5 项夜景状态/阈值/性能用例通过，0 失败、0 跳过。性能用例每轮合成 20,000 个曝光读数，共 5 轮，单轮耗时为 1.743、1.402、1.378、1.485、1.433 ms，平均 1.488 ms；该指标只代表判定函数吞吐，不是相机帧率或完整 App 性能。滞回用例覆盖单点噪声、连续触发/退出、EV 归一化和 reset。
- 同一代码版本上的 `NightCapturePhysicalTests.testThreeNightCapturesCompleteInMemoryAndReportHonestMergeState` 真机用例通过，连续执行 3 次实拍并检查多帧融合状态、忙碌状态释放和保存队列不增长。该用例显式把夜景采集选项置为开启，以免依赖测试现场光线，因此验证的是包围采集/融合路径，不代表真实环境门限或月亮颜色经过人工目视验收。没有向系统 Photos 保存诊断照片，也未启动模拟器。
- 测试控制台在切换相机模型测试时出现 `mdb_txn_commit error: MDB_MAP_FULL`；没有项目源码调用栈与其关联，本轮测试断言均通过，但其来源尚未确定，不能据此断言无害。结果包：`/private/tmp/LumaCameraNightIndicatorFinal.xcresult`、`/private/tmp/LumaCameraNightIndicatorSignedDeviceTests.xcresult`、`/private/tmp/LumaCameraNightCaptureSignedDeviceTest.xcresult`。

官方依据：[AVCaptureDevice.iso](https://developer.apple.com/documentation/avfoundation/avcapturedevice/iso)、[AVCaptureDevice.exposureDuration](https://developer.apple.com/documentation/avfoundation/avcapturedevice/exposureduration)、[AVCaptureDevice.automaticallyEnablesLowLightBoostWhenAvailable](https://developer.apple.com/documentation/avfoundation/avcapturedevice/automaticallyenableslowlightboostwhenavailable)、[AVCaptureDevice.isLowLightBoostEnabled](https://developer.apple.com/documentation/avfoundation/avcapturedevice/islowlightboostenabled)、[AVCaptureDevice.cinematicVideoCaptureSceneMonitoringStatuses](https://developer.apple.com/documentation/avfoundation/avcapturedevice/cinematicvideocapturescenemonitoringstatuses)。

## 2026-10-21 美食 CUBE 滤镜接入

- 移除旧 `FoodFilmProfile` 手写配方，以用户提供的 `美食.cube` 替换照片与 SDR/P3 视频中的“美食”滤镜。源 LUT 为 17³、4,913 个 RGB 表项，转换为 78,608 字节 float32 RGBA 资源；SHA-256 `2f8123b660cb15228f6741aad2a60ace2248560b42ec42ab7985348b3b81e6e6`。源文件没有 `DOMAIN_MIN/MAX` 或色彩空间标签；表项按默认 [0,1] 输入域读取，并沿用既有 Core Image sRGB LUT 管线。没有声称它包含 P3 专属版本。
- 沿用 `.food` 持久化标识并放在列表末尾，旧收藏、选中状态和照片滤镜元数据因此仍指向“美食”，但渲染改为新 LUT。照片预览/编辑及 SDR/P3 视频仍调用相同 `FilmStyle`/`CaptureLook` 路径；RAW、HDR 与 Log 视频不改变现有兼容规则。
- iPhone 17 Pro / iOS 27.0.1（build 24A446）定向真机 XCTest：6 项通过、0 失败、0 跳过，覆盖 LUT 载入与唯一性、旧配方替换、收藏/照片编辑往返、SDR/P3 视频帧烘焙、视频 LUT 性能和玻璃弹窗测试。没有拍摄或写入系统 Photos。
- 30 个 640×360 视频帧缓冲区逐帧复用输入/输出缓冲区，5 个 XCTest 时间样本为 11.420、11.449、11.645、11.388、10.202 ms，平均约 11.22 ms/30 帧。此测量只覆盖现有 Core Image 过滤和写入像素缓冲区，不包括相机采集、AVAssetWriter、音频、显示同步或温升，不代表实时录制帧率。
- Liquid Glass 弹窗绘制测试每次绘制 6 张视图层级快照，5 次样本平均 69 ms/6 张（约 11.6 ms/张）；这是 `drawHierarchy` 快照耗时，不是屏幕帧率。200 次快速方向状态变化后仍能取得有效弹窗截图。均在 iPhone 17 Pro / iOS 27.0.1 执行。
- Xcode 27.1 / iOS 27.1 SDK 的 generic iOS 构建通过，最低部署目标 iOS 18。`#available(iOS 26, *)` 玻璃分支在 iPhone 17 Pro/iOS 27.0.1 真机运行；iOS 18–25 旧外观分支参与编译，但这轮没有在 iOS 18 设备/模拟器上做运行时视觉检查。CoreSimulatorService 此轮无法连接，未启动模拟器。期间恢复安装了此前缺失的 Metal Toolchain 27A266a，Metal shader 与主 App 均成功构建。
- 实现依据：[Apple CIColorCubeWithColorSpace 表格格式与通道顺序](https://developer.apple.com/documentation/coreimage/cicolorcubewithcolorspace/cubedata)、[SwiftUI View.glassEffect](https://developer.apple.com/documentation/swiftui/view/glasseffect%28_%3Ain%3A%29) 与 [UIKit UIGlassEffect](https://developer.apple.com/documentation/uikit/uiglasseffect)。运行时行为以本次 iPhone 17 Pro 回归为依据；源 CUBE 本身未提供色彩空间标签。
- XCTest 控制台另外出现系统 `mdb_txn_commit error: MDB_MAP_FULL` 日志；未见对应项目源码调用栈，测试仍全部通过。日志来源尚未确认，不据此断言其无害。另有 Xcode 的 AppIntents 元数据提取跳过提示，项目未依赖 AppIntents。

# 架构重构验证

### 真机复测（iPhone 17 Pro / iOS 27.0.1）

- 真机 `NightCapturePhysicalTests.testThreeNightCapturesCompleteInMemoryAndReportHonestMergeState` 单独重跑通过。后置主摄 1×、A 挡、JPG、标准分辨率、闪光灯关闭，连续采集 3 组；三组均记录“3 帧对齐融合”，从提交到 `onCaptureCompleted` 的时间分别为 1.258、0.952、1.651 秒，中位数 1.258 秒。该耗时包含曝光采集、编码/解码、Vision 配准、Core Image 融合，不等于单纯曝光时长或预览帧率。相机每组完成后 `pendingPhotoCount` 回到 0、快门解除忙碌；测试替换了自动保存回调，PhotoLibrary 保存队列保持原值，没有向系统 Photos 写入诊断照片。
- 同一轮 `xcodebuild test` 定向执行 4 项，0 失败、0 跳过：上述真机采集、`PhotoOptionsTests.testNightMergerRepeatedSyntheticThreeFrameBracket`、`PhotoCaptureDiagnosticsTests.testNightBadgeRequiresCompletedThreeFrameMergeAndPersists`、`VideoDetailLayoutTests.testEditedVideoCanBeExportedAsAStandaloneFilesCopy`。最后一项在真机测试进程中验证剪辑导出副本存在、非空、与源文件分离并释放编辑锁；没有实际呈现/点按系统 Files 选择器，所以 UI 交互仍待目视验收。
- 夜景物理回归额外重复运行一次，仍为 1 项通过；三个样本融合结果一致。测试期间控制台出现若干 `mdb_txn_commit error: MDB_MAP_FULL` 和 Fig `-12710` 日志，但未发现项目源码调用栈，三次曝光、融合和成片回调均成功；这些日志来源尚未归因，不能据此断言其无害。另有 CoreMotion Managed Preferences 权限警告，和用户此前贴出的受保护系统文件警告一致。
- 此前 Xcode 27.1 / iOS 27.1 SDK 的 generic iOS `build-for-testing` 日志确认 Metal Toolchain 编译了项目 shader；本轮真机测试本身不用于证明每次构建都会重新编译 shader。设备为 iPhone 17 Pro（iOS 27.0.1，build 24A446），未启动模拟器。结果包：`/private/tmp/LumaCameraNightDeviceTests.xcresult` 与 `/private/tmp/LumaCameraNightPhysicalRerun.xcresult`。

## 2026-10-20 夜景合成与视频存储到文件

- 夜景采集使用 AVFoundation 三帧自动曝光包围。修正帧序号读取位置：`sequenceCount` 属于回调的 `AVCapturePhoto`，且序号从 1 起；此前从 `bracketSettings` 读取会让帧排序/中间帧选择错误。Apple 文档说明了包围拍摄配置和序号字段，但没有提供可直接调用的系统夜景合成算法。
- 应用合成逻辑使用 Vision 平移配准、曝光权重遮罩、Core Image `CIBlendWithMask` 和共有边缘裁切。仅当 3 帧都成功对齐时记录“3 帧对齐融合”并显示月亮标识；对齐不足退回第 2 帧，数据不完整退回可用单帧，以上回退均不显示夜景标识。诊断信息和图库标识读取 PhotoKit local identifier 对应的应用记录。
- `PhotoOptionsTests.testNightMergerRepeatedSyntheticThreeFrameBracket` 要求同一静态合成曝光组确实对齐满三帧，并生成 10 组合成样本；它已在本次 iPhone 定向测试中通过，但该测试未收集可报告的平均耗时指标。`PhotoCaptureDiagnosticsTests.testNightBadgeRequiresCompletedThreeFrameMergeAndPersists` 同样已在本次真机定向测试中通过，验证只有完整融合才显示并持久化夜景标识。三组真实相机采集时延见本节开头。
- 视频编辑器“存储到文件…”先用现有 `VideoEditExportService` 导出剪辑/滤镜后的独立临时文件，再通过 `UIDocumentPickerViewController(forExporting:asCopy:)` 让用户选择文件位置；导出为副本，不覆盖原视频。目标目录是否为 Files 根目录由用户在系统选择器中决定。`VideoDetailLayoutTests.testEditedVideoCanBeExportedAsAStandaloneFilesCopy` 已在本次真机定向测试中通过，验证导出副本存在、非空、与源文件分离且释放编辑锁；尚未实际呈现/点按系统文件选择器。
- Xcode 27.1 / iOS 27.1 SDK generic iOS `build-for-testing` 成功（禁用代码签名）。日志确认 Apple 随 Xcode 提供的 Metal Toolchain 实际执行并编译 `LumaCamera/Core/Imaging/ImageEffects.metal`；这是本项目构建日志中的实证，与另一项目安装状态相符。仍不据此推断单独的 `xcrun metal --version` 命令状态。构建出现 AppIntents 元数据跳过提示，项目未使用 AppIntents。
- 初次记录时设备清单仅枚举到 Mac，故当时没有执行测试；随后已在本节开头补记真机复测。融合回退样本、已保存 Photos 资产上的月亮标识目视检查和 Files 选择器实际点按仍未单独验证。官方依据：[AVCapturePhotoBracketSettings](https://developer.apple.com/documentation/avfoundation/avcapturephotobracketsettings)、[AVCaptureAutoExposureBracketedStillImageSettings](https://developer.apple.com/documentation/avfoundation/avcaptureautoexposurebracketedstillimagesettings)、[`AVCapturePhoto.sequenceCount`](https://developer.apple.com/documentation/avfoundation/avcapturephoto/sequencecount)、[UIDocumentPickerViewController](https://developer.apple.com/documentation/uikit/uidocumentpickerviewcontroller/init%28forexporting%3Aascopy%3A%29)。

## 2026-10-20 Xcode 推荐设置与拍摄辅助占位清理

- 核对 Xcode “Update to recommended settings”迁移结果：工程已启用推荐 Clang 警告、Debug `ONLY_ACTIVE_ARCH`、User Script Sandboxing、Objective-C weak references 与 localizability 检查；`LumaCamera.xcodeproj` 没有 `PBXShellScriptBuildPhase`，因此本次未发现会被脚本沙盒阻断的自定义构建脚本。
- Xcode 27.1（iOS 27.1 SDK）generic iOS `build-for-testing` 成功，禁用签名。迁移后的 iPhone 17 Pro / iOS 26.5 模拟器 `LogLUTCubeTests` 6 项通过，0 失败。
- 按用户澄清，“九宫格按钮”是拍摄辅助，“上方按钮”是独立子模块。仅从 `captureToolsPanel` 删除未实现的“人像、连拍、夜景、延时、慢门、慢动作”占位项；保留上方子模块入口及视频录制中的剩余时间/声音电平开关。其余辅助控制、4 列网格、间距、动画和按钮位置未改。
- 修改后 generic iOS `build-for-testing` 成功；iPhone 17 Pro / iOS 26.5 模拟器 `CameraPopupLifecycleTests` 2 项通过，0 失败。`CaptureControlRotationTests.testAllLandscapeCameraPopupTypesStayInsideWindowForEveryRatio` 在模拟器启动相机源后以 SIGSEGV 结束，未到达布局断言，因此不计为通过；相同项目构建与不启动相机会话的弹窗生命周期测试均通过。没有物理 iPhone 真机视觉验收，所有比例下辅助面板的位置仍需后续真机确认。
- 推荐设置构建中仍有 Swift 并发捕获及未使用局部值等警告，没有警告升级为构建错误；本次没有改动这些与辅助面板无关的代码。

## 2026-10-19 辅助开关独立保存与视频码率

- 拍摄辅助面板中已实现的功能改为全新默认关闭，并由 `CapturePreferences` 独立持久化，不随“保存拍摄设置”开关重置。未实现的占位入口明确排除。
- 视频码率档位始终可选；低/中/高仅由 HEVC/H.264 应用，ProRes/RAW 忽略设置且保留选择。默认将平均码率控制交给系统编码器；档位参考 HEVC 1080p30 8/16/28 Mbps、H.264 1080p30 10/20/35 Mbps，按分辨率、帧率与位深估算。
- 此记录是初始实现状态；后续修正与验证见本文件“2026-10-19 前置方向取景与码率适用范围”。

验证日期：2026-10-13。环境：Xcode 27，iPhone 18 Pro 模拟器（iOS 27）。

| 检查 | 结果 |
| --- | --- |
| Debug 模拟器构建及单元测试 | 15 项测试通过，0 失败 |
| Debug generic iOS 构建 | 编译通过，禁用代码签名 |
| 自动拍照首页 | 模拟器截图核对通过 |
| 16:9 手动白平衡参数窗口 | 模拟器截图核对通过 |
| 工程配置 | Info.plist 更新为 Resources 路径，明暗 App 图标及现有签名 Team 保留 |

截图：`Preview/Architecture-Auto.png`、`Preview/Architecture-Parameters.png`。

测试包括 CameraCaptureTests（1）、CameraViewModelTests（3）、ImagingTests（5）、PhotoLibraryViewModelTests（6）。PhotoLibrary 测试使用延迟回调替身，不调用系统权限弹窗或实际相册。

以上真机目标构建只验证编译，不代表已经在物理 iPhone 上运行。硬件拍摄与系统相册授权、保存、删除及取消行为仍需真机验收。

## 系统相册与工具栏更新

2026-10-13：22 项测试全部通过，0 失败；generic iOS 目标编译通过，禁用签名。新增的 7 项图库测试覆盖授权拒绝、有限权限分页、图库变化刷新、删除失败保留、删除当前已保存照片、删除其他照片，以及过期查询结果。

模拟器已使用真实 PhotoKit 数据源加载系统自带的 6 张照片，网格缩略图裁切经截图核对。手动参数按钮全部改为图标，顶部五项工具及页指示布局参照用户提供的极影相机截图，保留实际 JPEG 功能和暗色玻璃主题。

最终截图：`Preview/Updated-Manual.png`、`Preview/System-Gallery.png`。未删除模拟器自带照片；删除成功和失败的状态由服务替身测试验证。真实设备的权限选择、iCloud 下载、系统删除确认及取消仍需真机验收。

## 预览透明控件更新

移除工具栏上方的独立一行，将工具栏最右侧替换为应用设置入口。PreviewSurface 以约 20% 不透明度的深色底和轻微边缘高光绘制，不使用模糊材质；镜头、A/M、九宫格、直方图、16:9 工具栏和参数区，以及预览弹窗均使用透明背景。外部快门控制区继续使用玻璃材质。

Debug 模拟器和 generic iOS 目标编译通过。16:9 手动模式与滤镜窗口的叠加布局经过截图检查，背景画面和参考线可透过控件。截图：`Preview/Transparent-Controls.png`。本次为界面调整，未增加单元测试。

## 底部滤镜选择器重做

2026-10-13：参照 IMG_1700 的底部分区，替换中央悬浮滤镜窗口为分类栏、圆形卡片与底部收藏/强度/关闭操作。保留蓝灰暗色玻璃主题，原有五款风格的缩略图由真实滤镜配方渲染。新增收藏持久化与展开强度调节。

打开滤镜选择时支持预览横滑切换，短距离与纵向滑动忽略，分类内端点不循环，关闭后不再响应滤镜滑动。26 项测试全部通过，0 失败；generic iOS 目标编译通过。新增 4 项测试覆盖开关范围、横纵方向判定、边界与分类、收藏恢复。实际触屏手势未在物理 iPhone 上验收。

模拟器核对 4:3、16:9 和强度栏展开布局，截图：`Preview/Filter-Picker-Standard.png`、`Preview/Filter-Picker-Wide.png`、`Preview/Filter-Picker-Strength.png`。

## 参数窗口、前置方向与 2×／4×

2026-10-13：手动参数弹窗背景不透明度提高至 86%，弹窗打开时隐藏底层参数按钮重影。仅白平衡保留底部 AWB 与色温预设，快门、ISO、曝光和对焦删除底部固定值与 AUTO，顶部 A/M 保留。模拟器核对快门和白平衡布局，截图：`Preview/Manual-Shutter-Dark.png`、`Preview/Manual-WB-Dark.png`。

镜头连接改为在输入提交后设置竖屏旋转与前置镜像，横向预览帧有竖屏后备变换。增加 2×／4× 入口，优先原生镜头或传感器采样倍率；其余使用系统数字变焦。同一镜头变焦保留手动参数。

32 项测试通过，0 失败；Debug 模拟器和 generic iOS 目标编译通过。新增 6 项测试覆盖原生 2× 裁切与 4× 长焦选择、3× 长焦到 4× 的数字回退、禁止 5× 长焦缩小到 4×、超出能力范围的入口排除，以及横向帧旋转和避免重复旋转。

模拟器不提供真实摄像头。本次没有在物理 iPhone 上验证前置竖屏、前置照片镜像、点按对焦映射或实际原生倍率；这些仍需真机验收。

## 弹窗主题与固定镜头倍率位置

2026-10-13：参数、滤镜、拍摄功能、辅助工具、设置和图库窗口统一为相同的深蓝灰色背景（86% 不透明度）。取消参数窗口打开时额外上移镜头倍率区，按画幅固定位置，为最高的白平衡参数窗口留出空间。

Debug 模拟器和 generic iOS 目标均编译通过（禁用签名）。模拟器截图对照 16:9 手动模式打开白平衡窗口前后，镜头倍率和 A/M、辅助入口位置一致且不被参数窗口遮挡；核对 4:3 辅助工具及展开强度的滤镜窗口背景。截图：`Preview/Fixed-Lens-Closed.png`、`Preview/Fixed-Lens-Parameter.png`、`Preview/Unified-Popup-Tools.png`、`Preview/Unified-Popup-Filter.png`。本次为界面样式与布局调整，未新增或重跑逻辑测试；未在物理 iPhone 上验收。系统原生分享及确认对话框由 iOS 绘制。

## 格式、画幅、影调测光与预览切换

2026-10-13：参照 IMG_1701–1703，顶部前三类窗口采用胶囊选项、两列影调缩略图和三列测光入口，保留深蓝灰色主题。新增 HEIF/JPG/RAW/RAW＋JPG/TIFF/RAW 转 HEIF、12MP/48MP 能力选择、HDR；闪光灯循环关闭/打开/自动。新增 3:2、2:1、2.35:1 与 XPAN（65:24）画幅。顶部工具栏仅在预览内显示融合顶部与两侧的背景。

40 项测试通过，0 失败；最终 Debug 模拟器与 generic iOS 构建通过，禁用签名。新增 8 项测试覆盖闪光灯状态、实际 HEIF/JPG/TIFF 文件容器与裁切、HDR 文件 10-bit 位深、DNG 资源保留与 RAW＋JPG 配对、全局平均亮度、画幅比例、影调像素变化和顶部窗口状态；既有拍摄测试验证预览保持完整画面而输出按选定画幅裁切。长画幅测试按 Core Image 两侧最多扩张两个像素的取整范围验证。

截图核对：`Preview/Toolbar-Format.png`、`Preview/Toolbar-Ratio.png`、`Preview/Toolbar-Tone.png`、`Preview/Toolbar-Outside.png`。模拟器中的 RAW/48MP 入口不可用，未以演示资源冒充原生能力。HDR 测试使用合成高亮图像验证编码；RAW 配对测试验证资源字节与标识，不代表真实 DNG 硬件拍摄验收。

真实设备的 RAW/ProRAW 解码、48MP 实际交付、PQ HDR 显示、RAW＋JPG PhotoKit 保存及分享、自动闪光、全局测光稳定性、点测光位置与连续画幅切换性能尚需真机验收。仅保留发布前需要的硬件验收记录，不宣称切换已完全无卡顿。

## 视图更新期间发布状态的修复

2026-10-13：CameraView 生命周期回调不再同步发布 CameraEngine 与 CameraViewModel 的状态；通过 setCameraActive 延后到下一轮主线程执行，并用请求标识跳过快速进出页面后的过期启动／停止。顶部分页选择通过 updateToolPageFromPager 延后回写，忽略重复和过期选择，保留弹窗动画。

43 项测试通过，0 失败；generic iOS 构建通过。新增 3 项测试验证生命周期回调内不立即发布、页面离开前的启动被取消、以及分页状态延后更新且旧选择不覆盖新选择。模拟器以 16:9 和滤镜展开状态启动，控制台日志未发现 Publishing changes 警告；这不覆盖所有真机触摸路径，Xcode 调试下仍需核对原触发操作。


## 画幅动画、手动状态与自动保存相册

2026-10-13：52 项测试全部通过，0 失败；最终 generic iOS Debug 构建通过，禁用签名。新增 9 项测试覆盖自动保存资源及重复保护、失败保留与重试、编辑互斥、手动按钮状态、全分辨率旋转 JPEG、调整编码、编辑失败及页面释放后的解锁，以及从 CameraEngine 拍摄回调到自动保存的完整流程。单元测试使用服务替身，不写入系统相册。

模拟器单独执行真实 PhotoKit 自动保存烟雾检查：通过 Debug 自动拍摄入口保存一张演示 JPEG；重新进入图库后可读取该系统资产的文件名、900×1200 尺寸、时间和文件大小，确认保存成功并且没有额外保存确认。未修改或删除模拟器已有照片。截图核对三列图库、照片页五个按钮、编辑滑块、详情，以及 M 挡浅橙色手动参数。

截图：Preview/Gallery-Auto-Saved.png、Preview/Photo-Viewer.png、Preview/Photo-Editor.png、Preview/Photo-Info.png、Preview/Manual-Parameter-Orange.png。

画幅动画已接入布局及减少动态效果设置，未在物理 iPhone 上录制验收。编辑渲染和失败状态经单元测试验证，真实系统资产可打开编辑页，但本轮未提交编辑或删除系统样本照片。真机仍需验收硬件拍摄、授权、自动保存、编辑提交、分享及系统删除确认。视频录制尚未实现，本轮自动保存覆盖现有照片流程。


## 工具栏缩小、系统删除确认、8× 与滤镜一致性

2026-10-13：56 项测试通过，0 失败；generic iOS Debug 构建通过，禁用签名。新增 4 项回归测试：4× 长焦的原生 2× 裁切映射为 8×，无原生能力时拒绝数字回退；四种预览旋转的尺寸及对焦逆映射；翻转循环保持镜头与滤镜；所有滤镜／影调组合的 sRGB 预览与已编码 TIFF 在三个渐变采样点颜色差异不超过两个 8-bit 色阶。

模拟器核对缩小的顶部工具栏及拍摄辅助面板，确认外置镜头入口移除、翻转使用旋转图标。截图为 Preview/Compact-Toolbar-Tools.png。静态检查确认两种照片页均无 App confirmationDialog，点击删除直接调用 PhotoKit 服务。本轮未删除系统样本照片。原生 8× 需支持该能力的真机验证；模拟器不提供或伪造镜头能力。颜色测试验证统一处理和 SDR 编码，不能证明不同硬件帧、RAW 或 HDR 观感完全一致。


## 调节滤镜强度时的色彩异常

2026-10-13：此前固定强度的成片对照未覆盖滑块连续更新。本轮新测试复现 CIDissolveTransition 在银盐 1%／99% 时端点跳变，线性混合误差超过测试阈值（约 0.0042 的线性色阶）。改用线性灰度遮罩后，CPU 和默认渲染路径的所有滤镜、七个中间强度及不透明／半透明输入均通过线性混合与透明度检查；非法及越界值通过边界测试。

快速更新模拟器滤镜强度测试连续提交 30 个值，随后切换到暖忆 37%，验证之后发布的预览只包含最新设置的颜色。临时对照副本仅移除旧帧保护后，同一测试复现 13 个颜色断言失败，证明连续调整时旧强度的画面会在新设置后发布。正式项目未回退。修正版完整 59 项测试通过，0 失败；最终 generic iOS Debug 构建通过，禁用签名。

本轮没有在物理 iPhone 上复现用户所见异常。上述结果确认强度混合及旧预览帧保护，真机 GPU、相机输入色彩与持续拖动滑块的实际表现仍需用户设备验收。


## 顶部照片误选与自动参数被重新设为手动

2026-10-13：61 项测试通过，0 失败；generic iOS Debug 构建通过，禁用签名。新增两项状态测试覆盖快门、ISO 调整后选自动并重复 A/M 切换、手动样式保持关闭、原数值保留，以及白平衡／对焦自动状态和镜头参数重置。静态检查确认进入 M 挡与 resetParameters 均不再使用 supportsExposure 强制开启手动。

图库缩略图增加固定图像尺寸、裁切及矩形点击范围；照片详情页按资产 ID 隔离状态，防止不同照片复用旧详情。未自动点击删除系统样本照片；用户所见顶部格子误选及系统删除流程仍需在真机触摸验收。


## 保留 M 挡参数及参数模式

2026-10-13：63 项测试通过，0 失败；generic iOS Debug 编译通过，禁用签名。新增两项测试验证 ISO 640、快门 1/30s、色温 4200K、对焦 0.72 与 EV -0.7 在重复 M → A → M 切换后恢复，并恢复三个手动开关及按钮样式；A 挡 EV 1.2 单独保留。另验证先记忆手动状态、随后在 M 挡选择 ISO／白平衡自动后，后续切换保留新的自动选择，且独立的手动对焦状态与新数值仍恢复。此前自动参数状态测试继续通过。尚未在物理 iPhone 上验收实际硬件参数恢复。


## 录屏参考的半圆转盘变焦

2026-10-13：查看 28.8 秒参考录屏的 12 个采样画面，确认固定焦段条、半圆转盘、倍率指针及收起状态。每个真实焦段接入同一长按／横拖手势，普通点击仍切换固定焦段。

最终逻辑版本 67 项测试通过，0 失败；generic iOS 构建通过。新增 4 项测试覆盖设备变焦范围与物理镜头选择、0.5／1／2／4／8× 拖动映射及边界限制、模拟器居中裁切、转盘展开／变焦／收起及 M 挡状态保留。最后界面微调只跳过指针下方刻度并提升已有控件层级，模拟器构建通过；未为该视觉调整重复全部逻辑测试。

截图 Preview/Zoom-Dial-Wide.png 核对半圆背景、刻度、指针及倍率，消除中心刻度和倍率文字的重叠。模拟器仅展示 1–5× 演示范围，未冒充真实 0.5／2／4／8× 镜头。没有在物理 iPhone 上验收长按拖动的实际手感、跨镜头曝光恢复、RAW 能力更新或高倍率画质；这些需真机核对。


## 转动变焦轮时停住及 iPhone 原生变焦参考

2026-10-13：此前连续变焦每个手势事件均排入会话队列并重复配置照片输出，且每个新请求会使预览帧失效；高频拖动可能积压请求并让预览长期无新图像。本轮加入限频／最新值合并、减少配置调用，并停止以请求倍率修订丢弃硬件预览帧。

72 项测试通过，0 失败；最终 generic iOS Debug 构建通过，禁用签名。新增五项测试覆盖 5000 个请求只投递最后一个待处理目标、拍摄前 flush 最新目标且不重复投递、取消后新手势恢复、物理镜头切换边界防抖、100 个连续拖动事件期间预览仍有新帧及下一次拖动可继续。已有滤镜颜色、参数记忆和相册测试继续通过。

后置 A 挡优先接入系统虚拟多摄像头，使跨焦段连续变焦不再反复替换 App 的输入；M 挡采用物理镜头满足自定义参数需求。模拟器无法验证真实多摄像头、48MP／RAW、低光镜头选择或跨焦段硬件切换。本轮未在用户 iPhone 17 Pro 上运行，不能宣称与原生相机画质和过渡完全一致，仍需真实设备连续转动变焦轮验收。最后范围钳制修改只涉及真机路径，已通过最终真机目标编译。


## 转盘两侧裁切与变焦预览卡顿

2026-10-13：73 项测试通过，0 失败；最终 generic iOS 编译通过。新增 PreviewIsolationTests：暂停预览队列后，相机仍能准备、合并 500 个变焦事件并拍照，成片使用最终 2× 的 450×600 演示裁切；恢复队列后第一张预览同样为最终倍率。已有连续拖动预览更新、滤镜中间强度及成片颜色、M 挡记忆和图库测试继续通过。

静态检查确认视频帧委托与会话控制不再共用队列，显式启用系统预览尺寸缓冲区。模拟器截图 Preview/Zoom-Dial-Complete.png 显示完整半圆及左右两端，保留缩小后的高度；只用于截图的 Debug 启动选项等待准备完成后再展开。该截图选项微调经模拟器编译验证，未重复全部逻辑测试。

测试确认队列隔离与可恢复性，不能代替用户真机上的 GPU 帧率、自动镜头切换和持续变焦手感验收；本轮未在物理 iPhone 上测量帧率。

## 变焦盘尺寸、滤镜名称和刻度震动

2026-10-13：变焦盘完整半圆放大到预览框两侧；滤镜名称移至右上角，直方图开启时位于名称下方。转盘按显示的每档十二个对数刻度产生轻反馈，经过 0.5×、1×、2×、4×、8× 产生较强反馈，点击固定焦段也产生较强反馈。快速跨越多个刻度只产生一次反馈，并优先主要焦段；刻度附近抖动不会反复触发。震动发生在主线程，不进入相机会话或预览渲染队列。

77 项模拟器测试通过，0 失败；新增 4 项测试覆盖双向普通刻度、五个主要焦段、原地/抖动抑制、快速跨越及无效输入。generic iOS 目标编译通过，禁用签名。布局截图：`Preview/Zoom-Dial-Edge.png`。实际震动强弱及手感需要真机体验，模拟器测试只验证触发逻辑。

## 变焦盘松手后保持显示

2026-10-13：结束拖动仅清除本次手势起始倍率，变焦盘保持显示；直接再次拖动转盘从当前倍率开始。盘外透明点击区域收起转盘，收起的这次点击不会触发底层控件。离开相机或应用进入后台继续清理转盘状态。扩展连续变焦测试验证松手保留、再次拖动不跳回旧倍率和显式收起。77 项模拟器测试通过，0 失败；generic iOS 目标编译通过，禁用签名。触摸交互仍需真机体验。

## 焦段短按与长按、预览切换过渡

2026-10-13：固定焦段按钮短按只切换焦段并产生震动，长按 0.4 秒完成后才展开变焦轮。长按手势的第一阶段不再展开转盘。松手保持显示及盘外点击收起保留。固定焦段切换暂时覆盖上一帧快照，在镜头切换清空预览后收到新帧时，以 0.24 秒淡出；等待超时也会清理快照，避免失败后挡住实时画面。普通实时预览帧更新和转盘连续变焦不附加动画。

78 项模拟器测试通过，0 失败；新增固定焦段点击测试覆盖不展开转盘、收起已打开转盘、回到固定倍率、预览过渡快照清理和重复点击当前倍率。generic iOS 目标编译通过，禁用签名。长按与短按的实际触摸竞争、物理镜头切换观感仍需真机体验。

## 固定焦段短按修复与完整圆形转盘

2026-10-13：移除拦截 UIButton 短按的 SwiftUI 高优先级组合手势。CameraFocalButton 使用原生 UIButton 的 touchUpInside 切换固定焦段，UILongPressGestureRecognizer 在按住 0.4 秒后接管拖动；长按识别成功会取消按钮短按跟踪。松开仅结束拖动，盘外点击收起的行为保留。新增测试直接验证 UIButton 点击事件绑定、长按识别器配置、短按/长按互斥、拖动和取消行为。

转盘背景改为完整圆形，下半圆延伸到下方界面背后，由预览框边界裁切。圆形按实际预览宽度计算半径；4:3 位于预览框底部，16:9 为框内曝光区留出底部空间，两种布局均经过截图核对。截图：`Preview/Zoom-Full-Circle-4-3.png`、`Preview/Zoom-Full-Circle-16-9.png`。

全量 81 项模拟器测试通过，0 失败；补充原生按钮事件绑定验证后，4 项 CameraFocalButtonTests 再次通过，0 失败。最终 generic iOS 构建通过，禁用签名。按钮触摸竞争、震动及硬件镜头切换仍需真机体验；截图核对只验证布局。

## Xcode 即时诊断整理与转盘下移

2026-10-13：Xcode 编辑器原显示 4 处即时诊断：ZoomDialBoundsKey 未找到、ZoomDialOutsideSurface 两处未找到，以及复杂表达式检查超时。将辅助类型放至 CameraView.swift，盘外收起区域独立为 ViewModifier，底部弹窗独立为计算视图。编辑器问题导航器的四处提示已消失，完整 generic iOS 编译及最终模拟器、iPhone 目标编译均通过。

按用户确认保留刻度与倍率、少显示空白圆盘：转盘半径继续按预览宽度计算，圆心下移，可见操作区域缩短至 100 点。4:3 位于预览框底部，16:9 位于框内曝光栏上方。两种比例均经模拟器截图核对：`Preview/Zoom-Lowered-4-3.png`、`Preview/Zoom-Lowered-16-9.png`。

## 2026-10-14 真机反馈、通用崩溃修复与压力测试

相机工具栏、焦段、A/M、辅助工具、参数和滤镜等控件缩小，底部五个按钮保留原尺寸。相册入口本次拍过照片时先进入当前照片，返回进入图库；没有当前拍摄照片时进入图库。照片查看统一使用 UIScrollView 支持 1–6 倍双指缩放、放大后拖动及双击切换缩放。缩放只改变同一张预览图的显示变换，不重复解码 RAW。

移除变焦盘和普通弹窗遮罩对其他入口的拦截，通过统一的模型入口收起旧面板，支持变焦、比例、格式、影调、手动参数、滤镜、功能、辅助及设置之间直接切换。预览框的模式和辅助按钮位于转盘上层。进入相册/设置暂停相机，返回恢复。照片加载请求的取消操作改为幂等；过期详情、编辑回调不再更新退出后的界面。

从连接的 iPhone 读取了 2026-10-13 18:53–18:56 的 7 份 LumaCamera 崩溃记录，均为 SIGABRT，触发栈均为 AVCaptureFigVideoDevice.temperatureAndTintValuesForDeviceWhiteBalanceGains → CameraEngine.captureOutput。SDK 头文件说明非法白平衡增益会抛 Objective-C NSRangeException，Swift 错误捕获无法处理此类异常。现读取前检查 RGB 增益均有限且落在 [1,maxWhiteBalanceGain]，无效值跳过转换并显示未知白平衡；手动写入也检查有限值并限制范围。这是各拍摄格式共用的预览路径，不能归因为 RAW 独有问题。

照片预览长边限制在 2400 像素（边框可能略增加尺寸），Core Image 预览改为立即渲染，避免保留大尺寸 RAW 延迟渲染链。导出和保存照片仍使用原输出分辨率，DNG 原始资源保持不变。原始图与预览图分别处理，边框导出使用完整分辨率画布。

验证：最终 90 项模拟器测试通过，0 失败；真机签名构建通过并安装到连接的 iPhone 17 Pro。修复版启动数分钟后两次查询均保持同一进程，期间检查崩溃目录没有新增 LumaCamera 日志。此启动观察不是完整真机 UI 或 RAW 拍摄压力测试。未在用户系统相册执行实际删除；删除测试使用延迟回调替身。

新增 8 项压力测试覆盖：12,100 组异常白平衡增益组合、500 轮多入口弹窗切换、1,000 轮相册入口状态切换、1,000 次缩放/平移及视口变化、48MP 尺寸来源的有限预览与原始 RAW 资源保留、120 次全部照片格式与滤镜比例组合编码、1,000 次详情加载退出后延迟回调、100 轮保存删除各重复点击 20 次及失败重试。RAW 资源使用测试字节验证保留，不能代表传感器 DNG 解码测试。现有测试继续覆盖编辑、图库分页权限、自动保存、参数恢复、滤镜强度、变焦队列、预览隔离等功能。

截图核对：`Preview/Capture-Direct-Detail-Oct14.png`（模拟器演示拍照、自动保存及真实入口打开详情）、`Preview/Camera-Compact-Wide-Oct14.png`（16:9）、`Preview/Camera-Compact-Manual-Oct14.png`（4:3 M）。真机完整的拍照→相册→缩放路径、iCloud 照片、权限弹窗和长时间连续拍摄仍需操作验收；自动测试不能保证所有误操作都不会崩溃。

## 新拍照片只自动打开详情一次

2026-10-14：按最新确认的入口规则，拍摄成功后设置本次运行内的待查看标记。首次点击相册消耗标记，打开最后拍摄照片详情；返回相机再点击相册进入照片列表。再次拍摄才重新设置标记，编辑当前照片、保存完成及重复点击入口不会重新设置。删除当前照片会清除标记。标记只存在模型内存中，正常后台保留；应用被杀后重建模型默认进入照片列表。

21 项针对性测试通过，0 失败，包含 4 项新的首次/重复/再次拍摄、编辑不重置、模型重建、保存期间拒绝新照片回归测试，8 项压力测试和 9 项照片保存删除测试。现有入口压力测试扩展为 1,000 轮每次拍摄后再打开相册 5 次，验证只有首次进入详情。generic iOS 和真机签名构建均通过。

## 相机弹窗统一淡入淡出

2026-10-14：顶部格式/比例/影调、底部参数/滤镜/功能/辅助以及变焦盘统一使用 opacity 进出场过渡。移除顶部滑动缩放、底部上移和转盘缩放，共用 0.22 秒 easeInOut，减少动态效果开启时使用 0.16 秒。滤镜强度控件也显式使用 opacity 过渡。页面导航与系统提供的 sheet/alert 继续由系统管理。真机签名构建通过；本次为动画样式调整，未重复功能压力测试。

## 拍摄模式黑色玻璃弹窗

2026-10-14：移除拍摄模式面板顶部的标题和关闭按钮，保留模式网格。背景使用超薄材质模糊，叠加 80% 不透明度黑色层、轻微表面高光与细边缘高光，并添加柔和阴影。点击预览区域或切换其他功能仍可关闭，进出场继续淡入淡出。模拟器与真机签名构建通过，截图核对：`Preview/Shooting-Mode-Black-Glass.png`。

## 按 IMG_1732 修正拍摄模式玻璃质感

2026-10-14：此前 80% 黑色覆盖层叠加材质使弹窗近乎不透光。按用户新参考图改为深色超薄材质及 18%–32% 黑色纵向渐变，保留背景模糊后的颜色透光；增加沿左上至右下变化的细边缘高光和内侧暗边。非当前模式标签对比度提高，仍保持未实现功能禁用。无标题、无关闭图标与淡入淡出保留。模拟器与真机签名构建通过，模拟器截图核对：`Preview/Shooting-Mode-Translucent-Glass.png`。颜色随实时背景变化；模拟器演示画面不能代替真实场景质感验收。

## 拍摄模式玻璃染色匹配主题蓝

2026-10-14：仅将拍摄模式玻璃表面的黑色渐变染色替换为 AppTheme.popupColor 深蓝色。渐变不透明度继续为 18%–32%，原生模糊材质、透光程度、高光、内侧暗边、阴影及动画参数全部保留。真机签名构建通过。

## 增强灰蓝色辨识度

2026-10-14：原 AppTheme.popupColor 过暗，薄染色层在材料上不明显。将染色渐变改为 RGB (0.20,0.34,0.53) 至 (0.12,0.24,0.40)，仍保持 18%–32% 不透明度，其他模糊、透光、高光、阴影与动画参数不变。模拟器截图确认可辨认灰蓝色：`Preview/Shooting-Mode-Blue-Glass.png`，模拟器与真机签名构建通过。材质仍会透出取景画面的颜色，因此实际色彩会随背景变化。

## 统一其他弹窗灰蓝玻璃背景

2026-10-14：将确认的灰蓝材质提取为 PopupGlassBackground，保持 RGB 渐变、18%–32% 染色不透明度、超薄材料模糊、表面高光、细边缘高光、内侧暗边与柔和阴影一致。应用到拍摄模式、手动参数、辅助工具、格式/比例/影调、滤镜、变焦圆盘、应用设置，以及照片信息和编辑 sheet 背景。各面板形状、布局和已有淡入淡出保持；普通预览控件和图库按钮继续使用原有较轻的背景。

模拟器与真机签名构建通过。参数和滤镜弹窗截图核对：`Preview/Shared-Blue-Glass-Parameters.png`、`Preview/Shared-Blue-Glass-Filters.png`。这是外观修改，未重复功能压力测试。

## 点击对焦、曝光锁定与全部画面比例核对

2026-10-14：点击预览选择对焦目标；长按对焦框先对该位置测光，再锁定曝光，显示 AE 锁定状态；双击锁定框解除曝光锁定。显示对焦框时提供小太阳 EV 滑块，也支持预览画面纵向拖动调节，范围 −5…+5 EV。横向滑动继续沿用滤镜操作。锁定框保持显示，未锁定时自动淡出；切换目标、镜头、比例和离开拍照界面清除旧目标及锁定。锁定是所选位置的曝光锁定，不包含物体移动追踪。

按用户要求核对全部 7 种比例：4:3、1:1、3:2、16:9、2:1、2.35:1、XPAN。每种比例分别检查中央和靠边目标，共 14 张模拟器截图；最终核对图及原图保存在 Preview/Focus-All-Ratios。修复窄比例下原生焦段按钮宽度适配，并让 AE 提示、小太阳避开顶部工具栏、顶部标签与底部曝光栏。全部比例与四角的边界约束以及 1–6 个焦段按钮的宽度纳入自动测试。未来界面验收要求见 Docs/Camera-UI-QA.md。

全量 100 项模拟器测试通过，0 失败；最后的标签与控件避让调整后再次运行 6 项 FocusExposureTests，0 失败。覆盖对焦/锁定/EV/解锁、旧计时器、500 轮快速操作、非有限输入及全部比例布局边界。最终真机签名构建通过并安装到连接的 iPhone 17 Pro。截图与测试使用演示预览，真实场景测光、长按/双击手势和曝光效果仍需真机操作验收。

## A/M 按钮与变焦横向对齐

2026-10-14：A/M 从右侧纵向按钮组移到变焦左侧，与右侧拍摄辅助按钮同一水平线，两边保留相同边距，变焦居中。可用焦段宽度扣除左右按钮及间距。7 种画面比例截图均已核对，见 Preview/Mode-Alignment-All-Ratios；6 项 FocusExposureTests 通过，真机签名构建通过。本次也包含未锁定白色、锁定成功黄色的对焦框。

## 照片详情与可供边框读取的拍摄参数

2026-10-14：统一当前拍摄照片与系统图库详情的信息来源。当前照片改为读取实际编码资源尺寸、像素和格式，不再用长边受限的内存预览图尺寸代替成片；RAW+JPG 分别显示资源信息。原始拍照输出读取相机/镜头型号、实际及35mm等效焦距、ISO、快门、光圈等 EXIF。快门回调记录 A/M、实际启用主镜头、倍率和原生分辨率能力匹配；能力匹配明确标为诊断信息，不能保证最终处理流程。

新增 PhotoCaptureParameters 数值结构，保存拍摄时间、镜头、曝光、白平衡、对焦、闪光灯和取景处理设置等供后续边框使用。最终 EXIF 数值与设备状态采样分别存储；未提供值保持未知。随 CapturedPhoto 传递，相册保存成功后在本机应用支持目录按资源 ID 原子保存；当前照片与图库详情可读取，重启恢复、编辑保留原始拍摄参数。数据范围和限制见 Docs/Photo-Capture-Parameters.md。

完整 109 项模拟器测试通过，0 失败，包括 9 项新测试：EXIF 解析及缺失/异常值、真实输出尺寸的全部7种比例、资产标识隔离及存储重建、存储失败、去重合并、编辑保留与新照片不继承旧记录、数字精度和 RAW/处理后 EXIF 优先级、旧记录兼容。真机签名构建通过，并安装到连接的 iPhone 17 Pro。

7种比例均走模拟器演示拍照→自动保存→当前照片详情，截图见 Preview/Capture-Details-All-Ratios。模拟器详情明确显示无真实镜头信息。未在真机执行本次逐档拍摄；2×/4×/8×的实际镜头、RAW 和处理后输出信息仍需真实场景拍摄核对。测试未修改或删除用户真机相册照片。

## 切换固定焦段保留 M 挡参数

2026-10-14：定位到 selectedLens 订阅在物理设备变化时，固定焦段分支调用 resetParameters，而连续变焦分支保留参数。统一为 didChangeLensDevice，保留曝光、白平衡和对焦的手动/自动状态及 EV、白平衡与对焦数值；ISO 和快门仅限制在新镜头支持范围内，重新应用到设备。显式重置入口继续沿用原行为。

32 项相关测试通过，0 失败，含 3 项新回归：跨主摄/长焦/超广角保留手动参数并往返 A/M、不同曝光能力范围下上下限收敛且不切自动、500 轮切换保留混合自动/手动状态。真机签名构建通过。未修改界面布局，未重复截图；实际硬件参数应用需真机拍摄确认。

## M 挡切焦段回 A 挡卡死：NaN 快门显示崩溃

2026-10-14：在用户保留的 Xcode 调试现场确认，Thread 1 停在 CameraViewModel.shutterText，参数 seconds = NaN；控制台为 Double value cannot be converted to Int because it is either infinite or NaN。界面无响应是致命错误后的调试暂停，不是已证实的相机队列死锁。CoreMotion.plist 无权限警告与这个致命转换无关。附加两次采样无运行样本，与调试暂停现场一致；没有把空采样当作死锁证据。

新增 CameraNumericText 对 NaN/无穷/越界整数/无效快门显示未知；ISO 与白平衡显示统一安全转换。CameraReadings 在发布前校验曝光和对焦，白平衡无效时标记未知；镜头连接配置增加读数代次，停止或换输入后丢弃旧镜头的迟到读数。参数编辑拒绝非有限值，不把坏读数同步到用户设置。设备能力读取在 session 队列完成，主线程仅发布不可变快照；曝光写入校验硬件边界。

完整模拟器测试共118项，117通过、1项真机专用测试跳过，0失败。新增精确 NaN 快门崩溃回归、数字极值及参数显示、无效传感器读数、2,000轮迟到帧/停止状态检查、无效参数输入、500轮模式/镜头/生命周期混合操作。全部7种比例的拍摄读数栏布局已核对，截图见 Preview/Readings-Safety-All-Ratios；4:3 首次截图遇到启动白屏，等待启动完成后重新核对，最终存档为有效画面。

真机专用回归覆盖三轮全部后置焦段往返、重复点击与回 A 挡，要求有效读数和预览恢复；不执行拍照或相册删除。首次真机测试因测试目标缺少开发团队而未编译，指定项目现有团队后编译成功；测试安装停滞并已取消，设备安装命令60秒超时。已结束原卡在致命错误处的相机进程，设备查询显示 passcodeRequired=true。当前等待用户解锁后安装/验证，不把编译或模拟器结果记为真机通过。

## 相册入口最新缩略图与左上角直方图

2026-10-14：相册按钮读取系统相册按拍摄时间降序排列的第一张可访问照片，申请160×160缩略图，不解码完整RAW。当前新拍照片在自动保存完成前立即显示本次预览。应用回到前台、从图库返回、保存完成及PhotoKit变更后刷新；请求代次与取消机制防止旧图片覆盖新结果，最后一张被删除后清空。未授予读取权限时不在拍照入口主动弹授权提示，保留图标/当前拍摄照片回退；有限权限只读取可访问范围。

直方图从右上移至预览框左上，滤镜名称留在右上。64档亮度分布轻度平滑后绘制峰谷曲线和渐变填充，增加低对比度网格与基线，116×56点背景。保留测量数据，不人为生成峰谷；非法图形输入限制到有效范围。比例内嵌工具栏时下移避开工具栏；上方对焦目标出现时暂时隐藏顶部HUD以避免重叠。全部7种比例的缩略图截图见Preview/Album-Thumbnail-All-Ratios；直方图与靠边对焦共14张见Preview/Histogram-All-Ratios。

补充自动EV滑块的界面更新保护：相同值不重复发布，真实变化延后至下一主队列，合并快速回写并丢弃模式切换后的旧请求。1项新增回归验证布局回写不立即发布、最新值生效及M挡不会接收过期A挡回写。5项缩略图回归覆盖单张小图、权限、取消/迟到、外部删除和拍照即时显示。测光选项代码行为与限制见Docs/Metering-Behavior.md。

最终完整模拟器回归124项：123通过，1项真机专用测试跳过，0失败；最终图形输入限制为外观防御调整，随后模拟器编译与全部比例截图核对通过。真机测试包编译通过。

## 真机切换回归最终完成

2026-10-14：设备解锁、重连后恢复测试安装。早期真机回归曾通过一次；再次验证出现相机ready=false、读数未恢复，不能据此前一次通过判定稳定。检查发现测试另建CameraViewModel，额外启动第二个AVCaptureSession，与可见App的相机竞争。修正为DEBUG下从组合根读取App实际相机模型，测试操作同一套真实会话；测试期间临时保持屏幕唤醒，结束恢复原值。

最终PhysicalCameraSwitchingTests在iPhone17Pro通过，1项测试0失败，用时21.333秒。执行3轮全部后置焦段来回选择（含重复点击）及M→A，验证手动状态保留、返回A后有效CameraReadings与预览必须恢复。最终日志未再出现NaN致命错误或Publishing changes from within view updates警告。结果包/private/tmp/LumaSingleSessionPhysicalResult.xcresult，摘要为Passed/1通过/0失败/0跳过。测试通过调用实际界面模型驱动AVFoundation，不等同于手指/手势的完整UI自动化，未拍照或删除真机相册资源。

最新版本已由测试安装到真机，结束后尝试正常启动供用户使用。未来操作边界与全部比例要求继续见Docs/Camera-Interaction-QA.md和Docs/Camera-UI-QA.md。


## 2026-10-14：参考 IMG_1750 的直方图、RAW 标记与 Tint

- 直方图改为预览左上角的 80×39 pt 半透明小窗，128 档亮度分布、细白色折线和轻填充，保留真实波峰波谷；顶部工具栏覆盖画面时避让工具栏。
- 相册网格右下角标记 RAW，检查全部 PhotoKit 原始资源，包含 RAW+JPEG；刚拍摄且未保存的 RAW 资源也显示标记。
- M 挡新增绿色—洋红 Tint（−150…+150），与色温共同控制硬件白平衡；切换焦段及 A/M 保留参数和自动/手动选择。快门时实际色调加入照片详情，原有结构化参数继续保存。
- 六个拍摄参数按钮改为 42 pt 圆形，手动项保留浅橙色状态。
- 完整模拟器回归：126 项，125 通过、1 项真机专项按预期跳过，0 失败。日志 `/private/tmp/LumaReferenceTintTests.log`。
- 真机 iPhone 17 Pro 专项：1 项通过，连续三轮手动曝光及 Tint 设置、后置全部可用焦段正反向切换/重复点击、回到 A 挡恢复实时读数。无拍摄或删除用户照片。日志 `/private/tmp/LumaReferenceTintPhysicalTests.log`；结果 `/private/tmp/LumaReferenceTintPhysicalResult.xcresult`。
- 已检查 4:3、1:1、3:2、16:9、2:1、2.35:1、XPAN，包含直方图/圆形按钮和 Tint 弹窗共 14 张截图，见 `Preview/Reference-1750-All-Ratios/All-Ratios.png`。
- 真机版本已通过测试安装；模拟器画面只用于布局核对，色彩效果以设备实际白平衡和 RAW 解码软件为准。


## 2026-10-14：直方图连续性、前置切换与固定倍率开销

- 直方图由每 0.4 秒一次改为独立串行队列最多 20 Hz、只保留最新帧；单独 CIContext，不在预览渲染队列等待统计。128 维波形向量进行 0.10 秒连续插值，减少动态跳变；减少动态效果设置下直接更新。
- 输入切换期间暂停接收预览帧，按镜头代次与连接完成时间丢弃旧帧；预览连接固定不镜像，Core Image 统一处理肖像方向与前置镜像。照片输出连接继续单独设置，不改照片保存处理逻辑。
- 同一设备的固定倍率切换跳过方向/镜像重配置；照片输出只在设备改变或 RAW 资格相关倍率边界变化时刷新。预览节流改为接近 30 Hz，避免此前 30 fps 输入因 1/24 秒阈值降为约 15 fps。
- 完整模拟器最终回归 129 项：128 通过、1 项真机专项跳过、0 失败。涵盖镜像像素方向、插值边界/无效数值、过渡帧时间门控以及原有滤镜、对焦、曝光、焦段、照片保存与相册逻辑。日志 `/private/tmp/LumaSmoothPreviewFinalTests.log`。
- 全部七种比例截图已复核，直方图与参数弹窗无布局变化，见 `Preview/Histogram-Smooth-All-Ratios/All-Ratios.png`。
- 真机第一轮在新增前置断言下发现横向缓冲帧被过度过滤，已修正为统一预览方向处理；第二轮受到锁屏/相机中断影响，不能作为修复验证。
- 解锁后真机第三轮通过（23.856 秒）：三轮全部后置焦段正反向/重复点击与 M/A 往返、六次前后镜头切换且恢复肖像预览/有效读数、直方图开启 2 秒内至少 8 次有效更新（超过旧版约 2.5 Hz）。结果 `/private/tmp/LumaSmoothPreviewPhysicalResult3.xcresult`；日志 `/private/tmp/LumaSmoothPreviewPhysicalTests3.log`。已安装修复版。该测试验证画面持续恢复与更新频率，实际切换观感仍需用户拍摄场景体验。


## 2026-10-14：预览任意位置长按对焦并锁定 AE

- 长按预览空白区域 0.5 秒，使用起始触点直接定位对焦目标并请求 AE 锁定，不再要求先出现对焦框。长按与短按互斥，松手不追加一次普通对焦导致解锁；移动超过 12 pt 交由原有拖动交互。
- 原有对焦框长按/双击解锁、小太阳 EV 和预览上下调 EV 保留。弹窗可见时首先关闭弹窗，避免误操作背景锁定；拍摄中/相机未就绪/无效坐标继续忽略。
- 改动仅限手势入口和既有对焦方法的可选锁定参数，复用现有 CameraEngine 对焦/测光/延迟锁定管线，未修改曝光参数、镜头及图像处理代码。
- 完整模拟器回归 131 项：130 通过、1 项硬件专项跳过、0 失败。新增七种比例下无现有框首次锁定、重新锁定其他目标、无效/不可用输入等测试；原有单击对焦、EV、双击对应解锁动作、锁定定时器、500 次快速操作测试通过。日志 `/private/tmp/LumaPreviewHoldTests.log`。
- 已核对七种比例的居中/边缘锁定框与 EV 控件截图，见 `Preview/Preview-LongPress-All-Ratios/All-Ratios.png`。截图调用真实模型锁定入口，不能代替触摸手势的人工体验。
- 真机编译及安装成功，保留现有应用数据。日志 `/private/tmp/LumaPreviewHoldPhysicalBuild.log`、`/private/tmp/LumaPreviewHoldInstall.log`。本次未增加真机触摸自动化测试。


## 2026-10-14：精简弹窗与前台常亮

- 滤镜分类只保留全部、收藏；全部仍包含全部原有滤镜，收藏数据沿用既有存储。
- 拍摄辅助弹窗移除顶部标题及 X；功能按钮和既有点击预览/切换其他弹窗的关闭行为保留，玻璃背景不变。
- App 根场景 active 时禁用系统自动锁屏，inactive/background 恢复系统计时；在应用内相册和设置中同样常亮。
- 完整模拟器回归 131 项（130 通过、1 项真机专项跳过），0 失败；测试收藏兼容性整理后，另跑 FilterPickerTests 4 项通过。日志 `/private/tmp/LumaTabsAwakeTests.log`、`/private/tmp/LumaTabsFinalFilterTests.log`。
- 七种比例共 14 张滤镜/辅助弹窗截图已核对，见 `Preview/Tabs-Tools-All-Ratios/All-Ratios.png`。真机编译及安装成功，日志 `/private/tmp/LumaTabsAwakeInstall.log`。
- 用户明确暂缓 4800 万像素修改；现有 A/M 分辨率能力判断与拍照配置保持原样，本轮临时能力检查已移除，未执行硬件探测。


## 2026-10-14：拍摄定位、参考 IMG_1754 的详情卡片与触感

- 前台相机使用 When In Use 定位授权，10 m 期望精度、无后台定位；相机隐藏/后台停止更新。只记录 60 秒内有效坐标与非负定位精度，无权限/无有效定位不阻塞快门和保存。
- 拍照前快照位置；AVCapturePhotoSettings GPS 元数据覆盖 RAW/原生资源，PhotoEncoder 为 JPG/HEIF/TIFF/HDR HEIF 写入 GPS，不重新编码 RAW；PHAssetCreationRequest.location 同时保存系统照片位置，快门参数 sidecar 存储数值位置供以后边框使用。
- 历史照片从 PHAsset.location、文件 GPS、已有应用拍摄记录依次读取；不会用当前设备位置伪造旧照片地点。地址异步逆地理编码，失败显示坐标；地图使用系统 MapKit，保留地图归属标识。
- 详情改为照片下方的日期卡、设备/尺寸/大小/文件名卡、六个参数卡与位置地图。更多诊断信息可展开，保留缩放、分享、编辑、删除及返回相机；隐藏保存状态和像素设置展示，requestedMegapixels 数值继续保留。
- A/M 有效模式变化、拍摄辅助按钮提供轻触感；水平进入 0.025 rad 内并稳定约 0.2 秒反馈，0.05 rad 退出滞回、1 秒冷却，启动时已水平不重复反馈。
- 完整模拟器最终回归 137 项（136 通过，1 个物理相机专项跳过），0 失败，日志 `/private/tmp/LumaLocationInfoFinalTests.log`。随后新增 HDR HEIF/RAW+JPG GPS 检查，并运行 PhotoLocationTests + LevelHapticGateTests 共 7 项，全部通过，日志 `/private/tmp/LumaLocationHDRFinalTests.log`。
- GPS 编码测试覆盖 JPG/HEIF/TIFF 的全部七种比例；其他测试覆盖新鲜/过期/无效坐标、南/西半球与海平面以下、JSON 保留、无定位不写 GPS、RAW 字节不变、保存失败重试/编辑后定位与快门时间保留、水平震动防抖。
- 七种比例详情截图见 `Preview/Location-Details-All-Ratios/All-Ratios.png`。带坐标截图仅使用 DEBUG 模拟器明确启用的布局样例，非用户真实位置，也不会写入实拍照片。
- 最终真机编译及安装成功：`/private/tmp/LumaLocationInfoPhysicalFinalBuild.log`、`/private/tmp/LumaLocationInfoFinalInstall.log`。定位授权、实际 GPS 接收及真实震感仍需设备使用验证；未自动接受用户定位权限。
- 按用户要求，4800 万分辨率逻辑未改动。


## 2026-10-14：详情上滑覆盖、参考线、快门与高 ISO 色彩保持

- 详情面板从照片下方上滑覆盖，使用独立 overlay，不替换 ZoomablePhotoView、不改变照片布局尺寸；保留缩放对象与缩放状态。再次点详情、点未覆盖区域、点/下滑顶部把手可收起。详情按用户最新要求采用滑动过渡，减少动态效果时淡入淡出。
- 参考线白色透明度 0.23→0.42、线宽 0.5→0.75 pt，增加轻微暗描边。其他预览内容不变。
- 快门数值沿用 log2(seconds)，将拖动映射集中为 CameraRulerMapping，并用测试确认左滑减慢、右滑加快；ISO 等其他刻度方向保留。
- 后置 M/A 路由切换沿用旧帧淡出过渡，连接完成后新预览恢复；辅助弹窗不参与预览框的布局动画。DEBUG 实际预览几何测试覆盖全部七种比例：M→A 后打开辅助，预览矩形完全一致。
- 用户明确偏黄在原片、自动 WB、最高 ISO、预览与照片都出现。初次 100–1600 扫描不足以覆盖条件；另一轮记录出现白平衡增益变化，不能直接当成滤镜问题。
- 新增 ExposureWhiteBalancePolicy：只针对自动白平衡 + 自定义曝光，预计过曝超过 1 EV 时保持最近可靠的设备白平衡增益；实际曝光恢复到 0.5 EV 内并稳定后继续自动 WB。手动色温/色调不参与自动保护；切换镜头清除旧设备增益，重新选择 WB 自动时允许重新测量。没有可靠参考值时不制造白点；曝光造成的高光溢出无法恢复。
- 处理前先稳住硬件增益，因此预览、处理照片、RAW 记录使用同一设备白点；未给原片额外加冷色滤镜。照片详情区分“自动（高曝光色彩保持）”和手动锁定。
- 模拟器完整回归 142 项：140 通过、2 项硬件专项跳过，0 失败（`/private/tmp/LumaWhiteBalanceGuardTests.log`）。等待曝光稳定的最终修整后，另跑曝光策略、CameraViewModel 和读数安全共 22 项全部通过（`/private/tmp/LumaWBGuardFinalTests.log`）。
- 最终 iPhone 17 Pro 真机两项专项通过（27.724 秒）：固定场景 ISO 100→400→1600→6048→12096→100，400–12096 时 RGB 增益保持 2.3393555 / 1 / 1.9309082，ISO 100 时解除保持并恢复 continuousAutoWhiteBalance；界面仍为自动 WB。另通过三轮全部后置焦段、M/A 往返、六次前后切换和直方图刷新回归。没有拍摄/删除用户相册资源，诊断预览仅存 XCTest 临时附件。
- 真机日志 `/private/tmp/LumaWBGuardPhysicalTests.log`，结果 `/private/tmp/LumaWBGuardPhysicalResult.xcresult`。安装由 test-without-building 完成；之后尝试正常启动，见 `/private/tmp/LumaCameraGuardNormalLaunch.log`。
- 全部七种比例截图：`Preview/Info-Overlay-All-Ratios/All-Ratios.png` 与 `Preview/Grid-Transition-All-Ratios/All-Ratios.png`；前者使用明确 DEBUG 模拟器位置样例。


## 2026-10-14 移除曝光驱动的白平衡保护

按用户要求撤销过曝时保持自动白平衡增益的策略，恢复系统连续自动白平衡。删除保护策略和对应阈值测试；真机 ISO 扫描测试改为核对整个范围持续自动白平衡、ISO 写入和固定快门。此前记录的保护策略不再代表当前实现。

验证：模拟器完整回归共 141 项，139 项通过、2 项硬件测试跳过、0 失败；真机构建成功。真机 ISO 扫描暂被设备锁屏阻塞。日志：/private/tmp/LumaRemoveWBGuardTests.log、/private/tmp/LumaRemoveWBGuardPhysicalBuild.log。

设备解锁后真机 ISO 扫描已通过：100–12096 全程 continuousAutoWhiteBalance，实际 ISO 在容差内、快门保持约 1/125 秒。更新版本已通过测试流程安装。该扫描验证参数与模式，不作为固定光线下颜色观感结论。结果：/private/tmp/LumaRemoveWBGuardPhysicalResult.xcresult。


## 2026-10-14：手动曝光预览 HDR 与快门刻度排列

- 用户确认快门要求为刻度左侧慢、右侧快。为快门单独反转刻度分数和拖动映射，保持转盘跟随手指与中心指针一致；ISO、色温等其他刻度保留原方向。无障碍提示同步改为刻度排列说明。此前左滑变慢的记录被本次用户澄清取代。
- 真机固定电脑屏幕 A/B：实际 ISO 12096、约 1/125 秒，默认 HDR 开启时 64×64 亮度采样中 0 个像素大于 250/255，HDR 关闭后 1918 个，再恢复 HDR 后 0 个。全局影调单独切换无明显改善。日志 /private/tmp/LumaISOToneScreenTests.log；附件位于 /private/tmp/LumaISOToneScreenResult.xcresult。第一轮几乎全黑未取到屏幕的场景不用于亮度结论。
- 自定义曝光关闭视频 HDR，恢复自动曝光时还原设备原始 HDR 策略；不更改照片格式 HDR、自动白平衡或全局影调，也不人为加亮预览。跨镜头保持该策略，避免每次 ISO 拖动重新配置。
- 完整模拟器回归 141 项：139 通过、2 项硬件测试跳过、0 失败。日志 /private/tmp/LumaManualSDRFullTests.log。真机最终两项专项通过：ISO 100–12096 扫描、WB 自动、手动 SDR 与自动 HDR 策略恢复、三轮后置焦段/A-M 往返、前后镜头和直方图回归；无保存/删除照片。结果 /private/tmp/LumaManualSDRPhysicalResult.xcresult。
- 真机构建成功并由测试安装，已正常启动。七种画幅快门窗口逐一截图核对：Preview/Shutter-Scale-All-Ratios/All-Ratios.png。单元测试验证慢快门位于快快门左侧，以及手势与反向刻度一致。
- 当前证据确认默认视频 HDR 是本次亮度差异的一个可复现原因，不证明何时引入，也不证明和目标 App 所有输出完全相同。照片资源/RAW 亮度与高 ISO 色彩仍需单独验证。


## 2026-10-14：高 ISO 亮度差异仍未解决，成片链路诊断

用户提供 IMG_1775/1776 相册详情截图：极影 HEIC 1/50 秒、ISO 12096、24mm、f/1.78，光屿 JPG 1/50 秒、ISO 12500、24mm、f/1.78，极影明显更亮。约 0.05 EV 的 ISO 差距不能解释该差异。用户补充预览阶段即偏暗，前一轮预览 HDR 修复不是完整解决方案，不再表述为已解决。

固定场景真机诊断仅写 XCTest 临时附件，没有保存/删除相册照片：实际 ISO 12096、快门 0.019994 秒。分别拍摄默认局部影调、全局影调、恢复默认，且分别比较系统原始 JPG/HEIF 与光屿编码文件。EXIF 快门均 0.02 秒。64×64 sRGB 采样中原始 JPG 平均亮度 218.64696、编码后 218.65199；HEIF 原始 219.69604、编码后 219.68991；全局影调均约 219–220。重编码与格式未复现巨大差异，全局影调没有有效改善，不修改该产品策略。

诊断结果 /private/tmp/LumaPhotoExposureProbeResult.xcresult；日志 /private/tmp/LumaPhotoExposureProbeTests.log。相册只读查找所示拍摄时间窗口得到 0 个可访问资源，不能据此核对用户两张原图；该调用成功不等于已经读取到原图。现有附件为相册界面截图，不能检查真实成片的完整 HDR/成像元数据。需要未编辑照片原文件继续对比，不基于截图加入曝光补偿滤镜。

已删除临时原始照片回调、可变全局影调测试入口和两项探索测试，保留前一轮已验证的产品代码。当前未完成极影与光屿亮度对齐；没有声称修复。


## 2026-10-14：原图元数据发现输出模式不同

收到用户原图 FOTOR_20261014_171352.heic 和 Luma-122D3C4F-2463-4C6D-B31F-91EF72C3BE3C.JPG。ImageIO 确认极影 3024×4032、10-bit sRGB、1/49.998637 秒、ISO 12096、f/1.78、24mm；其 EXIF UserComment 中 FOTORCAM_META_V2 解码 JSON 明确 outputFormat="HEIF Pro"、isHDR=false、filterName="原图"。光屿 3000×4000、8-bit sRGB、0.02 秒、ISO 12500、同光圈焦距。两文件均无 HDRGainMap/ISOGainMap；极影 Headroom=1。曝光参数差距不足以解释亮度差异，输出模式差异需要单独核对。

统一 sRGB 8-bit 解码后 64×64 全图采样：极影平均亮度 240.038、>250/255 像素 2847/4096；光屿平均 193.197、326/4096。两图构图不完全一致，因此不是定量曝光标定，但可确认差异存在于普通解码像素，而非仅 HDR 显示。原始元数据 /private/tmp/LumaOriginalFileMetadata.txt；解码预览 /private/tmp/OriginalComparison-0.png 和 -1.png。未将原照片或 GPS 复制到项目。

JPG→HEIF Pro→JPG 诊断测试完成，但附件显示场景明显移动（首张模糊遮挡、中间运动、末张键盘），不可用其亮度数值证明格式造成的差异。结果 /private/tmp/LumaHEIFProComparisonResult.xcresult。已移除临时测试，不因此修改成像产品逻辑。

用户随后描述极影切回普通 HEIF 的新照片，但本次附件仍是同一路径、17:14:03 的 Luma JPG；读取元数据未发生变化。尚未获得极影普通 HEIF 新原文件，不据此下确定结论。


## 2026-10-14：M9 用户原始色表接入

使用用户 m9.png 替换 M9 模拟图像处理，512×512 sRGB 分块色表离线转为 64³ RGBA Float32 Xcode 数据资源；运行时缓存、GPU 应用，缩略图/预览/处理成片共用。强度 UI 和既有混合逻辑保持。NC=Classic Neg.、CC=Classic Chrome 先保留模拟配方，待对应色表。

完整模拟器回归共 144 项：142 通过、2 项硬件测试跳过、0 失败；包含 CPU/GPU 原始颜色点对照和透明度。日志 /private/tmp/LumaM9LUTFullTests.log。真机签名构建成功，安装并正常启动；本轮未声称进行实拍颜色标定。七种画幅逐一核对截图在 Preview/M9-LUT-All-Ratios/All-Ratios.png。原始色表来源、SHA256、排列和复现脚本见 Docs/Camera-Film-Styles.md。


## 2026-10-14：A/M 预览切换提速

让切换输入前即获得目标模式记忆的自定义曝光状态，消除旧状态导致的重复视频 HDR 重配置；取消待交付旧变焦并拦截过期代次。A/M 新帧一到立即移除旧帧遮罩，保留普通焦段的淡出。恢复重复选择当前模式时原有的参数重置/关窗行为；未采用无稳定提速收益的输入缓存。自动虚拟相机路由、M 挡物理镜头与分辨率能力保留。

相同记忆 ISO 400、1/125 秒的八次真机对照：新帧平均 1.285→1.001 秒（约 22%），完整过渡平均 1.346→1.008 秒（约 25%）。仍有系统输入切换耗时，不宣称完全无停顿。完整模拟器 145 项中 142 通过、3 项硬件测试跳过、0 失败；最终 UI 无淡出另跑 18 项模式及全部七种画幅布局检查通过。真机最终曝光/焦段专项与八次测速通过；最终版安装、正常启动。详细结果和限制见 Docs/Mode-Switching-Performance.md。


## 连续拍摄、相册缩略图与处理数量（2026-10-15）

快门曝光完成后即可接受下一次点击；系统照片回调、应用编码和相册保存分别管理。每次拍摄按原生 uniqueID 保留独立参数、RAW/处理图和位置，编码串行执行，结果按拍摄顺序交付。旧照片编码或保存完成不会解除新曝光的忙碌状态，也不会覆盖最新照片的保存身份。

待处理队列采用有界容量：普通照片最多 4 张，RAW/48MP 最多 2 张；相册写入串行排队，待保存及失败照片数量、内存预算共同限制新拍摄。满载时暂缓接受新拍摄，完成后恢复；这不是无限缓存或长按自动连拍。保存失败的资源在本次进程内保留，并提供重试入口，未增加跨启动磁盘暂存。

相册按钮右上角显示待处理与待保存照片数量，归零隐藏。缩略图在照片保存后继续显示当前拍摄预览，直到系统返回对应 asset 的缩略图；刷新不再先清空已有缩略图。

验证：完整模拟器测试 148 项，145 项通过、3 项硬件专用测试跳过，0 失败。新增阻塞编码测试确认 4 次曝光可先完成、编码和保存随后排队；队列满载拒绝额外请求，计数最终归零。保存失败/重试测试确认每张资源独立保留，旧任务完成不改变最新照片身份；缩略图测试模拟系统相册索引延迟和旧缩略图回调。

iPhone 17 Pro 真机：连续 4 张 JPG，待处理峰值 4；连续 2 张 RAW+JPG，每张均保留配对资源，文件名独立，计数归零。曝光/自动白平衡、8 次 A/M 切换及队列测试共 4 项通过；测试样张未写入系统相册。所有 7 种画幅已核对角标布局：4:3、1:1、3:2、16:9、2:1、2.35:1、XPAN。截图见 Preview/Processing-Badge-All-Ratios/All-Ratios.png；角标截图采用显式 DEBUG 布局参数固定显示 3，实际计数由上述管线测试验证。


## 对焦锁定防误触与照片详情左右切换（2026-10-15）

预览单击对焦在 AE 锁定中或已锁定时不再调用解锁，也不移动目标。双击对焦框仍解除锁定；显式长按新位置继续执行重新对焦并锁定。画幅、镜头、模式及生命周期变化时原有清理行为保留。

照片详情按当前相册列表顺序左右滑动切换，包括未被系统索引的刚拍照片。最新照片进入系统列表后按 asset ID 对齐，避免重复页面。切换只替换当前详情，不累加导航层级；返回仍进入照片列表。临近已加载末尾预取下一页，不在首尾循环。分享、编辑、删除、保存及详情面板操作期间不翻页。

单指左右滑动仅在完整画面比例触发；放大后拖动继续平移照片，双指缩放和双击缩放保留。更换照片重置缩放，旧页面销毁会取消加载，原有 generation 防止迟到的照片、元数据和资源回调污染新页面。翻页使用已有 2400px 预览，不重复解码 RAW。

完整模拟器回归：153 项，150 项通过，3 项硬件测试跳过，0 失败。新增测试覆盖全部 7 种画幅下反复单击已锁定目标、显式解锁后重新对焦、翻页首尾/过滤/空列表/资产索引延迟、缩放与翻页互斥及换图缩放复位。iPhone 17 Pro 上实际 AE 锁定防误触和 UIKit 翻页/缩放策略等 5 项测试通过。手指真实左右滑动的跟手体验仍需日常使用核对；上述 UIKit 测试验证识别器配置与回调规则，未自动注入真实触摸轨迹。


## 照片切换过渡与 RAW 滤镜规则（2026-10-15）

照片详情使用稳定的导航容器；目的照片预览准备好后，才执行约 0.28 秒的左右平移过渡。等待期间保留当前画面，失败保持原页并提示，取消或退出后的迟到回调不会翻页。过渡时拒绝重复切换，目的页带有预加载图片，继续接收系统高清预览而不闪回空白加载状态。分享/编辑/删除在等待目标预览时暂不可用，返回和相机入口仍可退出。减少动态效果开启时采用短淡入淡出。保留缩放、列表顺序与分页规则。

单独 RAW：禁用滤镜入口，关闭已打开的滤镜面板，预览与捕获上下文都绕过所选 FilmStyle，RAW 编码层也再次落实该规则。保存原先滤镜选择，切回可处理格式后恢复。RAW+JPG：滤镜应用于 JPG 和预览，DNG 字节原样保留；影调、画幅及边框的现有功能不改。格式说明同步区分这两种情况。

验证：完整模拟器回归 158 项，155 项通过、3 项硬件测试跳过，0 失败；额外实际视图动画测试通过，模拟延迟加载、前进与后退切换，确认等待时旧图保留、过渡时两页共存、完成后只有当前页。导出并核对过渡截图：Preview/Photo-Paging-Animation。使用纯色测试图片以显式观察页面接缝，无用户照片内容。iPhone 17 Pro 上 11 项队列、翻页、加载与 RAW 规则测试通过，其中实际连拍 4 JPG 及 2 RAW+JPG，样张未写入系统相册。RAW 字节保留、RAW 预览绕过滤镜及 RAW+JPG 输出滤镜由编码测试验证。


## 详情固定控件、RAW/地址标题、对焦提示及删除导航（2026-10-15）

照片切换调整为只有照片区域平移，顶部日期/地址/返回和底部五个按钮保持固定。外层页面不参与动画，新旧图片在有裁切边界的 viewport 内交接。继续预加载目标图片，保留双指缩放、放大后平移及快速连滑保护。界面测试在前进和后退动画中比较顶部/底部像素，确认固定区域没有跟随照片移动，并确认照片区两张图片参与过渡。

RAW 标识位于照片实际适配显示矩形的右下角，RAW+JPG 因含 RAW 资源也显示标识。标题中日期时间下方增加拍摄地址，使用相册资产已有 GPS 或刚拍照时记录的位置，不重新请求定位权限；地址解析期间或失败时显示坐标，没有定位则不显示地址行。地址请求随视图取消并缓存最近最多 100 个位置，分页不会因加载原图元数据而阻塞地址显示。

M 挡对焦刻度下方增加左侧 person.fill 人像、右侧 mountain.2.fill 山峰，分别表示近焦/远焦，不增加说明文字。依据当前 SDK AVCaptureDevice.lensPosition 文档：0 是最近端、1 是最远端；数值不是物理米数，1 也不承诺无限远。图标复用现有对焦数值方向，没有改变参数应用逻辑。

在照片详情删除成功后，优先转到列表顺序中的上一张；第一张没有上一张时转到下一张，最后一张删除后才回列表。删除前确定相邻目标，防止 Photos 刷新或当前拍摄资源清空造成索引偏移；取消系统确认或删除失败不导航。删除后暂存当前显示图片以等待目标预览，目标加载失败则回到列表。保留系统唯一删除确认，不增加 App 二次确认。

验证：最终完整模拟器回归 163 项，160 项通过、3 项硬件测试跳过，0 失败。真机详情、地址/标识布局规则、翻页/缩放、加载取消与 RAW 规则共 12 项通过，未删除真实照片。全部 7 种画幅核对 RAW 详情标识/标题和对焦图标，截图见 Preview/Photo-Detail-Fixed-Controls 和 Preview/Focus-Distance-Icons。截图使用测试图片与固定示例位置；对焦图标为低影响布局修改，复用既有对焦测试并额外构建、截图核对，没有新增镜像实现的单元测试。


## 参数震动、按钮防闪与删除动画方向（2026-10-15）

M 挡参数刻度经过普通刻度提供轻震，经过每五格的主刻度提供较强震动，力度沿用变焦盘 light/0.35 和 medium/0.8。仅用户拖动或辅助功能调整时触发，参数自动刷新不震动。抖动停留在同一刻度附近不重复震动，快速跨过多格合并为一次并优先主刻度。

照片预加载不再把底部工具按钮设为视觉上的忙碌状态，改为阻止对应操作命中，避免每次滑动出现变暗再变亮；返回和相机入口仍可退出。增加等待加载期间顶部/底部像素检查，继续核对动画中固定区域。删除后显示上一张的动画按用户要求统一从右向左进入。

30 秒多帧慢门已由用户明确暂缓，不实现采集或合成，也不开放虚假的 30 秒快门数值。真机诊断读取当前主摄 activeFormat 最大单次曝光及所有可用格式最大值均为 1.0 秒。App 维持原有真实硬件范围（最多 1 秒）。该诊断没有保存照片。

验证：164 项模拟器完整回归，161 项通过、3 项硬件专用跳过，0 失败；新测试覆盖 ISO/快门/白平衡/色调/对焦/EV 范围、反向快门刻度、跨格合并与抖动抑制。真机 9 项曝光上限诊断、刻度逻辑、删除导航和 RAW 规则测试通过。之后仅撤回 30 秒范围上限代码至原实现并重新构建，不重复无关测试。实际震动力度需用户手持手机体验；自动化测试验证反馈触发规则。


## 可持久保存的滤镜参数编辑（2026-10-15）

实现色彩、明暗、效果三个选项卡及参考图参数，支持实时预览和处理照片；色调分离/HSL 入口隐藏。每款滤镜配方与最后选择持久保存，只有明确重置当前滤镜才恢复默认。可选目录仅原片和 M9；原片浓度显示“—”、不参与处理。RAW 不应用配方，RAW+JPG 保持 DNG 字节不变。对焦人像/山峰放大，电影静帧/多重曝光入口移除，夜间模式仅预留。

最终完整模拟器回归 171 项，168 通过、3 项真机专用跳过，0 失败；真机相关 6 项通过，含效果参数的预览采样约 30.5fps，并验证实际拍摄携带同一配方，未将诊断样张写入系统相册。三类弹窗和对焦图标分别核对全部 7 种画幅。详见 Docs/Filter-Parameter-Editing.md 与 Preview/Filter-Parameter-Editor。


### 2026-10-15 滤镜连续调整、弹窗和压力回归

- 完整模拟器 177 项（174 通过、3 硬件跳过、0 失败）；另全 7 画幅 × 3 页等高/滚动/玻璃重置实景演示截图验证通过。
- iPhone 17 Pro 功能/图像 7 项通过，拖动中不再反复丢弃全部预览帧，结束后使用精确最终配方。RAW 资源字节保护、GPU/软件图像处理和预览/捕获一致性保留。
- 单独真机压力 1 项通过：120 轮、2040 次参数操作，约 22 秒，371 帧预览；内存 171 → 峰值 256 → 收尾 132 MiB。包括重置、弹窗、滤镜、格式、画幅切换。无崩溃或卡死，队列恢复为空。
- 光效分层降低计算分辨率、色差一次采样、颗粒密度模拟与光晕暗部保护通过图像断言。
- 详见 Docs/Filter-Parameter-Editing.md；本轮短时压力结果不等同长期温升或全部设备保证。


### 2026-10-15 照片后期滤镜、动态颗粒、按钮与直方图

完整模拟器 185 项（182 通过、3 硬件跳过）及最终布局专项 6 项通过；iPhone 17 Pro 13 项通过。覆盖实时颗粒相位、0–100 增强线性色差、照片编辑不累加/恢复配方/导出一致性和旧版本兼容。全 7 画幅编辑三页、双行长名、52pt 侧按钮与 320pt 窄屏、全部画幅对切换工具栏/直方图避让均验证。

新一轮 2040 次参数操作压力：22.09 秒，567 帧，内存 135 → 峰值 236 → 收尾 146 MiB，无崩溃/卡死，恢复正常。最终真机版本安装启动成功。记录与截图见 Docs/Photo-Filter-Editing.md、Preview/Photo-Filter-Editing。


### 2026-10-15 工具栏背景与直方图重叠补修

用户反馈的是背景条，而非工具栏按钮。此前预览顶部背景仍高 66pt，直方图从 58pt 起显示，约有 8pt 背景范围重叠。本轮仅将背景高度缩至 50pt，维持现有工具栏位置、色彩、透明度和直方图位置，两者相隔约 8pt。

扩充既有几何测试，除了工具栏控件，还断言背景下边界与直方图上边界至少留出 4pt。全部 42 对非相同画幅切换（每次过渡多点采样）、正常及窄屏全部 7 画幅布局共 3 项测试通过，0 失败；真机构建通过，修复版保留数据安装并启动。截图见 Preview/Toolbar-Backdrop-Histogram。

结果：/private/tmp/LumaToolbarBackdropSim.xcresult。此次未改动相机采集、滤镜渲染或照片保存路径。


## 2026-10-15 固定布局、相册顺序、iOS 18 与 Live

- 模拟器完整回归：196 项，193 通过、3 项真机专用跳过，无失败。结果 `/private/tmp/LumaOct15FinalSim.xcresult`。覆盖 A/M 各比例两两切换、固定按钮几何、动画可见性、直方图避让、Metal 内核加载/全部参数渲染、批量删除取消与重复点击、已加载页刷新、滤镜重新打开。
- LIVE 标识加入后定向回归：18 项全部通过，包含 7 种照片比例的 LIVE/RAW 详情截图及照片双向滑动时固定按钮不闪烁。结果 `/private/tmp/LumaOct15LiveBadgeSim.xcresult`。
- iPhone 17 Pro 实机：连续 12 次相机会话停止/恢复，实际 ISO、快门、WB 与对焦模式/数值全部保持正确。JPG Live 与应用 M9、色温、颗粒、16:9 的 HEIF Live 均通过 PHLivePhoto 解码，资源保持配对；没有写入系统相册。结果 `/private/tmp/LumaOct15LivePhysical.xcresult`。
- 实机连续编辑压力：2,040 次参数写入、120 轮切换/重置/格式/峰值组合，约 21.8 秒内 505 帧；内存基线 124MB、峰值 257MB、结束回落 168MB，通过上限及恢复断言，无崩溃。单项空间效果约 30fps，连续拖动 33 帧/1.06秒。结果 `/private/tmp/LumaOct15StressPhysical.xcresult`。这些测试不能保证所有设备、光线和操作组合绝无问题。
- 真机最终构建成功并安装。代码中的 CIKernel(source:) 与旧 AVCaptureSession 通知弃用警告已消除；Xcode 27 的 AppIntents 提取器仍会提示项目未依赖 AppIntents、跳过提取，不是源代码 API 弃用警告。没有为消除该工具提示而加入无用框架或关闭编译器警告。
- 对照截图：`Preview/Fixed-Camera-Controls-and-Live/`；实现说明：`Docs/Camera-Controls-and-Live.md`。


## 2026-10-15 Live 声音、实际保存与预览重叠修复

- 保存/失败重试/暂存资源/连拍/Live 格式等模拟器回归 24 项全部通过，`/private/tmp/LumaLiveAudioSim.xcresult`。
- 全部比例固定按钮、预览留白、参数行、直方图等布局回归 8 项全部通过，`/private/tmp/LumaLiveAudioLayoutSim.xcresult`。长比例预览仍从工具栏背后开始，但按比例缩放至底部五按钮上方，按钮坐标不随比例变动。
- 真机实际相册保存（区别于上轮仅验证 PHLivePhoto 解码）：普通 JPG 和 Live JPG 均成功。Photos 返回 Live 的 photoLive subtype，以及 photo、pairedVideo 两种资源。导出前后音轨均存在，声音时长约 2.93 秒。`/private/tmp/LumaLiveAudioSavePhysical2.xcresult`。测试产生的普通照片和实况照片保留在相册中，没有自动删除。
- 第一轮音轨测试因权限弹窗后生命周期更新覆盖了测试直接设置的麦克风意图而未录到声音，测试还包含一个可避免的强制解包失败；改为真实 Live 开关流程并用 XCTUnwrap 后通过。产品的音频意图跟随 Live 状态和前后台生命周期同步，导出时检查不能丢失源音轨。
- 上轮无声 Live 限制已取消。未授权麦克风时可继续保存无声 Live；不自动改动用户权限。


## 2026-10-15 拍照滤镜导入与 M 挡转盘最终回归

- 导入用户 3Dlut 文件夹的全部 44 份滤镜（40 PNG、4 CUBE；含既有 M9），加原片共 45 项。预览、照片和照片后期使用同一色表及独立持久化配方；视频 SDR/P3 功能按用户要求留待后续。本次没有新增普通视频录制。
- 每个滤镜的源文件网格采样和 GPU 输出对照通过，含等效 Display P3 输入的色彩管理。原始表没有独立色彩空间标记，按显示参考 sRGB 处理；没有推测性加入 Log 转换。来源、哈希与假设见 Imported-Filter-Manifest.json。
- 完整模拟器 205 项：202 通过、3 项真机专用跳过、0 失败，LumaZoomResponsiveSim.xcresult。最终局部 11 项通过，含全部 7 画幅展开变焦盘的固定按钮截图、边界反向无死区、节流、两次独立拖动。截图 Zoom-Preview-Clipped-All-Ratios.jpg 已目视核对。
- 真机 LumaZoomFilterFinalPhysical.xcresult 六项全部通过：全部色表、独立配方、五档物理镜头固定及手动曝光恢复、滤镜拍摄配方、连续编辑压力、本地 Live 长按实际 full 播放。Live 暂存资源随缓存保留，防止提前删除导致无法播放。
- 连续 2,040 次参数操作，21.60 秒内 544 帧，内存基线 117 MiB、峰值 264 MiB、收尾 164 MiB，无崩溃/卡死，恢复后队列为空。这是短时诊断，不代表全部设备或长期运行保证。
- 变焦达到边界后增量重置拖动基准，反向立即响应；变焦中的手动曝光恢复改到停稳 120ms 后，减少连续传感器曝光写入；避免重复启用 ProRAW。保持 M 挡每档范围与 A 挡路由策略。
- 最终真机 LumaZoomHapticsPhysical.xcresult 两项通过。每个焦段 180 次、共 900 次 4ms 间隔往返输入，单档预览持续 36–39 帧，最终硬件倍率正确，镜头未切换，手动曝光最终值正确。轻反馈上限 24Hz、锚点反馈上限 32Hz，日志不再出现上一轮的震动请求限频警告；固定焦段点击反馈仍保留。
- 相册返回保留旧帧至新预览到达再淡出，相关 22 项通过（LumaResumeTransitionSim.xcresult）。比例与返回过渡只作用于预览，按钮坐标不变。
- Xcode 原七项源码弃用警告已清理并重新构建确认；命令行仍有两项 AppIntents 元数据提取工具提示，不是源码弃用警告，没有加入无用框架掩盖提示。


## 2026-10-15 晚间：相册刷新、Live快门、批量分享与编辑

完整模拟器220项（217通过、3真机专用跳过、0失败），追加裁剪翻转像素方向1项通过，真机20项通过。模拟器真实PhotoKit验证外部入口新增3张照片自动更新列表，批量导出3张均可解码。照片编辑三页在全部7画幅目视核对，默认及重置滤镜强度100%，A挡实际主镜头自动切换加入短过渡。普通连续拍摄和Live锁快门、五档手动变焦均回归通过。诊断图没有保存真机系统相册。详细范围、已知静态分享/Live编辑限制、结果路径与测试记录见 Gallery-Editing-and-Sharing.md。


## 2026-10-15 夜间：参考编辑页、系统相册同步、滤镜映射

- LumaReferenceFinalSim：227项，224通过、3真机专用跳过、0失败。
- LumaSaveBadgeFullSim：230项，227通过、3真机专用跳过、0失败；包含模拟器真实PhotoKit另存/覆盖/重开编辑/恢复原参数及滤镜标记继承验证。测试照片仅写模拟器。
- LumaReferenceFinalNative：17项通过，含A挡restricted自动解除与变焦/切M/停止释放，M挡五档镜头范围连续变焦，JPEG/HEIF Live配对，裁剪、校正、配方保存与连续编辑；无诊断照片写入真机相册。
- LumaFinalLUTNative：4项通过，含44种滤镜网格与随机非网格插值、sRGB/P3等效输入、0/50/100%混合，及另存/覆盖路由重复点击防护。
- LumaFinalArcVisual：12项通过，含7种画幅固定按钮、相册分享状态像素稳定、Photos另存与覆盖、滤镜映射与新保存弹窗截图。弧形名称随后按用户要求恢复上下两行。
- LumaFinalRingSim：2项通过，确认分享/删除进度圈位于图标外围，按钮位置和其他按钮亮度保持。
- 未新增源码警告，仅Xcode AppIntents元数据提取跳过提示。
- 全部44个LUT的10,629,508网格点与源文件逐点相符；结果见Filter-Mapping-Audit-2026-10-15.md及同名JSON。

- LumaTwoLineFinalSim：2项通过；最终恢复两行名称且第二行8pt的全44滤镜截图、保存选择弹窗、相册分享/删除忙状态均已目测核对。最终真机包已重新构建，无新增源码警告。


## 2026-10-15 拍照偏好、A挡策略与分享闪动

- LumaPhotoPreferencesSim2：56项通过，包含版权/GPS元数据、JPG/HEIF无滤镜原片、Photos单事务创建独立资产、半浮点HDR高光、整页相册分享准备像素稳定以及对焦/相机/编辑回归。
- LumaFinalPhotoPreferencesFullSim：237项，234通过、3真机专用跳过、0失败。
- LumaAllPhotoPreferencesNative：18项通过，包含A挡仅变焦允许系统回退、对焦曝光变化期间主镜头稳定、恢复会话策略、全范围A变焦、五档M变焦和快速反转、A/M速度与Live配对等；诊断照片不保存真机相册。
- LumaPhotoPreferencesFinalPhysical：真实前置镜像开/关、HEIF Pro HDR文件10位与Artist字段、预览16位、拍照后A挡策略保留，全部七种画幅8倍对焦辅助边界均通过。图见Preview/Capture-Preferences/Focus-Assist-Seven-Ratios.jpg。
- LumaPhotoAnimationFinalSim：最终编辑页动画、分享整页稳定和裁剪回归14项通过。
- 本轮只接入拍照偏好，普通视频未新增。源码无新增警告，Xcode仍提示未依赖AppIntents而跳过元数据提取。

- LumaRAWAttributionNative：RAW原文件TIFF Artist署名及关闭定位后无GPS通过；诊断文件未保存到系统相册。最终真机验证合计20项通过（18项回归＋HDR/镜像/七画幅辅助1项＋RAW元数据1项）。


## 2026-10-16 HDR、相册缓存、滤镜校准与控件

- 完整模拟器 LumaOct16MacroFinalSim：244 项，241 通过、3 项真机专用跳过，0 失败。
- 最终统一按钮尺寸后，LumaUniformCameraControlsSim：20 项通过，覆盖全部七种比例固定按钮与参数行坐标、工具栏与直方图避让、窄画幅共享直径、焦段点击/长按、对焦锁定与 EV。最终截图已核对，按钮背景使用圆弧，长倍率允许单行适度缩放；切换画幅不改变坐标。
- LumaManualSettleWaitNative：2 项通过，普通 HEIF HDR 真正 10 位 HLG 预览，照片输出 10 位 PQ HEIF、约 4.93 高光余量；A/M 与 0.5/1/2/4/8 切换、HDR 开关往返及 HEIF Pro SDR 预览恢复通过。随后在 8× 长焦传感器裁切路由连续 12 次停止/恢复会话，实际 ISO 与快门恢复通过。曝光设置异步生效，验证等待实际值而非只检查 session ready；不以扩大数值容差代替生效判断。
- LumaOct16FinalRegressionNative：19 项通过，包含超广角独立回退候选、全范围 A 挡变焦、M 挡五档物理镜头与快速反转、会话恢复、JPEG/HEIF Live 配对、版权/GPS/原片/前置镜像/HDR 及全部滤镜映射。实际曝光尚在恢复时，测光/解除目标锁定不会用过渡中的硬件状态覆盖用户的手动曝光意图。
- LumaOct16FilterLiveStressNative：3 项通过，2,040 次连续参数修改，约 21.8 秒、394 帧；内存基线 123 MiB、峰值 294 MiB、收尾 180 MiB，无崩溃/卡死。另验证 Live 音频在前后镜头与 A/M 反复切换后连接正常。这是短时诊断，不构成长期运行或所有机型保证。
- 超广角回退由系统选择，保留显示倍率；系统没有公开确切微距进入/退出距离与切换原因。策略接口与候选恢复已真机验证，近远主体移动的主观平顺度仍需实际场景复测；不能把自动回退严格解释成精确距离判断。
- 相册成功保存且资源可由 PhotoKit 重读时释放完整拍摄缓存；失败或仅添加权限不清除。启动/前台重查列表与最新缩略图，外部删除同步清理。资源重新读取保留 RAW 伴随文件与 Live 配对视频。
- 红外校准仅作用于红外摄影的最终外观，保留原始 44 张色表和其他滤镜；同源参考及独立场景依据见 Infrared-Reference-Calibration.md。褪色改为暖黄方向，减少旧的白雾式抬黑。
- 源码没有新增编译警告；Xcode 仍有未依赖 AppIntents 而跳过提取的工具提示。以上真机诊断样张没有写入用户系统相册。


## 2026-10-16 相册同步、虚拟多摄稳定与自动恢复

- LumaCommittedGalleryFinalFullSim：249 项，246 通过、3 项跳过，0 失败；随后详情同步、恢复与材质调整的 LumaRecoveryBranchFinalSim：30 项全部通过。
- 追加覆盖逐张保存事件、三张连拍未收到 PhotoKit 通知时的列表刷新、600 张列表分页只在滚动时加载、快速 ID 校验先于资源元数据移除失效项、外部删除事件在详情邻图顺序丢失前发出、分享与详情动画。
- 真机只读相册查询确认完整读取权限及最新资源在系统查询中可见；没有通过制造相册数据复现用户现有图库故障。修复保存完成通知和刷新队列，并取消非可见分页递归加载。
- LumaUnlockedZoomRetryNative：5 项全部通过，验证完整虚拟多摄候选、1.25 秒切镜保持、用户主动超广角切换绕过保持、24/35mm 六次交替、M 挡五段物理变焦与快速反转。系统自动切镜不增加模糊/淡入淡出动画。
- LumaRecoveryGlassFinalNative：7 项，6 通过、1 项模拟器专用跳过。模拟四次运行时停止均自动恢复新预览帧及实际 ISO/快门；停止拍摄后中断结束通知不启动相机。另验证虚拟多摄、HEIF 10 位 HDR、A/M/焦段切换、12 次手动参数恢复、JPEG/HEIF Live 配对。
- 拍照弹窗材质不透明度统一调整为 0.86，保留灰蓝叠色、模糊与边缘高光；已核对辅助弹窗截图与文本清晰度。源码无编译警告，仅保留 Xcode AppIntents 未依赖跳过提示。
- 诊断照片没有写入用户系统相册。真实近远景的主观切换平顺度仍需场景复测；物理镜头视差无法仅凭策略接口完全消除。


## 2026-10-16 变焦流、实体快门与重新展开

- LumaCameraFinalDeliverySim：257 项，254 通过、3 项真机专用跳过。之后实体快门事件/变焦轮专项 LumaHardwareZoomOpenSim：8 项全部通过，包含开始/取消不拍摄、完成事件复用倒计时、相册/设置/后台不响应，两挡重新展开保持倍率及二次拖动。
- LumaHardwareZoomRecoveryNative：5 项，4 通过、1 项模拟器专用跳过。两挡在 4× 后变焦到 6×，关闭/重新展开三次，实际输入 ID、逻辑档位及倍率保持，后续拖动继续生效；三次模拟关闭帧门后启动均得到新帧；四次运行时停止恢复实际手动曝光；静音七种组合通过。不向系统相册保存诊断照片。
- 实体按键真实机械按压未由自动化完成；已编译系统事件接入并验证处理路径，不能等同于已按压测试。此次只实现单击拍照。
- 普通无 Live 预览切换到有界全输出后，4× 与 40× 临时图像实际构图明显不同；旧代理输出虽然设备倍率为 40，画面仍近似 4×。全输出在这台设备上不支持原生 Live，故仅 Live 开启时切回代理。JPG/HEIF Live 配对和 PHLivePhoto 解析另有通过记录（LumaLivePreviewFinalNative）。
- LumaPreviewRefactorFinalNative 滤镜压力检查：2,040 次更新约 21.9 秒、558 帧；基线 134 MiB、峰值 266 MiB、收尾 168 MiB，无崩溃。这是短时诊断。
- HEIF HDR 开关三轮未出现空帧/黑帧；最低预览均值约 0.297，终帧约 0.305。10 位 HLG 预览、PQ 成片、前置镜像、M 挡物理镜头及恢复回归通过。
- A/M 与 M 挡物理输入切换删除了多余输出尺寸重建。一次热态 M 物理切换约 0.78–0.94 秒，同输入裁切约 0.02–0.054 秒；后续冷态约 0.9–1.43 秒。A/M 最新实测约 1.2–1.8 秒。LumaDeliveryReadyNative 的 A/M 两次超过新增 1.5 秒目标，速度测试未通过该目标，未通过扩大阈值宣称达标；不能承诺无停顿。其他选中功能检查通过。
- 自然景观滤镜缩略图及原片卡片已核对截图；素材来源、最终提示词见 Filter-Thumbnail-Art.md。

## 2026-10-16 海滩缩略图与系统相机控制菜单

- LumaBeachControlMenuSim：10 项全部通过，覆盖 A/M 菜单结构、慢到快快门选项、事件隔离、实体快门倒计时、滤镜缩略图及变焦轮。
- LumaCameraControlMenuNative：2 项全部通过，系统实际接受 A 挡变焦和 M 挡全部六项控件，回调复用参数编辑使手动快门/ISO/焦点/白平衡/色调与 AE 自动曝光切换符合现有逻辑；旧模式事件忽略。没有保存诊断照片。机械按压与轻按菜单的实际呈现不由自动化代替验证。
- 海滩图由用户明确选定，使用内置 image_gen 生成，路径与提示词见 Filter-Thumbnail-Art.md。44 个滤镜和原片缩略图均正常生成。

## 2026-10-16 删除详情偶发跳过邻图

- LumaDeletionNeighborFinalSim：44 项全部通过，涵盖外部缓存清空不发本地删除回调、连续 20 次重复通知、加载后的迟到回调、旧令牌不能取消后续合法删除、保存未索引/缓存已清空/已索引三种详情邻图、本地删除成功及失败、分页、列表刷新与动画。
- 修复前已定位两条实际代码路径：PhotoReview 对 lastPhoto=nil 的监听与不可用资源事件均推进详情；此外已保存但未进入网格的 capture 页会在邻图计算中丢失，进而进入后续分页。此次分别消除重复导航与缺失当前页的位置推断。
- 真机版本构建通过；没有在用户系统相册创建或删除诊断照片。本次通过模拟服务控制通知顺序，不宣称必现用户原先的系统相册时序。

## 2026-10-16 三种目标锁定、Pro 影调与编辑缩放

- LumaLocksToneEditorVerifiedFullSim：272 项，269 通过、3 项真机专用跳过，0 失败。覆盖完整拍摄、滤镜、相册删除/分享/编辑、Live、全部七种画幅布局；新增模式记忆、AE/AF 独立与联合锁定、小太阳、菜单互斥、编辑视口保持、彩色颗粒/褪色定量和 HDR 明度单调性。
- 之后补查首帧长按与延迟参数恢复冲突：LumaPreservedLockFinalSim 专项通过，验证参数恢复不会取消刚建立的目标锁定，旧锁定行为、硬件菜单和会话恢复回归通过。没有改变白平衡自动/手动联动。
- 真实 HEIF Pro HDR 四种影调均已拍摄验证，回调记录的 toneID 一致，成片为 10 位 HEIF，预览成片图为扩展范围 16 位；未写入用户系统相册。合成灰阶与超白输入另行验证 HDR 高光保留和影调方向。
- LumaToneLocksEditorVerifiedNative 压力项：2,040 次参数修改约 21.8 秒、546 帧；内存基线 102 MiB、峰值 277 MiB、收尾 152 MiB。无卡死/崩溃，为短时检查，不等同于所有场景长期保证。
- 同轮锁定测试首次在 AF 先稳定、手动曝光尚未完成应用时读取了旧 ISO 400/1/125；改为等待实际 ISO 800/1/250 后判断（不扩大容差），LumaLockExposureSettledNative 的锁定及编辑缩放 4 项通过。数值写入会话队列不代表硬件已同步完成。
- 两场景影调对照及参数边界见 ProTone-Reference-Calibration.md。源码无新增编译警告，保留 Xcode 未依赖 AppIntents 时跳过元数据提取的工具提示。
- 最后交付 LumaAllDeliveryChecksNative：16 项，15 通过、1 项模拟器专用跳过，0 失败；包含真实 AE/AF 状态及手动曝光、四次运行时恢复、编辑视口、四种实际 HDR HEIF Pro 及合成 10 位影调、颗粒/褪色/光晕。所有诊断照片仅在测试回调或临时文件内，未写系统相册。

## 2026-10-16 晚：滤镜增强、名称显示、对焦恢复、Live 编辑

- `/private/tmp/LumaEffectsLiveSim1.xcresult`：24 项通过，覆盖原有静态编辑、各比例界面、缩放、纹理、影调、目标锁定和微距标识策略。
- `/private/tmp/LumaEffectsLiveSimFinal.xcresult`：17 项通过。
- `/private/tmp/LumaEffectsLiveNativeFinal.xcresult`：12 项通过，包括实际 AE/AF/组合锁定、点按后持续自动对焦、纹理以及 2040 次调参压力；21.75 秒持续 511 帧，内存基线 107 MiB、峰值 287 MiB、关闭编辑稳定 187 MiB，在原有回归阈值内。
- 补充 Live 覆盖/另存像素检查定位并修复 PhotoKit 已正向处理帧被重复转换方向的问题。最终 `/private/tmp/LumaLiveUprightNative.xcresult` 3 项通过，复制/覆盖归一化 RGB 平均差约 0.0152；旋转裁剪后照片 4570×3428、视频 1396×1048、动态 2.0117 秒，配对可播放。
- 加上详情封面及 Live 缓存更新后的 `/private/tmp/LumaLiveDeliveryNative.xcresult`：5 项通过，包含现有长按有声播放和重复播放；`/private/tmp/LumaLiveDeliverySim.xcresult`：13 项通过，静态编辑/Live 路由、各比例编辑布局、缩放及手势正常。
- 真机诊断未向系统相册新增、覆盖或删除任何资产；只读取一张已有 Live，并在临时资源上检查输出。系统相册最终保存事务未实写验证。微距近远景的偶发现象无法在固定摆放手机条件下保证复现，仍需现场复测；本轮修正了单次对焦停留与场景变化未恢复持续对焦的路径，没有改变系统自动多摄切换策略。
- 编译没有 Swift/Metal 源码警告；Xcode 提示未引入 AppIntents 因此跳过元数据提取，为构建工具提示。

## 2026-10-16 22:15 Live 编辑另存 3300 与浓度入口

- `/private/tmp/LumaLive3300FixtureNative.xcresult`：3 项通过，真实 Live 的裁剪方向/像素、播放配对、分辨率和编辑路由；只导出临时测试附件，不修改用户相册。
- `/private/tmp/LumaLive3300SaveSim.xcresult`：10 项通过，包含新的实际 PhotoKit 写入集成测试（正式 SystemPhotoLibraryService.saveCapture → openEditor → session.saveLive 两次 → saveCopy 静态），原始 Live 和两张编辑 Live 都有 photoLive 及配对视频资源；原资产保留。
- 附带临时文件类型/生命周期、失败清理、保存重复提交保护、各比例编辑布局和滤镜参数保存回归。无源码编译警告。
- 真机相册的实际写入未进行诊断性测试，须由用户对原操作重试确认，不将模拟器事务通过等同于真机写入已验证。

## 2026-10-16 22:30 编辑信息保留与浓度图标

- `/private/tmp/LumaEditMetadataSim.xcresult`：已有编辑/各比例界面/缩放与 Live 写入测试通过；新增元数据测试发现小数裁剪边界测试预期及 ImageIO 合并保留旧 SubjectArea，随后修正整数像素夹具和显式删除规则。
- `/private/tmp/LumaEditMetadataSim2.xcresult`：3 项通过，包括完整 EXIF、时间、位置、署名、版权、输出尺寸/方向，重复编码信息保留，源拍摄记录不变；实际 PhotoKit Live 两次另存及静态另存后记录继承正确。
- `/private/tmp/LumaEditMetadataNative.xcresult`：9 项全部通过。真实 Live 原片 8 项 EXIF 拍摄信息在编辑副本逐项一致，3200×2400 与 1396×1048 的静动构图匹配、时长约 2.633 秒，覆盖/另存平均 RGB 差约 0.0103，播放配对有效。未向真机相册提交诊断写入。
- 编译无 Swift/Metal 源码警告，只有未使用 AppIntents 的工具元数据提取跳过提示。

## 当前滤镜信息回归（2026-10-16）

`/private/tmp/LumaCurrentFilterSim.xcresult` 5 项通过，包括实际 PhotoKit Live 两次另存、静态另存后当前滤镜与拍摄事实；`/private/tmp/LumaCurrentFilterNative.xcresult` 11 项通过，当前滤镜/旧记录迁移/覆盖还原、EXIF 和静态/Live 编辑方向播放无回归。真机无诊断性 Photos 写入。


## 2026-10-17 横屏控件、文字边界与主动切换过渡

- `/private/tmp/LumaFinalPhotoUISimOct17.xcresult`：23 项通过，覆盖七种比例的固定布局、9 类弹窗在左右横屏的尺寸/避让、照片编辑刻度在实际横拿视角为竖向、圆形按钮长名称分行、对焦交互和编辑元数据。另检查导出截图，标题与文字均在玻璃背景内。
- `/private/tmp/LumaLiveWhitelistedOct17.xcresult`：7 项真机通过，HEIF HDR 开关/成片、LivePhotoPhysicalTests 全部两项（12 次会话恢复、JPG/HEIF Live 配对及重复点击门控）、M 挡各焦段、A/M 首帧过渡、过期白平衡命令跨路由。所有拍摄回调拦截为临时诊断资源，没有向用户真实 Photos 新增、覆盖或删除资产。
- 本轮先前 Live 检查生成过无视频轨的元数据 MOV，最初 async AVFoundation 合成导入器还触发 nil 解包崩溃。保留有界、可抛错的 nullable 回调及轨道验证，避免崩溃；Live 图配置在尺寸/ProRAW 批量事务之后启用。进一步核对发现测试绕过 ViewModel 相机激活/Live 开关，与实际功能协调器冲突，改为真实界面工作流后独立与连续 HDR/恢复回归均通过，没有降低配对断言。临时附件/详细日志代码已清理。
- 真机 WB 另发现虚拟镜头支持 locked 并不意味着支持自定义 RGB 增益；现按 isLockingWhiteBalanceWithCustomDeviceGainsSupported 判断，避免异常终止，并已回归。
- 最终构建仅保留 Xcode 未依赖 AppIntents 的元数据提取跳过提示，没有 Swift/Metal 源码编译警告。视频入口按用户要求继续延后，草稿仍未加入 App target。


## 2026-10-17 编辑页顶部圆角及参数提示

用户澄清“裁切”指滤镜/调色页照片上方两角被系统 sheet 圆角遮住，而非构图或缩放丢失。PhotoEditorView 设置 presentationCornerRadius(0)，仅针对编辑 sheet；未修改源照片、裁剪参数、缩放逻辑或其他弹窗。当前参数圆形文字提示从照片底部移至参数图标行右端，色彩页位于褪色右侧；参数较多时仅图标区横向滚动，提示固定且文字限制在圆形内。

`/private/tmp/LumaEditorSquareHintOct17.xcresult`：7 项通过。实际通过 SwiftUI sheet 打开编辑器，确认 UISheetPresentationController.preferredCornerRadius=0；遍历三类所有参数，提示在照片外，色彩页在褪色右侧。全部七种比例及横幅图的显示边界、切换工具、缩放平移保持，当前滤镜信息及拍摄元数据回归通过。人工核对实际 sheet 截图。真机构建成功；没有诊断性相册写入。


## 2026-10-17 减少重复预览工作与参数纯文字提示

- 照片编辑页当前参数提示保留固定 44 点槽和两行有界文字，移除圆形玻璃背景，其余按钮不变。
- FilterPickerViewModel 仅共享固定滤镜预览图片：首次生成请求合并，同进程后续编辑器直接取得相同 UIImage。分类、收藏、选中滤镜及参数仍独立，不新增持久化图片文件。不降低缩略图分辨率。
- 普通 SDR 且未开启峰值时，直方图使用已完成预览的 CGImage，避免第二个 CIContext 重新执行整条 LUT/影调/空间效果链。HDR、峰值、成片、Live 处理路径不变；预览维持 30fps 上限、原分辨率、直方图维持 20Hz 限流。
- `/private/tmp/LumaPowerReuseSimOct17.xcresult`：13 项通过，缩略图内容、共享对象/独立分类、直方图形状和预览队列隔离、编辑页真实 sheet/全部画幅/缩放；`/private/tmp/LumaPowerReuseNativeOct17.xcresult`：6 项通过，临时成片滤镜配方、2040 次调参压力、HEIF HDR、JPG/HEIF Live 配对、缩略图复用和渲染对照。真机诊断不写入用户相册。
- 真机受控渲染+直方图对照（固定 M9/柔化/光晕、预热后交替 10 次）：重复图链平均 8.273ms，复用已渲染像素平均 5.720ms，约减少 31% 的该段耗时，归一化直方图平均 bin 差 0.000854。此数字不等于 App 总体功耗、续航或温度降幅，也没有设置跨设备耗时断言。
- 真机压力约21.84秒，495帧；内存基线118MiB、峰值252MiB、收尾181MiB，符合既有阈值，无卡死/崩溃。本次短时检查不能保证所有长期温度场景，需要用户持续拍摄时继续观察。


## 2026-10-17 最终浓度、美食、褪色与场景对焦保护

- 浓度最终要求为 0–80 匀速、80–100 加速（平方曲线），80 为参考 LUT 满强度，100 为参考色彩差值 1.25 倍；默认和重置 80。未修改的旧默认100迁移80，自定义配方保留。见 Filter-Intensity-and-Food.md。
- `/private/tmp/LumaAcceleratedFadeSimOct17.xcresult`：22 项通过，覆盖所有滤镜 GPU/软件像素混合、加速增幅、80%参考一致、半透明和无效值、奶黄泛白、滤镜保存/重置和编辑各画幅缩放。
- 随后美食色彩增加到 vibrance 0.38、饱和度1.08；`/private/tmp/LumaFoodCreamFinalNativeOct17.xcresult` 9 项真机通过：新配方、真实预览与临时成片记录、加速曲线、奶黄泛白、HDR、Live以及2040次调参压力（约21.71秒/550帧，基线106MiB、峰值247MiB、收尾184MiB）。未向真实相册写入。此前中间回归的 HDR 启动读到前一测试尚未提交的 ready，已在测试开始等待实际会话队列后重测；没有扩大 HDR/成片断言或改动生产 HDR 路径。
- 横屏焦段省略号：UIButton 给旋转 UILabel 的原始布局过窄，改为圆形按钮内固定正方形文字槽，保留缩放字体及原点击/长按热区。`/private/tmp/LumaFocalTextSimOct17.xcresult` 8 项通过（0.5/1/24mm/35mm/11.7x/40x、左右横屏、点击/长按，加上最新美食/褪色）。
- 用户录屏为 `/Users/shurrikann/Downloads/ScreenRecording_10-17-2026 17-39-54_1.MP4`，约27.6秒；查看概览及11.5–13.0秒每0.1秒对照帧，控件不移动，远近对焦时背景存在轻微尺度变化。此前20秒只读硬件记录有一次主摄→超广角切换，之后主镜头与实际倍率稳定；这不能把所有变化简单归因于来回切镜，也不能单凭录屏严格区分光学呼吸与系统处理。
- 代码检查发现 subjectAreaDidChange 无条件重复设置连续自动对焦。现只在焦点偏离中心或未处于连续自动对焦时恢复，避免重复启动已在运行的中央连续 AF；保留 A/M、点击目标恢复及 AE/AF 锁定保护。不加过渡、不裁切、不改变自动多摄策略。
- `/private/tmp/LumaSceneFocusGuardNativeOct17.xcresult` 5 项真机通过：50次中央场景通知0次重设，旧偏心目标50次通知只恢复1次；AE/AF锁、系统虚拟多摄/全变焦范围、A/M和固定焦段切换通过。该修正减少不必要重对焦，不宣称已消除所有硬件/系统视角变化，需用户原场景复测。


## 2026-10-17 微距内近远对焦的轻微放大：诊断尚未修复

用户确认场景对焦去重版无改善。所有后续实验仅预览/临时 XCTest 附件，未调用照片捕获或向真实 Photos 新增、修改、删除资产。

- `/private/tmp/LumaOpticsV2ReadOct17.xcresult`：实际 1×（硬件虚拟倍率2）只发生一次主摄→超广角切换，之后实际主摄选择和硬件倍率固定。此前读取物理 constituent 的 lensPosition 固定1，不能作为真实虚拟相机对焦没有变化的证据；改读输入设备的对焦状态。
- `/private/tmp/LumaSmoothProbeOct17.xcresult`：设备支持平滑 AF，临时开启并恢复；用户观察仍然一样。未加入正式设置。
- `/private/tmp/LumaNativeComparisonOct17.xcresult`：同一会话的 AVCaptureVideoPreviewLayer 与滤镜预览上下对照，用户确认同步放大。这不是 iPhone 自带 Camera App 的完整管线，不能据此声称原生相机也有问题或断言属于不可避免的硬件限制。
- `/private/tmp/LumaOpticalCalibrationOct17.xcresult`：测试期间读取逐帧相机内参。超广角、硬件倍率2固定时 fx 范围约949.439–990.366（4.31%）；该元数据变化不足以单独证明用户看到的放大根因。
- `/private/tmp/LumaCalibratedPreviewOct17.xcresult`：临时按逐帧 fx 反向调整预览，最大缩放1.05465，各侧裁切约2.59%；用户仍观察一样。该补偿无效，未部署到预览或成片。
- `/private/tmp/LumaStabilizationCapabilityOct17.xcresult`：当前 .photo 格式支持 previewOptimized，实际连接 preferred=4 / active=4；不支持 standard / lowLatency。不是已证实的“未开启防抖”。测试未切换不支持的模式。
- `/private/tmp/LumaControlledFocusOct17.xcresult`：同一物理超广角、硬件倍率2，自动设定对焦0.2–0.8并取预览附件；请求值/实际值匹配。离线 Vision 配准观察到几何变化，但不同焦点模糊及手持姿态使这些结果不能当作精确标定或已验证修复。
- `/private/tmp/LumaMinimalSessionOct17.xcresult`：暂停现有相机，独立 .photo 虚拟三摄+AVCapturePhotoOutput+AVCaptureVideoPreviewLayer，不添加 VideoDataOutput、不启用 ProRAW/滤镜；用户仍观察一样。结束移除会话并恢复现有相机。用户另报告 iPhone 自带 Camera App 无此现象。

清理了临时上下对照视图、内参采集、校准裁切、平滑 AF 和稳定模式探针；实验源仅留 `/private/tmp/LumaMacroExperimentsOct17`。保留已有场景对焦去重与对应回归，其作用是避免不必要的 AF 重设，不能称为本问题修复。下一步方向需独立验证：自适应 AF 搜索策略或基于实际图像的几何稳定，不能用像素焦距变化直接推断 iPhone Camera App 私有实现。


## 2026-10-17 A 挡自动微距优先近距离搜索试用版

用户选择先试对焦策略方案。仅在 A 挡、后置虚拟相机实际以超广角提供≥1×构图时，等待路由稳定至少0.35秒并等当前对焦/拍摄任务结束，再使用系统 autoFocusRangeRestriction.near 提示优先搜索近处。该提示不是距离锁定，也未加入镜头切换限制、过渡、裁切或元数据几何补偿。系统仍可在近处未找到目标时搜索其他范围。

- 只在实际策略变化时设置并重启一次连续 AF；连续变焦/重复观察已激活的策略不再获取设备配置锁。
- 离开自动微距、选择普通0.5×、进入 M 挡、停机时恢复记录的原范围；点按/长按目标先恢复原范围，直到正常场景变化释放该用户目标；AE/AF锁定期间不自动改变搜索策略。
- 状态与设备操作只在会话队列，设备配置锁由各调用点独立管理，避免在已有配置锁内嵌套加锁；旧设备范围恢复暂时失败时不开始管理第二设备。
- `/private/tmp/LumaMacroNearRegressionOct17.xcresult`：10项通过，包括状态策略、真实虚拟镜头支持、50次重复请求只变更一次、用户点按/M挡/停止恢复、场景通知去重、A挡完整0.5–40×、M挡各焦段及参数/A-M首帧、AE/AF锁定、HEIF HDR、JPG/HEIF Live。所有成片拦截为临时附件，没有写入真实相册。
- 增补0.5×退出和旧设备保护后，`/private/tmp/LumaMacroNearExitFinalOct17.xcresult`：4项通过；手机读取supported=true，50次请求只设置near一次，切到0.5×恢复none并释放管理状态。

这证明策略可正确启用及退出，尚不代表用户观察到的突然放大已解决；需由同场景近远对焦实际试用判断。未声称复制 iPhone 自带 Camera App 的完整处理。


## 2026-10-17 回退近距离优先对焦试用版

用户实测感觉比改前差，明确要求回退。移除本次近距离优先的系统 AF 提示、稳定计时/重试任务、用户目标覆盖状态及相应新测试，恢复试用前的对焦/镜头策略。保留更早的场景通知去重保护及其回归，不修改滤镜、相册、拍摄参数、变焦和其他正常功能。前节试用版回归仅代表策略与功能检查通过，不代表改善用户观察到的放大；本次以用户实测为准撤回，不继续自动尝试其他方案。


## 2026-10-17 回退交付与滤镜80%以上加速增强50%

- 逐行重建试验前源文件，确认 CameraEngine.swift 与近距离优先试验前完全相同；`/private/tmp/LumaMacroNearRollbackOct17.xcresult` 的微距判定、通知去重和物理AE/AF锁定3项通过。回退版先行安装并启动，未继续保留近距离优先的定时任务、对焦范围更改或其他实验性补偿。
- 用户随后明确：80%以后到100%增加50%强度、过程加速。仅将 FilmStyle 的80%以上平方曲线系数由0.25改为0.5；默认80、0–80、色表和存储的参数数值不变，预览/成片/编辑仍共用路径。没有部署中间讨论的100%额外增强版本。
- `/private/tmp/LumaFilterBoost50Oct17.xcresult`：强度6项（包含本平台无操作的模拟器专用用例）及滤镜真机连续渲染/临时成片通过。所有可选滤镜的自然图80%输出与原参考逐字节一致；8位sRGB结果中整组80→100平均通道差累计由207.801变为400.082，表明增强没有在显示量化时全部消失；该值是固定测试图/整组统计，不能解释成每个滤镜的视觉倍数。人工核对 M9、红外、美食80/90/95/100对照附件。
- 初轮美食用例仍断言显示50%等于新的满强度一半，该旧假设与80以上非线性增强不符。改为验证40%等于80%参考与原片的中点，保留中间调、黑白端点、元数据和实际捕获断言；`/private/tmp/LumaFoodStrength50FinalOct17.xcresult` 3项通过。未修改美食色彩配方以迁就测试。
- 以上诊断图片和拍照只在临时附件/回调内处理，未写入真实系统相册。


## 2026-10-17 黑色背景与深色玻璃弹窗

- 相机背景由深蓝改为黑色系渐变；`AppTheme.popupColor`、玻璃面板及相册／详情／编辑底色统一为中性黑灰，强调色文字改用 `accentForeground`。`popupOpacity`、`cameraPopupMaterialOpacity`、`PreviewSurface` 等透明度参数保持原值。
- `PopupGlassBackground` 升级为多层深色磨砂玻璃：深色染色、`ultraThinMaterial`、上下明暗、对角高光与椭圆光晕、静态细颗粒、亮边与底边内阴影、双层投影；系统开启“降低透明度”时回退为高不透明度黑灰填充。新增 `Shared/Theme/GlassTexture.swift`，颗粒为共享静态纹理，不在动画或滚动中重新生成。
- 模拟器 Debug 构建通过。截图位于 `Preview/Black-Theme-Oct17/`：拍照页、参数面板、滤镜面板、辅助工具、功能切换和顶部格式面板。
- `/private/tmp/LumaThemeFocusedTests.log`：CaptureControlRotationTests 7 项、FilterInteractionTests 3 项、CameraControlMenuTests 2 项，共 12 项通过，0 失败；覆盖七种比例、左右横屏弹窗边界、滤镜交互和相机控制菜单。
- 完整套件本轮曾启动，其中 LUT 基准、单色通道、裁剪尺寸、会话恢复等 8 项失败与本轮视觉材质路径无关，已停止全量并待单独核对基线；未将全量结果视为通过。没有写入或删除真实相册资源。


## 2026-10-17 弹窗透明度、模糊度与按钮背景调整

- 按用户要求降低弹窗模糊度、提高透明度：`cameraPopupMaterialOpacity` 由 0.86 调整为 0.66，`PopupGlassBackground` 深色底由 0.34 调整为 0.22，默认材质透明度跟随 0.66；平面弹窗 `popupOpacity` 仍为 0.86，`PreviewSurface` 由 0.2 调整为 0.28。
- 按钮玻璃底更明显：`GlassSurface` 覆盖层由 0.36 调整为 0.52，顶部高光和描边增强、阴影加深；辅助工具图标底由 0.07 调整为 0.12；工具栏禁用图标由 0.35 调整为 0.55。
- 禁用状态改为保留背景、只降低内容：滤镜与翻转按钮不再整体使用 0.35 透明度，`CameraFilterButtonLabel` 增加 `dimmed`；格式选项禁用时保留胶囊背景；照片页操作按钮只淡化图标；相册分享／删除未选中时由 0.35 调整为 0.6。统一使用 `disabledControlOpacity` 0.46。
- 模拟器 Debug 构建通过；截图：`Preview/Black-Theme-Oct17/Buttons-v4.png`、`Parameter-Clear-v4.png`、`Filter-Clear-v4.png`、`Tools-Clear-v4.png`、`Toolbar-Clear-v4.png`。
- `/private/tmp/LumaThemeFocusedTests2.log`：CaptureControlRotationTests 7 项、FilterInteractionTests 3 项、CameraControlMenuTests 2 项，共 12 项通过，0 失败。没有写入或删除真实相册资源。
- 顶部格式弹窗的“10-bit HEIF”提示从行尾移到 HDR 开关后，与开关保持同一行内 8 点间距；模拟器与真机 Debug 构建通过，截图 `Preview/Black-Theme-Oct17/Format-HDR-Hint-v5.png`。


## 2026-10-17 弹窗横竖屏切换动画

- `OrientedPopup` 在弹窗显示期间切换横竖屏时，直接把当前卡片旋转到目标角度，并按目标横屏／竖屏的宽高比例同步缩放；动画结束的同一帧替换内容布局并复位缩放，不使用淡入淡出。减弱动态效果时改用短淡入淡出，避免 90° 旋转。
- 首版基于 SwiftUI transition 的实现未能产生可见变化；随后尝试的淡出／换布局／淡入也被用户确认不符合预期，最终改为旋转变形。底部弹窗的屏幕锚点在旋转期间保持旧边，旋转结束后才切到新边。
- 横屏卡片内部继续按控件角度旋转；设置 sheet 的旋转内容同样遵循减弱动态效果。
- 临时加入模拟器自动旋转开关，连续截图确认中间帧存在旋转与拉伸，随后移除该调试开关。中间帧联系表曾保存为 `Preview/Black-Theme-Oct17/Rotation-Transition-Contact.png`，已在回退时删除。
- 模拟器 Debug 构建通过，横屏弹窗锚点截图 `/tmp/LandscapeAnchorCheck.png` 核对通过；真机 Debug 构建、安装与启动成功。
- `/private/tmp/LumaThemeFocusedTests4.log`：CaptureControlRotationTests、FilterInteractionTests、CameraControlMenuTests 共 12 项通过，0 失败。没有写入或删除真实相册资源。


## 2026-10-17 弹窗材质与横竖屏切换：性能与稳定性（旋转变形版本，已回退）

新增 `LumaCameraTests/Camera/PopupAppearanceAndOrientationTests.swift`，覆盖本轮新增的深色玻璃、禁用按钮背景、HDR 提示布局和弹窗旋转变形：

- 性能测量使用完整窗口快照（`UIGraphicsImageRenderer` + `drawHierarchy(afterScreenUpdates:)`，scale 1）：`testPopupGlassDrawPerformance` 每组 6 帧，`testPopupOrientationSwitchDrawPerformance` 每组 8 次横竖屏布局切换并各绘制一次。该耗时包含整个测试宿主窗口，不等于 App 的实际帧率或合成耗时。
- 稳定性：`testPopupOrientationRapidStressEndsVisible` 连续 200 次快速切换横竖屏，结束后弹窗仍需可见；`testPopupOpenCloseDuringOrientationChangesRemainsResponsive` 在模拟器上执行 60 次弹窗开关与旋转交叉操作，最后断言横屏弹窗边界和可见状态。
- 模拟器（iPhone 17 Pro，iOS 26.5）：玻璃绘制平均 0.098 秒/6 次（约 16.3 毫秒/次），峰值内存 54.4 MB；切换绘制平均 0.155 秒/8 次（约 19.4 毫秒/次），峰值 82.5 MB；5 项测试，1 项真机专用跳过，0 失败。日志 `/private/tmp/LumaPopupPerfSimFinal.log`。
- 真机（iPhone 17 Pro，iOS 27.0.1）：玻璃绘制平均 0.059 秒/6 次（约 9.8 毫秒/次），峰值 308.6 MB；切换绘制平均 0.103 秒/8 次（约 12.9 毫秒/次），峰值 395.5 MB；5 项测试，1 项完整相机 UI 压力仅在模拟器执行而跳过，0 失败。日志 `/private/tmp/LumaPopupPerfDeviceFinal.log`。
- 真机另用 `CADisplayLink` 记录一次竖屏→横屏过渡：700 毫秒内 43 帧，平均 16.6 毫秒、最大 16.7 毫秒，没有出现超过一帧的停顿；这是单次过渡的帧间隔检查，不代表所有滤镜、温度和持续操作场景。日志 `/private/tmp/LumaPopupFramePacingSigned.log`。
- 内存数值是测试进程（XCTest + 全窗口快照）的峰值，不是 App 常驻内存；帧间隔测试只覆盖一次过渡，不能外推为持续 60 fps 或续航结论。
- 测试 target 已补充开发团队配置，真机 Command-U 可直接运行；本轮未写入或删除真实相册资源。
- 最终旋转变形版本复跑 12 项聚焦回归（七种比例、左右横屏弹窗边界、滤镜交互、相机控制菜单），0 失败；日志 `/private/tmp/LumaThemeFocusedTestsFinal.log`。


## 2026-10-17 回退旋转变形，恢复淡入淡出

用户实测旋转加尺寸变形效果不佳，要求换回之前的淡入淡出版本。本轮按用户实测结果撤回，不继续调整旋转方案。

- `OrientedPopup` 恢复为两段式淡入淡出：旧布局淡出 0.14 秒（轻微缩小与倾斜），不可见时切换布局，再淡入 0.20 秒；减弱动态效果时使用 0.08／0.10 秒。
- 底部弹窗的屏幕锚点延迟恢复为 150 毫秒（减弱动态效果 90 毫秒），淡出期间保持旧边缘，布局切换时再移到新边缘。
- 删除旋转版本的联系表截图 `Preview/Black-Theme-Oct17/Rotation-Transition-Contact.png`；临时模拟器自动旋转开关此前已移除。
- 模拟器（iPhone 17 Pro，iOS 26.5）复跑性能与稳定性：玻璃绘制平均 0.105 秒/6 次（约 17.5 毫秒/次），峰值 54.5 MB；切换绘制平均 0.159 秒/8 次（约 19.9 毫秒/次），峰值 82.0 MB；5 项测试，1 项真机专用跳过，0 失败。日志 `/private/tmp/LumaPopupFadePerfSim.log`。
- 真机（iPhone 17 Pro，iOS 27.0.1）：玻璃绘制平均 0.058 秒/6 次（约 9.7 毫秒/次），峰值 309.2 MB；切换绘制平均 0.086 秒/8 次（约 10.8 毫秒/次），峰值 386.2 MB；700 毫秒过渡记录 42 帧，平均 16.9 毫秒、最大 25.0 毫秒，没有多帧停顿，但有一帧略高于 16.7 毫秒；5 项测试，1 项完整相机 UI 压力仅在模拟器执行而跳过，0 失败。日志 `/private/tmp/LumaPopupFadePerfDevice.log`。
- 回退后复跑 12 项聚焦回归（七种比例、左右横屏弹窗边界、滤镜交互、相机控制菜单），0 失败；日志 `/private/tmp/LumaThemeFocusedTestsFade.log`。
- 以上快照耗时与测试进程内存峰值的局限同前；未写入或删除真实相册资源。


## 2026-10-18 回退镜头切镜实验，恢复系统自动微距

用户确认不再继续强制切镜/快速退出方案，回到系统自动微距行为。

- 移除强制物理主摄输入替换、10Hz 远距探测、强制退出冷却和微距图标短暂提示；恢复系统自动选择主摄/超广角，微距图标重新跟随实际镜头状态。
- 保留 `macroNotBefore` 的 0.6 秒路由稳定窗口，避免前后镜头切换时微距图标误闪。
- 保留本轮已确认的黑色背景、深色玻璃弹窗、按钮背景、HDR 提示位置和弹窗横竖屏淡入淡出；不再给镜头切换叠加淡入淡出。
- 删除 `MacroLensHoldTests.swift`；性能与稳定性测试文件 `PopupAppearanceAndOrientationTests` 保留。
- 模拟器回归：CameraMacroPolicyTests、AutomaticLensTransitionTests、CaptureControlRotationTests、PopupAppearanceAndOrientationTests 共 15 项，1 项真机专用跳过，0 失败。日志 `/private/tmp/LumaAutoFocusRegression.log`。
- 真机 Debug 构建、安装与启动成功；未写入或删除真实相册资源。未同步到 `LumaCamera`。


## 2026-10-18 M 挡参数弹窗贴底、固定焦段控件与竖屏参数布局

- M 挡参数弹窗改为全宽贴底：顶部圆角 36，底部圆角使用屏幕圆角（有底部安全区时 55，无安全区设备为 0）；移除原来的 10 点横向、8 点底部悬浮间距，内容底部留 42 点避开 Home Indicator。
- 参数弹窗始终使用竖屏卡片布局，不再走 `orientedPopup()`。横屏控制角度下只旋转关闭按钮、A/M 和中间标题；参数数值、刻度、焦点远近图标和 AWB 预设保持不旋转。
- 预览焦段条、左侧模式按钮和右侧工具按钮不再随参数弹窗高度抬升；横屏打开参数弹窗时也不再隐藏这三处，允许被弹窗覆盖。
- `PopupAppearanceAndOrientationTests` 新增四项：竖屏固定控件位置、横屏控制角度下参数卡片仍为竖屏形状、40 次快速开关/旋转压力、参数面板绘制性能。模拟器 9 项（1 项真机专用跳过）0 失败；真机 9 项（1 项模拟器专用跳过）0 失败。
- 真机（iPhone 17 Pro，iOS 27.0.1）参数面板全窗口快照 6 次平均 0.061 秒（约 10.2 毫秒/次），峰值内存 353.6 MB；真机帧间隔 42 帧、平均/最大 16.7 毫秒。模拟器参数面板 6 次平均 0.128 秒（约 21.3 毫秒/次）。快照耗时不等于实际 FPS，内存为测试进程峰值而非 App 常驻内存；日志 `/tmp/LumaParamNewTests.log`、`/tmp/LumaParamDeviceTests.log`。
- 截图：`Preview/Black-Theme-Oct17/Parameter-Popup-Bottom-v6.png`、`Preview/Black-Theme-Oct17/Parameter-Popup-Landscape-Portrait-v6.png`。
- 本轮未同步到 `LumaCamera`；用户真机确认后再同步。



## 2026-10-18 相机页全部弹窗取消横屏布局（最终）

本轮把顶部工具栏弹窗和滤镜、拍摄模式、拍摄辅助弹窗也改回竖屏，相机页不再有横屏弹窗布局。

- 顶部格式/比例/影调弹窗：移除 `orientedPopup()`，固定在顶部并按竖屏全宽布局。
- 滤镜、拍摄模式、拍摄辅助：移除 `orientedPopup()`，固定回竖屏底部，保留各自原有尺寸和底部间距；不再按左右横屏换边。
- M 挡参数弹窗保持上一轮的贴底全宽和底部圆角；横屏只旋转 X、A/M 和标题。
- 移除 `popupAnchor`、`targetPopupAnchor`、`bottomPopupAlignment` 及其横屏换边动画；相机页弹窗不再因横竖屏改变卡片布局。
- 模拟器：`PopupAppearanceAndOrientationTests` 12 项（1 项真机专用跳过）+ `CaptureControlRotationTests` 7 项，0 失败；边界用例在修正“滤镜/工具/模式弹窗不要求完全贴底”后重跑通过。日志 `/tmp/LumaFinalPortraitTests.log`、`/tmp/LumaPopupBoundaryFinal.log`。
- 真机（iPhone 17 Pro，iOS 27.0.1）：`PopupAppearanceAndOrientationTests` 12 项（1 项模拟器专用跳过），0 失败；参数面板快照 6 次平均 0.075 秒（约 12.5 毫秒/次），顶部工具弹窗 0.072 秒（约 12.0 毫秒/次），峰值内存约 348/329 MB（测试进程），帧间隔 41 帧、平均 17.1 毫秒、最大 33.3 毫秒。日志 `/tmp/LumaAllPortraitDeviceTests.log`。
- 快照耗时不等于实际 FPS，内存为 XCTest 进程峰值；未同步到 `LumaCamera`。


## 2026-10-18 M→A 微距标识短暂出现检查

- 结论：不是只有图标。`macroActive` 由 `activePrimaryConstituent` 是否为超广角驱动；显示时虚拟多摄的主镜头确实短暂是超广角，预览也走超广角帧，随后才回到主摄。
- 原因：M→A 通过 `applyContinuousZoom` 替换物理输入为虚拟多摄，这条路径此前没有设置 `macroNotBefore`，而虚拟多摄起步时主 constituent 可能是超广角；`selectLensOnQueue` 路径已有 0.6 秒抑制，因此只在模式切换时明显。
- 修复：M→A 时立即把微距状态置否，并把 `macroNotBefore` 延后 0.8 秒；连续变焦的输入替换同样设置 0.8 秒抑制，避免其他路径复现。
- 回归：`CameraMacroPolicyTests` 2 项、`AutomaticLensTransitionTests` 1 项通过；真机 Debug 构建、安装、启动成功。
- 局限：该修复先消除误显示的微距标识和状态；如果 0.8 秒内预览仍出现短暂广角画面，需要再决定是否在 M→A 时强制主摄路由。未同步到 `LumaCamera`。

### 追加：M→A 微距标识改为对焦距离门控

- 仅抑制 0.8 秒仍可能在超广角路由持续更久时再次显示，因此 `CameraMacroPolicy` 增加可选 `focus` 参数：对焦位置低于 0.2 时不算微距；真机远距对焦位置低，M→A 即使短暂停在超广角也不会显示标识。
- 近距真实微距仍满足 `focus >= 0.2`，显示逻辑不变。
- `CameraMacroPolicyTests` 新增远距 focus 0.05 不激活、近距 0.6 激活；策略 2 项、自动切镜 1 项全部通过，真机已安装。
- 注意：这只修正标识；如果预览仍短暂变广，说明虚拟多摄的物理路由仍在超广角，需要另行强制主摄。

### 修正：撤销对焦门控，M→A 改为主摄预热

- 对焦位置阈值会误伤真实微距（真机近距 `lensPosition` 低于 0.2），已完全撤销 `CameraMacroPolicy` 的 focus 参数和对应测试，微距标识恢复原判断。
- M→A 时如果虚拟多摄当前主镜头不是主摄，先短暂推到 2× 等效（主摄可满足），锁定主摄后回到原 1×，0.35 秒后恢复自动策略；同时保留 0.8 秒微距抑制。这样避免虚拟多摄沿用上一次的超广角起步。
- 预期代价：M→A 瞬间可能看到一次很短的推近再回弹；若仍出现广角或图标，说明预热未成功，需要改物理主摄入替换。
- 回归：`CameraMacroPolicyTests` 2 项、`AutomaticLensTransitionTests` 1 项通过；真机已安装。未同步。

### 最终回退：撤除 M→A 强制预热

- 2× 预热会造成多次连续跳动，已删除 `primeMainAfterManualExit` 及调用；不再主动改变 M→A 的镜头路由。
- 对焦门控已撤销，真实微距标识恢复。
- M→A 仅在切换时抑制微距标识 2 秒；连续变焦输入替换使用 `max` 保留更长的抑制窗口，不会缩短。
- 回归：`CameraMacroPolicyTests` 2 项、`AutomaticLensTransitionTests` 1 项通过；真机已安装。
- 若 2 秒后标识仍出现，说明系统虚拟多摄在该场景持续停在超广角；继续解决需要更换路由方案，不再用预热。


## 2026-10-18 M/A 切换快速淡入淡出

- 在检查点 1 基础上，仅为 M 挡与 A 挡切换增加预览淡出/淡入：约 0.10 秒淡到浅灰（峰值约 0.48），110 毫秒后约 0.18 秒淡回；减弱动态效果时为 0.06/0.10 秒。其他镜头切换和自动切镜不加该效果。
- 淡出只作用于取景画面，不遮住控件；微距标识仍沿用 M→A 的 2 秒抑制。
- 新增 `ModeSwitchFadeTests`：淡入淡出会启动并回零、20 次快速切换后不残留冻结淡出。模拟器 2 项、真机 2 项，0 失败；真机已安装。
- 当前工作区 = 检查点 1 + M/A 淡入淡出；检查点 2 仍保留 1× 限制交接版本。未同步到 `LumaCamera`。


## 2026-10-18 退出相机自动关闭功能弹窗

- `setCameraActive(false)` 现在先调用 `closePopups()`，覆盖参数、工具、拍摄模式、顶部工具栏、滤镜重置和变焦拨盘等状态；仅在 `review`（相册流程）为真时跳过，避免把进入相册误判为退出相机。
- 新增 `CameraPopupLifecycleTests`：退出时参数/工具/拍摄模式/顶部面板全部关闭；相册 review 状态下保留弹窗状态。模拟器 2 项，0 失败；真机已安装。
- 当前仍为检查点 1 + M/A 浅灰淡化 + 本项清理；未同步到 `LumaCamera`。


## 2026-10-18 前后镜头切换微距标识抑制

- 前后镜头切换属于相机位置变化，虚拟后置多摄可能沿用上一次的超广角起步。`selectLensOnQueue` 现在检测 `previousPosition != device.position`，位置变化时把 `macroNotBefore` 延后 2 秒并立即把 `macroActive` 置否；同位置换镜仍为 0.6 秒。
- 不改镜头路由，不增加推拉；若 2 秒后标识仍出现，说明系统路由仍停在超广角。
- 回归：`CameraMacroPolicyTests` 2 项、`AutomaticLensTransitionTests` 1 项通过；真机已安装。未同步。



## 2026-10-18 前后镜头切换复用浅灰淡化

- `flipCamera()` 从旧的 `startFocalTransition()` 改为 `startModeSwitchFade()`，与 M/A 切换共用浅灰淡化、冻结帧和占位图抑制；不再使用旧帧交叉过渡。
- 前后镜头切换的微距标识仍延后 2 秒；`ModeSwitchFadeTests` 2 项通过，真机已安装。未同步。


## 2026-10-18 切换淡化改为等待新镜头出帧

- 原实现按固定 110 毫秒开始淡出，前后镜头切换较慢时会先白一下再露出旧画面。现在切换开始后旧帧保持覆盖，淡化停在新画面峰值；只有检测到 `camera.preview` 先出现空档、随后在新路由 `ready` 后收到非空帧，才延迟 120 毫秒开始 0.18 秒淡出。
- 增加 1.8 秒兜底：新路由始终没有出帧时释放覆盖并淡出，避免永久冻结。
- `ModeSwitchFadeTests` 适配无相机帧的测试环境，等待兜底回零；2 项通过，真机已安装。未同步。


## 2026-10-18 回退 M→A / 前后切换过渡与微距抑制

- 回退 M 挡与 A 挡、前后镜头切换的淡化/冻结过渡，恢复原有 `startFocalTransition` 路径。
- 移除 M→A 专用的 2 秒微距抑制以及连续变焦输入替换的 0.8 秒抑制；M→A 回到系统原始判断，前后镜头保持原有 0.6 秒抑制。
- 保留退出相机自动关闭功能弹窗及 `CameraPopupLifecycleTests`；移除 `ModeSwitchFadeTests`。
- 回归：`CameraPopupLifecycleTests` 2 项、`CameraMacroPolicyTests` 2 项、`AutomaticLensTransitionTests` 1 项通过；真机已安装。未同步。


## 2026-10-18 同步到 LumaCamera 与最终回归

- 当前 `LumaCamera_DeepSeek` 已同步到 `LumaCamera`：相机弹窗竖屏布局、M 参数弹窗贴底圆角、固定焦段控件、退出相机关闭弹窗、深色玻璃与按钮背景、HDR 提示、相关测试和文档。M/A 与前后镜头切换保持原始路由，没有新增淡化、冻结或强制主摄。
- 同步后模拟器 29 项（1 项真机专用跳过）0 失败：`PopupAppearanceAndOrientationTests` 12 项、`CaptureControlRotationTests` 7 项、`CameraPopupLifecycleTests` 2 项、`CameraMacroPolicyTests` 2 项、`AutomaticLensTransitionTests` 1 项、`CameraControlMenuTests` 2 项、`FilterInteractionTests` 3 项。日志 `/tmp/LumaSyncedFinalTests.log`。
- 同步后真机 16 项（1 项模拟器专用跳过）0 失败；真机 Debug 构建、安装和启动成功。日志 `/tmp/LumaSyncedFinalDeviceTests.log`、`/tmp/LumaSyncedFinalDevice.log`。
- 未解决：M→A 和前后镜头切换后系统虚拟多摄可能短暂停在超广角，微距标识短暂出现；微距退出速度仍由系统决定。两者都没有在同步版本中加入额外路由或过渡补偿。
- 检查点 1 和检查点 2 的本地归档仍保留在项目上级目录，供后续对比，不属于 App target。


## 2026-10-18 前置广角切换

- 真机 `AVCaptureDevice` 探测（iPhone 17 Pro，iOS 27.0.1）：前置有独立 `Front Camera`（wide，1.0–128.875×）和 `Front Ultra Wide Camera`（ultra-wide，1.0–143.5×），TrueDepth 为虚拟设备。
- 已把前置超广角加入镜头目录，并在前置焦段条用单个“广角”切换按钮替代原前置 1× 入口：前置主摄 ↔ 前置超广角，选中时高亮；无前置超广角的设备保留原入口。
- 前置切换复用 `selectLens` 的输入替换、竖屏与镜像配置；后置多摄路由未改。
- 首次实现切换前置超广角时因 `AVCaptureVideoDataOutput.videoSettings` 固定尺寸与该镜头动态宽高比不匹配而触发 `NSInvalidArgumentException` 闪退；前置超广角路由现在跳过固定预览缓冲尺寸，交由 AVFoundation 决定。
- 图标改为两个斜对角箭头：关闭广角时箭头向外，开启时箭头相对/向内；选中高亮。
- 新增真机 `FrontWideSelectionTests`：前置主摄→超广角→主摄完整切换并校验倍率；模拟器只校验两个 SF Symbol 存在。真机测试通过，构建、安装、启动成功。未同步到 `LumaCamera`。


## 2026-10-18 前置广角同步验证

- 前置广角、双斜箭头图标、动态宽高比崩溃修复、镜头目录和 `FrontWideSelectionTests` 已同步到 `LumaCamera`。
- 同步后模拟器 26 项（2 项真机专用跳过）0 失败：前置箭头符号、弹窗与旋转布局、弹窗生命周期、微距策略、自动切镜。日志 `/tmp/LumaSyncedFrontTests.log`。
- 同步后真机 6 项 0 失败，含 `FrontWideSelectionTests` 前置主摄→超广角→主摄完整切换；真机 Debug 构建、安装、启动成功。日志 `/tmp/LumaSyncedFrontDeviceTests.log`、`/tmp/LumaSyncedFrontDevice.log`。
- 仍未解决：M→A 和前后镜头切换后系统可能短暂停在超广角并显示微距标识；微距退出速度仍由系统决定。


## 2026-10-18 清理微距退出残留与统一切镜协作规则

- 删除 `MacroExitRecheckPolicy`、微距场景变化后 1.2 秒重新单次对焦、恢复任务、取消状态及 DEBUG 诊断入口；删除只服务该实验的策略测试、合成微距测试与需要人工配合的 20 秒诊断。保留场景变化时原有的连续 AF 恢复、目标锁定、实际超广角供图判断和最新前置广角实现。
- `AGENTS.md` 与当前代码统一：A/M 和前后切换继续使用已有 `startFocalTransition`（旧帧轻微模糊，新帧到达后短淡出、失败超时释放）；不要求重新加入已回退的浅灰淡化或强制主摄。系统自动切镜仍不添加过渡。
- 真机 iPhone 17 Pro，iOS 27.0.1：7 项通过，涵盖微距状态判断、前置主摄/超广角往返、AE/AF/组合锁定和 EV/手动曝光、弹窗关闭/相册回退、场景通知压力。50 次居中通知重配置 0 次，50 次偏离中心通知重配置 1 次；本轮 100 次通知及队列交付约 16.4ms，1.7 秒后仍为连续 AF、预览有效。该耗时为单轮控制路径测量，不是 FPS 或微距退出耗时；未证明近远场景放大问题已修复。结果 `/private/tmp/LumaConsistencyNativeOct18.xcresult`。
- 模拟器 6 项，5 通过、1 真机前置切换用例跳过，0 失败；覆盖七种画幅下系统切镜不产生遮罩、弹窗生命周期、微距判断和前置箭头。结果 `/private/tmp/LumaConsistencySimOct18.xcresult`。正常 iOS Debug 构建成功，日志 `/private/tmp/LumaConsistencyBuildOct18.log`。
- 本次未同步到 `LumaCamera_DeepSeek`，未向真机系统相册保存诊断照片。

- 补充真机重复切换 2 项通过：6 次 A/M 过渡完成约 0.85–1.23 秒，12 次 M 挡固定焦段新帧恢复约 0.08–1.05 秒，手动曝光意图保留。新帧恢复与完整过渡是不同指标，不混为 FPS；仅为本轮设备/场景采样。结果 `/private/tmp/LumaConsistencySwitchFinalOct18.xcresult`。首次 `test-without-building` 因正常 build 后不存在测试清单而未执行，重新用 `xcodebuild test` 生成后通过，未改动性能阈值。


## 2026-10-18 同步微距清理与说明到 DeepSeek 项目

- 按用户指定方向，从 `LumaCamera` 同步到同级 `LumaCamera_DeepSeek`；本轮差异集中在微距重新对焦残留清理、回归测试及协作/架构/验证说明，并同步 README 的最新状态与同步约定。
- 同步前核对：目标的 5 个代码/测试/协作文件与本次修改前备份一致；未发现额外源代码差异。覆盖文件先备份到 `/private/tmp/LumaDeepSeekSyncOct18Backup`，不清理目标专有文件、Xcode 用户设置或构建缓存。
- 同步后逐文件 SHA-256 校验项目代码、资源、测试与文档；目标构建结果另行补录。源项目本轮真机 9 项通过、模拟器 5 项通过/1 项跳过，不能将这些结果表述为在目标路径上重新完成真机测试。

- 目标路径 `LumaCamera_DeepSeek` 的 generic iOS Debug 签名构建成功，日志 `/private/tmp/LumaDeepSeekSyncOct18.log`；构建后再次核对同步内容一致。本次仅同步与构建，未重复安装手机或运行目标路径真机测试。


## 2026-10-18 前置普通/广角切换提速

- 仅在前置设备间切换、HDR/Live 未开启的普通拍照路径，将输入、预览和照片输出配置合并到同一最外层事务，减少多次重建图。保留系统前置设备入口及原倍率，不增加模拟广角裁切，不调整图像分辨率或既有过渡动画。HDR/Live、后置及跨前后镜头保留原事务顺序。
- 切换前清除不适用于动态前置画幅的旧预览宽高；提交后设置实际输出连接的旋转/镜像，并更新帧时间门，避免配置提交前的排队帧成为完成动画的依据。无正式运行时分阶段日志，测试专用输出只在 XCTest 中。
- iPhone 17 Pro、iOS 27.0.1，同一测试流程各 6 次前置往返（不计后置进入前置的首轮）：未优化版新帧平均 1.225s，最终版 0.535s，缩短约 56%；包含既有过渡完成平均 1.415s → 0.751s。最终新帧范围 0.414–0.657s。样本为短时当前设备和场景，不能保证所有温度/格式同速；这里是切换延迟，不是 FPS。对照 `/private/tmp/LumaFrontSpeedBaselineOct18.xcresult`、最终 `/private/tmp/LumaFrontFrameGateFinalOct18.xcresult`。
- 前置专项最终 4 项通过：官方设备 ID/原始 zoomFactor、双箭头、6 次往返、4 次 M 挡切换期间 40 次重复点击、实际 ISO/快门恢复、两种前置临时 JPEG 输出、镜像开关、切换中停止及恢复会话。样张只进入临时测试回调，不保存系统相册。
- 成片测试最初假设超过 1000 万像素而失败；随后完全还原未优化引擎复核，两种前置输出均为 2250×3000（675 万像素），与优化版完全一致。测试改为守住这一既有输出基线，未降低生产分辨率或改动照片编码。失败对照留在 `/private/tmp/LumaFrontPhotoBaselineOct18.xcresult`，它不能被记作通过。
- 另有相关真机 8 项全通过（包含上述前置用例，以及后置 HDR 10 位预览/照片、JPEG/HEIF Live 配对、12 次 M 焦段与 6 次 A/M 切换），结果 `/private/tmp/LumaFrontOptimizedRegressionOct18.xcresult`；最后帧时间门修整后重新通过上述前置 4 项。模拟器最终 22 项、19 通过/3 真机专用跳过，0 失败，结果 `/private/tmp/LumaFrontSpeedFinalSimOct18.xcresult`。
- 本次未同步 `LumaCamera_DeepSeek`；微距策略和已知近远对焦视角变化未修改。

- 最终 generic iOS Debug 构建成功（`/private/tmp/LumaFrontSpeedDeliveryOct18.log`），已安装并启动到连接的 iPhone。


## 2026-10-18 前置照片侧转、系统相册等效焦距与单输入取景

- 用户明确以系统“照片”App 的照片信息为准，已写入 AGENTS；本轮核验系统原始处理文件与最终 JPG/HEIF 文件的 EXIF，不使用 App 内参数文字替代，也不手动写入 20/31mm 焦距字段。旧照片不追溯修改。
- 原始诊断复现普通前置与广角在 1× 时均写 20mm，且固定 90° 连接叠加新传感器补偿后，普通照片原始像素 4032×3024、EXIF 方向 4，解码后仍为横向；后续裁为竖幅造成内容侧转与 2250×3000 的错误裁切。附件实际比对确认内容转了 90°，不是单纯画布比例问题。结果 `/private/tmp/LumaFrontOrientationProbeFinalOct18.xcresult`。
- 采用 native portrait 前置传感器路径：照片连接 0°，关闭适用的旧传感器补偿；解码后规范化方向元数据为 1，避免系统再次旋转/镜像像素。旧设备及后置继续原 90° 路径。全部 7 种画幅使用红/蓝不对称图像编码验证：内容上下方向、比例、方向元数据和 EXIF 焦距均保留。
- 新前置目录 standard/wide 共用一个系统 Center Stage 超广角设备，以实际 zoomFactor 切换取景。优先可读的官方 supportedFramings 窄倍率（本机约 1.5855×），尚不可读时回退 1.6×；广角 1×。启动发现阶段检查所有支持格式，不仅看未启用设备的 activeFormat。删除被此路径取代的 batchFront/frontConfigurationOpen 多输入批处理。
- 第一轮尝试在旧普通前置端口按 31/20 放大，系统实际写成 36mm；该试验没有交付。单输入取景最终实测：原始 EXIF 及最终 EXIF 均为普通 31mm、广角 20mm（JPG/HEIF 各两张）。原始解码 3024×4032、4:3/12MP 设置处理后 3000×4000，最终方向 1；已目视检查编码文件 UIImage 与预览附件同向。结果 `/private/tmp/LumaFrontFilesFinalOct18.xcresult`，8 项真机通过，含文件元数据、镜像、实际 ISO/快门、40 次重复点击、取消/恢复、后置 HDR、12 次 M 焦段与 6 次 A/M 切换。
- iPhone 17 Pro，iOS 27.0.1，6 次前置宽窄往返：新帧恢复平均 0.132 秒（约 0.108–0.149），含既有动画平均 0.340 秒。旧多输入版同流程 6 次平均新帧 1.225 秒，前一轮输入事务优化版 0.535 秒。首轮进入前置不计入宽窄互切样本；设备/温度/场景会影响结果，不作为恒定耗时或 FPS。
- 前置普通和广角 Live 各一张，实际静态文件 EXIF 31/20mm，系统 PHLivePhoto 接受配对，音轨保留；每次 Live 后停止并恢复会话，均重新出帧。样张只存测试内存/临时资源，不进入用户系统相册。未声称已在真实系统相册界面人工验收。

### 连续 Live 回归发现并修复的启动时序

- 组合用例在前置 Live 测试结束后启动后续会话失败。只读记录为 App 前台、压力 nominal、无系统中断，但 requested=true、wantsRunning=false、running=false、recovering=true。单独后置 Live 通过并不能说明组合路径正确，失败结果保留 `/private/tmp/LumaFrontLiveInterruptionOct18.xcresult`。
- 保护新启动已发布但尚未执行到 session 队列的窗口：旧恢复通知不再推进 recoveryRevision 把该启动取消。session 队列接管运行意图后释放保护；启动本身仍检查运行/中断状态和新帧，真实后续故障沿用原有恢复。停止和权限拒绝清理保护。
- `/private/tmp/LumaFrontLifecycleFinalOct18.xcresult` 真机 3 项通过：4 轮启动、80 次迟到通知压力；前置 31/20mm Live 配对及两次停止/恢复；随后后置 JPG/HEIF Live 配对。最终 requested/wants/running 均为 true，没有扩大超时或放松运行断言。
- 模拟器最终 `/private/tmp/LumaFrontLifecycleSimFinalOct18.xcresult` 19 项：14 通过、5 真机专用跳过，0 失败；包含全部画幅像素方向、启动竞争与停止恢复。生命周期修补前的相机状态/自动切镜/微距回归 `/private/tmp/LumaFrontFilesSimOct18.xcresult` 35 项：30 通过、5 跳过。
- generic iOS Debug 构建成功，日志 `/private/tmp/LumaFrontDirectionDeliveryOct18.log`。本轮修改尚未同步到 LumaCamera_DeepSeek。

- 最终版已安装并启动到连接的 iPhone，未清除应用或相册数据。


## 2026-10-18 前后镜头切换性能

- 设备 iPhone 17 Pro / iOS 27.0.1。同一 runningAppCameraModel，JPG、HDR/Live 关闭、A 挡；每次触发 flipCamera 后再连续点 10 次，确认忙碌期间不会反向排队。新画面指标为目标镜头已发布、ready 且收到不同 UIImage；visible 为旧帧过渡图释放，5ms 轮询。不是 FPS 或传感器启动硬实时指标。
- 基线 8 次（每方向 4）：切后置新画面均值 1.775s、含过渡 1.986s；切前置新画面 1.032s、含过渡 1.200s。输入、预览、照片输出分开提交为主要耗时。基线 /private/tmp/LumaFlipBaselineOct18.xcresult。
- 单事务最终 /private/tmp/LumaFlipRegressionOct18.xcresult 的 8 次：新画面均值 0.507s（0.454–0.554），含原过渡 0.713s。能力补查 /private/tmp/LumaFlipCapabilityOct18.xcresult 再 8 次；两轮 16 次合计新画面均值 0.524s（0.428–0.924），含过渡 0.732s。有一次后置约 0.924s，不承诺每次小于 0.5s；初步优化试验 /private/tmp/LumaFlipBatchOct18.xcresult 也有一次约 0.994s。设备温度、光照、曝光和系统负载会影响结果。
- 最终真机组合 13 项通过：8 次 A 挡前后切换含 80 次忙碌点击，6 次 M 挡前后切换实际 ISO400、1/125s 保留，切换中停止/重开；前置镜像、普通/广角 JPG/HEIF 实际文件方向和 31/20mm；前置与后置 JPG/HEIF Live 配对；后置 HEIF Pro HDR 实际 10 位及署名；12 次 M 焦段、6 次 A/M；80 次迟到恢复通知。追加能力用例 1 项通过，4 次切回后置后 RAW/HEIF/像素与 ProRAW 能力和起始后置一致。诊断照片均截获在测试内存/临时资源，不写系统相册。
- 模拟器 /private/tmp/LumaFlipSimulatorOct18.xcresult 共 21 项，14 通过、7 硬件专用跳过，0 失败，含全部画幅方向与恢复竞争基础回归；不代替真机性能结论。
- 正常 iOS 构建 /private/tmp/LumaFlipDeliveryOct18.log 成功，已安装并启动连接的 iPhone，保留应用和照片数据。临时分阶段 print 已删除，仅保留测试日志。本次只修改主项目，未同步 LumaCamera_DeepSeek。


## 2026-10-18 同步前后镜头优化与前置修复到 DeepSeek

- 按用户指定方向 LumaCamera → LumaCamera_DeepSeek。同步 13 个代码/测试/文档文件：前后切换事务优化、前置单输入 31/20mm、照片方向、启动恢复保护和相关回归。目标差异均对应源项目已完成的改动，其他 770 个项目文件原先一致。
- 覆盖前目标备份 `/private/tmp/LumaDeepSeekFlipSyncOct18Backup`，附 manifest.json 记录原始及同步后 SHA-256。不修改 Xcode 用户设置和构建缓存。
- 上文真机性能和回归结果来自源项目，不表示已在目标路径重跑真机。同步后单独构建目标项目，结果另行补录。

- 目标项目 generic iOS Debug 签名构建成功，日志 `/private/tmp/LumaDeepSeekFlipSyncOct18.log`；构建后再次逐文件校验全部 783 个项目文件一致（排除 Xcode 用户设置、构建缓存和 .DS_Store）。本次仅同步和目标构建，未重复安装或修改手机数据。


## 2026-10-18 切换后短暂微距：自动路由初始化

- Apple 官方说明：虚拟多摄按倍率、焦距、对焦与曝光限制自动选择主供图设备，`.auto` 不限制系统切换；`activePrimaryConstituent` 可观测实际供图。参考 https://developer.apple.com/documentation/avfoundation/avcapturedevice/primaryconstituentdeviceswitchingbehavior-swift.enum 与 https://developer.apple.com/documentation/avfoundation/avcapturedevice/activeprimaryconstituent 。这些文档没有保证原生 Camera App 的专有稳定策略或固定初始化耗时。
- iPhone 17 Pro / iOS 27.0.1，固定 1 米以外远景基线 `/private/tmp/LumaMacroRouteFarBaselineOct18.xcresult`：4 次 M→A 全部先由超广角供图，约 0.626–0.692 秒的首次可采样状态为超广角，约 1.165–1.886 秒转回主摄；两次普通前后返回该轮已直接主摄。倍率约 1.458×（保持 M 挡实际构图），非单纯图标错误。50ms 轮询受会话队列阻塞影响，首次采样不等于精确第一帧时间。
- 修正非批量路径的输入替换顺序，目标倍率/连续自动 AF、AE、AWB 在输入提交前完成。普通前后批量路径本已在最外层提交前设置倍率，不重复启动健康控制器。保持系统 `.auto`、完整 fallback 候选和微距标识，不强制主摄或定时锁镜，不新增自动切镜动画。
- `/private/tmp/LumaMacroObservedFarOct18.xcresult` 用户保持远景并现场观察：4 次 M→A、2 次前后往返共 6 次，在每次切换后 3 秒采样中均为主摄、无微距提示；用户确认“这轮没有出现”。较早非受控轮在约 2 秒后仍曾记录超广角，未据此声称所有场景都无系统回退。
- `/private/tmp/LumaMacroNearInteractiveOct18.xcresult` 人工交互 20 秒：远景使用主摄、近物靠近触发超广角，移开记录到回主摄；主摄与真正微距均出现，系统策略始终 `.auto`，0 restricted conditions。该依赖人工移动的临时测试已移除，避免无人值守全量回归误判。没有拍摄或写入 Photos。微距退出速度与近远对焦轻微放大仍保留为独立未解决问题。
- `/private/tmp/LumaMacroRouteRegressionOct18.xcresult` 9 项中 8 通过、1 失败：失败旧用例在 session 队列屏障后立即读取被主动清空的 preview，未等异步新帧。测试修正为等待新 UIImage 与既有过渡释放，保留 1.5 秒目标，不扩大硬件参数容差。随后 `/private/tmp/LumaMacroFinalChecksOct18.xcresult` 3 项通过，含该外部锁镜恢复、实际 AE/AF/组合锁定与 EV、8 次前后切换。
- 上述真机组合已验证：系统 fallback 列表、0.5–40× 全范围、M 实际 ISO/快门、切换中停止/恢复、前置 JPG/HEIF 实际文件方向与 31/20mm、前后 Live 配对和声音、后置 HEIF Pro HDR 10 位与署名、连续场景通知不重启 AF。诊断照片仅内存/临时资源，不保存用户相册。
- 最终收窄修改范围后 `/private/tmp/LumaMacroFinalRouteOct18.xcresult` 5 项全部通过：系统自动候选和全变焦范围、4 次 M→A 与2次前后路由恢复、外部锁镜退出后新帧、后置 HDR 文件及8次连续前后切换。该轮前后新画面均值 0.565s、范围 0.444–1.014s，含过渡均值 0.772s；不能保证固定 0.5 秒。避免在普通批量前后切换时额外重启 AF/AE，保留上轮优化路径。
- 最终模拟器 `/private/tmp/LumaMacroRouteSimulatorOct18.xcresult` 19 项全部通过，包含微距图标判定、镜头过渡、启动恢复、7种画幅方向与目标锁定。正常 iOS 构建日志 `/private/tmp/LumaMacroRouteDeliveryOct18.log` 成功；修复版已安装并启动到 iPhone，未删除 App 或用户数据。本次主项目改动尚未同步 DeepSeek。


## 2026-10-18 微距初始化问题结项与 DeepSeek 同步

- 用户明确确认本问题已解决；README 与架构文档从当前已知问题中移出，保留微距退出偏慢及近远对焦视角变化两个独立待办。
- 从 LumaCamera 同步至 LumaCamera_DeepSeek，共 6 个代码、测试、文档文件；核对目标与上次同步 SHA-256／修复前备份一致，未发现目标独立修改。原文件备份 `/private/tmp/LumaDeepSeekMacroSyncOct18Backup`，附 manifest.json。保留 Xcode 用户设置和构建缓存。
- 源项目真机、现场验收与模拟器结果沿用上节记录，不把源码相同视为在目标路径重跑真机。目标构建结果和完整文件校验另行补录。
- 目标路径 generic iOS Debug 签名构建成功，日志 `/private/tmp/LumaDeepSeekMacroSyncOct18.log`。构建后对全部 783 个项目文件重新逐一校验 SHA-256，双方一致（排除 Xcode 用户状态、构建缓存及 .DS_Store）。本次仅同步和目标构建，未重复安装或改动手机数据。


## 2026-10-18 拍摄模式标签与前后切换图标

- 拍摄模式面板中“照片”下方的“当前模式”文字隐藏，保留原网格高度，避免其他模式按钮位置变化。
- 前后切换按钮去掉相机外框，改为纯环绕箭头，图标固定 22 点；点击时旋转 180°，约 0.32 秒，减弱动态效果时不做动画。
- `FixedCameraControlsTests` 与 `CameraViewModelTests` 共 19 项通过；已同步到 `LumaCamera`，同步后真机构建、安装和 19 项回归均通过。


## 2026-10-18 前置镜像开关同时作用于预览与照片

- 问题：预览取景一直按前置硬编码镜像，`mirrorFrontPhotos` 只更新照片输出连接，因此开关看起来无变化。
- 修复：`LivePreviewState` 增加 `mirrorFrontPreview`，由 `syncPreviewState` 从偏好同步；预览帧镜像改为读取该值，`setMirrorFrontPhotos` 同时刷新预览快照和照片连接。
- `CapturePreferencesTests.testFrontMirrorPreferenceAndRealHDRCaptureMetadataWithoutSaving` 增加预览镜像断言，真机通过。
- 后续发现横屏时左右镜像变成上下镜像：原因是镜像在 `PreviewRotation` 四分之一转之前应用。现改为先旋到显示方向，再对最终预览和峰值分析应用 `.upMirrored`；竖屏和横屏都保持水平镜像。真机已安装。未同步到 `LumaCamera`。


### 应用设置固定竖屏

- 应用本身 Info.plist 仅支持竖屏；设置页原先额外使用 `rotatingSheetContent()` 按设备姿态旋转。现已移除该容器，设置页固定竖屏。
- 设置页镜像说明改为“同时影响前置预览和照片”。真机已安装。未同步到 `LumaCamera`。


## 2026-10-18 自动居中功能取消

- 用户决定先取消前置自动居中功能；已移除“自动居中”开关、Center Stage 格式切换、支持状态、相关测试和文档说明。
- 保留前置双箭头广角切换、固定镜像、应用设置竖屏及其他既有改动。真机已安装。未同步到 `LumaCamera`。


## 2026-10-18 固定前置镜像与设置竖屏同步验证

- 已将固定前置镜像、镜像在显示方向后应用、移除镜像偏好/开关、应用设置固定竖屏、相关测试与文档同步到 `LumaCamera`。
- 同步后真机 9 项通过：前置镜像偏好测试、箭头符号、前置广角切换、反复前置切换；0 失败。真机 Debug 构建、安装、启动成功。日志 `/tmp/LumaSyncedMirrorTests.log`、`/tmp/LumaSyncedMirrorDevice.log`。
- 自动居中功能已取消，两工程均不包含该开关或自动居中控制；前置普通／广角仍共用支持动态画幅的系统超广角设备，按官方可用倍率切换取景。


## 2026-10-18 后续修改文档与功能复核

- 复核开始时 `LumaCamera` 与 `LumaCamera_DeepSeek` 的 783 个项目文件 SHA-256 一致。本轮只在主项目修正文档及前置 Live 元数据测试，未执行“同步项目”。
- 文档修正：README 和拍摄偏好文档改为前置预览、成片固定水平镜像，删除已取消的镜像开关说明；界面核对文档将切换后短暂误入微距标为已解决；架构说明区分 A 挡虚拟多摄和 M 挡物理镜头，并说明原生竖幅前置方向。自动居中开关与控制已移除，但前置宽窄取景仍使用支持动态画幅的系统超广角设备。
- 模拟器定向回归 `/private/tmp/LumaReviewOct18.xcresult`：34 项中 27 通过、7 项硬件专用跳过、0 失败；覆盖拍摄偏好、A/M 状态、固定按钮位置、前置入口与微距判定。模拟器结果不能验证真实镜头或照片元数据。
- iPhone 17 Pro / iOS 27.0.1 真机首轮 `/private/tmp/LumaReviewNativeOct18.xcresult`：5 项中 4 通过，前置 Live 一项因测试固定要求 31mm 而失败。普通前置 JPG/HEIF 的原始及最终 EXIF 均为 31mm，广角均为 20mm；固定镜像、HDR 10 位与署名、连续前置切换和 A/M 路由回归通过。前置宽窄 7 次切换中首轮新帧约 0.36 秒，其余 6 次约 0.10–0.15 秒；这是测试状态下的新帧时间，不代表恒定帧率。
- 真机原始数据对照 `/private/tmp/LumaReviewLiveFocalOct18.xcresult`：普通前置 Live 原始 EXIF 与最终文件均为 30mm，广角均为 20mm；两张 Live 都被系统识别为照片/视频配对，音轨保留，停止并重开会话后重新出帧。测试现在要求最终 EXIF 等于系统原始 EXIF，并接受 Live 普通取景 30–31mm 的系统取整范围；重跑 1 项通过。没有修改照片焦距元数据或相机生产代码，也没有将诊断照片保存到系统相册。
- 自动路由测试在非受控近景中有一次约 2.4 秒后由系统切到超广角，但模式切换后的首个可采样状态为主摄。该测试确认路由有效，不作为所有场景无微距的证明；此前用户受控远景验收结论保持。Live 编辑写入系统相册及长时间运行仍需单独验收。

### 本轮同步至 LumaCamera_DeepSeek

- 用户随后明确要求同步。仅同步上述复核产生的 5 份文档及 `FrontWideSelectionTests.swift`，目标原文件已备份到 `/private/tmp/LumaDeepSeekReviewSyncOct18Backup`，`manifest.json` 记录同步前后 SHA-256。同步前逐文件差异确认仅有这 6 个文件，没有覆盖其他独立改动。
- 目标工程单独进行 generic iOS Debug 签名构建，结果 `/private/tmp/LumaDeepSeekReviewSyncOct18.log` 为 `BUILD SUCCEEDED`。真机与模拟器测试来自主项目的同内容代码，未在目标路径重复运行，也未重新安装手机 App。


## 2026-10-18 工作区迁移验证

- 用户指定把主工作区迁移到 `/Users/shurrikann/MyProject/iOS/LumaCamera`。迁移前执行 `diff -rq`（排除 `.git`、`DerivedData`、`xcuserdata`、`.DS_Store`）：两个工程 784 个项目文件完全一致，差异仅为各处 `.DS_Store`；因此没有文件需要搬运，也没有目标侧独立改动被覆盖。
- 旧目录 `LumaCamera_DeepSeek` 保留在原位作为归档，不再是默认同步目标。README 中“从 `LumaCamera` 同步到 `LumaCamera_DeepSeek`”的约定已标记为失效；后续“同步项目”默认指当前工作区，除非用户另行指定。
- 新工作区独立验证：模拟器 Debug 构建 `BUILD SUCCEEDED`（`/tmp/LumaDerivedData`，Xcode 27.0 / iOS 26.5 模拟器）。定向回归 `CapturePreferencesTests`（6 项）与 `FixedCameraControlsTests`（3 项）共 9 项通过、0 失败，覆盖固定镜像偏好、固定按钮位置和七种画幅切换；结果 `/tmp/LumaDerivedData/Logs/Test/Test-LumaCamera-2026.10.18_17-57-42-+0800.xcresult`。
- 本轮只做迁移核对、文档更新和小范围构建/测试，没有修改相机生产代码。真机安装与硬件相关回归未在迁移后重复执行，设备数据沿用上一轮记录；模拟器结果不能替代真实镜头路由和照片元数据验证。
- 历史检查点归档 `LumaCamera_Checkpoint1.tar.gz`、`LumaCamera_Checkpoint2.tar.gz`（各约 34 MB）仍在项目上级目录，未移入工作区，保留与否由用户决定。

## 2026-10-18 前置自动构图开关

- Apple AVFoundation 真机探测：iPhone 17 Pro / iOS 27.0.1 的当前前置 4032×4032 取景格式支持 Smart Framing，照片格式可达 4032×4032 与 4896×4896；当前格式不支持 Center Stage。为保持现有照片规格和普通／广角单输入快速切换，采用 `AVCaptureSmartFramingMonitor` 建议倍率，不改用 Center Stage 视频格式。监测只启用竖幅 3:4 建议，系统变焦 ramp 平滑衔接；手动前置焦段或变焦接管时停止监测。
- 前置焦段条增加纯图标开关与 VoiceOver 标签，开关自身不重建输入／输出图。主动开关沿用焦段旧帧轻微模糊、新帧短淡出；自动推荐只平滑改变倍率，0.12 秒短暂稳定时间避免快速反复跳变。
- 真机前置专项 `/private/tmp/LumaSmartFramingRegressionOct18.xcresult`：9 项通过、0 失败；涵盖 8 次连续开关、手动广角接管、前后切换、M 挡曝光恢复、前置 JPG／HEIF 方向和原始焦距、前置 Live 配对与音轨。最终防抖版 `/private/tmp/LumaSmartFramingFinalOct18.xcresult`：开关及 Live 两项通过。最终版连续开关 8 次从点击到过渡结束约 0.246–0.313 秒，均值约 0.284 秒；这是当前设备短时操作完成时间，不是帧率，也不等于人物构图识别时延。测试未向系统相册保存诊断照片。
- 模拟器 `/private/tmp/LumaSmartFramingSimOct18.xcresult`：6 项通过，覆盖七种画幅下固定按钮位置、弹窗生命周期和图标资源；模拟器不用于验证自动构图的实体镜头能力。最终 iOS 真机 App 已安装并启动。人物进出画面时的实际构图策略仍由系统 Smart Framing 决定。


## 2026-10-18 视频与自动构图核对（历史记录，已被下文最终实现取代）

- 用户要求核对新增的视频和前置自动构图。核对期间曾临时修正测试编译、录像计时、录制完成判定和保存中按钮状态；用户确认全部回退，本轮最终只保留文档更新，生产代码和测试代码恢复原状。
- **测试 target 当前无法编译**：`LumaCameraTests/Library/BasicVideoSaveIntegrationTests.swift:31` 的 `memset` 第二参数为 `Int`，Darwin 接口要求 `Int32`。错误原文：`cannot convert value of type 'Int' to expected argument type 'Int32'`。临时改为 `Int32(index * 12)` 后可编译，该修正已回退。
- **视频真机结果**（iPhone 17 Pro / iOS 27.0.1，`platform=iOS,id=00008150-001934280220401C`）：`BasicVideoPhysicalTests` 通过。连续 3 次后置录像均为 1920×1080、约 30 fps、含音轨；首轮开始到可停止约 1.50–1.66 秒，第 2、3 轮约 0.02–0.06 秒；每轮约 1 秒、文件约 0.4–1.5 MB。前置录像可生成视频轨；切回照片后仍能正常拍照。样本量 3 轮，启动耗时受会话状态和温度影响，不代表固定性能。
- **自动构图真机结果**：`FrontWideSelectionTests.testFrontAutoCenteringToggleAndFrontWideRegression` 通过；连续 8 次开关从点击到过渡结束约 0.247–0.326 秒；手动选择前置广角后 `frontAutoCenteringEnabled` 变为 false，再选普通取景正常。该结果是短时操作完成时间，不是人物识别时延或帧率。
- **方向观察**：设备横放时前置录像为 1920×1080（natural 1080×1920 + 旋转/镜像 transform），后置录像为 1080×1920。前置角度按 `isCameraSensorOrientationCompensationSupported` 使用 0°，后置使用 90°；两种策略是否应统一尚未确认，本轮未修改。
- **模拟器回归**：临时修正 `memset` 后执行全量测试，已记录 299 项通过、7 项失败；运行在收尾前终止，不作为完整回归结论。失败项为 `CameraFilmProfileTests`（滤镜数量 46 vs 45）、`FilmColorLUTTests`（M9 颜色采样）、`FilterEditorLayoutTests`（找不到 UIScrollView）、`ImagingTests.testMonochromeProducesEqualColorChannels`、`ImportedFilterTests`（44/45 数量、插值）、`PhotoCropTests`（裁剪元数据）。初步判断与视频／自动构图无关，但未在基线工程复跑确认。
- **当前构建**：回退后模拟器 App 构建 `BUILD SUCCEEDED`；测试 target 因上述 `memset` 仍无法编译，未再执行模拟器或真机测试。
- **未修改的已知问题**：录像计时从快门请求开始、后台停止或启动失败后可能继续；完成回调只检查文件非空，未检查 `AVErrorRecordingSuccessfullyFinishedKey`；视频保存期间快门按钮仍显示可用；视频查看页没有左右滑动翻页；视频模式下的自动构图和关闭后恢复取景未验收。


## 2026-10-18 视频模式初版与文档同步（阶段记录）

本节保留初版实现和当时的测试结果；缺少 30fps 选项、测试编译阻塞、快速切换排队、保存期间快门状态及 HUD 自动化覆盖等问题已由下一节修正，不作为当前待办。

- 模式切换：底部按钮改为照片/视频直接切换，不再打开拍摄模式弹窗；按钮图标随模式切换为相机/摄像机并随横竖屏旋转。拍摄模式面板中的“点击切换”和延时/慢门/慢动作入口已移除。
- 顶部视频工具栏五项等宽：分辨率/帧率、比例、色彩空间、视频格式、设置；前四项打开同款玻璃弹窗。分辨率 720p/1080p/4K，帧率 24/25/50/60/120，比例 4:3/1:1/16:9/2:1/2.35:1，色彩空间 SDR/P3/HDR/Apple Log/Apple Log 2，格式 HEVC/H.264/ProRes 及六种 ProRes 规格。除比例外目前只保存选择并更新显示，录制仍固定 HEVC 1080p30。
- 录制管线：`AVCaptureVideoDataOutput` + `AVCaptureAudioDataOutput` + `AVAssetWriter` 直接编码，默认 HEVC 1080p30、约 12 Mbps，AAC 128 kbps/48 kHz 双声道；通过 `AVVideoScalingModeResizeAspectFill` 在编码时裁切比例，`AVAssetWriterInput.transform` 处理旋转/镜像，不再二次编码。比例在开始录制时锁定。
- 视频 A/M：进入视频默认 A，可切换 M 并显示照片同款六个参数按钮；录制中禁止切换。视频滤镜按钮可打开列表但不影响成片。
- 视频拍摄辅助：参考线、直方图、峰值、水平仪、翻转、剩余时间开关、声音电平开关、延时/慢门/慢动作占位；不显示水印和倒计时。照片辅助保留水印、倒计时、夜景、人像、连拍。
- HUD 与直方图：剩余时间面板和横向 L/R 电平在预览框内右上角、距边框 5 点；剩余时间用系统可用容量和固定码率估算，每 10 秒刷新。直方图在预览左上角，横屏只旋转内容（0.22 秒动画），顶部按 `max(5, hudTop)` 避让工具栏，位置不换角。

### 验证

- 真机 `BasicVideoPhysicalTests`（iPhone 17 Pro / iOS 27.0.1）在 AVAssetWriter 管线后通过：连续 3 次 HEVC 录像均为 1920×1080、约 30 fps、含音轨；前置录像、切回照片后拍照正常。
- 临时 4:3 诊断测试通过：成片显示尺寸 1080×1440、含音轨；临时测试文件与 `memset` 临时修正已移除。
- App 模拟器与真机 Debug 构建均成功，最新版本已安装到连接的 iPhone。
- HUD、声音电平、直方图旋转和开关属于界面改动，未加入自动化测试；模拟器无法验证真实麦克风电平。
- 测试 target 仍因 `BasicVideoSaveIntegrationTests` 的 `memset` 参数类型错误（`Int` 应为 `Int32`）无法编译，最终全量回归未执行。

### 已知问题

- 4K/120 fps/P3/HDR/Apple Log/H.264/ProRes 及 ProRes 规格只做选择显示，没有接入录制。
- 快速连续切换照片/视频会排队多轮会话重配，预览短暂停顿后自行恢复；尚未做请求合并/防连点。
- 视频保存期间快门外观仍可用，但点击不会开始新录制。
- 视频查看页没有左右滑动翻页。
- 延时/慢门/慢动作、夜景/人像/连拍仍为入口占位；夜景/人像没有公开系统 API。

## 2026-10-18 视频稳定性修复与六档帧率（最新）

覆盖上文视频稳定性相关旧待办，保留其他功能边界。

- 修正 `BasicVideoSaveIntegrationTests` 的 `memset` 参数为 `Int32`，测试 target 现在可以编译。
- 帧率选项为 24、25、30、50、60、120，30 默认选中。其余规格仍是选择显示，本轮没有把所选帧率接入录制；实际保持 HEVC 1080p30 SDR。
- 复现生命周期停止后计时继续：录制状态已关闭，650ms 后计时仍增加约 0.615s。修复后由首帧成功追加触发录制状态，ViewModel 订阅状态启动/停止单调时钟；启动失败不计时，主动停止、离开相机、系统中断和写入失败均结束计时。
- 录制器创建、视频/音频追加和 finish 限制在同一 `camera.recording` 串行队列，消除原先三个队列对 `movieRecorder`、`sessionStarted` 和 `finished` 的无同步访问。收尾中重复停止不再提前释放 busy。尚无首帧的取消清理临时文件，不作为错误照片保存；失败写入也清理残留文件并返回真实错误。
- 保存期间快门禁用并在按钮内部显示加载圈，收尾与录制中的圆点/方块保留局部动画。
- 快速模式请求按最新修订合并，相同配置跳过重配；首次麦克风权限请求避免重复发起。
- 视频 HUD 根据内容实际尺寸交换横屏布局宽高，保持旋转后的面板在预览边界内；直方图调试测量点改为图表自身，而不是铺满预览的外层容器。没有更改控件固定位置或系统自动切镜逻辑。

验证设备为 iPhone 17 Pro / iOS 27.0.1；最新针对性真机回归 41 项通过，0 失败。覆盖连续三次后置 HEVC 录像、前置录像、返回拍照、后台停止、立即取消和重复停止；五种视频比例 × 四个控件方向共 20 个 HUD/直方图边界组合；帧率弹窗在 320 点和真机 402 点宽度截图；60 次选项/弹窗操作；照片保存、相册刷新/删除和翻页状态。

可重复指标：三次后置实际写入首帧等待为 1.619s、0.022s、0.021s；视频均 1920×1080、30fps、含音轨，约 1.03–1.10s。100 次排队模式请求只执行 1 次最终会话配置，含等待完成约 2.27s；这不是单次切换延迟或界面 FPS。生命周期停止后额外等待 650ms，计时增量为 0。20 个 HUD 组合约 6.44s，包含每次 300ms 动画等待，不作为渲染性能数字。

模拟器针对性回归合并去重后 57 项通过、1 项 PhotoKit 写入集成用例因权限跳过。首次 HUD 检查的相交断言因调试测量指向整个预览而失败；修正测量点后重跑布局检查通过。曾尝试单独申请模拟器 Photos 权限，等待授权未完成，该次运行已中止并恢复为无授权时跳过；不把此轮当作写入成功。没有向用户真机相册保存诊断照片或视频。

结果：`/tmp/luma-video-final-physical-oct18.xcresult`；模拟器最终布局及启动失败/保存中状态检查：`/tmp/luma-video-sim-derived/Logs/Test/Test-LumaCamera-2026.10.18_23-29-10-+0800.xcresult`。真机测试已安装最终版；收尾后的主动启动因再次锁屏被系统拒绝，可在解锁后自行打开。

局限：这是针对本轮改动的回归，不是全量测试；既有滤镜等历史失败项本轮未处理。音轨存在不等于完成长期音画同步验证，串行化与短时压力测试也不能证明所有中断和长时间录像均无故障。视频详情左右翻页、其他编码/色彩空间及真实多帧率录制仍未实现。

### 文档整理与维护范围

- 已将本轮更新、修复、回归结果及实际录制限制汇总到 README 开头，并将视频初版记录标为阶段记录，避免把已修复问题继续列为当前待办。
- 按用户最新要求，代码、测试和文档仅维护 `/Users/shurrikann/MyProject/iOS/LumaCamera`；不再同步到 `LumaCamera_DeepSeek` 或其他项目。此前同步记录保留作历史追溯，协作规则已同步更新到主项目 `AGENTS.md`。
- 本次仅整理文档，未修改功能、未重新构建或执行测试；上文测试数字均来自已完成的同轮验证。

## 2026-10-19 照片切视频取景停顿优化

- 真机基线确认：切换录制输出/preset、连接麦克风、重新配置预览分别提交会话事务，产生多轮管线重启。麦克风阶段约 0.65–0.70 秒，预览连接阶段约 0.63–0.71 秒。
- 将录制输出、麦克风、preset、预览及照片输出辅助配置纳入同一个外层 `beginConfiguration` / `commitConfiguration`；内部嵌套事务不再单独提交到硬件。离开视频仍移除录制输出，不以常驻录制管线换取速度，不改变自动微距或物理镜头选择。
- 补查发现并修正切换顺序：进入视频先恢复照片 HDR 的原格式，再设置 1080p preset，避免 HDR 退出覆盖视频规格；返回照片先移除视频输出，再启用 Live/HDR，避免在录制管线上探测 Live 能力导致开关被误关闭。
- 新增 `VideoModeTransitionTests`，记录三轮往返的会话任务完成时间与新预览帧时间，并覆盖 Live、HEIF HDR、M 挡照片往返视频。临时分阶段诊断打印已移除，仅保留 DEBUG 下线程安全的预览时间测试读取入口。

性能：iPhone 17 Pro / iOS 27.0.1，同一设备三轮普通照片→视频，基线新预览帧恢复为 1.996、2.122、2.105 秒，平均 2.074 秒；最终版为 0.684、0.730、0.689 秒，平均 0.701 秒，缩短约 66%。最终版视频→普通照片为 0.700、0.686、0.681 秒。指标从主线程发起模式切换计至会话任务完成后接受到的新预览源帧，不等同屏幕最终呈现时间或 FPS；不涵盖所有镜头、HDR/Live、冷启动和光照下的延迟。

最终真机针对性回归 **9 项通过、0 失败**（约 82.55 秒）：三次后置与一次前置录像及音轨、切回拍照、后台停止计时、立即取消/重复停止；100 次排队模式请求只配置一次；Live JPEG/HEIF 动静配对与手动参数多次重启恢复；HDR 关闭无黑帧；Live/HDR/M 挡照片往返后恢复，三种来源录制均为 1920×1080；五种视频比例 × 四个控件方向 HUD 边界及窄屏帧率菜单。M 挡往返核对了手动标志、ISO 200、1/125 秒设置和实际 ISO 读数。

证据：基线 `/tmp/luma-mode-baseline2-oct19.xcresult`；最终 `/tmp/luma-mode-final-oct19.xcresult`，日志 `/tmp/luma-mode-final-oct19.log`。中间扩展用例曾检出 Live 状态丢失和 HDR 输出尺寸错误，调整配置顺序后重跑通过，不将中间失败计为通过。诊断资源仅存测试临时目录，未加入用户系统相册。最终构建已由真机测试安装；本轮仅维护主项目，无跨项目同步。

范围：实际录像仍为 HEVC 1080p30 SDR；未增加其他帧率、色彩空间或编码能力。本轮是切换及相关功能回归，不是全量测试，也未覆盖长时间录像的功耗和音画同步。

交付确认：最终回归后使用 `xcrun devicectl device process launch` 成功启动 `com.shurrikann.LumaCamera`，确认修复版已安装并能在连接的 iPhone 上打开。README 与架构文档已补齐本轮摘要、实现和测试入口。本次补充仅修改主项目文档，未重新执行测试，未同步其他项目。

## 2026-10-19 横屏水平仪、真实视频规格、详情与 2.39:1

本节覆盖此前“视频分辨率/帧率仅选择显示、固定 1080p30”和 2.35:1 的当前状态；旧记录保留为历史，不表示仍未接入。

实现：

- 水平仪重力角以最近的 0/90/180/270 度参考计算倾角，内容随相机控件方向旋转；高亮与触感门限共用 LevelHapticGate 的迟滞、稳定保持和冷却。照片和视频复用同一组件，几何布局不改。
- 720p、1080p、4K 与 24/25/30/50/60/120 fps 接入传感器 activeFormat、最小/最大帧间隔和编码器设置；依据当前路由能力禁用组合，换镜后回退到可用组合并同步工具栏。能力缓存按设备复用，快速设置请求按修订合并；配置期间在快门显示加载圈。恢复到原设置值也会通知界面，避免“显示 120、实际 60”。
- 实际编码仍为 HEVC SDR，明确写 BT.709 色彩信息；目标码率按分辨率像素数与帧率缩放，最低 4 Mbps，剩余时间随码率估算。录制改用 8-bit YUV 缓冲，预览仍独立限制尺寸/渲染频率；动态前置不设置其不支持的固定缓冲尺寸，而在编码时一次缩放裁切。手动快门上限受当前帧间隔限制。
- 视频详情复用照片的日期、设备与文件卡片、参数卡片、位置地图及玻璃浮层；不缩小播放画面。读取轨道实际尺寸、方向、帧率、编码、时长、码率、色彩与音频，缺失字段不编造。录制时保存日期、设备、可选位置/署名，以及开始时 ISO、快门、EV、光圈、倍率、镜头、白平衡和色调快照，明确说明自动参数可能继续变化。读取进度位于详情按钮，退出页面取消任务并忽略晚到的加载回调。
- 视频/照片共用工具栏轻触、选项选择和底部按钮的触感实现；重复选择已选选项不额外震动，分辨率/帧率切换沿用局部取景过渡及超时释放，不增加系统自动切镜动画。
- 拍照和视频的电影比例统一改为 2.39:1，预览和实际裁切共用 FrameRatio.cinema；编码尺寸取最近偶数像素。旧照片中的比例元数据不重写，原生 DNG 继续保留传感器画面。当前比例选择没有磁盘持久化的旧枚举需要迁移。

真机：iPhone 17 Pro / iOS 27.0.1。两轮针对性回归分别 **15 项通过**（约 122.70 秒）、**12 项通过**（约 80.77 秒），合并去重 20 项；第二轮含最终 2.39:1 和工具栏回退修正。模拟器先行回归 7 项通过；模拟器结果不作为实际硬件规格证据。

可重复指标及文件核验：

- A 挡虚拟多摄开放三种分辨率 × 24/25/30/50/60 共 15 组，全部实录约 1.2 秒并核对轨道尺寸、平均帧率、时长、声音、预览持续更新和详情解析；矩阵约 23.54 秒，结束时 thermalState=nominal（只代表当时状态，不等于功耗/温升测量）。
- M 挡物理主摄三种分辨率均提供 120 帧，最终短片实际 nominalFrameRate 分别为 120.13、118.81、117.49；4K120 有少量掉帧，不承诺长期恒定 120 帧。此前另一轮 4K120 为 114.73，样本约 1.5 秒，不能据此证明长时间录制稳定性。
- 前置 1080p30 和 4K60 均实录，显示尺寸分别 1080×1920、2160×3840，含 AAC 双声道 48kHz；高帧率主摄切前置后的不可用档位自动回退。
- 2.39:1 的 JPEG、HEIF 实际均为 1674×4000（像素取整）；前后镜头五种视频比例共 10 个实录，720p 基准显示尺寸依次为 720×960、720×720、720×1280、640×1280、536×1280，矩阵约 6.92 秒。全部按解码文件/轨道 transform 检查，不以菜单文字代替。
- 水平仪布局覆盖照片七比例、视频五比例 × 四方向，共 48 个组合，约 12.89 秒，包含每次 260ms 的等待，不能视作 FPS。另导出 0/±90/180 度水平与倾斜快照、320/402 点视频详情卡片并人工查看；设备上的方向注入不是人工旋转手机和主观触感体验。复用 CameraView 局部内容的测试宿主仍有读取未安装 Environment 的提示，子组件的旋转环境正常安装，以上边界检查不替代完整实机交互检查。
- 新版照片→视频三轮新预览源帧恢复 0.695、0.702、0.728 秒，平均约 0.708 秒；切换提速没有退回到原来的约 2 秒。100 次模式请求仍仅提交一次配置，约 1.10 秒；停止后额外等待 650ms，录制计时增量 0。
- 同轮回归覆盖连续录像、前置录像、声音、返回拍照、Live JPEG/HEIF 配对、HDR 关闭无黑帧、M 挡参数恢复、立即取消与重复停止。未向用户系统相册保存诊断照片或视频。

证据：`/tmp/luma-specs-final-oct19.xcresult`、`/tmp/luma-specs-delivery-oct19.xcresult`；日志同名 `.log`。截图导出到 `/tmp/luma-specs-delivery-attachments/`；模拟器为 `/tmp/luma-specs-sim-oct19.xcresult`。中间 `/tmp/luma-cinema-final-oct19.xcresult` 的恢复用例曾受上一用例残留 2.39 比例影响，误把正确 1920×804 裁切输出按 1920×1080 断言；显式隔离并恢复比例后重跑通过，未把该轮失败记为通过。

限制：P3/HDR/Apple Log 和其他编码仍未接入，视频滤镜未启用；这不是全量测试，也未验证长时间高规格录像的功耗、温升、音画同步与所有系统中断路径。实际物理触感强度不能由自动化断言保证。主项目文档已更新，无跨项目同步。

交付：最终构建已通过真机测试安装，随后 devicectl 启动成功；手机可直接体验本轮功能。

## 2026-10-19 ProRes 八种编码兼容性核验（非功能接入）

> 本节为接入前的历史核验；当前功能状态见本文后续“实际视频编码与外接 RAW 分支”。

### 弹窗选项及禁选联动

视频格式弹窗新增 RAW、RAW HQ，三列展示八项。HEVC/H.264 下整组规格禁用；ProRes 下允许六项常规规格，RAW 两项始终禁用并提供无障碍原因。选择入口同步校验格式、RAW 禁选和录制忙碌状态，切换编码格式不清空已选规格。仍为选项设置，正式录像编码尚未接入 ProRes。

真机 iPhone 17 Pro / iOS 27.0.1：`ProResOptionsLayoutTests` 一项通过，覆盖 HEVC/H.264 禁选、RAW 拒绝选择、切回 HEVC 保留规格，以及 240 次选择/打开/关闭循环（约 0.00484 秒，仅模型操作耗时，不是 UI FPS）。弹窗以 304/386 点宽、四个控件角度共八组宿主布局绘制，检查宽度并导出两张真机截图，人工核对八项完整显示、长名称未截断、RAW 置灰。由于宿主仅显示弹窗，角度注入不代表设备物理旋转操作或完整相机页遮挡回归。测试耗时约 2.34 秒，未进行长时间功耗测试。证据 `/tmp/luma-prores-options-final-oct19.xcresult`；截图 `/tmp/luma-prores-options-final-attachments/`。未拍摄或写入系统相册。

### 编码能力与存储条件

设备：iPhone 17 Pro / iOS 27.0.1。仅修改测试与文档，没有将 ProRes 加入正式录制流程；所有输出使用应用临时目录，未加入系统相册，不涉及外接存储访问授权。

- `ProResCompatibilityPhysicalTests`：六种常规规格 422 Proxy / LT / 标准 / HQ、4444 / XQ，各在 1080p30、4K30、4K60、4K120 的时间戳设置下编码 24 帧合成画面，共 24 组；再用后置主摄取得的一张实际 3840×2160 BGRA 画面，各编码 24 帧为 4K30，共 6 组。30 组均由硬件编码器成功生成对应 codec 的压缩帧，机内 MOV 写入完成，并可解码首帧。常规 4K 合成 24 帧的渲染加编码耗时约 0.108–0.198 秒，实际相机静帧编码约 0.110–0.195 秒；热状态为 nominal。该指标不是相机实时帧率，重复单张相机画面不等于连续采集；不据此承诺 4K120 持续录制、音画同步、原生 4:4:4 色彩采样或高位深/透明通道质量。证据 `/tmp/luma-prores-camera-oct19.xcresult`，两项测试通过；日志同名 `.log`。
- 初次 RAW 格式探测只覆盖 16VersatileBayer 与 DownscaledProResRAW，漏掉当前设备的 `kCVPixelFormatType_96VersatileBayerPacked12`。已补齐，不能以旧探测的空列表认定设备不支持 RAW。实际后置主摄报告 12 位 packed Bayer（`btp2`）格式：4224×2240 的最高 60/120 fps 两种格式、4224×3024 最高 60 fps；这是格式能力枚举，不是相应帧率已完成录制。
- `ProResRAWPhysicalTests` 选用 4224×2240 / 30 fps 真实 RAW 格式，锁定白平衡、关闭 MovieFileOutput 的 deferred start 后启动。系统同时报告 `aprn`（RAW）与 `aprh`（RAW HQ）可用。分别向机内临时 URL 调用 MovieFileOutput 录制，以及 VideoDataOutput 的 `recommendedVideoSettings(...outputFileURL:)`，四次均返回相同 Objective-C 配置异常：`Capturing ProRes Raw codec is supported only on external storage device.` 后一路返回的 settings 为 nil，不能据此构建受支持的机内 RAW 写入流程。
- 因此 RAW / RAW HQ 的结论为“设备具备真实采集格式与编码器；当前官方采集写入路径要求外接存储，机内录制不可用”。本轮没有生成可播放 RAW 文件，未完成 RAW 文件帧率、持续录制或解码验证，也未承诺外接存储完整录制通过。
- 首轮 RAW 调用因系统抛出 NSInvalidArgumentException 导致诊断测试进程终止，见 `/tmp/luma-prores-raw1-oct19.xcresult`，该轮不计通过。新增仅测试 target 使用的 Objective-C 异常捕获辅助与测试桥接头后，能安全记录系统拒绝原因，避免再次终止进程；未将异常捕获加入产品业务流程。
- 最终 `/tmp/luma-prores-raw3-oct19.xcresult` **2 项通过、0 失败**：RAW 两档两条路径的兼容性结果核验，以及现有 HEVC 三次后置、一段前置、音轨与返回拍照回归。这里“RAW 测试通过”仅表示正确识别并安全记录机内存储限制，不代表 RAW 成片成功。日志 `/tmp/luma-prores-raw3-oct19.log`。未进行长录功耗或全量功能测试，未向其他项目同步。

## 2026-10-19 实际视频编码与外接 RAW 分支

### Xcode 水平仪组件索引提示核对

用户报告 `CameraViewfinder.swift:76 Cannot find 'CameraLevelIndicator' in scope`。组件文件实际存在于 `Features/Camera/Components/CameraLevelIndicator.swift`，且已列入主 target 的 SwiftFileList。使用独立全新构建目录 `/tmp/luma-level-scope-check-oct19`、generic iOS、`CODE_SIGNING_ALLOWED=NO` 构建通过，日志 `/tmp/luma-level-scope-check-oct19.log`。随后在用户当前 Xcode 工程窗口执行 Build，界面显示 Build Succeeded（10:36），Issue Navigator 为空，原 Predicted Error 提示消失。结论为编辑器索引残留，本轮未修改源代码或组件行为，无需以新增重复定义规避提示；不声称进行了新的相机硬件功能回归。

### 实现范围

HEVC、H.264、ProRes 422 Proxy / LT / 标准 / HQ / 4444 / 4444 XQ 从菜单接入采集与 AVAssetWriter。编码及规格在录制期间禁改，硬件编码器列表缓存后用于禁选与回退；H.264 不接受 HDR/Log，自动回退 SDR 并同步工具栏。详情读取压缩轨道的真实 codec，ProRes 不使用 HEVC 的 profile 或目标码率。ProRes 估算容量使用典型档位码率，并非恒定码率承诺。

SDR/P3/HLG HDR/Apple Log/Log 2 的采集、预览和文件标记已接入。HDR 预览使用 16 位组件的高动态范围图像、P3 使用 Display P3；Log 为平坦代理预览，不套滤镜。Apple Log 写入属性按 iOS 27 开放，旧系统不伪装成 SDR/HLG。Log 1 文件标记 Rec.2020 + Apple Log；Log 2 使用 Apple Log 2 标记，不错误填入 Rec.2020 primaries 或普通 transfer。

`ExternalVideoStorage` 按官方发现/KVO、授权、连接、系统推荐状态和大于 2GB 的保守余量判断目的盘；授权只在发现合适磁盘后请求。RAW/RAW HQ 还要求当前逻辑镜头具备 Bayer 格式。选择后走物理 RAW 路由、4K 档位与原始画幅，禁用任意比例和色彩选择；系统代理供预览，原始数据直接 append 到采用官方推荐设置的 writer，保留系统校准元数据，白平衡锁定在完成/失败后恢复。外接 MOV 使用 security-scoped URL，完成后留在外接盘，不导入相册后删除原文件。发现拔盘时停止 RAW、完成后回退 HEVC，开始录制前重新检查目的盘。

用户本轮没有 SSD，已明确同意先完成代码和可验证部分。因此**真实接盘授权、RAW/RAW HQ 写入、解码、拔盘中断及重新连接恢复均未完成实盘验证**；不能将条件门控或本轮测试通过写成外接 RAW 已完整验证。旧系统的推荐状态采用官方旧属性，新 SDK 使用详细原因集合。外接盘格式按 Apple 指引使用 exFAT、非密码加密、USB3 10Gbps 连接；普通 ProRes 4K60/120 的 220/440MB/s 门槛不能直接保证所有 RAW HQ 规格。

### 真机结果与指标

设备 iPhone 17 Pro / iOS 27.0.1，所有诊断资源只存临时目录并清理，未写用户系统相册。

- `/tmp/luma-codecs-regression-oct19.xcresult`：**7 项通过、0 失败，约 105.32 秒**。12 组真实编码/色彩短片；A/M × 五种 HEVC 色彩共 10 组，实际轨道依次为 8 位 Rec.709、8 位 P3、10 位 HLG2020、10 位 Apple Log、10 位 Apple Log 2，逐项核对真实标记与帧率、HDR/P3 预览图像属性，再返回照片实际拍 JPEG。包含连续录像、前置、音轨、Live/HDR/M 挡照片往返和 UI 弹窗。色彩矩阵约 44.44 秒。照片→视频三轮新源帧恢复 0.706、0.717、0.727 秒，平均约 0.717 秒；不等于屏幕呈现延迟或 FPS。
- `/tmp/luma-codecs-final4-oct19.xcresult`：**6 项通过、0 失败，约 41.78 秒**。其中编码矩阵 **22 组短片，约 31.75 秒**，包含 HEVC、H.264 SDR/P3、六种常规 ProRes、ProRes HLG/Log/Log 2、H.264 4K60、ProRes HQ 4K60/120、4444 XQ 4K120、ProRes 全部五种比例、A 挡及前置。核对真实 codec、HDR/Log 文件标记、尺寸比例、轨道 nominalFrameRate 和首帧解码；4K120 两段轨道为 120fps、时长约 1.02 秒。另覆盖无 SSD 时 RAW 禁选、外接资格策略的断开/未知空间/空间不足/系统警告分支、H.264 HDR 回退、240 次弹窗选择开关、两种窄宽与四个角度布局、100 次排队模式请求及生命周期停止计时。两轮合并去重 11 项测试，不是全量测试。
- 画幅实例：ProRes 1080 基准下 4:3 为 1440×1080、1:1 为 1080×1080、16:9 为 1920×1080、2:1 为 1920×960、2.39:1 为 1920×804；首帧均可解码。轨道 transform 与当前前置路径保持原实现。
- 本轮循环期间系统热状态为 fair；未测长期功耗/发热、长时间音画同步、全部镜头的所有帧率色彩组合，也未逐帧统计长录掉帧。文件 nominalFrameRate 为 120 不等于持续恒定 120 帧保证。4444/XQ 编码不意味着相机源图就是 4:4:4；高帧率的基础源格式可能为 8 位/4:2:0，不编造源精度。

### 中间失败及修正

- ProRes 原生 x422 设备格式不接受旧 BGRA 预览设置，曾触发诊断进程的系统配置异常。录制与预览分别按当前输出的 availableVideoPixelFormatTypes 选择有效像素格式后重跑通过；不把早期进程终止计为成功。
- x422 的 4K120 完整双输出图配置导致相机无法恢复，见 `/tmp/luma-codecs-final3-oct19.xcresult`，失败 2 个断言。超过 60fps 改用基础采集格式，减少采集带宽，仍只做一次 ProRes 编码；最终两段 4K120 短片通过。不能用之前合成帧的编码成功代替这个真机失败。
- 新增测试首次有 async 断言编译问题，硬件编码能力探测首次用了 SDK 未提供的函数，均已修正；最终采用 VTCopyVideoEncoderList 的硬件加速字段。一次最终测试启动因锁屏/信任预检被阻止，解锁后继续，不计作功能失败或通过。
- 最终无 Swift/Objective-C 编译警告；Xcode 仍输出无 AppIntents.framework 依赖的通用元数据提取提示。证据日志与上述 xcresult 同名。主项目 README、架构及协作状态已更新，不向其他项目同步。

## 2026-10-19 状态栏背景改为纯黑

- 相机页顶部状态栏区域（系统时间、信号、电池）背景由灰色渐变改为 `Color.black`，顶部工具栏本身的深色渐变保持不变。
- 真机 iPhone 17 Pro / iOS 27.0.1 构建、安装、启动成功；截图 `Preview/Main-Camera-StatusBar.png`，状态栏与工具栏之间色差已消除。
- 纯视觉改动，未新增自动化测试；未涉及相机硬件或视频编码行为。


## 2026-10-19 主背景改为纯黑

- 相机页主背景 `glassBackground` 由黑色系渐变改为 `Color.black`，预览留白同步为纯黑；顶部状态栏此前已改为纯黑。原有半透明光晕保留，未改动任何带透明度的材质。
- 弹窗、曝光条、按钮的玻璃材质未改，避免影响可读性和点击热区。
- iPhone 17 Pro / iOS 27.0.1 构建、安装、启动成功；截图 `Preview/Main-Camera-Black.png`。纯视觉改动，未新增自动化测试。


## 2026-10-19 保存拍摄设置开关与相册视频图标

- `CapturePreferences` 新增 `saveCaptureSettings`，缺失字段时默认 `true`，关闭后写入 UserDefaults；应用设置 → 偏好设置新增同名 Toggle。当前不读取该开关恢复拍摄设置，footer 明确写明“仅记录开关偏好”。
- 测试：模拟器 `CapturePreferencesTests` 6 项通过，包含默认值、关闭后持久化、旧偏好数据迁移。
- 相册视频缩略图右下角由 `formatBadge("视频")` 改为 `video.fill` 图标，保留黑色半透明底和“视频”辅助功能标签；文字提示不再显示。
- iPhone 17 Pro / iOS 27.0.1 构建、安装、启动成功。视频图标为纯视觉改动，未新增 UI 自动化测试；未验证真实相册中每条视频单元格的图标位置，只按共享的 `photoTile` 布局核对。


## 2026-10-19 视频详情界面统一

- `SystemVideoView` 改为照片详情的顶部日期信息与底部分享/信息/相机/删除操作栏；视频专用返回按钮和右上摄像机图标已移除。
- 右下角新增视频图标标识，使用与相册缩略图一致的半透明黑底；RAW、LIVE、滤镜等标识存在时由 `HStack` 横向并排。
- 视频信息面板继续使用 `PhotoInfoPanel(isVideo: true)`，加载状态接入。
- iPhone 17 Pro / iOS 27.0.1 构建、安装、启动成功。模拟器相册导入视频后仍显示为空，未能取得视频详情运行截图；本轮只完成代码与构建核对，未声称界面截图已验证。未新增 UI 自动化测试。


## 2026-10-19 视频详情弹窗对齐照片详情

- 视频详情弹窗改为与 `PhotoViewerLayout` 相同的底部浮层：横屏高度 `min(340, width-28)`，竖屏 `min(540, height*0.72)`，左右 8 点、底部 6 点，背景 8% 黑色遮罩，滑入 + 淡入；减弱动态效果时只淡入。
- 允许弹窗覆盖底部播放操作栏，未再为播放条预留 76 点底部间距。
- iPhone 17 Pro / iOS 27.0.1 构建、安装、启动成功。模拟器相册无视频，未取得弹窗运行截图；布局参数与动画曲线按共享实现核对，未新增 UI 自动化测试。


## 2026-10-19 视频详情补滤镜入口占位

- 视频详情底部操作栏在相机与删除之间增加 `slider.horizontal.3` 按钮，位置、图标和样式与照片详情的编辑/滤镜入口一致；辅助功能标签为“视频滤镜”。
- 当前点击只显示“视频滤镜待支持”提示，不打开编辑器、不修改视频、不新增导出路径。
- iPhone 17 Pro / iOS 27.0.1 构建、安装、启动成功；未新增 UI 自动化测试，未取得运行截图。


## 2026-10-19 视频时长、精简播放条与详情纯黑背景

- `LibraryPhoto` 新增 `duration`，系统相册映射对视频写入 `PHAsset.duration`；相册缩略图右下角改为 `m:ss` / `h:mm:ss`，未知显示 `--:--`。
- 视频详情移除 `video.fill` 标识；播放器由 `VideoPlayer` 改为 `AVPlayerLayer` + 自定义常驻播放条（340 点宽、细轨、拖点、播放/暂停、当前/总时长、音量条与静音按钮），放在相机按钮正上方。播放条不自动隐藏，允许被详情弹窗覆盖。音量只作用于 `AVPlayer.volume`，不修改系统音量。
- 视频详情与照片详情的基色、底部操作栏背景改为纯黑；`PopupSurface`、日期胶囊、信息面板等半透明材质未改。
- iPhone 17 Pro / iOS 27.0.1 构建、安装、启动成功，无 Swift 编译警告。模拟器相册仍为空，未取得时长标识和播放条运行截图；未新增 UI 自动化测试。`GalleryPhotoPagingTests` 与 `PhotoPageLoaderTests` 共 9 项通过，确认 `LibraryPhoto` 新增时长字段未破坏相册分页。


## 2026-10-19 播放条上移与音量控制

- 播放条移入底部操作区，位于相机按钮正上方；宽度 300 → 340 点，仍短于屏幕宽度。
- 新增扬声器按钮：单击在静音与上次可听音量之间切换；右侧 42 点细音量条拖动 0–100%，调整 `AVPlayer.volume`。不调用系统音量 API，不改变系统媒体音量。
- iPhone 17 Pro / iOS 27.0.1 构建、安装、启动成功，无 Swift 编译警告。模拟器无视频，未取得播放条运行截图；未新增 UI 自动化测试。


## 2026-10-19 录制视频后首次打开相册进入详情

- 复现逻辑缺口：照片拍摄有一次性 `captureAwaitingReview` 状态，视频保存完成后没有对应状态，因此相册按钮总是进入列表。
- 视频写入系统相册成功后，`PhotoLibraryViewModel` 临时保存该视频的本地标识。相机第一次打开相册时消费标识，图库刷新并加载到目标视频后直接打开视频详情；用户返回相机后再次点相册进入列表。标识不写入持久存储，应用进程重启后不再跳转到上次视频。
- 新增打开目标视频期间的轻量加载遮层，避免图库列表先露出再跳进详情；若目标视频不在当前可见资源中则回退显示图库。
- 语法解析通过（4 个修改的 Swift 源文件）。完整 Xcode 构建未完成：Metal Toolchain 已安装，`xcrun metal --version` 正常；但 Codex 沙箱不允许编译器向 `~/.cache/clang/ModuleCache` 写入模块缓存，Xcode 将该失败报告为 Metal Toolchain 缺失。直接 Metal 编译指定 `/tmp` 缓存后通过。排除 Metal 源文件继续检查时，SwiftUI macro plugin server 仍返回 malformed response。iOS 27 模拟器运行时未安装；26.5 与 18.1 已安装。未完成真机回归。

### 2026-10-19 相册跳转回归核对

- 检查视频保存状态仅在 PhotoKit 保存成功后写入，并在相机第一次打开相册时消费；保存失败不会创建跳转标记。视频跳转优先于照片的一次性查看标记；视频查看后再次打开相册走列表。相册仍按拍摄时间倒序加载全部媒体类型，视频详情由本地资源标识查找。
- 检查照片查看/视频详情的布局改动没有更换保存、分页、播放、删除等动作处理入口。对整个 `LumaCamera` 和 `LumaCameraTests` 的 Swift 文件运行 `swiftc -frontend -parse`，语法解析通过。
- 尝试运行 `PhotoLibraryViewModelTests` 与 `GalleryViewModelTests`，但 Codex 环境中的 `simctl` 报 CoreSimulatorService connection refused，因此单元测试没有启动。Metal Toolchain 实际已安装且可运行；通用构建失败是沙箱阻止 Metal 编译器写入用户目录下的模块缓存，错误信息误报为缺少 Toolchain。独立 Metal 编译在把缓存指定到 `/tmp` 后通过。截图显示 iOS 27 Simulator 仍可点击 Get，而 iOS 26.5 / 18.1 Simulator 已安装。未能进行真机回归，故本节是代码路径和语法核对，不代表运行时测试通过。

## 2026-10-19 单色滤镜强度与稳定性回归

- 正式代码修复：银盐单色滤镜强度超过参考值时，使用零饱和度的对比度增强，避免高强度混合把彩色重新带回黑白画面。通用滤镜强度曲线按当前实现检查：0–80% 线性，80–100% 逐步加速，100% 相对 80% 的效果差值最高增加 50%。
- 相机功能入口配置恢复为照片/视频两项；照片辅助保留“夜景（即将支持）”占位入口。没有改页面布局、尺寸、颜色、动画或按钮样式。
- 测试断言/辅助代码更新仅在 LumaCameraTests 测试目标中，不会编入 App；包括滤镜目录和默认强度预期、LUT 参考图测试、滚轮测试前相机就绪，以及用公开几何测试钩子替代私有 SwiftUI 滚动视图探测。
- 模拟器：iPhone 17 Pro / iOS 26.5，337 项中 318 通过、19 跳过、0 失败。跳过项为真机专用用例。
- 真机：iPhone 17 Pro / iOS 27.0.1，筛选的 13 项通过、0 失败、0 跳过，覆盖滤镜实时预览和连续编辑、A/M 及镜头切换、手动锚点连续变焦与快速反向操作、变焦盘重开、相机中断恢复、HEIF HDR/RAW 质量恢复，以及照片/视频切换和录像往返。样张仅在测试进程内使用；未写入系统照片图库。
- 模拟器测试运行时输出两条 SwiftUI Environment<Double> 非 View 环境访问警告；ProRes 兼容性测试源另有一条 UnsafeMutableRawPointer 类型警告。这些警告没有导致测试失败，本轮未改动相机 UI 或 ProRes 测试探针。
- 局限：这是一组针对性回归，不等同于对系统相册授权/外部删除、外接盘 RAW 全链路、所有设备编码组合和长期热稳定性的穷举测试。


## 2026-10-19 视频 SDR/P3 滤镜与预览双指变焦

- 模拟器构建通过；`ContinuousZoomTests`、`VideoWorkflowTests`、`VideoFrameFilterRendererTests` 定向测试共 11 项通过、0 失败。覆盖捏合倍率边界与反向、视频滤镜仅对 SDR/P3 开放、原片配方门控，以及 sRGB/Display P3 目标缓冲区的滤镜像素输出。
- iPhone 17 Pro / iOS 27.0.1：连续三组捏合倍率操作均更新真实相机连续变焦状态，预览持续出帧；测试确认倍率边界及反向操作正常。该物理测试调用与 SwiftUI 手势相同的 ViewModel 更新入口，没有通过外部触控设备自动注入屏幕手势。
- iPhone 17 Pro / iOS 27.0.1：分别以 HEVC 1080p30 录制约 1.1 秒 SDR 与 Display P3 滤镜短片，解码检查成片像素。SDR 写入 35 帧、时长 1.167 秒、实测约 30.0 fps；P3 写入 34 帧、时长 1.134 秒、实测约 29.98 fps。两段输出的平均色度均为 0，符合单色滤镜已烘焙；预览分别测得平均色度 0.0728 与 0。录制过程约 1.25 秒完成，无二次编码。临时视频在测试后删除，没有保存到系统照片图库。
- 验证只覆盖 iPhone 17 Pro 的 HEVC 1080p30 SDR/P3 和短时连续变焦；没有覆盖 4K、高帧率、长时间录像、持续热负载或用户屏幕实际触摸自动化。HDR、Log、RAW 按设计不套照片滤镜。

## 2026-10-19 Apple Log/Log 2 LUT 烧录与成片标识

- 将 `Downloads/LUT/Log_LUT` 中 55 款 `.cube` 打包为 33³/65³ 半精度 `LCUB` 资源并纳入主 App。Log/Log 2 使用独立选择器，含“原片”；关闭“烧录”时只在预览显示 LUT，开启时将 LUT 写入录制像素，同时保留 Apple Log/Log 2 文件标记和 10-bit 4:2:0 编码缓冲区。Log LUT 不提供照片式调色编辑。普通照片滤镜参数更新与 LUT 选择更新分离，避免连续拖动时争用预览版本。
- 视频图库与详情并排显示 LOG/LOG2、已烧录滤镜图标、视频图标。Log 视频始终有 Log 标识；仅启用烧录且 LUT 实际载入时才记滤镜标识；仅预览的 LUT 不标为已烧录。标记写入 `VideoCaptureBadgeStore` 并按 PhotoKit 本地资源标识关联；外部导入视频不推断 Log/滤镜标记。
- 完整模拟器回归 347 项：328 通过、19 项真机或相册权限用例跳过、0 失败。滤镜预览两个连续更新用例在修复后通过。Log LUT 资源解析、应用、默认原片、标记语义和持久化均有单元测试覆盖。
- iPhone 17 Pro / iOS 27.0.1 真机录制验证通过：HEVC 1080p30 临时片段约 1.05 秒；检查到 Apple Log transfer 标记、10-bit 编码描述和有效视频帧。测试将临时 MOV 删除，没有保存到系统照片图库。
- 模拟器 640×360 渲染性能测试：一次迭代处理 30 帧平均约 0.096 秒；该结果仅为模拟器性能基线，不能代表真机 4K 或高帧率持续实时处理。55 款 LUT 的主观效果校准、4K/高帧率及长时间热稳定性仍需在目标设备另行验收。

## 2026-10-19 Log LUT 烧录控件样式

- 用户反馈后撤销系统 Switch 样式，恢复原有火焰图标胶囊按钮；保留原状态提示、触觉反馈、辅助功能标签和禁用条件。其他 Log LUT 功能未改动。
- 恢复后的界面通过 iOS Simulator 通用构建；本次仅调整控件样式，未重复录制测试。


## 2026-10-19 录像期间控件显隐与状态恢复

- 录像期间隐藏顶部工具栏、A/M 切换、M 挡六项参数按钮，以及底部相册、滤镜、拍摄模式和前后镜头切换；底部保留快门，A 挡曝光滑块继续可用。焦段和拍摄辅助控件保持原位置。隐藏控件保留布局空间并禁用触控与辅助功能，停止录像后按录制前 A/M 模式恢复对应控制界面。
- 模拟器 UI 回归：iPhone 17 Pro / iOS 26.5，`VideoWorkflowTests`、`LogLUTCubeTests`、`FixedCameraControlsTests` 共 12 项通过、0 失败、0 跳过。新增测试分别检查 A/M 录像态显隐、控件几何不变、停止后模式及对应控制恢复，并保留状态截图。
- 真机：iPhone 17 Pro / iOS 27.0.1，`VideoModeTransitionTests.testLiveHDRAndManualPhotoRoutesSurviveVideoRoundTrips` 1 项通过、0 失败、0 跳过，验证实际录像往返后拍照模式、Live/HDR 路由与手动参数状态可恢复。控件布局和录像态截图通过模拟器 UI 测试核对；本轮没有单独用真机屏幕截图确认每个控件的像素级呈现。
- 视频标识调整为普通视频只显示时长，SDR/P3 滤镜视频显示时长与滤镜标识，Log 视频显示时长与 LOG/LOG2；烧录 Log LUT 时额外显示滤镜标识。标识横向间距为 5 点，移除摄像机图标。标识规则由 `VideoCaptureBadgeStore` 单元测试覆盖。
- 真机测试结束后设备服务暂时报 CoreDeviceService 初始化超时；已从 `.xcresult` 中确认测试动作状态为 succeeded，1 项测试通过。该设备服务异常不影响本次已完成测试结果的判读。

## 2026-10-19 A 挡视频倍率与照片路由恢复

- 官方依据：苹果明确说明 [`activeFormat`](https://developer.apple.com/documentation/avfoundation/avcapturedevice/activeformat) 与会话 preset 相互影响，设置 preset 会重新配置输入格式，显式设置设备格式会转为 [`inputPriority`](https://developer.apple.com/documentation/avfoundation/avcapturesession/preset/inputpriority)。[系统主镜头切换行为](https://developer.apple.com/documentation/avfoundation/avcapturedevice/primaryconstituentdeviceswitchingbehavior-swift.property) 与回退候选继续由虚拟多摄管理，不增加距离阈值、定时锁镜或强制主摄。
- 真机复现：原流程先设置固定 1080p preset，返回照片时只恢复预设和色彩配置，缺少完整照片设备状态及当前倍率的保全；iPhone 17 Pro 曾记录到照片主摄约 1.458×，切回照片后为超广角 0.5×，同时留下 1920×1080 的设备格式。0.5× 重置是本机实测，不能当作所有设备的系统保证。A 挡实际输入一直是三摄虚拟设备，超广角并非唯一被允许使用的镜头。
- 修复：在改动输出或 preset 之前保存每个设备的照片格式、色彩、帧时长和倍率；视频在添加录制输出前使用 inputPriority，按规格显式设置格式。返回照片时在同一外层事务中恢复设备状态，当前输入最后恢复，并保持切模式前的当前倍率；在视频里改为 3× 后返回照片仍为 3×。系统自动宽色域开启时允许系统恢复到 P3，不把 activeColorSpace 的自动变化误判为 activeFormat 恢复失败。
- 最终模拟器回归：iPhone 17 Pro / iOS 26.5，18 项通过、0 失败、0 跳过，覆盖 VideoWorkflowTests、VideoSpecificationTests、VideoEncodingPolicyTests、AutomaticLensTransitionTests、ContinuousZoomTests、ManualZoomPolicyTests 及录像控件固定位置用例。
- 最终真机回归：iPhone 17 Pro / iOS 27.0.1，10 项通过、0 失败、0 跳过。包括 A 挡 1×/2×/4×/8×往返、视频中改变倍率、40 次快速模式请求/取消、A/M 与前后镜头恢复、0.5–40× 实际硬件变焦、重复录像与照片返回、前置与 120fps 路径、按设备能力开放的 SDR/P3/HDR/Apple Log/Log 2 A/M 组合实际录制及成片标记、Live/HDR/手动照片参数恢复。测试直接读取硬件倍率和 activePrimaryConstituent；当轮 1× 在照片、视频和返回照片时均记录为主摄、自动切镜，近摄超广角回退候选保留。
- 测试夹具修正：色彩矩阵和 M 挡往返录制等待与界面快门相同的就绪条件，避免响应式规格更新仍忙碌时直接调用录制而被正常防重复条件拒绝。没有为让测试通过而移除应用的录制保护。

性能样本为同轮普通照片与 HEVC 1080p30 SDR 的三次往返，共 6 次转换。记录模式请求到会话队列完成配置，以及该时刻之后第一帧的主机时间戳；这是配置/出帧延迟，不是屏幕实际 FPS。

| 方向 | 样本数 | 配置完成平均 | 新预览帧恢复平均 | 新预览帧恢复最大 | 观察到的帧间隔最大 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 照片→视频 | 3 | 0.368 秒 | 0.403 秒 | 0.422 秒 | 0.395 秒 |
| 视频→照片 | 3 | 0.378 秒 | 0.419 秒 | 0.424 秒 | 0.436 秒 |

- 录像期间增加隐藏拍摄辅助按钮：复用现有淡入淡出与原位置占位，同时关闭点击和辅助功能访问，停止后恢复；按钮尺寸、布局和其他样式未改。补充真机 1 项、模拟器 1 项均通过（与上述用例重叠，不另增去重数量）；截图前等待 400ms，让 0.22 秒动画完成后再核对。已实际查看 A/M 录制中与停止后的真机截图，辅助按钮隐藏/恢复及原位置保持正确。
- 结果包：`/private/tmp/LumaCameraVideoPhotoRoute-final-verification.xcresult`、`/private/tmp/LumaCameraVideoPhotoRoute-final-simulator.xcresult`；动画完成后的截图复查结果为 `/private/tmp/LumaCameraVideoPhotoRoute-controls-device.xcresult` 和 `/private/tmp/LumaCameraVideoPhotoRoute-controls-settled.xcresult`。倍率和性能文字证据在 `/private/tmp/LumaCameraVideoPhotoRoute-final-attachments/`，真机最终控件截图在 `/private/tmp/LumaCameraVideoPhotoRoute-controls-device-attachments/`，文件名见各目录 manifest.json。最终 App 已通过 devicectl 正常启动。
- 范围限制：以上为针对性短片与重复操作回归；没有进行外接 SSD RAW 录制、长时间热负载或所有设备组合验证。本轮没有重新执行手持近远移动的主观视角平顺度比较；确认的是选定倍率、实际主摄路由及系统自动切镜能力恢复，系统仍可能根据光照/最小对焦距离选择其他物理镜头。构建仍有一条已有的 ProRes 测试探针 UnsafeMutableRawPointer 警告，本轮未修改该探针。

## 2026-10-19 视频微距、录像控件与详情横屏

- 视频 A 挡按系统 `macroActive` 显示微距图标，不新增距离阈值或主动切镜。图标从 A/M 按钮中分离，使录像隐藏模式按钮时仍能显示。声音电平和剩余拍摄时间默认关闭，原辅助开关保留。录像期间固定焦段横条也隐藏并禁用触控/辅助功能，原布局占位不变，停止后恢复。
- 视频详情顶部返回与日期/位置标题同排居中。时长、滤镜和 LOG/LOG2 标识放在播放条右上方、间隔 5 点。只有视频、播放条和标识随设备旋转，五个操作按钮和顶部保持原位。播放器实例不因旋转重建，使用 resizeAspect 完整显示。图库、照片详情、编辑方向策略未改。
- 官方依据：SwiftUI 的 [rotationEffect](https://developer.apple.com/documentation/swiftui/view/rotationeffect(_:anchor:)) 不改变布局框，因此横屏显式交换媒体区域逻辑宽高；[AVPlayerLayer.videoGravity](https://developer.apple.com/documentation/avfoundation/avplayerlayer/videogravity) 使用 [resizeAspect](https://developer.apple.com/documentation/avfoundation/avlayervideogravity/resizeaspect) 保持视频比例，避免裁切画面。本次只改变显示，不重写文件方向或编码参数。
- 模拟器：iPhone 17 Pro / iOS 26.5，定向回归去重共 10 项通过。第一组中 9 项通过，详情布局用例因首次旋转尚未稳定时读取几何值失败；改为有上限等待实际旋转几何，并注入真实临时 H.264 视频替代空 composition 后，详情用例单独通过。应用布局代码未因该测试失败放宽边界要求。结果包 `/private/tmp/LumaCameraVideoDetail-simulator.xcresult`（保留初轮失败证据）及 `/private/tmp/LumaCameraVideoDetail-final-sim.xcresult`（最终详情 1 项通过）。
- 回归覆盖：全部照片比例切换的固定控件位置、变焦盘与按钮占位、A/M 录像隐藏/停止恢复、全部五种视频比例的微距提示及 HUD、默认开关与原视频工作流。微距用例覆盖 20 种比例/方向/录像组合和 40 次快速状态切换；详情覆盖 320/402 点宽度、0°/±90°/180°/回到竖屏共 10 种布局，以及 40 次快速旋转后退出。检查返回/标题水平对齐、操作栏几何固定、标识在播放条本地坐标的上方右侧、无越界、实际 AVPlayerLayer.videoRect 保持 16:9 且完整包含于播放器边界。临时视频不进入系统相册。
- 已人工核对最终竖屏、横屏截图，含紧凑宽度、长达小时的时长与多个标识。最终附件 `/private/tmp/LumaCameraVideoDetail-final-attachments/`。10 次生成并注册截图附件的平均耗时 0.320 秒、最大 0.332 秒；包括 UIKit 快照与测试附件处理，不是屏幕 FPS、播放帧率或相机处理耗时。
- 手机断开前：iPhone 17 Pro / iOS 27.0.1 的微距提示渲染测试 1 项通过，20 种布局和 40 次状态快速切换后正常退出。20 次 UIKit 快照绘制平均约 49.7ms，最大约 60.6ms；这是测试快照开销，不是实际帧率。结果 `/private/tmp/LumaCameraVideoMacro-render-device.xcresult`，最终截图与指标 `/private/tmp/LumaCameraVideoMacro-final-device-attachments/`。该测试注入微距状态，不证明所有实景下的自动微距判定；此前已完成的实际镜头恢复回归见上一节。
- 当前限制：按用户要求断开 iPhone 后只使用模拟器。视频详情本次横屏显示、旋转动画和实际触摸播放操作尚待真机复测；未进行长时间播放/热负载测试，不把模拟器通过当作真机验收。没有向真机或模拟器系统相册新增诊断媒体。

## 2026-10-19 视频详情补充真机回归

- 用户重新连接手机后，在 iPhone 17 Pro / iOS 27.0.1 运行本轮定向回归。首轮 11 项通过、0 失败、0 跳过；修正测试夹具后复查相关 6 项全部通过、0 失败、0 跳过、无 XCTest 运行时警告，两组合计去重 11 项，不把重复执行相加作为独立用例数量。
- 首轮发现旧夹具直接取 `CameraView(...).viewfinder`，在 View 尚未安装时读取环境角度，SwiftUI 会返回默认值。已把取景内容构建的角度显式传入，测试通过真正安装的宿主 View 读取环境并观察 model/camera；应用的 `viewfinder` 仍读取自身原环境值再转交内容，没有改变界面样式、镜头逻辑或旋转行为。修正后的水平仪/HUD 检查重跑通过，最终结果包的 runtimeWarnings 为空。
- 布局覆盖：7 种照片比例及 5 种视频比例 × 4 个方向共 48 组水平仪位置；视频 HUD/直方图 20 组、微距图标 20 组与 40 次快速状态变化；视频详情在 320/402 点宽度、0°/±90°/180°/回到竖屏共 10 组布局，另有 40 次快速方向变化后退出。核对返回/标题居中、底部五个操作按钮不移动、标识始终在播放条本地坐标右上方、播放器保持等比例且无越界。详情测试使用实际临时 H.264 视频并读取 AVPlayerLayer.videoRect，不请求系统图库权限。
- 实际相机回归：A 挡照片/视频的 1×/2×/4×/8× 往返和当前倍率保留，快速模式请求、录像后台停止/立即取消与计时停止；Live、HEIF HDR、手动 ISO/快门分别进入录像后返回，真实生成 1920×1080 视频并恢复对应照片状态。M 挡返回后读取设备 ISO 约 200，快门设置仍为 1/125。首轮与复查各实际完成三种往返；所有诊断视频仅写临时文件并清理，未保存到用户系统相册。
- 已查看真机最终截图：录像中固定焦段、辅助、工具栏及其他入口隐藏，停止后恢复；详情横屏播放条、标识与顶部/底部固定控件无重叠。微距渲染仍通过注入状态验证，不等同于所有近距实景下的系统镜头判定；方向通过环境角度驱动，不是机械转动手机的端到端测试。UIKit 快照中的视频层可能呈黑色，不以快照代替解码画面或触摸播放验收。
- 性能样本：最终详情 10 次生成/注册截图附件平均 75.1ms、最大 97.1ms；微距 20 次 UIKit 快照平均 45.7ms、最大 58.8ms。这些是测试截图开销，不是屏幕/播放帧率。首轮普通照片与 HEVC 1080p30 SDR 各三次转换，模式请求到配置后新预览帧恢复：照片→视频平均约 0.433 秒、最大 0.449 秒；视频→照片平均约 0.426 秒、最大 0.457 秒，不代表所有格式和光照。
- 证据：首轮 `/private/tmp/LumaCameraVideoDetail-device-regression.xcresult`；最终复查 `/private/tmp/LumaCameraVideoDetail-device-final.xcresult`；对应 `-attachments/` 目录保存截图和指标，具体文件名见各目录 manifest.json。未重新进行外接 SSD RAW、长时间录像/播放及热负载，也未自动注入屏幕触摸检查播放/拖动手势；本节补充上一节待做的真机布局和相机回归，不把上述未测范围标为通过。

## 2026-10-19 顶部工具栏弹窗标题缩小

- 共用 `panelHeading` 从 15pt 调整为 12pt，覆盖照片分辨率/文件格式、画面比例、Pro 影调/测光，以及视频分辨率/帧率、比例、色彩空间、视频格式/ProRes 规格。HDR 行标签同步由 15pt 调整为 12pt。此轮仅修改两处字号，保留原控件、间距和动画。
- iPhone 17 Pro / iOS 27.0.1：`ProResOptionsLayoutTests` 与 `VideoOverlayLayoutTests` 两项通过，0 失败、0 跳过、无 XCTest 运行时警告。已查看 304 点宽度 ProRes 和 320 点屏宽帧率弹窗截图，标题完整、未发生遮挡。
- 复用现有稳定性/性能检查：240 次规格选择/弹窗开关状态循环共约 3.19 秒；HUD 的 20 种比例/方向布局检查共约 6.35 秒，后者包含动画等待，均不是屏幕帧率或实际触摸速度。另检查 60 次工具栏弹窗快速切换并关闭；未拍摄或保存诊断媒体。
- 结果 `/private/tmp/LumaCameraToolbarTitles-device.xcresult`，截图 `/private/tmp/LumaCameraToolbarTitles-device-attachments/`。本次未重复录像、全功能或长时热负载测试。

## 2026-10-19 拍摄设置恢复、触感与色彩空间单行布局

- “保存拍摄设置”从仅记录开关接入实际快照保存/恢复。覆盖拍照/视频与 A/M 状态、照片格式/像素/闪光/Live/HDR/影调/测光/比例，视频分辨率/帧率/比例/色彩/编码/ProRes/Log LUT，手动数值和自动/手动标志、A/M 参数记忆、当前滤镜及调色、辅助开关、预览翻转、工具页、镜头和倍率。瞬时弹窗、录制和对焦框不恢复；开关关闭后下次冷启动使用用户指定照片/视频默认值，定位、署名等偏好保留。不支持的镜头能力和无外接盘 RAW 视频按原策略降级。
- 快照由 250ms 合并写入，后台立即 flush；关闭时取消待写入并清快照，防止旧任务复活状态。最终 JSON 使用排序键比较相同内容。测试宿主和临时模型改用内存偏好，持久化测试使用独立 suite，不修改用户设置。
- 视频水平仪原本已共用照片的迟滞/稳定门限，但录音期间系统触感默认关闭。官方依据：[录音触感许可默认 false](https://developer.apple.com/documentation/avfaudio/avaudiosession/allowhapticsandsystemsoundsduringrecording)、[设置许可](https://developer.apple.com/documentation/avfaudio/avaudiosession/setallowhapticsandsystemsoundsduringrecording(_:))、[AVCaptureSession 自动音频配置](https://developer.apple.com/documentation/avfoundation/avcapturesession/automaticallyconfiguresapplicationaudiosession)。本机初次只在接入麦克风前设置时，提交后读数又为 false；改为在提交完成和音频路由/会话启动后校正。麦克风录音及系统自动路由保持，失败只记 DEBUG 诊断，不因此阻止拍摄。
- 拍摄页相册、滤镜、翻转、参数入口及曝光复位，图库/照片/视频详情主要操作、编辑主工具与保存补充触感；已有反馈未增加全局点击层。视频色彩五个按钮改为单行，Apple／Log 和 Apple／Log 2 分两行，辅助功能名称保持完整。
- 模拟器 iPhone 17 Pro / iOS 26.5：首轮设置/视频/布局 7 项通过；最终排序编码及偏好/对焦补查 13 项通过，均 0 失败、0 跳过。覆盖所有主要设置的模型重建恢复、关闭后准确默认值、保留定位署名等偏好、重新开启立即保存、损坏/未来版本快照、连续修改后只保留最新值，以及关闭后延迟写入不能复活。两组有重复用例，不相加作为独立数量。
- iPhone 17 Pro / iOS 27.0.1：最终 9 项通过、0 失败、0 跳过、无 XCTest 运行时警告。隔离模型重建后，M 挡照片实际为 4× 物理镜头档位、5× 倍率，读到 ISO 200.07、快门 0.007995 秒；视频 M 挡恢复 P3/1080p30，ISO 199.72、快门 0.007997 秒，成功录制含音轨的临时视频。照片用例从启动到读数满足条件约 2.28 秒；视频用例约 1.31 秒包含短片录制与收尾，不是纯恢复延迟。
- 录音触感验证先强制恢复系统默认 false，再进入视频。等待麦克风路由实际就绪后，许可为 true；三次后置连录、前置录制时保持 true，输出均含音轨，返回照片仍可拍摄。后置三段约 1.03–1.07 秒、30fps，首次开始至录制约 84.5ms，后两次约 21ms；仅短片样本，不代表所有规格。先前两轮失败证据保留在 `/private/tmp/LumaCameraVideoHapticsColor-device.xcresult`、`/private/tmp/LumaCameraVideoHapticsColor-final-device.xcresult`；完善提交后许可并等待真实音频就绪后，`/private/tmp/LumaCameraHaptics-ready-device.xcresult` 及最终综合回归通过，未放宽“必须 true”的断言。
- 稳定性/性能：200 轮共 800 次参数/开关修改，真机约 0.718 秒、最终模拟器约 0.740 秒，均包含两次 350ms 取消等待；这是状态操作/取消检查，不是 FPS。原 Live、HDR、M 挡分别进出真实录像恢复通过；20 组视频 HUD 及 60 次工具栏切换检查通过。已查看 320/402 点宽的单行色彩按钮截图，五项同排且 Log 名称完整。
- 结果：`/private/tmp/LumaCameraCaptureState-sim-v2.xcresult`、`/private/tmp/LumaCameraCaptureState-final-sim.xcresult`、`/private/tmp/LumaCameraCaptureStateHaptics-device.xcresult`；真机截图在 `/private/tmp/LumaCameraCaptureStateHaptics-device-attachments/`。最终通用 iOS 构建通过。测试媒体只存临时目录并清理，未新增系统相册诊断照片或视频。
- 限制：触感验证确认门限逻辑与系统许可，不能自动测量人的实际震感；启动恢复通过重新创建模型并启动真实相机核对，未覆盖强制断电或磁盘故障。未验证所有设备/外接盘和长时热负载。


## 2026-10-19 前置方向取景与码率适用范围

- 前置动态画幅在横屏自动选择 wide、竖屏自动回到 standard，照片和未录制的视频模式都适用；录像过程中不自动改变倍率，停止后使用当前方向补应用。通过现有同一前置设备的 sensor zoom 切换，不新增物理镜头输入。照片模式的 Smart Framing 按钮在视频模式隐藏且保留版面位置。
- 修正 Smart Framing 初始化顺序：根据 Apple 文档，在 capture session `startRunning()` 前设置 `enabledFramings`；根据当前 active format 重新计算支持的竖幅候选。Apple 说明若不监测，`recommendedFraming` 会为空；候选启用后再启动监测，系统建议才可驱动自动构图。文档：[startMonitoring](https://developer.apple.com/documentation/avfoundation/avcapturesmartframingmonitor/startmonitoring%28%29)、[enabledFramings](https://developer.apple.com/documentation/avfoundation/avcapturesmartframingmonitor/enabledframings)。
- 设置中的码率 picker 对全部视频编码始终可选。低/中/高仅应用 HEVC/H.264；ProRes/RAW 按自身编码规格工作，忽略码率预设但保留该偏好，切回 HEVC/H.264 后继续使用。帮助文字同时按当前分辨率/帧率展示两种编码器的低/中/高估算值。
- iOS 27 模拟器定向测试：4 项通过、0 失败，覆盖码率档位对 HEVC/H.264 的映射以及对 ProRes 的忽略、横竖屏策略映射。
- iPhone 17 Pro / iOS 27.0.1 真机：设备竖直持握时，方向取景与录制保护、Smart Framing 开关及手动取景回归共 2 项通过、0 失败、0 跳过。实际读取设备方向后，前置取景正确匹配当前方向（portrait 对应 standard、landscape 对应 wide）；Smart Framing 连续开关 8 次及手动宽窄取景均通过，重复 ready 回调没有覆盖手动选择。录制保护通过测试状态钩子验证：录制期间不重构图，结束后方向未改变时保留当前取景；本轮没有在真实录像中旋转手机，因此不代表已完成真实录像中的物理转向验收。模拟器相关策略/码率定向测试 4 项通过。
- 视频前置广角控件调整：照片模式保留既有布局；视频模式不显示自动构图，将前置 wide 切换作为独立圆形按钮置于底部控制行中央，与焦段条分开。模拟器与 iPhone 17 Pro 目标均编译成功；在 iPhone 17 Pro 上安装并启动最新包后，实际前置视频界面截图确认圆形广角按钮居中、自动构图按钮隐藏。该次为静态界面核对，未远程点击按钮；按钮处理仍沿用已通过前置宽窄切换回归的选择逻辑。


## 2026-10-19 前置广角按钮点击修复

- 照片模式的前置宽窄切换按钮改用原生 SwiftUI `Button`，保留原圆形控件尺寸、箭头状态、触感反馈与 `selectFocalLength` 镜头动作；视频模式的居中圆形按钮和拍照页整体布局未改。按钮新增 `camera.frontWide.toggle` 辅助功能标识，便于后续界面自动化定位。
- iPhone 17 Pro / iOS 27.0.1 真机定向回归：`testFrontWideSwitchDoesNotCrashAndTogglesBack` 与 `testCurrentOrientationFramingAndRecordingGuard` 共 2 项通过、0 失败、0 跳过；覆盖 standard→wide→standard 实际设备倍率选择、当前方向取景、手动选取后的 ready 回调保护。
- 修复版已安装并启动。现有测试直接调用 ViewModel 镜头选择入口，未通过屏幕坐标或 UI 自动化实际点击按钮；因此验证了镜头切换路径和构建，但尚未声称按钮的物理触屏事件本身已被自动化复现。


## 2026-10-20 视频编辑入口与处理流程

### 已实现

- 视频详情编辑按钮打开 `VideoEditorView`。编辑器保持竖屏，包含起止时长裁切、滤镜选择、SDR/P3 参数调整与另存。保存结果作为新的系统相册视频，保留原视频。
- SDR/P3 读取视频拍摄时保存的滤镜样式、强度与参数，使用拍摄时相同的滤镜列表/参数模型；Log/Log 2 使用 Log LUT 列表，不显示参数调整；HDR 仅提供时长裁切。工具与保存按钮等分：SDR/P3 为 4 槽、Log 为 3 槽、HDR 为 2 槽。
- 逐帧预览/导出使用 AVFoundation `AVMutableVideoComposition.videoComposition(with:applyingCIFiltersWithHandler:)`；兼容输出容器通过 `AVAssetExportSession.compatibleFileTypes` 选择，原片不会被覆盖。不会在 composition 上强行覆盖源视频色彩标签；输出文件是否完整保留 HLG/PQ/Log 元数据仍需在真机读回文件验证。参考 [AVFoundation 逐帧 Core Image 合成](https://developer.apple.com/documentation/avfoundation/avmutablevideocomposition/videocomposition%28with%3Aapplyingcifilterswithhandler%3A%29)、[导出兼容容器](https://developer.apple.com/documentation/avfoundation/avassetexportsession/determinecompatiblefiletypes%28completionhandler%3A%29) 和 [视频合成色彩原色](https://developer.apple.com/documentation/avfoundation/avvideocomposition/colorprimaries)。
- 新增 `VideoEditorWorkflowTests`：工具类型/槽位数、裁切范围、最小时长、NaN/无效输入；扩展滤镜配方持久化测试。Swift 源文件语法解析通过。

### 首次验证状态（环境恢复后的完整结果见文末）

- 初次执行时，Xcode `build` 与 `build-for-testing` 在进入 Swift 编译前被 Metal Toolchain 与 CoreSimulatorService 环境阻断；当时没有成功构建、运行 XCTest 或执行真机回归。该状态已由文末 2026-10-20 后续验证更新。
- 真机尚未验证 Photos 视频资源导出/另存、带音轨剪辑、SDR/P3 滤镜画面和编码质量、Log LUT 输出、色彩元数据保持、快速切页/保存及长视频内存与温升。完成 Metal Toolchain 安装并恢复模拟器后，先跑 `VideoEditorWorkflowTests` 和 `LogLUTCubeTests`，再用短片分别核对 SDR、P3、Apple Log/Log 2；最后在 iPhone 上检查视频/音轨与 Photos 资源。
- 拍摄配方由当前版本在录制时按 asset ID 持久化。早期版本或外部视频没有应用内色彩空间记录时，编辑器读取视频轨道的公开格式描述，识别 Log/Log 2、HLG/PQ HDR、P3 与 SDR；若没有可识别的传递函数则只允许裁切，不显示滤镜工具。

## 2026-10-20 测试环境恢复与全量回归

- 恢复后使用 Xcode 27.0 与已安装的 Metal Toolchain 27A266a；CoreSimulator 可用，测试目标为 iPhone 17 Pro / iOS 26.5 模拟器。
- 首次进入类型检查时修复 `VideoEditorView` 的私有状态写入与条件视图分支类型问题，以及 `VideoEditorViewModel` 初始化期间过早访问 `self` 的编译错误。
- 首轮全量测试暴露出辅助拍摄设置在无预览启动参数时被模拟器调试初始化强制关闭、Log LUT 仅预览时仍被记为已烧录滤镜、水平仪布局测试夹具没有启用水平仪，以及 4K60 码率断言与当前按像素数/帧率平方根缩放的实现不一致。已分别改为保留已保存的辅助选项、只为实际烧录的 Log LUT 持久化滤镜标识、在布局测试中显式启用水平仪，并将码率断言校正到当前规格值；没有改动界面样式。
- 全量模拟器 XCTest 最终通过：361 项执行，20 项跳过，0 失败，耗时约 419.7 秒。跳过项涉及实体摄像头/真实 Live 文件、模拟器 Photos 授权或前台显示链路；这些属于测试前置条件，不计作测试失败。结果包：`/tmp/LumaCamera-full-regression-fixed.xcresult`。
- 通用 iOS 设备目标构建通过（`xcodebuild build -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO`）。构建输出仍有 `VideoEditorViewModel.save` 完成回调处的一条 Swift 隐式强引用/弱引用捕获警告；另有因项目未依赖 AppIntents 而跳过元数据提取的提示。它们没有阻止构建或测试，本次未改动此处代码。
- 本次仅完成模拟器全量回归及通用 iOS 编译，未在实体 iPhone 上安装或运行；相机镜头、Live 真机资源写入和 Photos 权限集成仍需在实体设备/已授权环境复测。

## 2026-10-20 Live 开关保留后置焦段

- 修复 Live Photo 开关触发的预览/照片输出重配可能丢失当前裁切倍率的问题。切换前 flush 待提交的变焦值；重配后若活动设备倍率变化，则在支持范围内恢复原倍率并刷新相机读数。没有改变控件布局或样式。
- iPhone 17 Pro / iOS 27.0.1 后置真机验证：A 挡 24mm 时开关 Live 均保持 1×；点击 1× 切换至 35mm 后，打开和关闭 Live 均保持设备实际 1.4583×，不再回到 24mm。新增回归 `testRearLiveTogglePreserves24mmAnd35mmFraming` 通过。

## 2026-10-20 视频编辑真机验证

- iPhone 17 Pro / iOS 27.0.1：`VideoEditorWorkflowTests` 5 项通过，覆盖 SDR/P3/Log 工具开放、色彩空间元数据识别、裁切边界和无效时长；`VideoDetailLayoutTests.testVideoPlaybackRotatesWithoutMovingHeaderOrActions` 通过，使用临时合成视频核对播放器布局及播放条随方向变化，固定标题/返回/操作区位置。测试未写入系统照片图库。
- 真机视频编辑器尚无端到端 PhotoKit 另存/覆盖测试；本轮不把 AVFoundation 导出、滤镜成片、音轨裁剪、Log/P3/HDR 元数据保留或长视频功耗视为已验证。验证结果包：`/tmp/LumaCamera-device-editor-workflow.xcresult`、`/tmp/LumaCamera-device-video-layout-rerun.xcresult`。
- 同一真机的前置 Live 回归覆盖普通取景 1.6×（系统及成片 EXIF 均 31mm）与广角 1×（EXIF 20mm）；两种资源都能被 `PHLivePhoto` 成功识别，Live 开启后取景倍率保持。该测试先确保前置镜头、设备倍率和相机会话均就绪，再切换取景，避免将测试夹具尚未完成的镜头切换误报为产品故障。
- 回归 `testNativeJPEGAndHEIFLivePairsDecodeWithoutWritingPhotos` 通过：后置 JPG 和 HEIF Live 的静态图/动态片段均可解码配对。诊断照片只在测试内存及临时文件中处理，没有写入系统相册。
- 最终合并回归：3 项通过、0 失败、0 跳过，结果包 `/tmp/LumaCamera-live-zoom-final-suite.xcresult`。通用 iOS `build-for-testing` 成功；本次未运行完整 XCTest 套件。

## 2026-10-20 视频编辑入口栈溢出修复

- 在 iPhone 17 Pro / iOS 27.0.1 上用临时 H.264 视频复现：打开带已保存 SDR 滤镜的全屏视频编辑器后，进程因主线程栈溢出退出。设备崩溃报告记录 `Thread stack size exceeded due to excessive recursion`，`VideoEditorViewModel.trimStart.setter` 连续递归 8,946 层；调用源是 `loadDuration()` 设置裁切起点。
- 根因是 `trimStart`/`trimEnd` 的 `@Published didSet` 内再次给同一属性赋值以钳制范围。改为 `setTrimStart`/`setTrimEnd` 显式规范化输入并同步播放器范围；异步加载时先设置时长和终点，再初始化起点。滤镜强度也取消观察器内的自我赋值，改由初始化数据和用户更新入口负责范围限制。
- 修复后真机回归：编辑器入口用例 `VideoDetailLayoutTests.testVideoEditorCanOpenFromFullscreenCoverWithStoredFilter` 加 `VideoEditorWorkflowTests` 5 项，共 6 项通过、0 失败、0 跳过；入口用例在全屏呈现编辑器后等待视频时长、已存滤镜预览合成和缩略图初始化完成。测试仅使用临时合成视频，未访问或写入系统照片图库。合并结果包：`/tmp/LumaCamera-video-editor-regression-suite.xcresult`；首次独立回归包：`/tmp/LumaCamera-video-editor-entry-device-verified.xcresult`。
- 此项验证覆盖导致崩溃的加载路径；PhotoKit 另存/覆盖、音轨剪辑、长视频功耗和不同色彩空间的成片质量仍按上节列出的范围待验证。

## 2026-10-20 Apple Log / Apple Log 2 LUT

- 将用户提供的 `AppleLog_Rec709.cube` 与 `AppleLog2_Rec709.cube` 纳入 `LumaCamera/Resources/LogLUTs`，保留 65³ 网格并以 LCUB 半精度资源打包；资源头和文件长度已静态核对。Log LUT 总数由 55 增至 57。
- Log 列表显示顺序为“原片”→“Log Rec709”→“Log2 Rec709”→其余 LUT。设备名和滤镜名分开显示，收藏沿用现有 Log LUT 收藏逻辑。`LogLUTCubeTests` 已包含 57 项数量及 Apple LUT 排序/命名断言。
- 通用 iOS `build-for-testing` 已通过。构建期间修复了缩略图预加载残留调用、Open Gate 按钮参数顺序、视频编辑器初始化顺序和 Live 重封装 continuation 类型；缩略图 `CIContext` 的跨线程访问警告也已消除。仍有 AVFoundation 并发捕获与视频编辑回调相关编译警告，不阻断构建。
- iPhone 17 Pro / iOS 26.5 模拟器定向回归共 51 项：50 项通过、1 项真机专用用例跳过、0 失败。包含 Log LUT 资源/命名/顺序/应用 6 项，Open Gate 能力与画幅 3 项，视频规格及编码策略 5 项，以及工具弹窗、比例布局、拍摄设置持久化、滤镜选择/缩略图复用和视频流程等 37 项。初次回归暴露的 Open Gate 预览顶边断言已更新后复跑通过。结果包：`/tmp/LumaCamera-Targeted-Verification.xcresult`、`/tmp/LumaCamera-Related-Regression-Rerun.xcresult`。
- 真机补充验证见下方 2026-10-20 记录；尚未核实 Open Gate 在实体设备上的实际传感器/视频输出规格，也未核对 Log LUT 选择器的真机视觉显示与收藏交互。

- 按用户最新要求，本轮只运行修改相关的定向用例，未继续全量 XCTest。画幅切换可视化用例的像素判据原先只识别白色，误报橙色按钮不可见；已将判据扩展为识别主题橙色，单项重跑 1 项通过、0 失败。未改应用界面。结果包：`/tmp/LumaCamera-FixedControls-VisualCheck-Final.xcresult`。

## 2026-10-20 Apple Log LUT 与 SDR/P3 视频滤镜真机回归

- 设备：iPhone 17 Pro（iPhone18,1），iOS 27.0.1；本轮只运行相关真机用例，没有运行全量测试。
- `VideoColorPhysicalTests.testAppleLogLUTBurnKeepsLogVideoTagsAndTenBitPixels` 通过：选用 Apple Log 列表首项 LUT，实际录制 1.067 秒临时 HEVC 视频，确认输出为 10-bit 并保留 Apple Log transfer 标记，视频滤镜标识状态也符合预期。临时文件在测试后删除，没有写入系统照片图库。
- `VideoColorPhysicalTests.testSDRAndP3FiltersAreBakedIntoRecordedPixelsWithStableFrameDelivery` 通过：SDR 与 Display P3 各录制约 1.13 秒，均收到 34 帧，测得帧率分别为 29.96 和 30.00 fps；预览与成片的单色滤镜检测都通过，临时视频均已删除，没有写入系统照片图库。该指标是测试片段的平均帧率，不代表所有场景下的实时帧间抖动。
- 两条真机测试结果包：`/tmp/LumaCamera-AppleLogLUT-Device.xcresult`、`/tmp/LumaCamera-SDR-P3-Filter-Device.xcresult`。尚未覆盖 Log LUT 选择器的视觉/收藏操作和 Open Gate 的实际传感器输出。

## 2026-10-20 Log LUT/Open Gate 与应用设置提示 UI 调整

- Log LUT 选择列表扩大卡片文字区域，设备名与滤镜名分行，长名称允许最多两行并采用中间截断；增加列表高度以避免文字被滚动视口裁掉。底部操作沿用照片滤镜按钮样式，顺序调整为滤镜名、收藏、烧录；原有 LUT 选择、收藏状态和烧录逻辑未变。
- 横屏视频工具栏的 Open Gate 标签改为双行；Open Gate 生效且未录制时，快门显示双行黑色提示（字号 12），录像开始时隐藏，并使用短淡入淡出。设置项说明图标移到标题后，说明弹窗保留标题栏关闭按钮并移除重复的“知道了”。
- 验证状态：对四个修改的 Swift 文件运行 `swiftc -frontend -parse`，语法解析成功。iOS 构建未完成：Xcode 27.0 报告 Metal Toolchain 27A266a 不可执行；下载/导入资产及 First Launch 检查后仍相同。模拟器与设备测试未运行：CoreSimulatorService/CoreDeviceService 当前无法连接。故本节 UI 排版、横屏和录制态显隐仍需在可用的 Xcode 构建环境中验证；没有将这些行为记为通过。

## 2026-10-20 Xcode 构建环境恢复

- 根因核对：在 Codex 沙箱进程中，`xcrun metal --version` 无法访问 Xcode 通过 Cryptex 挂载的 Metal Toolchain，CoreSimulatorService 的 launchd/XPC 服务也不可见；切换到正常权限后能枚举模拟器运行时，说明之前的 CoreSimulator 连接错误来自执行隔离，不是模拟器运行时缺失。
- 使用 Xcode 27.0 官方组件流程重新下载并导出 Metal Toolchain 27A266a；导入命令返回“已安装”，在正常权限下 `xcrun metal --version` 已成功，显示 Metal 32023.921。
- 定向构建通过：`xcodebuild -project LumaCamera.xcodeproj -scheme LumaCamera -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/LumaCamera-UI-Check CODE_SIGNING_ALLOWED=NO build`，结果 `BUILD SUCCEEDED`。
- CoreSimulator 验证通过：iOS 18.1、26.5、27.0 运行时可枚举；iPhone 17 Pro（iOS 26.5）成功启动，成功安装构建产物并启动 `com.shurrikann.LumaCamera`。
- 限制：模拟器验证仅覆盖启动、安装与应用启动；未手动检查 Log LUT 文字布局、横屏 Open Gate 提示或相关交互，也未运行真机测试。受限沙箱中的命令仍不能直接连接 CoreSimulator 或执行 Metal；后续构建/模拟器操作需在正常 Xcode 环境运行，或使用获准的正常权限执行。

## 2026-10-20 iPhone 17 Pro 界面真机检查

- 设备：iPhone 17 Pro（iPhone18,1），iOS 27.0.1；Xcode 27.0（27A266a）。真机构建、安装和启动均通过，应用进程正常启动。
- 设备截图（1206×2622）确认当前横屏视频页中 Open Gate 工具栏文字为双行；未录制时快门内黑色 Open Gate 提示为双行且可见。未拍摄或保存诊断照片/视频。
- 限制：Mac 的 iPhone 镜像显示无法连接提示，不能通过本轮远程触控打开 Log LUT/应用设置弹窗或开始录像。因此滤镜名称完整显示、收藏/烧录排列、说明图标位置和录制期间快门提示隐藏，仍需在手机上人工操作检查；本轮只确认构建、部署、启动和截图中可见状态，不把未操作项记为通过。

## 2026-10-20 Open Gate 快门提示居中调整

- 快门上的 Open Gate 文案从上移位置改为居中叠放，字号由 12 pt 提至 15 pt，字重提高为 `.black`；仅在 Open Gate 且未录像时显示的条件不变。
- iPhone 17 Pro（iOS 27.0.1）真机构建、安装和启动通过。设备截图确认快门中心显示加大加粗的两行黑字；未录制状态可见，未拍摄或保存媒体。本轮只用已连接的一台手机，没有启动模拟器。
- 录制时自动隐藏仍保留原条件，但本轮没有启动录像，故该状态未单独验证。

## 2026-10-20 视频录制计时方向

- 移除顶部录制计时的 `rotatingCaptureContent()`，使计时文字保持竖屏方向；计时位置、字号、颜色及显隐条件不变。
- iPhone 17 Pro（iOS 27.0.1）真机构建、安装和启动通过。未启动实际录像，因此计时的横屏运行画面尚未人工目视确认；没有保存诊断视频。

## 2026-10-20 拍摄界面滤镜按钮名称字号微调

- 将滤镜按钮标题从 9 pt 调整为 8 pt；存在设备名的双行样式标题从 8 pt 调整为 7.5 pt。设备名字号、行高、截断规则、按钮点击热区和整体布局均未改变。
- 定向模拟器回归：iPhone 17 Pro / iOS 26.5，`ToolbarHistogramLayoutTests.testLongFilterNamesKeepCaptureButtonSizeAndShowTruncation` 1 项通过、0 失败（用例耗时 0.512 秒），覆盖原片、普通滤镜、设备名及较长滤镜名；确认长名称不会改变按钮尺寸。
- iPhone 17 Pro / iOS 27.0.1 真机构建、安装、启动通过。设备截图确认横屏拍摄页控件仍在原位，滤镜按钮文字保留在按钮范围内；未拍摄或保存媒体。
- 性能/稳定性范围：本修改仅改变静态 SwiftUI 文本字号，不触碰相机、图像处理或动画路径；定向渲染用例耗时为 0.512 秒，但它不是应用帧率指标，也未测量实时预览帧率。真机仅完成安装启动和一次界面截图，未进行人工点按或重复切换；这些限制不影响字号和固定按钮尺寸的定向检查结论。

## 2026-10-20 拍摄辅助按钮间距统一

- 将拍摄辅助图标上方的拍摄模式按钮与图标间距从 8 pt 调整为 14 pt，和左侧微距提示到 A/M 档按钮的间距一致；两处现在使用同一布局间距常量，未移动底部控制行或焦段条。
- 定向模拟器回归：iPhone 17 Pro / iOS 26.5，`VideoMacroIndicatorTests.testVideoMacroIndicatorSurvivesRecordingAcrossRatiosAndRotation` 1 项通过、0 失败，测试本体 11.970 秒。覆盖全部 6 种 `VideoRatio`、0°/90°控件方向、录像前后共 24 种状态；以布局坐标按 SwiftUI 上移偏移量还原后的有效间距核对，误差容限 0.5 pt；并执行 40 次快速微距/录像状态变化。附件里的快照绘制耗时仅为 UIKit 绘制指标，不代表屏幕帧率或相机预览性能。
- 首轮测试断言直接把 `onGeometryChange` 返回的布局框当作偏移后的显示框，造成断言失败；根据 SwiftUI 的 `.offset` 位移修正测试测量后，定向回归通过，应用布局代码未因此追加等待或状态更新。
- iPhone 17 Pro / iOS 27.0.1 真机构建、安装、启动通过；横屏设备截图目视确认右侧两按钮间距与左侧宏提示/档位按钮组相称，其他拍摄控件仍在原位。未拍照或保存媒体。


## 2026-10-20 Log Rec709 滤镜名称调整

- Log LUT 的两个 Rec.709 转换滤镜在预览按钮、选择列表和无障碍名称中显示为“Log Rec709”和“Log2 Rec709”；底层文件名、资源 ID、列表排序与 LUT 数据不变。
- 初版相机滤镜按钮将它们按设备名在上、滤镜名在下展示；后续按用户澄清调整为滤镜名在上、设备名在下，当前顺序与列表及选中信息一致，详见下方“Log LUT 名称顺序与列表间距复核”。
- 定向验证：Xcode 27.0 的 Metal Toolchain 27A266a 已注册为 installed，`xcrun metal --version` 正常返回 32023.921；通用 iOS `build-for-testing` 成功，`LogLUTCubeTests` 在 iPhone 17 Pro / iOS 26.5 模拟器 6 项通过、0 失败、0 跳过（约 12.4 秒）。首次启动因模拟器 app-launch Busy 失败，重启同一台现有模拟器后通过；未运行全量测试。源级映射为 `Log`/`Rec709` 与 `Log2`/`Rec709`，列表及无障碍标签共用该映射。真机视觉检查未执行；该改动只调整显示字符串，不涉及相机管线或 LUT 渲染。


## 2026-10-20 Xcode Metal Toolchain 环境修复

- 通过 Apple 支持的 `xcodebuild -downloadComponent MetalToolchain` 补齐当前 Xcode 27.0 对应的 Metal Toolchain；组件状态确认 `installed`，版本 27A266a，`xcrun --find metal` 指向该组件，`xcrun metal --version` 可正常运行。
- 通用 iOS `build-for-testing` 成功编译 App、Metal shader 与 XCTest 包；之后在已有 iPhone 17 Pro / iOS 26.5 模拟器执行 Log LUT 定向测试，6 项通过。此次修复的是当前机器所选 Xcode 的组件安装，不修改项目构建设置；Xcode 升级后需确认相应版本的 Metal Toolchain 仍已安装。

## 2026-10-20 Log LUT 弹窗尺寸与圆角统一

- Log LUT 列表视口从 106 pt 调整为与 SDR 滤镜列表相同的 79 pt；Log 与 SDR 的空列表提示也统一为 79 pt。Log 卡片保留圆形缩略图、设备名/滤镜名、收藏和烧录入口，长名称采用中间省略。底部选中信息和操作栏固定为 44 pt，整体内容高度与 SDR 选择器一致，长名称不会把弹窗撑高。
- 滤镜弹窗玻璃背景改为左上、右上 28 pt 连续圆角，底角保持直角并延伸到屏幕底边；SDR 与 Log 共用同一背景形状。没有改滤镜数据、烧录状态或点击行为。
- Rec.709 转换滤镜的设备名与滤镜名已分离；最终的两行显示顺序和卡片间距以本节之后的“Log LUT 名称顺序与列表间距复核”为准。`displayName`、无障碍完整名称与录像记录仍为 `Log Rec709`、`Log2 Rec709`。对应解析测试已增加设备名、滤镜名和完整名称断言。
- Xcode 27.1 / iOS 27.1 SDK 的 generic iOS `build-for-testing` 成功，App、Metal shader 和 XCTest 包均编译通过。构建命令使用 `/private/tmp/LumaCameraDerived`；受限沙箱不能访问系统 Cryptex 中的 Metal Toolchain，正常 Xcode 构建环境可访问已安装组件并完成构建。
- 本轮 CoreSimulatorService 无法连接且没有可用模拟器运行时，未能执行界面截图或模拟器弹窗检查。结构核对确认 Log 与 SDR 列表视口高度均为 79 pt、选中信息和操作栏均为 44 pt；没有测量相机预览性能。
- 首次尝试真机测试时设备暂不可用；重新连接后，在实体 iPhone 17 Pro 上运行 `LogLUTCubeTests`，6 项全部通过、0 失败，总用例时间 2.689 秒，结果包为 `/tmp/LumaCameraDeviceDerived/Logs/Test/Test-LumaCamera-2026.10.20_14-24-39-+0800.xcresult`。覆盖 LUT 资源尺寸、图像应用、Rec.709 两行名称与完整显示名、原片选项和视频滤镜标识。
- 定向测试完成后通过 Apple `devicectl` 截取设备屏幕，确认手机当前显示锁屏；iPhone 镜像窗口仍处于连接中。因此本轮没有实际打开滤镜弹窗或目视确认圆角、长名称与高度；结构与构建检查不能替代这项视觉验证。

## 2026-10-20 对焦辅助双摄配置诊断

- 在实体 iPhone 17 Pro 上运行定向 `FocusNavigatorCapabilityTests.testWideAndTelephotoNavigationCaptureCapabilities`，1 项通过、0 失败。测试将广角与长焦输入、两路视频输出及长焦照片输出加入 `AVCaptureMultiCamSession`，提交配置后读取能力和成本；没有调用 `startRunning()`，也没有拍照或写入系统相册。
- 本机读数：`hardwareCost = 0.7701`、`systemPressureCost = 3.5673`、`isLivePhotoCaptureSupported = false`、`isAppleProRAWSupported = false`、RAW 像素格式列表为空、长焦最高照片质量标志为 false，照片最大尺寸为 4032×3024。该结果说明这组双摄格式不能保留当前全部拍摄能力；成本读数来自配置检查，未当作实际帧率或持续功耗指标。
- 因为没有启动双摄视频流，本测试没有测量真实预览帧率、持续功耗、温升、8×以上主画面与导航小窗同步效果，也未确认单次拍摄的实际行为。对焦辅助继续保持待支持；后续需先设计能力受限时的自动降级，再在真机启动会话做定向稳定性和性能测试。

## 2026-10-20 Log LUT 名称顺序与列表间距复核

- 按用户澄清，Log LUT 的两行顺序为滤镜名在上、设备名在下：相机按钮、列表卡片和选中信息均按此顺序显示；因此为 `Rec709 / Log`、`Rec709 / Log2`。完整语义名和保存的 LUT 名仍是 `Log Rec709`、`Log2 Rec709`，资源 ID 与 LUT 文件未改。
- Log 卡片宽度调整为 64 pt、横向栈间距 10 pt，缩略图维持 48 pt，文本宽度受卡片边界限制并在长名称中间省略。按布局尺寸计算，缩略图之间可见间隔约 20 pt，与 SDR 卡片间距接近；列表视口仍为 79 pt。
- iPhone 17 Pro / iOS 27.0.1 上执行 `LogLUTCubeTests` 与 `FilterPickerTests`：10 项通过、0 失败、0 跳过，测试执行约 6.1 秒。结果包：`/tmp/LumaCameraDeviceDerived/Logs/Test/Test-LumaCamera-2026.10.20_14-35-07-+0800.xcresult`。覆盖 LUT 名称解析、完整名称、资源解析及应用，以及滤镜选择/收藏状态。
- 使用 `devicectl` 在实体 iPhone 上启动最新 App 并截屏，确认拍摄界面滤镜按钮显示滤镜名在上、设备名在下。没有拍摄或保存媒体。
- 尚未目视检查滤镜弹窗中的卡片间距：当前相机正在使用设备时，iPhone 镜像显示需锁定手机才可连接；本轮保持手机解锁，未通过镜像打开弹窗。间距记录为代码布局尺寸推算，不冒充截图测量或实时性能指标。弹窗圆角、高度及列表长名称仍待可见界面复查。


## 2026-10-20 连拍与视频裁剪预览实现状态

- 连拍已接入拍摄模式子模块：按住快门时重复提交独立 JPG/HEIF 照片，松开停止；仅开放 12MP，HDR、Live、倒计时及不支持的格式/像素规格被排除。请求复用现有相机拍摄和有界保存队列，队列满时暂停提交。尚未声称这是系统原生高速连拍或有固定帧率。
- 视频裁剪起点/终点拖动会更新上方播放器的预览目标。`VideoEditorViewModel` 以 45ms 间隔合并拖动中的 seek 请求，采用 1/15 秒容差；定向测试验证两个截点及 20 次快速更新最终停在最新截点。
- Open Gate 官方文档复核：Apple 的 [supportedMaxPhotoDimensions](https://developer.apple.com/documentation/avfoundation/avcapturedevice/format/supportedmaxphotodimensions) 与 [AVCapturePhotoSettings.maxPhotoDimensions](https://developer.apple.com/documentation/avfoundation/avcapturephotosettings/maxphotodimensions) 说明当前设备格式支持的最大照片尺寸及拍照尺寸选择；[supportedDynamicAspectRatios](https://developer.apple.com/documentation/avfoundation/avcapturedevice/format/supporteddynamicaspectratios) 对应视频设备格式的动态画幅比例。公开文档没有定义名为“Open Gate”的静态照片模式，也没有列出 iPhone 17 Pro 支持几种 Open Gate 照片比例。项目从活动照片格式报告的最大尺寸推导入口能力属于应用实现；真机输出尺寸和元数据尚未验收。
- 静态检查：对本轮涉及的 11 个 Swift 源码和测试文件运行 `swiftc -frontend -parse`，均通过。该检查只覆盖语法解析，不代表 Swift 类型检查、链接或运行测试通过。
- 构建：Xcode 27.1（27A9275）在正常 Xcode 权限下 generic iOS `build-for-testing` 成功，App、Metal shader 与测试包均编译通过，结果包 `/private/tmp/LumaCameraBurstBuild.xcresult`。受限执行环境本身仍不能执行系统 Cryptex 中的 Metal 工具或连接 CoreSimulator；未修改系统 Xcode 组件，也未更换 Xcode 版本。
- 模拟器定向回归：iPhone 17 Pro / iOS 26.5，`PhotoOptionsTests.testBurstPolicyAllowsOnlyStandardJpegAndHEIFWithoutLiveOrHDR`、`BurstCapturePipelineTests.testHoldingBurstShutterQueuesShotsAndReleaseStopsFurtherRequests`、`VideoDetailLayoutTests.testDraggingTrimHandlesSeeksThePreviewToEachCutPoint` 共 3 项通过、0 失败，总测试时间 1.675 秒。0.9 秒模拟器长按得到 29 次拍摄回调，平均间隔约 0.031 秒、待处理峰值 1；该速度只反映模拟器管线，不代表真机帧率。视频测试覆盖起点、终点及 20 次快速更新后停在最新截点，测试耗时 0.532 秒。
- 真机连拍：iPhone 17 Pro（iPhone18,1）/ iOS 27.0.1。`BurstCapturePipelineTests.testHeldBurstShutterOnDeviceStopsCleanlyWithoutSavingToPhotos` 重复运行 3 次，均通过、0 失败；每次包含 3 轮各 0.9 秒按住并松开的操作。最近一轮共 12 张拍摄回调，平均回调间隔约 0.399 秒，待处理峰值 3/4；每轮松手后等待当前请求完成，并确认后续 150ms 无新回调。该指标是此设备配置下拍摄完成回调间距，不能视作传感器帧率或所有格式的速度保证。测试替换了系统相册保存回调，不向照片图库写入诊断照片。结果包：`/private/tmp/LumaCameraBurstDevice.xcresult`、`/private/tmp/LumaCameraBurstDeviceRepeat.xcresult`、`/private/tmp/LumaCameraBurstDeviceMetrics.xcresult`。
- 真机视频裁切预览：iPhone 17 Pro / iOS 27.0.1，`VideoDetailLayoutTests.testDraggingTrimHandlesSeeksThePreviewToEachCutPoint` 1 项通过、0 失败、0 跳过，结果包 `/private/tmp/LumaCameraTrimDevice.xcresult`。该用例验证播放器时间落点和快速更新后的最终 seek 目标；它没有人工拖动实际编辑界面，因此不代表屏幕画面刷新延迟或主观流畅度已验收。
- 限制：真机连拍只验证 JPG、12MP、无 HDR/Live/倒计时；HEIF 真机组合、长时间持按、保存队列满载和发热尚未覆盖。真机测试启动日志曾出现 `MDB_MAP_FULL`，但用例完成并通过；目前没有证据将其归因于连拍，需要在后续真机运行中观察是否复现。

## 2026-10-20 视频 Open Gate 开关与预览帧率

- 视频 Open Gate 使用独立开关；开启后 4:3 和 1:1 可选，其余比例仍显示但不可选。照片模式的 Open Gate 入口保持隐藏。切换开关及旧版画幅状态迁移由定向单元测试覆盖。
- Apple 官方说明，[`activeVideoMinFrameDuration`](https://developer.apple.com/documentation/avfoundation/avcapturedevice/activevideominframeduration) 可限制设备捕获的最大帧率，并要求使用活动格式支持的帧间隔、持有配置锁修改；这定义了相机采集节奏，不保证图像处理后的预览发布率或屏幕扫描率。项目预览现按视频模式实际采用的帧率节流，不再固定限制为 30 fps；照片预览仍使用 30 fps 基准。
- 构建与测试：Xcode 27.1，iPhone 17 Pro（iPhone18,1）/iOS 27.0.1，仅运行定向真机用例，没有启动模拟器或全量测试。Open Gate 录制用例与首次 A 挡预览帧率用例共 2 项通过、0 失败、0 跳过，结果包 `/private/tmp/LumaCameraOpenGateCadenceDevice.xcresult`；按当前 A/M 路由重新枚举规格后的帧率复测 1 项通过、0 失败、0 跳过，结果包 `/private/tmp/LumaCameraPreview120FinalDevice.xcresult`。
- Open Gate 实际录制：当前 1080p30 SDR HEVC 路由的设备活动格式为 1920×1440；4:3 临时视频轨道为 1920×1440，1:1 临时视频轨道为 1440×1440，均符合目标比例（容差 0.015）。每段录制约 1.1 秒；测试结束删除临时视频，没有写入系统照片图库。关闭开关后重新允许选择 2.39:1。
- 预览性能测量：按应用当前路由能力枚举规格。A 挡虚拟多摄路由开放 24/25/30/50/60 fps、未开放 120 fps；各运行约 1.6 秒，统计主线程发布时间戳，样本数/频率分别为 24 fps：37 帧 / 23.3 fps；25 fps：37 帧 / 23.2 fps；30 fps：48 帧 / 29.8 fps；50 fps：65 帧 / 49.6 fps；60 fps：96 帧 / 59.9 fps。M 挡物理镜头路由开放 720p/1080p/4K 的 SDR 120 fps；各运行约 2 秒，结果为 720p：238 帧 / 119.5 fps；1080p：237 帧 / 120.0 fps；4K：237 帧 / 119.9 fps。因此在本次 iPhone 17 Pro 的 App 能力列表中，120 fps 仅在 M 挡开放，A 挡选项应禁用。指标是图像进入主线程发布的平均频率，不等同于屏幕扫描率；每个规格为单次短时样本，不代表低光、高负载或长时间温升下的帧间抖动。
- 限制：真机采样覆盖 iPhone 17 Pro 上 A 挡 SDR 24–60 fps 与 M 挡 SDR 120 fps 的 App 实际可选规格；没有测量 HDR/Log、其他设备、长时间录像、低光/高负载和屏幕扫描率。系统与渲染负载仍可能使实际预览低于所选帧率。Open Gate 真机结果只证明本次 iPhone 17 Pro 的该路由与两种输出比例，不能外推到所有设备和规格。

## 2026-10-20 Open Gate 规格说明排版

- 视频画面比例弹窗将开关标题统一为“Open Gate”，开关与“画面比例”并排显示；其下说明支持 4:3/1:1、仅视频 HEVC 可用且照片格式不适用。当前镜头实际支持的色彩空间、分辨率和帧率组合由 `openGateVideoSettings` 动态分组展示；能力列表为空时显示“当前镜头暂未报告可用组合”。
- Xcode 27.1，iPhone 17 Pro / iOS 27.0.1：`VideoOverlayLayoutTests.testHUDAndHistogramStayInsideEveryVideoRatioAndFrameRatePopupFits` 定向真机回归 1 项通过、0 失败，测试本体 12.114 秒。测试涵盖 20 种视频比例/控件方向布局、视频比例弹窗在 320 pt 和当前设备窗口宽度下的尺寸检查，以及 60 次快速打开/切换/关闭操作；无相机拍摄或系统照片图库写入。12.114 秒是 XCTest 用例耗时，不代表动画帧率或相机性能。结果包：`/private/tmp/LumaCameraOpenGateInfoDeviceRetry.xcresult`。
- 同一用例在 iPhone 17 Pro / iOS 26.5 模拟器通过 1 项、0 失败（12.077 秒）；测试截图检查了标题/开关、说明文本、动态规格区和比例按钮的相对排版。模拟器测试没有启动真实相机，动态能力内容显示无组合回退文案；因此本次确认了布局和回退状态，没有验证设备实际列出的全部 Open Gate 色彩空间、分辨率及帧率组合。真机用例也以布局测试宿主运行，未人工操作相机弹窗。
- 构建：Xcode 27.1 generic iOS `build-for-testing` 与 iOS Simulator `build-for-testing` 均成功。构建过程中使用已安装的 Metal Toolchain；本条记录不代表模拟器服务在受限沙箱内可用。

## 2026-10-20 Open Gate 规格说明紧凑化

- 按新排版要求，移除“仅视频 HEVC 可用；照片格式不适用”及“当前镜头支持的色彩空间、分辨率与帧率”标题。比例说明下依次显示“支持比例：4:3、1:1”、“格式：HEVC”，再按当前镜头实际报告的规格显示紧凑行，例如“SDR：720p：24–60 / 1080p：24–60 / 4K：24–30 fps”。不同色彩空间分行；没有能力数据时显示“暂无可用规格”。帧率范围取设备公布的离散选项最小值和最大值，不表示范围内每个整数帧率均可选择。
- 将规格摘要格式化提取为 `OpenGateCapability.supportedSpecsSummary(from:)`，新增单测覆盖 SDR/P3 分组、分辨率范围和空列表。比例说明组内行距压缩至 2 pt，说明组与比例按钮间距为 10 pt。
- 初次 Xcode 27.1 真机运行于 iPhone 17 Pro / iOS 27.0.1，规格摘要单测和视频比例弹窗布局用例共 2 项通过、0 失败，测试用例时间 11.087 秒，结果包 `/private/tmp/LumaCameraOpenGateRevisionDevice.xcresult`。截图确认文字紧凑、比例按钮无重叠；测试宿主未启动相机，故显示“暂无可用规格”回退文案。随后将测试循环明确改为只遍历五种可选比例（×4 个控件方向），修正此前用例包含隐藏迁移占位项的问题。
- 修正后的测试在已启动的 iPhone 17 Pro / iOS 26.5 模拟器通过，共 2 项、0 失败：规格摘要单测 0.002 秒，比例弹窗布局用例 10.874 秒。覆盖 20 种可选比例/控件方向组合、320 pt 与模拟器窗口宽度、60 次快速切换/关闭操作。XCTest 用例时间包含布局等待，不代表动画帧率或相机性能。结果包 `/private/tmp/LumaCameraOpenGateRevisionSimFinal.xcresult`。未启动其他模拟器，也未拍摄或保存媒体。
- 手机解锁后在 Xcode 27.1 的 iPhone 17 Pro 真机目标上分别重跑上述两项定向测试，均通过、0 失败；最终结果包括修正后的五种可选比例循环。布局测试覆盖 20 种比例/控件方向组合、320 pt 与设备窗口宽度，以及 60 次快速打开/切换/关闭。该用例耗时包含布局等待，不作为动画帧率或相机性能指标。测试未拍摄或保存媒体；规格摘要测试未启动相机会话，因此只覆盖分组与格式化逻辑，真实设备能力仍由运行中的相机会话提供。

## 2026-10-20 Open Gate 说明弹窗布局

- 视频画幅弹窗将 Open Gate 开关移到比例按钮组下方，并在开关后加入应用设置同款圆形感叹号说明按钮。点击后以淡入淡出显示独立玻璃说明窗；支持比例、HEVC 格式和当前镜头可用的色彩空间/分辨率/帧率摘要均收在窗内，画幅面板不再直接展示说明。说明窗点击背景或关闭按钮可退出；退出相机、切换顶部弹窗、进入后台、打开相册或设置时也关闭。
- Xcode 27.1 在 iPhone 17 Pro 真机目标上运行定向 `VideoOverlayLayoutTests.testHUDAndHistogramStayInsideEveryVideoRatioAndFrameRatePopupFits`：1 项通过、0 失败。该用例覆盖 20 种视频比例/控件方向组合，在 320 pt 与设备窗口宽度下渲染画幅弹窗及说明窗，并执行 60 次快速工具栏切换。测试宿主渲染界面但没有启动相机，也没有人工点按说明按钮或关闭弹窗；因此确认了测试构建、布局快照和重复切换稳定性，不代表真实相机工作流或按钮动画的人工验收。未拍摄或保存媒体。
- 命令行 `xcodebuild` 的独立构建尝试受当前受限执行环境的 Metal Toolchain 访问问题阻断；Xcode 图形界面定向测试通过。没有测得动画帧率或设备性能指标，60 次交互样本只用于重复切换稳定性覆盖。

## 2026-10-20 Open Gate 规格移除 fps 后缀

- Open Gate 说明弹窗里的色彩空间规格行现在只显示帧率数值，例如 `SDR：720p：24–60 / 1080p：24–60 / 4K：24–30`；不再在每行末尾重复显示 `fps`。分辨率、范围、色彩空间分组及空能力回退文案不变。相机视频帧率选项、视频详情和其他性能记录中的单位未改。
- 已更新 `OpenGateCapabilityTests` 的预期字符串和布局测试样例。对实现与测试文件运行 `swiftc -frontend -parse`，语法解析通过。
- 本次未能运行 XCTest：`simctl` 报 CoreSimulatorService 连接失败，Xcode 命令行未枚举出已连接 iPhone；因此单元测试和真机显示尚未验证。该改动仅调整说明文本格式。

## 2026-10-20 M 挡流畅预览

- 新增“流畅预览”拍摄辅助，默认关闭并在辅助偏好中独立保存。仅照片 M 挡手动曝光下把实时取景切换为连续自动曝光，并将最长曝光时间限制为当前格式允许范围内、最高不超过 1/30 秒；拍摄请求临时使用所选快门/ISO，随后恢复辅助预览。视频模式不受影响。
- iPhone 17 Pro / iOS 27.0.1 真机测试：`PreviewExposureAssistPhysicalTests.testSmoothPreviewKeepsRequestedStillExposureAndSurvivesRapidToggles` 1 项通过、0 失败，约 12.2 秒。固定后置主摄 1×、M 挡、JPG、ISO 400、1/15 秒；预览发布样本各为三个 1 秒窗口。辅助关闭基线为 15、16、15 帧发布，连续样本的中位帧间隔为 67.820、67.219、65.673 ms；开启后为 25、25、25 帧发布，中位间隔为 41.446、42.076、40.891 ms。指标是 App 收到并发布预览帧的计数与间隔，不代表屏幕刷新率，也不代表相机传感器或显示面板的实际帧率。测试确认自动预览最长曝光不超过 1/30 秒。
- 同一真机用例捕获一张 JPEG 到内存回调、未写入系统相册；请求值 ISO 400 / 1/15 秒，照片元数据采样值为 ISO 399.431 / 0.066563 秒。随后验证辅助策略恢复、20 次快速开关后相机仍就绪，以及关闭辅助后回到 ISO 400 / 1/15 秒手动曝光。该样本只覆盖 iPhone 17 Pro 后置主摄、单一室内场景和一次拍照；没有覆盖其他焦段、低光长期运行、温升或视频。
- `CapturePreferencesTests.testPreferencesPersistAndNewInstallDoesNotRecordLocation` 在同一台 iPhone 上 1 项通过、0 失败，覆盖新安装默认关闭和偏好写入/读回。旧版偏好 JSON 迁移默认关闭也由该测试文件的对应单测覆盖，但本轮未执行该单独用例。
- 构建由上述真机 XCTest 完成。Xcode 在一次重试前短暂未枚举设备，后续目标恢复可用；未启动模拟器。照片格式顶部按钮改为单行“HEIF Pro”且沿用现有等宽工具栏槽位，格式说明字符串更新为“通过 RAW 格式转换 HEIF，保留更多细节和降低锐化，并支持 Pro 影调。”源码检查确认文案和布局条件；本轮没有单独进行顶栏弹窗的人工截图目视检查。

## 2026-10-20 HEIF Pro 按钮文案与说明

- 拍摄页格式按钮在 HEIF Pro 状态只显示“HEIF Pro”，不追加像素信息；沿用同一行其他工具栏按钮的宽度槽位和 32 pt 高度。无障碍标签同步为“图片格式，HEIF Pro”。格式弹窗说明更新为：“通过 RAW 格式转换 HEIF，保留更多细节和降低锐化，并支持 Pro 影调。”
- 与流畅预览一并通过 iPhone 17 Pro / iOS 27.0.1 真机目标构建；同次的 `CapturePreferencesTests.testPreferencesPersistAndNewInstallDoesNotRecordLocation` 1 项通过，但该用例不覆盖格式按钮。源码核对了显示条件、可访问性文本、固定按钮尺寸和说明字符串；真机截图确认当前拍摄页正常打开，但当时仍处于普通 HEIF，未单独进入 HEIF Pro 状态目视验收，因此只确认实现与构建，不记录为视觉验收通过。

## 2026-10-21 人像 48MP、ProRAW 与 HDR 组合核对

- 官方资料区分 Bayer RAW 与 Apple ProRAW，项目采集代码从当前 `availableRawPhotoPixelFormatTypes` 中优先选择 `AVCapturePhotoOutput.isAppleProRAWPixelFormat` 为真的格式；当前路由没有 ProRAW 时才回退到第一个可用 RAW 格式。因此 RAW/RAW+JPG/HEIF Pro 入口并不保证所有设备和焦段都输出 Apple ProRAW。HEIF Pro 的文件资源是 HEIF，而非 DNG。iPhone 17 Pro 后置 1× 真机回归报告 ProRAW 能力开启，RAW 采集走 ProRAW 优先分支；本测试没有把编码像素格式额外写入成片元数据诊断行，故不把 DNG 尺寸本身当成 Apple ProRAW 的独立格式证明。
- 人像不再硬编码限制 12MP。Xcode 27.1，iPhone 17 Pro（iPhone18,1）/iOS 27.0.1，定向 `PortraitCapturePhysicalTests.testPortraitProcessedAndProRAWCapturesWithoutSaving` 1 项通过、0 失败，19.010 秒；构建 `build-for-testing` 成功。A 挡 1× 标准 HEIF 输出 3000×4000，拍摄回调 1.412 秒；切至 M 挡并刷新当前路由后，3 次人像 HEIF 高分辨率捕获均输出 6000×8000（48MP），回调 P50 1.469 秒、最大 1.529 秒；3 次 ProRAW DNG 均输出 8064×6048（约 48.8MP），回调 P50 3.732 秒、最大 3.734 秒。普通 HEIF 对照因路由刚从 A 切至 M，当次输出为 3024×4032；不据此推断 HEIF 非人像规格不支持 48MP。所有诊断资源只留在测试回调内，PhotoKit 待保存数前后不变，未写入系统照片图库。测试期间有系统 `MDB_MAP_FULL` 日志，无用例失败或应用捕获异常；该系统日志来源未确认。
- 当前测试场景未产生可用的人像效果蒙版：HEIF 报告无深度遮罩，ProRAW DNG 未包含 Portrait Effects Matte 辅助数据，`CIRAWFilter` 也未解出蒙版。渲染器按既有策略保留清晰照片；不能将 48MP/ProRAW 成片验证等同于人像虚化效果验证。Apple 文档说明 ProRAW 可携带人像效果蒙版、Bayer RAW 不支持该蒙版，且场景和深度数据会影响蒙版交付。建议另用主体与背景明显分离的人像场景作视觉/蒙版回归。
- Portrait+HEIF HDR 在现有人像 HDR 诊断用例中等待 55 秒仍未收到完成回调；同一设备普通 HEIF HDR（不启用人像）对照成功，输出 10 位、约 12MP 文件。故当前 `PortraitCapturePolicy` 暂停人像+HDR 组合，是项目现有 RAW-backed HDR 捕获路径的实测限制；Apple 文档未规定所有人像与 HDR 通用不兼容。HDR 失败结果包：`/private/tmp/LumaCameraPortraitRun-1792563963.xcresult`。规格策略单测 `PhotoOptionsTests.testPortraitPolicyAllows48MPWhenCurrentCameraFormatProvidesIt` 1 项通过（0.002 秒），结果包 `/private/tmp/LumaPortraitPolicyOct21Retry.xcresult`；人像/ProRAW 真机结果包：`/private/tmp/LumaPortraitRepeatOct21.xcresult`。
- 官方参考：[WWDC21 Capture and process ProRAW images](https://developer.apple.com/videos/play/wwdc2021/10160/)、[`isAppleProRAWPixelFormat(_:)`](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/isappleprorawpixelformat%28_%3A%29)、[`CIRAWFilter.portraitEffectsMatte`](https://developer.apple.com/documentation/coreimage/cirawfilter/portraiteffectsmatte)、[`isPortraitEffectsMatteDeliveryEnabled`](https://developer.apple.com/documentation/avfoundation/avcapturephotosettings/isportraiteffectsmattedeliveryenabled)。


### 路由级 ProRAW 能力与主体场景复测

- 修正 `supportsProRAW` 的发布逻辑，改为检查活动路由实际公布的 RAW 像素格式中是否有 Apple ProRAW 类型；之前读取 `isAppleProRAWEnabled` 只能说明输出对象的全局开关，不能代表当前路由有可选 ProRAW 格式。采集仍按路由格式优先选 ProRAW，缺失时回退 Bayer RAW；人像策略仅在 ProRAW 可用时提供 RAW、RAW+JPG、HEIF Pro。
- iPhone 17 Pro / iOS 27.0.1 上重新运行 `PortraitCapturePhysicalTests.testPortraitProcessedAndProRAWCapturesWithoutSaving` 与 `PhotoOptionsTests.testPortraitPolicyAllows48MPWhenCurrentCameraFormatProvidesIt`，共 2 项通过、0 失败、0 跳过；结果包 `/private/tmp/LumaPortraitFinalOct21.xcresult`。ProRAW 3 次仍为 8064×6048；回调 P50 3.726 秒、最大 3.863 秒。ProRAW 文件没有携带 Portrait Effects Matte，Core Image 也未解出蒙版。用户按清晰主体场景准备设备后复测，仍未得到蒙版；这只能说明该次场景没有产出，不代表所有分离主体场景都不能生成蒙版。诊断照片只保留在测试回调，没有加入系统照片图库。
- `xcodebuild build-for-testing` 与本轮真机定向测试通过。测试覆盖当前后置 1× 路由，不覆盖所有镜头或仅 Bayer RAW 的设备；没有测得人工景深虚化成片效果。

## 2026-10-21 景深控件回归与视频延时摄影接入

- **景深控件最终样式**：按用户的手绘参考，将展开态做成一体式竖向玻璃胶囊：底部是 ƒ 景深标识，滑块向上延伸，顶部只显示“强”，移除底部“无”。滑块折叠后只剩独立 ƒ 圆形标识。微距和 ƒ 标识互斥且都独立放在 A/M 按钮上方；照片模式下即使录像状态值残留，A/M 仍显示，只有视频录制期间隐藏。iPhone 17 Pro / iOS 27.0.1 真机定向 UI 测试 `testMacroIndicatorReplacesPortraitDepthControlAndSliderGrowsUpward` 通过（1 项、0 失败），几何断言确认滑块在上、水平居中，滑块底边与 ƒ 控件顶边相接；已检查测试截图附件 `PortraitDepthSlider-Expanded`，确认 A/M、拍摄辅助和曝光控件不被覆盖。
- **A/M 和录像控件稳定性**：真机定向 UI 测试 `testRecordingControlsKeepPositionsAcrossRatiosAndRotation` 通过（1 项、0 失败）。覆盖 `VideoRatio.allCases` 六种值、竖/横控件方向及录制停止/进行中，共 24 个布局状态；检查 A/M 与拍摄模式按钮的位置和间距保持固定，录制开始隐藏 A/M、停止后恢复，并进行 40 次快速录像/微距状态切换。24 次 `drawHierarchy` 快照绘制样本平均 54.9 ms、最大 73.7 ms；这是 UIKit 离屏截图绘制成本，不等于屏幕 FPS、相机预览帧率或相机处理耗时，不据此宣称帧率改善。两份结果包分别为 `/Users/shurrikann/Library/Developer/Xcode/DerivedData/LumaCamera-gtfyracsdqqmeyaquhzhiluarvad/Logs/Test/Test-LumaCamera-2026.10.21_16-52-54-+0800.xcresult` 与 `/Users/shurrikann/Library/Developer/Xcode/DerivedData/LumaCamera-gtfyracsdqqmeyaquhzhiluarvad/Logs/Test/Test-LumaCamera-2026.10.21_16-51-52-+0800.xcresult`。这是合成控件 UI 回归，不验证真实人像蒙版、景深滑块触摸手感或相机预览画质。
- 视频延时摄影新增五个采样预设：人流 0.5 秒、车流 1 秒、云层 2 秒、日落 5 秒、星夜 10 秒。输入时间戳调度器在滤镜与编码之前抽帧，保留帧按当前帧率连续写入；延时视频不录音频，ProRes RAW 禁用。视频元数据增加拍摄类型与采样间隔。
- iPhone 17 Pro 定向逻辑回归：预设、无效时间戳、快速模式切换 1 项通过；调度性能 5 轮、每轮 10,000 个媒体时间戳，平均 0.581 ms、最大 0.589 ms。此数值只测调度函数，不代表相机帧率、编码吞吐或温升。结果包：`/tmp/LumaCameraDepthDerived/Logs/Test/Test-LumaCamera-2026.10.21_16-11-39-+0800.xcresult`。
- iPhone 17 Pro 布局回归：焦段栏和延时预设背景左右位置及宽度均为 `(x=95, width=212)`，延时条高 40 pt、焦段条高 44 pt；5 个预设按钮宽 40 pt，中心位置间隔约 42 pt。20 次快速切换后位置保持稳定。测试日志：`TIME-LAPSE-UI kind=video enabled=true lenses=7 presets=5 focal=(95,606,212,44) presetBar=(95,552,212,40)`；该测试结果包为 `/tmp/LumaCameraDepthDerived/Logs/Test/Test-LumaCamera-2026.10.21_16-08-20-+0800.xcresult`。
- Xcode 27.1 / iOS 27.1 SDK generic iOS App 构建成功（`CODE_SIGNING_ALLOWED=NO`）。此构建验证编译，不验证设备签名和运行。
- iPhone 17 Pro（设备 `00008150-001934280220401C`，iOS 27.0.1，arm64）通过 Xcode 仅运行定向真机用例 `BasicVideoPhysicalTests.testTimeLapseRecordingCreatesSparseSilentMovie`：1 项通过、0 失败，测试耗时 3.731 秒。使用 HEVC SDR、1080p、30 fps、人流 0.5 秒采样，采集 2.2 秒；测试实测录制至文件检查耗时 2.335 秒，输出 5 帧、时长 0.1667 秒、标称帧率 30 fps、无音轨；`AVAssetReader` 完整解码至 `.completed`。测试文件在临时目录完成检查后删除，没有写入系统 Photos。该单次短片只验证 0.5 秒预设和当前后置路由，不代表另外四档、长时间录制、各镜头路由或热稳定性已经通过。
- 本次测试结果包：`/Users/shurrikann/Library/Developer/Xcode/DerivedData/LumaCamera-gtfyracsdqqmeyaquhzhiluarvad/Logs/Test/Test-LumaCamera-2026.10.21_16-26-43-+0800.xcresult`。系统日志同时出现 `MDB_MAP_FULL` 和 Fig 状态监视器诊断行；来源未确认，XCTest 用例通过且成片检查指标符合断言，不据此判断为应用故障或 Apple 平台保证。
- 规则依据：[Apple AVCaptureVideoDataOutputSampleBufferDelegate](https://developer.apple.com/documentation/avfoundation/avcapturevideodataoutputsamplebufferdelegate?changes=_1_5&language=objc) 与 [AVAssetWriterInputPixelBufferAdaptor.append(_:withPresentationTime:)](https://developer.apple.com/documentation/avfoundation/avassetwriterinputpixelbufferadaptor/append%28_%3Awithpresentationtime%3A%29?changes=la) 支持按采集样本及媒体时间处理/写入视频帧；Apple 没有公布这些延时题材档位的间隔推荐，档位数值是应用预设。

### 景深预览稳定性、人像切换淡出与微距策略

- 连续拖动景深滑块时，`setPortraitPreview` 只有在预览开关状态或代次变化时才重新配置分割器；强度变化只更新当前渲染值。`PortraitPreviewProcessor` 保留最近一张有效的人像蒙版，短暂漏检时连续保留最多两次，第三次连续漏检才清除；蒙版仍受 0.55 秒最大使用时限约束。
- 人像模式开关复用既有预览切换覆盖层：先保留当前预览帧，切换照片输出并收到新帧后淡出覆盖层；最长 2 秒超时仍会释放覆盖层。淡出时长为 0.14 秒（系统开启“减弱动态效果”时遵循既有更短淡出路径）。A 挡重新提交人像照片输出配置后重新设置虚拟设备的 `.auto` 主镜头切换行为，并保留系统支持的超广角 fallback。官方参考：[AVCaptureDevice.PrimaryConstituentDeviceSwitchingBehavior.auto](https://developer.apple.com/documentation/avfoundation/avcapturedevice/primaryconstituentdeviceswitchingbehavior-swift.enum/auto)，它说明系统可自动选择虚拟设备的主组成镜头；近景时是否切换仍由当前场景和设备决策。
- iPhone 17 Pro / iOS 27.0.1 定向真机 XCTest：`PortraitCapturePhysicalTests.testPortraitModeKeepsAutomaticVirtualCameraAvailableForMacro` 与 `PortraitDepthControlTests.testPreviewMaskSurvivesTransientSegmentationMissesDuringSliderDrag`，2 项通过、0 失败、0 跳过。人像开关循环 6 次（开/关各 3 次），每轮断言旧预览帧覆盖层已建立、相机预览帧已更新且覆盖层释放；虚拟设备仍处于 `.auto`、限制条件为 0，超广角 fallback 保持可用。切换至新画面并释放覆盖层的总耗时中位数 875.7 ms、最大 1.062 s。该计时包含相机输出重配、等待新帧和覆盖层释放，不等于淡出动画自身时长、屏幕 FPS 或单次镜头切换耗时。蒙版稳定性用例通过 100 次相同配置更新及 1/2/3 次合成漏检检查。
- Xcode 27.1 / iOS 27.1 SDK `build-for-testing` 成功；最终真机结果包：`/private/tmp/LumaPortraitDragAndMacroOct21-final.xcresult`。本轮没有测量真实预览的屏幕帧率，也没有让用户在指定近距离主体前实际观察微距自动进入；测试证明的是淡出覆盖层生命周期、分割结果保持策略和 A 挡自动切镜配置未被人像输出更新关闭。实际视觉闪动与真实场景微距触发仍应由用户在常用场景确认。

## 2026-10-22 视频照片切换曝光恢复、分页与相关回归

- **视频切回照片后的手动曝光**：视频路由会设置活动视频帧间隔；退出时现在清除照片路由继承到的活动帧间隔与自动曝光上限。M 挡照片自定义快门慢于 1/30 秒时，根据活动格式公布的帧率范围放宽预览输出的最大帧间隔；较快快门恢复默认值。官方文档说明 `activeVideoMaxFrameDuration` 必须落在活动格式支持范围内，设为 invalid 可恢复格式默认值；`activeMaxExposureDuration` 设为 invalid 则恢复当前配置的 AE 默认上限。参考：[activeVideoMaxFrameDuration](https://developer.apple.com/documentation/avfoundation/avcapturedevice/activevideomaxframeduration)、[activeMaxExposureDuration](https://developer.apple.com/documentation/avfoundation/avcapturedevice/activemaxexposureduration)。
- iPhone 17 Pro（设备 `00008150-001934280220401C`，iOS 27.0.1）`VideoModeTransitionTests.testLiveHDRAndManualPhotoRoutesSurviveVideoRoundTrips` 通过。Live、HDR、M 挡手动三种状态分别往返照片/视频；视频轨道恢复为 1920×1080。M 挡预设 ISO 200、1/2 秒，切回后当前 ISO 读数断言为 200±5，实际快门为 0.499895 秒；活动格式上报最大曝光 1 秒，实际活动最大视频帧间隔按格式设置为 0.5 秒。XCTest 使用测试回调接收并删除临时视频，不把诊断照片或视频写入系统 Photos。
- **反复路由切换性能/稳定性**：同设备运行 `VideoModeTransitionTests.testRepeatedModeTransitionPreviewLatency`，照片↔视频往返 3 轮，共 6 次切换。记录相机串行队列配置任务屏障时间和首个新预览帧时间：视频方向配置中位数 390 ms，预览恢复中位数 735 ms、最大 751 ms；照片方向配置中位数 395 ms，预览恢复中位数 466 ms、最大 488 ms。各方向切换窗口内最大的预览帧时间戳间隔分别为 712 ms 和 455 ms。测试统计的是 App 预览帧主机时间戳，不是屏幕刷新率或稳定 FPS；每方向 3 个样本，不能代表所有光线、镜头和温度条件。
- **快门刻度**：`CameraRulerMappingTests.testShutterTickValuesSnapToStandardFractions` 验证标准分数吸附；范围内无标准档位时保留连续值，并使用连续映射。`testManualParameterDragAdvancesByVisibleQuantizedTicks` 验证拖动一格就更新到屏幕所见的下一档，ISO 400→500；慢门稀疏刻度在 300 pt 标尺上的单格距离不超过 30 pt。另运行快慢方向测试。三项通过；该单格距离是映射计算值，不是实体屏幕上的手指拖动速度测量。
- **视频详情左右翻页与参数行**：`GalleryPhotoPagingTests.testVideoCanvasPagingUsesHorizontalSwipesOnly`、`testVideoPageDoesNotWaitForPhotoPosterLoading` 均通过；验证横向分页策略以及视频路由跳过静态照片海报预加载。没有通过 UI 自动化在真实播放器上模拟手指滑动。`VideoDetailLayoutTests.testVideoInfoAndLandscapeLevelFitCompactAndRegularScreens` 通过；当前视频详情已按“设备信息→无卡片背景的一行拍摄参数→位置信息”排列，参数行复用照片详情组件。布局测试覆盖紧凑及常规宽度，但本轮没有人工目视检查实际视频详情。
- **RAW 外接存储时长**：`VideoEncodingPolicyTests.testExternalRAWCapacityShowsSpaceAndApproximateRemainingTime` 通过，以合成的容量快照验证只使用合规驱动器数据，并按当前码率估算剩余时长。没有连接 SSD；实盘挂载、RAW/RAW HQ 长时间写入、容量刷新和拔盘恢复仍未验证。
- **DockKit 主体点选和框选**：`CapturePreferencesTests.testDockKitPreviewMappingAccountsForAspectFillCrop` 与 `testDockKitPreviewMappingRejectsInvalidGeometry` 通过，覆盖预览裁切坐标转换和无效矩形拒绝。界面轻点调用 Apple `selectSubject(at:)`，按住拖动调用 `setRegionOfInterest(_:)`。Apple 文档说明前者按归一化点位选择已检测主体，后者设置跟踪区域；区域包含多个主体时不承诺具体选中对象。参考：[selectSubject(at:)](https://developer.apple.com/documentation/dockkit/dockaccessory/selectsubject%28at%3A%29)、[setRegionOfInterest(_:)](https://developer.apple.com/documentation/dockkit/dockaccessory/setregionofinterest%28_%3A%29)。未连接云台附件，未验证实际主体识别、追踪稳定度或电机响应。
- 本次最终定向真机 XCTest 共 11 项通过、0 失败、0 跳过，测试执行时间 35.072 秒；结果包 `/private/tmp/LumaCameraSevenFixes-Final.xcresult`。没有启动模拟器。测试日志仍出现 `MDB_MAP_FULL: Environment mapsize limit reached`；XCTest 全部通过，但该系统日志来源尚未确认，不据此归因相机管线或本轮修改。

## 2026-10-22 外接 RAW 白平衡锁定与文件释放

- 用户提供的录制失败截图显示：`录像失败：White balance mode is not locked.`。代码原先发起 `setWhiteBalanceModeLocked` 后立即创建 RAW 写入器；现改为等待 Apple 完成回调，再开始创建写入器。Apple 文档明确说明该回调在白平衡调整完成且模式设为 locked 后调用：[setWhiteBalanceModeLocked(with:completionHandler:)](https://developer.apple.com/documentation/avfoundation/avcapturedevice/setwhitebalancemodelocked%28with%3Acompletionhandler%3A%29)。此时序修复与截图错误直接对应，但尚未在 iPhone 上确认消除此错误。
- 用户报告三星 T7 可由系统相机录制，但光屿录制完成后在“文件”App 无法删除视频。`RecordingAccess` 现在随外接写入器持有 security-scoped URL，并在 `finishWriting` 完成、取消或失败后先释放访问权，再通知界面；初始化失败及录制前取消也走幂等释放。官方外接存储 URL 由 [`nextAvailableURLs(withPathExtensions:)`](https://developer.apple.com/documentation/avfoundation/avexternalstoragedevice/nextavailableurls%28withpathextensions%3A%29) 提供；Foundation 要求对 security-scoped URL 平衡调用 [`startAccessingSecurityScopedResource()`](https://developer.apple.com/documentation/foundation/url/startaccessingsecurityscopedresource%28%29) 和 [`stopAccessingSecurityScopedResource()`](https://developer.apple.com/documentation/foundation/url/stopaccessingsecurityscopedresource%28%29)。代码路径已调整，但“文件仍不能删除”的现象需在 T7 上复测，当前不能写成已解决。
- iPhone 17 Pro / iOS 27.0.1 真机回归：白平衡锁定用例在 HEVC SDR 1080p30 下各录制一段关闭/开启样片。关闭时设备模式保持录制前值；开启时写入开始前已进入 `.locked`，700 ms 后 RGB 增益保持一致，停止后恢复原模式。立即取消发生在锁定请求回调期间，确认没有交付视频 URL、相机仍就绪，并在恢复白平衡后清除快门忙碌状态。第一次取消断言过早读取设备状态，测试揭示忙碌状态早于白平衡恢复被清除；现已让忙碌状态保持到恢复完成，重跑通过。
- 同设备 `BasicVideoPhysicalTests.testRepeatedVideoRecordingsAndPhotoModeReturn` 通过（约 9.06 秒）：三次后置录像开始/停止、一次前置录像、回切照片并完成一张只进入内存回调的诊断照片。白平衡真机用例与普通录像回归最终同次共 2 项通过、0 失败、0 跳过，结果包 `/private/tmp/LumaCameraRealDeviceDerived/Logs/Test/Test-LumaCamera-2026.10.22_11-28-29-+0800.xcresult`。另有设置默认/迁移/持久化与 RAW 策略 3 项通过，结果包 `/private/tmp/LumaCameraRealDeviceDerived/Logs/Test/Test-LumaCamera-2026.10.22_11-20-41-+0800.xcresult`。这些实拍均使用临时目录及被测试覆盖的回调，不写入系统 Photos。
- “光轨”两行名称测试、照片拍摄类型详情测试、照片/视频分页几何测试均通过；分页只验证共用动画偏移规则，没有在真实播放器上手势滑动或目视验收。结果包分别为 `/private/tmp/LumaCameraRealDeviceDerived/Logs/Test/Test-LumaCamera-2026.10.22_11-24-28-+0800.xcresult` 与 `/private/tmp/LumaCameraRealDeviceDerived/Logs/Test/Test-LumaCamera-2026.10.22_11-25-15-+0800.xcresult`。未启动模拟器。
- 当前真机验证只覆盖 HEVC SDR 1080p30 的普通视频白平衡开关和恢复，不代表 ProRes 或其他色彩空间已逐一验证。三星 T7 的 RAW/RAW HQ 实盘写入、“文件”App 删除及拔盘恢复仍待外接盘端到端复测；此次也没有手动在“文件”App 删除录制文件。

## 2026-10-22 视频白平衡锁定偏好与慢门名称

- 拍摄设置“白平衡锁定”的标题后说明按钮补充了适用范围：HEVC、H.264、常规 ProRes 及设备支持的 SDR/P3、HDR、Apple Log/Log 2 组合；说明分辨率与帧率取决于当前镜头能力，并指出 ProRes RAW/RAW HQ 自动锁定。该改动仅更新说明文案，锁定逻辑未变。
- 拍摄设置新增“白平衡锁定”，默认关闭并作为独立应用偏好持久化，不受“保存拍摄设置”影响。普通视频开启后，在写入器启动前请求锁定当前设备白平衡，并等待 Apple 完成回调，再开始写入；停止、取消、写入失败或初始化失败时恢复录制前模式。RAW 视频仍自动锁定以满足其录制路径要求。设置入口含功能说明及辅助功能标识。
- 该实现依据 Apple `setWhiteBalanceModeLocked(with:completionHandler:)`：传入 `AVCaptureDevice.currentWhiteBalanceGains` 可保留当前白平衡，完成回调表示设置已应用且模式进入 locked：[Apple 文档](https://developer.apple.com/documentation/avfoundation/avcapturedevice/setwhitebalancemodelocked%28with%3Acompletionhandler%3A%29)。这是 API 对白平衡应用时点的说明，不等于已在本设备上验证色彩观感或每种视频格式。
- 慢门预设第一项由“灯轨”更名为“光轨”；预设按钮、辅助功能提示和当前拍摄类型名称一致，照片详情仍从拍摄时记录值读取。
- `CapturePreferencesTests` 覆盖默认关闭、持久化和旧设置迁移默认值；`VideoEncodingPolicyTests` 覆盖普通视频可选锁定、RAW 必须锁定的策略。Xcode 27.1 / iOS 27.1 SDK generic iOS `build-for-testing` 编译通过，包含以上两组和照片类型/预设按钮相关测试。
- iPhone 17 Pro / iOS 27.0.1 真机定向测试通过：白平衡默认关闭/开启及录像停止恢复、700 ms 增益稳定、锁定请求期间立即取消恢复，另有 3 次后置录像、1 次前置录像及切回照片拍摄回归。设置默认关闭、旧设置迁移与持久化，以及普通视频/RAW 锁定策略测试通过；“光轨”显示、拍摄类型详情和分页方向几何测试通过。详见上一节记录的结果包和覆盖范围。没有启动模拟器。
- 本轮只实际录制 HEVC SDR 1080p30；ProRes、其他色彩空间与不同镜头路由尚未逐项验证。普通视频的增益稳定通过设备 `.locked` 状态与短时相同增益读数确认，没有在录制时移动手机或更换场景作人工色彩观察。三星 T7 RAW/RAW HQ 实盘写入、“文件”App 删除与拔盘恢复仍需连接该盘端到端验证。
- iPhone 17 Pro 重新连接后再次运行 `VideoWhiteBalancePhysicalTests.testVideoWhiteBalanceLockIsOptionalAndRestoredAfterRecording`：1 项通过、0 失败、0 跳过，Xcode 27.1 / iOS 27.1 SDK，结果包 `/private/tmp/LumaCameraWBReconnect.xcresult`。同一用例分别录制白平衡开关关闭和开启的 HEVC SDR 1080p30 视频，再测试锁定回调期间立即取消；检查录制前后的设备模式、开启时锁定状态与 700 ms 内 RGB 增益稳定、取消不交付 URL 且相机保持就绪。全部临时视频已删除，未写入系统 Photos。
- 本次启动延迟样本数为 2（关闭、开启各 1 次），从 ViewModel 发起录制到 `videoRecording == true` 分别约 119 ms 和 212 ms，中位数约 119 ms、最大约 212 ms；不包含相机路由初始配置，也不代表屏幕帧率。热状态为 nominal。测试日志出现 `MDB_MAP_FULL` 提示但用例通过，来源尚未确认，不归因于白平衡功能。
- 本次确认了手机连接，未确认三星 T7 当时已挂载，因此没有复测外接 RAW/RAW HQ 写入、“文件”App 删除及拔盘恢复；这些仍是独立待验证项。
- 后续在 iPhone 17 Pro / iOS 27.0.1 真机启动当前版本，打开“应用设置 → 拍摄设置 → 白平衡锁定”说明弹窗，目视确认标题、适用规格与 RAW 说明完整显示、没有被弹窗边缘截断；关闭弹窗后开关仍为关闭。此次是设置说明 UI 的真机核对，不重新验证录像锁定行为、其他编码/色彩空间组合，也没有录制媒体。

## 2026-10-22 视频电影模式与慢动作子模块规格切换

- 电影子模块接入 iOS 26 Cinematic Video API：仅按当前镜头输入及活动格式的系统能力开放，启用后使用设备格式提供的默认虚拟光圈，点按画面请求系统主体跟踪对焦。当前 `AVCaptureVideoDataOutput` 路径会把散景烘焙进输出帧，不保留可供 Cinematic 框架无损改焦的 disparity 轨道。慢动作沿用 120 fps 输入帧时间戳重映射。
- 延时、慢动作、电影入口均按设备能力选择最接近当前设定的兼容规格；切换后，顶栏中当前子模式不支持的分辨率、帧率、色彩空间或编码不可选。三种视频子模式互斥；电影与 RAW、ProRes、Open Gate、延时和慢动作互斥。若当前路由没有对应能力，入口会说明不可用。
- 依据 Apple [WWDC25 Cinematic Video](https://developer.apple.com/videos/play/wwdc2025/319/) 与 [AVCaptureDevice.Format Cinematic 能力](https://developer.apple.com/documentation/avfoundation/avcapturedevice/format/iscinematicvideocapturesupported)：需要 iOS 26+、设备输入和格式均明确支持，并使用 Cinematic 专属帧率范围。Apple 说明 Video Data Output 的像素帧已带景深效果；非破坏性编辑需要系统电影文件输出携带的 disparity 与元数据，本项目当前自定义 AVAssetWriter 链路不提供该能力。
- Xcode 27.1 / iOS 27.1 SDK，`xcodebuild -project LumaCamera.xcodeproj -scheme LumaCamera -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/LumaCameraDerived build-for-testing -quiet` 退出码 0；App 与测试 target 均完成编译。新增/相关的慢动作策略、电影规格选择、子模式互斥及 60 次快速切换 XCTest 已编译，但本轮没有执行测试用例。
- 真机和模拟器回归尚未完成：`xcrun devicectl list devices` 等待 15 秒后报 `Timed out waiting for CoreDeviceService to fully initialize`；按历史设备 ID 发起的定向 XCTest 也以“no available devices matched”退出，当前环境此前同时报告 CoreSimulatorService 不可用。因此没有启动相机、没有录制媒体，也没有启动模拟器。性能指标样本数为 0；代码中准备的慢动作计时基准是 5 轮、每轮 10,000 个时间戳映射及 20 次调度器重启，60 次子模式切换测试也都需在测试运行器恢复后执行。下一步需在 iPhone 17 Pro 上确认电影实时预览/成片景深与主体跟踪，再连续切换延时/慢动作/电影并验证录像停止、取消和回到照片；不能把本次构建通过视作硬件验证通过。

## 2026-10-22 拍照与视频子模块自动适配

- 拍照的慢门、夜景、人像、连拍与视频的延时、慢动作、电影入口不再按当前规格是否兼容来禁用；相机未就绪、正在拍摄/录像或正在准备子模式时仍锁定入口，避免并发改写会话。
- 启用时先尝试沿用当前镜头和兼容参数；不兼容时，照片按当前相机公布的镜头能力选择兼容镜头、格式和分辨率，视频在相机串行队列检查各镜头公开的视频格式能力后选兼容镜头与最接近的安全规格。视频能力按物理设备 ID 缓存，避免每次弹窗或参数刷新重复扫描格式。切换期间禁用规格与焦段调整；启用后只开放当前子模块兼容的参数和已确认兼容的镜头。用户选择 Open Gate 延时但没有可用 Open Gate 路线时，回退到普通视频兼容路线并关闭 Open Gate。
- 当前子模式遇到设备能力异步刷新时，视频规格会尝试在当前路线内重新匹配；没有可用候选则退出该子模式，避免继续以不兼容参数录制。智拍入口当时保持可点并反馈“尚未开放”；该历史状态已被 2026-10-27 的智拍接入取代，详见 [智拍功能说明](SmartCapture.md)。
- 回归覆盖新增的照片/视频兼容策略、备用视频镜头路线能力和既有 60 次视频子模式快速切换用例；所有测试均随 Xcode 测试 target 编译。Xcode 27.1 / iOS 27.1 SDK 执行 generic iOS `build-for-testing`，退出码 0（`/private/tmp/LumaCamera-Submode-Derived`）。编译只发现 `CameraRuler.swift`、`DockKitTrackingController.swift` 的既有未使用变量警告及 App Intents 元数据跳过提示，没有本次修改文件的编译警告。
- 本次没有执行 XCTest：`xcrun devicectl list devices` 报 `Timed out waiting for CoreDeviceService to fully initialize`；`simctl` 报 CoreSimulatorService 连接失效。因此真机/模拟器运行样本数均为 0，不能据此确认镜头实际切换、子模式体验、重复切换稳定性或实机耗时。代码将设备格式扫描移到相机串行队列并缓存，但本轮没有取得真实时间指标；应在设备服务恢复后定向验证不兼容点按、自动换镜头、启用后禁用不兼容选项，以及 60 次快速切换和取消/返回路径。

## 2026-10-22 iPhone 17 Pro 真机全量回归与 RAW 能力提示

- 在 iPhone 17 Pro（设备 ID `00008150-001934280220401C`）上运行完整测试 target；为避免诊断媒体写入系统照片图库，跳过 `LiveAudioSavePhysicalTests`，并因未连接外接盘跳过 `ProResRAWPhysicalTests`。测试共执行 251 项，2 项跳过，29 个测试方法失败，累计 163 条断言/等待失败；XCTest 报告用例执行时间 743.322 秒，Xcode 总测试时长约 1137.9 秒。本轮不是全绿，不能视为全功能验收通过。
- **预览黑帧专项通过**：`HEIFHDRPhysicalTests.testTurningHDRBackOffDoesNotPublishBlackPreviewFrames` 连续 3 次 HDR→SDR 往返，每轮采集 6 帧；三轮最低平均亮度分别为 0.1787、0.2285、0.2297，测试的黑帧门限为 0.0005，未发现黑帧。该结果只覆盖 HEIF HDR 关闭后的实时预览，不代表其他启动/路由异常均已排除。
- HDR HEIF 10 位成片、16 位预览及 A/M 与焦段恢复用例通过；自动变焦、前置广角切换、焦段元数据、Live 配对和音轨、连拍回调、滤镜编辑压力、ProRes 常规编码、视频滤镜渲染及视频详情布局等用例也有通过记录。视频预览帧发布样本：24/25/30/50/60 fps 对应测得约 23.2/24.8/29.8/50.0/59.5 次/秒；这些是应用层帧发布频率，不是屏幕扫描帧率。当前设备/路由没有公布 120 fps 测试规格。
- 初次全量跑发现 `CapturePreferencesTests` 在前置转后置后仅等待 `camera.ready`，没有等待选定的后置 1× 路由和该路由的 RAW/HEIF Pro 能力更新，便发起诊断捕获。此时活动路由没有 RAW 像素格式，相机按能力保护拒绝请求并显示“当前镜头不支持 RAW”。该提示来自测试捕获请求，诊断数据未写入系统照片图库。已修正测试：显式设置目标格式，等待目标镜头、格式能力和新预览帧稳定；不支持时跳过能力专用测试。随后两项 RAW 元数据与 HEIF Pro HDR 真机用例单独复测通过（2 项、0 失败，5.746 秒）。这证实当时的提示是测试在镜头切换尚未完成时请求 RAW 导致；没有证据表明稳定后的后置 1× RAW 能力异常。
- 其余失败包含：自动镜头稳定用例要求超广角 fallback，但设备快照实际为系统 `.auto` 切换、主摄、wide fallback；自动 ISO 断言的预期上限为 7680，设备实际值为 6655.2；慢门/预览优化、延时拍摄、人像/ProTone 静态捕获有等待或曝光状态不符；2:1/2.39:1 摄像比例测试有显示尺寸断言差异。全量期间测试进程在滤镜全比例渲染用例附近经历一次异常退出/超时并由 XCTest 重启；后续多项视频用例报告相机仍有待处理捕获或无首帧，存在共享相机状态造成级联失败的可能，但尚未通过独立复测确认。应逐项重新定向运行这些失败用例后再判定产品缺陷。
- 本轮 Xcode 日志反复出现 `MDB_MAP_FULL`，该系统日志来源未确认；Xcode 收集设备诊断包也失败。外接存储 RAW/RAW HQ 录制没有连接三星 T7 实测，因此仍未验证。全量结果包：`/private/tmp/LumaCamera-FullDevice/Logs/Test/Test-LumaCamera-2026.10.22_14-41-49-+0800.xcresult`；RAW 与 HEIF Pro HDR 定向复测结果日志：`/private/tmp/LumaCamera-CapturePreferences-targeted.log`。

## 2026-10-22 HEIF Pro 格式入口恢复与双行标签

- 检查发现拍照格式弹窗遍历格式时显式排除了 `.heifPro`，而顶部工具栏只在当前已选择 HEIF Pro 时显示名称；因此用户切到其他格式后无法从弹窗切回 HEIF Pro。这不是镜头能力限制，而是入口被列表过滤条件隐藏。
- HEIF Pro 保持可选入口，仍由 `canSelectPhotoFormat` 按当前镜头 RAW 能力和子模块规则控制。格式弹窗现将 HEIF Pro 单独放在 HEIF 按钮下方，右侧附 9 pt 双行说明；选择 HEIF Pro 时不再在下方重复显示同一说明。顶部工具栏在横竖屏均显示“HEIF / Pro”两行，固定 32 pt 槽位、旋转与点击区域不变。其他原有显式双行标签（如 Apple Log / Log 2）未按方向分支，继续在横竖屏使用同样排版。
- `swiftc -frontend -parse` 对工具栏、格式弹窗和布局样例通过。Xcode 27.1 / iOS 27.1 SDK 的 iOS generic `xcodebuild build` 和 `build-for-testing`（禁用签名，不启动模拟器）均通过；初次沙盒构建被 Metal 编译器写入固定 `~/.cache/clang/ModuleCache` 的权限挡住，按构建所需权限重试通过。仍有 2 条既有 Swift 警告：`CameraRuler.swift` 未使用绑定值 `ticks`、`DockKitTrackingController.swift` 未使用绑定值 `accessory`，与本次改动无关。
- 已通过 Xcode 选择的 iPhone 17 Pro 目标执行 Run，Xcode 显示 `Running LumaCamera on 笨笨波尔霸&iPhone Pro`，调试进程 PID 1200 可见。尝试用 View Hierarchy 读取画面时，Xcode 报告应用未响应快照请求；调试器暂停后已恢复运行。因无法取得手机屏幕快照，本轮未目视确认 HEIF Pro 弹窗布局、竖屏/横屏标签或切换稳定性，也未测量性能。未拍照或向系统照片图库写入文件；后续补做目视复核时只需检查 HEIF Pro 入口与横竖屏双行标签。
## 2026-10-22 CameraEngine 读数发布警告规避

- 用户报告 Xcode 控制台重复出现 5 条 `Publishing changes from within view updates is not allowed`，位置指向 `CameraEngine.captureOutput` 的读数更新。这里的 5 条是运行时警告重复打印次数，不足以说明存在 5 种不同错误；它提示 `ObservableObject` 的发布与 SwiftUI 视图更新事务发生重叠。
- 读数和微距状态仍按原来的约 0.4 秒采样周期计算；发布改为延后一帧（约 16.7 ms），再确认相机仍运行且读数代次、微距路由代次未改变后更新 `@Published`。相机切换后排队中的旧读数会被丢弃。该延迟是调度间隔，不是实际预览帧率指标。
- `swiftc -frontend -parse LumaCamera/Core/Capture/CameraEngine.swift` 通过；Xcode 27.1 generic iOS `build-for-testing` 通过，测试 target 编译完成。构建仍报告项目已有的 `CameraRuler.swift` 与 `DockKitTrackingController.swift` 两条未使用变量警告，与本次运行时警告不同。
- 本轮设备服务 `CoreDeviceService` 无响应，未能启动模拟器或真机回归；运行时警告复现/消失测试样本数为 0，性能/稳定性重复操作样本数为 0。因此代码已构建，但不能宣称五条警告已在设备上确认消失。下一次真机复核需观察多次读数更新和微距切换，并确认控制台不再出现该警告。

## 2026-10-22 相机会话重试重建入口（待真机验证）

- 用户反馈相机持续提示“相机暂时无法恢复，请点击重试重新连接”。检查发现旧重试按钮只调用 `start()`，会在 `configured` 仍为 true 时重复启动原会话；若输入/输出图已经失效，重试不会重建连接。
- 新增显式重试路径：等待未完成的照片/视频收尾，停止会话并移除旧输入/输出，清理缓存连接后走现有 `start()` 重建；该路径保留当前请求的拍摄模式、手动状态、焦段与倍率，由正常配置流程重新应用当前照片/视频规格。自动微距仍由系统虚拟多摄决定。运行时错误现在也读取并记录通知提供的错误域、编号和说明，便于区分媒体服务重置、会话错误及其他原因；依据 Apple [`runtimeErrorNotification`](https://developer.apple.com/documentation/AVFoundation/AVCaptureSession/runtimeErrorNotification) 对 `AVCaptureSessionErrorKey` 的说明。
- Xcode 27.1 / iOS 27.1 SDK generic iOS 构建通过（`CODE_SIGNING_ALLOWED=NO`，产物位于 `/private/tmp/LumaCamera-ReconnectBuild`）；未启动模拟器。当前 Mac 的 `CoreDeviceService` 初始化超时，`xcrun devicectl list devices` 约 16 秒后失败，故修复版未安装。真机恢复、重复重试与 A/M/视频设置保留检查样本均为 0；此项不能记为已解决或真机通过，待设备服务恢复后继续验证。
- 反馈前的慢动作/电影两轮真机测试另行记录：慢动作路由分别约 0.946 秒和 0.486 秒；两次电影切换各约 13.6 秒并失败回退。该结果说明电影路由回归仍失败；没有证据证明它与持续相机恢复提示存在因果关系。

## 2026-10-22 人像景深上限与相机提示发布时序

- 人像预览与照片成片共用 `PortraitPhotoRenderer`，因此将最大模糊半径从 22 降至 8.8（40%）；前置和后置人像统一生效。滑块仍显示并保存 0–100% 的归一化位置，100% 对应新上限，50% 对应半上限。没有改动滤镜、相机参数或其他页面样式。
- 定向 XCTest 断言已更新：检查 0%、50%、100%、越界和非有限输入，并验证新最大半径是旧值的 40%。iOS 27.1 SDK generic `build-for-testing` 成功，包含应用和测试 target 编译；本轮没有运行 XCTest。
- 将 `CameraView` 的系统错误弹窗 Binding 改为在下一轮主线程清空消息，并确认消息仍是刚关闭的那一条，避免 `alert` 视图更新时同步写入 `camera.message` 引发 `Publishing changes from within view updates is not allowed`。代码构建通过；运行时告警是否消失仍待真机确认。
- 当前 `CoreDeviceService` 与 `CoreSimulatorService` 均不可用：`devicectl` 初始化超时，`simctl` 连接被拒绝。相机恢复重试、人像滑块的真实预览/成片观感，以及上述运行时告警复测均未执行，样本数为 0，不能记作真机或 XCTest 通过。

## 2026-10-22 Swift 6 电影规格闭包捕获错误

- 修复 `CameraViewModel.swift` 电影规格就绪检查闭包中对实例属性的隐式访问：改为显式读取 `self.videoResolution`、`self.videoFrameRate` 和 `self.videoColorSpace`。这是 Swift 6 对逃逸/嵌套闭包捕获语义的编译要求，不涉及运行时路由逻辑。
- Xcode iOS 27.1 SDK `build-for-testing` 通过，应用和测试 target 均完成编译；结果日志为 `/private/tmp/LumaCameraSwift6ClosureFix.log`。该项是编译修复，未另跑 XCTest 或真机录制。

## 2026-10-22 电影模式分辨率与帧率选择修复

- 用户反馈电影模式启用后分辨率和帧率无法选择。原支持方法要求待点击项目必须与当前另一项完全匹配；这使分辨率/帧率成为相互锁死的组合，无法从一个组合转到另一个组合。
- Cinematic 规格现按 Apple 相机公开给 iPhone 17 Pro 的组合过滤：1080p30、4K24、4K30；Apple 对较新机型公布的 1080p60/4K60 也允许进入候选筛选，但只有当前镜头格式明确支持 Cinematic、对应帧率范围及所选色彩空间时才会出现。选择分辨率或帧率时，如果保留另一项会造成不兼容，就原子调整为同色彩空间下最近的允许组合。1080p24、720p及25/50/120 fps 不开放。
- 官方依据：[Apple 中文 iPhone 电影模式录制设置](https://support.apple.com/zh-cn/guide/iphone/iphc1827d32f/27/ios)说明默认 1080p30，可切换 4K24 或 4K30，较新机型另有 60 fps 组合。该文档描述相机 App 提供的规格；本应用还按 AVFoundation 当前输入格式能力验证，不把官方相机 UI 规格视为硬件能力保证。
- 新增 XCTest 覆盖三种规格白名单、非官方组合拒绝、1080p30 与 4K24/30 之间的分辨率/帧率联动，以及切回 1080p 时自动恢复 30 fps。Xcode 27.1 / iOS 27.1 SDK 执行 generic iOS `build-for-testing`，退出码 0，App 与测试 target 编译通过；仅构建测试 target，未执行 XCTest。
- 本轮设备服务检查发现 CoreSimulatorService 连接失效；`simctl` 无法枚举设备，`devicectl` 也未返回设备列表，因此没有真机/模拟器行为验证。测试样本数为 0，未取得启动延迟、帧率、内存或温度指标；修复逻辑和电影实拍输出需在服务恢复后定向回归。构建发现 `DockKitTrackingController.swift` 与 `CameraRuler.swift` 两条既有未使用变量警告，与本次修改无关。

## 2026-10-22 慢动作采集规格选择与 HDR 元数据路径

- 慢动作规格弹窗现在将分辨率与帧率明确标为“采集分辨率 / 采集帧率”，只展示当前镜头支持、且存在更低回放率的采集候选。普通 SDR/P3 路由按设备格式展示 120/240fps；4K HDR 120fps 仅允许后置物理主摄，并要求活动设备格式支持 HLG 色彩空间、HDR 与 120fps。切换采集帧率时，输出回放率保持原值；如果回放率不低于采集率，则自动选到最近的兼容较低回放档。退出慢动作后，弹窗恢复普通输出分辨率与帧率列表。
- 24fps 是回放输出率而非慢动作采集率：4K HDR 120fps 或普通 120/240fps 采集均可按更低帧率映射播放；慢动作弹窗不会把 24fps 当作采集档显示。
- HDR 编码链路启用 `AVCaptureVideoDataOutput.preservesDynamicHDRMetadata`（iOS 26+），并给 HEVC Main10 / HLG BT.2020 的 `AVAssetWriter` 设置 VideoToolbox 自动 HDR 元数据插入与动态元数据保留。Apple 文档说明，使用 `AVCaptureVideoDataOutput` 和 `AVAssetWriter` 录 HDR 时需同时启用采集输出和压缩设置的元数据保留；Dolby Vision 自动插入依赖源帧元数据和写入器能力。依据：[Apple iPhone 17 Pro 规格](https://support.apple.com/en-us/125090)、[AVCaptureVideoDataOutput 动态 HDR 元数据](https://developer.apple.com/documentation/avfoundation/avcapturevideodataoutput/preservesdynamichdrmetadata)、[Apple Dolby Vision AVAssetWriter 指南](https://developer.apple.com/av-foundation/Incorporating-HDR-video-with-Dolby-Vision-into-your-apps.pdf)。iPhone 17 Pro 规格列出主摄 4K Dolby Vision 120fps 慢动作及电影模式最高 4K Dolby Vision 30fps；这是原生相机能力说明，不代表本应用成片已经验证为 Dolby Vision。
- XCTest 新增采集规格过滤与回放率分离用例，并扩展策略用例检查 24fps 回放、4K HDR 120fps 采集及不允许的 1080p HDR / 4K HDR 240fps。Xcode generic iOS `build-for-testing` 使用 `CODE_SIGNING_ALLOWED=NO` 成功，App 与测试 target 编译完成；新增测试本轮只编译，未执行。
- 真机 XCTest 已在 iPhone 17 Pro（iOS 27.0.1，设备 UDID `00008150-001934280220401C`）执行：`VideoWorkflowTests` 16 项通过、0 失败、0 跳过。覆盖慢动作采集规格与回放帧率分离、24fps 回放、HDR 4K/120 策略、电影规格配对选择及子模式状态切换。首轮发现一条旧断言未检查新增的 `captureFrameRate` 字段；已按新数据模型修正断言后重跑，全组通过。
- 这组 XCTest 在真机运行，但没有启动相机进行手动录制，也没有读取实际视频文件的 Dolby Vision Profile/动态元数据；因此不能据此认定 HDR 电影成片已经是 Dolby Vision。当前设备镜像提示 iPhone 正在使用，未完成慢动作弹窗的目视核对。性能帧率、丢帧、发热和真实录制稳定性也未测。后续需在 iPhone 17 Pro 上录制一段 4K HDR 电影短片，检查 `AVAssetTrack` 的格式描述及 Dolby Vision 元数据，再目视确认慢动作采集规格弹窗，并测试 4K/120 采集、24/30/60 回放、停止/取消和退出慢动作恢复。


## 2026-10-23 外接 ProRes RAW 启动元数据查询顺序

- 用户反馈：三星 T7 外接录制 ProRes RAW 时，点击录制直接退出。此次未取得该次闪退的设备崩溃堆栈，不能将后续检查结果写成对这次崩溃堆栈的确认。
- 代码检查发现明确违反平台前置条件的调用：启动 RAW 时，在 `setWhiteBalanceModeLocked` 之前读取 `recommendedMovieMetadata`。Apple 文档及当前 SDK 头文件明确说明 RAW 查询前必须锁定白平衡，否则会抛出 `NSInvalidArgumentException`；此类异常不由 Swift `do/catch` 捕获。依据：[Apple recommendedMovieMetadata](https://developer.apple.com/documentation/avfoundation/avcapturevideodataoutput/recommendedmoviemetadata(forvideocodectype:assetwriteroutputfiletype:))。
- 修复：获得外接 URL 后先锁定白平衡，等待完成回调，再复核会话运行状态、同一输入和目标编码能力；`RAWVideoWriterConfiguration.read` 先验证设备实际 `.locked`，随后读取推荐编码设置和影片元数据并创建 writer。设置无效时不进入元数据接口；失败时释放 URL 安全作用域并恢复白平衡。原外接存储资格、保留原始 RAW 帧与文件、取消令牌逻辑不变。
- 真机：iPhone 17 Pro，iOS 27.0.1（24A446），正常项目签名；定向 12 项通过，0 失败、0 跳过。`VideoEncodingPolicyTests` 10 项覆盖未锁定时 40 次请求全部阻止、推荐设置为 nil 时不查询元数据、推荐设置/元数据的顺序与保留、授权释放的幂等性、无效磁盘资格及既有编码策略。`VideoWhiteBalancePhysicalTests` 覆盖 HEVC 1080p30 白平衡开/关的两次实际临时录制、停止后恢复和一次立即取消，未保存系统相册。`ProResRAWPhysicalTests.testRAWMetadataAfterWhiteBalanceLockWithoutWritingFiles` 使用后置物理主摄的真实 12 位 Bayer 输入，RAW 与 RAW HQ 各 3 次锁定后查询系统元数据，无 Objective-C 异常；不请求外接 URL，不创建 RAW 影片。
- 性能与重复性：上述 RAW 元数据用例连续三轮通过（共 18 次 RAW/RAW HQ 元数据查询）。最后一轮持久保存了 6 个“锁定请求至完成回调并读完元数据”的样本，耗时为 93.0、267.0、133.0、131.9、133.3、134.8 ms，P50 133.1 ms、最大 267.0 ms。该指标只描述锁定和元数据读取，不是点击至首个编码帧延迟、视频帧率或 T7 吞吐；本轮没有测实际 RAW 编码内存、温度和长时间录制稳定性。
- 最终测试源已将等待方式改为异步 XCTest 等待，未新增 Swift 并发警告；最后一轮仍有既有 AppIntents 元数据提取提示和系统 `MDB_MAP_FULL` 日志，未据此认定为本次闪退原因。修复版已在已连接 iPhone 启动。
- 实盘限制：本轮没有对三星 T7 实际写入，因此 RAW/RAW HQ 的完整录制、成片解码、文件 App 删除和拔盘恢复仍未通过端到端验证，由用户接盘复测；不得将上述元数据查询通过等同于外接录制已完整通过。未向外接盘或系统相册写入诊断媒体。
- 结果：`/private/tmp/LumaCamera-RAWStartupRegression-20261023.xcresult`（12 项），`/private/tmp/LumaCamera-RAWStartupFinal-20261023.xcresult`（1 项），`/private/tmp/LumaCamera-RAWStartupMetrics-20261023.xcresult`（1 项及保留的 6 样本耗时附件）。


## 2026-10-23 电影模式开启速度与重复建图优化

- 官方依据：[Apple isCinematicVideoCaptureEnabled](https://developer.apple.com/documentation/avfoundation/avcapturedeviceinput/iscinematicvideocaptureenabled) 明确说明启用 Cinematic 会耗时重配渲染管线，应在会话启动前或运行中的 begin/commit 事务内设置。应用原路径在兼容镜头准备好后又同步一次相同规格，并在每次配置时无条件关闭再开启电影处理，真机计数证实每次进入建图 2 次。
- 改动：进入电影输入时将输入替换、自动控制初始化、最终格式与输出图合并为一次会话事务；异步准备成功后只收起面板及保存状态；同一输入、活动格式、色彩空间与帧间隔不变时，保留已启用的 Cinematic 和输出图。实际换规格、退出电影及移除旧输入前的 Cinematic 关闭仍执行。沿用现有局部淡出和最终路由帧标识，没有新增会话、预热第二路摄像头或改变系统自动微距规则。
- 设备与计时：iPhone 17 Pro / iOS 27.0.1（24A446），正常工程签名，无模拟器。计时起点为电影入口动作函数返回，终点为目标配置就绪且带新切换标识的预览 UIImage 发布；轮询间隔不超过 10 ms。不包含入口函数自身的同步执行时间和屏幕实际扫描输出，不等同于显示帧率或编码首帧延迟。基线附件沿用旧的 tap-to 标签，本节以实际测试代码的计时边界为准。
- 性能基线 2 样本：2.4466、1.8907 秒，平均 2.1686 秒；每次电影图重建均为 2 次。相同测法的第一轮优化 2 样本：0.9728、0.9539 秒。补充实际电影录制/规格切换后的两轮各 2 样本：0.9518、0.9213 秒，以及最终 0.9451、0.9311 秒；全部每次建图 1 次。最终两样本平均 0.9381 秒，相对该次基线约缩短 56.7%；样本少、仅一个设备，不能外推所有机型、温度或首次系统相机启动环境。实际管线启用到配置就绪的最终样本为 0.6559、0.6287 秒。
- 最终定向 27 项通过、0 失败、0 跳过：`VideoSpecificationTests.testSlowMotionAndCinematicRoutesOnDevice`、`VideoWorkflowTests` 16 项及 `VideoEncodingPolicyTests` 10 项。包含慢动作/电影各两次启停、电影每次开启后 3 秒稳定运行且无会话运行错误、3 次快速提交相同电影规格不增加建图次数、4K24→4K30→1080p30 实际规格切换、一次约 0.8 秒临时电影录制并读取实际视频轨道/时长，以及子模式快速互斥和停止/取消策略、已有 RAW 元数据前置检查。临时电影文件已删除，媒体未加入系统相册。测试只核对电影模式开启状态和实际短片轨道，不代表 Dolby Vision 元数据或长时发热/内存已通过本轮验证。
- 扩大回归另有失败，未写成全部通过：`VideoModeTransitionTests` 三项中两项通过、一项失败。普通 A 挡视频返回照片时，实际候选镜头列表缺少超广角，另一次 8× 往返恢复成 1×；同组普通手动往返阶段出现过 AVFoundation -12780 错误并随后恢复。为排除本次性能改动，用三处优化前的生产代码单独运行失败项，仍在同样的超广角候选断言与 8×→1× 断言失败，因此作为已有独立问题记录，尚未修复。对照后已完整恢复提速版，并重新完成上述最终 27 项回归。
- 测试日志仍有既有 `MDB_MAP_FULL` 和 AppIntents 无依赖提示；未据此解释本次切换耗时，也未作为内存峰值或应用性能指标。
- 结果包：`/private/tmp/LumaCamera-CinematicBaseline2-20261023.xcresult`（基线），`/private/tmp/LumaCamera-CinematicLatencyOptimized-20261023.xcresult`（17 项通过），`/private/tmp/LumaCamera-CinematicFinalRegression-20261023.xcresult`（13 通过、1 失败），`/private/tmp/LumaCamera-OrdinaryVideoControl-20261023.xcresult`（优化前代码同项失败对照），`/private/tmp/LumaCamera-CinematicReleaseCheck-20261023.xcresult`（最终 27 项通过）。各电影专项包含保留的首帧耗时/建图次数附件。


## 2026-10-23 慢动作焦段切换与物理路由保持

- 用户反馈慢动作切焦段卡顿。基线发现真正换物理镜头先提交输入，再配置高帧率输出；同镜头裁切也会清空取景 UIImage。修复将慢动作的输入替换、目标倍率、120/240 帧活动格式与输出图合并为单事务提交，同镜头裁切保留取景图；用户主动换焦段的既有局部过渡与失败超时仍保留。
- 补测 240 帧发现另一个实际故障：M→A 与 A 挡变焦的 `applyContinuousZoom` 强制选择普通虚拟多摄，导致慢动作状态关闭、`captureFrameRate` 变成 nil，设备帧间隔变为 1/30 秒。修复慢动作 A 挡沿用支持高帧率的物理路线，并使该入口的物理输入替换同样一次提交。普通 A 挡的自动微距/系统虚拟多摄策略不变。官方事务依据：[Apple beginConfiguration](https://developer.apple.com/documentation/avfoundation/avcapturesession/beginconfiguration())。
- 设备：iPhone 17 Pro / iOS 27.0.1（24A446），正常项目签名，无模拟器。基线与最终均在 HEVC SDR 1080p、30 帧回放下，A/M 各按 0.5→1→2→4→8→1 固定焦段序列测试；每次以按钮调用前为起点，等 selectedLens、ready、新路由帧标识及非空预览均满足才结束。指标为最终路由 UIImage 发布耗时，包含不超过 10 ms 的轮询，不代表屏幕扫描输出或实际编码帧率。
- 120 帧性能对照：基线 12 个切换样本中，8 次跨物理输入平均 0.3697 秒、P50 0.3059 秒、最大 0.6644 秒；4 次同镜头裁切平均 0.0456 秒、最大 0.0466 秒。最终同序列跨物理输入 8 次平均 0.2909 秒、P50 0.2961 秒、最大 0.3221 秒；同镜头裁切 4 次平均 0.0463 秒、最大 0.0535 秒。主要改善首次较长停顿；不能据此声称所有常规切换都快一半。
- 最终 240 帧另测 12 个样本：跨物理输入 8 次平均 0.2734 秒、P50 0.2732 秒，范围 0.2457–0.3009 秒；同镜头裁切 4 次平均 0.0385 秒，范围 0.0312–0.0452 秒。切换后核对活动设备 min/max frame duration 分别为 1/120 或 1/240 秒；这是设备实际配置读数，不保证在任意光照/负载下送达样本恒定达到该帧率。本轮没有做输入样本时间戳吞吐、长时温升或应用内存测量。
- 最终 28 项定向 XCTest 全通过、0 失败、0 跳过：新增 `SlowMotionLensTransitionPhysicalTests`、慢动作/电影联合真机专项、`VideoWorkflowTests` 16 项及 `VideoEncodingPolicyTests` 10 项。新增专项包含 120/240 帧 × A/M × 6 焦段（24 次）、A 挡重复点 1× 在 24/35mm 切换、双指变焦、M→A、快速连续点按与关闭/重启相机后恢复。最后录制约 0.6 秒真实慢动作临时短片，核对实际视频轨道、回放 nominalFrameRate 和延长的输出时长，完成后删除。没有向系统相册保存媒体或写入外接盘。
- 既有电影回归包括两轮开启/关闭、3 次相同配置不重建、4K24/4K30/1080p30 与真实临时录制；最终电影新预览两样本 0.9362、0.9571 秒，每次只建图一次。RAW 本轮只执行已有编码/元数据门控策略用例，不代表三星 T7 实盘写入完成。
- 本轮没有测慢动作 720p、P3、4K120/HDR 或前置镜头。跨物理摄像头仍需要传感器/输出图恢复时间，并非零停顿；普通视频返回照片的既有焦段/微距候选恢复问题仍按前一节待办，不以本次慢动作专项结项。日志仍有既有 MDB_MAP_FULL 与 AppIntents 无依赖提示，未据此推定性能或故障原因。
- 结果包：`/private/tmp/LumaCamera-SlowFocalBaseline-20261023.xcresult`（120 帧基线），`/private/tmp/LumaCamera-SlowFocalOptimized-20261023.xcresult`（首轮 17 项通过），`/private/tmp/LumaCamera-SlowFocal240-20261023.xcresult`（捕获 240 帧 M→A 退出慢动作的失败），`/private/tmp/LumaCamera-SlowFocalRouteFixed-20261023.xcresult`（路由修复后通过），`/private/tmp/LumaCamera-SlowFocalFinal-20261023.xcresult`（最终 28 项通过，保留各焦段耗时附件）。


## 2026-10-23 前置宽窄取景与子模块恢复

- **实测原因**：后置视频子模块切到前置时，旧兼容 ID 集合按朝向过滤后可变为空集合，按钮动作被拒绝。另复现系统 Center Stage 已启用，前置普通视频实际 `maxAvailableVideoZoomFactor = 1`，即使所选普通格式 `videoMaxZoomFactor = 143.5`，窄取景也被钳制到 1×；关闭该系统控制后，同格式实际范围恢复至 143.5×，窄取景为实际约 1.6×。照片深度输出下系统 Center Stage 未激活，因此不能仅凭照片正常推断视频正常。
- **实现**：会话初始化由应用接管系统 Center Stage 并关闭，照片 Smart Framing 保留。前置/手动视频子模块按真实设备重新查询兼容焦段，实际视频规格回报后再刷新；不再把旧后置集合直接过滤为空。前置变焦保留宽窄实际倍率，视频按钮启用状态与兼容判定一致，不改变位置、背景和动画。
- **前置电影**：本机超广角格式公布电影能力，Wide/TrueDepth 未公布；旧代码固定使用 TrueDepth，造成空兼容目录并残留电影启用文字状态。现按格式能力选取前置电影设备，测试核对已挂载输入确实支持且启用 Cinematic。电影专用变焦范围在本机为固定倍率，因此开启时只开放宽取景，窄取景被拒绝；退出电影后普通宽窄实际倍率恢复。此限制来自本机公开格式能力，不推广为所有设备的保证。
- **官方依据**：Apple [Center Stage 控制模式](https://developer.apple.com/documentation/avfoundation/avcapturedevice/centerstagecontrolmode-swift.type.property)、[Center Stage 激活限制](https://developer.apple.com/documentation/avfoundation/avcapturedevice/iscenterstageactive)、[电影格式支持](https://developer.apple.com/documentation/avfoundation/avcapturedevice/format/iscinematicvideocapturesupported)及[电影最大变焦倍率](https://developer.apple.com/documentation/avfoundation/avcapturedevice/format/videomaxzoomfactorforcinematicvideo)，并核对当前 Xcode SDK 头文件说明。系统人物居中会限制可用变焦范围是官方说明；实际限制到 1×及前置电影设备选择是本机观测。
- **真机功能和稳定性**：iPhone 17 Pro，iOS 27.0.1（24A446），正常项目签名。18 个不同的相关 XCTest 最终通过。专项序列覆盖照片普通/慢门/夜景/人像/连拍、视频普通/延时/慢动作/电影的启用与退出，以及前后切换、M 挡、30 次快速选择、切换中停止/重开、视频返回照片；共 76 次顺序选择请求（其中电影窄取景 2 次按能力拒绝），核对实际硬件倍率而非仅按钮状态。另覆盖 8 次前后切换与忙碌点击、自动构图开关、重复宽窄切换、镜像/手动曝光/取消、原生按钮触发及方向策略。
- **保存文件**：JPG/HEIF 普通与广角共 4 张，直接读取系统原始照片与最终文件 EXIF，分别为 31/20mm，最终方向为 1，竖幅大于 11MP；普通/广角 Live 各一组，实际静态文件 31/20mm，系统接受配对，停止与恢复后重新出帧。媒体均截获于测试内存或临时文件，没有写入系统相册。该检查不是在系统“照片”App 内人工查看。
- **性能采样**：最后专项序列从选择调用至目标倍率已确认、既有切镜过渡结束：照片 40 次均值 0.2927 秒、范围 0.0061–0.4097 秒；普通/延时/慢动作及恢复后视频 32 次均值 0.2809 秒、范围 0.1983–0.3226 秒。包含同值选择的无动作样本，不作为屏幕 FPS、纯传感器延迟或省电指标。最后后置电影回归 2 次进入到最终路由新预览发布约 0.964/0.961 秒，各建图 1 次，实际临时电影文件录制与解码通过。
- **测试衔接修正与结果包**：第一组合包 `/private/tmp/LumaCamera-FrontFramingVerified-20261023.xcresult` 中前置/按钮 17 项通过，后置电影用例失败；该用例从前置残留状态开始，翻转尚未就绪便切录像。补齐其测试前置条件等待后，专项前置与后置电影 2 项连续通过，结果 `/private/tmp/LumaCamera-FrontCinematicRegression-20261023.xcresult`，日志同名前缀 `.log`。方向用例也先通过前后往返清理上一用例的同方向手动取景覆盖，保留正式代码“同方向不覆盖用户手动选择”的规则。没有以测试等待修正宣称任意并发模式切换已通过。
- **范围**：未做全量测试、其他机型、外接盘或整机耗电温升测量；没有启动模拟器。前置电影本轮验证真实输入与取景限制，实际编码文件回归为后置电影，不宣称已录制前置电影样片。


## 2026-10-23 前后切镜方向耗时与收尾优化

- **现象与结论**：iPhone 17 Pro / iOS 27.0.1（24A446），照片与 HEVC SDR 1080p30 的 A/M 四组均复现前置返回后置稍慢。Debug 分阶段计时显示耗时主要集中在最外层 `AVCaptureSession.commitConfiguration()`，提交后的连接方向/镜像设置约 0.1–0.2ms，不是主要瓶颈。此为本机观测，不是 Apple 保证的固有延迟，也未推断所有后置设备都一定更慢。没有改动照片输出、RAW/景深管线或缓存策略来换取切镜指标。
- **改动**：只把 `flipCamera` 的最终新帧收尾淡出从 0.18 秒缩短到 0.10 秒，保留原切镜路径、失败超时释放、减弱动态效果及其他入口的动画。新增 Debug 有界阶段计时与 `CameraFacingLatencyPhysicalTests`，没有正式包计时开销。会话原子配置仍依据 Apple [beginConfiguration](https://developer.apple.com/documentation/avfoundation/avcapturesession/beginconfiguration%28%29) 的要求使用最外层提交；没有添加多摄预热会话或改变系统微距策略。
- **方法和样本**：每轮顺序切换 24 次：照片/视频 A 挡各 8 次（每方向 4），M 挡各 4 次（每方向 2）。等待目标朝向 `ready`、非空预览及不同于上次的最终路由 `userSwitchFrameID`，以约 5ms 轮询记为“新帧确认”；继续等待 `focalTransitionImage == nil` 记为“收尾结束”。两者均是应用发布/状态观察耗时，包含主队列和方向取景同步，不是屏幕扫描时间或真实 FPS。

| 规格/模式 | 每方向样本 | 前置新帧：修改前→后（秒） | 后置新帧：修改前→后（秒） | 后置收尾结束：修改前→后（秒） |
| --- | ---: | ---: | ---: | ---: |
| 照片 JPG A | 4 | 0.607→0.647 | 0.875→0.817 | 1.083→0.944 |
| 照片 JPG M | 2 | 0.506→0.511 | 0.846→0.644 | 1.056→0.776 |
| 视频 SDR A | 4 | 0.397→0.479 | 0.727→0.733 | 0.931→0.857 |
| 视频 SDR M | 2 | 0.340→0.370 | 0.617→0.658 | 0.820→0.783 |

- 表中“前→后”均表示修改前与修改后；不是镜头方向。12 次返回后置的新帧确认至过渡清除均值从 0.2063 秒降为 0.1263 秒，约少 80ms。新帧时刻受设备负载、场景和采集管线波动影响，本轮照片 M 的首帧改善不能归因于淡出参数；视频首帧没有稳定改善，因此没有宣称底层采集管线已提速或两方向已等速。另一轮未改正式逻辑的分阶段探测也复现差异。
- **稳定性与文件检查**：最终相关 6 项真机 XCTest 通过、0 失败。覆盖双向 24 次切换、8 次方向切换伴随 80 次忙碌点按、M 挡曝光恢复、切镜中停止/重开、各子模块前置宽窄与返回恢复；JPG/HEIF 普通/广角四个真实文件保持 31/20mm、方向 1，Live 普通/广角系统配对及停止恢复正常。诊断媒体不加入系统相册，没有访问外接盘或启动模拟器。
- **结果**：基线 `/private/tmp/LumaCamera-FacingLatencyBaseline-20261023.xcresult`；细分探测 `/private/tmp/LumaCamera-FacingCommitProbe-20261023.xcresult`；最终 6 项 `/private/tmp/LumaCamera-FacingLatencyOptimized-20261023.xcresult`。日志为各结果包同名前缀 `.log`。只验证当前机型与相关功能，未做全量回归、耗电或温升测量；后置会话准备较慢的差异仍存在。


## 2026-10-23 前置自动构图按钮状态刷新

- **用户场景**：照片 A 挡、HEIF、HDR/Live 关闭、未启用子模块，前置自动构图按钮灰色不可点。干净测试配置及复制用户已保存拍摄设置的隔离夹具中，修改前未稳定复现持续置灰：本机实际前置为 Ultra Wide，4032×4032 格式支持 Smart Framing，4 个构图候选，真实硬件开关可启停。因此没有把“偶发状态刷新”写成已经捕获的唯一根因。
- **修正的状态缺口**：旧实现只在若干配置点读取能力，未观察系统随后更新的 `activeFormat` 与 `supportedFramings`，主队列状态回报也没有过期保护。现监听这两项公开能力、在切镜事务提交后重读、拒绝旧设备回调及过期状态，且候选不变不重新设置。按钮启用条件与动作入口对齐，保留图标、位置和尺寸。依据 Apple [Smart Framing 指南](https://developer.apple.com/documentation/avfoundation/adopting-smart-framing-in-your-camera-app) 及当前 SDK 对 `supportedFramings` 可观察、随格式变化的说明；未为不可用规格伪造“支持”。
- **最终真机结果**：iPhone 17 Pro / iOS 27.0.1（24A446），4 项通过、0 失败。覆盖普通 JPG/HEIF、前置宽窄往返、Live 开关、普通视频返回照片、Smart Framing 启停、各子模块前置切换及退出恢复。使用用户设置的隔离副本启动后，实际 A 挡 HEIF 为 4032×4032 Smart Framing 格式，入口几何存在，开关可启用；临时 UIWindow 明确使用 active 场景以免测试夹具的 inactive 生命周期停止相机。原用户设置没有被此副本改写。
- **性能与稳定性**：8 次连续交替启停，从调用动作至目标监视状态、新预览及原过渡结束，平均 0.2986 秒，范围 0.2452–0.3313 秒；这是处理入口后的应用状态观测，包含 20ms 轮询，不能当作真实触屏延迟或屏幕 FPS。原有前置子模块压力序列包含 76 次顺序选择、30 次快速请求及切镜中停止/恢复，均通过；手动选择宽窄会按既有规则停止自动构图。未测试整机耗电/发热或其他机型。
- **原场景人工确认**：测试后用正常参数启动修复版，用户已在同一 iPhone 上确认自动构图“可以正常开关”。这项确认覆盖原先的实际按钮置灰问题，未将单纯 ViewModel 开关测试冒充触屏验收；未额外验证人物进出画面时构图推荐的艺术效果。
- **附件与结果**：`/private/tmp/LumaCamera-FrontSmartRefresh-20261023.xcresult`，日志同名前缀 `.log`；用户设置隔离夹具的 HEIF 页面快照位于 `/private/tmp/LumaCamera-FrontSmartSavedBaseline2-20261023.xcresult`。测试没有拍摄或向系统相册保存诊断照片，没有访问外接盘或启动模拟器。


## 2026-10-23 照片视频交叉挡位切换优化

- **问题与改动**：照片 M 挡进入视频先完成一次 A/M 路线切换，再分别配置媒体输出，产生多次中间图提交。现用一个最外层会话事务包住既有配置，提交后补齐连接、最终能力与新帧标记，沿用旧帧轻微模糊与局部短淡出。另在基线明确复现 3 次照片 A→视频 M→照片错误留在 M 挡，现总是恢复原照片挡位。依据 Apple beginConfiguration 文档和 SDK 对嵌套配置的说明；未修改系统微距策略和控件布局。
- **设备与计时边界**：iPhone 17 Pro / iOS 27.0.1（24A446），正常项目签名，无模拟器。JPG、HDR/Live 关闭、后置 1×、HEVC SDR 1080p30；照片 A/M × 视频 A/M，每组 3 次往返，基线与优化后各 24 次。起点为调用模式切换前，配置时间为相机队列此前任务完成，新帧时间为配置后处理预览时间戳更新，过渡结束还需旧帧覆盖清除；10ms 轮询。它们是应用状态/UIImage 发布指标，不等同屏幕实际呈现、采样 FPS、耗电或内存测量。

| 原照片挡位 / 视频挡位 | 切视频新帧均值：修改前→后（秒） | 返照片新帧均值：修改前→后（秒） |
| --- | ---: | ---: |
| A / A | 0.716→0.503 | 0.510→0.593 |
| A / M | 0.600→0.549 | 0.364→0.499 |
| M / A | 2.082→0.461 | 1.348→0.539 |
| M / M | 2.322→0.476 | 0.339→0.404 |

- **总体结果与限制**：每方向 12 样本，切视频配置均值 1.382→0.441 秒、新帧 1.430→0.497 秒、覆盖清除 1.564→0.642 秒，优化后新帧最大 0.562 秒；返照片配置均值 0.599→0.448 秒、新帧 0.640→0.509 秒、覆盖清除 0.698→0.651 秒，优化后新帧最大 0.804 秒。主要减少照片 M 进入视频的长停顿；不是每组都加快，尤其原照片 A / 视频 M 的基线返回状态本身错误，不能视作相同正确终态的性能对照。样本量有限且只有一台设备，未据此承诺零卡顿或所有规格相同速度。
- **最终相关 5 项真机 XCTest 通过、0 失败、0 跳过**：交叉挡位时延与恢复专项（24 次）；Live/HDR/手动曝光往返（各录制约 0.6 秒真实临时视频，核对 1920×1080 轨道及照片恢复的 ISO 200、0.5 秒快门）；快速切换与停止恢复（4 轮共 40 次媒体切换、20 次 A/M 请求，2 次停止重开，检查预览持续更新）；前置自动构图普通路线；前置子模块宽窄回归（包括电影/慢动作退出恢复与重复请求）。无媒体保存到系统相册，未使用外接盘。基线专项有 3 条挡位恢复断言失败，未计为通过。
- **剩余范围**：本轮没有测所有分辨率/编码/Log、RAW 外接录制、长时温升或耗电；普通视频返回照片的既有 8×→1× 与超广角候选缺失仍是之前记录的独立待办，未以本次挡位恢复测试冒充修复。日志仍出现既有 MDB_MAP_FULL 及 night 图标 moon.slash 不存在提示，未作为本次耗时原因，也未在本次变更中改动相关界面。
- **结果包**：`/private/tmp/LumaCamera-CaptureKindBaseline-20261023.xcresult`（基线含挡位失败）；`/private/tmp/LumaCamera-CaptureKindBatched-20261023.xcresult`（2 项通过，含性能附件）；`/private/tmp/LumaCamera-CaptureKindRecovery-20261023.xcresult`（其余 3 项通过）。各日志同名前缀 `.log`。


## 2026-10-23 视频挡位独立恢复

- 用户复现视频 M→照片→视频变成 A。上一轮只修正返回照片的挡位，进入视频仍明确设为 A，未覆盖视频自身恢复。本轮增加视频独立挡位并保存到可选存档字段，旧存档兼容；布局和既有局部过渡不变。
- 首轮回归进一步发现同挡位 M→M 重新应用更早的 savedManualSettings，导致当前照片 ISO 200 / 0.5 秒参数被覆盖；修正为仅 A→M 使用该快照。首轮结果 `/private/tmp/LumaCamera-IndependentModes-20261023.xcresult` 为 7 项通过、1 项失败（5 条手动参数断言），不计为全通过。
- **最终 8 项通过、0 失败、0 跳过**：iPhone 17 Pro / iOS 27.0.1（24A446），正常签名，无模拟器。交叉挡位专项扩展为照片 A/M × 视频 A/M ×3 轮，每轮额外重入视频并返回照片，总共 48 次切换，分别核对两边挡位；快速专项 40 次媒体切换、20 次挡位请求及 2 次停止恢复通过。保存设置 5 项检查包含停在照片时保存视频 M、重新创建模型后恢复、旧视频存档迁移、关闭保存时默认 A 及既有规格状态。Live/HDR/手动专项实际录制内部临时视频，核对 1080p 输出、Live/HDR 状态和返回照片的真实 ISO 200 / 0.5 秒快门，媒体未加入系统相册。
- **性能**：同一专项 48 次中，每方向 24 样本，切视频最终配置后新预览观测均值 0.498 秒、范围 0.365–0.734 秒；返回照片均值 0.480 秒、范围 0.372–0.722 秒；过渡清除均值分别 0.590、0.588 秒。起点为动作调用前，终点为最终配置后处理预览时间戳更新（10ms 轮询）；不是触屏到屏幕实际显示延迟，也不是 FPS。未测所有编码/分辨率、长时发热/耗电；不改变此前记录的外接盘及普通视频焦段恢复待办。
- 最终结果：`/private/tmp/LumaCamera-IndependentModesFinal-20261023.xcresult`，日志同名前缀 `.log`。


## 2026-10-23 M 挡切换前置的准备提示

- **代码路径与观测**：页面仅在 `camera.preview` 与局部切镜旧帧均为空时显示“正在准备相机”。正常 `selectLensOnQueue` 提交后，以及 M/A 路线更新后，旧代码仍发布 `preview = nil`；该主队列任务还可能晚于新帧发布。iPhone 17 Pro / iOS 27.0.1（24A446）基线 M 挡 HEIF、ISO 400、快门 1/125、1/15、0.5 秒，每种前后往返 4 次，总共 12 次出现 18 次 nil 预览发布，专项断言失败。这个计数确认不必要的清空路径，不能等同于人眼看到准备文字 18 次；未声称捕获了用户偶发提示出现的每个条件。
- **修复**：以上正常重配完成后保留最近 UIImage，新路由仍需通过原有时间门限与切镜帧 ID 才结束既有旧帧轻微模糊/淡出；首次启动、恢复/错误状态不屏蔽，不改变系统自动微距，不新增全页动画或等待时长。
- **最终相关 5 项真机通过、0 失败、0 跳过**：新增 12 次 M 挡切镜，nil 发布为 0，每次核对目标朝向及最终新路由帧 ID；既有照片/视频 A/M 双向 24 次；照片/视频独立挡位 48 次；快速媒体切换 40 次及 2 次停止恢复；手动前后切换 6 次核对真实 ISO 400、1/125 秒及切镜中取消/停止恢复。正常项目签名，无模拟器，无诊断媒体保存到系统相册。
- **性能与限制**：12 次 M 挡专项从 flipCamera 调用至新路由标记出现且局部过渡结束，基线平均 0.608 秒、范围 0.431–1.001 秒；最终平均 0.944 秒、范围 0.659–1.444 秒。包含 10ms 轮询、慢快门实际管线/负载变化，样本少且不是固定光线下多轮交错对照，因此本次只结项“清空预览导致的提示空档”，不宣称提速。最终另外 24 次照片/视频 A/M 双向切镜，新帧应用观测平均 0.566 秒、范围 0.346–0.841 秒（5ms 轮询）；非屏幕 FPS、非实际触屏延迟。没有测长时耗电、发热、应用内存、全部规格或外接盘；仍需用户确认原偶发场景观感。
- **结果**：`/private/tmp/LumaCamera-FacingPreviewBaseline-20261023.xcresult`（1 项失败，清空计数附件见日志）；`/private/tmp/LumaCamera-FacingPreviewFixed-20261023.xcresult`（最终 5 项通过）；日志同名前缀 `.log`。保留既有 prepare/recovery 行为，不将保留旧帧冒充相机实时出帧。


## 2026-10-23 慢动作规格弹窗按钮尺寸与帧率顺序

- **改动**：慢动作采集规格弹窗中，分辨率和帧率按钮统一固定为 70×32 pt；帧率行保留尾部空白，不再拉伸按钮填满布局。普通视频帧率行仍沿用原有宽度行为。
- **验证设备**：iPhone 17 Pro / iOS 27.0.1（24A446），通过已连接真机运行 Xcode XCTest；未启动模拟器，未使用屏幕镜像，未启动相机或拍摄媒体。
- **初次尺寸验证**：慢动作规格策略用例 1 项通过、0 失败；视频弹窗布局用例 1 项通过、0 失败。后者覆盖 20 个画幅/控件方向布局、320 pt 与设备窗口宽度下的工具栏弹窗、60 次快速弹窗切换，并新增慢动作规格弹窗截图。该轮截图显示 1080p 与 240/120 fps 按钮尺寸一致，且完整位于面板内；帧率左右顺序随后按用户要求调整。截图：`/private/tmp/LumaCamera-SlowMotionPicker-attachments/3BF83051-4178-475B-9BAD-339C2C86A943.png`。
- **计时边界与限制**：布局用例耗时 10.810 秒，包含布局等待和其他弹窗回归，不代表屏幕帧率或相机性能。测试宿主在真机窗口中渲染弹窗并保存 XCTest 截图；未验证真实相机预览下的手动点按、慢动作录制及输出文件。
- **结果包**：`/tmp/LumaCamera-SlowMotionPicker-20261023/Logs/Test/Test-LumaCamera-2026.10.23_11-37-17-+0800.xcresult`；慢动作规格策略结果位于同目录前一项测试包。

### 帧率显示顺序调整

- **改动**：慢动作采集帧率在弹窗内改为按数值升序显示，120 fps 在左、240 fps 在右。能力策略仍优先选择设备支持的最高采集帧率，故本次没有改变默认选择；截图中 240 fps 仍保持选中，按钮尺寸与选中样式不变。
- **真机回归**：iPhone 17 Pro / iOS 27.0.1（24A446），定向运行 `VideoOverlayLayoutTests.testHUDAndHistogramStayInsideEveryVideoRatioAndFrameRatePopupFits`，1 项通过、0 失败，耗时 10.714 秒。覆盖 20 个比例/方向布局、两种宽度的工具栏弹窗、60 次快速弹窗切换及慢动作规格弹窗截图。截图确认 120 fps 在左、240 fps 在右，选中状态仍对应 240 fps。没有启动模拟器、打开屏幕镜像或拍摄/保存媒体。
- **验证边界**：此回归检查真机 SwiftUI 弹窗渲染和按钮顺序，不启动真实相机采集，因此不代表 120/240 fps 录制能力复测。结果包：`/tmp/LumaCamera-SlowMotionOrder-20261023/Logs/Test/Test-LumaCamera-2026.10.23_11-42-23-+0800.xcresult`；核对截图：`/private/tmp/LumaCamera-SlowMotionOrder-attachments/D19DC9E9-593C-4F54-B9DF-3F66A463DD7E.png`。

- **再次调整帧率顺序**：按用户最新要求改为 240 fps 在左、120 fps 在右；只改变弹窗显示顺序，慢动作能力筛选、默认采集率和实际采集配置不变。iPhone 17 Pro / iOS 27.0.1（24A446）定向运行 `VideoOverlayLayoutTests.testHUDAndHistogramStayInsideEveryVideoRatioAndFrameRatePopupFits`，1 项通过、0 失败，耗时 10.751 秒；覆盖 20 组画幅/方向布局、两种窗口宽度的顶部弹窗、慢动作采集规格弹窗和 60 次快速弹窗切换。测试附件包含慢动作弹窗截图；本轮未运行录像采集。性能计时含界面等待和弹窗切换，不代表帧率或实际触屏延迟。结果包：`/private/tmp/LumaCamera-SlowMotionReorder-20261023.xcresult`。


## 2026-10-23 前置照片横幅构图

> 以下早期“内容正向”结论已被用户反馈和后续竖持对照推翻；当前结果以本节之后的“前置预览侧转与画幅变形复核”记录为准。早期 23 项通过不代表本次视觉缺陷已排除。

- **前一轮验收不足**：`LumaCamera-FrontAspect-MaskFinal2.xcresult` 的两项测试仅核对宽高、像素数和开关状态；虽通过，但没有核对内容上下方向，不能视为视觉验收。用户反馈后在竖持 iPhone 的实际场景重新采集临时对照图，确认旧横幅预览倒置、旧竖幅成片内容侧转；只按宽高选择旋转方向的策略错误。
- **最终修复**：保留系统动态 3:4／4:3 取景，移除按宽高“转成横图”的策略。新前置照片解码后与未镜像预览缓冲分别使用固定的传感器方向校正，蒙版同步；快门使用系统回调确认的画幅。相册按钮照片内容取消额外控件旋转。新方向像素测试还确认处理后的 JPG／HEIF 若继承旧 EXIF 6 会和 UIImage 预览方向不同，故非 RAW 编码统一规范 EXIF/TIFF 为 1，原始 RAW 字节保持不变。
- **官方 API 与观测边界**：照片设备使用 Apple `AVCaptureDevice.setDynamicAspectRatio`；Apple 文档将 `dynamicDimensions` 说明为当前动态画幅的视频缓冲输出尺寸，并未保证照片输出文件的像素方向或尺寸，应用仍需处理实际样本。参见 [动态构图指南](https://developer.apple.com/documentation/avfoundation/adopting-smart-framing-in-your-camera-app)、[`dynamicAspectRatio`](https://developer.apple.com/documentation/avfoundation/avcapturedevice/dynamicaspectratio) 与 [`dynamicDimensions`](https://developer.apple.com/documentation/avfoundation/avcapturedevice/dynamicdimensions)。
- **最终真机结果**：iPhone 17 Pro / iOS 27.0.1（24A446），正常签名，23 项相关 XCTest 通过、0 失败。包含两项真实相机画幅／前置宽窄／照片视频隔离测试、两项带上下色标的图像方向测试、四方向相册缩略图渲染检查、既有方向变换和文件元数据回归。真实照片竖幅为 3000×4000，横幅为 4000×3000，均为当前标准档约 12MP；对照临时图已人工核对预览与成片内容均正向，横幅呈现系统切换后的横向视野。用户明确同意采集临时小图；媒体只在内存和临时 XCTest 结果附件中，没有写入系统相册。未启动模拟器或屏幕镜像。
- **性能与重复操作**：实际相机交替切换 8 次，动作调用至目标画幅状态发布的中位数 0.0676 秒，范围 0.0322–0.0786 秒，含 10ms 轮询；全部保持就绪且预览继续出帧。相册按钮在 0°／90°／−90°／180° 下重复三轮共 12 次，红上蓝下色标均保持原方向；单次快照绘制约 0.0260–0.0461 秒。前者不是实际触屏延迟，后者不是屏幕 FPS；均不代表耗电或温升。既有前置宽窄和照片/视频往返路径通过。本轮未实拍 HEIF Pro、HDR、Live、RAW 或验证人像蒙版真实主体效果，未覆盖其他机型；RAW 与 1:1 按产品规则禁用画幅开关。
- **结果包**：方向诊断与临时图 `/private/tmp/LumaCamera-FrontAspect-VisualDiagnosis.xcresult`；修正后视觉对照 `/private/tmp/LumaCamera-FrontDirectionCorrected.xcresult`（该轮编码方向测试失败，不计全通过）；最终 23 项 `/private/tmp/LumaCamera-FrontDirectionFinal.xcresult`。最终版已通过正常启动命令在连接的 iPhone 打开。


## 2026-10-23 前置预览侧转与画幅变形复核

> 本节为中间结果；用户后续仍复现挤压和视野差异，单凭方向与宽高不能认定几何一致。最终结论见“前置预览内参比例修正与详情删除最终回归”。

- **问题与纠正**：用户反馈前置预览侧转 90°、横竖构图往返时人物变形。早期检查没有把手机实际姿态与控件方向一起核对，固定向左/向右旋转的结论错误。按用户确认的竖持场景复现，原始前置文件内容已朝上，光屿额外旋转后侧转。此前“视觉通过”结论撤回。
- **官方依据**：Apple `setDynamicAspectRatio` 完成回调对应首个应用设置的缓冲，但设备时钟需要转换后才能和采集样本时间比较；本次不直接比较两个时钟的时间戳。iOS 27 [`videoRotationAngleRelative(toDeviceOrientation:)`](https://developer.apple.com/documentation/avfoundation/avcapturedevice/rotationcoordinator/videorotationanglerelative%28todeviceorientation%3A%29) 可查询传感器相对指定设备方向的静态角度，本机相对 portrait 返回 0°。动态画幅与输出连接下缓冲宽高相反是本机实测，不能推广为平台保证。
- **实现**：新前置照片/预览取消额外固定四分之一圈旋转；照片按当前零旋转连接的实际缓冲方向映射动态画幅。预览丢弃宽高与目标画幅不匹配的交界帧，首张匹配图像和界面横竖标志同时发布；不对宽高做隐式动画，改用内容短淡化。“减弱动态效果”为更短淡化；视频保持原动态画幅选择，旧相机路线不变。EXIF/TIFF 归一和缩略图不随按钮旋转的修复保留。
- **设备与范围**：iPhone 17 Pro，iOS 27.0.1（24A446），正常项目签名，无模拟器、无屏幕镜像。相关测试共 6 个独立用例分批通过：画幅 A/JPG、M/HEIF+流畅预览、前置宽窄与照片/视频隔离、两个像素及编码方向测试、相册缩略图四方向测试。最后生产代码的照片/视频隔离与 M/HEIF 竖持复查 2 项通过，0 失败。
- **实际内容核对**：最后竖持轮次记录 `UIDevice.orientation=portrait`、官方相对 portrait 角度 0°。两张真实界面附件与最终 HEIF 预览均显示人物朝上，脸部/眼镜保持相同比例；横幅实际文件为 4000×3000、竖幅 3000×4000，约 12MP。临时原始文件、预览、最终图像均只在内存或 XCTest 附件中，不写系统相册。照片资源 EXIF 解码及方向像素测试通过，不只修改详情页显示。
- **性能与稳定性**：A/JPG 与 M/HEIF 各交替 8 次，共 16 次，并分别快速发送 12 次请求后回退，共 24 次快速请求；轮询中始终断言预览帧横竖与已发布界面构图一致。快速操作后持续出帧，无黑屏/崩溃/卡在错误画幅。最终竖持 M/HEIF 8 次从模型调用到匹配帧发布为 0.0275–0.0770 秒，中位数 0.0695 秒，包含 10ms 轮询；该轮快速请求恢复期间采到 10 次应用预览发布，最大间隔 0.1099 秒。前一轮 A/JPG 为 0.0608–0.1137 秒、中位数 0.0696 秒，恢复 12 次发布、最大间隔 0.1142 秒。不是触屏端到端延迟或显示器 FPS，不代表温升、耗电或应用内存测量。
- **限制**：未对连续切换的每个屏幕扫描帧做高速录像测量；以上含过渡期间轮询断言及稳定图像目视核对，不能声称排除所有瞬态视觉问题。未覆盖其他机型/系统、HEIF Pro/HDR/Live、人像真实蒙版边缘和非标准比例逐项实拍。横持成片的完整方向矩阵不作为本轮竖持构图的已验证结论。
- **结果包**：`/private/tmp/LumaCamera-FrontNativeFrameSync.xcresult`（6 项）；`/private/tmp/LumaCamera-FrontAspectRapidFinal.xcresult`（5 项，加入快速请求/帧框一致性断言）；`/private/tmp/LumaCamera-FrontUprightAcceptance.xcresult`（最终生产代码 2 项，竖持内容附件）。


## 2026-10-23 详情删除后旧照片停留

- 确认两处逻辑缺陷：删除成功后的下一张照片仍经 2400px 预载，慢请求时旧详情一直保留；无预加载的视频分支未释放 `PhotoDeletionNavigation` 令牌，随后删除成功也无法开启下一次导航。
- 修复：删除成功后的照片/视频立即提交目标页并释放事务；普通滑动仍预载。下一静态图尚未到达时显示媒体加载圈，不锁返回及详情页操作；图片到达仅淡入画布。删除失败或用户拒绝沿用原页，外部删除/本地完成的过期回调仍校验来源，避免多跳一张。
- iPhone 17 Pro / iOS 27.0.1（24A446）上，图库/分页/预载/删除竞态 36 个逻辑用例通过（`LumaCamera-FrontClockAndGalleryRegression.xcresult` 中前置画幅用例失败，不能将整个结果包写成通过）；涵盖拒绝保留、批量取消、重复回调、旧加载取消、外部删除与分页边界。独立真机托管 SwiftUI 窗口的普通翻页渲染用例通过，红/蓝画面交替且顶部底部控件位置保持，结果 `LumaCamera-FrontPhysicalPose-GalleryRender.xcresult`，不是屏幕镜像。
- 重复/性能：混合照片与视频的 100 次删除导航事务与过期完成通知检查通过，纯逻辑耗时约 0.000163 秒；不包含 PhotoKit 系统确认、网络下载和屏幕呈现延迟，不可视为真实删除速度。测试服务模拟删除，未删除用户系统相册媒体；真实系统确认与用户原始卡住步骤尚未人工端到端核对。


## 2026-10-23 视频详情默认静音

- `SystemVideoView` 的初始 `volume` 从 1 改为 0，`lastAudibleVolume` 保持 1；播放器创建时应用 0，进入详情即为静音，扬声器按钮可恢复到 100%。
- 每次新建视频详情都从静音开始；旋转、详情弹窗和页内播放不会重置用户当次调整。
- iPhone 17 Pro / iOS 27.0.1 构建、安装、启动成功。构建仍有 `CameraRuler.swift` 既有未使用变量警告，与本改动无关；未新增自动化测试，未取得运行截图。


## 2026-10-23 子模块弹窗去除状态说明

- 照片/视频拍摄模式弹窗中，选项标题下方的 `ShootingModeStatusLabel` 已移除；慢门、夜景、人像、连拍、智拍、延时、慢动作、电影不再显示“选择效果预设/设置慢门参数/三帧曝光合成”等状态文案。
- `ShootingModePanelLayout.optionHeight` 由 111 点收紧为 74 点（54 图标 + 7 间距 + 13 名称），弹窗不再为三行说明预留空白。
- 保留图标、名称、选中/禁用样式、无障碍标签和提示；仅移除视觉说明文字。
- iPhone 17 Pro / iOS 27.0.1 构建、安装、启动成功；`PopupAppearanceAndOrientationTests.testSubmodePopupUsesCompactOptionHeightWithoutStatusText` 通过。未取得弹窗运行截图，未新增其他 UI 自动化。

## 2026-10-23 慢门第一阶段：范围与支持修正

- `SlowShutterPreset.shutterRange(limitedTo:)` / `isoRange(limitedTo:)` 改为可选返回值，无有效交集时不再回退到完整硬件范围；新增 `supports(hardwareShutter:hardwareISO:)`。
- 预设按钮在相机就绪后按当前镜头范围禁用不支持项，并显示“当前镜头不支持”的无障碍值；已选预设因换镜头失效时由 `didChangeLensDevice` 清空。相机未就绪时仍允许预选，首个真实路由返回后再校验。
- 摇拍追焦范围由 1/60–1/15s 调整为 1/125–1/15s，建议值仍为 1/30s。
- 修复慢门开启后镜头按钮被每镜头能力表拦截：慢门改为参数型判断，当前朝向的镜头均可切换；切换完成后由 `didChangeLensDevice` 重新校验预设范围，不支持时清空预设。
- A 挡行为未改变，仍只设置最长曝光；在慢门模式的无障碍提示中说明“实际快门由系统决定，需要严格范围请切到 M 挡”。未新增可见说明文字。
- 测试：`SlowShutterPresetTests` 在 iPhone 17 Pro 上 6 项通过、2 项跳过（跳过项使用新建的未启动相机模型）；使用 App 实时相机会话的 `testPresetSlotsAlignWithFocalSlotsAndSurviveRapidToggleOnDevice` 通过，覆盖预设槽位与 20 次快速开关；新增 `testSlowShutterAllowsSwitchingRearLenses` 通过，覆盖慢门开启时后置镜头往返切换且预设保持。本轮未拍样张，未验证实际成片，也未实现多帧光轨/流水/星轨。
- iPhone 17 Pro / iOS 27.0.1 构建、安装、启动成功；无新增 Swift 编译警告。测试日志仍出现既有 `MDB_MAP_FULL` 系统日志，未表现为测试失败或应用崩溃。

## 2026-10-23 慢门第二阶段：光轨与流水多帧

- 新增 `SlowShutterSequenceSpec`：光轨 10 帧/10 秒/亮部叠加，流水 8 帧/8 秒/多帧平均；星轨仍为单帧。
- 新增 `SlowShutterComposer`：逐帧解码全分辨率资源，Lighten / 加权 Average 增量合成，每步渲染以限制内存；合成器测试 3 项通过。
- `CameraViewModel` 新增序列状态、A 挡测光锁定、1 秒目标 ISO 换算、进度、提前结束与恢复；`CameraEngine` 新增 `onSlowShutterFrame`，序列帧不进入普通相册回调。
- 序列固定 12MP JPG/HEIF，排除 RAW、Live、HDR、TIFF、48MP、人像、夜景、连拍；序列中禁用镜头和 A/M 切换，快门显示已完成/总帧数。
- 验证边界：`SlowShutterSequenceTests` 3 项通过；真机 10 秒/8 秒序列实拍、最终文件尺寸/EXIF、连续 10 帧内存/发热、取消/后台和照片保存后相册显示尚未执行。不能把合成器单测写成完整多帧成片验证。
- 第二阶段版本已构建、安装并启动成功；构建无新增 Swift 编译警告。


## 2026-10-23 慢门合成移出主线程

- `finishSlowShutterSequence` 先恢复相机曝光/A-M 状态，再通过 `slowShutterCompositionQueue` 在后台执行解码、Lighten/Average 合成和最终 `PhotoEncoder` 编码；主线程只更新 `slowShutterComposing`、取消令牌和保存结果。
- 合成期间快门显示加载圈并禁用；`slowShutterComposing` 阻止重复开始。离开相机或关闭慢门会使合成令牌失效，后台结果不再保存。
- `SlowShutterComposer` 测试 3 项通过；构建成功且无新增 Swift 编译警告。真机 10 秒/8 秒完整序列、合成耗时、内存峰值和最终文件仍未实测。
- 后台合成使用局部 `CIContext`，不跨线程共享主线程上下文。

## 2026-10-23 慢门序列卡住修复

- 复现路径：A 挡主摄、降低光照后启动光轨/流水，快门和相册持续转圈。静态检查确认序列启动时调用 `camera.setManualMode(true)` 会触发完整 A→M 路线重配，同时 A 挡慢门预览辅助可能覆盖自定义每帧曝光。
- 修复：序列启动不再切换 `camera.manualMode`，直接使用锁定后的 ISO/快门/白平衡/对焦应用自定义曝光；启动前关闭 `setSlowShutterPreviewOptimization` 与 A 挡自动最长曝光限制，结束后恢复。
- 每帧增加 12 秒看门狗；无帧回调时失败并恢复相机，避免永久忙碌。快门忙碌加载圈不再覆盖 `slowShutterSequenceProgress`，合成阶段使用独立加载圈。
- 构建、安装、启动成功。该修复尚未完成真机 10 秒/8 秒序列复测；不能写成卡住问题已完全解决。

## 2026-10-23 慢门合成图详情为空修复

- 根因：`SlowShutterComposer` 每步 `createCGImage` 后重新包成 `CIImage`，ImageIO 的 EXIF/TIFF 属性丢失；最终 `PhotoEncoder` 只能写入位置/署名，详情页的相机、镜头、ISO、快门等行因此为空。
- 根因二：最终合成使用新的空 `PhotoCaptureDiagnostics`，只添加两行合成说明，首帧的 `parameters`、镜头和滤镜记录未带入。
- 修复：合成循环保存首帧 `CIImage.properties`，最终 `merged.settingProperties(sourceMetadata)` 后再编码；诊断以 `input.frames.first?.diagnostics` 为基线，再追加“慢门合成/合成方式”。
- 构建、安装、启动成功。尚未在真机拍摄新光轨/流水并读取最终文件 EXIF 与详情页；不能把该修复写成已通过成片验证。

## 2026-10-23 慢门成片速度优化：源图直传

- 原路径每帧都走 `PhotoEncoder.encode` 生成 12MP JPG/HEIF，再由合成器解码；10 帧等于 10 次编码 + 10 次解码 + 最终再编码。
- 现改为 `CameraEngine.finishCapture` 在慢门序列分支把全分辨率 `CIImage` 直接交给 `SlowShutterSourceFrame`，不再逐帧编码。ViewModel 保留源图，合成完成后只调用一次 `PhotoEncoder`；滤镜和画幅也只应用一次。
- 首帧源图的 `properties` 仍用于最终 EXIF/TIFF，诊断仍取首帧参数；`PhotoCapturePurpose` 和普通拍照路径不变。
- 构建、安装、启动成功；未在真机测量优化前后 10 秒/8 秒序列的实际耗时、内存峰值和成片效果。

## 2026-10-23 慢门速度与预览优化

- 帧数据传输从 `CapturedPhoto`（已编码 JPG/HEIF）改为 `SlowShutterSourceFrame` 全分辨率 CIImage；合成器不再每帧 `createCGImage` 读回，最终只编码一次，滤镜/裁切只应用一次。
- 新增 `setSlowShutterSequencePreviewAssist`：帧间使用短曝光自动预览，拍摄时通过既有 preview-exposure-assist 路径临时应用手动 1 秒；序列结束恢复。
- 合成器测试 3 项通过；构建、安装、启动成功。真机 10 秒/8 秒序列实际耗时、内存峰值、成片和预览主观流畅度仍未测量；不能宣称已达到目标帧率。

## 2026-10-23 慢门序列真机测量与瓶颈

- 测试：临时真机测试 `SlowShutterSequencePhysicalTests`（使用测试替身 `PhotoLibraryService`，不写系统相册）完整跑完 10 帧光轨；该诊断测试在记录后已移除，避免把 40 秒级相机测试加入常规套件。
- 结果：总耗时 **42.344–46.768 秒**（多次运行），`phys_footprint` 峰值 **456.9–489.3 MB**，最终图 **2250×4000**、约 0.2–0.6 MB；测试断言最终图 >8MP、参数存在、进度清空、非合成中。最终图按当前默认画幅裁切，不是 12MP 4:3。
- 分阶段计时：`setExposureModeCustom` 从 1/30 秒预览切到 1 秒拍摄时，完成回调约 **4.8 秒/帧**；首帧约 1.2 秒。拍照提交到 `didCapturePhotoFor` 仅约 17ms，`finishCapture` 源图回调约 20–120ms。因此慢的主要是逐帧曝光模式切换，不是 JPEG 编码、合成或保存。
- 预览与 1 秒曝光共用同一传感器，无法同时保持 30fps 预览和 1 秒曝光。当前实现选择帧间恢复短曝光预览，因此序列约 40 秒；若保持 1 秒曝光不切回，预览约 1fps 但序列可接近 10 秒。需由产品确认优先级。
- 该测试只覆盖 M 挡、后置主摄、光轨；未测 A 挡、流水、8 帧、拔盘、温升或长时间连续序列。

## 2026-10-23 速度优先尝试与回退

- 用户选择速度优先后，尝试在序列期间持续保持 1 秒曝光、不逐帧切回 1/30 秒预览；同时设置 `activeVideoMinFrameDuration`/`activeVideoMaxFrameDuration` 为 1 秒。
- 真机测试未能稳定产生序列帧，最终没有成片；该路径已回退，当前安装版本仍为预览优先路径。
- 结论：不能通过简单关闭预览辅助实现速度优先；需要改成视频数据输出取帧、或一次曝光切换内连续拍多帧等更大的采集架构调整。未将速度优先写成已实现。

## 2026-10-23 顶部工具栏透明背景

- `CameraToolbarOverlapBackground` 不再绘制 `UIGlassEffect`、黑色染色或暖色渐变，只保留透明布局占位和 `allowsHitTesting(false)`。
- 工具栏按钮、位置、点击热区和弹窗定位未改。
- 相关测试预期已从“存在 Liquid Glass”改为“无 Liquid Glass”，但真机运行被锁屏拦截（`Unlock ... to Continue`），未取得测试结果；构建、安装、启动成功。未声称跨画幅透明效果已目视验收。


## 2026-10-23 前置预览内参比例修正与详情删除最终回归

- **定位证据**：独立最小系统会话与光屿同帧原图/处理图对照后，竖持手机切横幅时读到 fx≈2585.0632、fy≈1452.6512，横纵像素尺度比约 1.7796；竖幅约 1938.4552/1936.5264，接近 1。由此判断当前设备的预览代理缓冲存在非等比尺度，额外固定旋转、仅同步显示框或重复配置输出不能消除此问题。这是本机观测，不是 Apple 对所有设备的行为保证。
- **官方依据与实现**：通过 [相机内参交付](https://developer.apple.com/documentation/avfoundation/avcaptureconnection/iscameraintrinsicmatrixdeliveryenabled) 和 [逐帧内参附件](https://developer.apple.com/documentation/coremedia/kcmsamplebufferattachmentkey_cameraintrinsicmatrix) 读取以输出像素为单位的 fx/fy，压缩被拉伸的轴，再按成片画幅裁切并等比缩放。仅用于支持该能力的前置照片预览，蒙版/峰值采用相同坐标；不改变实际照片的源像素比例。系统自动设置代理缓冲尺寸；参考 [Smart Framing 官方示例](https://developer.apple.com/documentation/avfoundation/adopting-smart-framing-in-your-camera-app)，先应用画幅再恢复变焦。完成时间换算到会话时钟，丢弃旧交界帧，新图与框同步发布，保留短内容淡化而不插值宽高。
- **最终结果**：正常签名的 iPhone 17 Pro / iOS 27.0.1（24A446），`/private/tmp/LumaCamera-Framing-Deletion-FinalRegression.xcresult` 共 43 项通过，0 失败、0 跳过。包括 A/JPG、M/HEIF+流畅预览、前置宽窄与照片/视频隔离、内参两轴还原/非法值测试、图库删除/分页/加载和真机托管 SwiftUI 翻页渲染。不是全应用测试。无模拟器、无镜像，不向系统相册写入媒体。
- **真实图像**：最终 M/HEIF 轮记录实际 portrait 姿态且横幅内参比 1.7796，修正后预览与真实编码成片均朝上、人物比例一致。归一化人脸检测框宽/高差：竖幅 0.00936/0.00702，横幅 0.000912/0.000214。检测框只用于核对主体相对尺寸，不代表经过标定的光学视场角误差。标准档实际文件竖幅 3000×4000、横幅 4000×3000；处理后 EXIF/TIFF 方向为 1。已目视核对结果附件。
- **重复与性能**：A/JPG 与 M/HEIF 各 8 次连续切换（共 16 次），各 12 次快速请求后回退（共 24 次），持续核对已发布框与帧方向。最终 M/HEIF 的 8 次模型操作到匹配帧发布中位数 0.0462 秒，范围 0.0445–0.0890 秒，含 10ms 轮询；快速请求恢复窗口采到 8 次发布，最大间隔 0.1327 秒。无预览清空、崩溃或卡在错误画幅。指标不是触屏延迟、显示 FPS、功耗或内存。
- **删除回归**：最终结果包亦包含 36 项图库逻辑测试及 1 项真实设备托管分页渲染。100 次混合照片/视频删除导航与过期回调检查通过，纯逻辑耗时约 0.000177 秒；普通滑动动画保持。删除成功后不再等下一张高清图才切页，视频分支也结束事务。测试服务模拟删除，未删除用户媒体；真实 PhotoKit 确认弹窗与原始删除操作的人工端到端检查仍待复核，不能将逻辑耗时写成用户删除延迟。
- **边界**：最终批次没有自动执行完整的真实横拿→竖拿姿态序列，而是覆盖方向策略入口往返、实际竖持下的异常内参和连续画幅切换；不能把此前因姿态等待跳过的用例计为通过。未逐项复测其他机型/系统、HEIF Pro/HDR/Live、非标准比例和真实人像蒙版边缘。未测屏幕逐扫描帧或长期温升耗电。前述中间“已排除变形”结论由本节替代。


## 2026-10-23 慢门五预设最终真机复核与曝光交接修复

- **设备及隔离**：iPhone 17 Pro / iOS 27.0.1（24A446），项目正常签名。测试先停止可见相机会话，再运行独立相机模型与内存 PhotoLibraryService 替身，避免竞争相机；合成后的真实 JPG/HEIF 字节在设备端 ImageIO 解码检查。没有模拟器、屏幕镜像或系统 Photos 写入/删除。该流程不等同于目视操作真实保存弹窗和相册列表。
- **实测发现并修复**：关闭慢门原来仅关闭布尔值，预设及辅助没有统一清理；提前结束的合成记录仍写预设总帧数；普通慢门辅助关闭后首帧可能沿用短曝光；A 挡虚拟多摄路线无法应用本次要求的 1 秒 custom 曝光，旧流程仍合成短曝光帧。现在 A 挡用真实测光计算 ISO，暂借现有物理手动输入路线，界面及最终拍摄挡位保持 A，结束/取消恢复自动路线；序列期间 ready/镜头能力回调不再覆盖锁定曝光。逐帧读取源 EXIF，已知曝光偏离 1 秒超过 0.02 秒则停止并恢复。
- **连续拍摄问题**：中间版本在 M 挡光轨后接 HEIF 流水复现超时及 AVFoundation -11819。恢复/选预设时曾先提交长曝光，再立即切回短曝光预览；调整为普通辅助与序列辅助先接管、再释放另一方，避免中间状态。最终 M 挡同一会话内光轨→HEIF 流水连续通过，A 挡相同顺序也通过，两份最终日志均未出现相机会话 runtime error；不能据此保证所有长期场景不会再发生系统故障。
- **最终用例结果**：`/private/tmp/LumaCamera-SlowShutter-Handoff.xcresult` 为 13 通过、2 跳过、0 失败；`/private/tmp/LumaCamera-SlowShutter-AutoFinal.xcresult` 为 1 通过、0 跳过、0 失败。同一最终生产代码共 14 个不同用例通过，另 2 个旧用例因自行创建但未启动相机会话而跳过，未计为通过。覆盖合成颜色规则、五档范围与硬件裁切、实时预设布局/20 次开关、镜头切换，以及下列实际采集流程。

| 挡位/预设 | 文件 | 源帧 | 操作至合成保存回调 | 宿主基线/峰值 MiB |
| --- | --- | --- | --- | --- |
| A 光轨 | JPG，3000×4000 | 10 帧，均 1 秒 | 47.426 秒 | 83.1 / 475.0 |
| A 流水 | HEIF，3000×4000 | 8 帧，均 1 秒 | 37.468 秒 | 102.0 / 319.0 |
| M 光轨 | JPG，3000×4000 | 10 帧，均 1 秒 | 48.365 秒 | 87.3 / 481.5 |
| M 流水 | HEIF，3000×4000 | 8 帧，均 1 秒 | 38.314 秒 | 272.3 / 322.6 |

- **样本与指标边界**：表中最终每组合 1 次，共 4 个完整序列、36 个源帧；时间含路由准备、逐帧拍摄、合成编码和内存保存替身回调，不含真正 PhotoKit 保存。内存每约 50ms 读取 `task_info.phys_footprint`，单位为 1024² 字节；这是包含 XCTest 的宿主进程，不是脱离测试运行的纯应用内存，也不是总分配量/泄漏结论。各序列结束时 thermalState 为 nominal，不代表实测温度、功耗或长期不发热。
- **真实元数据**：逐帧实际 EXIF ExposureTime 为 1 秒；最终文件存在快门、ISO、焦距等 EXIF，像素尺寸为 3000×4000。应用拍摄参数快照存在，A/M 记录按用户挡位，合成说明为实际 10/8 帧；提前结束核对实际已完成帧数。这里只验证编码文件数据，没有把应用详情页文字代替系统相册的真实文件参数。
- **其余三档**：动态模糊、摇拍追焦、星轨各完成一次 M 挡单帧实拍，源文件快门分别为 0.125、0.0333333、1 秒，符合所选预设；均未进入多帧序列。星轨仍不能凭该预设生成完整长时间星轨。
- **恢复与稳定性**：提前结束并合成一次通过；拍摄中退后台取消并重开通过；提前结束后立即关闭慢门、取消后台合成通过，未交付取消任务的照片。快速预设选择/关闭 10 轮后无选中项、进度或合成状态残留，延迟下一帧任务校验原序列 token。A/M 的曝光、白平衡和对焦自动/手动标志恢复断言通过。A 挡曝光不合适的拒绝路径在早期测试分别观测到约 ISO 43（低于 54）和 233–236（高于 200），均没有保存；最终 A 完整序列用真实测光和公开 EV 调整到允许范围，不伪造读数。
- **官方依据**：[setExposureModeCustom](https://developer.apple.com/documentation/avfoundation/avcapturedevice/setexposuremodecustom%28duration%3Aiso%3Acompletionhandler%3A%29) 说明 custom 曝光设置及完成回调，实际应用时仍需核对镜头支持能力。虚拟路线失败和辅助交接冲突是本机观测；五个题材预设、ISO 范围、序列帧数和 EXIF 容差是应用策略，不是 Apple 官方夜景/长曝光算法或保证。
- **保留限制**：尚未在真实车流光轨、流水、摇拍或星空场景评价成片观感；未覆盖前置/其他焦段、所有比例、长时间连续序列、热稳态或独立进程功耗。预览优先仍需要约 48/38 秒完成目标累计 10/8 秒曝光，没有解决根本速度瓶颈；速度优先旧尝试仍处于回退状态。
- **失败历史保留**：`LumaCamera-SlowShutter-Validation1.xcresult` 的预设残留、`AutoMetered` 的短曝光、`AutoPhysicalRoute` 的超时、`Validation2`/`Final` 的连续 M 挡异常均为定位过程，不能称为通过；最终结论仅以上述 Handoff 与 AutoFinal 为准。此前“尚未验证 A 挡/流水”历史记录由本节更新。


## 2026-10-23 真机全量测试（本次独立归档，仅记录）

- iPhone 17 Pro / iOS 27.0.1（24A446），项目正常签名，真机单设备串行运行。XCTest 汇总 **494 项：469 通过、19 失败、6 跳过**，整体 Failed。结果包时间窗口为 17:41:25–18:05:16（Asia/Shanghai），约 1430.6 秒；不能只引用进程自动续跑之后的局部套件统计。
- 发生一次 `ImagingTests.testAllFiltersRenderEveryRatioAndBorderAddsCanvas` 的 `signal kill`，Xcode 自动恢复进程并继续剩余用例；未人工重跑失败项、未修改生产代码或测试代码。未确认 kill 根因，不据此宣称内存不足或系统相机崩溃。
- 根据用户最新要求，本轮失败项不合并此前待办，详见 [本次独立待办清单](Test-Reports/2026-10-23-FullDevice-TODO.md)；结构化汇总为 [本次结果 JSON](Test-Reports/2026-10-23-FullDevice-results.json)。19 个失败方法逐条保留摘要、源码断言、相关规格与后续核对状态；相机 runtime error、6 项跳过和命令排除项另列，不混作额外失败方法。
- 首次启动命令因未显式排除全部真实相册集成类被自动审批拒绝，没有执行。补齐排除名单后进行本次唯一全量运行；不向系统 Photos 写入/删除诊断媒体，未启动或操作模拟器、未使用镜像。外接盘实录和用户配合姿态未执行，FocusLockModeTests 因构造真实相册服务保守排除；部分图库集成类本就仅在模拟器编译。明确排除的选择器不计入运行时的 6 项跳过。
- 性能观测覆盖既有逻辑、快照、预览发布、滤镜压力与实际短片/慢门序列指标。滤镜 2040 次参数更新约 31.777 秒，宿主 footprint 基线/峰值/稳定后约 239/419/284 MiB；18 组视频规格短片约 25.63 秒，其中 1080p120、4K120 的轨道帧率分别约 61.62/62.04，未通过 120±6 的断言。发布次数不是屏幕 FPS，宿主包含 XCTest，不能写成纯应用内存。末尾视频用例 thermalState=1（fair）不等于实测温度；没有据此通过长期录像功耗/温升验收。
- 结果包：`/private/tmp/LumaCamera-FullDevice-20261023-RecordOnly.xcresult`；日志：`/private/tmp/LumaCamera-FullDevice-20261023-RecordOnly.log`。独立报告已持久保存必要摘要，临时目录可能被系统清理。

## 2026-10-23 全量失败项修复与定向真机回归

### 范围和最终结果

用户在原“只记录”全量运行后明确要求修复。原始 494 项、469 通过/19 失败/6 跳过的历史结果保留；不是把原运行改成成功。原 19 个失败方法现均有最新定向真机通过结果，逐项分类、原始断言和复测来源见 [独立清单](Test-Reports/2026-10-23-FullDevice-TODO.md)。没有与此前待办合并。

设备仍为 iPhone 17 Pro / iOS 27.0.1（24A446），Xcode 正常工程签名，单真机串行测试，不启动或操作模拟器、不使用镜像、不向系统相册写入或删除诊断媒体。样张与视频只在内存或临时文件中处理。

- `/private/tmp/LumaCamera-FullFix-Final21.xcresult`：选择原 19 项及 2 项直接相关补充（照片手动参数跨视频冷启动恢复、真实 Open Gate 画幅）；**20 通过、1 失败**。唯一失败是视频编码矩阵在规格重配后过早开始录制，不是画幅断言；未将这轮写为全通过。
- 随后视频编码测试补上与实际快门相同的就绪等待，在 `/private/tmp/LumaCamera-FullFix-FinalFollowup.xcresult` 连续运行人像捕获→慢门预览辅助→编码矩阵，**3 通过、0 失败**。因此原 19 项的最新逐项状态均为通过；没有声称获得一次全量 494 项全通过。
- `/private/tmp/LumaCamera-FullFix-K1.xcresult`：**15 通过、0 失败**，含 6 项拍摄状态保存、4 项 Open Gate 能力、22 段视频编码/画幅组合，以及 SDR/P3 滤镜烧录、Log LUT 烧录和 A/M×五种色彩空间文件标记。该组与上面有重叠，不能直接相加当作独立用例总数。
- 上述三组日志中未出现项目记录的 `Camera capture session runtime error:`；仍有系统 `MDB_MAP_FULL` 日志。未证明原 8 条 runtime error 的全部根因已消失。
- 最终正常 App 构建成功：`/private/tmp/LumaCamera-FullFix-FinalApp.log`；已按项目签名安装到该 iPhone，并通过 devicectl 正常启动。相关验证未改变界面样式、控件位置或已有过渡动画。

### 产品修复

1. 自动镜头策略在最终路线提交后恢复设备公开支持的完整 fallback 集合；不缓存格式切换中的临时子集。A/M 连续变焦路线与前后切镜同样覆盖。系统仍自行选择物理镜头，没有强制主摄、近距阈值、定时重对焦或系统切镜动画。
2. 照片/视频最外层事务提交完成后恢复音频触感许可，避免内层提交时设置被最终图配置覆盖。
3. 同一次媒体切换按**显示倍率**保存构图，在最终设备提交后换算物理倍率恢复，修复 8× 返回照片变 1×。照片 M 挡快门、ISO、白平衡/对焦标志保留进入视频前快照，避免视频 1/fps 上限覆盖照片长曝光；可选存档字段兼容旧数据，冷启动停在视频后也能恢复。
4. 普通 >60 帧视频复用录制输出生成预览，减少双路高帧率缓冲；在事务内先更新输入 `videoMinFrameDurationOverride`，再设置设备 min/max 帧周期。先改设备会被旧输入上限钳住，导致实际节奏落后一档；退出视频释放输入上限。RAW 外接文件仍不裁切、不烧录、不自动转存相册。
5. 静态画幅先选择原图内的整数像素矩形，再按最近像素居中裁切，避免 Core Image 小数边缘向外取整产生额外比例误差；不拉伸图像。拍摄时核对当前活动格式的照片尺寸缓存。

### 测试契约与前提修正

- 延时与视频编码矩阵等待最终规格和快门就绪再开始录制；不把 UI 本会禁用的提前按下当作录制失败。测试复用唯一可见相机会话，重置内存拍摄状态，不再建立多个竞争同一设备的诊断引擎。
- 前置竖幅测试显式关闭横幅，保留当前支持竖持横幅照片的功能。真实原片等效焦距可取整为 30/31mm；最终 EXIF 必须与原片完全一致，不改写为固定 31mm。
- 方形预览与 4:3 一样避让顶部工具栏；按钮符号检查使用有效 SF Symbol；A/M 首帧测量改看路线代次，同时断言保留旧预览、不清空闪黑。
- 普通视频矩阵使用五种 `aspectOptions`；Open Gate 是独立采集开关，另以真实 4:3/1:1 文件验证，不能在未启用它时把普通 16:9 原始帧当作 4:3 失败。
- 人像测试核对确实请求活动格式的 8064×6048 上限，以及系统实际交付文件与最终像素量。Apple 明确允许 `maxPhotoDimensions` 返回更小照片；该值不是每张必得 48MP 的保证。
- 人像蒙版测试使用与实际灰度蒙版一致的不透明黑白值，避免透明背景使对照失效。慢门反复选择动态模糊后应保留最新预设 1/8 秒，而非最初手动 1/15 秒。
- 全滤镜×画幅×边框仍完整覆盖，测试逐项释放临时对象、关闭中间缓存并清理 CI 缓存，使用硬件 CIContext。原 signal kill 没有取得系统根因证据；只能确认修改后的矩阵再次通过，不能称为已确认的 App 内存泄漏修复。

### 性能、稳定性及实际文件指标

- 原 19 项回归中的 A/M 切换共 **8 次**：最终路线首帧发布 P50 **0.290 秒**、最大 **0.352 秒**；旧帧没有被清空。指标是路线帧发布观察，包含观察者调度，不是屏幕 FPS 或触摸响应时间。相同用例的早期隔离环境结果有差异，不作未经控制的前后速度提升百分比。
- 视频规格矩阵 **18 段**临时文件，约 **33.11 秒**完成；720p/1080p/4K 的当前 M 挡能力均按真实轨道核对。1080p120、4K120 轨道均为 **120fps**，输入时间戳约 **119.95fps**，不是仅写入一个 120 标签。此为约 1.2 秒短片，不能代替长录与热稳定性验收。
- 视频编码矩阵 **22 个组合**，最后复查矩阵步骤 **33.16 秒**、整个方法 **39.59 秒**；HEVC/H.264、六种常规 ProRes、HDR/Log 及前后镜头/画幅按设备实际能力检查真实编码与解码。外接 RAW 实盘未测，不增加已验证声明。
- A/M×五种色彩空间共 **10 段**临时片，约 **31.43 秒**；HDR 为 10 位 HLG/BT.2020，Log/Log 2 使用实际 Log 标记；滤镜/LUT 按原规则核对烧录后像素和文件色彩标记。
- 延时 people 预设约 **2.2 秒采集→5 帧、0.1667 秒、30fps、无音轨**；重复普通录像 **3 段**核对触感许可在预览和录制期间保持开启。
- 人像远景重复 **3 次 HEIF**均输出 **6000×8000**，捕获完成 P50 **1.321 秒**、最大 **1.771 秒**；**3 次 ProRAW**均为 **8064×6048**，P50 **3.831 秒**、最大 **3.837 秒**。普通 48MP 对照第一张实际交付 4032×3024，尽管请求 8064×6048；不靠放大伪造 48MP。此场景没有取得有效人物蒙版，不能据尺寸通过推断人物发丝/虚化质量通过。
- 全滤镜×画幅×边框渲染在最终回归约 **3.726 秒**完成，未再 kill；这是测试矩阵耗时，不是拍摄预览帧率，没有将 XCTest 宿主内存当作纯应用内存。
- 以上组末记录的 `thermalState=0` 表示系统 nominal，不能换算为温度、功耗或长期发热结论。重复切镜、前后往返、慢门开关/取消、模式恢复、编码结束后的继续录制均由对应方法覆盖。

### 仍需处理的额外发现与边界

**FOLLOWUP-20261023-001：近距离 A 挡人像等待完成回调超时**。修复期间，多轮最近对焦端等待约 55 秒仍无完成回调；用户将后置对准约 1 米外场景后，A 挡与 M 挡重复捕获通过。没有把这个超时的根因归为已证实的原生捕获或后处理问题，也没有以远景通过冒充近距已修复。该项单独留在本次独立清单的“额外发现”，不计入原 19 项，不并入此前待办。

未做外接 SSD RAW 实录、真实系统相册写入/删除、长期录像/功耗/温升或全界面人工目视验收。相机系统日志未完全归因。此次为修复后的相关定向回归，不是又一轮全量测试。

官方依据：Apple [fallbackPrimaryConstituentDevices](https://developer.apple.com/documentation/avfoundation/avcapturedevice/fallbackprimaryconstituentdevices)、[videoMinFrameDurationOverride](https://developer.apple.com/documentation/avfoundation/avcapturedeviceinput/videominframedurationoverride)、[activeVideoMinFrameDuration](https://developer.apple.com/documentation/avfoundation/avcapturedevice/activevideominframeduration)、[maxPhotoDimensions](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/maxphotodimensions)、[录音期间触感许可](https://developer.apple.com/documentation/avfaudio/avaudiosession/allowhapticsandsystemsoundsduringrecording)。同时核对当前 Xcode SDK 的 AVCaptureDevice.h、AVCaptureInput.h、AVCapturePhotoOutput.h 与 AVAudioSession.h 中的官方契约。


## 2026-10-23 近距人像超时阶段诊断

- 设备：同一 iPhone 17 Pro / iOS 27.0.1（24A446），正常签名。用户确认后置近处主体准备好；没有测量主体实际距离，不能将本次场景视为此前超时场景的严格复刻。
- 构建：`/private/tmp/LumaCamera-PortraitPhase-Build.log`，TEST BUILD SUCCEEDED。新增诊断仅 DEBUG 且测试显式开启，记录提交、系统快门、原生处理完成、硬件完成、分割、编码与最终完成阶段，默认关闭；未更改人像算法、自动微距策略或界面。
- 定向结果：`/private/tmp/LumaCamera-PortraitPhase-Near.xcresult` / `.log`；`PortraitCapturePhysicalTests/testPortraitProcessedAndProRAWCapturesWithoutSaving` 1 项通过，20.036 秒，8 次临时捕获，无 Photos 写入。包含 A 挡 HEIF 12MP 1 次、M 挡高像素无虚化对照 1 次、人像 HEIF 48MP 与 ProRAW 48MP 各 3 次。
- A 挡首张：提交至 willCapture 约 0.396 秒、原生处理回调约 1.086 秒、完成约 1.300 秒；3000×4000，收到原生系统人像遮罩，无 Vision 后备分割。该次全部阶段正常，不能据此证明此前超时位于系统或应用哪一阶段。
- M 挡人像 HEIF 48MP（3 张）完成 P50 1.439 秒、最大 1.668 秒；6000×8000。ProRAW（3 张）P50 3.765 秒、最大 4.422 秒；8064×6048，文件包含可解码人像遮罩。此为完整捕获处理回调耗时，不是预览帧率；并未进行蒙版边缘质量目视验收。
- 本轮没有相机会话 runtime error 日志，仍有系统 MDB_MAP_FULL 日志。近距超时未复现，FOLLOWUP-20261023-001 保持未解决；原始 8 条 runtime error 也未完成逐条因果复现。不宣称本次定位根因或修复。
- 官方边界：Apple 的 [portraitEffectsMatteDeliveryEnabled](https://developer.apple.com/documentation/avfoundation/avcapturephotosettings/isportraiteffectsmattedeliveryenabled) 说明人像遮罩依赖深度数据，不保证每张都有遮罩，且可能显著增加处理回调时间；这不能解释或合理化此前 55 秒无完成回调。阶段记录依照 [AVCapturePhotoCaptureDelegate](https://developer.apple.com/documentation/avfoundation/avcapturephotocapturedelegate) 的系统回调区分，未增加基于距离的强制切镜。

## 2026-10-23 近距微距与人像请求互斥修复

- 设备：同一 iPhone 17 Pro / iOS 27.0.1（24A446），正常项目签名。用户将有纹理物体置于约 5–10 cm，未精确测距。
- 复现结果：`/private/tmp/LumaCamera-PortraitPhase2-Near.xcresult` / `.log`。实际虚拟三摄由超广角供图，界面 macroActive=false、对焦读数 0；提交时 captureReadiness=1（ready）。约 1.58 秒后 willBegin/willCapture，约 1.73 秒后 didCapture；55 秒没有原生 processed/final capture 回调，应用分割及编码尚未开始。本次超时不是应用后处理耗时。
- 官方依据：[单张深度选项](https://developer.apple.com/documentation/avfoundation/avcapturephotosettings/isdepthdatadeliveryenabled) 可选择是否请求深度，并说明会增加处理耗时；[输出管线配置](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/isdepthdatadeliveryenabled) 允许全局启用后逐张请求或不请求深度。苹果没有明确说明本场景必然超时，不能把实测现象写成平台保证。
- 修复：实现应用原定微距优先规则，快门提交前读取实际主镜头和倍率；微距本张不请求人像深度/遮罩、不执行后备人像虚化、不标为人像，用户开关保持开启。未改变全局深度输出管线、界面或系统自动切镜。
- 初步 `/private/tmp/LumaCamera-PortraitMacroFix-Near.xcresult`：1 项 / 8 次临时捕获通过，但 A 挡实际主摄供图，不计为微距分支覆盖。
- 严格近距 `/private/tmp/LumaCamera-PortraitMacroFix2-Near.xcresult`：**1 项通过，5.409 秒**。每次先观察到系统实际超广角，连续 HEIF 2 张、JPG 1 张，3 次均记录 portrait-suspended-for-system-macro，完成约 2.248、1.161、0.407 秒，P50 1.161、最大 2.248 秒。首张界面微距仍 false，覆盖了发布滞后分支。检查未执行人像处理且用户开关仍开启。
- 稳定性：近距用例还快速开关人像 6 次、停止相机再启动，最终 ready、pendingPhotoCount=0、shutterBusy=false。未模拟曝光中途取消原生请求，不宣称该路径已覆盖。
- 用户移向约 1 米外后，`/private/tmp/LumaCamera-PortraitMacroFix-Far.xcresult`：**4 项通过，22.212 秒**（MacroPolicy 2 项、人像真机 2 项）。A 挡恢复系统人像遮罩，12MP 完成约 1.673 秒；另外捕获 M 挡对照 1 张、HEIF48MP 3 张、ProRAW48MP 3 张。HEIF48MP P50 1.315、最大 1.400 秒，6000×8000；ProRAW P50 4.203、最大 4.279 秒，8064×6048，原始文件有可解码遮罩。未进行遮罩边缘质量目视验收。
- 人像开关路由回归 6 轮：过渡解除耗时 P50 0.254、最大 0.295 秒，仍为虚拟多摄 .auto，超广角 fallback 保留。这是状态/出帧路径耗时，不是屏幕 FPS。
- 正常构建：`/private/tmp/LumaCamera-PortraitMacroFix-FinalApp.log`，BUILD SUCCEEDED。各组样本有重叠，不相加成全量覆盖；未重跑 494 项。临时媒体未保存系统相册，无镜像、无模拟器操作。修复验证组没有相机会话 runtime error 日志，仍有系统 MDB_MAP_FULL；未测长期功耗或温升。
- 结论：已修复本次实际复现的微距深度请求超时分支。历史只有主摄状态快照的超时未独立重现，不能确认同根因；独立待办保留观察说明。

## 2026-10-23 八条相机会话错误专项处理

- 同一 iPhone 17 Pro / iOS 27.0.1（24A446），正常签名，无镜像、无模拟器、诊断媒体不写入系统相册。原七个关联方法基线 6 通过 / 1 失败，并产生 3 条真实运行错误；仅看功能通过不足以验收。
- 实际复现普通视频 A/M 与跨模式中间配置提交错误；输入/格式/输出改为完整事务，前置广角测试改为复用可见引擎；白平衡测试显式建立后置虚拟路由前提。保留原功能断言，并新增跨会话运行错误审计。
- `/private/tmp/LumaCamera-Runtime8-Final.xcresult` / `.log`：**10 项全部通过，121.312 秒，0 条非注入会话错误**。原八条记录对应七方法全部通过；另覆盖快速切换/退出回来、迟到通知启动竞争、带 error key 的恢复通知。
- 24 次前后切镜至新路由帧标记 P50 0.497、最大 0.866 秒；48 次跨模式 P50 0.480、最大 0.637 秒。基线对应最大值 1.010、1.093 秒。样本场景负载并非严格受控，不作统计显著提速结论，不能当作屏幕帧率或触屏延迟。
- 主动停止会话后注入 -11800 / 底层 -12780 与 -11819，各 2 次，4 次均恢复并获得新帧，P50 0.109、最大 0.386 秒；再注入 1 次并退出，0.5 秒后实际会话保持停止。日志中的 5 条错误均为恢复用例主动注入，不是新自然错误；不等于真正让系统媒体服务崩溃。
- 原始 -11819 的系统内部根因未能由旧日志确定；其他未单独复现的历史行不宣称与已复现路径同因。未重跑 494 项，也未测长录、外接盘和长期功耗。既有测试目标警告、系统 MDB_MAP_FULL 与 Fig 私有断言未扩展归因为本次会话错误。
- 原始日志、逐项映射、基线/中间结果、官方依据与边界见 [八条会话错误专项记录](Test-Reports/2026-10-23-Runtime8-Resolution.md)。

## 2026-10-24 星轨与动态模糊多帧

- iPhone 17 Pro / iOS 27.0.1（24A446），正常签名，真实相机 + 内存相册替身；未保存/删除系统相册媒体，无模拟器、无镜像。
- `/private/tmp/LumaCamera-StarMotion-Physical.xcresult`：5 项，4 通过、1 条旧测试断言失败（动态模糊实际 0.125 秒，测试仍期望旧 1 秒）。完整星轨 **120 张全部核对 EXIF 1 秒**，1200 万像素输出，合成结果耗时 **598.491 秒**，方法耗时 601.647 秒；宿主 footprint 基线/峰值 **111.8/497.6 MiB**。每次采样检查应用只保留一张源图；该内存包含 XCTest，不是纯 App 内存或无泄漏证明。
- 原光轨 10×1 秒、流水 8×1 秒回归通过，约 48.369、36.718 秒；摇拍单帧曝光检查通过。旧光轨/流水合成路径未改为流式。
- 修正共用测试按各预设实际曝光核对后，`/private/tmp/LumaCamera-StarMotion-Final.xcresult`：**11 项全部通过，45.517 秒**。动态模糊 8 张实际 0.125 秒、最终 EXIF 0.125 秒，1200 万像素，耗时 **6.174 秒**；宿主 footprint 约 **80.1/480.4 MiB**。
- 提前结束计入正在合并的一帧，取消不保存；新建动态模糊时注入旧星轨源帧确认忽略，首帧期间取消后状态恢复。快速预设切换及源图数量检查通过。
- A 挡本轮两个新预设均测得目标 ISO 低于允许范围，安全拒绝且保留 A 挡/原参数；未完成 A 挡暗光完整序列，不能按已通过记录。120 帧小图亮点保留、平均像素对照、空帧拒绝、预设/硬件范围和预览门限检查通过；小图耗时不是全分辨率吞吐或显示 FPS。
- 真实星空/运动题材成片、所有镜头/滤镜组合、长期温升功耗未验收。累计曝光与墙钟时间不同，原生捕获处理有间隔，不承诺无缝星轨或连续运动拖影。配置、官方 CIContext 依据及完整指标见 [专项记录](Test-Reports/2026-10-24-StarMotion-MultiFrame.md)。

## 2026-10-24 慢门五预设出片速度优化

- 官方手动曝光包围每次一张，将真实快门/ISO 绑定到静态请求，不再每张等待预览曝光切换；兼容性不足保留原捕获路径，标准分辨率外不启用新路径。取消及参数恢复沿用原逻辑，移除帧间固定 60 ms 空档。
- iPhone 17 Pro / iOS 27.0.1、主摄 M 挡：光轨旧 47.343 秒，新 3 次 11.970–13.752 秒（中位 12.013）；流水旧 37.546 秒，新 10.136–11.829 秒（中位 10.192）；动态模糊旧 6.097 秒，新 2.810–2.873 秒（中位 2.867）。完整星轨 120 张新路径 152.953 秒，历史同配置旧路径 598.491 秒，两者各 1 次。摇拍默认约 0.1 秒、开启预览辅助约 0.32 秒，未观察到明显变化，不宣称五项都同等提速。
- 所有完整序列逐张核对实际 EXIF 曝光及 ISO；成片 3000×4000，源图数与诊断一致，星轨最多保留一张源图。合成编码仍约 0.1–0.3 秒。取景发布间隔测量不能视为显示帧率，1 秒拍摄仍可造成约 1.1 秒取景发布空档。
- 对比轮 `/private/tmp/LumaCamera-SlowSpeed-Compare.xcresult`：11 通过、0 失败，366.994 秒。补充轮 `/private/tmp/LumaCamera-SlowSpeed-Final.xcresult`：6 个方法通过、1 个暗光前提不足方法失败（框架 2 条断言）；该方法未开始捕获，已修正为明确跳过环境不足。
- 最终代码 `/private/tmp/LumaCamera-SlowSpeed-ReleaseCheck.xcresult`：4 通过、1 跳过、0 失败，59.002 秒，含真实会话错误审计。覆盖动态模糊实际曝光、摇拍重复 12 次、预览辅助开关、星轨提前结束/取消/迟到源帧及快速选择。前两轮还覆盖合成中取消和后台返回。诊断成片全部留在内存相册服务替身，未写系统相册；未使用镜像或模拟器。
- A 挡范围外拒绝通过，但完整暗光 A 挡序列本轮未验证；没有放宽 ISO 或用短曝光代替真实曝光。未验证所有镜头/画幅、真实运动/星空效果、像素级画质等价或长期热功耗。宿主内存含 XCTest，不能当作纯 App 内存。
- 2026-10-23 约 48/38 秒及速度优先回退记录保留为历史；本次没有恢复持续 1 秒预览曝光的失败试验。完整样本与实现依据见 [专项报告](Test-Reports/2026-10-24-SlowShutter-Speed.md)。

正常版构建日志 `/private/tmp/LumaCamera-SlowSpeed-FinalApp.log`：BUILD SUCCEEDED。已按项目原签名安装并在连接的 iPhone 启动，诊断阶段日志默认关闭。

## 2026-10-24 人像成片与连续景深调节优化

- iPhone 17 Pro / iOS 27.0.1，原签名、真实相机，未使用镜像或模拟器。诊断照片仅存临时捕获回调与测试附件，未写系统相册、未添加项目图片资源。
- 修正大图/预览虚化相对比例、背景轮廓渗色、小强度黑边及融合元数据保留；预览复用视频分割请求、强度短缓动、漏检按源帧年龄渐退。收起滑块保持效果，退出/微距/模式切换同步暂停，关闭释放分割历史。
- 前后置真实人物各连续修改 180 次强度，分别 194/218 次 UIImage 发布，均未见 nil 预览；发布间隔 P95 42.91/49.85 ms、最大 63.33/64.31 ms，不是屏幕 FPS。分别只新建 1 次视频请求，本段成功蒙版 65/55 张；分割近期窗口 P50 13.57/10.56 ms、P95 17.61/14.07 ms。收起滑块、快速开关和后台返回检查通过。
- 前置临时 JPG 0/100% 回调约 0.947/1.003 秒，后置约 0.880/0.747 秒；人物移动的跨照片对比不用于严格画质结论。另单独取得同一张后置原片与处理结果：实际主摄 24mm、ISO 320、1/60 秒、原生人像蒙版，人物与手持手机保持清晰，背景虚化生效。
- 像素检查：高反差人物边缘抑制渗色、0.01 弱强度不发黑、0 强度原图；900/1800 宽等比处理后线性 RGB 平均差约 0.00265。900×1200 真机实际非延迟渲染 20 样本，最终 P50/P95/最大约 3.28/3.90/3.98 ms，不是预览 FPS。
- Probe 轮 8 项中 2 项初始失败已修正并复测；Edges 轮 11 通过、Rear 轮 1 通过、Final 轮 11 通过、Metadata 轮 10 通过、SameFrame 轮 1 通过。具体路径前缀 `/private/tmp/LumaCamera-PortraitOptimize`。EXIF 快门/ISO/焦距、HEIF 12MP/48MP、ProRAW 48MP 输出及系统自动切镜/微距 UI 规则回归通过；没有蒙版的格式用例不能视为原生人像虚化已触发。
- Edges 轮快速构造测试状态出现一次 Bool onChange 多次更新警告，未据此改动布局；后续 Rear/Final/Metadata/SameFrame 未见该警告或相机会话运行错误。不声称全部系统日志无警告。
- 复杂发丝、透明物体、遮挡和局部背景仍受蒙版精度限制；未实现三维焦平面模拟，未验证全部画幅/镜头、多人快速运动或长期功耗。当前人像模式在滑块关闭后也保持分割，因此仍有运行成本。官方依据、具体样本与剩余边界见 [专项记录](Test-Reports/2026-10-24-Portrait-Optimization.md)。

正常版本：`/private/tmp/LumaCamera-PortraitOptimize-FinalApp.log` 构建成功，已按项目原签名安装并在连接的 iPhone 启动 `com.shurrikann.LumaCamera`。未把测试回调、样片或诊断附件加入正常应用资源。

## 2026-10-24 M 挡后置主摄 HEIF 人像入口

- iPhone 17 Pro / iOS 27.0.1、后置物理主摄 M/HEIF、Live 关闭，`/private/tmp/LumaCamera-PortraitM-EntryBaseline.xcresult` 复现入口失败。原因是原生 depth/matte 不支持被当作整个应用人像不可用，且快门 preflight 会清掉可由 Vision 处理的请求。
- 分离应用入口与原生管线能力，兼容软件处理时保留请求；不切 A、不换虚拟输入、不改界面。Live 继续按人像规则关闭，普通 HEIF Live 规则不变。
- 初修 4 项通过；最终 `/private/tmp/LumaCamera-PortraitM-EntryVerified.xcresult` **4 项通过、0 失败，12.254 秒**。4 次 HEIF 捕获约 0.496/0.673/0.717/0.386 秒，中位 0.584；3 轮人像开关及 3 轮 A/M 往返保持人像与规格，实际文件验证手动 ISO 200 / 1/125 秒。原有 A 挡虚拟多摄自动选择规则、软件入口/格式策略检查通过；临时照片不写相册。
- 本轮无可用人物蒙版，实际保留清晰原片，不写为 M 挡人物虚化画质已验收。测试计时是提交到回调，30 ms 轮询，不含相册保存，非 FPS；未做全量规格/热功耗检查。
- 中间扩大测试共 22 项，2 个方法产生 5 条断言：手动参数需等待真实异步曝光生效（最终已正确验证）；另一个比例中心断言有 0.5 像素差，本次未修改 FrameRatio，已单独待办。快速调参后立即拍摄的曝光同步是独立观察边界，本轮未改全局流程。详见 [专项记录](Test-Reports/2026-10-24-Portrait-M-Entry.md)。

正常版 `/private/tmp/LumaCamera-PortraitM-FinalApp.log` 构建成功，已用项目原签名安装并在连接的 iPhone 启动。

## 2026-10-24 夜景曝光归一与暗部优化

- 固定三帧包围增加曝光归一、运动区域保护、暗部降噪和影调提升；支持参考帧存在时实际双帧融合，单帧回退不标为多帧。未修改环境门限或实现自适应帧数。
- iPhone 17 Pro / iOS 27.0.1，原签名。`/private/tmp/LumaCamera-Night-Optimize-Normalized.xcresult` 10 项通过；3 次临时真实捕获（JPG×2、HEIF×1）均三帧融合，回调耗时 1.561/1.765/1.702 秒。实际 EXIF 快门/焦距与中间曝光一致，文件含 ISO 800；附件目视见暗部亮度/噪声改善，样本失焦限制细节评价，不宣称全部题材验收。
- `/private/tmp/LumaCamera-Night-Optimize-Final.xcresult` 9 项通过：快速开关 4 轮、退出/重入 1 次、普通拍照 1 次、七种画幅横竖共 14 个编码、运动/亮度/无效帧回退及环境门限重置等。会话错误审计无错误，诊断不写系统相册。
- 320×240 真实渲染 12 次中位/P95 138.6/147.6 ms；合成噪声夹具暗部 10400 像素通道标准差 7.240→2.073。只代表该夹具，非实景降噪幅度、显示 FPS、全分辨率吞吐或长期功耗。本场景未自然触发夜景，硬件采集用例强制请求；此限制及首轮偏暗修正过程见 [专项记录](Test-Reports/2026-10-24-Night-Optimization.md)。

正常版本 `/private/tmp/LumaCamera-Night-Optimize-FinalApp.log` 构建成功，已按项目原签名安装并启动 `com.shurrikann.LumaCamera`；未将临时样片或测试插件加入正常包。

## 2026-10-24 夜景自适应帧数与照片信息

- 固定三帧已扩为按暗度和场景稳定性规划 **3/6/9 帧**。每次最多请求三张，真实后置 A 路线读取的单请求包围上限为 8；首批包围、追加批次 0 EV 降噪帧，同一快门 token 只交付一张成片。低电量/严重热状态减至三帧，运动、路线变化或预算不足不再追加；退出期间取消组并回收资源。
- iPhone 17 Pro / iOS 27.0.1，原签名。受控条件真机 5 项通过：3 帧 1 次、6 帧 2 次、9 帧 2 次均实际融合全部请求帧；6 帧约 3.491/3.603 秒，9 帧 5.049/5.160 秒。宿主含 XCTest footprint 112.6→635.8 MiB，40 ms 采样，不能当作纯应用内存或长期无泄漏结论。
- 最终无注入自然暗光 `/private/tmp/LumaCamera-Night-Adaptive-NaturalFinal.xcresult` **4 项通过、11.353 秒**。实际 ISO 约 2709 / 0.033244 秒，正式门限自然触发夜景，需求 90.1；连续三次均 **6 帧规划、6 帧采集、6 帧实际融合**，回调 3.133/3.120/3.197 秒。早期绝对纹理阈值在该暗景过于保守，已改相对场景对比度；弱单方向纹理、位移/变化区域保护仍通过。
- 照片信息沿用既有“夜景曝光合成：N 帧对齐融合”，显示实际数，不重复增加计划/采集栏；后者保留内部诊断。`...-Info.xcresult` 12 项通过，覆盖 2–9 帧标识持久化及原滤镜诊断。此前无滤镜详情路径绕过隐藏集合导致的 8 条去重断言已针对性修复。
- 运动缩短、追加至第二批时退出取消（零交付）、返回普通拍照及 4 轮快速开关通过；不写系统相册，无模拟器/镜像，无 AV 会话运行错误。九帧自然极暗环境及长期温升/功耗未验收。完整用例、真实与注入条件的区分及中间失败记录见 [专项验证](Test-Reports/2026-10-24-Night-Adaptive.md)。

正常版本 `/private/tmp/LumaCamera-Night-Adaptive-FinalApp.log` 构建成功，已按项目原签名安装并在 iPhone 启动 `com.shurrikann.LumaCamera`。正常包不包含测试插件；临时诊断照片未写系统相册。

## 2026-10-24 夜景出片速度优化

- 保持 3/6/9 张数、配准/遮罩尺寸、曝光归一、运动保护及降噪配方，仅优化探针连续内存、直接 bitmap 渲染、单位增益探针复用和逐像素遮罩写入，保留无有效输入的安全回退。没有更改 UI、普通照片编码或切镜规则。
- iPhone 17 Pro / iOS 27.0.1、原签名 Debug：完整六帧（前/后各 2 次）3.616/3.829→3.193/2.596 秒，九帧（各 2 次）5.245/5.236→3.494/3.602 秒；六/九帧融合准备阶段中位分别 2.563→1.532、4.060→2.424 秒，约减少 40%。总回调还包含实际曝光，不能保证固定时长或外推 Release。3 帧单次 1.805→1.043 秒仅作记录。
- 三档优化前后各 1200 通道网格采样最大差值均 0；最终 `/private/tmp/LumaCamera-Night-Speed-Final.xcresult` **11 项通过、8.136 秒**，覆盖像素参考、降噪/运动/部分与单帧回退、全部照片比例横竖编码、透明无效探针、真实在途第二批取消及普通拍照恢复、信息帧数持久化。未写系统相册，无模拟器/镜像，无会话运行错误。
- 中间一次路线变化导致六帧缩成三帧（未作为六帧速度样本）；另一次停止原因文本的稳定性断言已改为核对真实运动评估及采集数量。保护条件未放宽。基线与优化轮 footprint 含 XCTest，不能据其变化宣称纯 App 内存降低。完整样本、像素参考来源和边界见 [提速专项](Test-Reports/2026-10-24-Night-Speed.md)。

正常版本 `/private/tmp/LumaCamera-Night-Speed-FinalApp.log` 构建成功，已按项目原签名安装并在 iPhone 启动 `com.shurrikann.LumaCamera`。测试插件与像素参考不包含于正常应用包。

## 2026-10-29 夜景亮度差异与公开能力对齐

### 实际文件观测

- 对比文件为用户提供的同一黑暗房间样张，未将取景位置差异作为原因。系统相机 `IMG_2473.heic` 为 Display P3、3024×3024、1 秒、ISO 4000、曝光补偿约 +0.06 EV；元数据标记合成图像，记录 4 个来源，来源曝光包含约 0.853 秒与最长约 3.413 秒。
- 光屿 `Luma-B8FA...HEIC` 为 sRGB、2997×3996、0.5 秒、ISO 3200、约 +1.00 EV；`Luma-C7C...HEIC` 为 sRGB、3000×4000、0.5 秒、ISO 3200、约 +1.09 EV。两张数值都命中旧版 A 挡夜景的 0.5 秒和约 +1 EV 上限。
- 将三张文件解码为 sRGB 后做全图亮度统计：系统相机平均/中位/95% 分位约 0.306/0.300/0.672；光屿 B8 约 0.176/0.184/0.370；光屿 C7 约 0.101/0.102/0.237。该统计受构图内容影响，不能单独证明曝光因果；与真实 EXIF/合成来源及旧代码上限共同使用，支持“采光与影调不足”判断。

### 修改与验证

- A 挡自动夜景上限由单帧 0.5 秒、最多 2 倍曝光提升为单帧 1 秒、最多 4 倍曝光；硬件范围仍是最终边界。`AVCapturePhotoOutput` 在会话启动前将最高允许优先级准备为 `.quality`，A 挡夜景逐请求使用 `.quality`，M 挡与自定义曝光保持 `.speed`。
- 仅对至少两帧真实融合成功的 A 挡结果启用自适应影调：64×64 探针以中位亮度 0.28 为目标，同时限制 95% 分位不超过 0.82，曝光补偿上限 1.25 EV；随后按暗度调整阴影曲线。单帧后备、M 挡和普通照片不走该全局补偿。
- iOS 27.0 模拟器定向测试 17 项通过、0 失败，测试时间 9.552 秒。320×240 确定性夹具 12 次：新自动影调/融合中位 149.6 ms、P95 153.4 ms；标准融合中位 141.8 ms、P95 145.1 ms；暗部通道标准差 7.240→2.071。该耗时不是 1200 万像素吞吐、屏幕帧率或 Release 真机性能。
- 连接的 iPhone 17 Pro 定向真机测试 3 项通过、0 失败，总计 25.903 秒。注入 1 秒/ISO 3200 计划后，三张真实来源依次记录 0.5/1.0/1.0 秒，ISO 均为 3200，保存代表帧为 1 秒/ISO 3200；A 挡请求诊断为 `.quality`。重复样本回调约 3.192、4.461、4.856 秒；另三次强制三帧融合回调 2.903、2.795、3.017 秒，中位 2.903 秒。回调耗时包含真实曝光及系统处理，不是固定承诺。
- 稳定性覆盖 4 次快速开关夜景、相机停用/恢复、随后普通拍照以及追加/回退路径；临时照片只进入内存服务替身，待保存数不变，未写系统“照片”App。
- 通用 iOS 设备目标（iPhoneOS 27.1 SDK、关闭签名）完整构建成功。首次沙箱内构建仅因 Metal 模块缓存目录无写权限失败，授权缓存写入后同一命令通过；该环境失败不计为产品代码失败。

### 官方依据、推断与剩余限制

- Apple 官方公开能力允许包围曝光逐帧指定时长/ISO，并允许照片输出预先声明最高质量优先级、逐请求选择质量优先；`.quality` 可能让系统优先低光细节与降噪，但不等于系统“相机”App 的私有夜景管线。
- “旧版曝光上限是本批样张偏暗的主要原因”是依据文件与代码一致性作出的工程判断，不是 Apple 平台保证。系统相机多帧选择、合成、色彩和语义影调的内部实现未公开，项目不能声称复刻。
- 修改后尚未在用户原黑暗房间重拍三张主观对照，也未验证所有镜头、手持运动题材、长时间温升/功耗和全分辨率影调耗时；这些项目保持未验收状态。

## 2026-10-29 HEIF Pro HDR 层次与极影公开方案对比

### 用户文件与问题复现

- 同源文件 `Luma-452D63...DNG` / `.heic` 来自 iPhone 17 Pro、iOS 27.2，实际曝光均为 1/50 秒、ISO 400。DNG 为 4032×3024、16-bit 解码、Display P3；HEIC 为 3000×4000、10-bit BT.2100 PQ，Core Image 报告内容 headroom 约 4.926。配方记录为 HDR、自适应显影、清新明亮、无额外曝光/滤镜参数。
- 统一转换至 SDR 观察时，HEIC 对两处灯光有高光保护，但顶棚、墙面、百叶窗及桌面区域的黑位/局部反差低于 DNG。DNG 经与产品相同的 `CIRAWFilter` 设置统计：p02 约 0.0117、中位 0.1437、p90 0.7319、p99.8 15.1166；旧自适应策略全局增益为 0，但深暗增益约 0.704 EV。该结果与“灯泡压制尚可、其余层次不如 DNG”的用户观察一致。
- 该底片的 RAW 解码器默认 `sharpnessAmount=1.0`、`detailAmount=0.5`，两项均支持。旧 HEIF Pro 只把 sharpness 设为 0，因此官方定义的边缘细节增强仍存在，不能称为完全无锐化。

### 参考视频中的公开行为

- 对用户提供的 518.266 秒极影介绍视频抽取 121 个分布/密集关键帧并用 Vision 识别画面字幕。视频明确展示或描述：ProRAW 管线输入、内部关闭锐化、定制滤镜、最高 48MP HEIF Pro、HDR 开关、四种亮度曲线影调，以及系统/全局/点测光。
- 视频称其 HEIF Pro/JPG Pro 为自研渲染管线，并展示网络平台 HDR；这些属于视频公开陈述，不足以证明具体曲线、编码元数据、增益图/PQ选择或私有实现。没有使用反编译、抓包或把宣传说法写成技术事实。
- 光屿已有同类公开能力：ProRAW/Bayer RAW 按设备回退、12/48MP、10-bit PQ、四种影调、三种测光、滤镜 HDR 余量恢复。光屿额外将 DNG 作为同一 PhotoKit 资产的 alternate photo，并在 HEIC 中保存可重新显影配方；参考视频未展示这两项。

### 修正与验证

- HDR `AdaptiveDynamicRenderer` 不再使用为 SDR 逆光场景设计的 `shadowEV/deepShadowEV`，输入低于参考白的黑位和中灰保持 RAW 显影基准；参考白以上继续使用原连续肩部并保留大于 1 的 PQ 高光。SDR 自适应暗部恢复不变。
- HDR“清新明亮”曲线由 SDR 的 `[0.04, 0.38, 0.62, 0.82, 1]` 分离为 `[0, 0.30, 0.55, 0.79, 1]`，饱和度由 0.86 调为 0.94；因此黑点保持 0，中灰只轻抬。自然、电影、高对比和全部 SDR 曲线保持原定义。
- RAW 捕获与重新显影两条 HEIF Pro 路径在能力支持时都设置 `sharpnessAmount=0`、`detailAmount=0`；用户后续主动设置的编辑锐化仍在 RAW 解码之后执行。
- iPhone 18 Pro / iOS 27.0 模拟器定向测试 5 项通过、0 失败，执行 1.481 秒；覆盖曲线单调、HDR 扩展高光、HDR 清新明亮保黑/受限中灰、SDR 深暗恢复保留和 PQ 暗部/中灰不变。2.88MP GPU 渲染 6 次为 51.2/14.5/13.8/15.2/24.5/14.8 ms；首样本含预热，不是屏幕 FPS、全分辨率真机吞吐或发布性能。
- 连接的 iPhone 17 Pro 真机两项通过、0 失败，测试执行 13.924 秒。真实 HEIF Pro HDR 四影调正反顺序共 8 张，均为 3000×4000、10-bit、BT.2100 PQ，EXIF 保留；回调耗时首张 2.208 秒，其余约 0.840–0.890 秒，中位 0.862 秒。快速影调切换 40 次和相机恢复通过，待处理任务归零。
- 真机非 HDR 逆光回归中，系统 RAW/修正/实际 HEIF 中位约 0.2115/0.2115/0.2094，白点约 0.7518/0.7383/0.7305；证明 SDR 原有基准未因 HDR 修正整体改变。测试照片仅保存在捕获回调/附件中，未写系统相册。

### 依据与限制

- Apple 官方将 `sharpnessAmount=0` 定义为不施加锐化，将 `detailAmount=0` 定义为不施加边缘细节增强；两者是不同控制项。`localToneMapAmount` 默认值随底片变化，本次仍保留底片默认值，不因参考视频改成固定常数。[Sharpness](https://developer.apple.com/documentation/coreimage/cirawfilter/sharpnessamount)、[Detail](https://developer.apple.com/documentation/coreimage/cirawfilter/detailamount)、[Local tone map](https://developer.apple.com/documentation/coreimage/cirawfilter/localtonemapamount)
- Apple 说明线性 HDR 的 1.0 是参考白，峰值可到内容 headroom；本次“只在参考白以上做 HDR 肩部”是结合用户目标的项目策略，不是 Apple 规定的唯一影调。[Apple HDR effect](https://developer.apple.com/documentation/appkit/applying-apple-hdr-effect-to-your-photos)
- 原办公室灯光场景尚未用修改后版本重新拍摄；真机环境也未覆盖极端灯泡 headroom、所有镜头/48MP、社交平台上传读回、长期温升与功耗。不能写成已与极影画质等价或已验证所有平台 HDR 展示。

## 2026-10-26 拍照子模块虚拟光圈入口与三列布局

- 照片拍摄模式弹窗新增“虚拟光圈”占位入口，图标 `camera.aperture`；点击调用 `showVirtualApertureStatus()`，只提示“虚拟光圈功能尚未开放”，没有实现光圈/景深功能。
- 子模块选项改为 3 列 `LazyVGrid`：照片 6 项两行、视频 3 项一行；`ShootingModePanelLayout.panelHeight(for:)` 计算 74/158 点高度，原选项卡片和状态文字删除后的紧凑高度保持。
- `PopupAppearanceAndOrientationTests.testSubmodePopupUsesCompactOptionHeightWithoutStatusText` 通过，验证 3 项/6 项面板高度。iPhone 17 Pro 构建、安装、启动成功；未取得弹窗运行截图，虚拟光圈功能未实现。

## 2026-10-26 拍照子模块入口图标改为相机样式

- 辅助拍摄按钮上方的子模块弹窗入口默认使用 `camera.fill`；选中子模块后跟随该功能的语义图标，关闭后恢复相机图标。
- 弹窗内部恢复原语义图标：慢门 `timer`、夜景 `moon.stars.fill`、人像 `person.crop.rectangle`、连拍 `square.stack.3d.up`；虚拟光圈 `camera.aperture`、智拍 `sparkles`。
- 名称、按钮尺寸、选中/禁用样式、三列布局和触控逻辑未改；视频子模块入口和弹窗图标未改。
- iPhone 17 Pro 构建、安装、启动成功；未取得运行截图，未新增 UI 自动化。

## 2026-10-29 手持流水及夜景/慢门预览

### 文件诊断与改动

- 用户流水样张 `Luma-C8A7DEC6...HEIC` 为 3000×4000、sRGB，实际 EXIF 为 1/15 秒、ISO 80、f/1.78、等效 48mm；静态墙面、灯和鱼缸边缘均有重复轮廓。结合旧流水直接平均而无整幅对齐的代码，判断帧间手持位移是本张整体模糊的重要原因；单张文件不包含完整源帧，不能排除源帧自身模糊，也不能从其 EXIF 推断整段采样时长。
- 流水改为全幅平移配准、相关性复核与不可靠帧拒绝；自动曝光优先不慢于 1/30 秒，保持测光曝光量且受硬件 ISO/快门限制，M 挡自定义数值保留。默认采样仍为 10 秒、可选 5/10/15 秒，并非单张曝光 10 秒。
- 夜景实际采用首批三张、评估后追加三张的原生请求结构；批次切换曝光帧导致黑闪是结合用户观察与预览未屏蔽该时段的工程推断，未获得逐屏像素黑帧录屏证据。现在从硬件提交前保留已有预览至最终硬件完成与路线恢复，渲染及发布两侧都拦截，恢复时废弃旧代次、旧时间戳并跳过两帧预热。融合处理期间恢复实时取景。
- 慢门支持手动静态包围时维持短曝光实时取景；必须临时切换曝光的回退路线才保留画面，统一完成/失败/超时/退出清理。没有通过缩短实际成片曝光来替代预览优化。

### 已执行验证

- Xcode 27.1 / iOS 27.1 SDK，通用 iOS 无签名构建通过。iPhone 18 Pro / iOS 27.0 模拟器曝光/合成定向 7 项通过，0 失败，执行约 2.109 秒。流水合成 5 张人工平移/异常纹理样本接受 4 张、拒绝 1 张；测试图像相对参考的误差指标由直接平均约 114.94 降为 0，合成内部约 0.489 秒。这是确定性纹理样本，不代表真实手持水面效果或全分辨率帧率。
- iPhone 17 Pro / iOS 27.2（24B119），流水完整采集与参数恢复、提前结束/取消重拍、JPEG 路线共 3 项通过，0 失败，执行 76.748 秒。三次完整序列各 28 张，实际源文件为 1/30 秒、ISO 160；源图交付跨度约 10.22–10.23 秒，含准备和编码的回调约 11.64–11.79 秒，最终编码约 0.21–0.37 秒，预览发布最大间隔约 0.148 秒。最终图约 12MP（对齐有效交集可能裁去少量边缘），最终文件 EXIF 已核对，诊断照片未写入系统相册。
- 同轮采样测试宿主 footprint 峰值约 458–497 MiB，包含 XCTest、框架与缓存，不能当作独立 App 内存，也不构成泄漏或长期稳定性结论。设备日志出现框架缓存 `MDB_MAP_FULL` 提示，测试仍完成；未将该提示当作画质或帧率指标。
- 夜景 3/3/6 张真实硬件连续采集、运动停止追加及追加批次取消后返回两项通过。最新跨批次断言版本的三次回调约 2.977/5.725/5.170 秒，真实曝光核对覆盖 1/8 秒 ISO 200 和 1 秒 ISO 3200；每批提交均处于预览保留，六帧的两次提交之间预览发布计数不变，结束后新帧继续发布。环境亮度、运动与曝光计划部分由测试注入，只证明硬件执行和生命周期，不冒充自然暗光画质验收。
- 慢门正常/回退路径交替四次真机采集通过。最终指标重跑把采集起点和观测终点纳入间隔，避免仅在恢复后发布几帧时低估停顿：正常路线预览发布最大间隔约 0.144/0.150 秒；回退路线保留画面约 2.695/2.731 秒；完成回调后的新帧恢复采样约 0.053 秒。保留画面期间并非实时取景，以上间隔是发布观测，不是显示 FPS。该次 1 项测试通过、执行 11.771 秒，亦覆盖退出返回；结果 `/tmp/LumaCamera-Handheld-DeviceDD/Logs/Test/Test-LumaCamera-2026.10.29_14-27-08-+0800.xcresult`。
- 最终退出回归 4 项通过、0 失败、0 跳过：包含两项预览状态/直方图基础回归、夜景取消返回和慢门四次交替采集后在回退曝光中退出/返回。夜景测试约 6.569 秒、慢门约 11.507 秒，取消没有增加照片，返回后取得真实新帧。结果 `/tmp/LumaCamera-Handheld-DeviceDD/Logs/Test/Test-LumaCamera-2026.10.29_14-25-12-+0800.xcresult`。

### 依据与未验收项

- Apple 官方公开手动包围曝光逐张指定 ISO/曝光时长与 Vision 平移配准能力；短曝光优先值、相关性/位移门限、保留预览与预热帧数都是本项目策略，不是平台保证。[包围曝光](https://developer.apple.com/documentation/avfoundation/capturing-a-bracketed-photo-sequence)、[平移配准](https://developer.apple.com/documentation/vision/vntranslationalimageregistrationrequest)
- 初轮夜景测试发现 DEBUG 批次通知早于预览保留标志，首批状态断言失败；启用保护移至通知前后重跑通过。初轮新增慢门测试在路线读数有效前按快门被应用拒绝，补上实际有效读数等待后四次采集通过，未通过放宽应用曝光校验掩盖问题。
- 自动化真机未由人工手持移动，也未拍摄原水流场景；强旋转、视差、大面积无纹理流水、单帧本身模糊、所有镜头和长时间温升功耗仍未验证。尚未取得人眼观看夜景屏幕全过程的录屏验收；上述跨批次发布不变及恢复断言不能替代最终主观体验。全预设均无条件可手持、与系统相机画质等价等结论均未作出。

## 2026-10-29 智拍点位闪现与移动滞后修正

### 代码依据与行为

- 旧跟踪器只显示`misses == 0`的目标，一次框/纹理失效即返回nil；ViewModel又在nil时重置稳定器，并通过`flatMap`绕过已有缺失宽限，导致间歇漏检直接闪现。旧点位还经过0.008死区、0.5低通和0.16秒UI补间，叠加250ms轮询，在移动取景时会显示在物体旧位置。以上为代码可确认的缺陷，未把用户实景的全部误差归因于单一条件。
- 跟踪轮询改为66ms、一次在途，场景检测以0.8秒节流；有目标时跳过显著性/人体框重新提名。有效对象框每次都继续官方序列，纹理可独立恢复；主体坐标直接发布。中心圈仍固定，提示/完成淡入淡出保留。
- 短漏检显示最多0.18秒、身份最多0.45秒，不再用3帧代表固定时长；模型对nil也调用显示稳定器，另有最多0.18秒显示宽限。仅预测/保留的点带`trackingVerified=false`，自动取景门控拒绝该状态，重新确认后重新计稳定时长。关闭场景建议不再暂停跟踪两秒。持续丢失最终隐藏，不能长期用屏幕上的旧点冒充物体跟踪。

### 真机结果与性能边界

- iPhone 17 Pro / iOS 27.2（24B119），Xcode 27.1 / iOS 27.1 SDK。最终功能组15项通过，0失败、0跳过，执行18.507秒，涵盖人工纹理移动/遮挡、目标UUID、缺失与提示迟滞、预测点不触发自动取景、真实自动变焦/对焦流程及取消、场景建议、真实预览轮询与全部画幅组件渲染。结果`/tmp/LumaCamera-Handheld-DeviceDD/Logs/Test/Test-LumaCamera-2026.10.29_14-50-56-+0800.xcresult`。
- 人工纹理平移24帧，每帧移动1像素并叠加垂直位移，同一UUID持续跟踪；最大归一化误差约7.85e-17（浮点近零），单目标跟踪中位8.53ms、p95约9.04ms。三候选静态重复12次，身份不随检测顺序改变，归一化漂移0，逐次约26.4–34.8ms。它们是运行在真机上的确定性图像输入，不是实际移动相机测得的贴合误差。
- 真实相机4秒窗口发布48个分析结果，其中4次场景检测；分析结果发布间隔中位66.99ms，非场景检测路径处理耗时中位5.61ms，请求分析图至发布最大550.46ms，包含初次/无目标重新提名。该实景可靠候选样本数为0，不能用5.61ms冒充带目标的跟踪耗时；更不能把发布间隔或处理耗时当作屏幕FPS。
- 真实预览关闭参数建议后0.55秒内仍持续发布，快速格式弹窗开关12轮清理引导，禁用后不再残留点位；另一真机自动取景用例覆盖一次真实变焦/对焦、30次重复对齐不重复执行、评分中打开弹窗取消、M挡不自动改参数。测试未向系统相册保存照片。
- 八种画幅各横/竖布局共16次真机组件渲染通过；快照绘制约21.2–43.4ms，只代表测试绘制耗时，不能作为实际动画帧率。点位不再补间，出现/完成淡入淡出仍沿用原有减弱动态效果策略。
- 早期扩大回归23项为22通过、1跳过、0失败，跳过项是自然实景未获得可靠稳定居中主体的自动取景拍摄用例。没有把跳过改成通过；最终定向15项没有包含该自然触发拍摄用例。实际手持移动时的点物贴合、尺度/旋转变化、反复遮挡、重复纹理、长时温升功耗与其他设备仍待现场验收。
- 最后补充“提示迟滞期间漏检不回跳旧坐标”修正，显示稳定器3项真机复测通过、0失败，执行约0.002秒；这是纯状态逻辑耗时，不是界面性能指标。结果`/tmp/LumaCamera-Handheld-DeviceDD/Logs/Test/Test-LumaCamera-2026.10.29_14-53-05-+0800.xcresult`。

Apple官方说明对象跟踪结果需要作为下一帧`inputObservation`延续，序列请求在后台执行；本次按该接口约定修正输入推进。66ms轮询、纹理阈值、显示与身份宽限都是项目策略，不是苹果对跟踪成功率的保证。[官方对象跟踪示例](https://developer.apple.com/documentation/vision/tracking-multiple-objects-or-rectangles-in-video)、[inputObservation](https://developer.apple.com/documentation/vision/vntrackingrequest/inputobservation)。

## 2026-10-29 智拍点位短过渡及对齐后无效果

用户复测确认点位比前版固定，但移动时仍呈阶梯跳动、对齐后看不到效果。本节补充上节，不将上一轮的“取消全部位置补间”视为最终显示策略。

- 推荐点仍使用原始确认坐标，显示层仅增加45ms线性位置过渡，替代66ms采样间隔下的直接跳变；选中点按UUID重建，换对象不跨身份插值。系统减弱动态效果开启时不做位置过渡，圈位置固定。A挡可靠点进圈即显示对齐颜色，不再等自动流程结束才着色。
- 代码确认两条无效果路径：单帧未确认会让0.75秒稳定计时反复归零；美学评分为空时先`gate.finish()`再返回，既没有对焦/反馈又封住本轮。现在短漏检及圈边15%内轻微越界最多暂停0.20秒，暂停时间从有效稳定时长扣除，只有重新确认且实际进圈才能触发；相邻确认帧比较允许缓慢圈内漂移。持续丢失、大幅运动、取消仍重置。
- 无评分结果保持倍率、仍提交对焦和完成反馈，只有变焦稳定并提交对焦后才封住本轮。此完成状态不意味着已读取硬件合焦确认；暗光、无纹理或镜头能力仍可能使实际自动对焦失败。M挡只参考的规则不变。

### 真机验证

- iPhone 17 Pro / iOS 27.2（24B119），Xcode 27.1 / iOS 27.1 SDK。第一组13项通过、0失败、0跳过，执行21.645秒；第二组4项通过、0失败、0跳过，执行8.662秒。合计17个不同方法有通过记录。结果分别为`/tmp/LumaCamera-Handheld-DeviceDD/Logs/Test/Test-LumaCamera-2026.10.29_14-58-06-+0800.xcresult`与`/tmp/LumaCamera-Handheld-DeviceDD/Logs/Test/Test-LumaCamera-2026.10.29_15-01-23-+0800.xcresult`。
- 无评分结果注入3轮：稳定对齐开始至反馈出现约1.095/1.060/1.078秒，包含测试等待的0.8秒、系统爬坡检查及调度；倍率不变，每轮只执行一次，后续共60次重复对齐不重复执行。退出智拍清除完成/反馈状态，正常有推荐倍率的硬件流程和弹窗取消亦通过。照片未写系统相册。评分为空是注入条件，不冒充自然场景评分失败复现；测试核对对焦路径和完成状态，不保证真实焦平面清晰。
- 手持门控确定性回放30个15Hz输入，包含圈内缓慢漂移和每4帧一次未确认，最终完成一次且未确认帧不触发。补充短边界越界暂停、持续失踪重计时，以及原有稳定/取消/离开主体门控回归通过。
- 8种画幅×横竖2种×减弱动态效果输入2种×点位2处，共64次真机组件快照检查通过：90ms观察窗口后点位落在新坐标，旧点位无残留，中心圈仍在原位。快照绘制中位约29.47ms、最大48.29ms；仅为测试截图绘制，不是显示FPS或实测45ms动画时长，也不能证明真实手持运动观感已验收。减弱动态效果值直接传入内容组件，正式入口仍读取系统只读偏好；未修改用户系统设置。
- 实际相机4秒窗口发布49个分析结果，5次场景检测，其中2个结果包含可靠候选；发布间隔中位67.53ms，非检测路径处理中位5.71ms，图像请求至发布最大657.70ms（含无目标重新提名）。可靠候选样本不足以证明实际手持贴合精度。12次快速弹窗开关、关闭建议继续跟踪、停用清理通过。人工纹理移动24帧仍保持同一身份，误差浮点近零，处理耗时中位8.61ms/p95约9.11ms。
- 当前没有原场景的连续屏幕录屏/人工移动目视对照，也未测显示帧率、长期功耗和温升。强旋转、遮挡和重复纹理仍可能失去锚点；45ms过渡增加少量显示延迟，取景资格和对焦位置始终使用未经显示补间的真实确认坐标。

官方公开`linear(duration:)`指定匀速动画时长，Vision美学评分用于评价图像属性；本项目45ms显示策略、计时容错和无评分时保留倍率并对焦均为产品实现选择，不是平台保证。[线性动画](https://developer.apple.com/documentation/swiftui/animation/linear(duration:))、[美学评分](https://developer.apple.com/documentation/vision/vncalculateimageaestheticsscoresrequest)。

## 2026-10-29 M挡智拍、持续点位、同场景拍后恢复及端侧语义

### 用户确认与当前行为

- 用户确认一直在M挡使用。此前`smartAutomaticAllowed`明确限定A挡，因而A挡修复/测试不能覆盖该场景。用户随后明确授权M挡自动调整倍率和焦点，但保留ISO、快门和白平衡。现在A/M均允许智拍；M挡完成时只释放手动焦点标志并提交AF，等待过程中校验原挡位，切挡/弹窗等使旧工作失效，不切到A挡绕过。
- 用户最终取消“明显换场景后再显示”的要求：未对齐、未拍照时持续显示仍有效的候选；完成对齐只在1.6倍圈半径容差内隐藏，超出即恢复，不加场景判断或退出等待。圈内轻微手抖不会反复触发；未确认位置不能触发自动取景。
- 相机只在真实CapturedPhoto成功按快门顺序交付时递增`deliveredPhotoRevision`，模型据此清除完成/反馈并开启下一轮，保留仍有效点位；同场景拍完不需要挪开。主选漏检时还有其他有效候选也会显示，避免整个覆盖层消失。拍摄时隐藏点位；照片失败不按成功处理。
- 多点选择另有独立缺陷：旧0.15锁定区可能让圈外旧目标挡住圈内另一点。现在任何实际进圈的可靠候选优先，同一批改选另一ID可重新执行；AI偏好也不能抢走用户已对齐的对象。点位显示继续45ms短过渡，减弱动态效果时关闭位置补间。

### 实际真机验证

- iPhone17Pro / iOS27.2（24B119），Xcode27.1 / iOS27.1 SDK。最终完整组20项通过、0失败、0跳过，执行33.128秒；最后队列隔离/标签完整词匹配/过期建议补测16项通过、0失败、0跳过，执行23.060秒。两组有重叠，不相加为36个独立方法。结果：`/tmp/LumaCamera-Handheld-DeviceDD/Logs/Test/Test-LumaCamera-2026.10.29_15-36-09-+0800.xcresult`、`/tmp/LumaCamera-Handheld-DeviceDD/Logs/Test/Test-LumaCamera-2026.10.29_15-40-19-+0800.xcresult`。
- M挡受控点位/评分三轮实际取景、对焦、JPEG捕获通过，同场景原地拍完重新引导3次；前两次回到原场景的额外移开动作已从最终测试移除。完整组对齐至反馈约1.069/1.089/1.076秒，倍率为1/1.15/1.3225倍，其中首轮评分为空仍对焦且不放大。设备实际处于custom曝光，AF模式开启、焦点在中心，前后ISO/曝光时长和WB RGB增益未变；三张真实JPEG均为ISO200、1/125秒、EXIF WhiteBalance=1。只通过捕获回调读取数据，没有写系统相册。
- 同一批两个候选连续对齐两轮通过；改选进圈点时重新显示2个候选，主选nil但其他候选仍有效时覆盖层显示入口不为nil。M挡完成组件实际渲染中心点为橙色，附件`Smart-M-completion-feedback`。评分中打开格式弹窗取消后，倍率/手动焦点保持、没有迟到执行。人工框/评分是注入条件，不当作自然场景检测准确率。
- 全画幅与横竖布局、两种减弱动态效果输入共64个组件端点快照通过，点到新坐标、旧点无残留、中心圈固定；绘制中位30.31ms、最大39.85ms，只是测试快照耗时。人工纹理24帧跟踪误差浮点近零，中位8.23ms/p95约8.72ms。真实预览4秒45个分析结果，发布间隔中位67.53ms，非检测路径处理中位5.35ms，请求至发布最大872.83ms；本窗口可靠候选为0，不能冒充目标跟踪精度或屏幕FPS。12轮快速弹窗开关、建议关闭继续跟踪和禁用清理通过。
- 早期M挡文件/硬件检查已通过，但新测试错误地把跨方法累计操作计数5与硬编码3比较，导致一项失败；改成相对本方法起始计数后重跑通过。没有放宽曝光/WB断言。后续用户取消换场景要求时，相应等待转场的门控测试同步改为容差/拍后事件规则。

### 端侧AI接入与限制

- 新增`SmartLocalCompositionAI`，单在途actor每批候选低频分析一次，和实时跟踪分离。无需训练/自带权重的系统Vision预训练分类分析全景与候选裁切，分类标签、置信度结合现有人物检测形成主体优先级及保留环境建议。标签按完整词/词组匹配，避免`cat`之类片段误命中其他单词。分类到摄影推荐的权重是项目规则，不等同已训练专属审美模型。
- iOS27另适配Foundation Models端侧图像理解与Generable结构化输出，只允许已有候选索引与保留环境，置信度低于0.7、无效索引/UUID、过期上下文、用户已开始对齐处理或超过3秒的新鲜度预算均不应用。系统模型不可用/失败时使用Vision分类；没有PCC、云API、网络图像上传或模型包下载。模型只建议，实际进圈选择优先。
- 当前真机实际返回`unavailable(...deviceNotEligible)`，因此系统大模型的图像生成/语义输出没有实跑通过，也不将其推断为某一具体地区、开关或芯片限制。编译与不可用分支通过不代表大模型效果验收。
- 兼容Vision分类真实预览3次实际执行：完整组约55.23/37.52/43.87ms；最后词匹配/队列补测约33.56/31.62/46.44ms，中位33.56ms。各次包含全图和一个受控候选裁切，首次完整图分类日志采样不计入该耗时。返回`structure`、`material`、`portal`等标签，最高置信度约0.16–0.18，未达到当前门限，所以3次都保守保留原推荐、没有强行接受语义建议。它证明模型在设备上运行与保守回退，不能证明已提高构图审美。
- 取消3次请求均返回无建议；纯策略测试拒绝无效索引、NaN/无穷/低置信度输出，AI偏好不能覆盖用户已进圈目标。跟踪器验证旧context/不存在UUID的建议不应用，合法建议保留目标身份且正确传递保留环境标志。
- 测试发现原场景缓存跨MainActor读写和跟踪引用Sendable警告，已改为仅由智拍串行队列访问的`SmartSceneAnalysisState`，跟踪器同样明确仅该队列持有可变状态。最终重编译未再报告这些智拍隔离警告。日志仍有系统框架缓存`MDB_MAP_FULL`提示，测试未因此失败，不能把提示当作应用内存/性能测量。
- 尚未覆盖多种真实摄影题材的分类准确率、审美偏好对照、全镜头/高像素格式组合、长时温升/功耗和系统大模型可用设备。没有采集训练集、训练/微调模型或上传照片；未来专属摄影审美模型需要独立样本与评价，不能把当前分类接入写成已具备摄影师审美。

依据：Apple说明Vision提供预训练视觉模型，分类返回标签与置信度，需按任务权衡精确率/召回率；本项目分类阈值、排序、容差及拍后重置均为应用设计。[Vision](https://developer.apple.com/documentation/vision)、[分类示例](https://developer.apple.com/documentation/vision/classifying-images-for-categorization-and-search)、[端侧系统模型可用性](https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel)。设备曝光、对焦分别核对真实状态，照片检查真实EXIF，而非详情页文字。[自定义曝光](https://developer.apple.com/documentation/avfoundation/avcapturedevice/setexposuremodecustom(duration:iso:completionhandler:))、[对焦点](https://developer.apple.com/documentation/avfoundation/avcapturedevice/focuspointofinterest)。

## 2026-10-29 智拍快速隐藏及近物边缘反复拉焦

用户追加反馈白点隐藏慢，并确认远近反复拉焦在未对齐取景及对齐后都会发生。本节替代原“完成后实心点停留1.1秒”行为。

- 代码确认原白点隐藏依赖smartFramingComplete，串联0.75秒有效稳定、评分与变焦/对焦提交；完成还会显示实心点1.1秒。现在UI确认对齐0.18秒后100ms淡出（减弱动态效果60ms），硬件触发仍0.75秒；完成仅留空心圈250ms。未对齐持续显示、对齐手抖容差、拍后重显与M挡自动取景规则保留。
- 原智拍focus沿用continuousAutoFocus，框边纹理模板可能混入前后景。现在模板中心内缩、AF采样点限制框内12%；首次稳定可靠候选在没有手动焦点/用户锁时做一次预览AF，对齐后也单次AF。观察实际扫描开始/结束，再切locked保持，不采用距离阈值、定时重复AF或强制换镜。普通点焦与手动焦点仍能接管，退出智拍归还连续AF。

### 最终真机结果

- iPhone17Pro / iOS27.2（24B119），Xcode27.1 / iOS27.1 SDK。最终17项通过，0失败、0跳过，执行42.484秒；结果`/tmp/LumaCamera-Handheld-DeviceDD/Logs/Test/Test-LumaCamera-2026.10.29_16-09-07-+0800.xcresult`。
- 日志`/tmp/LumaCamera-SmartFocus-ReleaseFinal.log`记录最终结果与所有指标。覆盖预览AF获取与保持、A/M取景/取消、手动控制与普通点焦、三张实际JPEG、主选/多点、纹理锚点、AF安全投影、白点提前隐藏以及既有AF锁偏好/布局/真机锁定流程。没有向系统相册写诊断照片。
- 提前隐藏受控点位3次，在66ms采样节奏下确认时刻约0.200/0.207/0.202秒，且确认时自动取景尚未启动。32个真机组件快照覆盖8种比例×横竖×两种动态效果输入，白点中心已暗、固定圈仍可见；快照绘制最大约28.11ms。这是状态确认时间和最终像素检查，未测屏幕FPS或真实逐帧淡出时长；名义100ms淡出由代码指定。
- 预览AF测试给出框边受控候选、真实硬件执行：一次AF请求，保持后12次、约100ms间隔采样，全部focusMode=locked；lensPosition均为0.77254903，峰峰差0。一次isAdjustingFocus迟到为true，其余最终窗口均false，镜头位置并无对应运动。包含取景输入、等待与采样的流程约2.858秒，不等于AF获取时间。
- 参数恢复没有重新开启持续AF；关闭智拍恢复continuousAutoFocus，手动焦点可锁定，普通点焦恢复原连续AF，均通过。A/M切换和评分中打开弹窗取消通过；用户AE/AF锁回归未被智拍保持覆盖。
- M挡三轮对齐至提交完成反馈约1.072/1.083/1.074秒，倍率1.44/1.656/1.9044（本组沿用前序测试起始倍率）；每轮只增加一次最终对焦请求。同场景拍后重显3次，真实JPEG均ISO200、1/125秒、手动WB标记，硬件曝光与WB增益保留。
- 框边AF安全点单测验证不修改显示锚点，先框内收缩再变焦投影；真实竖屏采样点从显示(0.348,0.5)映射为传感器(0.5,0.652)，实际硬件读数符合。固定纹理移动、空白拒绝及候选身份回归通过。

### 过程观测与边界

- 初版只用autoFocus时，12次采样仍看到扫描及lensPosition约0.714–0.812变化，不能仅凭“单次AF模式”宣称不再来回搜索；因此补上实际扫描结束事件后的保持。首次保持测试因严格要求所有采样isAdjustingFocus=false失败，但镜头位置12次完全相同、模式均locked；最终采用实际镜头位置范围与末6次状态共同验收，保留该迟到状态观测，没有隐藏数据。
- 一次测试编译因在XCTest同步断言自动闭包内直接await读取硬件失败，改为先异步取值再断言后通过。组件测试仍有部分“未安装View读取减弱动态效果默认值”警告；两种动态效果的端点验证通过显式参数输入覆盖，正式组件入口读取实际环境。系统缓存/运动服务诊断日志不当作应用内存或渲染指标。
- 当前测试是受控推荐点＋真实相机硬件和固定场景，未由人工反复摆放近物/远背景或精确测量AF正确合焦率。框内安全区不等于前景蒙版，虚焦、极低纹理、遮挡、首次AF扫描时的光学视角变化及所有镜头/自动微距组合仍需实景验收；不能写成消除所有光学呼吸。语义、曝光等其他正常功能未因此改为固定焦距或强制主摄。

Apple将autoFocus定义为一次自动对焦后保持，continuousAutoFocus为持续监测，isAdjustingFocus用于观察调整状态；本项目额外在实际扫描结束后保持及内部点位策略是工程选择，不是保证每次正确合焦。[FocusMode](https://developer.apple.com/documentation/avfoundation/avcapturedevice/focusmode)、[官方采集/对焦说明](https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/AVFoundationPG/Articles/04_MediaCapture.html)。

## 2026-10-29 中远景推荐偏好

用户要求推荐点偏向中远景。新增范围策略依据当前物理主用镜头稳定焦位及系统微距，近端收点、远端恢复；不把主体框面积当实际距离，不增加距离驱动切镜。Apple的lensPosition说明0为最近端、1为最远端，并不映射固定距离；minimumFocusDistance是设备能力而非当前测距。阈值0.35/0.50、0.25秒确认均为项目工程选择，未按米校准。[lensPosition](https://developer.apple.com/documentation/avfoundation/avcapturedevice/lensposition)、[minimumFocusDistance](https://developer.apple.com/documentation/avfoundation/avcapturedevice/minimumfocusdistance)。

### 实际验证

- 设备iPhone17Pro / iOS27.2（24B119），Xcode27.1。最终定向9项通过、0失败、0跳过，36.722秒；日志`/tmp/LumaCamera-SmartMidFar-Verified.log`，结果`/tmp/LumaCamera-Handheld-DeviceDD/Logs/Test/Test-LumaCamera-2026.10.29_16-29-45-+0800.xcresult`。仅维护主项目，无系统相册诊断写入。
- 纯策略1000轮、4000个新样本，2000次期望状态转换通过，总耗时约0.445ms；这是纯策略执行时间，不是应用FPS/端到端延迟。另100次同时间样本不能伪装稳定、20次灰区变化不闪点、扫描中不确认、非法读数/设备变化/系统微距路径通过。
- 模型受控近远恢复2轮；占画面90%的远景框仍保留。启动真实取景任务并注入600ms延迟评分，近端切换清空点/取消任务，等待700ms后无迟到变焦和提交；再次远端恢复、微距立即隐藏通过。这些距离信号是注入值，不是实物距离测量。
- 真实预览450ms间隔8次采样，得到8个不同单调时间戳、有效物理设备身份，当前主用镜头焦位均0.65098035；确认真实读数链路，不表示该值对应某个米数。真实分析85次，发布间隔中位67.93ms，非场景重检处理中位2.08ms，请求至发布最大约0.801秒；固定场景没有可靠跟踪点（verifiedSamples=0），因此不宣称这组测得实际跟踪准确率。重复弹窗开关12轮、关闭智拍与取消路径通过。
- 既有回归：M挡3张真实JPEG保存ISO200、1/125秒及手动WB信息，硬件参数保持；同场景拍后重显3轮，对齐完成约1.061/1.080/1.072秒。单次AF一次请求、最终12次焦位均0.34117645且模式locked，末6次不扫描，普通点焦/手动焦点/退出交还通过。
- 提前收点3次约0.212/0.213/0.218秒；32个组件端点覆盖8比例×横竖×两种动态效果，最大快照绘制38.74ms。仅端点像素和状态时序核对，不是屏幕FPS或实际动画逐帧测量。

### 过程及剩余限制

- 首轮9项中范围4项通过，但AF测试两秒等待超时；第二轮实际观察完成约2.267秒，因此改为有10秒上限的事件状态等待，保留后续严格保持检查，最终约2.063秒完成。未改成定时强行锁焦或放宽镜头保持判据。
- 第二轮M挡比较错误地在实际硬件尚未应用时取了初始基线（ISO约12709、1/15.8秒，与请求ISO200、1/125秒不同）；改为核对真实请求曝光到位及WB连续3样本稳定后才取基线，最终9项全通过。其余测试断言保留。系统缓存MDB_MAP_FULL及组件未安装环境值警告仍有记录，不当作应用内存/帧率指标。
- 当前为画面焦位代理，无法区分同一画面内各候选的独立距离。前景合焦可能连远背景推荐一起暂停；焦点保持期间也不能仅凭焦位知道新近物进入，未知/固定焦点设备保守不出点。未用人工移动实物完成近中远、所有焦段和照明条件的距离分布/召回率测试，不能宣称“几米以内绝不推荐”或所有实景已验收。系统自动微距仍由虚拟多摄控制。

## 2026-10-30 源码警告清理与48MP焦段按钮

### 警告与构建

- 新独立DerivedData完整build-for-testing基线日志`/tmp/LumaCamera-Warnings-Baseline.log`：应用源码15处、测试源码15处警告，另2条App Intents元数据工具提示。已修正双拍手势Coordinator的MainActor隔离、4处嵌套弱捕获的外层显式引用、未用变量、双拍旧方向API和测试同步取帧API；原生诊断探针依据串行配置队列及锁说明unchecked Sendable边界，前置共享预览/回调以锁保护。
- 修复后Debug应用和全测试目标build-for-testing成功，源码警告0；日志`/tmp/LumaCamera-Warnings-After.log`。仍有2条Xcode appintentsmetadataprocessor提示“Metadata extraction skipped, no AppIntents.framework dependency found”，没有用关闭Swift警告、降低并发检查或添加无用途依赖来掩盖。
- 补查Release发现既有正式调用afterPendingSessionTasks，但定义处在DEBUG区，编译器在两个Task表达式报failed to produce diagnostic；已将会话等待接口移出DEBUG。最终Release成功、源码警告0，工具提示1条（仅应用目标），日志`/tmp/LumaCamera-Focal48-Release.log`。没有把DEBUG构建通过当作Release通过。
- 官方依据：UIKit的[UIGestureRecognizer](https://developer.apple.com/documentation/uikit/uigesturerecognizer)具有MainActor隔离；AVFoundation以[videoRotationAngle](https://developer.apple.com/documentation/avfoundation/avcaptureconnection/videorotationangle)替代旧方向属性。iOS27继续原设备方向协调路径，旧版本回退保留90°竖屏语义；本轮硬件为iOS27.2，没有实测iOS18–26回退。

### 警告相关回归

- iPhone17Pro / iOS27.2（24B119），Xcode27.1。初轮18项：16通过、1跳过、1失败，166.571秒；跳过项明确是模拟器专用A/M工具布局，不算通过。日志`/tmp/LumaCamera-Warnings-Regression.log`，结果`/tmp/LumaCamera-WarningAudit-DD/Logs/Test/Test-LumaCamera-2026.10.29_16-36-09-+0800.xcresult`。真机启动曾等待解锁，用户解锁后继续。
- 通过项覆盖刻度快速拖动/抖动、双拍能力矩阵、前后源合成及转码后解码、原生拖动100次/双击/单击、30个合成像素样本跨五视频比例、三次录制/交换/停止/退出。三轮双拍进入约0.597/0.608/0.647秒，退出约0.653/0.571/0.603秒；文件1080×1920、时长约1.45/1.47/1.43秒且有音轨。记录的是进入/恢复延时和文件读回，不是屏幕FPS或应用内存。
- 失败项是智拍对焦测试在共享相机模式切换尚未就绪时调用toggle，实际上未打开智拍；补上会话栅栏、有限重试并先断言smartCaptureEnabled后再注入点，后续真实硬件回归通过。未删去对焦保持判据。最终12次镜头位置均0.372549、模式locked，末6样本无扫描；单次AF等候约1.937秒，普通控制交还正常。
- 原生诊断2项通过、0失败、0跳过，28.311秒，日志`/tmp/LumaCamera-Warnings-DiagnosticRegression.log`，结果`/tmp/LumaCamera-WarningAudit-DD/Logs/Test/Test-LumaCamera-2026.10.30_09-00-01-+0800.xcresult`。前置缓冲900×1200/900×675与照片3024×4032/4032×3024读回通过；长曝光退出3轮均恢复短曝光帧，记录真实交付延时，不据此宣称原生曝光恢复即时。

### 焦段禁用原因及修改

用户明确实际问题是48MP下底部0.5×/1×/2×等按钮，而非转盘。代码canSelectFocalLength存在photoResolution==high时统一return false，是项目限制。当前A挡48MP绑定后置物理主摄1×的工程策略，不是所有设备所有镜头的硬件定律。Apple要求请求尺寸来自当前activeFormat的[supportedMaxPhotoDimensions](https://developer.apple.com/documentation/avfoundation/avcapturedevice/format/supportedmaxphotodimensions)，且[maxPhotoDimensions](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/maxphotodimensions)为上限请求；不据此宣称所有镜头均可输出48MP。

- 移除统一禁用；点击当前原生1×保留48MP，不执行A挡24/35mm轮换。明确切其他焦段、长按转盘或首次捏合时回12MP再变焦。这里保留现有主摄48MP路由，不是逐镜头48MP开放，未来若扩展需要按镜头能力和实际输出另验收。
- 焦段共同玻璃移到独立、非交互背景并关闭背景命中，原生按钮不包含在整条交互glassEffect中；选中/按下不叠加整条动态高亮。没有移动焦段条、A/M和工具按钮。独立按钮仍保留自己的原样式。
- 最终功能组16项通过、0失败、0跳过，19.388秒，日志`/tmp/LumaCamera-Focal48-Verified.log`，结果`/tmp/LumaCamera-WarningAudit-DD/Logs/Test/Test-LumaCamera-2026.10.30_08-59-01-+0800.xcresult`。包括原生按钮点击事件绑定、短按/长按互斥、取消、连续变焦及A/M转盘重开。原生样式200次布局总计约3.53ms，是布局工作时间，不是屏幕FPS；转盘重开6次含队列/硬件读回约14.5–29.6ms。
- 补充真实文件专项1项通过，17.463秒，日志`/tmp/LumaCamera-Focal48-Files.log`，结果`/tmp/LumaCamera-WarningAudit-DD/Logs/Test/Test-LumaCamera-2026.10.30_09-00-44-+0800.xcresult`。当前1×按钮点选后实际JPEG6000×8000（48MP），切镜后3000×4000（12MP），数据从成片ImageIO属性读取，未写系统相册。3次从48MP切其他焦段并恢复就绪约1.102/1.121/1.044秒。
- 完整相机页安装在真机UIWindow：初始5个焦段中心及七种照片比例×0°/90°内容方向共70个中心均命中原生UIButton；所有焦段纵坐标保持，使用原生touchUpInside事件驱动实际会话选镜。该方法是窗口命中测试＋控件动作，不等同于手指完整触摸注入。
- 真机按压选中态截图已导出并目检，焦段条仅一层共同圆角玻璃，无单独选中玻璃。附件`/tmp/LumaCamera-Focal48-Attachments/F985E768-8AF2-4289-9BD6-436E4D1884A8.png`。较早完整页面命中测试因测试窗口scenePhase未激活导致按钮未就绪而失败；改为显式活跃场景及等待camera.ready后基线即可命中，未把该测试设置问题当作实际透明层拦截结论。双层修复针对绘制/交互玻璃结构，48MP禁用根因由代码和用户规格确认。

本轮没有实测物理音量/相机控制按钮，也未逐一核对六照片格式、所有特殊子模式与每个镜头的48MP能力；不能将目前的主摄策略表述为硬件只能1×。工具缓存MDB_MAP_FULL等日志仍存在，不当作源码编译警告或应用内存指标。

## 2026-10-30 逐镜头48MP实际能力核对

当前连接iPhone17Pro / iOS27.2，M挡物理路由7档位、4个设备身份、35份实际成片数据（每档JPG2、HEIF2、RAW1），单项48.271秒通过，0失败、0跳过，未向系统相册保存。0.5×/1×/4×均JPG/HEIF6000×8000、DNG8064×6048；2×/8×虽请求8064×6048，均交付约12MP；前置两取景档位无系统48MP格式，当前4:3成片约12MP。

三个后置镜头的activeFormat均公布48MP，但2×/8×实际交付仍低于请求，证明只读取supportedMaxPhotoDimensions不足以判断当前倍率能否交付48MP。A挡仅主摄及主动切镜降12MP的策略本轮未更改；不能把该策略当作后置超广角/长焦不支持48MP的硬件结论。

含350ms稳定等待的7次路由就绪0.363–0.787秒；35份捕获交付延时中位0.992秒、最大3.094秒。3轮快速提交选镜后均恢复就绪；这是回调/恢复指标，不是FPS、快门响应或画质细节测试。新DEBUG能力快照只读、正式路由未改；图像原始文件数据通过ImageIO读取实际尺寸、EXIF焦距和方向，RAW保持DNG。没有把前置两个目录选项当成两个物理镜头。

日志`/tmp/LumaCamera-Lens48-Audit.log`，结果`/tmp/LumaCamera-WarningAudit-DD/Logs/Test/Test-LumaCamera-2026.10.30_09-05-25-+0800.xcresult`，内含35条JSON附件。详细表格、平台依据、首张/第二张一致性及固定场景/格式范围限制见[逐镜头报告](Test-Reports/2026-10-30-Lens48MP-Audit.md)。HEIF HDR/HEIF Pro/RAW+JPG/TIFF及特殊拍摄模式不在本轮结论内，未将本机结果推广到其他机型。

### 35mm倍率补充

用户追加35mm是否仍支持48MP。最终A/M两路径、JPG/HEIF/RAW各2张，共12份文件核对，单项15.551秒通过、0失败、0跳过；文件EXIF等效焦距均35mm，同格式首张/第二张尺寸一致，未写系统相册。日志`/tmp/LumaCamera-35mm-48Audit-Final.log`，结果`/tmp/LumaCamera-WarningAudit-DD/Logs/Test/Test-LumaCamera-2026.10.30_09-17-41-+0800.xcresult`，含12条JSON。

M路径实际物理主摄倍率1.458333，最大请求8064×6048，系统处理照片5530×4148，最终JPG/HEIF4148×5530、DNG5530×4148，均22,938,440像素。A路径实际虚拟多摄物理倍率2.916667（显示约1.458×），请求上限5712×4284，实际处理照片/DNG4032×3024，最终JPG/HEIF3024×4032。当前A返回12MP不是35mm硬件只能12MP的依据；物理主摄也没有返回完整48MP。测试绕过UI降分辨率策略只验证能力，不改变产品路由或新增23/24MP档位。

首轮1处失败源于审计误设“A也必须为物理路由”；实际记录表明自动连续变焦走回虚拟设备，修正为分别记录A/M路由，M仍严格要求物理，同时新增每份文件EXIF35mm及两张尺寸一致断言后通过。没有改变生产代码以迎合测试预设。当前固定场景、SDR基础JPG/HEIF/RAW结论不扩展到HDR和全部环境，详细差异见同一[镜头报告](Test-Reports/2026-10-30-Lens48MP-Audit.md)。

## 2026-10-30 48MP三固定焦段、M挡曝光回退与切换提速

已按用户最新规则实现：A/M挡48MP条仅显示本机支持的0.5/1/4原生焦段，切换不降规格；按钮尺寸沿用普通档，背景收缩，禁用转盘/长按/捏合/连续变焦。M挡48MP默认自动曝光实际读数，调整ISO/快门立即回12MP再应用手动值，WB和焦点继续可手动。官方资源准备回调替代额外预拍；旧“48MP只主摄、其他焦段降12”说明被此规则替代。

- iPhone17Pro / iOS27.2（24B119），Xcode27.1：最终18项通过，0失败、0跳过，86.591秒；日志`/tmp/LumaCamera-Fixed48-AllFinal.log`，结果`/tmp/LumaCamera-WarningAudit-DD/Logs/Test/Test-LumaCamera-2026.10.30_09-47-04-+0800.xcresult`。
- 12次A/M原生焦段操作的12张正式JPG/HEIF均6000×8000，实际物理倍率1、设备身份匹配；高像素M挡6份均有手动WB标记。ISO/快门两条实际编辑入口另2份文件确认回12MP且保存约ISO200和1/125秒，不写系统相册。
- 真正物理切镜9次，从按钮动作到资源/会话就绪0.437–0.836秒、中位0.626秒；排除测试前固定120ms等待及重复选当前镜头。开发期预拍方案同类样本减掉固定等待后中位约1.103秒，但期间还有质量策略变化，不宣称严格单变量A/B或所有环境同等提升。
- 全7比例×横竖内容方向14配置、42中心窗口命中，按钮40×40点不变、背景212→128点，A/M和工具位置不变。当前减弱动态效果关闭，代码80ms分支未在本轮切系统设置逐帧核对。200次原生布局3.70ms仅为布局工作时间，不当作FPS。
- 普通变焦、转盘A/M重开、取消及快速48→12恢复通过；智拍48MP固定倍率、实际HDR低尺寸回退、夜景返回、三轮WB过期事件到虚拟路由回归通过。Release成功、源码警告0，日志`/tmp/LumaCamera-Fixed48-Release-Verified.log`；App Intents元数据工具提示仍保留。

官方依据：48MP处理照片需[balanced/quality](https://developer.apple.com/videos/play/wwdc2026/304/)，严格自定义曝光需[speed](https://developer.apple.com/documentation/avfoundation/avcapturedevice/setexposuremodecustom(duration:iso:completionhandler:))；[setPreparedPhotoSettingsArray](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/setpreparedphotosettingsarray(_:completionhandler:))只预分配资源，不拍摄。测试曾实测quality输出48MP却把1/125秒改成约1/33秒，最终没有用该路径冒充严格手动曝光。

首次空能力缓存、首张12MP、只读环境值编译失败、WB首张未就绪、35mm旧连续标志以及测试画幅/虚拟路由基线问题均已记录并纠正；完整过程、指标定义和格式/场景/冷启动限制见[专项报告](Test-Reports/2026-10-30-Fixed48MP-Focals.md)。本轮不宣称六格式、全部特殊模式及所有环境已验收。

## 2026-10-30 三镜头视频与预设规格核对

本机iPhone17Pro / iOS27.2（24B119），Xcode27.1。普通4K120仅主摄；超广角/长焦最高4K60。三镜头均提供1080p120/240慢动作采集，4K120慢动作仅主摄。能力快照还区分了SDR/P3/HDR/Log格式，不把H.264、ProRes、RAW及外接盘组合一并宣称可用。

最终2项真机测试通过，0失败、0跳过，30.180秒，日志`/tmp/LumaCamera-VideoLens-Verified.log`，结果`/tmp/LumaCamera-WarningAudit-DD/Logs/Test/Test-LumaCamera-2026.10.30_10-02-02-+0800.xcresult`。一次性19行能力快照耗时约0.822秒。真实11段HEVC SDR包括：三镜头4K60（解码60fps、73/74/74帧）、主摄4K120两次（解码120fps、146/145帧）、三镜头1080p240→30慢动作（各288帧/9.6秒）、三镜头1秒间隔/3帧基础4K30延时（各3帧/0.1秒）。实际物理路由、帧周期、文件尺寸/标称帧率及逐帧PTS均核对，未写系统相册，临时文件测试结束删除。

延时五题材预设主要对应采样间隔，不是独立镜头能力。电影格式须用专门的Cinematic范围：项目后置采用双广角虚拟设备，本机公开SDR/P3格式1080p30、4K24/30，物理倍率2–6乘显示因子0.5后为1–3×；不能把普通三个原生焦段都算作电影支持。代码现状后置电影候选仍可把同一设备规格映射到其他目录焦段，范围门控差异已记录，本轮未改生产逻辑。虚拟光圈仅主摄/长焦，双拍后置固定主摄＋前置。

初次测试Cinematic属性缺少iOS26判断导致编译失败，修正后通过；首次实录读取代码错误地跨AVAsset实例取轨道，触发AVAssetReader异常，修正为同一实例后完整复测通过。设备锁屏等待经用户解锁后继续。没有把这些过程失败写成镜头硬件不支持。

仅短片与指定HEVC SDR组合实录，其他颜色/编码、外接RAW/ProRes及长时热负载不算端到端验证；电影范围来自能力快照，本轮不重做效果实录。解码fps不等于预览FPS，也未报告应用内存。平台依据、全部矩阵及证据见[视频镜头审计](Test-Reports/2026-10-30-VideoLens-Specification-Audit.md)。

## 2026-10-30 视频镜头/规格相互筛选

同一iPhone17Pro / iOS27.2完成第一轮27项真机回归，0失败/0跳过，118.672秒。普通视频、慢动作、电影、延时及题材预设按当前镜头和精确规格隐藏不兼容项；拒绝不兼容选择，不自动换镜头或降低普通调整中的规格。上节记录的后置电影目录映射问题在本次修正，候选按Cinematic真实倍率范围限制。

真机4K120/4K60双向筛选、慢动作240→120采集切换、电影24/30与分辨率兼容、五延时预设、重复选择/取消、生命周期回退、慢动作A/M切镜和11段实际视频文件回归通过。1000组能力查询（100批×10组）批内平均中位0.239ms、P95 0.283ms；首次进入视频含7行能力及会话准备1.262秒（单样本）。真机304/386pt宽卡片中，超广角4K60卡片缩至262/325.67pt，70×32pt分辨率按钮和原fps槽宽保持；五比例×两个内容方向及四卡片配置共14组布局，固定按钮位置不变。指标是查询/准备/布局工作时间，不能当作预览FPS或应用内存。

日志`/tmp/LumaCamera-VideoSelection-Regression.log`，结果`/tmp/LumaCamera-WarningAudit-DD/Logs/Test/Test-LumaCamera-2026.10.30_10-35-17-+0800.xcresult`。系统减弱动态效果关闭，短动画分支未切系统设置验证；未覆盖外接RAW/ProRes实盘、全部颜色/编码和长期热负载。详细样本与补充复测见[专项记录](Test-Reports/2026-10-30-VideoSelection-Compatibility.md)。

A挡补测随后发现真实路由问题：物理主摄提供4K120，而虚拟多摄不提供，旧路径回退到60fps；两轮补测各4个断言失败后修正。现在只在虚拟路由不支持请求时使用兼容物理输入，普通支持的规格继续使用原自动多摄策略。修正后6项真机测试0失败/0跳过、89.728秒，A挡实际采集周期1/120秒、A/M筛选及11段视频复测通过，日志`/tmp/LumaCamera-VideoSelection-RouteFixed.log`，结果`/tmp/LumaCamera-WarningAudit-DD/Logs/Test/Test-LumaCamera-2026.10.30_10-43-30-+0800.xcresult`。该轮首次视频准备1.330秒，1000组缓存查询中位0.251ms/P95 0.284ms，均按上述相同定义统计。最终Release构建成功，源码警告0，仍保留无AppIntents.framework依赖的元数据工具提示：`/tmp/LumaCamera-VideoSelection-Release-Final.log`。

最终4项补充真机验证0失败/0跳过、63.700秒：前置各子模式/A/M/后台及返回照片实际倍率恢复，五视频比例×四方向HUD/直方图边界和规格卡布局，Open Gate实际4:3/1:1文件，以及100次快速规格赋值后的回退一致性。日志`/tmp/LumaCamera-VideoSelection-Recovery.log`，结果`/tmp/LumaCamera-WarningAudit-DD/Logs/Test/Test-LumaCamera-2026.10.30_10-46-01-+0800.xcresult`。
# 2026-11-03 48MP 焦段条测量点复核

- 将焦段条测试几何记录移至占满可用宽度的居中容器之前，记录实际焦段内容宽度，不改变界面布局。
- iPhone 17 Pro、iOS 27.2，项目正常签名，`HighResolutionFixedFocalTests/testFixed48MPRoutesFilesAndAdaptiveStripAcrossModesAndRatios` 定向真机复测通过，结果 `/tmp/LumaPriority48Geometry.xcresult`；诊断照片未写入系统相册。此前同一测试的 28 条宽度断言失败，原因是测量了外层容器。
- 当前两轮固定焦段样片均未复现报告中的首拍低分辨率；不能据此认定所有场景和冷启动路径已解决。1 秒夜景计划曝光专项另一次通过，结果 `/tmp/LumaPriorityNight48.xcresult`；该结果包整体因首次布局断言失败而失败。

# 2026-11-03 慢门成片方向与尺寸

- 慢门源帧携带首帧快门时确定的画幅和方向，最终合成沿用该状态，避免横持源帧按界面默认竖幅裁切。
- iPhone 17 Pro / iOS 27.2 定向真机 `testManualBracketSpeedComparisonAndRepeatedCapture` 通过，覆盖光轨、流水、动态模糊各四次采集、实际保存文件大于 11MP 和速度对照；结果 `/tmp/LumaSlowOrientationFix.xcresult`。测试时长 231.677 秒含启动及诊断，非帧率或单次成片速度；诊断照片未写入系统相册。
- 本轮未覆盖全部慢门预设、所有画幅和设备方向，也未证明长时间热稳定与内存峰值通过。

# 2026-11-03 双拍主画面与横幅小窗

- 前置作为主画面时，后置小窗横幅不再限制前置普通／广角切换；前置成为横幅小窗时启用广角，换回主画面恢复先前状态。
- iPhone 17 Pro、iOS 27.2，`DualCaptureZoomPhysicalTests/testMainZoomDuringRecordingAndRepeatedSwap` 定向真机通过，覆盖前置主画面加横幅小窗、普通/广角往返、交换主副画面、录像变焦与三轮交换；结果 `/tmp/LumaDualInsetSpecific.xcresult`。未向系统相册保存诊断视频。未覆盖全部分辨率、长时间温升及真实手指操作。

# 2026-11-03 HEIF HDR 拍摄预览与影调

- 普通 HEIF HDR 拍摄切回静态路线前保留当前预览帧，恢复 HDR 路线后释放；提前失败路径也释放。HEIF/HEIF Pro 的非高动态显影路径将 HDR 状态传给影调处理。
- iPhone 17 Pro / iOS 27.2：`HEIFHDRPhysicalTests` 和 HDR 高光基础检查通过，结果 `/tmp/LumaHDRFix1103.xcresult`。测试检查 10 位文件、预览配置、恢复和合成夹具；未将诊断照片写入系统相册。
- 既有真机用例尚未连续测量快门期间的预览 HDR 亮度，也未用真实高反差场景核对 HEIF Pro 成片或系统照片 App 显示；用户报告的最终视觉效果尚待验收，10 位编码不等于证明画面具有可见 HDR 高光。

# 2026-11-03 Live 24/35mm焦段

- Live生效时M挡也允许短按当前1×在24/35mm间切换，并显示对应名称；Live输出重配后恢复本次用户请求倍率。
- iPhone 17 Pro / iOS 27.2，`testRearLiveTogglePreserves24mmAnd35mmFraming` 定向真机通过，结果 `/tmp/LumaLiveFocalFix.xcresult`；A挡4次、M挡3次点击方法调用均核对实际硬件倍率，包含Live开关前后倍率恢复。未拍照或写入系统相册。
- 修改前A挡方法调用已通过，未复现用户实际手指点击失败；本轮未用真实手指验收，不将其写为A挡触控问题已确认解决。未测持续高频点击及长期功耗。

# 2026-11-06 微距拍摄后路由恢复

- 连拍延长临时物理输入保持时间时重新安排恢复，避免旧定时任务提前退出后永不恢复。重接虚拟多摄时恢复其支持的完整 fallback 候选集合，仍由系统决定实际镜头。
- iPhone 17 Pro 真机、固定近距场景：修复前两张 HDR HEIF 后七秒仍是物理超广角锁焦；修复后两张完成，七秒后恢复自动虚拟三摄，候选包含超广角与主摄，实际主 constituent 为超广角。定向测试 1/1 通过，临时照片未保存相册。
- 仅一组近距、两张照片；未完成多组速度/性能、远景退出、快速切换和首次拍摄过程中画面连续性验证，不能认定原问题在所有场景已解决。现有临时物理输入/五秒保持路径仍需进一步评估。

# 2026-11-06 微距标识及相册返回检查

- 微距拍照临时物理超广角作为取景状态快照的一部分，仍受主动切焦段的代次保护；普通用户选择 0.5× 不视为临时微距。
- iPhone 17 Pro 真机：近距两张 HEIF HDR 拍摄后微距状态均为 true，模拟一次相册相机停启后 ready=true、macro=true，7 秒后虚拟多摄恢复且超广角供图；原有微距策略用例通过。临时照片未写入系统相册。
- 相册往返仅验证生命周期和状态恢复，未测量画面位移或目视验收，返回画面跳动仍未解决；未覆盖所有格式、重复往返或渲染性能。

# 2026-11-06 微距进入相册返回跳动诊断

- 查看用户录屏：返回时出现不同构图的旧预览与新预览短暂叠加；单凭视频不能确定物理镜头。
- iPhone 17 Pro 固定近距真机诊断：第一次相册生命周期往返前为虚拟三摄的超广角，返回首帧时为主摄，显示倍率仍为 1×；两个镜头均在自动 fallback 列表内。后续两轮起始和返回均为主摄；首帧就绪约 0.34 秒（3 次，含生命周期等待，不是渲染帧率）。测试未实际保存媒体。
- 诊断只模拟相机生命周期，非真实相册界面操作；不能判断所有跳动都由切镜造成。尚未修改产品行为或验证消除跳动；不可通过强制锁镜、延时单次对焦或旧帧遮盖来宣称解决。

# 2026-11-06 首次微距拍摄后预览放大诊断

- 用户 09:52 录屏显示第一张拍后预览放大并保持，24mm 标签不变。真机固定近距首张前后临时预览附件也观察到构图差异。
- 名义设备倍率均为 2.0、格式 4032×3024、videoFieldOfView 均 103.62532 度、畸变校正均开启；输入由虚拟三摄改为物理超广角，重新对焦并锁焦。配置视角相同不等于有效画面一致，不能据此断定倍率错误或仅光学呼吸。
- 后续修复：微距不再优先走虚拟 constituent，始终切物理超广角并保持输入；只要仍处于微距就每5秒延长保持，真正离开微距后才恢复虚拟多摄。连续拍摄日志确认第一张后 input 仍为 UltraWide（virtual=false），预览不切回主摄。
- 增加光学配置日志及首张前后预览附件用于排查；修复后连续两张 HDR 用例通过，仍需用户用录屏复核构图是否完全稳定。

# 2026-11-06 A挡微距改回系统虚拟多摄

- 按最新规则，A挡移除 macroActive 驱动的物理超广角预切换调用；快门不再执行 prepareMacroAutomaticRoute，普通0.5×路线不变。设备支持时只请求超广角 constituent，并关闭本张自动融合；不请求主摄 constituent。官方允许指定 constituent 子集，不保证所有格式均支持。
- iPhone17Pro 真机：近距两张 HEIF HDR 前后 input 均 TripleCamera / virtual=true，primary 均 UltraWide，设备zoom=2，自动对焦状态保持；文件EXIF焦距均2.22mm，HDR headroom约6.50，测试含额外500ms等待的完成耗时2.89/1.72秒。恢复与相册生命周期检查通过，临时照片未保存相册。
- 远景场景另测1×主摄、0.5×超广角三轮往返通过。该测试重新建模并主动选择倍率，不能替代同一连续会话里“近→远”的实际退出过程验收。
- 首张前后预览附件仍有少量位置/亮度变化，尚未量化是否来自持机或光学变化；未宣称画面绝对无变化。0.5×近距连续拍摄、全部格式及其他倍率、真实相册动画仍未全部覆盖。旧物理保持辅助代码尚保留用于历史/手动路径，不再作为A挡自动微距入口。

