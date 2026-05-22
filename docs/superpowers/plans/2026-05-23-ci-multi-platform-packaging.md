# 多平台自动打包 CI 实现计划

> **面向 AI 代理的工作者：** 必需子技能：使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans 逐任务实现此计划。步骤使用复选框（`- [ ]`）语法来跟踪进度。

**目标：** 让代码 push 到 `feature/ci-multi-platform-packaging` 分支后，GitHub Actions 自动在 Windows / Ubuntu / macOS / UOS 四个平台构建并打包 cc-compare，产物作为 artifact 上传。

**架构：** 单个 `.github/workflows/build.yml`，含 4 个并行的显式 job。每个 job 独立完成「装 Qt → 编 QScintilla 静态库 → 编主程序 → 部署 Qt 依赖 → 打包 → 上传 artifact」。先做一轮构建脚本清理（剥离死依赖 protobuf、修正写死的绝对路径），再分阶段逐平台接入并 push 验证。

**技术栈：** GitHub Actions、Qt 5.15.2、qmake、`jurplel/install-qt-action`、NSIS（Windows）、`macdeployqt`（macOS）、`dpkg-deb` + `linuxdeploy`/`linuxdeploy-plugin-qt`（Linux/UOS）、Deepin Docker 容器（UOS）。

**重要背景：**
- 本项目无单元测试，本功能是 CI 配置。每个任务的「验证」是真实的检查：本地用 `grep`/`qmake` 检查，或 `git push` 后用 `gh run watch` 观察 GitHub Actions 运行结果。
- 构建分两步：先编 `src/qscint/src/qscintilla.pro`（产出静态库 `qmyedit_qt5`），把库拷到 `src/x64/Release/`，再编主程序。
- 主程序产物输出到 `src/x64/Release/`（两个 `.pro` 都设了 `DESTDIR = x64/Release`）。
- protobuf 是死依赖：全部源码无 `protobuf`/`.pb.h` 引用，`.pro` 却链接了它，且 `libprotobuf.lib` 仓库里不存在。
- 设计文档：`docs/superpowers/specs/2026-05-23-ci-multi-platform-packaging-design.md`。

---

## 文件结构

**创建：**
- `.github/workflows/build.yml` — CI 工作流，含 windows/ubuntu/macos/uos 四个 job。
- `packaging/cc-compare.desktop` — Linux 桌面入口文件，被 `.deb` 与 AppImage 共用。
- `packaging/cc-compare.png` — 256×256 应用图标 PNG，从仓库 `.ico` 转换而来，被 `.deb` 与 AppImage 共用。

**修改：**
- `src/mac/LINUXRealCompare.pro` — 删除全部 protobuf 相关 `LIBS`/`INCLUDEPATH`；将写死的 `/home/yzw/...` 绝对路径改为相对路径。注：经核实，全部 protobuf 配置（含 `win32{}` 块）都在此文件中；`src/RealCompare.pro` 不含 protobuf，无需修改。
- `src/installer/installer.nsi` — 仅在任务 3 核对发现引用了开发机特定路径时才修改。

---

## 任务 0：前置检查

**文件：** 无（只读检查）

- [ ] **步骤 1：确认当前分支与 GitHub 远程**

运行：
```bash
git branch --show-current
git remote -v
```
预期：当前分支为 `feature/ci-multi-platform-packaging`；`origin` 指向一个 GitHub 仓库（形如 `github.com/<user>/cc-compare`）。

若 `git remote -v` 无输出（无远程），**停止并询问用户**：CI 验证需要把分支 push 到一个能运行 GitHub Actions 的仓库，请用户提供并配置 `origin`。

- [ ] **步骤 2：确认 `gh` CLI 可用且已登录**

运行：`gh auth status`
预期：显示已登录 GitHub。

若未安装或未登录，**停止并告知用户**：后续每个阶段需要用 `gh run watch` 观察 Actions 运行，请用户运行 `gh auth login`（可在会话中输入 `! gh auth login`）。

- [ ] **步骤 3：核对设计文档**

运行：`cat docs/superpowers/specs/2026-05-23-ci-multi-platform-packaging-design.md`
预期：阅读并确认实现与设计一致。

---

## 任务 1：构建脚本清理

剥离死依赖 protobuf、修正写死的绝对路径。此任务只动构建配置，不碰任何 C++ 业务代码。

> **执行后更正：** 经核实，全部 protobuf 配置（含步骤 2 所述的 `win32{}` 块）都在 `src/mac/LINUXRealCompare.pro` 中，`src/RealCompare.pro` 不含 protobuf。下方步骤 2 的代码块需在 `LINUXRealCompare.pro` 中删除，`src/RealCompare.pro` 实际未修改。

**文件：**
- 修改：`src/mac/LINUXRealCompare.pro`（全部 protobuf 配置与绝对路径均在此文件）

- [ ] **步骤 1：确认 protobuf 确为死依赖**

运行：
```bash
grep -rln "protobuf\|google/protobuf\|\.pb\.h" --include='*.cpp' --include='*.h' --include='*.cc' src | grep -v qscint
```
预期：无输出（源码中无任何 protobuf 引用）。若有输出，**停止并报告**——protobuf 实际被使用，需重新评估。

- [ ] **步骤 2：从 `src/RealCompare.pro` 删除 protobuf 块**

删除以下整段（位于文件中部 `win32{ ... }` 块，链接 `libprotobuf` 的那一段）：

```qmake
win32{
	if(contains(QMAKE_HOST.arch, x86_64)){
		if(CONFIG(Debug, Debug|Release)){
			LIBS += -Llib64/Debug -llibprotobufd
		}else{
			LIBS += -Llib64/Release  -llibprotobuf
		}
   }else{
		if(CONFIG(Debug, Debug|Release)){
			LIBS += -Llib32/Debug -llibprotobufd
		}else{
			LIBS += -Llib32/Release  -llibprotobuf
		}
  }
}
```

注意：保留同文件中链接 `uchardet` 的 `win32{}` 块——uchardet 不是死依赖，Windows 需要它。

- [ ] **步骤 3：从 `src/mac/LINUXRealCompare.pro` 删除 protobuf 并修正绝对路径**

将该文件的 `unix{ ... }` 链接段：

```qmake
unix{

if(CONFIG(Debug, Debug|Release)){
          LIBS += -L/home/yzw/build/cccompare/lib -lprotobuf
          LIBS += -L/home/yzw/build/cccompare/x64/Debug -lqmyedit_qt5_debug
}else{
          LIBS += -L/home/yzw/build/cccompare/lib -lprotobuf
          LIBS += -L/home/yzw/build/cccompare/x64/Release -lqmyedit_qt5
          DESTDIR = x64/Release

        QMAKE_CXXFLAGS += -fopenmp -O2
        LIBS += -lgomp -lpthread
}
}
```

改为（删除两行 `-lprotobuf`，把绝对路径改为相对路径 `x64/...`）：

```qmake
unix{

if(CONFIG(Debug, Debug|Release)){
          LIBS += -Lx64/Debug -lqmyedit_qt5_debug
}else{
          LIBS += -Lx64/Release -lqmyedit_qt5
          DESTDIR = x64/Release

        QMAKE_CXXFLAGS += -fopenmp -O2
        LIBS += -lgomp -lpthread
}
}
```

同时删除该文件中 protobuf 的 `INCLUDEPATH` 段：

```qmake
win32
{
INCLUDEPATH += e://protobuf-3.11.4/src
}
unix
{
INCLUDEPATH +=/home/yzw/build/protobuf-3.11.4/output/include
}
```

- [ ] **步骤 4：验证清理结果**

运行：
```bash
grep -n "protobuf" src/RealCompare.pro src/mac/LINUXRealCompare.pro
grep -n "/home/yzw" src/mac/LINUXRealCompare.pro
```
预期：两条命令均无输出。

- [ ] **步骤 5：Commit**

```bash
git add src/RealCompare.pro src/mac/LINUXRealCompare.pro
git commit -m "build: 剥离死依赖 protobuf 并修正写死的绝对路径

protobuf 在源码中无任何引用，且 libprotobuf 库文件不在仓库中。
LINUXRealCompare.pro 中的 /home/yzw 绝对路径改为相对路径，
以便在 CI 干净环境中构建。

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## 任务 2：创建 workflow 骨架与 ubuntu job

ubuntu 是最简单的环境，先让它跑通，验证项目本身能在干净环境编译并打包。

**文件：**
- 创建：`.github/workflows/build.yml`
- 创建：`packaging/cc-compare.desktop`
- 创建：`packaging/cc-compare.png`

- [ ] **步骤 1：创建桌面入口文件 `packaging/cc-compare.desktop`**

```ini
[Desktop Entry]
Type=Application
Name=cc compare
GenericName=Code Compare Tool
Comment=A free code comparison tool
Exec=CCompare %F
Icon=cc-compare
Categories=Development;Utility;
Terminal=false
```

- [ ] **步骤 2：生成应用图标 `packaging/cc-compare.png`**

运行（找到仓库中的应用 `.ico`，转换为 256×256 PNG）：
```bash
sudo apt-get update && sudo apt-get install -y imagemagick
ICO=$(find src -name '*.ico' | head -1)
echo "使用图标源文件: $ICO"
mkdir -p packaging
convert "$ICO[0]" -resize 256x256 packaging/cc-compare.png
file packaging/cc-compare.png
```
预期：`file` 输出确认是 PNG 图像。若仓库无 `.ico`，改用 `src/mac/main.icns`：`convert "src/mac/main.icns" -resize 256x256 packaging/cc-compare.png`。

- [ ] **步骤 3：创建 `.github/workflows/build.yml`（含 ubuntu job）**

```yaml
name: Build & Package

on:
  push:
    branches: [feature/ci-multi-platform-packaging]

concurrency:
  group: build-${{ github.ref }}
  cancel-in-progress: true

env:
  QT_VERSION: 5.15.2
  APP_VERSION: 1.26.0

jobs:
  ubuntu:
    runs-on: ubuntu-22.04
    steps:
      - uses: actions/checkout@v4

      - name: Install Qt
        uses: jurplel/install-qt-action@v4
        with:
          version: ${{ env.QT_VERSION }}
          host: linux
          target: desktop
          arch: gcc_64

      - name: Install build deps
        run: |
          sudo apt-get update
          sudo apt-get install -y build-essential libuchardet-dev \
            libgl1-mesa-dev libxkbcommon-x11-0 fuse libfuse2

      - name: Build QScintilla static lib
        run: |
          cd src/qscint/src
          qmake qscintilla.pro
          make -j$(nproc)
          mkdir -p ../../x64/Release
          cp libqmyedit_qt5.a ../../x64/Release/

      - name: Build CCompare
        run: |
          cd src
          cp mac/LINUXRealCompare.pro ./LINUXRealCompare.pro
          qmake LINUXRealCompare.pro
          make -j$(nproc)
          ls -la x64/Release/

      - name: Stage app tree
        run: |
          STAGE="$GITHUB_WORKSPACE/stage"
          mkdir -p "$STAGE/usr/bin" \
                   "$STAGE/usr/share/applications" \
                   "$STAGE/usr/share/icons/hicolor/256x256/apps"
          cp src/x64/Release/CCompare "$STAGE/usr/bin/"
          cp packaging/cc-compare.desktop "$STAGE/usr/share/applications/"
          cp packaging/cc-compare.png \
             "$STAGE/usr/share/icons/hicolor/256x256/apps/cc-compare.png"

      - name: Build .deb
        run: |
          STAGE="$GITHUB_WORKSPACE/stage"
          mkdir -p "$STAGE/DEBIAN"
          cat > "$STAGE/DEBIAN/control" <<EOF
          Package: cc-compare
          Version: ${{ env.APP_VERSION }}
          Section: devel
          Priority: optional
          Architecture: amd64
          Maintainer: cc-compare CI <ci@example.com>
          Description: A free code comparison tool
          EOF
          dpkg-deb --build "$STAGE" "CCompare-ubuntu.deb"

      - name: Build AppImage
        run: |
          wget -q https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage
          wget -q https://github.com/linuxdeploy/linuxdeploy-plugin-qt/releases/download/continuous/linuxdeploy-plugin-qt-x86_64.AppImage
          chmod +x linuxdeploy*.AppImage
          ./linuxdeploy-x86_64.AppImage \
            --appdir AppDir \
            --executable src/x64/Release/CCompare \
            --desktop-file packaging/cc-compare.desktop \
            --icon-file packaging/cc-compare.png \
            --plugin qt \
            --output appimage
          mv CCompare*.AppImage CCompare-ubuntu.AppImage

      - name: Upload artifacts
        uses: actions/upload-artifact@v4
        with:
          name: ubuntu-packages
          path: |
            CCompare-ubuntu.deb
            CCompare-ubuntu.AppImage
```

- [ ] **步骤 4：本地校验 YAML 语法**

运行：
```bash
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/build.yml')); print('YAML OK')"
```
预期：输出 `YAML OK`。

- [ ] **步骤 5：Commit 并 push**

```bash
git add .github/workflows/build.yml packaging/
git commit -m "ci: 新增多平台打包工作流（ubuntu job）

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
git push -u origin feature/ci-multi-platform-packaging
```

- [ ] **步骤 6：观察 ubuntu job 运行结果**

运行：`gh run watch --exit-status`
预期：`ubuntu` job 成功（绿）。

若失败，根据日志定位（参考设计文档风险 R1/R2）：
- **链接错误提示 uchardet 符号未定义**：在 `src/mac/LINUXRealCompare.pro` 的 `unix{}` else 段加一行 `LIBS += -luchardet`，commit 后重新 push。
- **QScintilla 库未找到**：检查 `cp libqmyedit_qt5.a` 步骤——确认 `make` 后 `.a` 文件实际生成的文件名（`ls src/qscint/src/*.a`），按实际名调整。
- **缺少 Qt 模块编译报错**：在 `install-qt-action` 的 `modules:` 中补充缺失模块。
逐项修复后重复步骤 5–6，直到 ubuntu job 绿。

---

## 任务 3：增加 windows job

**文件：**
- 修改：`.github/workflows/build.yml`

- [ ] **步骤 1：核对 NSIS 脚本引用的路径（风险 R3）**

运行：
```bash
cat src/installer/installer.nsi
```
预期：阅读脚本，记录它引用的输入文件路径（待打包的 exe、Qt DLL、资源等）与输出文件名。后续步骤的 `windeployqt` 输出目录需与之对应。若脚本引用了开发机特定的绝对路径，在步骤 3 一并修正 `installer.nsi`（修改后纳入本任务的 commit）。

- [ ] **步骤 2：在 `build.yml` 的 `jobs:` 下新增 `windows` job**

在 `ubuntu` job 之后追加：

```yaml
  windows:
    runs-on: windows-2022
    steps:
      - uses: actions/checkout@v4

      - name: Install Qt
        uses: jurplel/install-qt-action@v4
        with:
          version: ${{ env.QT_VERSION }}
          host: windows
          target: desktop
          arch: win64_msvc2019_64

      - name: Setup MSVC
        uses: ilammy/msvc-dev-cmd@v1
        with:
          arch: x64

      - name: Build QScintilla static lib
        shell: cmd
        run: |
          cd src\qscint\src
          qmake qscintilla.pro
          nmake
          if not exist ..\..\x64\Release mkdir ..\..\x64\Release
          copy qmyedit_qt5.lib ..\..\x64\Release\

      - name: Build CCompare
        shell: cmd
        run: |
          cd src
          qmake RealCompare.pro
          nmake
          dir x64\Release

      - name: Deploy Qt runtime
        shell: cmd
        run: |
          cd src\x64\Release
          windeployqt CCompare.exe

      - name: Build NSIS installer
        shell: cmd
        run: |
          cd src\installer
          makensis installer.nsi

      - name: Upload artifact
        uses: actions/upload-artifact@v4
        with:
          name: windows-package
          path: src/installer/*.exe
```

注意：`path:` 与 `makensis` 的工作目录需按步骤 1 核对到的 `installer.nsi` 实际输出位置与文件名调整。

- [ ] **步骤 3：本地校验 YAML 并 commit、push**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/build.yml')); print('YAML OK')"
git add .github/workflows/build.yml src/installer/installer.nsi
git commit -m "ci: 增加 windows job（NSIS 安装包）

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
git push
```
若步骤 1 未修改 `installer.nsi`，`git add` 时去掉该文件。

- [ ] **步骤 4：观察 windows job 运行结果**

运行：`gh run watch --exit-status`
预期：`windows` job 成功，artifact `windows-package` 含 `.exe` 安装包。

若失败，常见原因：`nmake` 找不到——确认 `Setup MSVC` 步骤生效；QScintilla `.lib` 名称不符——`dir src\qscint\src\*.lib` 核对实际名；`installer.nsi` 找不到输入文件——按步骤 1 核对结果修正路径。修复后重复步骤 3–4 直到 windows job 绿。

---

## 任务 4：增加 macos job

**文件：**
- 修改：`.github/workflows/build.yml`

- [ ] **步骤 1：在 `build.yml` 的 `jobs:` 下新增 `macos` job**

在 `windows` job 之后追加：

```yaml
  macos:
    runs-on: macos-13
    steps:
      - uses: actions/checkout@v4

      - name: Install Qt
        uses: jurplel/install-qt-action@v4
        with:
          version: ${{ env.QT_VERSION }}
          host: mac
          target: desktop
          arch: clang_64

      - name: Install build deps
        run: brew install uchardet

      - name: Build QScintilla static lib
        run: |
          cd src/qscint/src
          qmake qscintilla.pro
          make -j$(sysctl -n hw.ncpu)
          mkdir -p ../../x64/Release
          cp libqmyedit_qt5.a ../../x64/Release/

      - name: Build CCompare
        run: |
          cd src
          cp mac/LINUXRealCompare.pro ./LINUXRealCompare.pro
          qmake LINUXRealCompare.pro
          make -j$(sysctl -n hw.ncpu)
          ls -la x64/Release/

      - name: Deploy & build dmg
        run: |
          cd src/x64/Release
          macdeployqt CCompare.app -dmg
          mv CCompare.dmg "$GITHUB_WORKSPACE/CCompare-macos.dmg"

      - name: Upload artifact
        uses: actions/upload-artifact@v4
        with:
          name: macos-package
          path: CCompare-macos.dmg
```

- [ ] **步骤 2：本地校验 YAML 并 commit、push**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/build.yml')); print('YAML OK')"
git add .github/workflows/build.yml
git commit -m "ci: 增加 macos job（dmg 安装包）

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
git push
```

- [ ] **步骤 3：观察 macos job 运行结果**

运行：`gh run watch --exit-status`
预期：`macos` job 成功，artifact `macos-package` 含 `CCompare-macos.dmg`。

若失败，常见原因：构建产物是 `CCompare`（裸可执行文件）而非 `CCompare.app`——`mac/LINUXRealCompare.pro` 缺少 macOS app bundle 配置，需确认 `.pro` 中 `TARGET`/`CONFIG`；`uchardet` 链接失败——同任务 2 步骤 6 的处理，在 `unix{}` 段加 `LIBS += -luchardet`，并确保 `INCLUDEPATH` 含 `$(brew --prefix uchardet)/include`、`LIBS` 含 `-L$(brew --prefix uchardet)/lib`。修复后重复步骤 2–3 直到 macos job 绿。

---

## 任务 5：增加 uos job

UOS 无官方公开 Docker 镜像，使用其社区上游 Deepin 的镜像近似（设计文档风险 R4）。

**文件：**
- 修改：`.github/workflows/build.yml`

- [ ] **步骤 1：在 `build.yml` 的 `jobs:` 下新增 `uos` job**

在 `macos` job 之后追加：

```yaml
  uos:
    runs-on: ubuntu-22.04
    container:
      image: linuxdeepin/deepin:apricot
    steps:
      - uses: actions/checkout@v4

      - name: Install build deps
        run: |
          apt-get update
          apt-get install -y build-essential qtbase5-dev qttools5-dev-tools \
            libqt5sql5-sqlite libuchardet-dev \
            wget file dpkg-dev

      - name: Build QScintilla static lib
        run: |
          cd src/qscint/src
          qmake qscintilla.pro
          make -j$(nproc)
          mkdir -p ../../x64/Release
          cp libqmyedit_qt5.a ../../x64/Release/

      - name: Build CCompare
        run: |
          cd src
          cp mac/LINUXRealCompare.pro ./LINUXRealCompare.pro
          qmake LINUXRealCompare.pro
          make -j$(nproc)
          ls -la x64/Release/

      - name: Stage app tree
        run: |
          STAGE="$GITHUB_WORKSPACE/stage"
          mkdir -p "$STAGE/usr/bin" \
                   "$STAGE/usr/share/applications" \
                   "$STAGE/usr/share/icons/hicolor/256x256/apps" \
                   "$STAGE/DEBIAN"
          cp src/x64/Release/CCompare "$STAGE/usr/bin/"
          cp packaging/cc-compare.desktop "$STAGE/usr/share/applications/"
          cp packaging/cc-compare.png \
             "$STAGE/usr/share/icons/hicolor/256x256/apps/cc-compare.png"
          cat > "$STAGE/DEBIAN/control" <<EOF
          Package: cc-compare
          Version: ${{ env.APP_VERSION }}
          Section: devel
          Priority: optional
          Architecture: amd64
          Maintainer: cc-compare CI <ci@example.com>
          Description: A free code comparison tool (UOS build)
          EOF

      - name: Build .deb
        run: dpkg-deb --build "$GITHUB_WORKSPACE/stage" "CCompare-uos.deb"

      - name: Build AppImage
        run: |
          wget -q https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage
          wget -q https://github.com/linuxdeploy/linuxdeploy-plugin-qt/releases/download/continuous/linuxdeploy-plugin-qt-x86_64.AppImage
          chmod +x linuxdeploy*.AppImage
          export APPIMAGE_EXTRACT_AND_RUN=1
          ./linuxdeploy-x86_64.AppImage \
            --appdir AppDir \
            --executable src/x64/Release/CCompare \
            --desktop-file packaging/cc-compare.desktop \
            --icon-file packaging/cc-compare.png \
            --plugin qt \
            --output appimage
          mv CCompare*.AppImage CCompare-uos.AppImage

      - name: Upload artifacts
        uses: actions/upload-artifact@v4
        with:
          name: uos-packages
          path: |
            CCompare-uos.deb
            CCompare-uos.AppImage
```

注意：`APPIMAGE_EXTRACT_AND_RUN=1` 用于容器内无 FUSE 时运行 AppImage 工具。

- [ ] **步骤 2：本地校验 YAML 并 commit、push**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/build.yml')); print('YAML OK')"
git add .github/workflows/build.yml
git commit -m "ci: 增加 uos job（Deepin 容器内打包 deb + AppImage）

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
git push
```

- [ ] **步骤 3：观察 uos job 运行结果**

运行：`gh run watch --exit-status`
预期：`uos` job 成功，artifact `uos-packages` 含 `.deb` 与 `.AppImage`。

若失败，常见原因：
- **镜像 `linuxdeepin/deepin:apricot` 拉取失败**：改用 `debian:11`（设计文档 R4 记录的回退方案，glibc 接近 UOS 20）。
- **Deepin 仓库 Qt 版本过旧导致编译报 API 错误**：记录具体报错并停止，向用户报告——UOS 目标可能需要自托管 runner 或真实 UOS 镜像（R4）。
- **uchardet 链接失败**：同任务 2 步骤 6 处理。
修复后重复步骤 2–3 直到 uos job 绿。

---

## 任务 6：收尾验证

**文件：** 无

- [ ] **步骤 1：确认四个 job 全绿**

运行：`gh run list --branch feature/ci-multi-platform-packaging --limit 1`
然后：`gh run view --log` 查看最近一次运行。
预期：`windows` / `ubuntu` / `macos` / `uos` 四个 job 全部成功。

- [ ] **步骤 2：确认所有 artifact 产出**

运行：`gh run view <run-id> --json jobs` 或在运行页面检查。
预期：4 个 artifact 组——`windows-package`（.exe）、`ubuntu-packages`（.deb + .AppImage）、`macos-package`（.dmg）、`uos-packages`（.deb + .AppImage）。

- [ ] **步骤 3：更新设计文档状态**

将 `docs/superpowers/specs/2026-05-23-ci-multi-platform-packaging-design.md` 头部 `状态` 改为 `已实现`。

- [ ] **步骤 4：Commit**

```bash
git add docs/superpowers/specs/2026-05-23-ci-multi-platform-packaging-design.md
git commit -m "docs: 标记多平台打包 CI 设计为已实现

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
git push
```

---

## 完成标准

- 四个 job（windows/ubuntu/macos/uos）在最新一次 push 中全部成功。
- 产出 6 个安装包：Windows `.exe`、Ubuntu `.deb` + `.AppImage`、macOS `.dmg`、UOS `.deb` + `.AppImage`。
- 无写死的开发机绝对路径，无对死依赖 protobuf 的引用。
