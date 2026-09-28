# ITRP 与 Caustica 离线渲染对照 — 2026-09-20

## 范围和结论

- 实际参考目录：`F:/mygit/test/Caustica_n/shaders/itrp`；对照 Caustica 当前工作区 0.3.13。本文为源码研究，没有运行 ITRP 的游戏对照，也没有证明剩余白点的唯一原因。
- ITRP 的离线模式是在体素追踪、辐照度缓存和屏幕复用组成的混合光照上累积；Caustica 则在实际三角形场景中继续追踪多次 BSDF 反射/透射。两者计算的光照并不等价。
- 最有价值的差别在于怎样处理后续间接光，累积公式本身没有发现可直接替换的特殊降噪机制。水池专项改善不能代表普通反光房间、人工光源及复杂游戏场景收敛。
- 本地 `Lib/Settings.glsl:139` 默认注释了 `RENDERING_MODE`。下文“离线”指开启该选项后的代码分支，不能据此推断用户实际运行 ITRP 时的选项。
- 本次只记录研究结果；不改变传输、默认画质、版本或部署 JAR。

## 已核实的差异

| 环节 | ITRP 本地实现 | Caustica 当前实现 | 对比较的影响 |
| --- | --- | --- | --- |
| 离线平均 | `TAA.glsl:553`，历史与当前帧按 `1/renderFrames` 混合 | `shaders/display/offline_accumulate.comp:21`，FP32 按样本数加权平均 | 没有发现应靠移植平均公式解决的差别 |
| 后续漫反射 | 命中后使用局部发光、直接日光和辐照度缓存 | 每次命中继续采样 BSDF、追踪实际路径 | 缓存复用减少重复估计，但改变间接光近似 |
| 后续反射 | 体素命中着色、缓存、屏幕颜色复用及天空近似 | 普通 PBR 表面可继续形成多次光泽反射链 | 不能要求两者在相同“样本数”下噪声一致 |
| 光泽方向 | GGX VNDF 随机域裁剪，常见 `clip=0.75` | VNDF、BRDF 和混合 PDF 配套计算路径权重 | 不能只复制裁剪参数而保留原 PDF |
| 稳定离线滤波 | 漫反射/反射的多项时间及空间滤波跳过；缓存仍参与 | FP32 累积完成后跳过 DLSS-RR | ITRP 有降噪文件不等于离线仍执行那些滤波 |
| 法线/起点 | 保留顶点与着色法线，多个追踪入口沿顶点法线偏移 | 普通材质会覆盖法线，后续起点使用该法线和固定偏移 | 是另一个应独立验证的正确性问题 |

## 1. 累积、精度与样本数

- ITRP `composite17.fsh:7` 包含 `Lib/Programs/Composite/TAA.glsl`。开启 TAA 和离线平均模式后，稳定帧执行 `mix(prevColor, currColor, 1.0 / renderFrames)`；下界尚未进入离线累积时走普通重投影。
- `RENDERING_MODE_ACCUM_TYPE=0` 是平均；值 1 执行 `max(prevColor,currColor)`，会保留峰值，不能作为消除白点的办法。对应中文标签见 `lang/zh_CN.lang:899`。
- `composite30.fsh` 的 `PROGRAM_FINAL_0` 才在 `Lib/Programs/Final_FS.glsl:543` 做曝光和色调映射，晚于 composite17。常规离线路径是 HDR 颜色先平均，再映射显示；不是先压白每个样本再平均。
- `Lib/Programs/Composite/Soild_FS.glsl:18` 的渲染目标格式声明为离线历史指定 RGBA32F，当前光照目标指定 RGBA16F（声明位于光影包注释块中）；没有依据认为 ITRP 使用比我们更高精度的当前样本。实际驱动资源未检查。
- Caustica 当前输入及历史都是 RGBA32F，平均后才写 RGBA16F 显示目标。`RtComposite.java:1053` 完成离线累积后，通过 `!offlineDone` 条件跳过 DLSS-RR。
- ITRP `PixelData_VS.glsl:80` 统计帧，最多 1000000；`DiffuseTracing_FS.glsl:114` 在累积启动后的前十帧之外启用默认每帧 20 次漫反射采样。`SpecularTracing_FS.glsl:104` 仅调用一次该反射追踪，没有相同的 20 次循环。不能把“帧数 × 20”解释为每像素完整多反弹路径数。

## 2. 辐照度缓存替代了大量后续路径计算

- `Lib/Settings.glsl:118` 默认 128³ 缓存、每次 1 个采样、历史混合参数 0.99；`shaders.properties:34` 以 `PT_IRC` 启用 deferred2，`deferred2.csh:7` 包含 IRC_CS。没有发现开启离线就关闭此缓存的条件。
- `Lib/Programs/Composite/DiffuseTracing_FS.glsl:496`：普通体素命中后加入发光；501 行加入 `SampleIrradianceCache(hitVoxelPos) * hitSurface`；之后用 `SimpleShadow` 计算直接日光。不是从这个普通表面重新采样完整混合 BSDF、一直追到最终光源。
- `Lib/Programs/Composite/IRC_CS.glsl:460`：新缓存采样在命中位置读取前一帧缓存，传播更深的间接光；554–560 行再与本位置历史混合。稳定时间且约 60 FPS 时，默认约 99% 历史、1% 新估计。
- IRC 中的 `*100` 和读取时的 `*0.01` 是配套储存尺度，不能误读为把间接光压低 100 倍。自反弹衰减、非半球采样权重等是另外的近似。
- `Lib/PathTracing/Tracer/SampleIRC.glsl` 的 `SampleIrradianceCache_Full_Smooth` 还进行邻域加权。缓存时间复用与空间平滑在离线图像滤波旁路后仍有意义。
- 这些行为足以说明 ITRP 不承担与当前完整路径相同的逐像素采样任务；但尚无同场景实验能量化各项对噪声的贡献。缓存也可能产生细节损失、漏光和更新滞后。

## 3. 反射路径与随机域裁剪

- `Lib/PathTracing/Tracer/SpecularTracer.glsl:243` 尝试将体素命中投回屏幕，深度及法线匹配后读取已有 colortex1 颜色；276 行默认读取平滑辐照度缓存。后续将局部日光、缓存、发光和屏幕颜色组合。
- 此普通命中分支不会像 Caustica 那样在每个反光方块重新采样 GGX 并递归继续。透明穿行、其他水体分支和屏幕中已包含的照明仍存在，不能概括成“只有一次交互”或“完全没有间接反射”。
- `Lib/Settings.glsl:104` 默认开启屏幕复用，105 行开启反射缓存平滑，109 行 SSR 模式为 2；天空缺失部分另有近似天空和解析高光。它们的光源模型、遮挡和反射能量不能与 Caustica 的有限天体发光盘直接等同。
- `SpecularTracer.glsl:80`、82 行传入 `clip=0.75`（手部还会更低）；`Lib/Utilities.glsl:519` 的实际启用分支执行 `noise.y *= clip`，缩小随机域后构造可见微表面法线。
- 这改变了采样分布；不是“剔除最亮的 25% 样本”。函数没有输出与此裁剪匹配的 PDF；另一分支中的 `pdfWeight` 位于 `#if false` 下。
- Caustica `world.rgen.slang:1709` 使用 `BRDF * cos / previousBsdfPdf` 更新路径权重。只移植随机域裁剪会使现有采样与 PDF 不一致；且丢失支持域后，仅改归一化因子也不能恢复所有路径。

## 4. 不能把离线效果归功于实时降噪文件

- `shaders.properties:703`：离线且视点稳定时，`rtwDiscardRefresh` 为真。
- `DiffuseTemporal_FS.glsl:44` 和 `DiffuseSpatial_0..7_FS.glsl:24` 在该条件下 discard；`DiffuseVariance_FS.glsl:31` 返回当前颜色。
- `SpecularTemporal_FS.glsl:26` 和空间滤波 1/2 同样跳过；`SpecularSpatial_0_FS.glsl:26` 直接透传。
- 因而“把 ITRP 实时降噪器搬过来就等于其离线效果”不成立。缓存提供的平滑光照，与最终图像降噪是不同环节。

## 5. 法线差异值得独立审计

- ITRP `SpecularTracing_FS.glsl:102` 沿 `vertexNormal` 偏移；`SpecularTracer.glsl:75` 对平滑反射检查几何半球。`DiffuseTracing_FS.glsl:134` 对落入错误几何半球的方向重新生成。它也使用经验修正，不能当作无偏标准直接移植。
- Caustica 普通命中阶段把贴图法线写回 payload；`world.rgen.slang:1541` 用 `hitPos + n * SURF_BIAS`，常量为 0.005。此前已有水面邻接处偏移跨界的实际证据，但普通反光房间是否由此产生亮点尚未验证。
- 应保留几何法线用于界面侧别/发射起点，以着色法线计算材质，检查两者半球及采样一致性。不能简单把偏移常量调大，也不能随意镜像样本却沿用原 PDF。
- 参考：[PBRT 浮点误差与光线起点](https://www.pbr-book.org/4ed/Shapes/Managing_Rounding_Error)、[PBRT 着色法线的几何不一致](https://pbr-book.org/3ed-2018/Materials/BSDFs)。

## 从比较得到的下一步

1. 正确性线：用现有通用路径日志核对反光房间的高贡献来源；优先检查几何法线、起点跨界和错误半球。不把减少噪点当成证明原路径正确。
2. 方差线：最适合先做小范围 A/B 的是“间接路径正则化”。保留相机直接看到的材质及纯镜面链，在发生非镜面散射之后，对后续尖锐普通 PBR 反射适度增加粗糙度。光照评估、采样、PDF 和 MIS 必须使用同一调整后的参数。
3. 该办法是有偏的降方差选项，可能改变间接高光和焦散；它不是 ITRP 裁剪代码的逐行移植。水/玻璃当前使用专门的理想界面分支，单改普通材质粗糙度不会自动覆盖它们，不能预先宣称解决水体白点。
4. 中期才考虑缓存：直接把后续辐射换成缓存是更大的画质/架构取舍。若希望保留原光照目标，可研究以缓存指导采样，并保留原 BSDF 支持和匹配 PDF；不能把一个已平滑的照明值直接加进原估计器而不处理重复贡献。
5. 原始累积保留作基线；对照必须同时包含低角度水池、开顶反光房间、无水玻璃的人工光源室内和原游戏暗场景。固定分辨率、相机、曝光、时间、反弹数，比较等样本与等时间的噪声、平均亮度、反射细节及耗时。既不能只看 17/18/21，也不能只凭白点数量宣告收敛。

[PBRT 路径正则化](https://pbr-book.org/4ed/Light_Transport_I_Surface_Reflection/A_Better_Path_Tracer#PathRegularization)说明：小而亮的光源经光滑表面形成的间接路径会产生方差尖峰；在非镜面散射后调整后续 BSDF 能降低这类误差。它支持上述实验方向，不能替代当前场景的根因证据。

用户观察到“先很少，后来冒出新白点”与罕见高贡献样本进入平均相容。例如旧均值为 1，之后在第 7000 个样本出现贡献 100000，则新均值约为 15.29；样本数多并不保证每一步都更平滑。此例只是解释机制，不是测得的房间路径，也不能排除错误权重或几何问题。

## 验证边界

- 已逐项核对上述本地源码分支、调用入口、默认开关及 Caustica 对应路径，并查阅 PBRT 原始技术资料。
- 未运行 ITRP、未做同场景计时/图像误差测试、未新增渲染实验实现。当前证据支持调整研究范围，不支持承诺下一版彻底消除白点。
