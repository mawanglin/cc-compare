# 多平台自动打包 CI 设计

- 日期：2026-05-23
- 分支：`feature/ci-multi-platform-packaging`
- 状态：已批准设计，待编写实现计划

## 1. 目标

代码 push 到 GitHub 上的 `feature/ci-multi-platform-packaging` 分支后，自动在
Windows、Ubuntu、macOS、UOS 四个平台构建并打包 cc-compare，产物作为 GitHub
Actions artifact 上传，可在工作流运行页面下载。

## 2. 需求确认

| 项目 | 决定 |
|---|---|
| 目标平台 | Windows、Ubuntu/Linux、macOS、UOS（UOS 单独构建） |
| 触发条件 | 每次 push 到 `feature/ci-multi-platform-packaging` 分支（不针对 main） |
| 产物形式 | 各平台原生安装包 |
| 产物存放 | GitHub Actions artifact（运行页面下载，不创建 Release） |
| Windows 产物 | NSIS `.exe` 安装包 |
| macOS 产物 | `.dmg` |
| Ubuntu 产物 | `.deb` + AppImage（两个） |
| UOS 产物 | `.deb` + AppImage（两个） |
| CI 结构 | 单 workflow 文件 + 4 个显式 job（方案 A） |

不在本次范围内：发布 GitHub Release、tag 触发、ARM 架构、自托管 runner、
删除仓库内未使用的 `protobuf-cpp-3.11.4.tar.gz`。

## 3. 总体架构

单文件 `.github/workflows/build.yml`：

```yaml
on:
  push:
    branches: [feature/ci-multi-platform-packaging]
concurrency:
  group: build-${{ github.ref }}
  cancel-in-progress: true   # 同分支新 push 取消上一次未完成运行，省额度
```

4 个并行 job，互不依赖、失败隔离：

| job | runner | 说明 |
|---|---|---|
| `windows` | `windows-2022` | MSVC 工具链 |
| `macos` | `macos-13` | 锁 x86_64（项目假设 x86_64；macos-14+ 为 arm64） |
| `ubuntu` | `ubuntu-22.04` | 面向 Ubuntu 用户 |
| `uos` | `ubuntu-22.04` + `container:` Deepin 镜像 | Deepin 是 UOS 社区上游，是最接近 UOS 的公开镜像 |

Qt 版本统一 **5.15.2**。Windows/macOS/Ubuntu 通过 `jurplel/install-qt-action`
安装；UOS 在 Deepin 容器内用 apt 安装系统 Qt5。

## 4. 构建脚本清理（打包前置工作）

打包前必须先修正构建文件。这是本分支上的一个独立 commit，只动构建配置，
不碰任何 C++ 业务代码。

- protobuf 是死依赖——全部源码无任何 `protobuf` / `.pb.h` 引用，且 `libprotobuf`
  库文件在仓库中不存在。经核实，全部 protobuf 配置（`LIBS` 与 `INCLUDEPATH`，含
  `win32{}` 块）都在 **`src/mac/LINUXRealCompare.pro`** 中；`src/RealCompare.pro`
  不含 protobuf，无需修改。
- **`src/mac/LINUXRealCompare.pro`**：
  - 删除全部 `-lprotobuf` / `-llibprotobuf` 的 `LIBS` 及 protobuf 的 `INCLUDEPATH`。
  - 将写死的绝对路径 `-L/home/yzw/build/cccompare/x64/Release` 改为相对路径
    `-Lx64/Release`（Debug 段同理）。
- **每平台使用的 `.pro`**：
  - Windows → 根目录 `src/RealCompare.pro`
  - Linux / macOS → 清理后的 `src/mac/LINUXRealCompare.pro`

## 5. 各平台 job 步骤

### 5.1 通用步骤（4 个 job 都有）

1. checkout 代码
2. 安装 Qt 5.15.2
3. 编译 QScintilla 库：`cd src/qscint/src && qmake qscintilla.pro && make`
   （Windows 用 `nmake` 或 `jom`），产出静态库 `qmyedit_qt5`
4. 将产出的 `libqmyedit_qt5.a` / `qmyedit_qt5.lib` 拷贝到 `src/x64/Release/`
5. 编译主程序：`qmake <平台对应 .pro> && make`
6. 部署 Qt 依赖并打包
7. 上传 artifact

### 5.2 各平台专属步骤

| job | 打包专属步骤 | 产物 artifact |
|---|---|---|
| `windows` | uchardet 用仓库自带 `src/lib64/Release/uchardet.lib`；`windeployqt` 收集 Qt DLL；`makensis src/installer/installer.nsi` 生成安装包 | `CCompare-windows-setup.exe` |
| `macos` | 用清理后的 `LINUXRealCompare.pro`；`macdeployqt CCompare.app -dmg` 生成 dmg | `CCompare-macos.dmg` |
| `ubuntu` | 构造目录树（`/usr/bin`、`.desktop` 文件、图标），用 `dpkg-deb` 打 `.deb`；用 `linuxdeploy` + `linuxdeploy-plugin-qt` 打 AppImage | `CCompare-ubuntu.deb`、`CCompare-ubuntu.AppImage` |
| `uos` | Deepin 容器内 apt 安装 `build-essential`、`qtbase5-dev`、`qttools5-dev-tools` 等；同 ubuntu 方式打 `.deb` + AppImage | `CCompare-uos.deb`、`CCompare-uos.AppImage` |

## 6. 错误处理

- 4 个 job 相互独立，无 matrix、无 `fail-fast`，一个 job 失败不影响其他。
- 每个 job 的关键步骤失败即整个 job 标红，日志可在运行页面查看。
- artifact 仅在对应 job 成功时产出。

## 7. 已知风险

实现阶段需逐个排查解决：

| 编号 | 风险 | 应对 |
|---|---|---|
| R1 | 项目能否在干净环境编译，完全未验证——最大风险 | 分阶段推进，先单平台跑通 |
| R2 | uchardet 在 Linux/macOS 的链接方式不明（unix 段 `.pro` 未链接它） | 实现时确认：可能需 `apt/brew install` 对应开发包或修改 `.pro` |
| R3 | `installer.nsi` 可能引用开发机特定路径/文件 | 实现时核对并修正 NSIS 脚本 |
| R4 | UOS 无官方公开 Docker 镜像，用 Deepin 镜像近似；若 glibc/Qt 差异大，产物在 UOS 真机可能不兼容 | 可接受的折中；后续可换自托管 runner 或真实 UOS 镜像 |
| R5 | macOS 托管 runner 默认 arm64（macos-14+），项目假设 x86_64 | 锁定 `macos-13` 保证 x86_64 |

## 8. 实现策略

因 R1 风险较大，**分阶段推进**，每阶段一个 commit + push 验证：

1. 构建脚本清理（第 4 节）。
2. `ubuntu` job 跑绿（最简单环境，先验证项目可编译、可打 `.deb` + AppImage）。
3. 增加 `windows` job。
4. 增加 `macos` job。
5. 增加 `uos` job。

## 9. 验证与测试

- 本功能是 CI 配置，无单元测试。
- 验证方式：push 到 `feature/ci-multi-platform-packaging` 分支后，检查 4 个
  job 是否全绿、artifact 是否正确产出。
- 可下载 artifact 在对应系统做手工冒烟测试（程序能否启动、能否对比文件）。

## 10. 涉及文件

新增：
- `.github/workflows/build.yml`
- 可能新增：`packaging/` 下的 `.desktop` 文件、`.deb` 的 `control` 模板
  （实现计划阶段确定）

修改：
- `src/mac/LINUXRealCompare.pro`（剥离 protobuf、修正绝对路径——全部 protobuf 配置均在此文件）
- 可能修改：`src/installer/installer.nsi`（视 R3 核对结果）
