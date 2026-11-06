## HDR源增益保留与编码（2026-11-06，覆盖先SDR后猜测扩展的旧路径）

`Imaging.filteredHDR`用最大RGB通道软肩生成参考白范围内的SDR基底（knee=0.8，target=1），再处理原有影调、滤镜及参数。`hdrRestoreSourceGain`以同一源图最大通道/基底最大通道的逐像素比例恢复高光；不再使用hdrExpand推测增益。最终SDR基底直接复用处理结果，不再二次压肩。照片参数和曝光采集路线不变。

`PhotoEncoder`移除HDR主图额外0.7EV，通过`CIAreaMaximum`在扩展线性P3读取最大通道，`HDRToneMapping.measuredHeadroom`提供实际编码headroom（无效读数回退）。iOS26+在最终HDR图上设置该标记，然后通过官方`heifRepresentation`的`hdrImage`写SDR基底及HDR图。保留原有ISO/Apple增益图和EXIF封装；源图无扩展高光时系统可能不生成增益图，允许交付有效HEIF，不强制抬高曝光制造增益图。旧系统既有PQ回退保留，本轮未验证iOS18/低版本实机。

官方依据：[HDR图像编辑/编码](https://developer.apple.com/videos/play/wwdc2024/10177/)、[headroom标记](https://developer.apple.com/documentation/coreimage/ciimage/settingcontentheadroom(_:))。软肩、增益传递与参数取值为本项目实现，不是苹果原生相机算法或官方保证；最大RGB值作为本项目编码标记的测量方法，也不等同于显示屏的亮度尼特。

## 裁剪入口面板清理（2026-11-06）

`enterCrop()`先调用`closeEditorControls()`清理数值草稿及拖动状态，再记录裁剪快照并切工具。`finishCrop`仅恢复之前工具，不重新开启面板；裁剪取消仍恢复原构图配方。沿用既有局部淡入淡出。

## 照片编辑共享控件（2026-11-06）

通过 `FilterEditingControls` 协议复用 `FilterDialEditor`、`FilterAdjustmentTabs` 和 `FilterNumericInputDialog`。CameraViewModel 与 PhotoEditorViewModel 分别提供绑定；照片仍写本地 PhotoAdjustments、走既有预览和保存管线，不写拍照配方。照片进入编辑时读取全局调色盘偏好，默认旧版控件。分类还原推进代次；切工具、滤镜、分类、保存和取消清除数值草稿，旧手势不能覆盖新配方。

PhotoEditorViewModel 独立管理 editorControlsVisible：当前工具再次点按或关闭图标收起，再点恢复；退出拖动时结束交互。新版滤镜选择160点、参数290点，旧版190点；收起为0。照片适配区域吸收高度变化，底部工具栏原位。局部切换使用既有减弱动态效果感知的淡入淡出，不改原图及编码算法。

## 底部横条与盘面端点对齐（2026-11-06）

新版底部横条使用50点右对齐名称、6点间距、56点尾部空白，与盘面左右8＋40＋8点的占位一致。DEBUG几何采样记录实际中央盘面与横条的global frame，用例在支持宽度和比例下断言端点及宽度一致；这些调试几何不参与产品布局。旧版Slider保持原结构。

## 新版包裹式滑条（2026-11-06）

仅`FilterDialEditor`内部横/竖轨道复用`FilterDialTrack`。`FilterDialGeometry`集中定义trackThickness=28、thumbDiameter=22、inset=13；端点触摸映射与视觉位置仍共用原fraction/value函数，轨道不再按inset裁短，保证端部圆帽包裹滑块。FilterDialRail保留参数名/数值及AX容器，横条保留参数名和独立AX标签；结束或退出清理交互状态。底部横条通过尾部24点padding收短，不改参数范围、默认值、配方绑定、旧版原生Slider或弹窗高度。

## 分类还原（2026-11-06）

`resetCurrentFilterTab()`依照共用`FilterEditorTab.parameters`目录还原当前分类，不依赖界面类型。调整先写局部配方，持久化恢复标志内一次赋值，随后统一save/flush/updateLook；浓度仅在色彩目录包含strength时恢复80。操作推进filterResetRevision，清理单项输入和拖动状态，防止旧手势写回；录制繁忙、格式不支持或整组重置确认层显示时不执行。选项卡行的还原图标复用此路径，不改变默认旧版、弹窗高度或成片算法。

## 单项数字草稿与键盘隔离（2026-11-06，最新）

`FilterDialEditor`上方统一数值按钮调用`CameraViewModel.presentFilterNumericInput`。模型保存单项参数、草稿及打开时的受保护绑定；只在确认时调用绑定，默认还原仅写草稿。关闭相机弹窗、切滤镜、切分类和整组重置均清除输入状态；原绑定的滤镜身份、重置代次与能力检查继续防止晚到事件覆盖新配方。`FilterParameter.inputValue`只接受该范围内有限Double，默认值集中为strength=80、其它=0。原版滑条的text格式不改，新版numericDisplayText最多显示三位小数。

`FilterNumericInputDialog`复用PopupSurface玻璃外观，使用系统TextField和[FocusState](https://developer.apple.com/documentation/swiftui/focusstate/)获取/释放焦点，监听官方[keyboardWillChangeFrameNotification](https://developer.apple.com/documentation/uikit/uiresponder/keyboardwillchangeframenotification)调整弹窗底部避让；相机根视图忽略键盘safe area，使下层控件不被抬升。当前坐标处理面向固定竖屏、全屏iPhone，不将键盘屏幕坐标与视图全局坐标在多窗口环境下相同视为平台保证。过渡沿用减弱动态效果感知的短淡入淡出。

新版内容高度348点；色彩/明暗五项数值在同一行、盘面两轴方向字为主题色；褪色/亮度只保留滑条左侧名称。质感顶部七值使用与下方轨道相同列距，数值行与轨道背景分离。没有增加成片参数或改变基础滤镜浓度的作用范围。

## 质感竖轨与静态磨砂表面（2026-11-06，最新）

`FilterDialLayout.vertical`描述质感七项的固定顺序；`FilterDialEditor`在effects分支渲染七个`FilterDialRail(texture: true)`，色彩/明暗继续原二维盘。竖轨复用单参数受保护绑定和端点内缩映射，彼此不联动，值在上、语义双行名称在下。质感无底部标签或横向滑条。两种分支同高并局部淡入淡出；旧版仍由默认false的设置分支控制。

调色盘的`dots`扩大为2.4点；`matteTexture`按固定整数种子绘制低对比微点，关闭命中测试，没有Timer、逐帧随机源或照片渲染器依赖。纹理只是SwiftUI控件表面装饰；不新增滤镜参数或改变任何输出像素。

## 可选横向调色盘（2026-11-06）

`CameraFilterAdjustmentPanel`仍以`CapturePreferences.filterDialPad`分支选择控件，默认及旧数据缺省为false；旧版滑条保留334点高度，开启后的调色盘内容为386点，三类同高。`FilterDialLayout`只描述界面分工：色彩为色温×色调、浓度/饱和度竖轨、褪色横轨；明暗为曝光×对比、高光/阴影竖轨、亮度横轨；质感为柔光×卤化、细节/暗角竖轨、色差/颗粒大小/颗粒饱和度标签与共用横轨。卤化在新界面显示“胶片光晕”，原key不变。标签只切换正在编辑的参数，所有配方数值保留；相册照片/视频编辑继续原滑条。

`filterParameterPairBinding`与单项绑定共用格式、videoBusy、重置代次和滤镜身份检查，并拒绝切分类后延迟到达的旧手势；两轴写入一份`FilterAdjustments`后只发布一次。取消原先光晕把softness/halation同时写为同值的合并入口。`FilterDialGeometry`让指示点位置与触摸端点使用同样的13点内缩；默认标记按参数零值定位。浓度仍是基础滤镜的`intensity`，不缩放独立调色参数，不改变渲染器。切页/底部参数切换使用局部透明过渡，遵循`AppTheme.popupAnimation`的减弱动态效果规则。

手势与无障碍采用苹果官方[DragGesture](https://developer.apple.com/documentation/swiftui/draggesture/)和[accessibilityRepresentation](https://developer.apple.com/documentation/swiftui/view/accessibilityrepresentation(representation:))接口；参数映射与批量提交为项目自身实现，不是平台提供的调色算法。

## 夜景源ISO降噪与元数据（2026-11-03）

NightPhotoMerger配准交集裁切后按原始索引显式带入source.properties；融合器按有效源ISO中位数对800–3200区间线性映射噪声压力，提高CINoiseReduction阈值及暗部覆盖。缺失元数据/低ISO保留原路径，不改自动曝光、帧数、运动拒绝及M挡曝光语义。最终仍使用参考帧元数据。[测试与边界](Test-Reports/2026-11-03-Night-HighISO.md)。

## 视频虚拟光圈竖向入口（2026-11-02）

视频子模块按钮上方保留唯一可见入口，移除重复透明点击层。toggleVirtualApertureSlider同时服务照片顶部和视频侧边入口；照片depthControlPopupVisible不扩大到视频，视频仍通过独立VStack在按钮上方展开竖向Slider。编辑通知接入共用3秒空闲任务，持续持有不关闭，退出清理状态。[实际验证](Test-Reports/2026-11-02-Video-Aperture-Entry.md)。

## 双拍主画面变焦请求（2026-11-02）

双拍使用独立LatestValueThrottle，在会话队列按双拍代次与主画面位置校验后只修改目标设备videoZoomFactor。交换和释放取消旧请求；范围从会话队列当前主设备读取，不依赖合成队列的frontIsMain。纯倍率不刷新readingsGeneration；主线程发布倍率及最近焦段，录制分支允许双拍有效范围，不走普通单摄录制输入变焦。普通同输入变焦仅按需恢复系统自动切镜策略，输入变更仍执行配置。详见[实际验证与限制](Test-Reports/2026-11-02-DualCapture-Zoom.md)。

# 架构与开发约定

## 2026-11-02 选中状态文字颜色

慢门预设/时长统一在外层VStack根据selectedSlowShutterPreset设置accent/white；不再由toolbarPanel或时长值决定，覆盖旧“只着色预设名”的规则。设置视频码率使用Menu显式标签，内部保留Picker与原偏好绑定；标签按systemDefault为white、其他为accent，原生菜单选项和编码策略不变。[验证](Test-Reports/2026-11-02-Control-Selection-Colors.md)。

## 2026-11-02 视频连接防抖

configureOutputConnections对普通视频的录制/预览连接，按当前activeFormat支持情况选择cinematic→standard→off，不调整用户选择的规格；不使用自动选择的扩展档位以限制缓冲。返回照片恢复预览尺寸输出的previewOptimized（支持时）或off，photoOutput不设置视频防抖。RAW/Open Gate不经过此普通视频策略，双摄保留原路径。DEBUG只读状态在相机会话队列获取preferred/active及真实帧周期；测试读取实际生效模式。[真机与延迟观测](Test-Reports/2026-11-02-Video-Stabilization.md)。

## 录制期间变焦与轮盘超时（2026-11-01）

CameraEngine在录像开始时固定recordingZoomDeviceID并发布实际videoRecordingZoomRange，录制变焦走applyRecordingZoom，仅修改当前设备的videoZoomFactor/ramp，不走换输入、拍照输出重配或规格回退；物理设备的逻辑焦段仅从同设备候选中选择，虚拟多摄仍交系统选择物理供图。CameraViewModel以单个可取消videoZoomAutoHideTask处理视频待机及录像时松手后3秒收起，持有手势不收起，结束录制/退出/关闭共用endZoomDial取消；默认显示焦段条，短按只切焦段，长按打开变焦轮。变焦轮显示时焦段条隐藏但占位，收起后原位恢复，原CameraZoomPanSurface拖动结构保留。CameraFocalControl通过读取最新状态的acceptsNewTouches闭包关闭隐藏按钮的新命中及动作入口，已开始的长按仍可继续拖动和释放。顶部人像景深与虚拟光圈由sliderAutoHideTask在最后操作后3秒淡出，编辑持有取消计时，结束后重启。CameraToolbar只为已选慢门预设名称设置accent，下行时长沿原样式。[首轮验证](Test-Reports/2026-11-01-Recording-Zoom.md)、[最新交互验证](Test-Reports/2026-11-01-Video-Zoom-Interaction.md)。

## 后置文件方向与相册当前方向（2026-11-01后续修正）

CameraEngine为后置保留独立RotationCoordinator；快门时按最近90°方向设置照片连接与CaptureLook裁切轴，CaptureContext固定角度，所有原生提交通过captureNativePhoto恢复快门角度，避免夜景换路由或多批提交覆盖。普通后置视频在开拍时把角度传给MovieRecorder，按显示轴选择裁切/编码宽高，再写轨道transform；前置参数沿旧路径，RAW外接和双摄合成未接新参数。GalleryView自身的方向StateObject动态供给详情，App不再携带媒体角度；相册按钮通过CaptureAlbumThumbnail读取当前控件方向，LibraryMediaThumbnail统一铺满，详情仍完整适配。只读诊断证明本次侧转源于原文件保存方向，升级不自动重写旧资产。[实拍证据](Test-Reports/2026-11-01-Library-Upright-Fill.md)。

## 相册媒体显示方向（2026-11-01）

CaptureControlOrientation 向 libraryMediaAngle 提供独立媒体方向；GalleryView 仅归零 captureControlAngle，保持页面/控件竖屏。相册按钮、列表（含视频封面）用 LibraryMediaThumbnail 完整适配，圆形入口按对角线内接；LibraryMediaCanvas 显式交换横拿时的内部宽高并只旋转媒体。PhotoPageViewport 将照片缩放、Live、标识及翻页旧帧放入媒体画布，翻页位移留在屏幕轴；PhotoZoomScrollView 在方向变化时结束Live并重置适配，四本地方向手势按角度只开放屏幕左右轴。SystemVideoView 继续沿用同源 videoPlaybackAngle，复用画布尺寸和拖动向量映射，旧帧也随媒体旋转；视频播放条/标识随视频、顶部底部控件固定。编辑流程和保存文件不参与显示变换。[验证](Test-Reports/2026-11-01-Library-Media-Rotation.md)。

## 慢门/延时顶部预设入口（2026-11-01）

CameraToolbar复用slowShutterDuration与videoColor面板标识：慢门按钮预设/时长两行，延时色彩/预设两行。CameraToolbarPanels复用PopupSurface与choicePill，慢门预设、时长和延时预设采用五个固定槽宽，色彩空间不足五项仍占原槽，不扩大按钮；相同模型选择API保留规格约束与预设取消。choicePill可关闭包装触感，模型已处理预设/时长的动作只触发一次；重复当前时长直接返回。CameraCaptureControls删除预览中的两个旧预设条，仅保留原视频光圈浮层；M挡慢门仍通用时长、无自动预设行。前置视频CameraFocalButton沿用无内部玻璃标志，选中图标/触摸逻辑保留。原底部布局与玻璃假样例测试改验真实顶部控件；延时实录使用FullDeviceRegressionFixture基线和实际快门就绪等待。[结果](Test-Reports/2026-11-01-Preset-Toolbar.md)。

## 相机恢复本地诊断（2026-11-01）

CameraViewModel在生命周期请求入口提交模式/格式/预设等固定字段；CameraEngine启动时让CameraResumeDiagnostics观察主线程、会话队列及预览队列20秒，每秒每路最多一个未返回探针，3秒无响应或缺帧记录一次状态变化。观察代次废弃停止后的迟到响应，不修改会话恢复、镜头或曝光行为。独立utility队列的CameraResumeDiagnosticStore原子保存最近64事件到Caches/CameraResumeDiagnostics/recent.json；不写媒体、位置、设备标识，不上传。缓存可清理，标记只用于定位队列/缺帧，不能等同死锁证明或主线程调用栈。SLOW-RESUME-001尚未复现关闭。[验证与局限](Test-Reports/2026-11-01-SlowShutter-Resume.md)。

## 顶部景深与光圈完整浮层（2026-11-01）

DepthToolbarButtonAnchorKey同时传递按钮与工具栏bounds；toolStrip通过transformAnchorPreference合并父锚点。CameraView在完整高度的工具栏容器解析浮层，避免滑条绘制和触摸区域悬在短工具栏之外。位置仍为工具栏下10点、190×32、对应按钮正下方并限位14点，保持局部淡入淡出、减弱动态效果和焦段条固定。真手势在App原窗口观察绑定，不另建共享模型的相机页；光圈压力夹具只复用取景及控件，避免第二份CameraView生命周期启停同一会话。智拍累计执行数按测试增量验收，48MP恢复等待会话请求后再检查准备完成。[本轮记录](Test-Reports/2026-11-01-Other-Six-Fixes.md)。

## 视频真机回归的实际快门就绪条件（2026-11-01）

FullDeviceRegressionFixture.waitForVideoShutter统一等待CameraViewModel现有videoShutterEnabled，打印初始switch/ready/configuring状态与等待时长。会话队列排空后，主线程模式切换仍可能未结束，测试应在按钮实际可用后触发，另计录制启动延迟。自动视频路线、白平衡矩阵和前置人物/官方居中实录采用此等待；居中准备中按钮禁用与启动立即取消仍按原竞争场景测试。修改限于真机测试，生产录制与方向策略保持已有版本。真实人物两项分批等待用户就位，以实际UIDevice姿态、文件轨道变换及Vision抽帧验收。[结果](Test-Reports/2026-11-01-Video-Six-Fixes.md)。

## 长焦导航退出保留最新逻辑倍率（2026-11-01）

CameraEngine.stopFocusNavigatorOnQueue先恢复原照片设备/格式，再以focusNavigatorZoom及原路由基准换算实际videoZoomFactor，限制在恢复后的硬件范围；不能把FocusNavigatorGraph进入时的倍率快照当作用户最终选择。原虚拟多摄与自动微距行为保持。导航主路预览在执行渲染前复核focusNavigatorRevision，准备完成通知同样复核；辅助缩图使用ownedCGImage，既有原照片会话和输出不迁移。

关联BasicVideoPhysicalTests使用现有videoShutterEnabled等待实际模式与硬件就绪后点击，生产toggleVideoRecording的切换保护不变；导航阈值测试另覆盖退出后实际录像。[真机、文件参数与性能](Test-Reports/2026-11-01-FocusNavigator-Fixes.md)。

## 慢门参考画布、像素所有权与预览交付（2026-11-01）

SlowShutterComposer对可靠配准结果保持累积器参考extent，新帧未覆盖的边沿先由已有累积像素覆盖，再按平均/亮部叠加融合；普通无配准路径仍取交集。SlowShutterGlobalAlignment和SubjectAlignment的小参考图使用ownedCGImage，避免跨帧持有延迟渲染输出；接受两帧后释放不用的全分辨率单帧备份，继续逐帧16位P3检查点与缓存清理。

CameraViewModel保留源帧侧0.5秒渲染节流，另以实际主线程发布时间限频，等待中仅保留最新预览；序列UUID校验与Task取消共同阻止完成/取消后的迟到画面。合成回调先提交序列状态再发布预览，处理同步取消和@Published赋值前通知的重入边界。最终成片不等待中间帧节流，既有局部显示动画及控件布局不变。[真机与稳定性验证](Test-Reports/2026-11-01-SlowShutter-Fixes.md)。

## 双摄错误归属与稳定退出状态（2026-11-01）

CameraEngine的双摄onError与等待录制/准备收尾的Task均校验dualCaptureRevision，当前准备中的错误仍处理，已退休图不能退出新图或覆盖提示。CameraViewModel将dualCaptureEnabled与dualCapturePreparing合并，只在准备结束时去重并恢复普通视频快照，避免enabled先false导致恢复丢失；快照清空仍保证一次恢复。底层真实运行错误保留NSError日志。DEBUG增加源UUID与错误回调读取用于真实换图/故障注入；入口与引擎UI验收使用独立完整CameraView窗口，HUD开启后读取最新布局并核对合成矩形。[真机验证](Test-Reports/2026-11-01-DualCapture-Recovery.md)。

## 自动夜景曝光需求、固定画布与低信号处理（2026-10-31）

NightAdaptiveCapturePolicy.targetFrameCount新增自动曝光方案需求；makeNightCaptureSettings按本次计划刷新降噪张数，仅DEBUG显式张数测试可保留受控目标。未知评估可补足6帧，可配准整体位移与主体变化分开；assessMotion始终在参考画布上比较，避免交集尺寸变化造成假运动。NightPhotoMerger仅自动配方用线性光域估计最多2.5EV，再按暗部掩码局部提亮；色度平滑、提亮前信号可信度和半尺度降噪分别处理低信号彩斑与颗粒，较亮信号保持原尺度。M挡手动曝光与既有取消token机制保持。[真机、同源复算与限制](Test-Reports/2026-10-31-Night-Quality.md)。

## 夜景取消覆盖完整交付生命周期（2026-10-30）

CameraEngine主线程维护nightCaptureTokens及cancelledNightCaptureTokens；stop标记尚未交付的夜景请求，覆盖硬件上下文已移除、后台合成及有序等待阶段。CompletedCapture携带token，交付时统一释放集合、过滤已取消结果，不更新成片版本/预览或调用完成处理。pendingCaptureTokens继续保证同一请求只终结一次，CaptureContext仍固定原请求自己的完成处理；nil清理默认不通知，真实超时用notifyFailure显式保留一次失败通知。[真机验证](Test-Reports/2026-10-30-Night-Cancellation.md)。

## 渲染像素所有权与请求回调（2026-10-30）

Imaging.ownedCGImage将长期保存的CI输出转成自有像素；RGBA8/RGBA16用CIRenderDestination直接渲染至自有内存，RGBAh复制像素及HDR属性，保留色域/位深/HDR元数据；PhotoEncoder在任务结束清理CI缓存。CaptureContext与有序CompletedCapture固定每次快门自己的完成回调，成功/真实失败均终结一次；显式用户取消仅清理请求，不交付半成品或nil完成通知，默认库回调忽略nil以保留旧缩略图。仅DEBUG诊断只读库支持测试基线清理，正式失败保存队列不清空。[验证](Test-Reports/2026-10-30-Priority-Fixes.md)。

## Pro影调位于格式弹窗（2026-10-30最终）

撤回CameraToolbar顶部新增的Pro影调项，照片顶部恢复五项。CameraToolbarPanels.formatOptions将HEIF Pro与Pro影调按相同五列尺寸相邻排列，说明另起一行；选择HEIF Pro后可从同一玻璃浮层切换到tone内容，复用choicePill触感/淡入淡出，不重复触感。DepthToolbarButtonAnchorKey保留，景深/光圈浮层继续锚定模式按钮下方。[验证](Test-Reports/2026-10-30-ProTone-FormatPopup.md)。

## Pro影调独立入口与按钮锚定（2026-10-30最新）

CameraToolbar将Pro影调放到HEIF Pro格式按钮后，独立于Live/人像/光圈分支；格式弹窗不再保留临时入口。DepthToolbarButtonAnchorKey传递模式按钮实际bounds，在toolbar overlay中解析为190×32滑条中心，并限位保留14点边缘，纵向仍在工具栏下10点。工具栏翻页不增加额外TabView identity，保持既有状态与浮层互斥。[报告](Test-Reports/2026-10-30-ProTone-Toolbar.md)。

## 顶部景深／光圈调节（2026-10-30）

CameraViewModel.depthControlPopupVisible统一照片模式、工具栏页及弹窗状态；dismissDepthControls统一计时器、可见性和编辑释放。交互期间停用自动收起，结束后重新计时。CameraToolbar优先模式按钮再Pro影调/Live，HEIF Pro模式的Pro影调入口保留在格式弹窗；浮层维持原底部overlay偏移42、190×32居中，仅局部淡入淡出。视频光圈入口及成像链不变。[验证](Test-Reports/2026-10-30-Depth-Toolbar.md)。

## 电影模式倍率与 M 挡参数（2026-10-30）

后置电影模式只展示真实目录中的1×/2×锚点，重复点击1×执行24/35mm数字取景循环，A/M一致，不添加伪造设备ID。CameraEngine连续变焦优先保留系统电影设备，在设备电影格式范围内将后置显示倍率限制1–3×，能力发布与实际写入共用边界；前置保留实际能力范围。CameraViewModel.displayedManualParameters在电影期间为EV/WB/TINT，视图仅局部动画居中；ISO、快门和手动对焦入口隐藏并拒绝打开，曝光写入暂用自动但不清除手动标志，退出后按原值恢复。详见[实测及局限](Test-Reports/2026-10-30-Cinematic-Zoom.md)。

## 真机诊断相册隔离（2026-10-28）

DEBUG下，AppDependencies的默认相册服务仅在显式环境变量 `LUMA_DIAGNOSTIC_READ_ONLY_PHOTOS=1` 时采用DiagnosticReadOnlyPhotoService：浏览只转发PhotoBrowserService协议，六类写入/删除入口直接失败并记录拦截；异常恢复的默认照片/视频回调亦不能落入PhotoKit写入。显式内存替身不替换。该变量仅写入临时xctestrun宿主EnvironmentVariables，不进入正式scheme/用户偏好；Release不编译该分支，普通启动不启用。

两项隔离自检覆盖全部入口、默认回调；78项失败复验均确认启用，未发现额外写入拦截。此隔离只服务测试，不是相机会话/录像故障修复；直接使用系统相册服务的真正保存集成测试仍需单独授权和审计，不能据此视为安全。[复验与限制](Test-Reports/2026-10-28-FailureRecheck.md)。

## 人像头部双向校正（2026-10-28最新）

头部区域不再以max-only方式叠加准确人物分割，而用柔化区域权重替换误分前景；身体区域外的原蒙版保持。眼部窄带仅从原始蒙版提取已有前景，与准确分割取最大后再做区域融合，以保留透明眼镜的外框；不是整条窄带填白。这样在本轮实拍中同时排除了脸侧绿叶清晰岛、保住镜框。原同图分割复用与静态/预览分离不变，历史“只增加前景”的说明已被本段取代。[验证及限制](Test-Reports/2026-10-28-Portrait-BackgroundExclusion.md)。

## 静态头部语义轮廓补充（2026-10-28）

CameraEngine在正强度静态人像中统一运行一次accurate人物分割：原生matte缺失时作底层后备，已有蒙版时作头部修补。PhotoEncoder传递portraitHeadMask并在原片副资源递归编码中复用；不再次运行人物分割。faceProtectedMask将语义结果仅限制在人脸附近宽1.9/高1.85倍区域，柔化区域边界并略扩真实轮廓，再与已有蒙版取最大；旧脸部椭圆保留。没有全头矩形白区，也不增加实时滑块的分割负担。当前仍不根据距离筛掉远处人物，需要后续结合深度判断。[验收与限制](Test-Reports/2026-10-28-Portrait-HeadRepair.md)。

## 高动态深暗区域补偿（2026-10-28）

AdaptiveDynamicRenderer在原中位数统计外保留p2和p90，先clamp小探针边缘并跳过alpha<0.99像素；避免真机采样无效边缘把p2压为0。原0.45锚点曲线之后串联0.12锚点深暗曲线，以已补偿的p2计算需求、目标0.018、最多3EV，且需有足够亮区。Metal仍为一次统一亮度映射，保色相、黑位及单调次序，不生成空间模糊蒙版，不修改曝光。Analysis公开统计用于诊断；拍摄和RAW编辑复用，不把成片再次解码当底片。高对比度影调本身未修改。[实测及未验收项](Test-Reports/2026-10-28-HEIFPro-DeepShadow.md)。

## 静态人像脸部保护（2026-10-28）

PhotoEncoder在已定向的developed源图上，对原生matte或软件portraitMask统一调用PortraitPhotoRenderer.faceProtectedMask，再交给原背景虚化器。静态检测最长边1200，可靠脸框生成有限柔边椭圆，与原蒙版取最大值；不替换全身蒙版、不扩大整体模糊，也不把检测放进实时滑块处理。无脸、检测失败或强度0时沿用原路径。与原蒙版的尺寸/原点映射在合成坐标内完成，不额外镜像或旋转。[验证与局限](Test-Reports/2026-10-28-Portrait-FaceProtection.md)。

## 夜景静态曝光规划与临时输入（2026-10-28）

NightAdaptiveCapturePolicy为A挡夜景生成受硬件限制的曝光基准，保存到CaptureContext，后续批次不重新读取AE。首批自动曝光使用−1/0/0EV相对基准，追加0/0/0EV；夜景仅支持A挡；开启夜景会先切A，切M立即退出夜景。虚拟输入不公开custom时，CameraEngine保存原AVCaptureDeviceInput，并临时使用activePrimaryConstituent物理输入，按原显示倍率换算变焦、传递对焦和白平衡状态；不修改普通取景的系统切镜决策。首批提交前等待新预览帧和两次稳定AF/AWB（最多0.8秒），不附加一次重新对焦。hardwareFinished统一归还原输入，覆盖完成、取消和失败清理。旧输入测光与快门token绑定，避免切到物理输入后的未收敛读数重设曝光需求。

NightPhotoMerger只有自动计划曝光且实际融合成功时，才启用64×64亮度探针决定暗部曲线强度；显式M挡、默认融合及单帧后备不变。相机会话队列只处理输入/请求，配准融合和影调仍在处理队列；没有额外常驻预览计算。内部曝光/路线诊断保留在rows，详情仍只展示既有有效合成帧数，避免重复参数行。[实测与尚未验收范围](Test-Reports/2026-10-28-Night-Exposure.md)。

## 高动态逆光修正（2026-10-27补充）

AdaptiveRAWDeveloper不再把localToneMapAmount固定为0.35，保留各底片默认值；编辑预览复用解码器时仍先恢复该底片初始值。AdaptiveDynamicRenderer在192点线性统计上判断大面积亮区与高反差，以0.14中位目标/最高3EV决定强度，Metal有理曲线在0–0.45严格单调，黑位仍为0。捕获和RAW重新显影共用，普通照片/视频不受影响。正式PhotoKit保存以HEIF为photo、DNG为alternatePhoto；本机已验证读回DNG及覆盖编辑再打开，未扩展为iCloud保证。

## 智拍候选锁定与自动取景（2026-10-27）

SmartCaptureAnalyzer先按可见画幅裁图、最长边768；2026-10-29起跟踪轮询间隔66ms、场景检测间隔0.8秒，最多一次在途。已有目标时`nominateComposition=false`跳过显著性/人体框重新提名，仍保留场景参数判断。显著人物可结合身体范围，其他对象优先objectness显著性，必要时attention回退。最多3个可靠候选交给SmartSubjectTracker，用VNSequenceRequestHandler/VNTrackObjectRequest在同一串行队列维护UUID，并以固定纹理锚点复核；提名顺序变化不会换身份。

2026-10-29修正：对象框输入每帧延续，纹理允许独立恢复；移除0.008坐标死区、主体坐标低通和UI位置补间。短暂漏检显示宽限0.18秒、身份保留0.45秒，不用帧数推断时间；预测位置通过`trackingVerified=false`与真实确认位置区分，自动取景门控拒绝未确认状态。ViewModel对nil也实际调用显示稳定器，且仅在收到不同非空身份时重置；不会一帧漏检就抹掉候选身份。提示迟滞期间也保存最新点位，避免随后漏检跳回旧位置。场景建议抑制不暂停跟踪。候选框、纹理和显示宽限是项目策略，非平台可靠性保证。

SmartAutoFramingGate使用与固定中心圈一致的实际短边半径，稳定0.75秒后最多一次评分/应用；SmartFramingEvaluator结合不同主体占幅目标、边缘留白和有限Vision美学评分，在后台比较至多4幅中心取景。没有可靠改善时保留当前倍率。CameraEngine.ZoomRequest新增默认false的smooth字段，只有智拍启用官方ramp；其他变焦行为默认保持。实际硬件爬坡结束后按倍率投影，对焦到选中主体在新画面的位置，用户AE/AF锁、M挡、48MP倍率边界保留。

CameraViewModel以生命周期/模式/比例/格式/分辨率/倍率/方向快照丢弃过期结果，SmartFramingWork可取消Vision请求；后台停止轮询，恢复重新建立代次。场景建议仍需点应用；逆光人像及异步开启补记来源，M挡不自动退出人像。SmartCompositionGuideOverlay只画最多3个白点和固定白圈，圈短边10%、描边3、点径圈径−6，完成短暂橙色再淡出；不拦截对焦操作。详情见[功能说明](SmartCapture.md)。

## A/M挡48MP固定物理路由（2026-10-30）

普通A挡仍使用系统虚拟多摄。48MP选择后，CameraEngine.highResolutionPhotoRequested在A/M两挡均有效，按当前传感器选择其原生镜头；从2×/8×/35mm等裁切倍率进入时归位同传感器原生焦段。highResolutionLensIDs由会话队列从真实格式能力、物理倍率1及0.5/1/4白名单计算，镜头目录建立后才发布，避免首次启动空能力缓存。48MP选镜固定物理输入，不改动普通A挡的系统微距策略。

prepareHighResolutionPhotoRoute用setPreparedPhotoSettingsArray准备最大尺寸、balanced优先级的JPG/HEIF资源，不再拍摄丢弃帧。highResolutionPhotoConfiguring在资源完成回调后释放，准备时只在对应焦段按钮内显示小加载圈；有代次校验、错误说明及8秒超时释放。回普通分辨率清空prepared设置释放资源，系统普通路由按原规则恢复。maxPhotoDimensions和资源准备仍不是平台保证交付高像素，实际文件继续核对。

模型fixedHighResolutionFocalsOnly过滤裁切档位，但lensBar槽宽仍按完整普通焦段数量计算，所以按钮不放大、共同背景按实际三个按钮收缩。长按识别器、转盘、捏合、A挡实体连续滑块及引擎连续变焦/过期节流请求均禁用；离开48MP恢复。1×不执行24/35mm轮换，智拍仅在当前固定倍率对焦，不改变倍率。

M挡选择48MP时manualExposure=false、使用系统实际AE读数，进入M挡及恢复高像素设置同样不恢复过期手动曝光标记；用户调ISO/快门令manualExposure=true时先切回standard再应用真实曝光。48MP自动曝光用balanced优先级，严格手动12MP仍按speed。手动白平衡保留，快门按下时快照已验证的色温/tint，并在高像素提交前等待官方白平衡锁定回调，避免快速切镜后首张仍带自动WB。焦点控制不改。完整格式边界见[验证记录](Validation.md)。

## 格式弹窗 HDR/高动态双列说明（2026-10-27）

HDR 与高动态开关保持同一行；说明文字拆成下方两列，使用 `frame(maxWidth: .infinity)` 自适应等宽并 `fixedSize(horizontal:false, vertical:true)` 多行显示。HDR 文案由 `hdrFormatDescription` 按 HEIF、HEIF Pro 和不可用格式切换；高动态文案保持固定，继续注册 `format.highDynamic.explanation` 几何与无障碍标识。

## 前置视频按钮透明背景（2026-10-27）

`CameraCaptureControls` 的 `frontVideoCenteringButton` 和 `dualCaptureButton` 移除 `PreviewSurface` 玻璃底，改为透明内容加 `contentShape(Circle())` 保留原圆形热区；图标、强调色、直径、组间距和 `captureControlGeometry` 记录不变。其他按钮继续使用原玻璃材质。

## HDR与滤镜互斥（2026-11-05）

- 产品恢复HDR与滤镜互斥：`hdr` didSet在有滤镜时自动调用`restoreFilterSettingsForOriginal`并保留HDR；`filtersEnabled`在照片HDR时返回false。
- HDR滤镜实验室、Metal预览原型、实验偏好和Metal live桥接代码已删除；正式UI不再有实验入口。
- PhotoEncoder恢复同时写ISO 21496-1与Apple HDRGainMap，系统照片识别HDR；应用内相册PhotoKit请求`preferHDR=true`、`targetHDRHeadroom=4.0`。
- 成片的HDR软肩与单份ISO数据仍保留在编码内部；无HDR+滤镜产品入口。
- 未做全量回归；HDR滤镜实验代码仅保留为未接入原型。

## HDR与微距收尾实现（2026-11-05）

- HDR与滤镜互斥；HDR开启时预览走SDR，右上角显示HDR标识，成片才带HDR。
- PhotoEncoder使用系统HDR数据 → `CIContext.heifRepresentation` → Display P3 SDR基底 + 全分辨率ISO/Apple增益图；不再使用系统直存弱增益图。
- HDR主图仅做0.7EV编码补偿，SDR基底保持原亮度，避免增益比被抵消。
- 微距通过物理超广角/虚拟constituent + 主动AF/锁焦；自动曝光临时+0.5EV后恢复；最近微距5秒内后续成片仍走超广角。
- 未解决：第一张微距后系统把主constituent切回主摄，预览未保持；锁/物理保持方案被系统重置或崩溃，未完成。
- 详细状态与限制见[HDR-Macro-Status](HDR-Macro-Status.md)。

## 高动态显影与RAW编辑配方（2026-10-27）

HEIF Pro 的 HDR 成片现在保留已选 Pro 影调：HDR 分支仅清空滤镜、浓度、调整和虚拟光圈，`requiresImageProcessing` 将非自然影调纳入，`filteredHDR` 先在 SDR 基底套影调，再恢复 HDR 高光；不得在 HDR 恢复后再套影调。高动态仍可与 HDR 同时开启，滤镜继续禁用。

`PhotoOptions.adaptiveHighDynamic`仅在普通HEIF Pro下有效，与HDR独立，存档使用兼容旧版本的可选字段。格式切换、水印或照片合成子模块会关闭开关，不改写相机AE、M挡快门/ISO，也不增加应用包围曝光。相机预览沿用原路线，高动态在成片中计算。

`AdaptiveRAWDeveloper`复用CIRAWFilter，保留EDR中间数据、基础降噪，支持RAW曝光与白平衡控制；`AdaptiveDynamicRenderer`从最长边192点浮点小图统计亮度分位数，决定保留黑位的单调有理暗部曲线和连续高光肩部。全尺寸Metal处理保持RGB比例，不增加应用空间模糊式局部映射；局部影调基础使用苹果RAW解码能力。HDR套滤镜时拆分SDR颜色输入与逐像素亮度余量，滤镜后恢复，避免有限域LUT抹掉HDR层次；此保护只接入新的RAW高动态路径。

HEIF的EXIF UserComment保存版本化`PhotoAdjustments`显影配方，DNG作为alternatePhoto资源保持原字节。`RAWPhotoDevelopment`为预览复用缩放RAW解码器、最终保存使用全尺寸解码器，保留拍摄像素预算，曝光/色温/色调只在RAW阶段应用一次。输出使用整像素HEIF尺寸并更新EXIF几何和色彩标记，保留真实拍摄参数。`PhotoEditSession`新增默认nil的RAW开发器，普通照片/Live编辑仍沿用旧分支。

`RAWPhotoEditLoader`只对已附带DNG且带可识别配方的资产启用重新显影；第三方或不理解的编辑配方保留现有扁平编辑流程，避免重置别人编辑。覆盖保存使用官方HEIC编辑输出URL和版本6的PHAdjustmentData，另存保留HEIF+DNG；自动保存失败的临时资源也可从底片编辑。读资源可取消，编辑预览使用既有最新值节流/修订门控。Photos实际写入重开尚未验收，不将文件级验证当作完整相册回路通过。[验证记录](Test-Reports/2026-10-27-AdaptiveDynamic.md)。

## 前置视频原生Center Stage（2026-10-27）

`VideoCaptureSettings.format`新增默认关闭的requiringCenterStage，只接受格式声明的支持及专用帧率范围。引擎缓存单设备兼容规格，使用app控制模式启停系统Center Stage，KVO读取实际active；开启前关闭照片深度/蒙版输出并保留几何畸变校正。普通照片、原Smart Framing、双拍和自动微距不改为软件人物追踪。

VM管理独立开关意图、兼容规格、宽取景、互斥和保存状态；手动宽窄、双拍、子模块、前后镜头及照片/视频切换退出，后台保留意图并在相机恢复时重新激活。按钮局部加载，激活前禁止提前开拍。系统原生构图不做额外应用逐帧Vision处理；测试里的Vision仅分析临时样本。

`centerStageRectOfInterest`按最终裁切区域引导系统构图，退出恢复整幅。必须读取recordingOutput自动配置后的实际宽高：本机标称1920×1080时输出为1080×1920，不可直接用activeFormat尺寸算ROI或滤镜缓冲池。新前置人物居中预览保留原生方向；MovieRecorder新增默认nil的nativeCaptureRotationAngle，仅本路径按持续持有的官方RotationCoordinator写入固定轨道变换，滤镜、裁切和编码仍一次完成。普通路线默认分支保持。视频描述记录开拍时实际Center Stage状态。

此节替代下方历史记录中“视频人物居中始终关闭”的表述；不恢复照片自动构图按钮。[实测与限制](Test-Reports/2026-10-27-FrontVideo-CenterStage.md)。

## 光圈滑块固定轨道（2026-10-27）

iOS26+通过VirtualApertureContinuousSlider封装UISlider，普通/高亮共用自定义轨道图以停止系统动态轨道外观，保留原生连续和无障碍事件；按下/完成/取消与销毁桥接现有交互预览门控。PreviewSurface新增默认true的interactive参数，仅光圈条设false，保持单层玻璃，其他调用不变；iOS18沿用原Slider分支。[验证与限制](Test-Reports/2026-10-27-ApertureSlider-Background.md)。

## 视频虚拟光圈与控件几何所有权（2026-10-27）

`effectiveCaptureLook`为SDR/P3视频提供virtualAperture，复用VideoFrameFilterRenderer与MovieRecorder一次编码；录制队列按实际供图镜头传入virtualApertureAllowed，系统微距超广角帧暂停星芒，其他滤镜和写入流程保持。录制器拒绝不兼容色彩/RAW静默漏处理。VM管理视频互斥、默认规格适配、状态保存及镜头发布后刷新look；视频描述元数据独立记录软件光圈。四项子模块沿用三列网格。`CaptureControlGeometryModifier`注册UUID所有权，旧淡出视图只能释放自己的位置记录，避免清掉新滑块；生产避让与测试共用。[验证及限制](Test-Reports/2026-10-27-VideoVirtualAperture.md)。

## 点光源空间门控（2026-10-26）

`VirtualApertureRenderer`改用通用`aperturePointSeeds` Metal内核：局部峰值候选后，两圈32方向邻域检测亮度延伸，以相对画面尺度抑制面源/长边。第0输入ROI按1.45倍圈半径+2扩展，辅助层384上限保持，不读回CPU、不改相机对焦路径；不是连通域面积算法或语义分类。[验证与限制](Test-Reports/2026-10-26-VirtualAperture-PointOnly.md)。

## 虚拟光圈上限重映射与复位（2026-10-26）

效果系数改为`pow(position(f) * position(6), 2)`，显示范围与默认值保持，最大档对应上一版ƒ/6。数值按钮调用`resetVirtualAperture`，复用既有look更新/保存并在值改变时触感反馈；宽高、布局、连续交互预览机制保持。[验证记录](Test-Reports/2026-10-26-VirtualAperture-Reduced.md)。

## 星芒处理与交互预览修正（2026-10-26）

`VirtualApertureRenderer`辅助层上限改384、四方向各一次模糊并补偿亮度，预览先按900宽等比处理。光圈Slider的onEditingChanged复用既有交互代次门控，结束/消失释放标志；参数更新只提交look，避免每次刷新导航配置。原768及12次模糊章节为历史实现。[验证及限制](Test-Reports/2026-10-26-VirtualAperture-Responsive.md)。

## 虚拟光圈星芒管线（2026-10-26）

`CaptureLook.virtualAperture`在预览与照片处理末段调用`VirtualApertureRenderer`；辅助峰值图≤768长边，通过Metal局部高亮提取、Core Image双向运动模糊和独立增亮内核形成八芒，保留原CIImage属性。引擎按实际物理供图设备限制主摄/长焦，系统微距不强制干预。`PhotoEncoder`保留真实EXIF光圈，将软件值写入UserComment独立标记；诊断与详情从真实文件解析该字段。VM管理连续对数映射、互斥/镜头与格式限制及保存恢复，UI共享焦段条宽高、现有上方偏移和小窗避让。[验证与边界](Test-Reports/2026-10-26-VirtualAperture.md)。

## 拍照对焦辅助独立采集图（2026-10-26）

`FocusNavigatorGraph`持有后置长焦+广角独立MultiCam会话及其自身视频输出；引擎原AVCaptureSession/输入/照片输出始终保留，不搬运输出、不替换普通session对象。主路借现有预览单任务门控渲染，辅助路独立低频缩图，原子修订号拒绝停止后的迟到回调。资源预算检查、运行中断和压力critical/shutdown走恢复保护，失败签名缓存防止每帧反复重建。

逻辑8倍/开关/后置/普通拍照共同控制进入；照片捕获先恢复原设备格式、倍率及手动参数并启动普通图，原捕获流程完成后再恢复导航。视频、其他子模块和HDR实时预览不启动该图。UI固定3:4导航+视场角估计白框，`focusNavigatorLayoutRect`随主画幅同步算大小，复用既有生产控件几何和避让算法；只消费拖动，不提供横竖切换或主副交换。偏好独立保存，临时导航图不入成片。[验证限度与保留失败](Test-Reports/2026-10-26-PhotoFocusNavigation.md)。

## 双拍开启状态不参与启动恢复（2026-10-26）

`captureStateSnapshot`对兼容字段`dualCaptureEnabled`写false，启动忽略旧true标志，只恢复小窗构图及待手动应用的前置倍率偏好。`restoredDualFrontWide`在下一次手动进入时消费；会话生命周期保持原后台暂停/返回恢复路径。测试使用DEBUG完整恢复任务状态，不能用首帧ready替代启动参数恢复完成。[验证范围](Test-Reports/2026-10-26-DualCapture-DefaultOff.md)。

> 顶部为最新实现，按日期倒序排列；10-23 的固定 10×1 秒慢门、42 秒测量和速度优先尝试属于历史阶段，当前以 10-24/10-25 的静态单帧包围、自适应多帧和双拍章节为准。

## 小窗边缘锚点（2026-10-26）

`DualCaptureInsetLayout.resized`在原位置等于归一化安全边缘（容差0.0001）时固定对应边，而非固定中心；其余位置保持中心。此计算供画幅切换和主比例变化共用，之后仍经控件/HUD避让，不能绕过障碍强制贴边。对焦辅助只记录技术讨论：可复用小窗交互，后置长焦+广角采集/导航映射需单独验证，尚未接入。[验证与方案](Test-Reports/2026-10-26-DualCapture-DockedEdges.md)。

## 双拍辅助显示持续避让（2026-10-26）

小窗按钮复用前置广角双箭头、字体与选中颜色规则，保留独立点击及原画幅逻辑。直方图及`VideoRecordingHUD`在旋转占位之后、外侧填充之前上报生产几何；两辅助开关都关闭时不挂载HUD，消失清理障碍。`legalDualInsetRect`按控件类别及显示开关过滤：录像释放隐藏操作按钮，但保留直方图/容量与电平/计时，几何变化继续走已有合并校正。[验证边界](Test-Reports/2026-10-26-DualCapture-HUDAvoidance.md)。

## 小窗UI与几何避让（2026-10-26）

`dualInsetAspectButton`作为`DualCaptureInsetSurface`右下角overlay独立命中，不占原生拖动/双击手势；按钮不进入合成图。`captureControlGeometry`除DEBUG断言外也上报受选控件到生产几何字典，预览自身同样上报全局框。ViewModel将控件加6点边距后转为归一化障碍，`DualCaptureInsetLayout.avoiding`枚举障碍边界的候选位置并投影到最近合法点，结果同时供透明热区和编码使用。

几何更新合并到下一主队列事件，大小/录制状态变化时校正；固定控件的位置不动。上方子模块overlay需依据辅助按钮实际框和`upperButtonOffset`推导视觉位置，不能把SwiftUI外层布局框当已offset的图标位置。[验证限制](Test-Reports/2026-10-26-DualCapture-InsetAvoidance.md)。

## 双拍小窗横竖画幅（2026-10-26）

引擎发布`dualCaptureInsetLandscape`，`DualCaptureInsetLayout.resized`按主输出比例计算16:9横幅的归一化高度，保留窗口中心并钳制边界；`clamped`保留窗口尺寸，拖动不再把横幅重置为旧尺寸。规格/比例变更时重新提交相同形状的合成矩形。前置倍率切换成功后再提交横幅状态，失败不更改画幅；异步操作期间按钮内进度和输入门控避免连点反转。

ViewModel保存进入前广角状态，冷启动存档新增可选横幅和返回状态，旧存档默认竖幅。界面新增独立画幅按钮，保留小窗原生拖动/双击手势；编码仍使用`DualCaptureSource`中的同一矩形和等比例填充，不增加传感器旋转或二次编码。[测试边界](Test-Reports/2026-10-26-DualCapture-Landscape.md)。

## 双拍规格策略与拖动坐标（2026-10-26）

`DualCapturePolicy`维护25种实测组合并与本机原生MultiCam格式/编码能力求交集，`CameraEngine`发布目录供现有选择器禁用无效组合。色彩/帧率/尺寸变化替换独立采集图，编解码器/比例变化复用采集图；配置请求使用修订号收敛到最后一次，失败恢复前一配置，普通会话不并行运行。前置1280方形低成本路线最多30帧，标准/广角倍率切换不重建会话。

`DualCaptureInsetLayout`在归一化左上坐标中保存窗口，映射预览旋转/裁切及反向拖动位移；`DualCaptureInsetSurface`使用UIKit单击消费、双击交换和窗口坐标累计拖动。`LatestValueThrottle`将最终位置送到合成队列，录制开始前刷新，合成使用同一位置而非仅移动透明热区。存档新增可选位置/前置画幅字段，旧存档兼容；退出恢复普通ProRes子规格。[验证限度](Test-Reports/2026-10-26-DualCapture-ExpandedControls.md)。以下描述保留早期基础版阶段。

## 双拍兼容性配置和录像HUD（2026-10-26）

`DualCaptureSource.Configuration`为同一采集/合成/写入路径提供规格、前置尺寸/设备/倍率和独立帧率参数，供真机能力矩阵验证；CameraEngine正式调用保留默认基础档，不自动解锁界面。主画面输出按分辨率边界裁切目标比例，避免窄画幅过度放大；P3使用对应上下文和色彩附件。前置帧率低于后置时，副帧新鲜度门限按较慢一路计算，仍不是硬件同步曝光。

相机控件区将前置照片的两按钮、前置视频的两按钮各作为一组居中；不改变左右A/M和辅助按钮位置。录制计时由CameraView顶部工具栏容器迁入viewfinder，与直方图/容量共用预览边缘布局：录像时5点顶距，预览宽不足300点时左右数据面板下移至34点给计时留位；停止恢复旧工具栏避让。动画只作用于这些数据面板和计时，主预览图片仍禁用隐式动画，计时不跟随横拿旋转。[验证限度](Test-Reports/2026-10-26-DualCompatibility-and-RecordingLayout.md)。

## 同步双拍独立采集图（2026-10-26）

入口后续修正：`CameraCaptureControls`在完整焦段容器上独立展示双拍按钮，不再嵌入`CameraFocalButton`的窄边界/广角分支。广角中心不变，双拍按钮在其右侧并带独立圆形玻璃背景。DEBUG几何记录仅在实际离开入口状态时清理，避免过渡旧视图的`onDisappear`删掉新视图记录。

`DualCaptureSource`持有独立`AVCaptureMultiCamSession`、前后视频输出及音频输出，采用Apple AVMultiCamPiP示例的显式连接和最近副帧合成；只保留一张副帧，PTS差超过2/30秒不合成，四缓冲像素池限制分配。合成与现有`MovieRecorder`同在recordingQueue，预览使用原有单任务门控；一次编码，不做录后转码。普通`AVCaptureSession`在双拍前停止，退出先拆双拍图并恢复格式/倍率，随后恢复普通规格；两图不同时启动。

ViewModel暂存普通视频规格，双拍基础档锁定HEVC SDR 1080p30/16:9；入口保持原广角按钮中心不变，小窗点击交换只对取景内容使用既有过渡。A/M配置作用于当前主镜头，范围变化同时约束UI显示值；录制白平衡偏好锁定两路。保存状态新增可选`dualCaptureEnabled`，旧存档默认关闭；冷启动完整焦段ID因窄幅倍率改变而失配时后备到前置标准入口。文件description写入同步双拍拍摄类型及双路说明。

前置先从视频进入时，不能把缺少动态画幅的1080p格式作为照片恢复基线；仅在该特殊分支按真实`supportedDynamicAspectRatios`及照片尺寸能力保留原生照片格式。系统中断、运行错误和严重压力走双拍退出保护，后台停止采集并保留会话意图；真机保护场景的限度见[验证报告](Test-Reports/2026-10-26-DualCapture.md)。

## 前置宽高比与广角联合往返（2026-10-26）

`CameraViewModel.toggleFrontPhotoAspectRatio`将主线程当前逻辑焦段/显示倍率交给`CameraEngine.toggleFrontPhotoWideAspect`。后者在会话队列保存设备/画幅/真实倍率/焦段的临时快照，横幅取`.wide`候选，第二次按快照恢复。`applyFrontDynamicAspectRatio`复用系统动态画幅与时钟过滤，在画幅完成后设置目标倍率，更新逻辑焦段和M挡变焦锚点，并用两帧warmup隔离过渡缓冲。

快照按请求意图切换而非迟到的界面布尔值，`frontAspectInFlight`和既有请求代次处理连续点按。直接设置画幅会清除临时往返快照，冷启动无撤销历史；进入视频则取消未完成的照片回调。照片横幅手动选择优先于方向自动构图，视频既有策略不变。捕获仍读取已确认的原生画幅/真实倍率，按钮位置及局部过渡不变。[验证报告](Test-Reports/2026-10-26-FrontWideAspect-Return.md)。

## 普通M挡长曝光恢复自动（2026-10-26）

`setExposure(nil,nil,bias:)`向`configureDevice`传递`restartLongPhotoExposure`意图。仅M挡真实custom曝光至少0.5秒、会话已运行/出帧、无在途照片、无AE目标锁且没有视频/流畅辅助/原生HDR或人像预览时，暂停同一个session，释放长帧过渡后按原AE/HDR策略恢复。保持原input/output、format、zoom和look；设备锁在`startRunning`之前释放，读数代次增加以丢弃旧异步结果，恢复后沿用一帧warmup，不清空预览或新增冻结覆盖层。

`PreviewRevision.current`线程安全读取生命周期代次；在配置排队之前获取，停机或重启意图使旧恢复失效。无新增循环计时或永久高频采样；既有1.5秒读数快传窗口继续使用。DEBUG旧路径开关/次数仅用于同场景A/B，正常运行默认优化，不接入产品设置。[验证报告](Test-Reports/2026-10-26-SlowestShutterAuto-Recovery.md)。

## 夜景A挡与现代曝光（2026-11-06）

夜景不再支持M挡：开启夜景时若当前为M会先切A；夜景下切M立即退出夜景并清理环境触发/独立路线。独立夜景默认必须同时满足“用户开启夜景”“环境已触发”“照片A挡”，仅在环境触发后才切48MP独立会话，避免一亮起夜景就进入重负载路线；实验设置“强制独立夜景（测试）”可临时跳过环境触发，默认关闭。

读数增加`customExposure`/`exposureTargetOffsetEV`。环境触发及采集帧数估算共用偏差修正，缺少有效偏差时不伪造测光。3/6/9分批、运动停止追加、取消释放和合成信息沿用现有管线；固定手动曝光融合不宣称实现不同曝光HDR。DEBUG源帧回调仅供逐张EXIF验收，不写相册。[验证记录](Test-Reports/2026-10-25-NightManual.md)。

## 子模块入口图标（2026-10-25）

`PhotoSubmode.symbol`和`VideoSubmode.symbol`是弹窗选项与入口按钮共用的系统图标映射。视频顶部格式按钮在 `videoCodec == .proRes` 时把 `proResSpecification.rawValue` 作为 `videoToolbarButton` 的第二行 detail；HEVC/H.264 保持单行，不改变按钮高度和其他四项布局。`CameraViewModel.shootingModeButtonSymbol`读取当前真正启用的子模块，照片默认`camera.aperture`、视频默认`video`；未完成适配的子模块不伪造启用状态；智拍已接入实际逻辑。`shootingSubmodeEnabled`统一入口选中颜色，包含夜景/人像。`ShootingModeButtonSymbol`在固定22点区域局部opacity过渡，外层按钮热区、玻璃背景及既有方向旋转不重排；减弱动态效果沿用`AppTheme.popupAnimation`。不新增相机配置请求或采集任务。

## 组织方式

项目采用按功能划分的 MVVM。当前保持一个应用 target 和一个测试 target，使用系统框架，没有引入空模块或第三方依赖。文件目录直接映射 Xcode 同步组；添加 Swift 文件无需手工注册到 pbxproj。`Resources/Info.plist` 是同步组例外，通过 `INFOPLIST_FILE` 参与构建，不作为普通资源重复复制。

## 职责与依赖

| 目录 / 类型 | 职责 |
| Features/Library / VideoEditorView 与 VideoEditorViewModel | 视频裁切、滤镜/Log LUT 选择、SDR/P3 参数调整、预览合成和另存导出；不修改源视频 |
| --- | --- |
| App / AppDependencies | 应用生命周期入口、创建具体服务、连接拍摄结果与照片管理 |
| Features/Camera / CameraView | 页面布局、生命周期转发、观察硬件和功能状态；按工具栏、取景框、控制区、面板与设置拆分扩展 |
| Features/Camera / CameraViewModel | 拍摄参数、A/M 切换、倒计时取消、镜头选择、弹窗状态与参数绑定 |
| Features/Library / GalleryViewModel | 系统照片授权状态、分页元数据、图库变更刷新、删除选择项 |
| Features/Library / PhotoLibraryViewModel | 最近照片、自动保存、保存标识、拍摄/编辑/删除互斥与错误状态 |
| Core/Capture / CameraEngine | 摄像头授权、串行会话配置、预览与照片处理、设备能力及实时读数 |
| Core/Imaging | 滤镜配方、画幅裁切、输出边框和直方图，不依赖 SwiftUI |
| Core/Motion / DeviceLevelMonitor | 持有并停止 Core Motion 更新，输出水平仪角度 |
| Core/PhotoLibrary | PhotoLibraryService 接口与 SystemPhotoLibraryService 实现，封装 PhotoKit 权限、读写、分页元数据、可取消图片请求及图库观察 |
| Shared | 通用主题、玻璃材质和系统分享组件 |
| Resources / Support | 正式资源与配置 / 模拟器和测试使用的示例图生成 |

依赖方向是 App → Features → Core。Shared 提供展示组件，Core 不引用 Feature 或 SwiftUI。相机引擎通过主队列回调输出处理后的照片；AppDependencies 将结果传递给照片 ViewModel，Engine 不依赖相册功能。相机 ViewModel 订阅拍摄状态，保护照片保存和删除与拍摄的互斥。

## 状态与线程

- 原生照片请求收尾（2026-10-24）：`captureContexts` 仍按 AVFoundation uniqueID 在 session 队列管理；`pendingCaptureTokens` 在主线程记录尚未终结的逻辑请求，`completeCapture` 先移除 token 再按快门 sequence 排空结果，迟到/重复结果直接忽略。每次原生提交安排一次弱引用延时检查，匹配 uniqueID、上下文身份和 `waitingForNativeCompletion`；最终回调清除此等待，夜景批次间 CPU 判断不算原生等待。标准处理人像预算 12s，其他处理格式 20s，RAW/Live 45s，是应用级保护而非平台时限。
- 漏最终回调时撤销旧照片输出的全部上下文，为每个失败序号提供空终结，释放硬件、快门、权重与容量，后序成功照片仍正常按序交付。恢复先禁止向旧会话提交，再复用既有重建流程移除旧输出并创建新的 `AVCapturePhotoOutput`，重新配置并等新预览；后台只清理，下次用户 start 再替换输出，不能自动唤醒。单张无数据时给出重拍错误，不自动补拍新时刻的场景。
- 原生人像请求超时的设备 ID 仅在当前引擎生命周期记录。重建输出时关闭该设备原生深度/蒙版交付，但保留现有 Vision 处理格式人像后备，不关闭用户的人像模式；没有失败的设备不受影响，重新创建 App 引擎后重新探测。测试注入在真实硬件完成后丢弃应用最终收尾，正式运行覆盖值为 nil、丢回调标志为 false；不将注入等同于系统服务故障。
- 功能 ViewModel 标记 `@MainActor`，只在主线程更新 UI 状态。
- AVFoundation 会话操作、参数配置及预览处理位于 `camera.session` 串行队列；照片渲染位于 `camera.photo` 队列。
- CameraEngine 的发布状态和拍照结果统一回到主队列。Core 的服务不能直接调用 View。
- PhotoLibraryService 的完成回调约定在主队列调用。测试替身也遵守这一约定。
- 保存/删除期间禁止新拍摄；处理照片期间禁止保存/删除旧照片。失败后保留当前照片，只有确认删除成功才清空。
- 已保存照片仅通过本次保存返回的 PhotoKit 标识删除。完整权限下资产不存在视为已删除，有限权限下查不到资产则保留预览并提示。
- 倒计时使用取消任务及操作标识避免旧任务修改新状态；离开页面、进入后台或翻转镜头时取消。

## 新功能放置规则

1. 新增独立用户功能时创建 `Features/<Feature>`，按实际需要添加 Models、ViewModels、Views、Components；无需创建空目录。
2. 页面布局放 View，状态与动作放 ViewModel；本地 UI 暂态（如分享 sheet、删除确认）可保留为 `@State`。
3. 平台权限、文件读写、网络等放 Core 服务；需要替换外部依赖进行测试时先定义小接口，再在 AppDependencies 组装。
4. 仅被相机使用的组件留在相机功能中，跨功能共享后再移入 Shared。
5. 测试目录对应功能与核心能力。优先测试状态转换、失败处理、取消与图像输出，避免测试只重复实现。
6. 主题色通过 AppTheme，图标和资源位于 Resources；设计原稿和界面截图留在工程根目录之外的 Design、Preview，不进入应用包。

## 验证范围

现有测试覆盖滤镜、裁切、边框、直方图，模拟器拍摄设置传递，A/M 自动恢复，弹窗互斥，倒计时取消，以及照片保存/删除成功、重复操作、权限失败和操作期间状态保护。图库测试覆盖有限权限、拒绝访问、分页、系统变更刷新、失败保留、删除当前或其他照片及过期查询回调。

模拟器测试不能证明硬件参数或系统相册权限 UI 的行为。真机仍需验收不同镜头、曝光/对焦/白平衡、闪光、镜像、后台恢复以及授权、取消删除和 PhotoKit 读写。

## 系统相册浏览

照片元数据每页 60 项，按拍摄日期倒序。LazyVGrid 只为可见照片请求缩略图，页面离开时取消请求；打开单张照片才请求较大图像，允许 PhotoKit 从 iCloud 获取图像。使用请求标识丢弃过期图片回调，使用查询代次丢弃过期授权与分页结果。

相册服务通过 PhotoBrowserService 输出可替换的浏览接口，通过 PHPhotoLibraryChangeObserver 触发刷新；最近拍摄和系统照片删除共用 PhotoLibraryViewModel 的互斥状态，删除本次保存的照片会同时清理最近预览。图库同时读取照片和视频；视频在网格显示播放标识，打开后由 SystemVideoView 播放、分享或删除。视频保存完成后，PhotoLibraryViewModel 在内存中暂存一次性视频详情 ID；相机第一次打开图库时消费它，图库等目标视频进入当前照片页后直接推入视频详情。返回相机后再次打开图库会显示列表；进程重建后该临时 ID 不存在，因此不会恢复到旧视频详情。仍不提供命名相簿管理。

照片与视频详情共用 `GalleryPageTransition` 的左右方向和时长；照片保留现有缩放/拖动手势，视频在播放画布上捕获当前帧作为离场画面。详情页标题、标识和底部按钮固定，只有媒体画布参与切页；启用系统“减弱动态效果”时改用短淡入淡出。

有限授权管理采用 Apple 的 [presentLimitedLibraryPicker](https://developer.apple.com/documentation/photos/phphotolibrary/presentlimitedlibrarypicker(from:completionhandler:))，系统图片请求采用 [PHImageManager](https://developer.apple.com/documentation/photos/phimagemanager)。

## 视频录制

- 模式切换由底部按钮直接完成。进入视频前按设备保存照片的 `activeFormat`、色彩空间、最短/最长帧时长及倍率，再添加 recordingOutput 和 audioOutput；视频使用 `.inputPriority`，在 `camera.session` 串行队列中按能力目录显式选择格式和帧间隔，避免固定 1080p preset 提前重置倍率。离开时移除录制输出，在同一事务中恢复照片设备状态并配置照片输出；共享传感器的路由先恢复非当前设备，最后恢复当前输入。录制中 `videoBusy` 阻止切镜、变焦和模式切换，规格配置期间 `videoConfiguring` 阻止开始录制并显示快门加载圈。
- `MovieRecorder` 以 AVAssetWriter 直接写 HEVC、H.264 或六种常规 ProRes。HEVC/H.264 的“默认”不写 `AVVideoAverageBitRateKey`，交给编码器选择码率；低/中/高按 HEVC 1080p30 的 8/16/28 Mbps、H.264 1080p30 的 10/20/35 Mbps 作为基准，再按像素数、帧率平方根和 10-bit 色彩调整目标平均码率。默认档剩余容量按 12 Mbps 估算，不代表写入码率。ProRes 使用对应系统编码器的质量档位，不套用 HEVC 的 ProfileLevel 或目标码率。音频 AAC 128 kbps/48 kHz 双声道。常规编码通过 ResizeAspectFill 一次缩放裁切，track transform 处理竖屏方向和前置镜像。五种视频比例共用偶数像素取整，720p/1080p/4K 为 16:9 基准；不二次编码。ProRes 优先 10 位 4:2:2 采集，超过 60fps 使用带宽更低的基础设备格式；编码规格不保证原始采样为 4:4:4，也不能把 8 位源转换的输出宣称为原生高位深数据。
- 录制输出使用原生 8-bit 双平面 YUV，避免高规格录制走 BGRA 的额外带宽；普通设备按选定分辨率设置输出尺寸，动态前置传感器保留原生缓冲尺寸并在编码时缩放，避免不支持固定输出尺寸的异常。预览独立控制图像处理尺寸；照片模式按约 30 帧节流，视频模式从线程安全的 `LivePreviewState.Snapshot.videoFrameRate` 读取当前实际采用的帧率作为处理节奏，不再固定封顶 30 fps。实际预览交付仍受设备输出、图像处理负载和显示刷新限制，目标帧率不等于屏幕扫描频率。音频同时供录制和电平计；首个视频样本确定写入时间基准，之前的音频丢弃，随后保留各自时间戳。
- SDR/P3 视频可应用照片滤镜及其色彩、明暗和效果参数；HDR/RAW 不套照片滤镜，Log/Log 2 使用独立 LUT。视频不使用照片的 Live/48MP 或边框设置。视频支持 A/M 切换，M 挡显示照片同款六个参数按钮；录制中禁用模式、镜头和变焦切换，并隐藏工具栏、模式、拍摄辅助、M 挡参数及快门以外的底部入口，保留占位和原位置。停止后恢复录制前 A/M 控件。退出视频恢复进入前的照片 A/M 和画幅，同时保持切换时的当前倍率，包括在视频中主动调整的新倍率。
- 视频顶部五项等宽。`VideoCaptureSettings` 携带分辨率、帧率、色彩空间、编码和 ProRes 规格；基础设备格式目录按设备缓存，编码器硬件能力从 VideoToolbox 列表缓存。视频 Open Gate 由独立布尔状态控制，不作为画幅选项；活动格式必须出现在设备 Open Gate 能力目录中，开启后只开放 4:3 和 1:1，其他比例保留但禁用；旧持久化的 Open Gate 画幅会迁移为 4:3 + 开关开启。照片模式不提供 Open Gate 入口。视频比例弹窗先列出画幅选项，再显示独立开关和应用设置同款说明按钮；说明窗中显示支持比例、HEVC 格式，以及按活动镜头 `openGateVideoSettings` 能力分组的色彩空间、分辨率与离散帧率端点，帧率只显示数字、不附加“fps”，空列表显示“暂无可用规格”。说明内容不占用画幅选择面板空间。帧率范围不代表中间所有整数帧率均可选。`VideoColorPipeline` 明确 SDR709、Display P3、HLG2020 与 Apple Log/Log 2 的采集、像素格式和写入属性；HEVC 使用 Main/Main10，H.264 仅 SDR/P3。Log 写入属性使用 iOS 27 接口并按版本禁用。Log 2 不错误标为 Rec.2020，HDR 为 HLG。预览独立使用 sRGB/Display P3/高动态范围 P3 图像；Log/Log 2 可通过 `LogLUTCube` 在预览侧查看 LUT，不修改未开启烧录的录像帧。切镜或编码不兼容自动回退并发布实际值，恢复照片色彩状态。设置修订合并与手动曝光帧间隔限制保持原有实现。
- `ExternalVideoStorage` 使用 AVExternalStorageDeviceDiscoverySession KVO 发现磁盘，仅在有适用磁盘时请求官方访问授权；按连接状态、系统推荐状态及保守剩余空间门限（大于 2GB，非苹果最低要求）判断资格。录制前重新核对并取得官方 security-scoped MOV URL。RAW 使用物理镜头的 12 位 packed Bayer 格式；预览采用系统代理输出，写入采用官方 recommendedVideoSettings 与 recommendedMovieMetadata。白平衡通过 `setWhiteBalanceModeLocked` 锁定当前值后，必须等待 Apple 完成回调确认；回调内先复核会话仍运行、输入未更换和编码仍受支持，再经 `RAWVideoWriterConfiguration.read` 检查设备实际为 `.locked`，按顺序读取推荐编码设置与影片元数据，最后创建写入器。Apple 明确要求 RAW 的 `recommendedMovieMetadata` 查询发生在白平衡锁定后，否则会抛出 Swift `do/catch` 无法捕获的 `NSInvalidArgumentException`；推荐编码设置为 nil 时停止准备，不继续读取元数据，并释放目的 URL 的安全作用域、恢复白平衡；拍摄设置中的白平衡锁定默认关闭，开启时对普通视频也采用此时序，设置独立持久化。录像完成、失败或取消后恢复录制前的白平衡模式；白平衡锁定尚未完成时取消会继续保持快门忙碌状态，直到恢复完成，避免下一次录像请求与清理竞争。RAW 为满足其录制要求仍自动锁定。`RecordingAccess` 以幂等 lease 持有 URL 安全作用域，在 AVAssetWriter 完成、失败或取消后、向界面回报结果前显式释放。RAW 不经普通缩放 adaptor，不任意裁切或自动导入/删除外接文件。拔盘使 RAW 禁选并停止录制，完成后回退 HEVC。三星 T7 上的实际写入、Files 删除和拔盘恢复仍需真机端到端验证。
- 视频 HUD 位于预览右上角，时间面板和 L/R 电平独立开关，默认均关闭；剩余时间按当前规格的目标视频码率 + AAC 128 kbps、附加 5% 开销估算，每 10 秒刷新，并在用户切换码率或录像规格后立即重算。录制计时在工具栏下方，仅录制时显示。固定焦段横条录像时隐藏并保留占位；系统微距图标独立于隐藏的 A/M 按钮，A 挡照片和视频（含录像中）按相同 macroActive 状态显示，不更改镜头判定逻辑。
- 直方图保持在预览左上角，左边距 5；横屏时只旋转内容，顶部按 `max(5, hudTop)` 避让工具栏，位置不换角，旋转动画约 0.22 秒。
- 录制器创建、音视频追加和 finish 均限制在 `camera.recording` 同一串行队列，`camera.session` 只负责会话和读取设备配置。首个视频帧追加成功后才发布 recording 状态；ViewModel 订阅该状态启停单调时钟。停止时先关闭录制状态与首帧回调令牌，finish 完成前仍保留 busy，避免重复停止提前释放快门；无首帧的取消清理临时文件，写入失败主动结束录制并报告真实错误。
- 模式请求用线程安全修订号跳过过期目标，相同输入/输出不重复提交，麦克风授权避免重复发起；保存期间快门显示加载圈并禁用。帧率为 24/25/30/50/60/120，默认 30；菜单启用状态基于当前相机路由实际公布的 `supportedVideoSettings`，切换 A/M 后重新读取能力，因此某路由不支持的帧率会禁用而不会让工具栏与实际采集规格脱节。iPhone 17 Pro 本次真机结果是 A 挡不提供 120 fps，M 挡 SDR 物理镜头路由提供 720p/1080p/4K 120 fps。
- 照片/视频切换时，录制输出、麦克风输入、preset、设备格式与倍率、预览连接及照片输出的配置共用一个外层会话事务；辅助方法的嵌套事务由最外层统一提交，避免每一步分别重启取景管线。照片状态必须在变更 preset 或输出之前保存，不能把已变成视频格式和 0.5× 的设备状态当作照片快照。进入视频先退出照片 HDR，再交由显式视频格式管理；返回照片先移除录制输出，再恢复设备和 Live/HDR，避免误判 Live 不支持。A 挡的后置输入沿用系统虚拟多摄及自动主镜头/回退候选，M 挡沿用物理镜头路径；不增加强制主摄、距离阈值或定时切镜。
- 自动化与验证：`BasicVideoPhysicalTests`、`VideoWorkflowTests`、`VideoOverlayLayoutTests` 覆盖录像、音轨、前置、返回拍照、后台计时、立即取消、100 次模式请求和 20 种 HUD 布局；`VideoModeTransitionTests` 补充模式切换延迟及 Live/HDR/M 挡往返恢复。2026-10-19 定向真机回归共 9 项通过，详细指标和范围见 `Validation.md` 当日记录。`BasicVideoSaveIntegrationTests` 的 `memset` 编译错误已修正；真实 PhotoKit 写入测试仍需已授权的模拟器，不向用户真机相册加入诊断视频。

- 视频详情：VideoDetailsReader 通过异步轨道 API 读取实际尺寸/变换、帧率、时长、码率、编码、色彩与音轨，复用 PhotoDetails、PhotoInfoPresentation 和 PhotoInfoPanel。返回按钮和日期/位置标题在同一行垂直居中，底部五项操作保持固定。时长、滤镜和 LOG/LOG2 标识间距为 5 点，位于播放条右上方。独立的 videoPlaybackAngle 环境值保留设备角度，不受图库的 captureControlAngle=0 覆盖；仅中央视频和播放条/标识旋转，±90° 时交换逻辑宽高并使用 AVPlayerLayer.resizeAspect 等比例完整显示，顶部和操作栏不旋转。图库、静态照片和编辑仍保持竖屏。旋转保留原播放器实例、时间和音量，退出暂停并取消载入请求；文件详情任务随页面退出取消，加载圈放在详情按钮。录制时保存日期、设备、可选 GPS/版权和参数快照到 QuickTime 元数据；开始时 ISO、快门、EV、倍率、镜头、光圈、白平衡和色调明确标为快照，不能代表整个自动曝光过程。外部视频缺失的字段不补造。
- 水平仪：CameraLevelReading 将重力 roll 归一到最近的直角参考，CameraLevelIndicator 跟随控件角度旋转，LevelHapticGate 对残余倾角共用保持时间、迟滞和冷却；相机几何布局不变。

## Live Photo 与取景倍率

开启或关闭 Live Photo 会在 `camera.session` 串行队列中刷新预览输出与照片输出。切换前先 flush 合并变焦队列，避免最后一次焦段调整尚未落到设备时以旧倍率重配；随后保留当前设备的 `videoZoomFactor`，若会话重配后 AVFoundation 重置了裁切倍率，则在设备支持范围内恢复并重新发布读数。这样 A 挡 1× 控件中的 24mm/35mm 两种取景都能在 Live 开关前后保持，前置普通/广角取景也沿用相同保护。该流程不更换镜头、不改照片画幅或 UI。

官方接口依据：[activeFormat 与 inputPriority](https://developer.apple.com/documentation/avfoundation/avcapturedevice/activeformat)、[受支持格式与帧间隔配置](https://developer.apple.com/documentation/avfoundation/capture-device-formats)。设置帧间隔前必须校验格式范围并持有设备配置锁，不能仅设置编码器的期望帧率来假装实际采集帧率。

## 滤镜选择器

FilterPickerViewModel 管理分类、持久化收藏、强度栏展开状态和缩略图缓存。收藏使用 UserDefaults 中的 `camera.favoriteFilmStyles`；缩略图在独立队列使用本地示例图及实际滤镜配方渲染，不逐帧重复计算。

CameraViewModel 负责分类与当前滤镜的同步，以及预览横滑的选择逻辑。横滑仅在滤镜窗口打开时生效，超过 44 点且横向距离大于纵向距离的 1.25 倍才切换，分类内到达端点后不循环。预览交互层仅在滤镜打开时添加 DragGesture，对焦点按与控件自己的点击分别处理；滤镜列表的 ScrollView 不向预览层传递手势。

滤镜面板停靠在相机页面底部，隐藏底部快门和参数区的点击，但保留它们的布局尺寸，因此打开选择器不会改变预览裁切。镜头、A/M 和九宫格控件随底部面板与强度栏上移。内置风格与导入 LUT 统一由 FilmStyle.availableStyles 提供，当前 46 款（包括原片）；分类按实际支持的风格展示。导入 CUBE LUT 作为 float32 RGBA 数据集放入 Assets.xcassets，通过 ImportedFilterCatalog 按滤镜懒加载，并由 FilmColorLUT/CIColorCubeWithColorSpace 共用于照片和 SDR/P3 视频。美食条目沿用稳定的 `food` 原始 ID，用户提供的 17³ LUT 替代旧手写配方，使已有选择、收藏与照片记录继续解析到新的外观。CUBE 没有显式色彩配置时按当前导入管线的 sRGB 输入约定处理；不要将这一假设描述为源 LUT 自带的色彩元数据。

拍摄界面共享表面使用系统版本分支：iOS 26 及以上调用 SwiftUI `glassEffect`，焦段圆形控件和画幅导致的顶部工具栏/预览重叠带使用 UIKit [`UIGlassEffect`](https://developer.apple.com/documentation/uikit/uiglasseffect)；iOS 18–25 继续走原自定义材质。工具栏重叠带按 `CameraPreviewLayout` 计算出的可见高度绘制，未重叠时保持透明，且不参与命中测试；系统减少透明度时该区域回退为高不透明度实底。曝光控件与弹窗从共享的 `PreviewSurface`、`GlassSurface` 与 `PopupGlassBackground` 取得背景；固定焦段条不再有整组背景，只让当前选中项绘制圆形背景，未选中项保持透明。顶部工具栏按钮保持纯图标/文字样式，不单独绘制按钮背景；工具栏外层仍有透明触控拦截面，防止点按空白区域落入预览对焦手势。

## 倍率与竖屏方向

CameraLensCatalog 读取系统虚拟镜头的 constituentDevices、virtualDeviceSwitchOverVideoZoomFactors 和显示倍率系数，得到各物理镜头相对主摄的原生倍率。iOS 17 根据主摄切换阈值归一化；iOS 18 起使用系统 displayVideoZoomFactorMultiplier。没有虚拟镜头映射时根据物理镜头视场角估算相对倍率。

CameraZoomPolicy 在纯数据能力模型上选择 2×、4×：优先物理镜头或 activeFormat.secondaryNativeResolutionZoomFactors 支持的原生采样倍率，否则选择无需缩小视场的最佳物理镜头并使用 videoZoomFactor。不能把 5× 长焦缩小成 4×；支持范围之外的入口不展示。CameraLens 的标识同时包含设备与实际变焦倍率，因此同一个物理镜头的 1×／2×／4× 分别可选，返回后置时也能记住倍率。

M 挡使用物理镜头输入保留手动曝光；A 挡使用系统虚拟多摄，允许自动切换组成镜头。同一输入内仅改变变焦倍率，不重建输入、不重置手动参数；更换输入时提交配置后重新设置方向与前置镜像，再发布能力和选择标识。预览先归一为竖屏方向，再对前置画面做固定水平镜像；新前置照片在快门前按 RotationCoordinator 的重力捕获角配置，旧设备及后置按原方向配置。预览保持零旋转缓冲，照片独立通过输出连接与 EXIF 解码处理。

原生与数字属性通过 CameraLens.isNative 表示，并在镜头无障碍描述中区分。应用无法给不具备相应硬件和采样模式的设备增加原生焦段。Apple API 说明：[原生采样倍率](https://developer.apple.com/documentation/avfoundation/avcapturedevice/format/secondarynativeresolutionzoomfactors)、[虚拟镜头切换倍率](https://developer.apple.com/documentation/avfoundation/avcapturedevice/virtualdeviceswitchovervideozoomfactors)。

## 统一弹窗主题

AppTheme 集中定义弹窗底色、透明度与强调色：相机主背景使用纯黑，弹窗与玻璃面板使用 `popupColor` 黑灰色；`popupOpacity`（0.86）用于平面弹窗与预览表层，`cameraPopupMaterialOpacity`（0.66）用于磨砂玻璃弹窗，`PreviewSurface` 默认 0.28；强调色按钮上的文字使用 `accentForeground`。PopupSurface 复用边缘高光绘制参数、拍摄功能和辅助工具窗口。`PopupGlassBackground` 使用多层深色磨砂玻璃：深色染色、`ultraThinMaterial` 磨砂、上部受光与下部加深、对角高光与椭圆光晕、静态细颗粒、亮边与底边内阴影、双层投影；颗粒是静态 128×128 图像，按平铺显示，不在动画或滚动中重新生成。系统开启“降低透明度”时改用高不透明度黑灰填充并保留边缘高光。相机页弹窗（顶部格式/比例/影调、视频顶部选项、M 挡参数、滤镜、拍摄辅助）在横竖屏切换时保持竖屏布局，不旋转、不重排、不换边；`OrientedPopup` 仅保留给设置、滤镜重置等非相机页弹窗。M 挡参数弹窗全宽贴底，顶部圆角 36，底部圆角对齐屏幕圆角；参数弹窗只旋转关闭、A/M 和中间标题，数值、刻度、焦点图标保持竖屏。焦段条和左右按钮位置固定，允许被弹窗覆盖。相机弹窗显示/隐藏使用淡入淡出，减弱动态效果时缩短。滤镜窗口、设置及图库 sheet 使用相同 popupBackground；取景框内普通控件继续使用轻透明 PreviewSurface。`GlassSurface` 的按钮底色比初版更明显，禁用按钮通过 `disabledControlOpacity` 只降低图标和文字对比度，保留玻璃背景与点击热区。镜头倍率和 A/M、辅助入口的底部位置按画幅固定预留参数窗口空间，不依赖窗口打开状态。颜色与材质调整不改变尺寸、定位和淡入淡出；透明度按本轮要求单独调整。顶部工具栏与预览重叠区域不再绘制 Liquid Glass、黑色染色或暖色渐变，只保留透明布局占位和命中隔离；按钮、弹窗定位与触控逻辑不变。

## 顶部选项与格式输出

CameraToolbarPanel 独立管理顶部格式、画幅、影调测光窗口，可与底部滤镜选择器同时存在；手动参数与辅助工具会关闭顶部窗口。PhotoOptions 传递闪光灯三态、照片格式、像素与 HDR，PhotoEncoder 编码真实 HEIF/JPG/TIFF 数据，CapturedPhoto 将预览与原始资源分开。PhotoLibraryService.saveCapture 与分享按实际资源输出；RAW＋JPG 保存为同一 PhotoKit 资产的 photo 和 alternatePhoto。

PhotoOutput 最大分辨率及 ProRAW 在输入配置时设置，裁切比例变化不重配会话。Bayer RAW 数字变焦不可用，按能力禁用入口并在捕获时再次检查。HEIF Pro 是 RAW 解码后减少锐化的 HEIF 管线，HDR 使用 10-bit PQ，与极影专有算法不同。DNG 资源保留原始画面，照片效果写入处理文件。

预览保持完整传感器画面，Viewfinder 使用 scaledToFill 即时显示所选裁切；直方图与全局测光仍按画幅裁切计算。取景节点在画幅切换时保持，取消布局动画及逐帧背景模糊。点测光通过 exposurePointOfInterest 设置位置，全局测光按线性平均亮度平滑修正自动曝光补偿，手动曝光不被覆盖。影调处理同时用于预览与输出。

接口依据：[最大照片尺寸](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/maxphotodimensions)、[ProRAW 配置](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/isappleprorawenabled)、[测光位置](https://developer.apple.com/documentation/avfoundation/avcapturedevice/exposurepointofinterest)。


## M 挡流畅预览

“流畅预览”是独立保存的照片辅助偏好，默认关闭。仅当处于 M 挡、手动快门/ISO 已启用且没有照片捕获任务时生效：实时预览使用连续自动曝光，将 `activeMaxExposureDuration` 限制在当前格式支持范围内且不超过 1/30 秒；曝光补偿仍保留，用户设定的快门和 ISO 单独记忆。视频模式不启用此策略。`usesSmoothManualPreviewExposure` 在检查照片辅助偏好前统一排除 `videoModeRequested`，避免切视频后 `setExposure` 仍误走自动预览曝光分支；偏好不被清除，返回照片可继续使用。

拍照时为该请求临时切换到记忆的手动快门和 ISO，待曝光设置完成后提交照片；使用 `.speed` 照片质量优先级，避免输出质量策略与自定义曝光要求冲突。捕获到首帧或捕获结束的恢复路径会重新应用预览自动曝光上限。如果用户在捕获期间关闭辅助或切回自动模式，收尾逻辑恢复当前选定模式，而不是强行启用已关闭的辅助。预览曝光策略只影响取景流，输出像素不经过额外曝光后处理。

官方接口依据：[自动曝光最长时间](https://developer.apple.com/documentation/avfoundation/avcapturedevice/activemaxexposureduration)、[自定义快门与 ISO](https://developer.apple.com/documentation/avfoundation/avcapturedevice/setexposuremodecustom%28duration%3Aiso%3Acompletionhandler%3A%29)、[照片质量优先级](https://developer.apple.com/documentation/avfoundation/avcapturephotosettings/photoqualityprioritization)。官方文档说明 `activeMaxExposureDuration` 限定自动曝光算法可选的最长曝光时间；在自定义曝光模式下，系统使用指定的快门与 ISO。应用通过真机结果验证这条临时切换路径，不将预览发布频率等同于设备显示帧率。

退出视频会话时，CameraEngine 在照片路由提交前把 `activeVideoMinFrameDuration`、`activeVideoMaxFrameDuration` 和自动曝光上限重置为当前配置的默认值，避免继承录像格式。M 挡照片自定义快门慢于 1/30 秒时，再按活动格式公布的 `videoSupportedFrameRateRanges` 放宽视频预览输出的最大帧间隔；较快快门回到格式默认帧间隔。该间隔调整服务于实时预览节奏，不替代 `setExposureModeCustom` 的照片曝光值，也不改变照片输出格式。每次写设备参数都在会话队列持有配置锁；若当前格式不支持所需帧率，不写入越界间隔。iPhone 17 Pro 真机视频往返后设定 1/2 秒，预览读数实际为 0.499895 秒。Apple 对 [`activeVideoMaxFrameDuration`](https://developer.apple.com/documentation/avfoundation/avcapturedevice/activevideomaxframeduration) 说明了格式帧率范围约束，对 [`activeMaxExposureDuration`](https://developer.apple.com/documentation/avfoundation/avcapturedevice/activemaxexposureduration) 说明了将其设为 invalid 会恢复自动曝光默认上限。


## 快门刻度与照片详情参数

手动快门刻度由 `CameraShutterStops` 提供常见分母档位，并以 log2 曝光时间排列，使相邻档位对应等距曝光变化；刻度标签与硬件旋钮选项从同一组档位生成。用户拖动值会先限制在活动格式的真实快门范围内，再吸附到范围内最近的标准档位。如果该范围内不存在标准档位，则保留受限后的连续值，避免显示/旋钮选择跳到不相干的上下端点。

拍摄参数快照包含快门、ISO、EV、焦距、光圈、输出格式和拍摄类型。`PhotoInfoPresentation` 为照片详情生成七个带标题的参数项；拍摄类型来自快门请求时的 `PhotoOptions` 快照（普通、夜景、连拍或慢门预设），不是对 EXIF 中不存在字段的推断。对外部照片或缺少快照的旧照片，缺失值显示占位符，不补造数据。视频详情沿用同一 presentation，但使用轨道读取出的帧率、时长、格式和码率。


## 自动保存与照片详情、编辑

拍摄完成后 CameraEngine 先解除 capturing 状态，再通过 AppDependencies 将 CapturedPhoto 交给 PhotoLibraryViewModel.acceptCapture 自动保存。普通成功不弹确认；失败保留预览与原始资源，并允许重试。保存、编辑、删除共用操作互斥，避免新拍摄覆盖正在处理的照片。

Core/PhotoLibrary 中的 PhotoDetailService 抽象详情读取、原始资源分享与编辑会话；SystemPhotoDetailService 使用 PhotoKit 读取元数据、资源和编辑输入，并通过 PHContentEditingOutput 写入 JPEG 与调整信息。PhotoEditSession 仅持有 Core 类型和提交闭包，不引用 Features。Core/Imaging 的 PhotoEditRenderer 负责 Core Image 调整、旋转及全分辨率 JPEG 输出。

Features/Library 中的 PhotoDetailViewModel 管理可取消请求和过期结果；PhotoEditorViewModel 管理滑块、异步预览与保存状态。编辑保存回调即使页面对象已释放仍会解除操作锁。系统照片通过 PhotoKit 编辑保留原图，未保存照片编辑后可重试自动保存。已保存的标准 Live 可在编辑器中选择保留 Live 或转为静态照片；保留 Live 支持另存与覆盖（版本 5 配方），逐帧应用同一滤镜与裁剪并保留音轨、配对标识和回放元数据；静态编辑使用版本 4 配方。

相册使用全屏导航与三列网格。图库和照片页的相机按钮关闭整个图库返回相机；照片页共用 PhotoViewerLayout，保持分享、详情、相机、编辑、删除的排列。相机生命周期启动还检查 cameraVisible，避免图库遮盖时因场景激活重新启动会话。

画幅变化使用独立的 frameAnimation 调整预览布局，保留现有会话；手动按钮颜色由 parameterIsManual 对曝光、白平衡、对焦的独立状态推导。曝光补偿没有独立手动开关，因此保持普通颜色。


## 工具栏、原生 8× 与预览旋转

顶部工具栏字体与图标缩小，保留原触控区域；读数标题及数值同步缩小。照片页删除按钮直接调用删除服务，已保存照片由 PhotoKit 请求系统确认，未保存照片直接清理内存。

CameraZoomPolicy 增加 nativeOnly 参数；8× 入口仅接受物理镜头或 secondaryNativeResolutionZoomFactors 明确支持的原生裁切，不以数字放大充当原生 8×。2×／4× 保持现有回退策略。

拍摄辅助移除外置镜头。翻转由 CameraViewModel.rotatePreview 每次递增一个 quarter turn，CameraEngine 在显示管线旋转图像，四次恢复；底部前后镜头切换仍由 flipCamera 处理。PreviewRotation 同时提供逆变换，使点按对焦与点测光映射回原始传感器位置。预览旋转不修改成片方向。

Imaging.filtered 为滤镜与影调的统一入口。实时预览和 PhotoEncoder 均先在源图像应用效果，再缩放；成片预览复用已处理图像，避免重复应用。实时预览、SDR 成片预览与编码明确使用 sRGB。RAW DNG 不写入滤镜，PQ HDR 输出仍使用其专用色彩空间。视频预览与照片输入来自不同 AVFoundation 输出，硬件曝光、系统照片处理及 HDR 显示差异仍需真机对照。


## 滤镜强度与预览帧隔离

FilmStyle 的强度混合改用 CIBlendWithMask，灰度遮罩在 linear sRGB 中表达权重，0% 直接返回原图、100% 直接返回效果图，中间强度连续混合。无效数值回退到 0%，超范围值钳制；混合保持输入范围与透明度，避免过渡滤镜的端点跳变。

PreviewRevision 使用锁保护修订号。updateLook 在调用时立即失效旧帧，在相机会话队列更新 look 与修订号；所有拍摄设置仍按原队列顺序提交。模拟器跳过已过期渲染，实时预览与模拟器回到主线程发布前再次校验修订号。旋转同样使旧预览失效。createCGImage 使用 deferred: false 将预览像素即时渲染，SwiftUI 图像内容关闭隐式动画，界面画幅动画保留。

Apple 的即时渲染参数说明：https://developer.apple.com/documentation/coreimage/cicontext/createcgimage(_:from:format:colorspace:deferred:)


## 相册点击边界与 A/M 自动状态

LibraryImageView 的 scaledToFill 图像明确约束到格子尺寸，并为裁切后的容器设置矩形 contentShape；图库两种 NavigationLink 标签同样限制裁切及命中范围。视觉裁切不能替代点击区域约束，避免下方缩略图溢出的命中区域抢占上方照片点击。照片导航目标按资产 ID 设置身份，隔离 StateObject 详情数据。

setMode 进入 M 挡不再强制开启 manualExposure，也不覆盖曝光参数数值；切换至 A 挡仍恢复系统自动参数。快门／ISO 的自动设置通过共享曝光状态保持，只有用户显式调整或切换参数 A/M 才再次进入手动。切换镜头的 resetParameters 同样默认自动，不因当前位于 M 挡而开启手动。


## M 挡参数记忆

切换 M → A 前，CameraViewModel 将曝光、白平衡和对焦的自动／手动开关，以及 ISO、快门、色温、对焦位置和 EV 保存到 ManualSettings。A 挡实际应用系统自动曝光、白平衡、对焦；返回 M 挡时恢复快照并重新提交设备参数，手动按钮颜色随开关恢复。在 M 挡显式选择自动后，下一次离开 M 挡保存新的自动选择，不恢复更旧的手动状态。

A 挡 EV 单独保留，避免覆盖 M 挡曝光补偿。恢复 ISO／快门时按当前镜头能力钳制范围。开启“保存拍摄设置”时，当前手动值和 M→A 记忆一起纳入持久化快照；关闭时仍保留本次进程内的 A/M 记忆。已实现的辅助面板开关（水印、倒计时、参考线、直方图、峰值、水平仪、预览旋转、剩余时间、声音电平）由 `CapturePreferences` 独立保存，首次默认全部关闭，冷启动读取时不依赖该快照开关；未实现的辅助占位不纳入持久化规则。视频码率档位作为独立偏好保存；应用设置始终允许选择。低/中/高仅由 HEVC/H.264 的编码器配置使用，ProRes/RAW 忽略所选档位并按自身规格编码；从 ProRes/RAW 切回 HEVC/H.264 时恢复此前选择。默认不写入目标码率，由系统编码器决定。

### 拍摄状态持久化

`SavedCaptureState` 保存拍摄模式与规格等选择，不保存弹窗、录制状态、对焦目标、辅助面板开关或待处理媒体。`CapturePreferencesStore` 用独立 `capture.state.v1` JSON 与 `capture.preferences.v1` 偏好分开存储；版本未知或损坏数据不应用。CameraViewModel 合并连续修改，250ms 后保存；进入后台沿用 `flushFilterSettings` 同步提交最新设置。JSON 按键排序，相同内容不重复写入。开启开关立即保存当前值，关闭取消待写入任务并清除快照，当前拍摄不中断，下次冷启动才应用默认值。独立辅助偏好与视频码率档位保留。每款滤镜的自定义配方仍独立保存，不因关闭启动记忆而抹掉。

初始化先恢复界面选择和自动/手动标志；相机就绪后按保存的镜头与倍率恢复，再将 ISO/快门钳制到实际镜头范围并调用既有参数恢复流程。初始默认镜头的临时能力回调不能覆盖待恢复的 RAW/48MP 等选择；实际目标镜头就绪后再按能力降级。缺少外接盘的 RAW 视频回退 HEVC，不绕过原存储资格检查。冷启动保存的录像模式只进入取景，不自动开始录像。DEBUG XCTest 宿主与临时模型使用内存偏好；持久化测试显式注入隔离 UserDefaults，避免写入用户拍摄状态。

关闭记忆的冷启动默认值：照片 A/JPG/4:3、闪光和 Live 关闭、原片且无调色；视频 A/1080p30/16:9/SDR/HEVC、原片，Log LUT 不烧录；定位、署名、快门静音等偏好独立保留。

### 一级按钮和录音触感

主要操作按钮在自身启用的 action 中发出轻触反馈，已有快门、模式、焦段、辅助和工具栏反馈沿用原实现，不叠加全局点击手势。新增覆盖拍摄页相册/滤镜/翻转/参数入口，以及图库选择、分享、删除、返回相机、详情操作和编辑主工具/保存入口。禁用或隐藏按钮仍由原 Button 条件阻止操作。

CameraEngine 在麦克风连接配置前后、视频外层会话提交后，以及会话启动/音频路由变化时，按需设置 AVAudioSession 的 `allowHapticsAndSystemSoundsDuringRecording`；保留 AVCaptureSession 自动音频管理，不手动切换录音类别。水平仪继续使用原保持时间、迟滞和冷却，不增加频繁震动或轮询任务。

## 视频详情分页与 DockKit 主体框选

图库翻页沿用网格中的时间顺序和资产身份。`GalleryPhotoPaging.requiresImagePreload` 在普通翻页中仅为静态图像和本次拍摄预载；删除成功后所有目标页都立即提交，由详情各自加载，不能继续停留已删除照片等待高清下载。两条提交分支均释放删除事务，过期源页面回调不能二次跳页。下一静态图未加载时不锁住整页操作，媒体到达后仅淡入画布；视频详情由 AVAsset 播放器自身载入，不等待 still-image loader。横向滑动仅加在媒体画布上，并按水平距离阈值判断方向；竖滑、缩放中的照片拖动不分页。

视频详情的拍摄参数复用 `PhotoCaptureParameterRow`，顺序为设备信息、单行参数、位置，参数行本身不绘制卡片背景。横屏视频详情仍只旋转视频、播放条及其标识；顶部与五个底部功能按钮维持原位。

云台追踪启用且 DockKit 附件连接时，轻点先对焦，再把 aspect-fill 预览点换算为 DockKit 规范化视频坐标并调用 `DockAccessory.selectSubject(at:)`；长按拖动会绘制区域，松手后换算并调用 `setRegionOfInterest(_:)`。命令在主 actor 上串行提交，避免连续点选与框选乱序。Apple 文档说明 `selectSubject(at:)` 可选择点位处的已检测主体；`setRegionOfInterest(_:)` 设置 DockKit 搜索区域，但不承诺当区域内有多个主体时必定选中其中某一个。单元测试验证 aspect-fill 坐标变换；实际追踪质量仍需连接 DockKit 附件测量。官方接口：[选择主体](https://developer.apple.com/documentation/dockkit/dockaccessory/selectsubject%28at%3A%29)、[设置追踪区域](https://developer.apple.com/documentation/dockkit/dockaccessory/setregionofinterest%28_%3A%29)。


## 半圆变焦转盘

参照用户录屏，CameraZoomDial 用 Canvas 绘制透明暗色半圆、对数刻度、固定指针和实时倍率。CameraViewfinder 的每个固定焦段共用长按后拖动的组合手势，原焦段条只隐藏外观，保留手势宿主。CameraViewModel 管理展开、拖动原点及收起，连续倍率计算由 Core 的 ContinuousZoomPolicy 提供。

CameraEngine.setContinuousZoom 按显示倍率选择真实镜头，并在会话队列设置 videoZoomFactor；同一镜头调整不重启会话，跨镜头才替换输入并恢复竖屏与镜像连接。倍率范围来自物理镜头的基准倍率及系统允许范围，显示上限最多 40×；较弱设备使用自身上限。原生 8× 固定入口仍使用原生能力判断，转盘中的其他倍率可为数字变焦。

连续变焦引发真实镜头变化时保留 M 挡开关与参数，并按新镜头曝光能力钳制。RAW 可用格式随裁切更新，避免在 Bayer RAW 不可用时保留失效的格式选择。预览发布同时校验滤镜修订和变焦修订，避免旧倍率画面覆盖新请求。模拟器只用 1–5× 演示裁切，不提供虚假的原生镜头。

系统变焦 API 参考：https://developer.apple.com/documentation/avfoundation/avcapturedevice/videozoomfactor


## 转盘防卡顿与原生多摄像头路由

LatestValueThrottle 将高频拖动合并为一个待执行任务及一个最新倍率，最多约每秒 30 次投递；拍摄前在会话队列 flush 最后目标，停止相机或固定焦段切换时取消旧请求。同镜头变焦仅设置 videoZoomFactor，不再每个事件重复配置拍照输出和发布全部设备能力；只有输入变化或 Bayer RAW 的原生倍率可用状态变化才重新配置输出。

变焦请求不再使已渲染预览帧失效：相机帧反映真实硬件当前倍率，持续拖动时继续发布，避免请求频率高于预览帧率导致所有画面被丢弃。滤镜修改仍使用自己的修订保护。转盘手势增加 GestureState 的取消收起，并固定倍率标签宽度，减少布局变化；离开相机同时关闭转盘。

A 挡后置输入优先选择 builtInTripleCamera／builtInDualWideCamera／builtInDualCamera，由系统执行构成镜头切换。固定倍率及转盘共用虚拟输入，并通过 displayVideoZoomFactorMultiplier 转换显示倍率；实际倍率与范围按虚拟设备当前能力钳制。没有虚拟多摄像头的设备回退物理镜头。M 挡切换回物理输入，因虚拟设备不支持自定义曝光、色温和对焦位置；保留既有参数记忆与手动状态。物理镜头连续选择采用约 6% 的向上边界滞回，避免边界附近反复切换输入。

Apple 多摄像头行为：https://developer.apple.com/documentation/avfoundation/avcapturedevice/devicetype-swift.struct/builtintriplecamera
Apple 显示倍率：https://developer.apple.com/documentation/avfoundation/avcapturedevice/displayvideozoomfactormultiplier
SDK 限制依据：AVCaptureDevice.h 中三类虚拟设备说明均列出不支持自定义曝光、指定对焦位置及指定白平衡增益。


## 完整半圆与独立预览渲染

CameraZoomDial 使用两段贝塞尔曲线绘制容器内完整半圆，半径同时受宽度和高度约束，左右端点及顶部均在可见范围内。保持 136 点高度和两侧 24 点间距，不再以超宽圆形裁切形成转盘。

AVCaptureVideoDataOutput 回调改为独立 camera.preview 队列；会话输入切换、变焦及参数配置继续使用 camera.session 队列，照片编码使用 camera.photo 队列。实时帧使用独立 CIContext，并显式要求 deliversPreviewSizedOutputBuffers，减少预览的数据量而不修改照片输出分辨率。

LivePreviewState 在锁内传递运行状态、滤镜、修订号、旋转、直方图、测光和设备的快照。帧队列更新预览尺寸，点按对焦通过快照读取。用户主动切换焦段时，CameraEngine 增加微距路由代次并暂时隐藏前一路由的微距标识；排队中的旧采样因代次过期而丢弃，新路由建立后再从当前设备状态恢复标识，避免旧路由状态短暂残留。全局测光的亮度计算在预览队列进行，最多每 0.4 秒把均值回传会话队列；旧设备的均值不应用于新设备。曝光/白平衡/焦点读数与微距标识由视频采样回调每 0.4 秒采样一次，发布 UI 前再延后一个显示间隔，并检查读数代次，避免相机状态更新与 SwiftUI 视图事务重叠。模拟器预览同样在独立队列通过最新值合并渲染，不阻塞相机控制；停止后不会发布旧画面。


## 已知问题

- 微距退出速度由系统自动切镜决定；距离阈值、强制主摄和帧融合方案已回退。2026-10-18 已进一步移除残留的 `MacroExitRecheckPolicy`、1.2 秒延迟单次重新对焦及其状态/诊断入口；场景变化只沿用原有连续自动对焦恢复，不再安排微距专用重新扫描。
- 近远对焦时背景的轻微视角变化仍在诊断，未加入额外补偿。


## 前置广角切换

- 支持 Center Stage/动态画幅的前置设备，`appendFrontLenses` 只加入同一个系统超广角设备的两个逻辑取景：standard 使用系统窄取景倍率（本机约 1.5855×，display 1×），wide 使用 1×（display 约 0.63×）。不再假设两个设备类型代表两颗物理镜头。
- 前置宽窄取景显示双斜箭头：未开启广角时箭头向外，点击切到 wide；开启后箭头向内，点击切回 standard；选中状态用强调色高亮。照片模式通过原生 SwiftUI `Button` 处理轻点，避免复用焦段变焦控件的长按手势；视频模式为居中的独立圆形按钮。没有 Center Stage 的前置设备保持原有前置 1× 入口。
- 前置切换只设置同一输入的 `videoZoomFactor`，不更换输入；照片方向、镜像与旧设备 90° 路径见后续“Center Stage 单输入取景与照片方向”章节。后置多摄路由不变。


## 2026-10-18 前置普通/广角切换事务（历史方案，已被后续单输入方案替代）

- 普通拍照、HDR/Live 未启用时，仅前置设备之间切换合并输入替换、预览缓冲及照片输出配置，在最外层事务提交后发布能力和就绪。后置路由、跨前后切换及 HDR/Live 沿用原有事务顺序。
- 前置动态画幅不能沿用旧的固定缓冲宽高：同一事务内先移除旧尺寸，再按目标设备配置；提交后重新设置实际输出连接的方向/镜像并刷新帧时间门，丢弃提交前的排队帧。
- 该节记录当时的多输入事务尝试，已被后续“Center Stage 单输入取景”替代；当前实现不切换前置输入，也不把两个系统设备类型当作两颗物理镜头。


## 2026-10-18 Center Stage 单输入取景与照片方向（替代前置多输入方案）

- `CameraLens.frontFraming` 区分 standard/wide 逻辑取景。支持动态画幅的前置超广角提供两个镜头目录条目，共用 `uniqueID`，以真实 zoomFactor 区分 ID；UI 按逻辑取景选双箭头，不再假设两个设备类型必然代表两颗镜头。
- 能力检测遍历设备支持的 formats，避免相机未启用时默认 activeFormat 不含动态画幅而漏判。窄取景优先读取系统 smartFramingMonitor 的 supportedFramings；尚不可读时采用 1.6× 回退。本轮 iPhone 17 Pro 官方窄倍率约 1.5855×；1.6× 回退的真实照片 EXIF 同为 31mm，广角 1× 为 20mm。显示倍率按同一基准归一化。
- 普通/广角切换只设置同一输入的系统 zoom；删除被替代的 frontConfigurationOpen/batchFront 输入事务逻辑。后置虚拟多摄、A/M 路由和旧前置设备保持原行为。
- Center Stage 的 native portrait 传感器关闭旧传感器方向补偿；照片在快门前使用当前 RotationCoordinator.videoRotationAngleForHorizonLevelCapture（本机竖持 0°、横持左向 90°），不再固定 0°。视频预览仍用原无旋转缓冲与既有方向处理。旧设备与后置照片连接保持 90°。照片上下文在快门请求时记录 native portrait 来源，解码后的输出像素不再携带重复旋转/镜像的 EXIF/TIFF 方向标记；仅规范化方向元数据，不改写真实焦距。
- 实际文件而非应用详情为元数据验收依据；JPG/HEIF 检查系统原始文件和最终文件两处焦距与方向，前置 Live 检查系统配对识别。旧文件不自动修改。

### 前置取景与横幅照片

- 支持动态画幅的前置相机继续使用同一个系统超广角输入。前置宽窄按钮在 standard 与 wide 之间调整同一设备的 sensor zoom，不更换输入；横竖屏触发的宽窄自动切换仍由既有方向策略处理，录像中保持当前取景，停止后再按方向调整。照片宽高比按钮与这个宽窄按钮彼此独立。
- 照片模式中原“自动构图”按钮现改为竖幅／横幅切换。仅当 iOS 26 及以上、当前前置格式同时支持 `AVCaptureDevice.AspectRatio.ratio3x4` 和 `ratio4x3`、且输出不是 RAW 或 1:1 时可用。按钮确认切换后，`frontPhotoLandscapeApplied` 作为相机队列中的成片状态，防止异步 UI look 覆盖系统确认的画幅。
- 使用 Apple `AVCaptureDevice.setDynamicAspectRatio` 改变实际取景。新前置预览保持连接零旋转，照片关闭旧传感器方向补偿，并在快门前按持续持有的官方旋转协调器设置照片连接；照片按文件 EXIF 解码后不再额外固定侧转。iOS 27 官方 `RotationCoordinator.videoRotationAngleRelative(toDeviceOrientation: .portrait)` 在本机返回 0°，与竖持实际样本一致；旧相机和视频预览保留原方向处理。
- 本机当前零旋转连接的实际缓冲宽高与 `dynamicDimensions` 对调：请求 `.ratio4x3` 时缓冲为 3024×4032，请求 `.ratio3x4` 时为 4032×3024。因此照片的竖幅/横幅按该连接下实际帧进行映射，而不旋转人物像素；这是本机观测，不声明所有机型/系统都保证同样映射。视频沿用原动态画幅请求，不扩大本次变更。
- `frontPhotoLandscapeApplied` 在相机队列记录设备完成的传感器构图。快门读取当前照片捕获角，90°/270° 时仅在捕获上下文中交换裁切轴，保持完整视野；不改变预览或传感器画幅选择。协调器与当前新前置输入绑定，离开该输入时释放，快门更新照片连接不重建会话。预览队列丢弃宽高方向与目标构图不符的交界帧；首张匹配的新图像与 `frontPhotoLandscapeEnabled` 在同一主线程更新中发布，避免新显示框接收旧帧。用户画幅切换不对宽高做隐式插值，只对取景内容做短淡化，遵循“减弱动态效果”，按钮位置不插值。系统自动切镜路径不受影响。
- 前置照片预览由系统自动配置代理缓冲尺寸，不回写系统推导的 Width/Height。动态画幅完成时间从输入端口时钟转换到会话同步时钟后过滤旧帧；参考 Apple Smart Framing 示例，先应用画幅，再恢复并夹紧当前 zoom，避免重启会话。
- 在支持的前置照片视频数据连接启用 `isCameraIntrinsicMatrixDeliveryEnabled`，逐帧读取 `kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix` 的 fx/fy。若横纵像素尺度不一致，先压缩被拉伸的轴，随后按成片比例裁切并等比缩放；不直接把视频缓冲的内参修正套到照片文件上。非有限值、非正值和异常比例丢弃，约 2% 内的小差异不补偿。后置和录像不启用此修正。
- 交界帧方向判断仍使用未修正的原始尺寸；滤镜、峰值分析与人像预览蒙版使用同样修正/裁切坐标，避免画面与辅助图层错位。内参读取与仿射变换位于既有预览队列，不额外生成第二套常驻预览。
- 本机标准档编码竖幅为 3000×4000，横幅为 4000×3000，约 12MP；1:1 与 RAW 继续禁用该开关，其他非正方形照片比例在系统取景后裁切。蒙版与照片/预览保持相同坐标，不额外旋转；真实人像边缘效果仍需相应场景验证。
- `PhotoEncoder` 对处理后非 RAW 图像统一将 EXIF/TIFF 方向归一为 1，因方向已应用到实际像素，防止编码时继承旧方向而使系统相册再次旋转。RAW 数据不修改。相机页相册按钮的照片/视频缩略图按成片自身方向解码后，作为按钮内容再使用 `rotatingCaptureContent` 跟随当前控件方向；这是显示变换，不改源图或文件。旋转限定在固定正方形内容框，外层圆形背景、玻璃、加载状态位置不变；相册/详情/编辑方向规则不变。
- 前置电影输入按设备格式的 `isCinematicVideoCaptureSupported` 发现并缓存，不固定假设 TrueDepth。本机电影能力由前置超广角提供，TrueDepth 未公布电影格式。兼容焦段列表同时检查电影格式的 `videoMinZoomFactorForCinematicVideo` / `videoMaxZoomFactorForCinematicVideo`；本机前置电影只支持固定宽取景，不开放无效的窄取景按钮。离开电影后按普通能力恢复；设备/朝向与最终录像规格改变时重查前置兼容集合，异步回调校验子模块请求和当前规格，避免旧后置列表覆盖新前置状态。
- 视频模式不显示照片宽高比按钮；当设备提供前置 standard/wide 两种取景时，wide 切换改为独立圆形控件，固定在底部控件行中央。Smart Framing 相关代码仍保留，但照片宽高比按钮不再调用人物构图建议；当前拍摄页面不提供该模式入口。系统视频 Center Stage 仍在会话初始化时明确关闭，避免系统变焦范围限制与应用宽窄按钮冲突。


## 2026-10-18 前后镜头切换单事务优化

- 普通 SDR 拍照且原生 Live/HDR 预览均未启用时，跨前后输入替换、预览尺寸/方向、照片尺寸/ProRAW/响应式拍摄配置由最外层 begin/commit 包裹；内部嵌套事务不再启动中间状态的会话。输入复用、后置 A 虚拟多摄与 M 物理镜头选择保持原行为。
- 提交后重新设置实际输出连接方向/镜像，刷新预览状态，再读取并发布实际格式能力和新帧标识。照片能力发布独立为 publishPhotoCapabilities，避免读取尚未提交的临时图状态。失败路径与 defer 均确保事务平衡。
- 原生 Live 已启用、Live 请求中或 HEIF HDR 预览请求/运行中时保留原事务与配对顺序，防止 Live 动态片段或 RAW/HDR 能力退化。本次性能数据仅代表普通拍照，不能外推至 HDR/Live。
- 保留原 startFocalTransition、前置单 Center Stage 输入宽窄取景、native portrait 方向和实际 EXIF 31/20mm；不同时运行前后摄像头，不降低照片分辨率。


## 2026-10-18 自动虚拟多摄的初始状态

`prepareAutomaticRoute` 仅用于进入 A 挡虚拟设备的输入替换，先写入最终倍率并恢复连续 AF/AE/AWB，再提交会话，防止系统按缓存倍率或旧控制状态启动后再二次判断。M 挡物理镜头和用户参数记忆不变。普通跨前后单事务路径本已先写倍率后提交，跳过重复初始化，避免重新启动健康的自动控制器；HDR/Live 非批量路径沿用其提交顺序，仅提前初始化目的自动相机。

实际镜头由 `.auto` 与系统完整 fallback 列表决定，`activePrimaryConstituent` 为记录依据。不直接指定供图镜头，不改微距图标规则、0.6 秒原有读数门或已有过渡动画，不新增距离阈值/延时扫描。局部近远对焦视角变化、微距退出较慢不属于本次已解决范围。


## 微距初始化问题验收（2026-10-18）

用户已确认切换后短暂误入微距的问题解决，初始化时序修复与回归测试同步至 DeepSeek。系统因真实场景选择超广角仍为正常功能；微距退出速度及近远对焦视角变化仍单独保留，不随本问题结项。


## 2026-10-19 SDR/P3 视频滤镜与预览双指变焦

- `CaptureLook.requiresImageProcessing` 用于跳过原片且无调整的逐帧处理。`CameraViewModel.effectiveCaptureLook` 在照片和 SDR/P3 视频间提供一致配方；视频照片滤镜仅 SDR/P3 且非 RAW 时开放，沿用当前滤镜强度与持久化的 `FilterAdjustments`。Log/Log 2 走独立 `LogLUTCubeRepository`，不提供照片式参数编辑；默认选“原片”，关闭烧录时只在预览路径应用 LUT，开启烧录时 `MovieRecorder` 在写入同一段 HEVC 流之前将 LUT 渲染到编码缓冲区。Log/Log 2 的像素缓冲继续使用 10-bit 4:2:0，`AVAssetWriter` 的原色/传递函数标记沿用 `VideoColorSpace.encodingColorProperties`，因此成片仍报告 Apple Log 或 Apple Log 2。录制期间冻结 LUT 选择及烧录状态。

55 个 `.cube` 资源按原 33³/65³ 网格打包为半精度 `LCUB` 数据，默认输入域必须为 0–1；`LogLUTCube` 在主线程外载入并以 NSCache 限额，预览缩略图延迟生成。当前资源转换保留 LUT 表格值，不对不同来源 LUT 做自动 Log 曲线识别或创意外观校准；选择列表含“原片”。保存视频后，`VideoCaptureBadgeStore` 按 PhotoKit local identifier 记录 LOG/LOG2 与是否烧录 LUT，图库和详情将对应标识与摄像机图标并排展示。任意外部视频不推断这些标识。

Log LUT 只在用户切换 LUT 时推进对应预览版本；普通照片滤镜参数更新只提交 `CaptureLook`，避免两种更新互相使对方过期。滤镜拖动回归用例覆盖连续更新后最新预览仍落定为当前配方。
- 视频预览继续使用 `LivePreviewState` 的实时滤镜路径。录制帧由 `MovieRecorder` 在追加样本前调用 `VideoFrameFilterRenderer`：将源 `CVPixelBuffer` 转为 `CIImage`，复用 `Imaging.filtered` 与照片相同的 LUT/调整配方，再渲染到目标色彩空间的 BGRA 缓冲区并交给 `AVAssetWriterInputPixelBufferAdaptor`。原视频时间戳保留，最终文件只经历一次编码，没有录制后的二次转码。无滤镜或不支持滤镜的格式继续直接写源帧。
- `CameraViewfinder` 在预览焦点表面附加同时手势 `MagnificationGesture`，比例变化交给 `CameraViewModel.updatePreviewPinchZoom`。ViewModel 以手势起点倍率作为锚点、沿用 `zoomRange`、连续变焦入口和已有镜头路由；倍率抵达边界时重新锚定，确保反向捏合立即生效。结束或取消时清理手势状态，并复用变焦刻度触感；捏合期间不把焦点 EV 拖动误认为手势。没有改动布局或视觉样式。
- 自动化覆盖 ViewModel 的倍率钳制、边界反向、结束清理和与变焦盘互斥；渲染测试覆盖 sRGB 与 Display P3 像素转换。真机验证证明 iPhone 17 Pro 的实际变焦状态随连续手势 API 更新、SDR/P3 滤镜写入最终视频。4K、高帧率和持续录像的性能/温升需另行验证。


## 视频详情编辑

视频详情的编辑入口以全屏 `VideoEditorView` 打开竖屏编辑器。`VideoEditorViewModel` 按视频色彩空间提供工具：SDR/P3 为时长裁切、照片拍摄使用的滤镜集合、同一滤镜参数调整；Apple Log/Log 2 为时长裁切及 Log LUT 选择，不显示调整工具；HDR 目前仅开放时长裁切。工具按钮和保存按钮共享等宽布局：SDR/P3 四等分、Log 三等分、HDR 两等分。

新拍视频的色彩空间与滤镜配方通过 `VideoCaptureBadgeStore` 按 PhotoKit asset ID 保存，编辑器据此恢复拍摄时的滤镜。兼容旧拍摄/外部视频：Log 标识及公开的轨道色彩元数据用于识别 Log、HDR、P3 与 SDR；不能识别的文件只开放裁切。预览与导出都通过 `VideoFilterComposition` 使用 AVFoundation 的逐帧 Core Image 视频合成，SDR/P3 复用 `Imaging.filtered`，Log 使用 Log LUT。输出格式从 `AVAssetExportSession.compatibleFileTypes` 选择，保留原视频和音轨；编辑结果另存为新 PhotoKit 视频资源，不覆盖原片。另有“存储到文件…”路径：先用同一导出服务生成带裁切/滤镜的临时视频，再通过 `UIDocumentPickerViewController(forExporting:asCopy:)` 交给用户选择 Files 目标；目标文件是副本，源视频不变，成功或取消后清理临时文件。视频合成不强行指定源色彩标签，最终文件是否完整保留 HDR/Log 元数据仍需真机读回验证。

## 照片夜景多帧合成

2026-10-30更新：以下早期仅平移/固定降噪配方已由本节末的手持优化说明补充。旧像素基准仍覆盖非自适应融合配方，不代表保留错误的配准方向。

`CameraEngine` 使用 AVFoundation 的 `AVCapturePhotoBracketSettings` 和三项 `AVCaptureAutoExposureBracketedStillImageSettings` 请求曝光包围照片。回调中的帧序号来自 `AVCapturePhoto.sequenceCount`；其官方定义是包围序列中从 1 开始的帧索引。收到帧后在后台排序与解码，选第 2 帧作为 EXIF/曝光参数代表及安全回退图像。采集依赖 Apple 的公开相机 API，但图像配准、融合权重与输出裁切属于本项目实现，并非调用 iOS 内置相机的夜景合成。

`NightPhotoMerger` 把图像缩小后交给 Vision `VNTranslationalImageRegistrationRequest`，估计各曝光相对中间帧的平移；只接受位移在图像宽/高 6% 内的帧，取所有有效帧的交集。探针最长 1600 像素，权重探针最长 900 像素，最终仍按成片分辨率处理。

2026-10-24 起，曝光融合先在 sRGB 探针中以线性化亮度的对数比中位数估计各帧增益（限制 ±2 EV，排除近黑/近白像素），用 `CIExposureAdjust` 归一至中间曝光，再进行平均。原始曝光的有效亮度用于权重；归一后 RGB 的差异用于运动置信度，运动区域优先保留参考曝光，避免直接平均不同曝光导致亮度下降和重影。该亮度增益/运动判断属于应用启发式，不等同于光流或三维配准；局部色调映射、旋转及复杂运动仍可能影响精度。

融合后向暗部混入 `CINoiseReduction`（noiseLevel 0.035、sharpness 0.25）结果，再用保留黑白端点的 `CIToneCurve` 适度抬起暗部。没有额外锐化；不是原生相机 Night mode 算法，也不保证恢复原片未记录的细节。保留参考图像属性，最终编码仍走原有滤镜、画幅和 EXIF 写入流程。

夜景出片提速保持上述配方、探针尺寸与张数策略。`ProbeBuffer` 为一次融合独占的连续 RGBA8 存储，`CIContext.render(toBitmap:)` 直接写入，取消原 CGImage/CFData/逐像素 Swift 数组拷贝；没有有效 alpha 则安全回退。相同单位曝光增益复用原探针，权重暂存和独立遮罩使用明确生命周期的连续缓冲，避免嵌套数组逐像素写时复制检查。通过 `withExtendedLifetime` 保证探针裸指针有效，返回的遮罩使用自有 Data 拷贝，不依赖临时可写内存；没有跨照片缓存或新增着色器。详见 [提速验证](Test-Reports/2026-10-24-Night-Speed.md)。

2026-10-30手持优化：按Vision SDK，request的targeted image应为floating图，handler处理reference；原实现传反，现已同时修正平移与新增单应请求。配准探针转灰并轻微平滑；平移10%范围内先走快速路径，残差较大再尝试受界限约束的`VNHomographicImageRegistrationRequest`，匹配失败可尝试±1.5°/±3°的小角度与平移组合。按曝光归一残差选优，限制异常倍率、位移与裁切，只使用有效内接区域。局部视差/主体运动仍由融合掩码保护；张数、曝光和资源上限未在本次增加。

自动影调路径在曝光归一后的运动探针中再做1.2px平滑，避免细碎高ISO噪声过度阻止有效帧参与；原始探针仍决定曝光权重，最终照片不使用该模糊图。暗部`CINoiseReduction`强度按后续曝光/阴影提亮从0.035调整至最多0.085，sharpness为0，手动曝光原固定配方保持。`NightCompositeMetadata`在成功融合后写入实际源张数/对齐帧数、可取得的源曝光统计，未知总历时不伪造；单帧回退不新增合成标记。

`CaptureLook.nightPreviewAssist`只由照片夜景打开，`CameraEngine`在帧队列每0.25s测量一次线性平均亮度，平滑地取得最多1.5EV的显示补偿；`Imaging.filtered`/PhotoEncoder不消费该标志。`NightPreviewReveal`按拍摄token持有取景图和实际收到的帧进度，`NightCaptureRevealView`只在预览区域做加亮混合，避免白色蒙层抬黑；最后淡入真实照片，短暂停留后归还实时取景。新拍摄、取消和后台按token隔离，减少动态效果时缩短动画；显示进度不是精确耗时百分比，不改保存曝光或滤镜参数。

完整夜景现由 `NightAdaptiveCapturePolicy` 选择 3/6/9 帧：曝光需求为 ISO×秒数÷2^EV；低于原有夜景进入门限 64 规划 3 帧，64–<256 规划 6 帧，≥256 规划 9 帧。低电量模式、严重/危急热状态或未知热状态采用 3 帧。环境门限仍只决定是否触发夜景；上述是应用自身的张数策略，不是 Apple 的 Night-mode 参数。

`CameraEngine.CaptureContext` 跨请求保存同一快门 token、递增序号和原始压缩帧。首批 −1/0/+1 EV，追加批次为三张 0 EV。每批保持在实际 `maxBracketedCapturePhotoCount` 内；本次后置 A 挡真机读到上限 8，仍按三张分组以在批次间评估运动。首批第 2 张一直作为 EXIF 与融合参考；后续 `willCapture` 不覆盖它。收到最后一批才释放硬件 token，期间沿用快门内加载圈，其他按钮不移动。

批次间在处理队列分析最长 320 像素的 Vision 平移探针、96×72 的亮度比较探针，不常驻分析预览、不新增运动传感器。双方向纹理按场景标准差的 3%（至少 0.002）判断，标准差至少 0.025；相对位移大于边长 1.5% 或曝光归一后变化像素超过有效像素 10% 时停止追加，曝光裁切区不计作运动；无法可靠评估时也停止。仅稳定、帧完整、路线/主镜头未变且资源允许时继续；超过 8 秒不再启动下一批，压缩数据到达 80 MiB 也不再追加，最多 9 张。8 秒是追加预算，不是硬件曝光/最终回调的绝对超时保证。路线变化只结束追加，不强制切镜或干预系统微距。

相机退出后标记采集组取消，等待在途系统回调释放 token，不把半成品交付相册；分析结束再次校验字典身份，旧结果不能续拍。普通照片、RAW、Live 和其他子模块仍使用原有完成路径。组结束后再将上下文交给最终处理队列，至少两帧对齐才标记多帧，单张安全回退。照片信息继续使用既有“夜景曝光合成：N 帧对齐融合”，N 为实际对齐数（2–9），不重复添加帧数栏；计划、采集数与评估细节保留内部诊断而不展示。诊断按 PhotoKit local identifier 保存，不伪造系统照片 App 可识别的合成帧数 EXIF 字段。DEBUG 测光/运动注入只用于可重复的硬件批次测试，默认均为空，正常拍摄不使用。

夜景开关状态与低照度触发状态分开保存。开启且当前拍摄配置兼容时，取景框显示白色月亮；环境门限满足后变为橙色月亮，点按橙色月亮可关闭夜景；关闭时整个指示器及底板一起淡出，当前配置不兼容时显示带斜线月亮。`NightCaptureEnvironmentGate` 消费 `CameraReadings` 的 ISO、曝光时长与用户 EV，以 ISO×秒数近似曝光需求并扣除 EV 补偿；进入门限为 64（连续 2 个有效读数），退出门限为 40（连续 3 个有效读数），两门限间保持原状态以减少闪烁。读数由预览管线最多每 0.4 秒发布一次，因此门限确认延迟约为一个或多个读数周期。该方法只是应用侧启发式代理，未使用环境照度传感器，也不是 AVFoundation 或 Apple 公布的 Night-mode 判定阈值；不同镜头、光圈、测光区域和场景应继续实测校准。

官方 API 依据：[AVCapturePhotoBracketSettings](https://developer.apple.com/documentation/avfoundation/avcapturephotobracketsettings)、[AVCaptureAutoExposureBracketedStillImageSettings](https://developer.apple.com/documentation/avfoundation/avcaptureautoexposurebracketedstillimagesettings)、[`AVCapturePhoto.sequenceCount`](https://developer.apple.com/documentation/avfoundation/avcapturephoto/sequencecount)、[`AVCaptureDevice.iso`](https://developer.apple.com/documentation/avfoundation/avcapturedevice/iso)、[`AVCaptureDevice.exposureDuration`](https://developer.apple.com/documentation/avfoundation/avcapturedevice/exposureduration)。苹果还公开设备自动低光增强开关及当前 `isLowLightBoostEnabled` 状态；由设备自行决定何时启用，部分格式/分辨率才支持，切换可能掉视频帧，所以它不等同于照片多帧夜景触发条件，也未纳入本实现。`AVCaptureSceneMonitoringStatus.notEnoughLight` 是给 Cinematic Video 场景监测使用的状态，并非通用照片照度判定。参考：[自动低光增强](https://developer.apple.com/documentation/avfoundation/avcapturedevice/automaticallyenableslowlightboostwhenavailable)、[当前低光增强状态](https://developer.apple.com/documentation/avfoundation/avcapturedevice/islowlightboostenabled)、[Cinematic Video 场景监测状态](https://developer.apple.com/documentation/avfoundation/avcapturedevice/cinematicvideocapturescenemonitoringstatuses)。


## 照片连拍与裁切点预览

- 连拍入口属于拍摄模式子模块；开启后，快门按住期间重复调用现有单张照片拍摄管线，松开即停止提交。每次输出仍是独立照片，沿用 `CameraEngine` 的拍摄、处理与 `PhotoLibraryViewModel` 的有界保存队列，不另建无限缓冲。当前政策只开放 12MP JPG/HEIF，并排除 HDR、Live、倒计时及其他照片规格。设备最终连拍速度由拍摄回调和队列容量约束，不宣称固定帧率。
- 视频裁切起止手柄改变时，`VideoEditorViewModel` 更新播放范围并将 seek 请求合并为最新目标，约每 45ms 最多发起一次预览定位；允许约 1/15 秒时间容差以降低解码等待。拖动期间暂停播放，停止拖动时再定位到最终截点。该逻辑影响视频预览，不改变导出区间或视频文件。
- `PhotoBurstPolicy`、连拍长按测试及视频截点预览测试负责验证规格约束、松手停止、有界队列和最终 seek 落点；当前结果见 `Docs/Validation.md`。

## 人像蒙版与 RAW 像素格式选择

原生人像蒙版管线由 `AVCapturePhotoOutput.isDepthDataDeliverySupported` 和 `isPortraitEffectsMatteDeliverySupported` 判断当前会话是否可请求人像效果蒙版；应用入口还允许可用的软件人物分割路线；这些能力只代表输出/路由支持，不保证每个场景一定生成蒙版。JPG/HEIF 使用 `AVCapturePhotoSettings` 的深度与 Portrait Effects Matte 交付选项；原生蒙版缺失时对静态图运行一次 accurate Vision 人物分割，仍无可用人物蒙版则保留清晰原片并记录诊断。

ProRAW 捕获不请求普通 AVFoundation 深度/蒙版交付，改为从 ProRAW DNG 辅助数据通过 `CIRAWFilter.portraitEffectsMatte` 读取，再传给照片渲染器。此数据是场景依赖的；未得到辅助蒙版时不会凭空合成背景虚化。RAW/RAW+JPG/HEIF Pro 共用 RAW 像素格式选择：先从当前 `availableRawPhotoPixelFormatTypes` 选择 `AVCapturePhotoOutput.isAppleProRAWPixelFormat` 为真的类型，没有 ProRAW 时才选择首个可用 RAW 类型。因此“RAW”界面项不能跨设备、镜头或路由承诺一定是 Apple ProRAW；`HEIF Pro` 最终输出 HEIF 资源，不是 DNG。

人像规格策略只开放 JPG/HEIF，以及当前路由确实公布 ProRAW 时的 RAW、RAW+JPG、HEIF Pro；12MP/48MP 由当前路由公布的可用分辨率决定。Live 与 HDR 在人像模式下关闭，TIFF 不在当前人像规格策略内。`supportsProRAW` 根据活动路由公布的 RAW 像素格式是否包含 Apple ProRAW 类型计算，不使用输出对象的全局 ProRAW 开关代替路由能力。

人像模式不再固定限制为 12MP；可选尺寸跟随当前相机格式公布的最大照片尺寸。App 当前把 Portrait+HEIF HDR 组合关在策略层，因为 iPhone 17 Pro 的现有 RAW-backed HEIF HDR 路径在启用人像时未能完成回调；这是本项目已观测到的实现限制，不是 Apple 文档公布的普遍兼容规则。

官方依据：[WWDC21 Capture and process ProRAW images](https://developer.apple.com/videos/play/wwdc2021/10160/) 说明 Bayer RAW 与 Apple ProRAW 是不同像素格式，应用应通过 `isAppleProRAWPixelFormat` 区分；其讲解还指出 Live Photo 仅支持 Bayer RAW，而 Portrait Effects Matte 仅支持 ProRAW。参考 [`CIRAWFilter.portraitEffectsMatte`](https://developer.apple.com/documentation/coreimage/cirawfilter/portraiteffectsmatte) 与 [`AVCapturePhotoSettings.isPortraitEffectsMatteDeliveryEnabled`](https://developer.apple.com/documentation/avfoundation/avcapturephotosettings/isportraiteffectsmattedeliveryenabled)。

## 视频延时摄影

延时摄影复用普通视频采集和 `AVAssetWriter` 写入路径。`TimeLapseFrameScheduler` 按输入采集时间戳决定是否保留视频帧；被丢弃的帧不会进入滤镜渲染和编码。保留帧使用当前所选视频帧率生成连续输出时间戳，因此播放时保持常规速度，实际时长由采样间隔决定。五个应用预设现在是开关，并绑定推荐组合：人流 1s/300 张、车流 3s/300 张、云层 5s/300 张、日落 10s/300 张、星夜 15s/300 张；这是应用提供的题材起始建议，不是系统相机参数或 Apple 对某类场景的保证。取消预设、切 M 或 A 挡无预设时恢复 1s/120 张。

延时录像关闭音频轨道，并拒绝 ProRes RAW，以免改变 RAW 时间戳语义。SDR/P3 等普通编码继续使用既有滤镜和单次写入流程。视频元数据增加拍摄类型与所选采样间隔。测试或取消录制后恢复原有延时开关与预设，避免污染用户状态。

Apple 的 [AVCaptureVideoDataOutputSampleBufferDelegate](https://developer.apple.com/documentation/avfoundation/avcapturevideodataoutputsamplebufferdelegate?changes=_1_5&language=objc) 提供采集样本及丢帧通知；[AVAssetWriterInputPixelBufferAdaptor.append(_:withPresentationTime:)](https://developer.apple.com/documentation/avfoundation/avassetwriterinputpixelbufferadaptor/append%28_%3Awithpresentationtime%3A%29?changes=la) 允许将图像缓冲区按指定媒体时间写入。Apple 文档没有规定延时档位间隔或题材预设，这些取值属于应用策略。

## 视频慢动作与电影模式

慢动作沿用 `AVCaptureVideoDataOutput` 和 `AVAssetWriter`：设备按当前物理镜头格式支持的 120/240 fps 采集，`SlowMotionFrameScheduler` 将递增的输入时间戳映射到较低的回放帧率，再写入连续时间轴。规格弹窗只展示实际采集分辨率和采集帧率；回放率不显示在慢动作弹窗内，继续沿用原有输出设置。SDR/P3 的采集组合按设备格式能力枚举；4K HDR 120 只加入后置物理主摄实际同时支持 10-bit HDR、HLG BT.2020 和 120 fps 的格式。回放策略还要求采集率严格高于回放率，因此 24 fps 可以作为慢动作回放率，但不会作为慢动作采集选项显示。音频、RAW、Open Gate 与 ProRes 不参与慢动作。

HDR 视频使用 HEVC Main10 和 HLG BT.2020 输出属性。iOS 26 及以上将 `AVCaptureVideoDataOutput.preservesDynamicHDRMetadata` 打开，并在 `AVAssetWriter` 压缩设置中采用 VideoToolbox 自动 HDR 元数据插入及动态元数据保留。若设备采集帧包含系统动态 HDR 元数据且编码器支持，写入器可生成 Dolby Vision；否则输出仍是 HLG。该编码配置同时适用于 4K HDR 慢动作与 HDR 电影视频，但 Dolby Vision 只能通过实际文件元数据验证，不能由 HLG 色彩标签推断。

电影模式使用 iOS 26 起的 `AVCaptureDeviceInput.isCinematicVideoCaptureEnabled`。iPhone 17 Pro 的分辨率/帧率组合按 Apple 相机公布的 1080p30、4K24、4K30 过滤；Apple 为较新机型公布的 60 fps 组合也只有在当前格式实际支持 Cinematic 和该帧率范围时才开放。所有组合再按 `isCinematicVideoCaptureSupported`、`videoFrameRateRangeForCinematicVideo` 和色彩空间能力逐项确认。电影规格弹窗允许分辨率与帧率分别选择：若当前另一项不兼容，自动调整为同一色彩空间下最近的官方组合。Cinematic 输入与延时、慢动作、Open Gate、ProRes/RAW 互斥，子模块入口在可用时保持可点。

启用时在选择活动格式后设置 `isCinematicVideoCaptureEnabled`，并使用该格式声明的 `defaultSimulatedAperture`。系统同时对取景预览与视频数据输出应用电影景深；本项目通过 `AVCaptureVideoDataOutput` 逐帧编码，因此散景已烘焙进输出像素，不保留可用 Cinematic 框架进行非破坏性重新对焦的原始 disparity/metadata 轨道。点按取景区域调用 Cinematic tracking focus，电影模式不提供普通镜头位置对焦滑块。

实现依据：[WWDC25 Capture cinematic video in your app](https://developer.apple.com/videos/play/wwdc2025/319/)、[输入的 Cinematic 能力](https://developer.apple.com/documentation/avfoundation/avcapturedeviceinput/iscinematicvideocapturesupported)、[格式的 Cinematic 能力与帧率范围](https://developer.apple.com/documentation/avfoundation/avcapturedevice/format/iscinematicvideocapturesupported)。Apple 的示例也说明 `AVCaptureVideoDataOutput` 得到的帧已烘焙浅景深，而可非破坏编辑的 disparity 数据来自 Cinematic movie 文件输出；本项目使用自定义逐帧写入路径，所以不承诺保留该非破坏编辑能力。

## 拍照与视频子模块规格预检

子模块入口点按不再由当前规格兼容性决定是否可点。`CameraViewModel` 先检查当前相机路线是否已有兼容设置；有则保留当前路线和用户选择，没有则按应用策略选择最接近的兼容设置。视频备用镜头查询通过 `CameraEngine.compatibleVideoSubmodeRoutes` 在相机串行队列读取各镜头格式，并按物理设备 ID 缓存普通视频、Open Gate 与 Cinematic 能力；等待目标镜头就绪后才启用模式。切换准备期间参数和焦段入口暂时禁用，避免会话切换过程中的交叉写入。

照片镜头格式与分辨率从会话发布的每镜头能力表中筛选；夜景/连拍需要 JPG 或 HEIF 与标准分辨率，人像按当前路由公布的处理格式、ProRAW 和尺寸开放，慢门沿用当前路线能力。视频启用后，顶栏参数通过 `videoCapabilitiesForCurrentRatio` 和相应支持方法筛选，焦段按钮只接受该子模式记录为兼容的镜头路线。异步视频能力更新导致当前组合失效时，先在当前路线内回退；无法恢复则退出子模式，不保留失配状态。智拍按钮已接入场景建议、中心对齐和拍前取景；详见 [智拍功能说明](SmartCapture.md)。

点按后的参数回退与每镜头扫描属于应用策略；Apple API 只提供可查询的设备/格式能力，不保证某个具体子模块的默认组合或不同镜头间相同规格。设备扫描缓存与切换事务已通过 Xcode 测试 target 编译，但本次设备服务不可用，行为、耗时与稳定性尚未在运行时验证，详见 `Docs/Validation.md`。


## 2026-10-23 电影模式切换事务与幂等配置

`finishVideoSubmodePreparation` 已提交目标镜头和规格并等待就绪后，调用 `finishVideoSubmodeChange(synchronize: false)` 只完成面板淡出与状态保存，避免随后再次提交同一组电影规格。直接可用的当前路线、退出子模式仍沿用默认同步路径。

`selectLensOnQueue` 进入电影模式时，将同一朝向的输入替换也纳入既有单事务路径：移除旧输入前继续关闭其 Cinematic 状态，添加新输入、初始化自动控制、设置最终格式并挂载电影输出图，然后一次提交。普通 A/M、前后切换以及 Live/HDR 路径的既有条件和过渡效果不变，不改变系统自动微距切镜逻辑。

`configureVideoFormat` 只有在退出电影、活动格式/色彩空间或采集帧间隔确实变化时，才关闭已经启用的 Cinematic。完全相同的配置保留当前输入与输出图；实际更换规格仍在会话事务内关闭旧处理、设置新格式并重新启用。Apple 明确说明启用 Cinematic 会耗时重配渲染管线，并要求在启动前或 begin/commit 事务内配置；这里减少的是重复重配，不保证系统初始化可以归零。依据：[Apple isCinematicVideoCaptureEnabled](https://developer.apple.com/documentation/avfoundation/avcapturedeviceinput/iscinematicvideocaptureenabled)。

DEBUG 诊断仅累计电影输出图重建次数，不增加发布频率或常驻额外相机会话；真机回归检查每次用户进入仅建图一次，并以最终切换标识对应的新预览发布作为可用性判据。


## 2026-10-23 慢动作换镜与变焦物理路线

`selectLensOnQueue` 的专用视频单事务条件扩展到 `requestedVideoSettings.captureFrameRate != nil`：切换物理输入后，在同一最外层 begin/commit 中完成自动控制初始化、目标倍率、最终高帧率格式与共用录制/预览输出配置；避免先提交普通帧率输入再配置慢动作。提交后补齐输出连接方向，不发布尚未恢复照片格式的中间照片能力。慢动作同一物理输入内切焦段只改倍率并保留现有预览图，新路由帧标识继续驱动原有局部切换淡出。

`applyContinuousZoom` 在慢动作 A 挡使用物理路线，不能复用普通 A 挡的虚拟多摄分支；M→A、所选 1× 的 24/35mm 切换和双指/变焦轮均走此入口，因此需要相同约束。实际换物理输入时，慢动作仍将输入、倍率与高帧率输出纳入同一事务；错误分支先结束尚未提交的配置事务，再走既有恢复路径。普通 A 挡自动虚拟多摄规则、系统自动微距、RAW 与电影各自的设备选择规则不因本条件改变。

依据：[Apple beginConfiguration](https://developer.apple.com/documentation/avfoundation/avcapturesession/beginconfiguration()) 允许将输入/输出与设备参数变更组合为原子更新，嵌套配置到最外层 commit 才生效。此优化减少中间图启动，不保证跨物理传感器换镜完全无间隔，也没有新增多摄并行常驻采集。


### 前后切镜方向耗时与过渡收尾（2026-10-23）

- `flipCamera` 保留既有 `startFocalTransition`、旧帧轻微模糊、最终路由出帧后局部淡出的路径，只将该入口的收尾淡出设为 0.10 秒；A/M 与普通固定焦段仍沿用各自既有时长，系统自动微距不增加过渡。减弱动态效果继续走现有短淡出，失败继续超时释放。
- Debug 构建用有界的最后一次前后切镜阶段字典记录输入、连接、照片输出、最外层提交和提交后连接设置的耗时；不发布 ObservableObject 更新，不积累逐帧数据，Release 不编译该计时。性能测试同时等待目标朝向就绪与 `userSwitchFrameID` 更新，单独统计旧帧过渡已清除时间，不把会话配置结束当作用户已看到新帧。


### 前置自动构图能力状态（2026-10-23，入口已改为照片画幅切换）

- `observeFrontSmartFramingCapabilities` 在前置绑定当前真实设备的 `activeFormat` 和 `AVCaptureSmartFramingMonitor.supportedFramings` KVO，离开该设备时释放观察者；回调只在相机队列上核对仍运行且输入对象一致后，重新准备候选并刷新监视状态。普通宽窄切换不重复安装同一设备的观察者，不增加定时轮询或重启采集会话。
- 前后切镜最外层提交后再次读取 Smart Framing 能力，覆盖系统在提交阶段更新格式的情况。`publishFrontAutoCenteringState` 以 `PreviewRevision` 丢弃主队列中已过期的状态，并只发布真实变化；当前设备、格式与支持的 3:4 构图共同决定是否可用，不强制开放系统不支持的格式。监视器已运行时也更新按钮状态；候选不变则不重复设置 `enabledFramings`。
- 以上为原 Smart Framing 入口的能力刷新实现记录。该入口随后按用户要求改为前置照片竖幅／横幅切换；当前按钮、方向处理及能力规则见“前置取景与横幅照片”。Smart Framing 监测代码保留，当前拍摄页不提供启用入口。


### 照片/视频切换的最外层事务（2026-10-23）

`setCaptureKind` 在原有同步状态更新前调用 `beginCaptureKindConfiguration`，并以 `defer` 排入对应的 `finishCaptureKindConfiguration`。相机串行队列只在当前运行、无拍摄上下文且非恢复状态下开启事务，以 token 记录实际开启的事务；只有对应 token 存在时才提交。原有 A/M、Live、HDR 和视频规格函数继续使用各自事务，嵌套到同一最外层提交，避免每个中间路线分别启动输出图。每次入口同步排队结束前即排入 finish，后续停止/恢复请求在其后执行；不在主线程等待系统提交。

最外层提交后重新设置连接、读取前置 Smart Framing 与最终照片能力、同步预览，再标记最终用户切换帧。媒体切换沿用 `startFocalTransition` 局部旧帧轻微模糊及新帧后淡出，正常收尾 0.14 秒，减弱动态效果和失败超时仍走原有逻辑；没有新增会话或干预系统自动微距。

返回照片始终调用 `setMode(photoModeBeforeVideo)`，包括原照片 A 挡；旧代码跳过 A 挡恢复，导致视频 M 挡意外留在照片页面。曝光值仍在视频输出移除后恢复，避免被视频帧间隔限制。依据 Apple [beginConfiguration](https://developer.apple.com/documentation/avfoundation/avcapturesession/beginconfiguration()) 及 SDK 关于嵌套事务只在最外层提交生效的说明；系统不保证具体提交耗时。


### 视频挡位独立恢复（2026-10-23）

`videoModeBeforePhoto` 在离开视频时记录，进入视频后恢复；不再强制 A 挡。照片继续使用 `photoModeBeforeVideo`，媒体重配仍包含在同一个最外层事务内。先切换 captureKind 退出照片专用子模块，再恢复视频挡位，避免照片夜景的 A 挡限制阻止恢复。

`SavedCaptureState.videoMode` 为可选字段，兼容旧存档；停在视频的旧存档按其当前 mode 推导，停在照片的旧存档默认视频 A。保存设置关闭时冷启动规则保持不变。`setMode` 只在 A→M 时应用旧手动快照，M→M 同挡位重配使用当前快门/ISO 等参数，避免较早的快照覆盖新参数。这是应用的状态恢复策略，不属于 Apple 对媒体模式记忆的保证。


### 正常镜头重配保留最后一帧（2026-10-23）

`selectLensOnQueue` 提交完成后以及 `setManualMode` 完成路线切换后，不再向主队列发布 `preview = nil`。旧实现可能在新帧已发布后再次清空预览，或在慢快门等待新帧期间使页面落入首次启动的准备提示。现在保留最近取景，新路由的帧时间门限与 `userSwitchFrameID` 仍决定既有局部旧帧模糊/淡出的结束；没有增加冻结时长或新过渡样式。

保留应用显示的 UIImage 不代表路由已就绪，ready、真实出帧标记、恢复状态与错误处理仍单独判断。系统自动物理镜头切换不走该用户入口，不新增过渡；首次没有任何取景的启动仍显示准备提示。该修正针对应用预览状态发布顺序，不将其描述为 Apple 要求清空或保留 UIImage，也不承诺缩短底层会话提交耗时。

## 延时拍摄间隔与张数（2026-10-28）

延时启用后，`videoRatioOptions` 在比例网格下增加 `TimeLapseInterval` 和 `TimeLapseFrameCount` 两组 5 列选项；非延时模式不生成这两组。`CameraViewModel` 将所选间隔和张数、显式 `timeLapseEnabled` 传给 `CameraEngine.startVideoRecording`；即使预设被取消仍可延时。顶部画面比例按钮在延时启用时用第二行 8 号字显示当前“间隔·张数”，数值来自同一状态，不另算复制值。`MovieRecorder` 的 `TimeLapseFrameScheduler.maxFrames` 达到上限后通过 `onTimeLapseLimitReached` 回调停止录制，∞ 传 nil 并保持手动停止；每接受一帧通过 `onTimeLapseFrameAccepted` 更新快门剩余张数。有限张数只按已接受帧计数，不按墙钟时间估算。

## 慢门预设的 M 挡范围（2026-10-28）

`toggleSlowShutterMode` 在从 M 进入时先 `setMode(.auto)`，确保预设与自适应曝光一致；`selectSlowShutterPreset` 对当前预设做开关，相同预设再次点击会清空 `selectedSlowShutterPreset` 并保留慢门模式。`setMode(.manual)` 不清空 `slowShutterEnabled`，保存 A 挡预设快照、暂清当前预设并重置1s、关闭时长弹窗，让 `hasActiveSlowShutterPreset` 变为 false；2026-10-29起切回 A 挡恢复该快照及合法时长，无预设则1s；预设条只在 `slowShutterEnabled && mode == .auto` 时显示，M 挡保留慢门状态但参数使用完整手动范围。`hasActiveSlowShutterPreset = slowShutterEnabled && selectedSlowShutterPreset != nil` 是 M 挡范围收紧的门槛。快门范围仍用 `preset.shutterRange(limitedTo:)` 的自适应范围，本轮没有额外的 M 挡手动快门范围；ISO 范围用 `manualISORange` 把预设建议 ISO 与硬件范围求交。仅开启慢门但未选预设时两者都返回硬件范围。序列曝光规划仍使用硬件 ISO 范围，避免把 UI 限制误当成暗光合成上限。

## 慢门拍摄时长（2026-10-28）

`SlowShutterDuration` 提供 0.3、0.5、1、3、5、10、15、30、60 秒和 ∞ 十档；顶部 Live 在慢门开启时替换为时长按钮，弹窗复用 `toolbarOptionsPanel` 的玻璃容器和 `choicePill`，按 5 列两行排列。顶部显示值就是启动时读取的目标时长；选中预设会写入预设默认时长，取消预设（A 挡）恢复 1s。未选预设时使用完整硬件曝光范围的通用测光规划生成平均融合序列，保留显式 M 挡快门与 ISO，`spec.captureDuration` 取顶部当前值。`startSlowShutterSequence` 在自适应曝光计划之后调用 `sequenceSpec.applying(duration)`，覆盖 `captureDuration` 并按预设采样率重算帧数；有限时长达到后由 `advanceSlowShutterSequence` 自动结束，序列进行中再次按快门走 `finishSlowShutterSequenceEarly`，∞ 使用 `Int.max` 作为流式计数边界，不以旧的36,000帧自动截止，依赖再次按快门结束或取消。时长随拍摄状态持久化，恢复时校验预设范围。序列进行中时长按钮禁用，退出慢门会关闭该弹窗。

## 真机测试隔离（2026-10-29）

会话恢复测试单独运行及与物理相机切换连跑均通过；全量串行后出现的 `FigCaptureSessionRemote -12784` 和“camera ready”超时未能在小批量复现，不能归因于单个测试用例。物理测试应分组并在组间重启测试宿主/重置相机，避免长时间复用同一 AVCaptureSession 进程。

## 同步双拍变焦限制（2026-11-02）

当前双拍后置主画面变焦由 `CameraEngine.setDualCaptureMainZoom` 逐事件提交到 `DualCaptureSource.setMainZoom`；每事件锁设备、设置 `videoZoomFactor`、递增 readings generation 并同步预览状态。双拍使用 `AVCaptureMultiCamSession`、两路视频输出和前后合成预览，逐事件设备锁与预览状态刷新会放大卡顿。

待实施方案（未落地）：用 LatestValueThrottle 合并变焦目标；用 `ramp(toVideoZoomFactor:withRate:)` 平滑；变焦期间只更新 `currentZoom`/选中焦段，稳定后再同步预览状态；变焦期间锁 AE/AWB；监测系统压力。不得以关闭预览渲染规避卡顿。

## 同步双拍子模块与主画面控件（2026-11-02）

视频子模块为延时、慢动作、电影、同步双拍、虚拟光圈三列；前置模式过滤虚拟光圈。固定控制栏不再有独立双拍按钮，入口只在子模块。`CameraEngine.dualCaptureMainIsFront`、`dualCaptureMainZoomRange` 发布主画面状态；双击小窗交换时更新。`CameraViewModel.displayedFocalPosition` 在前置主画面返回前置、后置主画面固定返回后置，`displayedFocalLenses` 据此过滤；双拍后置不显示 0.5×。

双拍后置主画面通过 `setDualCaptureMainZoom` 调数字变焦，由引擎按当前倍率更新 `selectedLens`，焦段条按 `selectedLens` 高亮；命中的最近固定档显示实际倍率（如 2.6×），1× 保留 24/35mm 切换。前置主画面显示前置标准/超广角切换；双拍开启时隐藏人物居中。后置长按焦段条可开变焦轮，捏合/拖轮/焦段都走主画面数字变焦，不重建会话。

## 视频虚拟光圈入口（2026-11-02）

视频虚拟光圈开启后，控制入口位于子模块按钮上方，不使用顶部色彩空间槽位；按钮为无背景 `ƒ + 数值`，点击向上展开竖向 `videoVirtualApertureVerticalControl`，色彩空间弹窗只保留色彩空间选择。旧焦段条上方滑块已删除。

## 录制中虚拟光圈更新（2026-11-02）

`MovieRecorder.filterLook` 改为可变，`updateLook` 只在录制启动时已配置图像处理 look 且色彩空间有效时更新；`CameraEngine.updateLook` 在更新预览 look 后将其投递到 `recordingQueue`，使录制中的虚拟光圈滑杆变化作用于后续帧。录制开始时的元数据快照仍记录初始虚拟光圈。

## 视频防抖设置（2026-11-02）

`CapturePreferences.videoStabilization` 持久化关闭/低延迟/标准/电影，默认低延迟。`CameraEngine.setVideoStabilizationPreference` 在视频待机时同时应用到 `videoOutput` 和 `recordingOutput`，预览与成片使用同一模式；`applyVideoStabilization` 按格式能力回退（电影→标准→低延迟→关闭，低延迟在 iOS 26 以下回退标准）。RAW/Open Gate 仍关闭防抖；照片预览仍使用 `previewOptimized`。设置在下一次开始录像或重新配置时生效。

## 人像景深控制（2026-10-30）

人像模式下 `toolStrip` 的 Live 入口替换为 `ƒ` 景深按钮；`portraitDepthSliderVisible` 控制跟随顶部工具栏，挂在工具栏底部、水平居中，宽度取横竖屏较小宽度扣除直方图及间隔后的可用值，封顶 210pt，横竖屏同宽；绑定同一个 `portraitBlurStrength`；展开时顶部 ƒ 按钮显示百分比，滑杆右侧同步数值。虚拟光圈复用同一位置和尺寸，绑定 `virtualAperturePosition`，显示当前 `ƒ/` 值；照片模式移除焦段条旧虚拟光圈滑杆，视频模式暂留旧控件。旧 `fixedCameraControls` A/M 上方的 ƒ 按钮、竖向 `portraitDepthSlider` 和 `portraitDepthPanel` 已移除，微距标识单独保留；进入微距仍会收起滑块并停止预览分割。

## 实体 Camera Control 变焦（2026-10-29）

`CameraHardwareControls` 用 `AVCaptureSlider`/`AVCaptureIndexPicker` 注册 `AVCaptureSession` 控件。A 挡发布 `A.zoom`；M 挡仍只发布 `M.S/M.ISO/M.MF/M.EV/M.WB/M.TINT`，不注册实体变焦，屏幕焦段和捏合变焦不受影响。`handleHardwareAdjustment` 的 `A.zoom` 只在 A 挡生效。焦段条使用外层 `PreviewSurface` 液态玻璃，`CameraFocalControl` 选中项保留原有内部 `UIGlassEffect` 背景。当前点按选中焦段仍会出现双层背景，已回退到修改前实现，未继续修复。

## 照片/视频切换门禁（2026-10-29）

`CameraViewModel.setCaptureKind` 在切换开始时置 `captureKindSwitching` 并生成新 token；允许新的切换请求覆盖旧请求，旧完成回调因 token 不匹配而失效。完成后用 `CameraEngine.afterPendingSessionTasks` 等待会话队列排空，并要求 `camera.ready`、出现与切换前不同的预览对象、`videoConfiguring == false` 后才解除；最长 2 秒超时保底。切换期间照片快门和视频开始按钮禁用，`takePhoto`/`toggleVideoRecording` 也有同一门禁。这样不会在旧输出图仍连接或新路由未出帧时提交拍摄。

## 快门倒计时显示（2026-10-29）

慢门序列不再绘制刻度环。`SlowShutterSequenceProgress.countdownText` 在有限时长显示剩余秒数（小于 10 秒保留一位小数），∞ 显示已拍时钟。延时录制通过 `MovieRecorder.onTimeLapseFrameAccepted` 把实际接受帧数发布到 `CameraEngine.timeLapseCapturedFrames`：剩余张数放在预览底部，∞ 显示 `videoElapsedText`；快门白圈外的主体色圆弧按帧数旋转，每接受一帧转一圈。倒计时只在对应序列/录制进行时出现，合成中仍用加载圈。`slowShutterCaptureHidesControls` 在任何慢门序列进行且未合成时生效：只隐藏 `fixedCameraControls` 中的 A/M、辅助拍摄（tools）、子模块入口（shootingMode）、预设条和镜头条，以及它们附带的模式指示；顶部工具栏、滤镜、翻转、相册、网格、水平仪、直方图和快门保留。序列结束或进入合成即恢复。

## 慢门预设时长范围（2026-10-28）

`SlowShutterPreset.captureDurationRange` 把时长选项限定为光轨 10–30s、流水 5–15s、动态模糊 1–3s、摇拍 0.5–2s、星轨 60s–∞；`defaultCaptureDuration` 给预设写入默认值（15/10/3/1/60s）。`availableSlowShutterDurations` 过滤弹窗选项，选预设时同步顶部时长显示；A 挡再次点击同一预设取消时把 `slowShutterDuration` 恢复 `.s1`，不支持当前预设的档位直接隐藏。`slowShutterDuration` 随 `SavedCaptureState` 持久化；恢复时若预设仍有效则使用已保存且被该预设允许的值，否则使用预设默认值。未选预设时 `startSlowShutterSequence` 使用通用平均融合及完整硬件曝光范围，保留 M 挡手动值；时长取顶部当前值，不套用流水的最低帧数与采样节奏。

## 慢门与 Live 互斥（2026-10-28）

慢门序列使用静态多帧曝光，不能与 Live Photo 的配对视频同时请求。`CameraViewModel.livePhotoAvailable`、`canToggleLivePhoto` 和 `capturesLivePhoto` 均检查 `slowShutterEnabled`；开启慢门时统一清空 `livePhotoEnabled` 并同步相机 Live 音频/预览请求，能力刷新时也会再次关闭 Live。退出慢门不会自动恢复 Live，用户需重新开启。

## 慢门多帧序列（2026-10-23 第二阶段，历史）

`SlowShutterPreset.sequenceSpec` 只给光轨和流水返回多帧规格：光轨 10 帧×目标 1 秒/亮部叠加，流水 8 帧×目标 1 秒/多帧平均；10/8 秒表示目标累计曝光，不是完成耗时。星轨仍为单帧，等待长序列阶段。

`CameraViewModel.startSlowShutterSequence` 在照片模式读取当前测光值，按 1 秒目标帧换算 ISO，锁定曝光、白平衡和对焦；A 挡只临时使用这些值，结束后恢复原 A 挡。序列固定 JPG/HEIF、12MP，禁用 Live/HDR/RAW/TIFF、人像、夜景和连拍。

序列曝光路线与界面挡位分开：A 挡先用真实测光计算目标 ISO，通过现有 `setManualMode(true, customExposure: true)` 暂借支持 custom 曝光的物理镜头输入，界面仍保留 A；结束、失败或取消后按原挡位恢复路由。临时输入的 ready/能力发布不再触发普通参数恢复或 A 挡慢门策略，否则会覆盖序列的锁定曝光。普通自动微距不增加阈值或强制切镜规则。

序列显式启用 `setSlowShutterSequencePreviewAssist`，让每帧在 `setExposureModeCustom` 完成后才提交照片。读取源文件 EXIF 检查曝光；已知实际曝光偏离 1 秒超过 0.02 秒时停止并恢复，不把短曝光预览帧冒充目标慢门。提前结束的合成诊断记录实际帧数，A/M 记录用户挡位，曝光/焦距仍来自真实首帧文件。关闭慢门经统一清理入口清空预设与辅助，合成中的任务也失效；延迟下一帧任务校验序列 token，避免取消后的旧任务启动新序列。

每帧通过 `PhotoOptions.purpose = .slowShutterSequence(token)` 走现有 `CameraEngine.capture`。`CameraEngine.finishCapture` 对序列帧不再调用普通 `onCaptureCompleted`，也不逐帧编码，而是把全分辨率 `CIImage` 和诊断封装成 `SlowShutterSourceFrame` 交给 `onSlowShutterSourceFrame`；ViewModel 在帧回调后启动下一帧。`SlowShutterComposer` 保留懒加载 CIImage 图，亮部叠加使用 `CILightenBlendMode`，平均现使用 `CIDissolveTransition` 的标量帧权重（2026-10-25修正重复alpha预乘压暗），最终只由唯一一次 `PhotoEncoder` 渲染、应用滤镜/画幅并编码。

拍满或再次点快门时，ViewModel 先恢复相机曝光/白平衡/A-M 状态，再把帧数据交给 `slowShutterCompositionQueue` 合成；主线程只更新“合成中”、取消令牌和最终 `library.acceptCapture`。序列中禁止切镜头和 A/M；离开相机、关闭慢门或失败会恢复曝光/白平衡/对焦并删除未完成状态。快门圆环显示完成帧数，合成期间显示加载圈并禁用快门。

### 慢门序列的源图与预览辅助（2026-10-23）

序列帧在 `CameraEngine.finishCapture` 中不再逐帧 `PhotoEncoder`，而是把全分辨率 `CIImage` 放入 `SlowShutterSourceFrame` 交给 ViewModel。`SlowShutterComposer` 保留懒加载的 CIImage 图，最终由唯一的 `PhotoEncoder` 渲染和编码，滤镜与画幅只应用一次。

预设选择先启用普通慢门辅助，再提交手动数值；序列开始先启用序列辅助，再解除普通辅助；恢复时先让普通辅助接管，再释放序列辅助。这个交接顺序避免在两种短曝光预览之间短暂插入无人等待的长曝光设置，随后又被 AE 覆盖。真实捕获仍等待 Apple 的 custom 曝光完成回调，不用固定延时冒充硬件已应用。

预览侧使用 `setSlowShutterSequencePreviewAssist`：在帧间以 `applySmoothPreviewExposure` 保持短曝光自动预览，拍摄时通过既有 `usesPreviewExposureAssist` 路径临时应用手动 1 秒，拍完恢复。每次 1 秒曝光期间预览仍会停住，这是同一传感器曝光的固有限制。

真机测量（iPhone 17 Pro，10 帧光轨）总耗时约 42–47 秒，`phys_footprint` 峰值约 456–489 MB；主要耗时是每帧 `setExposureModeCustom` 从 1/30 秒预览切到 1 秒拍摄约 4.8 秒，不是合成或编码。2026-10-23 速度优先试验（持续 1 秒曝光、不切回预览）在真机未能稳定出帧并回退；该段是历史瓶颈记录。2026-10-24 已改用独立静态手动包围请求提速，见本文末节与专项验证；没有恢复那条失败的持续长曝光预览路径。


### 2026-10-24 前置传感器画幅与预览裁切方向分离

`LivePreviewState.Snapshot.nativeFrontSensorLandscape` 只表示相机队列已经确认的前置动态传感器横/竖幅，独立于 `look.landscape`（最终裁切方向）。视频缓冲新旧画幅过滤和匹配帧发布前置宽高比按钮状态，均使用传感器字段；最终画幅裁切仍使用 look。1:1 无横竖区别，不能用它的 false 裁切方向拒收已经确认的横幅输入，否则旧横幅预览会一直冻结。保留宽高比回调时间戳、预览代次与旧帧过滤，不添加自动切镜过渡，也不修改拍摄参数或成片旋转。

### 2026-10-23 全量失败项修复后的事务与帧节奏

- 媒体切换事务 token 同时保存切换前的显示倍率；最外层提交完成后按最终设备的显示倍率乘数恢复物理变焦，再发布能力。录像触感许可也在该提交之后恢复，避免内层事务尚未生效。照片 M 挡进入视频前保存 `SavedManualCaptureState`，返回照片再应用；`SavedCaptureState.photoManualBeforeVideo` 为可选字段，兼容旧存档并支持从视频冷启动返回照片。
- 自动镜头候选使用当前设备公开的 `supportedFallbackPrimaryConstituentDevices`，不缓存格式变化中的临时子集；A/M 连续变焦和输入替换各自在最终提交后恢复全集。系统 `.auto` 决定实际近远切镜，无计时重对焦、距离阈值或强制主摄。
- 高帧率普通视频（>60）与慢动作共用录制输出供预览，录制队列继续只负责快速送帧，预览渲染在独立队列。先调整输入 `videoMinFrameDurationOverride` 的资源上限，再写设备帧周期；照片路线清除输入上限。实际文件帧率仍必须以时间戳/轨道验证。
- `FrameRatio.crop` 使用源图内部整数像素矩形，按最近像素居中；预览/编码共用，不用拉伸消除小数边界扩张。高像素捕获在请求前核对活动格式的尺寸缓存；最大尺寸是请求上限，系统可能返回较小照片，元数据保留实际文件值。
- DEBUG 硬件测试复用唯一可见引擎并重置内存规格，不创建多个竞争设备的诊断会话。全滤镜渲染矩阵按单项释放对象和缓存，不将测试宿主资源开销写成 App 内存结论。
- 冷启动设置恢复测试需要新建模型时，先让可见模型退出：等待主队列提交生命周期请求，再等待相机队列完成，并读取实际 `session.isRunning == false`。每轮正常或抛错都异步停机后才创建下一模型；`afterPendingSessionTasks` 本身只覆盖已提交的引擎工作，不代表尚在主队列等待的模型生命周期已经完成。重复新模型启动是同一测试进程的恢复指标，不标为操作系统进程冷启动。

### 2026-10-23 单张人像请求与实际微距互斥

`CameraEngine.capture` 构造单张 depth/matte 设置时，通过 `activePrimaryConstituent`、实际倍率和 `CameraMacroPolicy` 判断系统微距，不依赖延迟发布给界面的 `macroActive`。微距优先时仅关闭当前 `CaptureContext.options.portraitMode`，不请求深度/遮罩，不执行后备人像虚化，并校正拍照类型；用户开关与全局深度管线不变，下一张重新判断。此为应用既定互斥规则，不是苹果明确规定所有微距+深度必然超时。

DEBUG 阶段日志补充 `willBeginCaptureFor` 的系统预期处理范围及提交时 `captureReadiness`，默认关闭。预期范围仅用于诊断，不作为硬性超时期限；没有增加超时重拍、距离阈值或强制切镜。

### 2026-10-23 普通视频输入替换的完整事务

`applyContinuousZoom` 在任何视频路线更换输入时保留最外层配置事务，等待 `configureConnections` 设置最终格式/输出、倍率及状态后再提交；不再只有慢动作保留事务。`selectLensOnQueue` 的视频固定焦段切换也统一批处理。普通照片仍沿用既有路径，前后切镜与 A/M 过渡保持 `startFocalTransition`，不干预系统自动微距。

DEBUG 配置历史仅存最近 32 条操作，出错时按条记录引擎标识、运行意图、输入和格式，避免延迟快照被误当作触发点。测试的 `SessionRuntimeErrorAudit` 在原七个相关方法期间监听所有会话，真实错误直接导致失败；恢复专用方法明确注入错误并独立计数，不与正常操作混淆。

### 2026-10-24 星轨/动态模糊的流式合成

`SlowShutterSequenceSpec.frameExposureSeconds` 用累计曝光 / 帧数定义本预设的单帧曝光；源帧验证与拍摄设置使用相同值，不再把所有序列固定视为 1 秒。星轨为 120×1 秒 lighten，动态模糊为 8×1/8 秒 average；旧光轨/流水参数不变。

新预设的 `SlowShutterSequenceState` 分离 completedFrames 与保留的源图数量，frames 仅留首帧元数据。`SlowShutterComposer(materializeFrames: true)` 只在合成串行队列访问，逐帧用 CIContext 非延迟输出 16 位 P3 CGImage，下一帧使用已渲染结果，切断历史 CIImage 依赖链；旧光轨/流水仍使用原惰性短序列路径。最终编码只应用一次 CaptureLook，源帧不提前套滤镜。

每个 `SlowShutterSourceFrame` 带序列 UUID，取消后的迟到帧不会污染新序列。源帧正在合并时，提前结束记录 finishRequested，等这一帧计数完成后再编码；取消直接使序列/合成 token 失效，后台返回不保存。实际合成帧数用于进度和诊断，EXIF 保留真实单帧快门，累计曝光另作说明。

### 2026-10-24 慢门静态曝光请求与预览分离

PhotoOptions.prefersManualExposureBracket 仅由慢门预设设置。CameraEngine 对标准分辨率、非 RAW/Live/HDR/夜景/人像、已有独立手动拍摄值且需要预览曝光辅助的请求检查包围能力及当前快门/ISO 范围；符合时构造一张 AVCaptureManualExposureBracketedStillImageSettings，并提交 AVCapturePhotoBracketSettings。CaptureContext.usesManualExposureBracket 标记其不需要临时 setExposureModeCustom 或逐帧恢复 AE；其余请求保留原路径。包围请求不设置不支持的 flashMode，不更改用户可选规格，也不进行多帧批量预提交。

ViewModel 仍逐张接收源帧、验证 EXIF、完成相应合并后推进；硬件和容量已释放，移除下一张前固定 60 ms 等待。序列 token、看门狗、单张占位、提前结束、取消和结束后的原参数恢复保持。DEBUG 可禁用新请求并启用阶段日志，用于同机对比，正常启动默认使用新路径且不打印阶段日志。性能与观测边界见 Docs/Test-Reports/2026-10-24-SlowShutter-Speed.md。

### 2026-10-24 人像预览时序与成片融合

PortraitPreviewProcessor 在独立串行队列复用 balanced VNGeneratePersonSegmentationRequest/VNSequenceRequestHandler，0.10 秒节流、最多一个在途。开关 generation 与镜头/读取代次/缓冲尺寸 route 对应的 epoch 分别隔离迟到数据；关闭后队列释放请求历史。最新蒙版按源帧年龄限制 0.55 秒，最后 0.20 秒用半径权重淡出；强度按 45 ms 时间常数趋近目标，照片仍直接采用保存时的目标值。

人像取景启用条件为人像开启、照片模式、相机活动且就绪、未处于 A 挡微距，独立于滑块展开。ViewModel 监听 ready、macroActive、mode、captureKind 并延后同步实时状态；setCameraActive 也同步释放。CameraEngine 沿用既有前置内参、方向、裁切与镜像坐标，只为同路线有效蒙版绘制效果；不干预系统自动切镜或其动画。

PortraitPhotoRenderer 的半径/边缘参数以 900 像素宽参考进行尺寸换算。背景权重先排除人物边缘，计算 Gaussian(image×weight)/Gaussian(weight)，再由 CIBlendWithMask 合回清晰人物；弱半径同步缩小排除圈以防黑边。使用内置 Core Image 滤镜，未新增运行时自定义内核。结果继承源 EXIF/TIFF，随后按既有 PhotoEncoder 输出和方向规范化。该路径是人物蒙版背景效果，不是由 AVDepthData 重建完整三维焦平面。记录见 Docs/Test-Reports/2026-10-24-Portrait-Optimization.md。

### 2026-10-24 M 挡人像应用能力与原生能力分离

CameraEngine.supportsPortraitCapture 和 PhotoLensCaptureCapabilities.supportsPortraitCapture 表示应用人像入口可用性，来源为原生能力或当前照片路线可用的 JPG/HEIF 软件人物分割。PortraitCapturePolicy.supportsSoftwarePortrait 只判断兼容处理格式与标准照片尺寸；不替代真实深度/蒙版管线属性。配置输出及逐张请求仍使用 AVFoundation 实际支持/启用状态。

单张 preflight 在原生 depth/matte 不可用时先核对照片策略；兼容则保留 portraitMode，finishCapture 沿用 Vision 后备分割，无可用人物时保留清晰原片。M 挡物理输入和手动参数不变，不通过自动切 A/虚拟输入绕过入口。RAW 原文件及辅助数据行为沿用原逻辑，不宣称软件虚化烧录 DNG。见 Docs/Test-Reports/2026-10-24-Portrait-M-Entry.md。

### 2026-10-24 静音快门统一原生提交

`submitPhotoCapture` 在每个原生请求上查询输出的官方静音能力，并应用CaptureContext中的静音快照；不再在普通入口排除夜景。这样首批/追加夜景、单张、Live、RAW及手动包围共用安全判断。组内偏好变化只影响下一次逻辑快门，既有组保持快照。DEBUG最近请求标志亦在统一入口记录，不模拟/修改系统音量或录音。

### 2026-10-24 普通手动照片的曝光提交同步

`CaptureContext.manualExposureForCapture` 不再仅在预览辅助时记录：普通照片 M 挡自定义曝光也保存请求快照。`submitPhotoCapture` 在官方 `setExposureModeCustom` 完成回调、会话仍运行且请求上下文仍有效时才提交该张照片；手动包围请求仍直接提交，A挡、Live与夜景自动曝光路径不变。`usesPreviewExposureAssist` 继续单独决定是否恢复短曝光预览，不因新增快照而把普通M挡切回自动。现有原生超时与唯一token清理保护继续覆盖等待阶段，迟到回调不能提交已清理请求。照片保留speed优先级，以遵循苹果对自定义曝光的要求。该同步用于防护间歇性参数/实际文件不一致，不宣称系统内部根因已确定。

### 2026-10-24 录像白平衡等待阶段的取消隔离

白平衡锁定等待由会话队列的 `videoWhiteBalanceLockToken` 标识，pending为令牌是否存在，并临时持有安全作用域访问。`stopVideoRecording` 在尚未创建写入器时主动清令牌、释放访问并恢复白平衡，再于主队列交付一次取消；不依赖硬件回调能否继续到达。迟到回调及排队的startRecorder都必须匹配同一UUID，不能启动旧写入器或改变下一请求。重复停止没有写入器时，也要确认主队列没有新videoCaptureToken才能清忙碌状态。已开始写入的路径仍在recordingQueue顺序append/finishWriting，结束回调按writer状态判定；文件所有权及系统相册策略不变。

### 2026-10-25 录像白平衡与慢动作重定时写入

- `lockVideoWhiteBalanceBeforeRecording` 区分普通视频与 `synchronizesRAWMetadata`。普通视频有合法当前增益且支持自定义增益时，用无完成回调的官方接口固定快照，否则设置locked模式，不依赖HDR路线可能未送达的增益回调。RAW调用显式传true，仍等待原生锁定完成后才查询推荐配置/元数据，取消令牌和安全作用域流程保留。停止恢复原模式；已有手动白平衡不被改为自动。
- `MovieRecorder` 源帧率提示使用captureFrameRate（若有），而不是慢动作播放帧率。普通/RAW实时写入提示保留true，仅已把PTS放慢的慢动作设false；本机实测减轻持续notReady反压，仍先检查ready再append，不增加应用层积压队列、不二次编码。该策略是特定重定时路线的实测选择，不能当作苹果对所有实时采集的普遍建议；长时系统内部缓冲行为仍需验证。
- DEBUG统计提供received/written/span及未就绪、append拒绝、时间轴拒绝计数；录制结束后在主队列发布给用例。统计不等于独立App内存或屏幕FPS。

## 2026-10-25 流水自适应曝光与采样

本节替代旧流水“8张×1秒”的固定曝光描述；光轨、星轨及摇拍的曝光策略保持。

`AdaptiveWaterExposurePolicy`分离单帧曝光与采样时长。A挡及M挡自动曝光按读取的ISO×秒选择常见快门/ISO对，在硬件范围及约0.2EV匹配内偏好低ISO，最长1秒；M挡已有手动曝光则保留。流水开放硬件真实ISO/快门范围，选择预设不强制把M挡变手动。序列开始时冻结本次计划及WB/焦点，避免帧间自动亮度波动。

运行时`SlowShutterSequenceSpec.exposureOverride`提供真实单帧曝光，`captureDuration=8`从首个源帧交付开始计时，至少8帧、最多64帧；因此8秒不是成片完成时间或EXIF累计曝光。原生`AVCapturePhotoOutput`仍每次采一张全分辨率静态照片，不改成视频预览帧。逐张验证实际EXIF快门，流水容差max(50微秒,2%)，不满足时停止恢复。常见曝光档位是本机元数据归并观测后的应用策略，非官方硬性限制。

流水使用有界逐帧16位P3检查点，只保存首帧元数据/诊断与当前平均结果；不保留全部全分辨率源帧。平均模式共用`CIDissolveTransition`的1/(n+1)权重，避免RGB和alpha同时缩放的重复预乘压暗；该修复也覆盖动态模糊。亮部叠加继续`CILightenBlendMode`。滤镜/比例仅在最终编码应用一次，真实单帧EXIF保留，帧数/采集时长/累计曝光另写诊断。

提前结束时若有原生捕获或合并在途，先标记finishRequested，待本帧返回后结束；序列期间的快门不因单帧busy被禁用。恢复前通过`clearSlowShutterSequenceCaptureExposure`清理旧物理输入帧时长，再恢复A/M及原参数；取消token继续隔离迟到结果。此处为初版记录；流水手持配准已由下方 2026-10-29 实现替代。没有加入自动微距干预。原生照片离散采样不承诺ND连续长曝光效果，具体指标和未验证项见流水专项报告。

## 2026-10-25 流畅预览与普通手动照片交接

预览使用有界AE与原视频HDR流策略；静态手动请求仍快照`manualExposureForCapture`。正式custom曝光提交前释放AE专用上限，使用`updatePreviewHDR(customExposure:true)`统一与辅助关闭时的传感器策略，再等待官方曝光完成回调。普通M挡原有speed质量优先级不变。

`didCapturePhotoFor`只释放非夜景的快门占位，不再调用`finishPreviewExposureAssistCapture`。该恢复统一在`finishPhotoCapture`的原生最终完成、提交失败或超时清理中执行，并尊重最新辅助偏好及其他在途请求；避免原生照片尚未完成时切回AE/HDR流。EXIF数值与实际输出像素分别验收，不能以诊断读数正确代替成片效果检查。专项对照的残差与未覆盖格式见验证报告。

## 2026-10-25 五种慢门统一自适应与中央主体对齐

本节替代旧光轨固定10×1秒、动态模糊8×1/8秒、星轨120×1秒及摇拍单张的描述。`AdaptiveSlowShutterExposurePolicy`复用流水已验证的曝光量匹配器，只复用ISO/快门匹配，不复用艺术融合方式。`SlowShutterPreset.sequenceSpec`定义各自采样时长、最少/最多帧和blend；运行时写入真实`exposureOverride`，M挡已有手动曝光保留，自动曝光按测光规划。ISO使用硬件范围、快门下界扩展至硬件短曝光，预设上界分别保留1秒/1/4秒/1/15秒。

光轨10秒8–96帧lighten，流水8秒8–64帧average，动态模糊2秒6–24帧average，摇拍1秒3–8帧subjectAlignedAverage，星轨120秒16–512帧lighten。`firstSourceTime/lastSourceTime`记录原生源图交付，达到目标跨度且满足最少帧才结束；达到上限也收尾。不能用主队列/最后一帧合并耗时冒充采样跨度。

所有预设使用有界逐帧16位P3检查点。`SlowShutterSubjectAlignment`仅为摇拍建立最长640像素探针，对中央40%做Vision平移配准，用96×96灰度相关性校验（至少0.75、纹理方差>16、平移各轴<=全画面8%），全分辨率图应用验证后的平移并保留公共边界。不是语义主体追踪或透视恢复。失败后`SlowShutterComposer`选中央边缘能量最高的候选单帧；`frameCount`统计实际源帧，`effectiveFrameCount`回退时为1，诊断分开列采集/融合帧数和回退原因。

M挡手动WB/焦点保留，否则拍前锁定读数；结束、失败、取消仍走统一恢复。序列或合成中禁止选择新预设，避免帧间隙改变后续原生曝光；快门仍支持提前结束、关闭模块可取消。新逻辑没有改变自动微距决策、格式编码和其他页面布局。真实星空/运动场景验证限制见专项报告。

## 2026-10-25 M挡恢复自动的帧时长与读数交接

`setExposure(nil,nil,...)`在照片路线先退出custom，再通过`restoreAutomaticPhotoFrameDurations`释放手动曝光改变的activeVideoMin/MaxFrameDuration，随后恢复HDR流；不重置视频帧率。流畅预览拍摄后恢复AE也执行相同帧时长释放。

`refreshAutomaticParameterReadings`仅照片路线设置LivePreviewState的`readingsRefreshRevision`和1.5秒`readingsFastUntil`。预览队列发现新代次立即采样，其后窗口内每0.08秒、常态每0.4秒；无帧或后台时不运行额外轮询。主线程继续延后一帧发布，叠加检查刷新代次、读数路线代次及微距路线代次，丢弃自动切换前排队的旧值。WB/色调和AF恢复自动同样请求刷新。数值始终来自设备，不将“收到指令”当作硬件收敛，也不把旧读数估计成新自动值。

## 子模块弹窗三列布局（2026-10-26）

`ShootingModePanelLayout` 新增 `rowSpacing = 10` 和 `panelHeight(for:)`；选项超过 3 个时按两行计算高度。照片选项为慢门、夜景、人像、连拍、虚拟光圈、智拍，使用 3 列 `LazyVGrid`；视频为延时、慢动作、电影一行。虚拟光圈是占位入口，图标 `camera.aperture`，点击只显示未开放提示，不接入捕获、景深或光圈参数。按钮尺寸、选中/禁用样式和无障碍标识保持原组件规则。

### 拍照子模块入口图标（2026-10-26）

`CameraViewModel.shootingModeButtonSymbol` 在照片模式默认返回 `camera.fill`；存在 `activePhotoSubmode` 时返回该子模块的 `symbol`，关闭后回到相机图标。弹窗内部恢复 `PhotoSubmode.symbol` 原语义图标：慢门 `timer`、夜景 `moon.stars.fill`、人像 `person.crop.rectangle`、连拍 `square.stack.3d.up`；虚拟光圈 `camera.aperture`、智拍 `sparkles`。图标只影响入口/弹窗显示，不改变子模块能力、按钮尺寸和触控逻辑。

## 2026-10-28 遗留失败修正后的捕获边界

- 手动静态请求：`supportsManualBracket` 同时检查 `.custom` 与 iOS 27 对具体光圈/时长/ISO 的 `supportsExposureModeCustom`。创建设置和真正提交前各校验一次当前格式，防止排队期间路由改变后提交非法包围曝光。普通 M 挡标准 JPG/HEIF 与慢门可使用单帧手动包围请求绑定真实曝光；RAW、Live、人像、夜景仍走各自流程，不把所有请求改成包围曝光。
- 慢门首次采样先让出主线程、等待 `afterPendingSessionTasks` 屏障及就绪状态，并校验序列 token；活动序列恢复保持其手动硬件路由，避免生命周期遗留 stop 取消新一轮。无预设通用序列使用完整硬件范围及顶部时长，不套用流水的最低帧数/曝光范围。预设只允许 A 挡；M 挡暂不应用预设，保留慢门本身。2026-10-29起另存 A 挡预设快照用于往返和存档恢复。
- 固定视频节奏：关闭自动帧率，设置输入预算与设备 min/max duration，能力支持且满足最短周期时使用官方输入锁帧。改规格先释放旧锁，回照片清除锁。电影模式沿原电影帧周期路径，在配置电影前释放普通视频锁帧，不把本机的输出图冲突写成官方普遍互斥规则。
- HDR HEIF高像素：高分辨率只是请求上限。原生 HDR RAW 实际低于40MP时记录设备ID，在原生捕获完成后才向主线程发布能力观测；物理主摄与其虚拟路由复用该观测，避免往返清空。HEIF HDR规格回落标准，文件保留真实尺寸与PQ位深；不自行放大。记录仅限本次会话/实测镜头，不持久化为所有设备的固定限制，SDR高像素保持开放。
- 延时调度使用候选scheduler，仅当writer append成功后提交计数和采样时间，目标帧数按成功编码帧触发停止；0目标拒绝，无限不计目标。无预设存档不自动填回默认预设，同挡位setMode不重置自定义值，真正切挡仍遵守当前默认策略。
- DEBUG夜景批次通知在实际提交设置、写入本次静音诊断快照后发出，避免测试先收到计数再读取到旧状态。生产夜景融合策略未因这项测试时序修正而改变。

关联证据、失败尝试与限制见 [FailureResolution](Test-Reports/2026-10-28-FailureResolution.md)。

## 2026-10-29 A 挡夜景采光与自适应影调

`NightAdaptiveCapturePolicy.automaticExposure` 负责 A 挡暗光静态基准，不复用预览短曝光作为最终上限。它从冻结的测光 ISO×时长计算需求，在硬件范围内最多增加 2 EV，优先延长到最多 1 秒后再确定 ISO。首批三张仍由 `AVCapturePhotoBracketSettings` 提交：高光保护帧使用负偏移，两张基准帧优先提供可配准降噪样本；追加批次继续沿用冻结基准，不重新读取 AE。M 挡不经过该规划器。

`CameraEngine` 在首次会话配置、加入 `AVCapturePhotoOutput` 后且启动前设置 `maxPhotoQualityPrioritization = .quality`。`NightCapturePolicy.qualityPriority` 对夜景和手动/RAW路线统一使用 `.speed`，避免质量优先采集改变逐帧曝光时序；独立夜景在收到每帧后核对文件EXIF的快门/ISO，超出容差则停止合成。这个设置只使用 AVFoundation 公共能力，不代表接入系统相机未公开的 Night mode。

`NightPhotoMerger` 保留既有曝光归一、运动区域保护与暗部降噪；已移除“亮度优先影调”实验开关，自适应影调不再有独立的高亮分支。只有 A 挡自适应夜景至少两帧真实融合后，`automaticTonePlan` 才渲染 64×64 sRGB 探针，使用中位数和 95% 分位共同约束 `CIExposureAdjust`；随后应用按暗度调整的 `CIToneCurve`。高光余量不足时不做全局曝光补偿。单帧后备直接保留参考帧，非自适应调用不增加全局 EV。

## 2026-10-29 HEIF Pro 的底片基准与 HDR 高光分层

`AdaptiveRAWDeveloper.configure` 在底片支持时同时将 `CIRAWFilter.sharpnessAmount` 和 `detailAmount` 设为 0。前者是边缘锐化，后者是独立的边缘细节增强；两项都归零后才构成 HEIF Pro 的无锐化 RAW 基准。`localToneMapAmount` 继续使用每张 DNG 的系统默认值，白平衡/曝光调整仍在 RAW 阶段执行；用户编辑器的“模糊／锐化”位于解码之后，不受此基准限制。非自适应 HEIF Pro 捕获分支使用相同两项归零策略。

`AdaptiveDynamicRenderer.apply` 将 SDR 逆光恢复与 PQ HDR 分开。SDR 保留基于 p02/p10/p50/p90/p99.8 的 `shadowEV` 与 `deepShadowEV`；HDR 将两项置零，使 0...1 的黑位和中灰保持底片显影，只让 `adaptiveDynamic` 的连续肩部处理参考白以上的亮度并限制到内容上限。这样 HDR 是高光维度的扩展，不再承担全画面提亮。

`Imaging.filtered` 接受 HDR 上下文，并交给 `PhotoTone` 选择输出曲线。只有“清新明亮”分离 HDR 配方：保持零黑点、轻抬中间调并减少去饱和；SDR 参考曲线以及自然/电影/高对比的既有创作方向不变。滤镜仍先在 0...1 基础层处理，再由 `adaptiveHDRRestore` 按原像素余量恢复大于参考白的亮度，避免普通 LUT 截断 PQ 高光。

极影参考视频只用于比较公开产品行为；它展示的 ProRAW 输入、无锐化、四影调、48MP、HDR 和三测光不构成其内部实现证据。光屿不复制未公开算法，继续使用 Core Image/AVFoundation 公共接口、保留 DNG alternate photo 和嵌入式重新显影配方。

## 慢门 A/M 状态记忆（2026-10-29）

`setMode` 只在实际切挡且慢门开启时重置/恢复时长。A→M保存`selectedSlowShutterPreset`与`slowShutterDuration`到独立A快照，当前预设置nil、时长1s；M→A恢复快照，时长不在该预设范围则回预设默认，无预设则1s。M内编辑和同挡同步不会覆盖A快照。主动取消预设、`clearSlowShutterMode`和重新开启清空快照，避免旧预设复活。沿用当前`startFocalTransition`与弹窗淡入淡出路径，时长弹窗在切挡时关闭。

`SavedCaptureState.slowShutterAutomaticPreset/Duration`为可选兼容字段；保存A时从当前选择取值，保存M时取A快照；恢复时缺失字段回看旧preset/duration。M当前时长仍保存到既有字段，冷启动不额外覆盖用户在M内自选的时长，只有真正切入M时回1s。验证见[SlowShutter-ModeMemory](Test-Reports/2026-10-29-SlowShutter-ModeMemory.md)。

## 焦段条共用玻璃背景（2026-10-29）

`CameraFocalButton.usesEnclosingGlassBackground`从make与update两个路径传入`CameraFocalControl`。条内调用传true，由现有`PreviewSurface`负责唯一公共玻璃；原生控件不显示自己的选中effect/旧系统选中填充。独立按钮默认false，仍保留选中`UIGlassEffect`。文本颜色、字重及交互不依赖该背景标志。避免只在SwiftUI更新里清backgroundColor，却被UIKit的layoutSubviews再次加回内层effect。

## 2026-10-29 手持流水与夜景/慢门预览

本节记录10月29日策略；10月30日手持配准、自动单帧偏好和摇拍恢复已按下述更新扩展，原有夜景渐亮预览另见夜景多帧章节。

流水改用 `handheldAlignedAverage`。`SlowShutterGlobalAlignment` 在最长边 640 像素的探针上通过 Vision 平移配准，再用 128×128 灰度相关性复核；接受相关系数至少 0.72、每轴位移不超过原图对应边长 6% 的帧。首帧保留为基准，之后无法可靠对齐的帧只计入采集数与拒绝数，不参与平均。融合权重使用实际接受帧数，结果裁切至共同有效区域，保留有界 16 位 P3 检查点。它只能补偿整幅平移，不能消除单帧运动模糊、明显旋转、视差或全画面流水缺少静态纹理的限制。

流水自动曝光在保持测光曝光量和硬件范围的前提下，优先选择不慢于 1/30 秒的单帧；暗光受 ISO 上限约束时允许更慢，M 挡自定义曝光仍保留。默认采样 10 秒、可选 5/10/15 秒；采样时长与真实源图 EXIF 单帧曝光分离，不把 10 秒写成一张 10 秒曝光。诊断分别记录采集、对齐拒绝和有效融合帧数。

夜景从首个原生批次提交至最后一批硬件结束、曝光及原镜头路线恢复，使用 `LivePreviewState` 的预览保留标志。渲染入口和主线程发布入口同时拦截，继续显示已有 UIImage，因此 3→6→9 帧的批次间隔不发布曝光切换画面。结束时推进预览代次，丢弃旧时间戳和两张预热帧后恢复；提交失败、超时、取消及退出相机也释放标志。该策略在采集期间是静态保留画面，融合处理阶段已经恢复实时取景，不增加覆盖层或动画。

慢门序列继续独立短曝光取景与静态请求曝光，支持单张手动包围时不中断实时预览；不支持时，仅在临时切换成片曝光的请求期间使用相同保留机制。正常、失败及取消路径复用统一清理。预览不替代实际成片曝光，最终文件仍检查 EXIF。

## 2026-10-30 慢门普通手持容错

`SlowShutterGlobalAlignment`以最长边640像素的单张参考图保存几何锚点，调用`NightPhotoMerger.alignHandheldFrame`共享经过方向修正的Vision几何配准；只复用几何，不应用夜景影调或运动保护融合。平移优先，残差较大时尝试受界限约束的单应与小角度补偿。残差以96×72探针的6×4纹理区域评估，保留误差较小的一半、至少6块，降低流水/车辆局部变化对背景判定的干扰；缺少足够纹理则使用整幅残差，不虚构稳定区域。共享夜景调用的评分默认参数不变。

流水和动态模糊使用`handheldAlignedAverage`，光轨使用新增`handheldAlignedLighten`。星轨保持`lighten`，不把星体整体运动当作手抖消除。摇拍继续只估计中央主体平移，Vision的targeted/handler按floating/reference方向修正。低纹理首帧不锁死跟踪参考；`SlowShutterComposer`统一区分采集数、接受数和拒绝数，拒绝帧不参与权重，后续可恢复。尚无可融合结果时保留清晰单帧，至少两张有效帧后恢复融合，不再将一次失跟作为永久单帧标志。

自动曝光在现有±0.2EV匹配与硬件范围内，流水/动态模糊/摇拍优先≤1/60秒，光轨≤1/30秒，星轨≤0.5秒；ISO耗尽时可放宽，手动数值不经过该偏好。预设时长范围、默认时长和采集/预览分离策略保持。流式处理持续只保留有界检查点：累积图、清晰单帧备选和小参考；原生源帧队列不随序列增长。诊断记录实际采集/接受/拒绝和单帧回退，不能以请求张数冒充融合帧数。

慢门累积预览：每次源帧在`slowShutterCompositionQueue`完成真实融合后，按至少0.5秒的采样间隔调用`SlowShutterComposer.renderPreview`，以最长边900像素小图应用当前滤镜/画幅，不重新编码、融合或改变累积图。主线程用序列token复核再发布`SlowShutterAccumulationPreview`，`SlowShutterAccumulationView`只在原预览框内按版本交叉淡化（220ms，减弱动态效果80ms），不推移或拦截控件。结束时以正式`photo.preview`淡化接替，650ms后清理；取消、失败、后台即时清理，迟到回调不得复活旧序列。延迟清理只捕获ID，不额外持有整个序列合成器。

## 智拍短过渡与有效对齐计时（2026-10-29补充）

在直接跟踪坐标发布的基础上，`SmartCompositionGuideOverlay`仅给候选点/选中点的position附加45ms线性动画，不恢复低通或旧160ms补间；选中点以UUID作为视图身份，切对象不插值。正式入口读取系统减弱动态效果，传给纯内容组件，开启时不做位置动画；圈和按钮位置固定。可靠点实际进入绘制半径时，A/M均立即显示对齐颜色，不依赖提示文字迟滞。

`SmartAutoFramingGate`用pausedSince维护最多0.20秒短暂停顿：未确认或圈边15%范围内越界只暂停，恢复确认且点重新进圈后扣除暂停时间；未确认/圈外不能触发。大幅位移、持续失踪和显式取消仍清空计时。稳定性比较使用相邻确认帧，避免缓慢手持累计漂移不断触发起始点距离阈值。

评分空结果不代表对齐失败：`finishAutomaticSmartFraming`只在有评分时采纳推荐倍率，否则保持原倍率。等待硬件变焦稳定后提交主体对焦、标记gate完成并播放既有反馈；移除评分空时提前完成/静默返回。完成只表示取景流程与对焦指令已提交，未读取或保证硬件已合焦。工作被取消或等待失败时gate尚未封住，允许重新稳定对齐。场景建议、M挡仅参考和用户手动快门保持。

## M挡智拍与拍后重新引导（2026-10-29最新要求）

本节替代上文M挡仅参考及“明显换场景后重新引导”的描述。`smartAutomaticAllowed`允许A/M，仍检查媒体、锁定、弹窗和生命周期；完成变焦后只释放`manualFocus`并按主体投影对焦，保留曝光、WB及其自动/手动标志。等待硬件阶段还校验原A/M，切挡不让旧工作落地。M挡复用既有固定物理镜头的数字变焦，不切A/虚拟多摄。

`CameraEngine.deliveredPhotoRevision`仅在真实CapturedPhoto按快门顺序交付时递增。模型订阅后清除本轮完成/反馈并重置gate，保留当前仍有效的点；失败、单纯缩略图改变和慢门源帧不触发。`smartDisplayedCompositionGuide`允许主选暂失时用其他有效候选构建显示层，避免整层隐藏。普通状态没有隐藏计时器，只有对齐完成且位于1.6倍圈半径容差内、或实际拍摄时隐藏；不做场景切换检测。

同批选择先检查实际进圈的可靠点，旧的0.15锁定区不再挡住已对齐的另一点。同批切换到另一ID会重置本轮；自身变焦后全部ID重建不视作用户改选。模型正常与测试共用`publishSmartComposition`，覆盖候选选择、显示稳定器和自动取景链路。

## 端侧语义建议与跟踪分离（2026-10-29）

`SmartLocalCompositionAI`是单在途actor，输入最长边768的分析图和最多3个已有候选；Vision分类读取全景和安全裁切，给出受限目标偏好及保留环境标志。分类标签优先级、0.25/0.4置信门限和主体排序是项目规则，不当作专用审美模型已训练。无需自带/下载模型权重。

iOS27的`SystemLanguageModel.default`在available、vision及guidedGeneration能力都满足时使用图像附件和Generable结构，只输出已有索引、置信度及保留环境；否则使用Vision分类。没有PCC、网络API或自定义模型下载。请求不阻塞跟踪/评分队列；主线程返回时检查批次、代次、相机状态、3秒新鲜度，随后在跟踪队列核对UUID仍存活才应用。相机参数不能由AI直接产生，实际进圈选择优先于语义偏好。

`preserveSceneContext`经tracker与稳定器传递到候选取景器，限制为当前倍率原构图；其他情况继续原有安全边界与有限美学评分。取消/过期/低置信度保持基础Vision流程。当前设备系统大模型不可用状态及分类实际测量记录于Validation，不将编译通过等同系统模型生成通过。

场景缓存集中在`SmartSceneAnalysisState`，与`SmartSubjectTracker`一样仅由`camera.smart-capture`串行队列读写。其`@unchecked Sendable`表示受此队列所有权约束，不是允许调用者在任意队列并发修改。UI/AI返回通过调度到该队列才应用，消除MainActor模型属性被后台直接读写的隔离警告。

## 智拍早期收点与单次AF保持（2026-10-29）

`SmartAutoFramingGate.alignmentConfirmed`在有效对齐达到0.18秒时供UI使用，真正的取景触发仍为0.75秒。模型`smartAlignmentLatched`保留1.6倍圈半径的手抖容差，取消、换主体、拍照交付和停止会清理；UI只给候选层opacity做100/60ms淡出，位置跟踪仍45ms短过渡。完成不再插入实心橙点，仅空心圈保留250ms并淡出；按钮不动，评分等待用原中心圈内进度。

`SmartFeatureAnchor.seed`在框内至少保留模板半径+1像素和10%边距；`SmartFramingRecommendation.focusPoint(for:)`把实际AF采样点约束到框内12%，再做变焦与既有传感器坐标映射，显示纹理点不改。该框内规则是保守工程策略，不是完整前景分割。

2026-11-02起取消未对齐首次候选的额外预览AF，以减少初始扫描造成的点位重建；沿用正常取景AF，稳定对齐完成后仍传`smartSingleShot=true`，用户锁时不抢控制。`CameraEngine`对该路径使用autoFocus，并在会话队列持有KVO观察：实际扫描开始后首个isAdjustingFocus=false事件才切locked；所有回调校验目标代次、设备身份及保持标志。没有固定时延后的反复AF或距离/切镜规则。

`smartFocusHolding`是智拍内部保持，不复用用户AE/AF锁。参数恢复不把它重置为continuousAF，场景变化默认对焦回中也不覆盖；手动焦点、普通点焦、普通变焦、主动选镜头、A/M切换及退出清理观察并交还对应控制。stop仅清状态/观察，不额外启动一次对焦。普通focus默认参数和视频路径保持，曝光/WB未在本次控制中重写。不能以进入locked当作识别目标正确或所有光学呼吸已消除，实际取景边界见Validation。

## 智拍推荐范围偏好（2026-10-29）

`CameraReadings`增加单调采样时间、当前activePrimaryConstituent（物理设备则自身）的焦位与身份。推荐判断不用虚拟设备焦位冒充当前物理镜头距离。`SmartRecommendationRangePolicy`默认不放点，稳定焦位≤0.35抑制、≥0.50允许，中间保留状态；转换要求至少两个不同时间的新读数且跨度≥0.25秒，扫描中不确认，设备变化重新确认，系统微距立即抑制。这些阈值是工程代理，未按米校准；0近端/1远端及不可直接映射距离依据Apple当前lensPosition文档/SDK。

范围变化清理候选、门限、AI与取景任务，推进trackingEpoch阻止异步旧点回写；近景抑制时仅归还智拍自身的AF保持，系统继续原有对焦，不增加距离驱动切镜或定时对焦。场景参数建议仍可分析，范围只约束构图点和自动取景。检测器在不允许时不提名/跟踪构图候选，恢复后新代次检测。DEBUG受控点测试可显式绕过范围判断，范围专项则关闭绕过。

## 编译隔离与焦段操作（2026-10-30）

双拍小窗Coordinator明确MainActor所有权；录制创建、高分辨率暖机及智拍AF配置的外层闭包显式捕获self，保持原有异步操作存活与内层弱回调语义。双拍iOS27之前方向回退使用受支持的90°videoRotationAngle，iOS27继续原RotationCoordinator路径；诊断用视频帧提取改为异步image(at:)。原生测试探针以配置队列/采样队列和锁约束Sendable边界，前置预览及照片回调新增锁保护，不将AVCaptureDevice任意跨队列修改声明为安全。

`afterPendingSessionTasks`由DEBUG诊断区移为正式内部接口：照片/视频切换与慢门启动本已调用该会话栅栏，Release也必须存在。它只表示已提交会话任务执行完毕，不承诺传感器曝光/WB已生效，参数回归另读取真实状态确认。

焦段条不把前景按钮包含进交互glassEffect：独立Color.clear背景承载非交互PreviewSurface并关闭命中，原生按钮只负责文字/选中色和原touchUpInside/长按。48MP现在只显示0.5/1/4三个受支持原生镜头，切镜保留高像素；长按、捏合、连续变焦均禁用，智拍倍率范围锁定当前倍率。低分辨率条与交互规则保留。

## 视频镜头与规格兼容选择（2026-10-30）

`CameraEngine`在会话队列按设备缓存普通、慢动作采集、Open Gate、电影、RAW与前置居中格式，按逻辑焦段发布`videoSelectionCapabilities`。电影条目从实际Cinematic设备取得，并用专用格式的最小/最大倍率过滤前后置目录焦段。能力表独立于busy/录制状态，避免切换中出现列表清空闪烁；界面不逐帧枚举AVCaptureDevice格式。

`CameraViewModel`以当前选中物理镜头和精确规格计算分辨率、帧率、颜色、编码与可见焦段；慢动作使用传感器采集帧率，不能用回放30fps替代。选择方法拒绝不兼容项，电影分辨率/帧率调整也保留另一项。进入/退出特殊模式的原有准备与恢复、设备断开等运行时回退保留；双拍仍走独立组合策略，RAW仍受外接存储限制。连续变焦的物理路由候选同样读取缓存并保留视频规格，不干预系统自动微距。

虚拟多摄本身也缓存格式能力。A挡请求物理镜头支持、虚拟设备未公开的规格时，`videoNeedsPhysicalInput`改用当前兼容物理输入（例如本机4K120）；变焦及M→A沿用这一判定，避免回虚拟路由后降至60fps。虚拟路由支持当前规格时保持原自动多摄策略，不增加近远景触发规则。

顶部弹窗从完整可用宽度计算原有槽宽，再按可见按钮数量决定容器宽度；剩余按钮不被拉伸。焦段槽宽仍按完整目录计算。只对局部内容/容器变化做动画，沿用弹窗淡入淡出及减弱动态效果短动画，顶部浮层不推动固定控件或HUD。

## 智拍显示身份稳定性（2026-11-02）

`SmartSubjectTracker.Target`分别记录像素确认`lastConfirmed`与高置信连续对象观测`lastObserved`。对象框满足连续性、置信度≥0.8、当前对象具有可用结构时更新显示观测，局部复核失败不再直接驱逐已跟住的目标。显示/身份按最后有效观测与确认时间维护，自动动作仍由`trackingVerified`和原对齐门限约束。真正失去系统跟踪时使用有界宽限，越界/异常跳框拒绝，最后有效状态1.2秒后释放；批次冷却维持原0.8秒。

`SmartSubjectAppearance`以12×12灰度结构补充原11×11固定局部模板，只有高置信连续对象框与整体相关性≥0.90时可作为独立确认。辅助整体参考仅在原固定局部模板连续两帧证实时低频刷新，不逐帧学习预测位置。`SmartCompositionGuideOverlay.smartVisiblePoints`统一组合/去重后用一个ForEach显示所有候选，主候选切换不再将白点移入另一分支。

未对齐预AF获取状态及其额外请求已移除；对齐后的`finishAutomaticSmartFraming`、单次AF保持及取消恢复保留。候选提名/推荐范围未采用本轮尝试的结构质量门限；AI语义接口保持原实现，运行时仍需模型可用与vision能力检查。验证和局限见[专项记录](Test-Reports/2026-11-02-Smart-Point-Stability.md)。
# 2026-11-06 A挡微距路由更新

A挡预览沿用系统虚拟多摄，不再由macroActive预切物理输入，也不在快门中替换输入。可用时通过AVCapturePhotoSettings的virtualDeviceConstituentPhotoDeliveryEnabledDevices只请求超广角照片，并按sourceDeviceType接收；手选0.5×沿用原路线。近距两张输入保持与远景倍率往返已定向验证，连续近远自然退出及所有格式尚未完整验收。此前物理输入保持方案不代表当前A挡产品路径。

