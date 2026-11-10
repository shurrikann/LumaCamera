# 2026-11-10 Release 包体评估

## 构建

```text
xcodebuild Release, generic/platform=iOS, CODE_SIGNING_ALLOWED=NO
```

Release 编译曾因 `grainFrameCounter`、`histogramFrame` 被误放在 `#if DEBUG` 中而失败；已移到 Release 可见作用域，Release 构建通过。

## 体积

| 项目 | 大小 |
|---|---:|
| Release `.app` | 193 MB |
| 未签名 IPA（zip 估算） | 95 MB |
| 主二进制 | 21 MB |
| `Assets.car` | 93 MB |
| `LogLUTs` | 79 MB |

## 说明

- IPA 用 zip 压缩估算，不是 App Store 实际分发包；App Store 处理可能略有差异。
- 没有设备专属 asset variant，因此预计不会产生明显的 App Store thinning。
- `Assets.car` 包含 256 支照片滤镜资源（208 支 709 LUT 约 42MB + 其他图片/资源）。
- `LogLUTs` 为 110 支 LCUB：33³ 69支、65³ 41支；65³ 占主要体积。
- 总包体约 95MB 下载量，低于 200MB 蜂窝下载限制，但属于偏大应用。

## 可选优化

1. 65³ Log LUT 下采样到 33³：预计显著减少 LogLUTs 体积，需要视觉/色准回归。
2. Log LUT 只内置精选，其余按需导入。
3. 照片 709 LUT 保留精选，其余外部库导入。
4. 不建议再增加同类全量 LUT 到主包。
