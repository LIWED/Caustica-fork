# 离线渲染收敛与性能优化设计

## 目标

本阶段改善 Caustica 离线渲染在高渲染距离、少量室内光源和高 SPP 下的性能与画质：

- 渲染距离增大时，附近有效光源仍保持较高抽样概率；
- 6000+ SPP 不再受 32 相位主射线重复造成的稳定磨砂限制；
- 离线路径的 HDR 辐射值在进入累积历史前保持 FP32；
- 非有限值不能污染累积历史；
- 静态光源 NEE 与 BSDF 命中光源的 MIS 使用完全一致的概率；
- 帧统计可在离线模式正常开启。

本阶段不让 Minecraft 光源方块在实时模式生效，不加入降噪器，不复制同级付费光影包代码，也不执行 Git 暂存、提交或推送。

## 已确认根因

1. 当前每个普通材质交点都从整个驻留范围的全局 CDF 抽取一个光源。远处和被遮挡光源会稀释附近有效光源的概率。
2. 静态光源列表随场景版本整体重建，并在重建前等待 GPU 空闲；渲染距离越大，重建成本越高。
3. 路径追踪结果先写入 RGBA16F，再进入 RGBA32F 历史。极亮样本可能在进入历史前量化或溢出。
4. 一帧内全部 SPP 共用同一条主射线，跨帧又复用面向 DLSS 的 32 相位 Halton 抖动。
5. `frame.offlineAccumulate` 已被调用，但没有注册到帧统计阶段表。

## 光源选择

保留现有全局光源 CDF，并为每个已发布地形 section slot 建立一个邻域光源目录。

- 邻域采用 section 坐标的 Chebyshev 半径 2，即接收 section 周围 `5×5×5` 个 section。
- 有邻域光源时，以 `0.9` 概率选择邻域分支，以 `0.1` 概率选择全局分支。
- 没有邻域光源或接收点属于实体时，完全使用全局分支。
- 不按相机半径删除光源；全局分支保证每个已注册光源始终有非零概率。

GPU 新增两个紧凑缓冲：

```text
LocalLightDirectory[sectionSlot] = {
    uint referenceOffset;
    uint referenceCount;
    float totalWeight;
    float reserved;
}

LocalLightReference = {
    uint globalLightIndex;
    float cumulativeWeight;
}
```

邻域引用按全局光源编号升序写入。相同数组既可按累计权重二分抽样，也可按全局编号二分查询某盏灯是否属于邻域。

若光源 `i` 的全局权重为 `w_i`，全局总权重为 `W_g`，邻域总权重为 `W_l`，混合概率为 `a=0.9`，则：

```text
q_i = (1-a) * w_i / W_g
      + (i 属于邻域 ? a * w_i / W_l : 0)
```

点光源贡献除以 `q_i`。面积光源的立体角 PDF 为：

```text
pdf_light = q_i * distance² / (abs(cosLight) * area)
```

BSDF 路径命中发光三角形时，使用“上一接收表面的 section slot”重建同一个 `q_i`，再计算 reciprocal MIS。这样局部优化只降低方差，不改变期望亮度。

## 光源权重

面积光源基础权重继续使用 `area * emission`，但乘以 CPU 估算的可见 alpha 覆盖率。覆盖率使用现有 `SpriteContentsAccessor` 读取原始贴图，并按所有动画帧统计 alpha 大于等于 0.5 的比例。

- 没有 sprite 的流体发光三角形覆盖率为 1；
- 覆盖率为 0 的候选不进入光源表；
- LabPBR `_s` 的逐像素发光仍在 GPU 采样时解码，本阶段不在 CPU 复制材质贴图逻辑。

## 离线 FP32

实时模式保留 RGBA16F，避免增加正常游玩带宽。

构建系统从同一份 `world.rgen.slang` 额外编译离线 FP32 变体：

- `world_offline.rgen.spv`
- `world_offline_nv.rgen.spv`

离线变体将 binding 1 声明为 `rgba32f`。切换离线模式时，在已有的设备空闲/资源重建点选择对应 raygen 变体并创建 RGBA32F trace image。离线累积链路变为：

```text
RGBA32F trace -> RGBA32F history -> RGBA16F display resolve
```

resolved 图只用于显示，不反馈到历史。写入 trace image 前拒绝 NaN、Inf 和负辐射值。只有在确认 PDF/MIS 正确后才考虑可选的 firefly clamp；本阶段不默认引入有偏亮度裁剪。

## 离线样本序列

`WorldPush` 增加离线全局样本起点，来源为 `OfflineAccumulationState.Decision.previousSamples()`。

对每个像素和每个帧内 SPP：

- `globalSampleIndex = previousSamples + s`；
- 使用按像素哈希旋转的低差异二维序列生成独立 sub-pixel jitter；
- 为路径随机数使用 `(pixel, globalSampleIndex)` 派生的独立 seed；
- 每个 SPP 重新构造主射线，不再整帧共用一条主射线。

实时/DLSS 路径继续使用现有抖动协议。低差异主射线只在真正离线累积时启用。

## 性能统计与诊断

- 将 `frame.offlineAccumulate` 注册进 `RtFrameStats.FRAME`。
- 增加静态契约测试，确保所有 `RtFrameStats.FRAME.stage("...")` 名称均已注册。
- 光源快照记录全局光源数、局部引用数和局部目录地址，便于之后用 frame stats 对比渲染距离。
- 本阶段先保留场景变化时的全量重建；增量 section 发布属于后续优化，避免同时改变抽样正确性和生命周期。

## 版本与文档

- 功能版本从 `0.1.0` 升级为 `0.2.0`，以 `gradle.properties` 为唯一版本源。
- 构建产物必须为 `build/libs/caustica-0.2.0.jar`，JAR 内 `fabric.mod.json` 也必须为 `0.2.0`。
- 持续维护 `docs/PROJECT.md`、`docs/CHANGELOG.md`、`docs/BUGS.md` 和本阶段实施计划。

## 验收

自动验证：

- 混合概率总和为 1，邻域内外光源均具有正确非零概率；
- NEE 和 BSDF-hit 对同一光源得到相同选择概率；
- alpha 覆盖率为 0、0.5、1 时权重符合预期；
- 每个帧内 SPP 的主射线 jitter 不同，前 6000 个样本不出现 32 相位循环；
- shader 编译和 SPIR-V 验证通过；
- 开启 frame stats 的离线阶段名称检查通过；
- 完整 Java/Gradle 构建成功并生成 `caustica-0.2.0.jar`。

游戏内验证使用 `caustica_test`，固定分辨率、反射次数和手动曝光：

1. `2×2×2` 封闭房间，仅放一个光源；
2. 午夜火把房间；
3. 相同房间分别使用萤石、灯笼和光源方块；
4. 逐级提高渲染距离并比较 GPU 功率、渲染帧数和达到 1500/3000/6000 SPP 的时间；
5. 对比 1500、3000、6000 SPP 截图，确认细颗粒继续随样本增长下降；
6. 确认没有持续不消失的 NaN/Inf 亮点。

原始体验实例 `E:\Minecraft\.minecraft\versions\Caustica26.2` 不得修改。
