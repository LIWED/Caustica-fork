# 第一阶段：上游 Wavefront 水体/玻璃移植实施计划

**目标：** 以官方上游快照建立独立底座，仅移植水体/玻璃的体积衰减与稳定折射修复；不移植 `minecraft:light` 专用点光源、离线累积和旧光源基础设施。

**底座来源：** `.superpowers/upstream-audit/2026-07-30/Caustica-main`

**目标目录：** `Caustica-upstream-port`

## 任务 1：建立并验证上游底座

1. 确认目标目录不存在。
2. 完整复制已审计的官方上游快照到目标目录。
3. 将本计划和已确认设计说明复制到目标项目的 `docs/superpowers/`。
4. 在未修改 Shader 前运行 Java 测试和 Shader 编译，记录基线结果。

## 任务 2：先建立失败的移植契约测试

创建 `scripts/test_wavefront_water_glass_port.ps1`，检查：

1. Pass B 在命中/未命中分支前，对当前介质执行一次 Beer 衰减；未命中使用安全的有限距离。
2. Guide walker 每段追踪后、发布终点和更新介质栈前执行当前介质 Beer 衰减。
3. Guide 不再额外乘玻璃界面色，避免与体积吸收重复计色。
4. 三处水体折射均使用几何法线，波浪法线仍负责 Fresnel 与反射。
5. 几何法线折射发生全反射时强制走反射，且不更新介质栈。

先运行测试并确认它在未移植的上游代码上失败。

## 任务 3：最小化修改 Wavefront Shader

修改：

- `shaders/world/world_primary.rgen.slang`
- `shaders/world/world.rgen.slang`
- `shaders/world/guides.slang`

保持上游的 Pass A/Pass B、`MediumStack`、RIS、队列布局和 ABI 不变。完成后运行契约测试与 `compileShaders`。

## 任务 4：验证与文档

1. 运行契约测试、Java 测试、Shader 编译；条件允许时运行完整构建。
2. 检查差异只覆盖本阶段范围。
3. 更新目标项目：
   - `docs/PROJECT.md`
   - `docs/CHANGELOG.md`
   - `docs/BUGS.md`
4. 执行一次独立代码审查并修正发现的问题。

## 完成标准

- 新底座目录可独立编译目标 Shader。
- 契约测试全部通过。
- 水/玻璃体积吸收按传播距离生效且不重复计色。
- 水体波浪外观保留，折射方向不再受高频波浪法线扰动。
- `minecraft:light` 功能完全未进入新底座。
- 未执行任何 Git 操作。
