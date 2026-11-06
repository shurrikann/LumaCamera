# 2026-10-27 HEIF Pro高动态首版

## 功能范围与官方基础

照片格式弹窗的HDR后加入高动态开关及说明，删去“裁切后实际像素会减少；灰色选项表示当前镜头不支持”，高度上限390→360点、内容间距16→12点。两开关独立；高动态默认关闭，跟随保存拍摄设置。首版只用于普通HEIF Pro，切到其他照片格式、水印或夜景/人像/慢门/连拍时关闭。没有改变A挡测光或M挡快门/ISO，没有新增应用多帧包围合成，也不实时显影相机预览。

官方基础：[ProRAW捕获及显影](https://developer.apple.com/videos/play/wwdc2021/10160/)、[HDR图片管线](https://developer.apple.com/videos/play/wwdc2023/10181/)、[RAW局部影调属性](https://developer.apple.com/documentation/coreimage/cirawfilter/localtonemapamount)、[HEIC编辑输出](https://developer.apple.com/documentation/photos/phcontenteditingoutput/renderedcontenturl(for:))、[编辑配方](https://developer.apple.com/documentation/photos/phadjustmentdata)。官方提供RAW/EDR/Photos机制；本应用的场景统计、曲线参数和组合策略为自定义方案，不声称与参考视频的专有算法相同。

基础显影保留EDR，使用官方RAW降噪及局部影调能力；最长边192点的线性浮点小图计算分位数/反差/暗部需求，GPU执行有黑位门控的暗部提升与平滑高光肩部。SDR高光压入显示范围，HDR保留大于1的亮度，处理后接影调/滤镜；HDR滤镜拆分颜色域和逐像素亮度余量再恢复。不是人物语义识别，不凭空恢复已丢失高光，不把所有阴影都提亮。

开启后HEIF同时附带原始DNG，显影配方进入HEIF EXIF UserComment，DNG字节不改。编辑曝光/色温/色调由RAW解码执行，之后再做高动态、影调和滤镜，不重复应用；右上菜单可改高动态、HDR和Pro影调，HDR预览使用16-bit浮点图。最终重新显影保留原像素预算，裁切输出整像素尺寸并更新EXIF，真实快门/ISO等不伪造。只分享HEIF而不带DNG时不能重新显影；详情按实际资源显示是否有底片。

## 真机验证

iPhone17 Pro、iOS27.2（24B119）、正常项目签名。12个不同方法有通过记录：新增高动态组4项、照片编辑元数据组3项、普通编辑组4项、既有Pro影调HDR组1项。均为定向检查；Photos写入禁用，不能把临时资源验证算成保存后重开相册已通过。

- 实际捕获：后置A/M、前置、HDR与SDR；M挡设置100 ISO/1⁄120秒，成片快门为0.0083333333秒。HEIF带DNG、配方、8/10-bit、HDR PQ色彩标记及方向1通过。EditorUI组前四张12MP回调耗时约2.338/1.700/3.526/1.306秒，含原生拍摄、解码、处理及编码，不能单独当算法耗时。另有第五张约12MP，不计48MP验收。
- 独立48MP：`48Inspect2`和`LastChecks`确认界面、PhotoOptions为48，原生请求8064×6048，RAW nativeSize8064×6048、解码输出6048×8064。实际输出48,000,000像素；同底片全尺寸重新显影保留输出尺寸，单次约2.709秒。不是48MP平均速度或长期热稳指标。
- 同底片重建：SDR在缩至64×64后比较成片与重新显影，RMSE为0；最后EditorUI轮HDR加入+0.5EV、色温12和电影影调后RMSE约0.001403。允许编码/颜色转换误差，不等于高光恢复量的测量。原DNG文件暂存前后字节一致。
- 显影预览：12次连续曝光调整，每次RAW小图解码并渲染约18–24ms；这是渲染调用耗时，不是屏幕FPS。真实编辑页16-bit HDR图、30次快速调整、取消后无迟到预览覆盖通过，截图已检查。
- 线性合成图：验证黑位、暗部提升、HDR高光大于1、SDR不同高光值保留次序和RGB比例；四种代表滤镜在HDR保护路径下高光仍分层。不是全部滤镜全部场景画质验收。
- GPU与统计：288万像素合成图，192点统计加GPU输出共6次，HDRFilterFinal约5.45–6.92ms，含实际CGImage渲染，不是快照绘制或实际显示帧率。
- 布局/稳定性：六格式×四控件方向共24组，HDR与高动态同排、后者位于HDR右侧、说明不超出360点弹窗；60次开关、离开相机关闭弹窗通过。最终相机弹窗和RAW编辑页已目视检查；无模拟器结果冒充真机。
- 普通编辑、真实信息保留、RAW编辑选原片后去掉旧滤镜标记、保存失败/退出后编辑状态释放通过。既有HEIF Pro四影调的SDR/HDR共8张回归通过，实际PQ与任务清空检查保留。

## 过程问题与未验收项

- 初次启动被手机锁屏阻断，用户解锁后继续。新增48MP测试辅助一度缺少AVFoundation导入导致编译失败，补导入后通过，非生产功能失败。
- 组合流程在切镜/格式回调尚未稳定时设置48MP，后续实际只交付约12MP；没有把它记作48MP成功。独立等待主摄M挡和格式稳定后，原生请求、DNG及最终文件均确认高分辨率。本次未修改全局切镜/规格恢复逻辑。
- 检查发现普通LUT可能截断HDR，已仅在新高动态路径加入余量保护并复查。RAW自由裁切使用整像素输出，EXIF尺寸与容器尺寸一致；不继承旧MakerNote偏移或旧色彩标记。
- **Photos中HEIF+DNG资产创建、覆盖/另存、iCloud下载及保存后重开编辑的完整回路未写入验收**。资源暂存、底片字节、配方、重新渲染和输出文件验证通过；不将其标成PhotoKit端到端通过。第三方/不理解的配方回退旧编辑分支以保留已有结果。
- 未逐项验收Live/人像/夜景/慢门/连拍组合，本版入口策略不开放这些合成路径。没有应用级长时功耗、内存峰值、持续热稳或其他设备/iOS18实测，也未完成各类逆光人物、窗景、夜景的主观画质标定。

结果包位于`/private/tmp/`，前缀`LumaCamera-AdaptiveDynamic-`：`Checks`、`Final`、`Resolution`、`HighResFinal`、`48Inspect2`、`LastChecks`、`MetadataFinal`、`FractionalCrop`、`HDRFilterFinal`、`EditorUI`，各有`.xcresult`和`.log`。机器指标见同名results.json。

正常 Debug 版本构建通过，已按项目签名安装并启动到 iPhone（安装序列1880）。
