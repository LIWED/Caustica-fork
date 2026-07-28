# Caustica 本地构建环境脚本设计

## 目标

提供一个 Windows PowerShell 构建入口，使 Caustica 不依赖当前终端是否已经配置环境变量，也不依赖 Gradle Wrapper 在线下载成功。默认执行完整构建并生成 JAR。

## 方案

新增 `scripts/build_local.ps1`，只修改脚本自身及其子进程的环境，不写系统或用户环境变量。

脚本按以下顺序工作：

1. 从脚本位置确定 Caustica 项目根目录。
2. 优先使用有效的 `JAVA_HOME`，否则从 `java.exe` 自动推导 Java 目录，并验证 Java 25。
3. 使用项目内固定路径加载：
   - `.toolchain/VulkanSDK/1.4.350.0`
   - `third_party/DLSS`
   - `.toolchain/gradle/gradle-9.5.0`
4. 删除当前进程中重复的 `PATH`/`Path`，重建为单一 `Path`，并加入 Java、Vulkan 和 CMake。
5. 通过 Visual Studio Installer 的 `vswhere.exe` 定位 Visual Studio 2022 Build Tools 和 CMake。
6. 默认重新配置并编译 `native/ngx_shim`。
7. 调用项目内 Gradle，默认执行 `build --no-daemon`。

脚本提供：

- `-CheckOnly`：只检查环境和 Path 清理结果，不执行编译。
- `-SkipNative`：已有 `ngxshim.dll` 时跳过原生构建。
- `-GradleArgs`：覆盖默认 Gradle 参数，便于运行 `test`、`clean build` 等任务。

## 错误处理

任何必要文件或工具缺失时立即停止，并显示缺失项目的完整路径。CMake 或 Gradle 返回非零退出码时，脚本原样返回该退出码。

脚本不会安装软件、下载依赖、持久化环境变量、暂存文件或提交代码。

## 测试

先新增环境脚本契约测试，并确认它因脚本缺失而失败。实现后验证：

1. `-CheckOnly` 成功，并确认子进程只有一个 `Path`。
2. 原生 NGX shim 构建成功。
3. 功能契约测试继续通过。
4. 默认完整 Gradle 构建成功并生成 JAR。

## 生成文件管理

在 `.gitignore` 中忽略 `.toolchain/`、`.toolchain-downloads/` 和 `.gradle-user-home/`，避免本地 SDK、Gradle 分发包及缓存出现在 Git 变更列表中。
