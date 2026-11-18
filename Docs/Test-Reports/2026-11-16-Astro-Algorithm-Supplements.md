# 星空算法四项补充（2026-11-16）

## 实现范围

1. **采样与时长**：使用源帧 PTS 分配固定时间窗口，重复/倒退/无效时间戳不计入；掉帧后收尾已有部分组，不按收到多少帧推算录制时长。融合时长不超过实际采样间隔：调长融合会提高间隔，主动选较短间隔会相应缩短融合，顶部显示实际值。有限录制从首个有效源帧开始计时，另有真实时间截止任务；输出按窗口序号写入30fps时间轴。写入背压只保留一个待写组，不覆盖它或堆积捕获池。手动和有限时长结束均保留至少一帧的有效短片，零帧丢弃；停止最多异步等待2秒排空待写组，超过时保留已写有效部分。取消、退出取消旧任务，封装回调核对拍摄代次。
2. **天空与地景**：增加图像特征估计的软天空蒙版，支持四个传感器方向；天空需要多星点支持，低置信度不强制地景配准。地景先用 Vision 平移，明显越界时使用有界亚像素搜索；ROI先归零再缩放。星空照片在地景稳定后独立旋转/平移天空；星轨只稳定地景，保留星体移动。延时整段稳定地景，仅在每个融合组内部配准星点，保留组间自然运动。羽化地平线的亮边不参与星点匹配。统计/参考代理有界，原照片变换与融合维持线性浮点，参考缓存使用RGBAh。
3. **质量与降噪**：加入噪声/细节评分，拒绝相对明显模糊帧；照片和延时组前几个样本可替换较弱参考。配准后约束无参考支持的正向异常值；降噪强度随噪声与ISO调整，保护紧凑星点及地景。生产路径不再将低百分位估计当作暗场扣除，不再无条件全图中值删孤立点；背景只减弱天空的大尺度梯度。星轨不叠加第二次固定空间降噪。保存有效融合帧数。
4. **轨迹与时序**：按天空中新出现的细长残差抑制瞬态亮轨；星轨从多星位移和源帧间隔估计方向，只沿有依据的方向连接短缺口，地景不补缝。延时按已编码组做有界曝光和红/蓝比例平滑，减轻帧间闪烁。

## 官方依据与应用策略

- Apple [CMSampleBufferGetPresentationTimeStamp](https://developer.apple.com/documentation/coremedia/cmsamplebuffergetpresentationtimestamp(_:))提供源样本时间戳。窗口分配、掉帧处理和有限时长截止为本项目策略。
- Apple [VNTranslationalImageRegistrationRequest](https://developer.apple.com/documentation/vision/vntranslationalimageregistrationrequest)用于两图平移配准。重复纹理的越界结果是本次合成图测试的实际观测，有界搜索和5%位移门限为本项目补充，不是系统保证。
- CI软蒙版混合与RGBAh缓存用于处理链；天空估计、质量阈值、运动估计和轨迹几何筛选均为本项目算法，不将其写成Apple语义识别能力。

## 验证

设备：iPhone 17 Pro（iPhone18,1），iOS27.2.1（24B156），Xcode27.2（27B52）。最终真机集成35项执行，34通过、1项交互后台用例跳过、0失败，243.454秒。诊断不写系统相册。

| 项目 | 实际结果与样本 |
| --- | --- |
| 有限延时 | 5秒间隔/2秒融合/1分钟，首个有效源帧到截止60.290秒；按开始到截止67.143秒，包含曝光准备（n=1）。12个实际编码帧全部解码，PTS为0…11/30，严格递增；4次快速取消后重新拍摄通过 |
| 时间调度 | 1000条序列/30000个源时间点，CPU调度合计6.44ms；融合30秒/请求间隔5秒归一为30秒，掉帧、越窗、重复/倒退/NaN、部分窗口收尾通过。该指标不是画面FPS |
| 天空/地景 | 独立位移、旋转蒙版、非零ROI、地平线亮边排除和HDR星点通过；地景平移(-5,+2.85)，天空另校正约(-4,+0.055)。重复构造/配准8次512×512合计3.499秒，为蒙版及配准计算/图构建，不是显示FPS或12MP吞吐 |
| 噪声与细星 | 固定随机种子线性噪声图，64×64区域MSE从3.37718e-5降至3.18998e-6（下降90.55%）；HDR星值由3保留为2.736。另测单像素星点、参考支持与无支持异常值、坏帧/早期参考替换、地景保护。仅代表该合成输入 |
| 图像处理性能 | 256×256，12次统计+降噪+GPU成图合计232.63ms，平均19.39ms；不是全分辨率帧率，也不是App内存指标 |
| 时序与轨迹 | 20帧交替曝光平滑且保留HDR；新增长亮线抑制、点星保护；12个移动星图估计方向后仅沿运动补2像素短缺口，地景与垂直方向不膨胀，无运动依据不补缝 |
| 硬件采集/文件 | 实际2帧4032×3024 RAW、星轨、3帧2160×3840延时、返回普通视频37帧解码；自动ISO/EV三次、实际文件快门/ISO/6.765mm物理焦距/24mm等效焦距核对通过 |
| 预览/切换稳定性 | 8种画幅16次往返，会话停止0次、无超时；进入1.295—1.670秒(n=8)，返回1.346—1.656秒(n=8)，为请求至交接清理而非显示帧率；另3次快速退出、8次零帧停止后继续拍摄通过 |
| 曝光恢复 | 90次待机刷新、93次采集中刷新、3次暂停恢复、9次镜头切换通过；待机实际1/15秒，采集实际0.5/1秒；13次启动/恢复0.710—2.065秒（20ms轮询，非FPS） |
| 恢复存储 | 实际延时文件冷加载、原子图像检查点、模拟后台过期、部分分段MOV不重编码恢复通过。需要人工返回主屏的实际后台用例本轮跳过；此前共享会话版实际后台通过不能记成本轮再测 |

证据：`/tmp/LumaAstroAlgorithmsFinal.xcresult`、`/tmp/LumaAstroAlgorithmsFinal.log`。测试包含AstroAlgorithmPipelinePhysicalTests、AstroCaptureTimelineTests、AstroFiveFixesPhysicalTests、两项AstroModeHandoffPhysicalTests、AstroPreviewExposurePhysicalTests、AstroRecoveryTests、AstroSceneRegistrationTests、AstroSignalProcessingTests、AstroStarRegistrationTests、AstroTemporalMedianTests及AstroTimelapseStopPolicyTests。最终Release构建通过（`/tmp/LumaAstroAlgorithmsReleaseFinal.log`），已退出测试进程并重新启动普通App。临时结果包可能被系统清理，本报告保留关键指标。

复现入口（在主项目根目录、已连接解锁真机上运行，诊断模式不导入相册）：

```sh
xcodebuild test -project LumaCamera.xcodeproj -scheme LumaCamera \
  -destination 'id=00008150-001934280220401C' -parallel-testing-enabled NO \
  -only-testing:LumaCameraTests/AstroAlgorithmPipelinePhysicalTests \
  -only-testing:LumaCameraTests/AstroCaptureTimelineTests \
  -only-testing:LumaCameraTests/AstroFiveFixesPhysicalTests \
  -only-testing:LumaCameraTests/AstroModeHandoffPhysicalTests/testVisiblePhotoVideoStarHandoffsAndRapidExit \
  -only-testing:LumaCameraTests/AstroModeHandoffPhysicalTests/testSharedSessionCapturesRawTrailsAndTimelapseThenRestoresNormal \
  -only-testing:LumaCameraTests/AstroPreviewExposurePhysicalTests \
  -only-testing:LumaCameraTests/AstroRecoveryTests \
  -only-testing:LumaCameraTests/AstroSceneRegistrationTests \
  -only-testing:LumaCameraTests/AstroSignalProcessingTests \
  -only-testing:LumaCameraTests/AstroStarRegistrationTests \
  -only-testing:LumaCameraTests/AstroTemporalMedianTests \
  -only-testing:LumaCameraTests/AstroTimelapseStopPolicyTests
```

实际后台交互用例需要单独设置测试环境并配合返回主屏，默认跳过，不计入34项通过。

## 剩余范围

- 天空蒙版是保守图像规则，未接入语义分割模型；树枝、复杂山脊、厚云、城市灯光与缺少星点的画面仍需实际星野样本校准。
- 细长瞬态轨筛选不是飞机/卫星分类器，也可能移除流星；固定坏像素仍需真实暗场或跨运动的传感器坏点标定。本轮不提供暗场/平场采集、RAW整组导出与重新堆栈入口。
- 方向补缝仅处理有可靠位移且较短的间断，不凭空补长时间缺失。时序平滑为软件有界调整，采集中硬件ISO仍锁定，未实现跨昼夜大范围自动曝光策略。
- 室内短采集与合成星点验证不等于真实银河、长时星轨画质验收；分钟/小时级真实星野、温升、耗电与剩余空间压力仍需外拍。环境页的光污染/云层数据仍未接入。
