# Caustica 项目状态

## 当前底座

- 分支性质：非官方 0.4.3 实验分支
- 基线：官方上游 Wavefront 渲染架构快照 `5d6bf62`
- 移植来源：早期实验分支 0.3.2
- 当前开发版本：0.4.3
- 当前阶段：WG-024/WG-025 的 0.4.3 实现与自动构建验证已完成；游戏内画面与 GPU 帧时仍待验证

## 0.4.3 开发状态

- 基础水体吸收校准为 `(0.118, 0.052, 0.058)`；Water Fog Strength 只调节翠绿至青蓝散射，不再改变直接 Beer-Lambert 吸收。
- 焦散新增六层仅供焦散使用的短波细节谱及解析二维 warp；基础波与细节梯度在统一增益/坡度限制前合并，并将 Jacobian 差分尺度与 LOD footprint 分离。
- 固定 CPU 镜像回归覆盖峰值密度、方向熵、各向异性、自相关、脊线半峰宽、峰间距、能量范围、确定性、时间连续性和世界重基准不变性。

## 0.4.2 状态

- 深水基础吸收更新为 `(0.120, 0.095, 0.105)`；水体生物群系吸收和中性浑浊消光接口保持不变。
- 视频设置新增持久化的“水波幅度”滑杆，范围 `0–200%`，默认 `100%`；每帧通过 `WorldPush.waterTuning.x` 发布。
- 水面/反射使用十二层波，折射使用低频有界八层波，物理焦散使用十二层波；三者按独立 gain 与坡度上限消费同一幅度。`0%` 回退到几何法线并输出中性焦散。
- Pass A、Pass B 与 Transmission Guide 复用 `waterRefractionNormal`；上一帧仅全反射时采用保守 motion 回退，不增加 `traceGuide`、`traceRadiance` 或 `visibility` 调用。
- Transmission Guide 在每次有限命中后按真实 `payload.hitT` 推进 ray cone，并为当前/上一帧方向分别计算水体 footprint，与 radiance 路径保持相同折射 LOD。
- 已完成自动验证：两个源码契约通过；离线 Gradle `generateShaderRecords compileJava test compileShaders build` 通过，JUnit 为 `45 tests, 0 failures, 0 errors, 0 skipped`；已生成 `build/libs/caustica-0.4.2.jar`。
- 已完成截图验收并确认失败：水体整体偏黑失色，焦散亮纹规则、稀疏且近似平行。根因尚未诊断；水波幅度 `0/100/200%`、运动连续性、previous-only TIR 回退和 GPU 帧时仍需系统实机测试。

## 0.4.1 状态

- 视频设置提供独立的“大气雾”“体积光”开关及 `0–200%` 大气雾强度。
- 空气介质使用解析指数高度雾；首个相机空气段使用固定四层太阳/月亮可见性采样形成体积光，后续路径不重复采样。
- 天气驱动世界锚定动态厚云片、天空、天体与直射光；晴、雨、雷及真实闪电信号具有不同照明反馈。
- 仅在 RT 确认取消 vanilla level renderer 后捕获不可变雨雪柱快照。
- 雨雪转换为 terrain-rebased 交叉双 quad，复用动态粒子 mesh/BLAS 生命周期并仅参与 primary ray。
- 独立 rain/snow 纹理使用安全 bindless slot；any-hit 将纹理 alpha、天气强度及 vanilla 距离淡出结合。
- 水体吸收与浑浊消光提高，深水可见度降低，并保持浅水琥珀到深水翠绿蓝青的层次。

## 已移植

- Pass B 对命中段和有限天空段统一应用当前介质 Beer-Lambert 衰减。
- Transmission Guide 对每段传播应用当前介质衰减。
- 移除 Guide 的玻璃界面重复染色。
- 水体折射使用由几何法线构建的低频有界八层波法线；`0%` 回退到几何法线。
- 水面 Fresnel、反射、反射引导和焦散继续使用动画波浪法线。
- 折射失败/全反射时强制反射，不更新介质栈。
- 水面与焦散共享统一的 12 层非谐波解析频谱；各层使用独立方向、相位和二维波峰弯曲，并保留 footprint LOD。
- 水下物理焦散使用十二层波的 Jacobian 聚焦，并保留稳定主光方向与深度/角度淡出。
- 近岸焦散使用更小的深度自适应采样，并只增强相对中性聚焦的浅水对比。
- 水体使用红强、蓝略强于绿的光谱吸收，以及由浅水琥珀过渡到低饱和翠绿蓝青的散射。
- 视频设置提供默认开启的“水体雾气”；关闭后仅移除水中散射，保留随深度增强的光谱吸收。
- 水中方向散射使用 8 层、最大 48 方块的视线积分；各层独立查询太阳/月亮遮挡与入水光程，并逐帧抖动后交给时间重建收敛。
- 视频设置提供 0–200% 水雾强度；仅缩放翠绿/青蓝环境散射雾与方向光束，直接 Beer-Lambert 吸收和深水透射不随滑杆变化。
- Pass A、Pass B 与 Transmission Guide 共用同一有效消光，避免水底可见度和重建引导不一致。

## 明确未移植

- `minecraft:light` 专用点光源表及相关采样。
- 离线 FP32 累积和冻结状态机。
- 旧静态/CDF 光源基础设施。
- 旧版单体 `world.rgen.slang` 和旧材质 ABI。

## 后续目标

1. 游戏内验证 0.4.3 水雾强度 `0/100/200%` 的直接吸收不变性、翠绿/青蓝水色、密集焦散、静止/移动连续性和 GPU 帧时。
2. 复测深水层次、previous-only TIR motion 回退，以及晴/雨/雷/雪场景的画面连续性。
3. 对比大气雾/体积光开关与 `0/100/200%` 雾强度，检查室内外光柱、运动稳定性和 GPU 帧时。
4. 单独修复染色玻璃仅在移动时出现的明显拖影。

## 验证状态

- 移植契约测试：通过。
- Atmospheric volume/weather 契约：通过。
- Shader 编译：通过。
- 0.4.1 Java、Shader、完整 JUnit（45 tests，0 failures/errors/skipped）及 focused 雨雪测试：通过。
- NGX shim：已生成。
- 0.4.1 完整 Gradle 构建：通过；`build/libs/caustica-0.4.1.jar` 已生成。
- 0.4.0 JAR：已完成完整构建。
- 0.4.1 JAR：已完成完整构建。
- 0.4.1 游戏内视觉与性能验证：待执行；自动测试不能替代实际画面和帧时测量。
- 0.4.2：wavefront water/glass 与 atmospheric volume/weather 源码契约通过；离线完整 Gradle 构建通过，JUnit `45/0/0/0`，`build/libs/caustica-0.4.2.jar` 已生成。
- 0.4.3：两份公开源码契约、50 项 JUnit、强制 Shader 编译和完整离线构建通过；`caustica-0.4.3.jar` 为 `21,089,743` 字节，SHA-256 `B62EAAA522520DEFEAC594DC7699086FEDB7386FD1092484B88C40042FBCE8C9`，内嵌版本为 `0.4.3`。
- 0.4.3 参考画面目标与 GPU 中位帧时增幅 `<=5%` 尚未实机确认；构建产物不纳入源码分支。
