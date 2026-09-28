# 离线收敛重启设计

日期：2026-09-09。用户已授权按联网研究和源码审查后的方向重启。

## 目标与边界

- 当前工作区：`F:\mygit\test\Caustica_n\Caustica-fork`，源码版本 0.3.3。
- 用户现象：暗场下各种光源、方块都有持续亮点，非仅水/玻璃/天体；实际运行 JAR、场景、SPP 尚未核实。
- 历史 docs 是待验证记录，不是渲染正确性的证明。
- 保留已有未提交改动；不提交、推送、部署或修改游戏实例。
- 先完成 GGX 数学一致性修复及回归验证，再推进天体模型与实景诊断。

## 第一阶段：GGX 数学一致性

当前 `ggxD` 在分母加 `1e-7`，但 `sampleGGXVNDF` 仍采样标准分布。
`surfaceBsdfPdf` 使用被修改的 D，无法描述真实抽样概率。
roughness=0.045、NdotH=1 时标准 D 约 77624.72，当前约 40.98。
这是分布差异，不代表像素亮度被放大同样倍数。

修复采用稳定的等价 GGX 公式：

```text
a = rough * rough
a2 = a * a
d = (1 - NdotH) * (1 + NdotH) + NdotH * NdotH * a2
D = a2 / (PI * d * d)
```

生产调用已有最小粗糙度 0.045；不通过固定 epsilon 改变分布。
同步核查 Smith G1 的保护项，确保抽样/PDF使用一致模型。
共享 GGX 函数会影响实时和离线高光，必须编译全部 raygen 变体并回归透明材质。

## 验证

新增测试提取实际 shader 标量函数并以 Java float 执行，对照独立 double 参考。
覆盖低粗糙度峰值、角度扫描、分布积分及可见法线 PDF；先验证旧源码失败。
这属于 CPU 数值回归，不冒充 GPU 渲染或完整白炉测试。
执行既有离线、透明材质、实时 Light、帧统计测试和完整构建。

## 后续阶段

本轮补充离线贡献诊断（2026-09-09 用户说明暗场普遍出现后）：

- 复用 `debugView` 的 8–12，分别输出方块直接光、发光命中、天体直接光（含 SSS）、天空命中、bounce>0 的贡献。
- 8–11 是相互独立的来源分类；12 与其重叠，只表示摄像机路径深度，不作为完整物理间接光分解。
- 仅离线编译变体过滤最终贡献，所有抽样、遮挡、throughput、随机数调用保持执行。
- 每个 SPP 独立分类后再累积；不能用最后一次采样的 guide 代替光照贡献。
- 切换分类通过既有 debugView 签名清空 history；1–7 guide 模式不变，移动/等待时8–12显示正常实时图像。
- 增加中英文选项，并说明同机位、同SPP、固定手动曝光比较；天空分类包含现有艺术日月盘。
- 不增加 GPU readback、统计 buffer 或 ABI；统计最大样本/尾部分布为后续测量工作。
- 0.3.4 用于区分本轮包与旧 0.3.3，构建产物不自动安装。

1. 天体直接光与可见光盘角尺寸不同，GGX continuation 与 NEE 未统一 MIS。
   先明确保持美术外观的边界，再设计同一照明模型的 Sample/PDF/Le。
2. 对固定场景分离静态灯 NEE、发光命中、天体 NEE、天空命中和透明路径贡献。
3. 用固定曝光/机位在 1500、3000、6000 SPP 对比误差、最大样本和高亮尾部分布。
4. 仅在采样正确且证据支持时评估可选间接光裁剪/路径正则化。

## 依据

- [PBRT 微表面分布及可见法线 PDF](https://www.pbr-book.org/4ed/Reflection_Models/Roughness_Using_Microfacet_Theory)
- [Heitz 2018 GGX VNDF](https://jcgt.org/published/0007/04/01/)
- [PBRT 路径追踪、MIS 和路径正则化](https://pbr-book.org/4ed/Light_Transport_I_Surface_Reflection/A_Better_Path_Tracer)
