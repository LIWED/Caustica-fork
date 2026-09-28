# 暗场离线噪点诊断

适用：0.3.4 起提供的离线贡献视图；当前复测版本为 0.3.17。贡献视图用于定位，不是降噪器；新增可选平滑实验见文末。

## 已知现象与验证范围

- 用户观察：光线很少时，不同光源、不同方块都可能出现持续亮点。
- 已复现并修正：GGX D/G1 标量公式偏离标准分布。
- 用户已提供 0.3.4/0.3.5 游戏截图并报告持续亮点；两版均未通过画质验收。本任务尚未自行执行该场景的 GPU 复现。
- FP32 trace/history 与样本索引在源码中已接通；CPU/源码测试不等于实际 GPU 图像验证。

## 如何比较

1. 使用同一暗场、同一机位、同一资源包和离线反弹次数。
2. 视频设置中把曝光模式改为手动，并保持同一个曝光 EV；不要让自动曝光把不同来源都拉到相似亮度。
3. 开启离线渲染，相机静止后等待 HUD 样本数持续增长。
4. 先用“调试视图：关闭”记录 1500、3000、6000 样本的画面。
5. 逐一切换下表视图，每次等到相同样本数再比较。切换视图应清零并重新累积。
6. 测试结束把调试视图恢复为关闭。

| 编号 | 贡献 | 亮点出现时优先检查 |
|---|---|---|
| 8 | 方块直接光 | 静态光源选择概率、遮挡、BRDF 与 NEE PDF |
| 9 | 发光表面命中 | 发光材质、BSDF 命中权重、未登记光源 |
| 10 | 天体直接光 | 太阳/月亮 NEE、SSS 和水焦散调制 |
| 11 | 天空命中 | 大气、星空；0.3.5 次级射线还包含经 MIS 加权的解析天体光，直接看天空仍是装饰日月盘 |
| 12 | bounce>0 贡献 | 经至少一次表面继续追踪后取得的贡献；判断问题是否集中于更深路径 |
| 13 | 基础天空 | 次级大气/星空；直接看天空仍包含装饰日月盘 |
| 14 | 解析天体命中 | 次级路径最终命中用于照明的太阳/月亮 |
| 15 | 天体路径曾直穿玻璃 | 14 中历史包含玻璃透射的部分 |
| 16 | 天体路径曾反射于玻璃 | 14 中历史包含玻璃反射的部分 |
| 17 | 天体路径曾折射于水 | 14 中历史包含水折射的部分 |
| 18 | 天体路径曾反射于水 | 14 中历史包含水反射的部分 |
| 19 | 最后允许反弹的天体直接光 | 10 中 bounce==maxBounces 的直接光/SSS部分 |
| 20 | 水天体光，末段受保护 | 曾经水反射或折射，最后普通散射后的方向受到水引导提前终止保护 |
| 21 | 水天体光，末段未受保护 | 曾经水反射或折射，但末段不具有上述保护，包括仅镜面链或不适用引导的方向 |

8–11 按来源分类；12 与前四项重叠，不可一起相加。
0.3.6 的 11=13+14（在线性贡献域）；15–18 是 14 的历史筛选，混合路径可能同时出现在多个视图，不能相加。
玻璃、水后的贡献仍归到最终光源来源；12 不等于独立的玻璃/水视图。
对于有限贡献、忽略浮点舍入时，8–11 在线性辐射域形成分解；经过曝光和色调映射后的截图不能直接相加验证。
非有限值仍遵循既有帧级清理：某类 NaN/Inf 可能使默认整帧通道清零，而排除它的视图仍有限，不能用分类加和证明没有污染。

## 比较边界

- 贡献视图只在真正离线累积时生效；移动或等待冻结时显示正常实时画面。
- 路径依旧执行全部采样和可见性计算，过滤只作用于计入画面的贡献。
- 相同场景、输入和样本索引下保持相同随机序列；重新冻结时天空、水波可能变化，跨视图比较应选静态场景或固定这些设置。
- 当前没有 GPU 最大亮度计数/异步读回，也没有 EXR 分层导出，不能从 CPU 帧统计推断高亮样本数。
- GGX 修复恢复了此前错误压低的高光；它可能让已有天体采样问题更明显，不承诺减少所有场景的亮点。

## 回报最少信息

请记录样本数、反弹次数、曝光 EV，以及亮点主要出现在哪个贡献视图。
若 HUD 样本不断清零，应先定位累积重置；若样本持续增长，再检查对应光照来源。
确认运行版本与本次复测包一致，避免把旧包现象用于评价新源码。

## 0.3.5 的复测重点

- 沿用原暗场、8次反弹、手动 +0.4 EV，提供“源”、10、11、12在1500/3000/6000样本的对照。
- MIS把部分天体贡献从10分配到11；10变干净但源/12仍差，不算通过。
- 离线反射/折射中的日月采用照明角尺寸与亮度，可能比旧装饰盘更小、更亮。
- 玻璃、水不再让离线天体直线阴影穿透，改由真实的反射/折射路径承载；透射焦散可能仍有高方差。
- 同时检查整体照度、玻璃/水后的可见度、镜面日月、夜间月光和掠射角材质，不只比较亮点数量。

## 0.3.5 复测失败后的边界

- 用户新增 `035_10/11/12.png`，报告 10000+ 样本仍产生新亮点。当前 11 混合基础天空、解析天体和不同材质路径，不能据此单独判定哪条路径出错。
- 需增加材质输入/白炉验证及路径亮度尾部记录；不是继续要求更多 SPP 就能完成归因。
- 研究与后续顺序：`docs/superpowers/specs/2026-09-10-firefly-path-reassessment.md`。

## 0.3.6 的复测顺序

- 先记录“源”、14、19，保持原场景、8次反弹、手动+0.4EV，建议同机位1500/6000SPP并记录耗时。
- 如果14仍有亮点，再看15–18；如果11有亮点而14没有，再看13。这些视图不会改变光路采样。
- 玻璃直通天体光已恢复配对采样；水折射仍靠继续路径。新包不承诺复杂焦散亮点全部消失。
- 检查整体亮度、掠射材质和远处花纹玻璃：能量约束会改变部分暗部，高频玻璃固定LOD0可能增加锯齿。
- 尚无单条GPU路径导出和最大样本亮度读回，本轮提供的是贡献分层，不能由此直接统计HDR亮度尾部。

## 水池对照证据 — 2026-09-14

- 用户报告空池没有亮点（未附空池截图）；只加水后，源画面阳光照到的池内区域出现大量亮点，左侧未直射区域没有明显白点。不能将此局部复现外推为所有历史暗场亮点的唯一原因。
- 源图：`2026-09-14_20.59.18.png`，未显示样本数；17号：`2026-09-14_21.06.18.png`，HUD为2083SPP；18号：`2026-09-14_21.05.07.png`，HUD为4141SPP。均来自用户提供的 `E:/Minecraft/.minecraft/versions/caustica_test/screenshots/`。
- 17号散点分布在池内；18号可见散点更贴近池边轮廓。样本数不同，不比较两者强弱；它们是“曾折射/曾反射”的重叠集合，不能据此认定两个独立故障，也不能从18号推断反射发生在相机首次命中的水面。
- 代码确认：`celestialVisibility` 的离线连接只穿薄玻璃，遇水返回零；水反射/折射分支将天体MIS状态重置为delta，后续直接逃逸命中太阳时权重为1。现有直连策略不能覆盖池底经水折射连接太阳的路径。
- 与观察相符的候选路径（从相机向外）：相机→水面折射→池底散射→水面折射→太阳。它说明为什么加水后照明需要罕见随机命中；不是从截图恢复出的单条GPU路径。包含水面反射和池壁再散射的路径可同时进入17/18。
- 当前权重1不能直接改小：在没有竞争采样策略时压低它会漏掉太阳能量。将阴影射线直接放行穿水也不等价于折射连接。
- 后续实现优先针对平面水界面的显式折射天体连接，校验Snell方向、角度PDF变换、Fresnel/吸收、遮挡、介质状态、剩余反弹预算与配对MIS；反射链另行验证。当前水折射采用几何法线，波浪只影响反射/Fresnel，不能把平面测试通过等同于波浪焦散已正确。
- 接受标准：水池源图在相同曝光/太阳/机位下亮点减少且平均照度保持，空池不退化，再回测城市和暗场。只使17/18变黑不算通过；新增连接可能把贡献移到10号。
- 技术参考：[PBRT 的困难镜面路径与方差](https://pbr-book.org/4ed/Light_Transport_I_Surface_Reflection/A_Better_Path_Tracer)、[MNEE 折射界面连接](https://onlinelibrary.wiley.com/doi/full/10.1111/cgf.12681)、[Specular Manifold Sampling](https://rgl.epfl.ch/publications/Zeltner2020Specular)。本次仅记录证据和核对源码，未改渲染代码或完成GPU修复验证。

## 0.3.7 水池复测

- 实现采用折射方向引导继续路径，未增加独立NEE项。水下普通表面以50%概率尝试折射后的天体方向、50%保留原材质采样，统一使用混合概率计算权重。水面反射/折射、遮挡、吸收仍由实际追踪完成。
- 引导角范围比真实天体大5%，只为避开浮点边缘误差，不放大太阳或改变其照度；太阳接近地平线时回退原采样。镜头直接看到的水面镜面反射不属于这次水下表面引导。
- 17/18仍按路径历史归类，目标贡献继续留在14/17/18，可能从孤立白点变成连续的池底照明；不能以这些视图是否全黑作为验收标准。
- 保留已有空池/水池机位、材质、太阳、水波和曝光。先比较源图500/2000SPP与旧版相同SPP，记录耗时和整体亮度；仍有明显白点再看17/18。源图正常后回测城市和原暗场。
- 自动测试含六组太阳高度/半遮挡照度、实际折射浮点边缘、概率归一化、PBR/漫反射混合密度和提前终止补偿；不替代游戏验收。性能和剩余镜面链亮点仍待测。

## 0.3.8：残留路径与提前终止

- 0.3.7未通过用户验收：反馈源画面白点“差不多”；`2026-09-15_19.16.39.png`及`19.18.20.png`为17/18（按发送顺序），后者5078SPP，前者样本数未知。图片来自既有screenshots目录；未据此进行同SPP像素差统计。
- 已复现的代码方差机制：普通材质分支恰好采到引导范围内的方向，仍可能被连续提前终止判定放大。0.3.8将其纳入保护；不降低太阳亮度、不裁剪样本。
- 20/21互斥，在线性域之和是17/18的并集，不是17+18。路径是否受保护与最后一次水事件是反射还是折射并不等价；受保护末段也可能带着更早路径产生的大权重。
- 同机位、同曝光和同SPP先看源图；若白点仍明显，提供20/21。21集中亮点时继续查未覆盖反射链/引导条件；20仍有尖点时查更早权重、实际水面法线及数值支持。两者均不能单独证明某条路径错误。
- 新测试保留旧策略的平均能量，验证两次提前终止放大被消除；不能因此宣称已定位全部截图亮点。GPU验收与性能仍待测。

## 0.3.9 actual-path logging

- Restart Minecraft after the automatic package replacement; use source view0 in the existing water pool. Keep camera/settings fixed and accumulate beyond256 samples until the bright points are visible. No new20/21 screenshots are required for this step.
- 0.3.12 additionally guides ordinary-surface→water-reflection and locally tilted water-exit directions using a bounded pilot. Compare source view at the same pool-rim camera/resolution/exposure/sun, e.g.500/2000/5000SPP, and note time. More paths may move from21 to20, so raw20/21 brightness is not a version-independent noise score. Real traversal/variance and added trace cost remain unverified until a game run.
- The instance automatically writes `logs/caustica-paths-YYYYMMDD-HHMMSS-SSS.jsonl`; `latest.log` reports its path. A session-only file means capture activated but no qualifying records have yet been written (or check `latest.log` for probe errors).
- Capture selects water-related analytic celestial hits whose single-sample magnitude is at least256, independent of selected diagnostic view. Up to32 records/dispatch,256/process and16MB. Restart to obtain a fresh capture budget when changing scenes.
- Paths are replayed with the same seed; their radiance is discarded and guide outputs restored. The recorded per-step max contribution permits checking the header source against replay. Actual GPU equivalence is pending; first-come capture may be dominated by normal water reflections and is not an unbiased tail-frequency measurement.
- `geometricNormal_material` contains the returned shading normal for normal-mapped ordinary surfaces and geometric normal for water. Water effective normal additionally shows wave perturbation. `survived=-1` means the step ended without a recorded continuation decision; terminal miss uses event6.
- This is a diagnostic build, not a claimed firefly fix. Probe collection can be disabled with JVM option `-Dcaustica.offline.pathProbe=false`.

## 0.3.13 general capture (supersedes the old water-only scope)

- Restart and begin with the problematic reflective room in source view0. Hold the camera/settings fixed past256SPP until dots are visible; no17/18/20/21 screenshot sequence is required. Logs are automatic in the existing instance logs directory.
- Capture includes direct surface lighting at any depth and secondary emissive/atmosphere/celestial contributions, with no water/glass requirement. Threshold32; primary directly visible source/sky pixels remain excluded. A single path records its largest eligible contribution, so this is not a complete or unbiased frequency measurement.
- Accumulation restart restores the256-record quota and increments `captureGeneration`. Lifetime2048 records and16MB still bound logging; restart Minecraft if exhausted. Discarded stale-generation results do not reuse GPU-owned buffers or consume the new run's quota.
- This release does not change transport or claim reduced noise. Findings and broader scene acceptance: `docs/OFFLINE_GENERAL_REASSESSMENT_2026-09-20.md`.

## 0.3.14 可选间接反射实验

- 重启后在视频设置选择“离线间接反射平滑 → 轻度（实验）”；默认关闭。源画面0下在原反光房间对比关闭/轻度的同样本、同机位结果，记录颗粒、亮度、反射细节与耗时。切换自动重置累积，无需依次截取所有编号。
- 首个可见材质粗糙度保留，但间接照明可能改变；较强档在 CPU 掠射角案例中有明显亮度损失。水/玻璃自身模型和几何偏移未修复，不能据此宣称所有白点解决。
- 日志世界 flags 的 bits7–8 记录模式；每步粗糙度仍记录原材质值，人工数学回放需按前序非 delta 散射和模式重新求有效粗糙度。详见 `docs/OFFLINE_REGULARIZATION_EXPERIMENT_2026-09-20.md`。

## 0.3.15 简短复测

- 新版本调整普通反射/漫反射采样分配，不增加平滑强度。重启后保持较强档以及相同场景、机位、时间、分辨率、曝光、反弹次数。现有匹配房间日志记录的是 24 次反弹。
- 只看源画面，在 500/2000/5000 样本记录画面与耗时；先判断趋势，无需再次立即跑到 30000，也无需遍历全部诊断编号。记录亮度与反射细节，不能只数白点。
- 关闭档也使用新采样。CPU 数值改善不代表游戏必然按同一比例加速；证据和边界见 `docs/OFFLINE_LOBE_SAMPLING_2026-09-20.md`。

## 0.3.16 降噪对照

- 默认开启“离线画面降噪”，只处理源画面。先在500–2000样本开关比较即可；开关本身不清空样本，也不改变原始累积或曝光统计。较强/轻度间接反射平滑是另一个选项，本轮保持原档位。
- 所有诊断编号仍未经降噪，编号中的白点不会因为该选项消失。验证源画面颗粒的同时检查小灯、反射细节和纹理是否被抹掉。
- 细节代价、日志与验证边界见 `docs/OFFLINE_DENOISE_2026-09-21.md`。

## 0.3.17 细节优先

- 0.3.16因严重细节损失未通过。新“离线自适应降噪（实验）”默认关闭，不继承旧降噪配置。原始累积和编号视图保留。
- 若开启对照，重点看细纹理、砖缝、镜中细节和小灯，而非只数白点。至少32累计帧后才有统计；同一次累积可以开关，无需各跑30000样本。说明见 `docs/OFFLINE_DETAIL_RECOVERY_2026-09-21.md`。
