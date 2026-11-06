# 相机风格与参考色表

徕卡 M9 采用用户提供的 m9.png 色表。原图保存在 Docs/Filter-References/m9.png，SHA256 ca90daba0fd7075a4997f34a1492ceca1cfbd7f91e92664f96fc15f358b20f8e。该文件为用户提供的参考滤镜，不宣称由徕卡官方提供或等同于 M9 传感器成像。

原色表为 512×512 sRGB RGBA PNG：8×8 蓝色切片，每片 64×64，红色沿片内横向递增，绿色沿片内纵向递增。蓝色切片按从左到右、从上到下排列。离线转换为 64³ RGBA Float32 小端数据，索引依次红最快、绿其次、蓝最慢，总计 4194304 字节。构建时作为 FilmLUT-M9 数据资源打包，运行中仅解包一次并缓存；CIColorCubeWithColorSpace 明确 sRGB 色彩空间，统一用于缩略图、实时预览与处理照片，不再叠加原 M9 模拟曲线。原片、已有滤镜及曝光/白平衡代码未改动。

复现转换（需 Pillow）：

```sh
python3 Scripts/convert_tiled_lut.py Docs/Filter-References/m9.png LumaCamera/Resources/Assets.xcassets/FilmLUT-M9.dataset
```

LUT 支持外推，保持图像边界及输入透明度。当前强度调节与旧混合逻辑保留，按用户要求不进行新设计。直接保存的 RAW 数据不烘焙滤镜；处理预览和 RAW 转 HEIF 使用统一色表处理路径。

富士 NC 按用户指定的 Classic Neg. 经典负片解释，CC 为 Classic Chrome。目前为模拟配方，等待各自原始色表替换；不将此前待确认的 Provia 色表用于这些风格。

参考方向：
- https://www.fujifilm-x.com/global/products/film-simulation/classic-neg/
- https://www.fujifilm-x.com/global/products/film-simulation/classic-chrome/

验证：FilmColorLUTTests 在软件和 GPU 渲染器核对原 PNG 的黑、白、RGB、灰阶、肤色、绿叶、蓝色样本，允许最多 2/255 渲染量化差。既有全部滤镜端点、透明度、混合、最新帧、全部画幅成片裁切测试通过。这里只证明参考色表映射和共用处理正确，不承诺不同相机采集管线下逐像素相同。
