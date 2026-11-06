# HDR 与微距阶段状态（2026-11-05 收尾）

## 结论先行

- **HDR + 滤镜产品路径已取消**：HDR 与滤镜互斥；有滤镜时开启 HDR 自动回退原片；HDR 开启后滤镜入口禁用。
- **HDR 预览改为 SDR**，预览右上角显示 HDR 标识；HDR 只在成片中生效。
- **成片重新走官方 Core Image 写入路径**：系统 HDR 拍摄数据 → SDR 基底 + 全分辨率增益图；不再使用“系统直存弱增益图”的快速路径。
- **微距对焦已改善**：物理超广角/虚拟多摄 constituent + 主动 AF + 锁焦；微距超广角补 +0.5EV。
- **已修复候选**：微距改为始终切物理超广角并保持输入，macroActive 期间续期；连续日志确认第一张后不再切回主摄，待用户录屏复验。
- **仍未达到对方 App**：成片速度约 2.8 秒、HDR 观感仍略弱；对方微距 HDR 可快速连续拍摄。

## 这几天的主要改动

### 1. 滤镜浓度与 HDR 试验

尝试过：

- LUT 只作用于 SDR 基底，再补 HDR 高光
- HDR 域内混合浓度
- `hdrExpand` 软肩曲线、`hdrTintResidual` 高光染色
- Metal `CAMetalLayer` HDR 预览原型
- HDR 与滤镜互斥/自动回退原片
- HDR 滤镜实验开关

结果：

- 预览/成片 headroom 和亮度反复不一致
- LUT 对高光截断、增益图降采样、系统显示映射差异叠加
- 最终决定取消 HDR + 滤镜产品路径

保留的相关代码：

- `Imaging.filteredHDR` / `hdrSoftShoulder` / `hdrTintResidual`（部分仅实验）
- `HDRMetalPreviewPrototype.swift`、`HDRFilterLabView.swift` 已删除（实验阶段结束）

### 2. 当前 HDR 成片路径

```text
系统 HDR 拍摄
→ CIImage .expandToHDR
→ PhotoEncoder
→ HDR 主图仅提升曝光（0.7EV 编码补偿）
→ SDR 基底保持原亮度
→ Display P3
→ CIContext.heifRepresentation
→ ISO 21496-1 + Apple HDRGainMap
```

真机结果：

```text
增益图：12,288,000 字节（全分辨率）
AlternateHeadroom：2.70
成片 headroom：6.50
成片耗时：约 2.8 秒
```

### 3. 微距

- 微距对焦：当前使用物理超广角（或虚拟 constituent）并主动 AF/锁焦；清晰度已通过真机近距成片确认。
- 超广角曝光：自动曝光时临时 +0.5EV，拍完恢复。
- 连续两张：用“最近微距 5 秒”让第二张仍走超广角；实测两张均为 2.22mm。
- 预览保持：第一张后系统会把虚拟多摄主 constituent 切回主摄；目前第二张成片可保持微距，但预览仍可能切回主摄。

## 文件实测对比

### 对方 App 微距 HDR

```text
3024 × 4032
2.22mm 超广角
Display P3
增益图约 12MB（全分辨率）
AlternateHeadroom：1.70
HDR 解码 headroom：3.25
HDR 平均：0.83
最大亮度：2.78
```

### 光屿快速直存（已废弃）

```text
增益图约 3MB（降采样）
AlternateHeadroom：1.32
HDR 平均：0.49
headroom：2.86
```

### 光屿当前官方重编码

```text
增益图 12,288,000 字节
AlternateHeadroom：2.70
HDR 平均：0.60–0.80（微距 +0.5EV 后）
headroom：6.50
成片约 2.8 秒
```

## 已验证

- 滤镜下开 HDR 自动回退原片、HDR 下滤镜禁用。
- HDR 预览 SDR，右上角 HDR 标识。
- HDR 成片全分辨率增益图 + Apple HDRGainMap。
- 微距超广角对焦清晰。
- 微距 +0.5EV 后 HDR 平均接近 0.80。
- 连续两张均走 2.22mm 超广角（成片层面）。

相关测试：

- `testHDRSwitchesFilterToOriginalAndDisablesFilterEntry`
- `testHDRHEIFWritesGainMapWithSDRBase`
- `testHDRHEIFKeepsMidtonesAndConfinesGainToHighlightShoulder`
- `HDRCaptureDiagnosticsTests`
- `HDRSequentialDiagnosticsTests`
- `testHDRSuppressesFilterTemporarilyAndRestoresIt`
- `testJPEGDisablesHDRAndManualHDRRestoresFilter`（新增并通过）

## 未解决 / 风险

1. **预览镜头保持**
   - 已改为物理超广角输入保持；连续日志确认第一张后 input 仍为 UltraWide。
   - 仍需真实录屏确认构图无轻微变化。

2. **速度与效果仍落后对方**
   - 当前约 2.8 秒；对方可快速连续点击。
   - HDR 平均 0.60–0.80，对方 0.83。
   - 全分辨率增益图已恢复，但增益曲线/曝光/编码仍不同。

3. **HDR 直存与重编码的取舍**
   - 系统直存：约 2.3 秒，增益图降采样、效果弱。
   - 官方重编码：约 2.8 秒，全分辨率增益图、效果更好但仍非对方水平。

4. **历史实验代码**
   - `HDRFilterLabView` / `HDRMetalPreviewPrototype` 已删除。
   - `CapturePreferences.hdrFilterEnabled`、Metal live桥接和未使用的 `hdrResidual`/`hdrTintResidualV2` 已移除。
   - `filteredHDR`/`HDRToneMapping` 仍被正式 HDR 编码路径使用，不可按死代码删除。

5. **回归范围**
   - 未重新跑全量测试。
   - 未完成横竖、画幅、弹窗、长时间功耗、真实相册保存回路的全量验收。

## 如果继续

优先级建议：

1. 先解决“微距预览不切回主摄”，否则连续微距体验仍不完整。
2. 再统一/校准系统 HDR 增益曲线与 +0.5EV 曝光，目标接近对方 HDR 平均 0.83。
3. 最后再做速度优化；不要同时改镜头保持、增益图和快门队列。

## 当前原则

- 不再在未验证的情况下放开连续快门。
- 不再恢复 HDR + 滤镜产品路径。
- 微距 SDR 强制仅作为历史尝试，当前产品路径以系统 HDR + 官方重编码为准。
