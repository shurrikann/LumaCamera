# 2026-10-25 M挡手动参数恢复自动延迟

## 问题与处理

用户反馈M挡恢复自动后数字、刻度及画面都慢。后置主摄实测半秒手动曝光恢复AE约1.42秒，帧时长上限仍为0.5秒；其他参数大多约0.24秒才有下一次数字读数。原实现每0.4秒采样一次读数，且恢复HDR时设备仍处于旧长曝光custom。

- 照片退出自定义曝光时先切回continuousAutoExposure，再恢复视频HDR流策略，避免HDR重配置等待多个旧长曝光帧。清理照片手动曝光改变的activeVideoMin/MaxFrameDuration为invalid，回归格式默认；不更改录像帧率。
- 恢复曝光、白平衡/色调或对焦自动后，在锁保护的LivePreviewState增加读数刷新代次，下一可用帧立即采样；1.5秒内按最多每0.08秒采样，之后回到0.4秒。保持原延后一帧的主线程发布，并验证新代次以丢弃切换前排队的旧读数。
- 所有值仍来自AVCaptureDevice真实ISO、时长、白平衡增益及镜头位置，不预填估计的自动值，也不伪装相机已经完成收敛。没有增加强制对焦、固定切镜、重建相机或永久高频轮询。
- 拍摄中关闭辅助后的最终自动恢复也释放照片帧时长并刷新读数。静态捕获的参数快照、官方曝光完成等待、最终回调后恢复预览的既有路径保持。

## 真机结果

iPhone17Pro/iOS27.0.1，正常项目签名，无模拟器或镜像。主摄M挡，快门/ISO组先设ISO100、1/2秒；白平衡/色调先设2800K/tint30，对焦先设0.2。流畅预览关/开分别验收，共10个参数恢复样本（快门和ISO共享同一曝光硬件，WB和色调共享白平衡硬件）。未进行相同场景照度标定。

| 参数入口 | 流畅预览 | 确认硬件自动ms | 首次新读数发布ms | 截至此时确认有新预览ms |
| --- | --- | --- | --- | --- |
| shutter | 关 | 841.0 | 863.5 | 880.5 |
| iso | 关 | 851.8 | 878.4 | 885.4 |
| wb | 关 | 14.8 | 315.5 | 333.1 |
| tint | 关 | 9.0 | 27.6 | 37.2 |
| focus | 关 | 17.7 | 25.0 | 30.4 |
| shutter | 开 | 21.9 | 27.0 | 34.9 |
| iso | 开 | 19.2 | 47.9 | 54.7 |
| wb | 开 | 11.9 | 29.0 | 36.2 |
| tint | 开 | 5.3 | 39.2 | 49.9 |
| focus | 开 | 5.2 | 41.9 | 52.4 |

第三列是10ms轮询确认AVCaptureDevice已进入对应自动模式的耗时；不是最终AE/AWB/AF算法收敛。第四列是下一次@Published读数，可能仍包含硬件过渡值。最后一列在读数检查后确认预览时间戳已更新，是上界观测，不能当作首个自动曝光像素或屏幕显示延迟。未使用快照绘制耗时推断FPS。

- 基线无流畅预览的半秒曝光，硬件恢复约1.420/1.428秒；Final为0.841/0.852秒，帧时长上限由0.5秒回归当前格式默认约0.0667秒。当前曝光/硬件管线仍有等待，不能承诺长快门瞬时恢复。
- Baseline2白平衡/色调/对焦及开辅助后多数新读数约0.235–0.254秒；Final多数约0.025–0.048秒，一次白平衡约0.315秒仍受硬件/帧交付影响，不宣称每一项均稳定几十毫秒。
- 仅清理帧时长并加快读数的Fix轮，长曝光仍约1.4秒；进一步调整“退出custom→HDR恢复”的顺序后Order轮约0.837–0.843秒，Final复测相近，保留各轮数据。
- 快速20轮曝光/WB/对焦手动→自动后，最终三组硬件保持自动；退出/返回正常。快速回传窗口结束2秒后，1.2秒窗口只有3次读数，确认没有永久维持高频采样。
- Final四项47.789秒通过：新增恢复延迟用例11.442秒，慢门辅助7.908秒，普通流畅预览快速开关/拍摄中关闭17.728秒，照片/视频/生命周期10.711秒。回归核对ISO400/1/15秒JPG/HEIF真实文件EXIF，以及视频M挡ISO400/1/125秒仍有效；诊断照片/视频不写系统相册。真实会话运行错误审计通过。

## 验证边界与中间记录

第一轮测试代码await置于XCTUnwrap自动闭包导致构建失败，先取异步快照后修正；Baseline2、Fix、Order、Final均有通过记录，Fix只属于局部改进，未写成已解决全部延迟。日志仍有系统缓存MDB_MAP_FULL消息，未声称平台零警告。

未标定AE/AWB/AF最终收敛、强暗光、所有物理镜头/规格或目标AE/AF锁定组合；只验证自动模式指令、真实读数、预览继续发布与相关捕获恢复。未做独立App内存、功耗或长期热稳定性测试；安静窗口读数计数只证明采样频率会回落。没有改界面样式。

## 官方依据

- [Apple activeVideoMaxFrameDuration](https://developer.apple.com/documentation/avfoundation/avcapturedevice/activevideomaxframeduration?changes=_8)、[activeVideoMinFrameDuration](https://developer.apple.com/documentation/avfoundation/avcapturedevice/activevideominframeduration?changes=_2)：官方支持通过invalid回到当前格式默认帧时长，设置时需持有配置锁。
- [Apple activeMaxExposureDuration](https://developer.apple.com/documentation/avfoundation/avcapturedevice/activemaxexposureduration)：AE依据当前配置选择曝光上限；平台不保证所有环境相同收敛速度。此处0.08/1.5秒采样策略与操作顺序优化是项目实现和本机实测，不是苹果时间保证。

本地结果前缀`/private/tmp/LumaCamera-ManualAuto-20261025-`：Baseline、Baseline2、Fix、Order、Final。详情见[量化记录](2026-10-25-ManualAuto-Recovery-results.json)。

验证后普通App构建成功，已使用项目正常签名安装并启动 `com.shurrikann.LumaCamera`。
