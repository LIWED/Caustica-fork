> **Original author credit:** This project is based on [ComfyFluffy/Caustica](https://github.com/ComfyFluffy/Caustica). The original mod author is **i**. Thanks to the original author and contributors for their work. **LIWED** maintains this unofficial fork and adds features to the original mod. **0.5** is this fork's version number.

[English](#english) | [简体中文](#中文)

<a id="english"></a>

# Caustica 0.5

Caustica is a ray tracing mod for Minecraft 26.2. This fork keeps the original mod's ray tracing, DLSS Ray Reconstruction, Frame Generation, and HDR features, and adds water, weather, material, and camera effects with more options for everyday play and architectural photography.

## Features added or improved in this fork

- **Water effects:** Animated waves, shallow-water caustics, underwater fog, and light shafts. Adjust wave amplitude, water transparency, and water fog strength.
- **Rain, snow, and wet surfaces:** Wet ground, reflective puddles, ripples, and rain splashes. Surfaces gradually dry after rain stops, and snowfall has improved motion and appearance.
- **Clouds and weather lighting:** Clouds, cloud shadows, and sunlight occlusion respond to the weather, giving clear skies, rain, and thunderstorms different lighting and atmosphere.
- **Fog and volumetric lighting:** Air fog changes with the time of day and weather. Adjust base density, rain and thunderstorm increases, sunrise/sunset and midday density, and light shaft attenuation.
- **Material depth:** LabPBR resource packs with height information give surfaces such as brick and stone more visible relief, crevices, and shadows, with adjustable depth.
- **Depth of field and camera controls:** Autofocus, fixed distant focus, adjustable depth of field, and camera zoom for buildings, close-ups, and miniature-style scenes.
- **Organized settings:** Ray tracing options are grouped into rendering, materials, exposure, depth of field, water, fog, clouds, and debugging, with English and Chinese descriptions.
- **Visual fixes:** Fixes fullscreen shaking with Frame Generation enabled and purple planes inside boats, and improves cloud shadow stability around sunrise and sunset.

## Screenshots

These in-game screenshots were taken with this fork. Appearance also depends on resource packs, scenes, and settings.

### Rainy courtyard and interior lighting

![Rainy courtyard and interior lighting](docs/gallery/0.5/2026-09-28_17.04.49.png)

### Sunset windmills and depth of field

![Sunset windmills and depth of field](docs/gallery/0.5/2026-09-29_20.49.39.png)

### Daytime architecture and air fog

![Daytime architecture and air fog](docs/gallery/0.5/2026-09-30_16.12.08.png)

### Waterfront buildings, reflections, and shallow-water caustics

![Waterfront buildings, reflections, and shallow-water caustics](docs/gallery/0.5/2026-09-30_19.38.45.png)

### Offshore tower and distant scenery

![Offshore tower and distant scenery](docs/gallery/0.5/2026-09-30_19.40.34.png)

## Download and installation

The mod JAR and source archive for this fork are available from [GitHub Releases](https://github.com/LIWED/Caustica-fork/releases).

1. Use **Minecraft 26.2** and **Java 25 or newer**.
2. Install **Fabric Loader 0.19.3 or newer** and the matching **Fabric API**.
3. Put `caustica-0.5.jar` in your game's `mods` folder and remove or disable older Caustica JARs.
4. Launch the game with the **Vulkan graphics backend**.
5. Open Video Settings to adjust ray tracing, water, weather, and camera options.

The source archive is for inspecting and modifying the project; it cannot be installed as a mod. Material depth effects require a LabPBR resource pack that includes height information.

## Requirements

- A GPU and driver with Vulkan ray tracing support.
- DLSS Ray Reconstruction and Frame Generation require supported NVIDIA RTX hardware and drivers. Frame Generation remains experimental.
- HDR requires an HDR-capable display with system HDR enabled. Linux also requires a native Wayland session with HDR support.
- This mod runs on the client only. Other mods that take over world rendering or the graphics backend may conflict.
- If the game switches back to OpenGL after a crash, re-enable the Vulkan backend.

## Links

- [This fork and issue tracker](https://github.com/LIWED/Caustica-fork)
- [Original project](https://github.com/ComfyFluffy/Caustica)
- [Original project's Discord](https://discord.gg/SeWCjyKu2)
- [Original mod on Modrinth](https://modrinth.com/mod/caustica)
- [Original mod on CurseForge](https://www.curseforge.com/minecraft/mc-mods/caustica/preview)

## License

Project-owned source code and documentation remain licensed under **GNU LGPL v3.0 or later**. See [LICENSE.md](LICENSE.md), [COPYING](COPYING), and [COPYING.LESSER](COPYING.LESSER).

NVIDIA DLSS/NGX components bundled with releases are governed by NVIDIA's own license terms. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

---

<a id="中文"></a>

## 简体中文

> **原作者声明：** 本项目基于 [ComfyFluffy/Caustica](https://github.com/ComfyFluffy/Caustica)，原 Mod 作者为 **i**。感谢原作者及贡献者的工作。此仓库由 **LIWED** 在原 Mod 基础上添加功能并维护，属于非官方分支，版本 **0.5** 为本分支版本。

[English](#english) | [简体中文](#中文)

# Caustica 0.5

Caustica 是用于 Minecraft 26.2 的光线追踪渲染 Mod。本分支保留原 Mod 的光线追踪、DLSS 光线重建、帧生成和 HDR 功能，在此基础上增加水体、天气、材质和镜头效果，让日常游玩与建筑摄影有更多可调选项。

## 在原 Mod 基础上添加与改进的功能

- **水体效果**：动态水波、浅水焦散、水下雾气与光束；可调整水波幅度、水体透明度和水雾强度。
- **雨雪与湿润地表**：雨天的地面湿润、积水反射、涟漪和落地水花；停雨后逐渐变干，并改善雪花飘落效果。
- **云层与天气光照**：随天气变化的云层、云影和日光遮挡，让晴天、雨天与雷暴呈现不同的亮度和氛围。
- **雾气与体积光**：空气雾随时段和天气变化；可调整基础浓度、雨天与雷暴增量、日出日落及正午浓度，以及光束的衰减强度。
- **材质凹凸效果**：支持带高度信息的 LabPBR 资源包，使砖石等方块表面呈现更明显的凹凸、缝隙与阴影，可调整效果深度。
- **景深与镜头控制**：自动对焦、固定远景对焦、可调景深与画面缩放，方便拍摄建筑、近景和微缩风格画面。
- **更便于使用的设置**：光追选项按渲染、材质、曝光、景深、水体、雾气、云层和调试分组，提供中英文说明。
- **画面修正**：修复帧生成开启时的全屏抖动和船内部紫色平面，改善日出日落时的云影稳定性。

## 游戏截图

以下图片来自本分支的游戏内截图，画面也会受到资源包、场景与设置的影响。

### 雨天庭院与室内灯光

![雨天庭院与室内灯光](docs/gallery/0.5/2026-09-28_17.04.49.png)

### 日落风车与景深

![日落风车与景深](docs/gallery/0.5/2026-09-29_20.49.39.png)

### 日间建筑与空气雾

![日间建筑与空气雾](docs/gallery/0.5/2026-09-30_16.12.08.png)

### 水上建筑、反射与浅水焦散

![水上建筑、反射与浅水焦散](docs/gallery/0.5/2026-09-30_19.38.45.png)

### 海上高塔与远景

![海上高塔与远景](docs/gallery/0.5/2026-09-30_19.40.34.png)

## 下载与安装

本分支的 Mod JAR 与源码压缩包通过 [GitHub Releases](https://github.com/LIWED/Caustica-fork/releases) 提供。

1. 使用 **Minecraft 26.2** 和 **Java 25 或更新版本**。
2. 安装 **Fabric Loader 0.19.3 或更新版本**及对应的 **Fabric API**。
3. 将 `caustica-0.5.jar` 放入游戏实例的 `mods` 文件夹，移除或禁用旧版 Caustica JAR。
4. 使用 **Vulkan 图形后端**启动游戏。
5. 在视频设置中调整光线追踪、水体、天气和镜头选项。

源码压缩包用于查看和修改项目，不能作为 Mod 安装。想使用材质凹凸效果，需要搭配包含高度信息的 LabPBR 资源包。

## 运行要求

- 支持 Vulkan 光线追踪的显卡与驱动。
- DLSS 光线重建和帧生成需要受支持的 NVIDIA RTX 显卡与驱动；帧生成仍为实验功能。
- HDR 需要支持 HDR 的显示器，并开启系统 HDR；Linux 下还需要支持 HDR 的原生 Wayland 会话。
- 本 Mod 仅在客户端运行。其他接管世界渲染或图形后端的 Mod 可能产生冲突。
- 如果游戏在崩溃后自动切回 OpenGL，请重新启用 Vulkan 后端。

## 项目链接

- [本分支与问题反馈](https://github.com/LIWED/Caustica-fork)
- [原作者项目](https://github.com/ComfyFluffy/Caustica)
- [原项目 Discord](https://discord.gg/SeWCjyKu2)
- [原 Mod 的 Modrinth 页面](https://modrinth.com/mod/caustica)
- [原 Mod 的 CurseForge 页面](https://www.curseforge.com/minecraft/mc-mods/caustica/preview)

## 许可证

项目自有源码与文档沿用 **GNU LGPL v3.0 或更新版本**。详见 [LICENSE.md](LICENSE.md)、[COPYING](COPYING) 和 [COPYING.LESSER](COPYING.LESSER)。

发布包中包含的 NVIDIA DLSS/NGX 组件适用 NVIDIA 的许可条款，详见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
