# Linux / Arch + Hyprland 适配说明

> 适用版本：v2.8.6 ｜ 目标环境：Arch Linux + Wayland（Hyprland）+ PipeWire ｜ XWayland
>
> 本文记录 Y2Kmeter 在 Linux 桌面上的落地方式、改动点与已知限制。
> 上游原本只支持 Windows / macOS，Linux 相关代码是本次移植新增的。

---

## 一、结论速览

| 能力 | Linux 状态 | 说明 |
|------|-----------|------|
| 构建（Standalone） | 支持 | CMake + Ninja，GCC 16 实测通过 |
| 窗口显示 | 支持 | 无边框浮动条；Hyprland 下自动转 floating + 置顶 |
| 置顶（Pin） | 支持 | 走 X11 `_NET_WM_STATE_ABOVE`，Hyprland 实测生效 |
| Stick 驻留条 | 支持（视觉等价） | 浮动条贴屏幕顶/底边 + pin；**不压缩工作区**（Wayland 无 AppBar API） |
| Hide 模式 | 支持 | 窗口收缩，悬停浮层逻辑与 Windows 一致 |
| 系统输出（Output 源） | 支持 | 采集默认 sink 的 monitor（`pw-record`；PulseAudio 回退 `parec`） |
| 麦克风（Microphone 源） | 支持 | 走 JUCE ALSA 设备 |
| 预设 Save / Load（.settings） | 支持 | 原生对话框走 zenity/kdialog；失败会弹错误提示 |
| Milkdrop 模块 | 不可用 | 仓库只带 Windows DLL / macOS dylib，Linux 无 libprojectM |

---

## 二、依赖与构建

### 2.1 依赖（Arch）

```bash
sudo pacman -S --needed base-devel cmake ninja gcc ccache \
    libcurl alsa-lib freetype2 libpng \
    libx11 libxrandr libxinerama libxcursor libxext \
    pipewire pipewire-pulse wireplumber \
    zenity        # 文件对话框（非必需：缺省时回退 JUCE 自绘对话框）
```

说明：

- `gtk3` / `webkit2gtk` **不再是构建依赖**：CMake 里显式 `JUCE_WEB_BROWSER=0`，
  避免 juce_gui_extra 去包含 `gtk/gtk.h`（Arch 默认没有 webkit2gtk-4.0）。
- `libcurl` 是 Linux 上 JUCE 网络栈的硬依赖（`JUCE_USE_CURL=1`），CMake 通过
  `NEEDS_CURL TRUE` 让 JUCE 把 pkg-config 的 libcurl 链进来。
- `zenity` 只在"保存/导入预设"的文件对话框里用到；没有它 JUCE 会退回自绘
  文件选择器（功能等价）。

### 2.2 构建

```bash
cmake --preset linux-release
cmake --build --preset linux-release --target Y2Kmeter_Standalone
# 产物：build/linux/Y2Kmeter_artefacts/Release/Standalone/Y2Kmeter
```

或手动：

```bash
cmake -S . -B build/linux -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
cmake --build build/linux --target Y2Kmeter_Standalone -j"$(nproc)"
```

### 2.3 运行 / 安装

```bash
# 直接运行
./build/linux/Y2Kmeter_artefacts/Release/Standalone/Y2Kmeter

# 安装到用户目录（可选）
install -Dm755 build/linux/Y2Kmeter_artefacts/Release/Standalone/Y2Kmeter \
    ~/.local/opt/Y2Kmeter/Y2Kmeter
```

应用配置文件：`~/.config/Y2Kmeter.settings`（JUCE `PropertiesFile`）。

---

## 三、本次为 Linux 修的构建问题

| # | 现象 | 根因 | 修法 |
|---|------|------|------|
| 1 | `fatal error: gtk/gtk.h: No such file` | `JUCE_WEB_BROWSER` 默认 1，Linux 分支会强包含 GTK/WebKit 头，而 CMake 只有在 pkg-config 找到 webkit2gtk-4.x 时才加 include 路径 | CMake 增加 `JUCE_WEB_BROWSER=0` |
| 2 | `invalid use of incomplete type SIMDRegister<long long>` | `juce::jmax<juce::int64>` 显式模板实参命中了 JUCE 的 `SIMDRegister` 重载，GCC 下实例化不完整类型 | 改成自然推导 `juce::jmax ((juce::int64) 1, now - start)` |
| 3 | `undefined reference to curl_multi_timeout` 等 | Linux 上 JUCE 的 URL 走 libcurl，但工程没声明该依赖 | `juce_add_plugin(... NEEDS_CURL TRUE)` |

---

## 四、窗口行为（Hyprland）

### 4.1 为什么需要专门处理

- Hyprland 是平铺式合成器：普通 X11 窗口默认会被塞进平铺布局，表现为
  窗口被拉满屏幕、无法拖动/缩放，`setBounds` 也会被合成器覆盖。
- Hyprland **不采纳 X11 `ConfigureRequest` 里的坐标**（映射时会把浮动窗口
  居中），只采纳尺寸 —— 所以"贴边驻留"必须显式通过 IPC 搬窗口。
- 上游的 Stick 是 Windows AppBar（`SHAppBarMessage`），Linux 没有对应 API。

### 4.2 实现方式

新增 `source/standalone/LinuxWindowSupport.{h,cpp}`：

- 通过环境变量 `HYPRLAND_INSTANCE_SIGNATURE` 判定是否 Hyprland；
- `hyprctl -j clients` 里按 pid 找到本进程窗口的 address；
- `hyprctl version -j` 解析 tag，**同时适配两代 dispatch 语法**：
  - Hyprland ≥ 0.55（Lua 配置）：`hl.dsp.window.float{action="enable", window="address:0x..."}` /
    `hl.dsp.window.pin{...}` / `hl.dsp.window.move{x=.., y=.., ...}`；
  - Hyprland < 0.55（hyprlang）：`hyprctl dispatch setfloating` 等旧语法；
- 坐标换算：应用拿到的 X11 像素坐标 × (显示器逻辑宽 / X11 像素宽) = Hyprland
  逻辑坐标（本机 2560 物理 ↔ 2400 逻辑，scale 1.0667）。

启动时的窗口流程（`Y2KStandaloneApp::initialise`）：

1. 恢复/计算窗口 bounds（见下）；
2. `addToDesktop()` + `setVisible(true)`；
3. `tryAdoptLinuxWindow()`：最多 8 次 × 250ms 重试，把窗口转 floating + 提到最前；
4. 成功后重新提交期望几何，并用 `hyprctl` 把窗口搬到目标位置。

平铺式 WM 的兜底：非 Hyprland 环境不会做任何 IPC 调用，若仍被平铺，可在
合成器配置里加窗口规则（Hyprland 示例）：

```ini
windowrulev2 = float, class:^(Y2Kmeter)$
windowrulev2 = pin, class:^(Y2Kmeter)$
```

### 4.3 Stick（驻留条）

Linux 上 Stick 走"浮动条贴边"：

- 进入：窗口改为屏幕宽 × 条高，贴显示器 `userArea` 顶边或底边，`pin` 置顶，
  布局切换到对应的 stick 槽（T/B 与 Windows 一致，独立存档）；
- 退出：取消 pin，恢复进入前的窗口 bounds 与常驻布局；
- 差异：**Hyprland/Wayland 没有 AppBar 那种"缩小其他窗口工作区"的 API**，
  所以是视觉等价的覆盖条，而不是真正的占位。介意重叠可在合成器侧配合
  `windowrulev2` 或留出顶部间距。

### 4.4 窗口 bounds 的恢复策略

- 存档里若出现"等于整屏尺寸"的窗口（Windows 时代的伪最大化残留），Linux 上
  不再照搬，而是缩到显示器 `userArea` 的 80% 并居中 —— 避免一启动就是一块
  盖满桌面、无法拖动的窗口。
- 关闭时仍按"Show 态等效尺寸"保存，语义与上游一致。

### 4.5 文件对话框层级

保存/导入预设用的 `FileChooser` 在 Linux 上可能是独立顶层窗口（zenity 或
JUCE 自绘），旧代码 `parent = nullptr` + 主窗 AlwaysOnTop 会让对话框出现在
主窗下面，表现为"点了 Save 没反应"。现在：

- `FileChooser` 传入顶层窗口作为 parent（居中/归属更合理）；
- 对话框打开期间临时摘掉主窗 AlwaysOnTop，关闭后恢复。

---

## 五、系统输出（Output 音频源）

### 5.1 旧实现为什么不行

Linux 上原来的 "Output" 走 `findPreferredVirtualLoopbackInputName()`：在
JUCE 的 **ALSA 输入设备列表**里按关键词（blackhole/loopback/monitor/...）挑一个
设备当回环输入。

但 PipeWire 的 monitor 源**不是 ALSA 物理设备**，JUCE 的 ALSA 设备枚举里
根本没有它；关键词匹配失败后它按"排除麦克风关键词"兜底，会挑中 ALSA 的
`default` 播放 PCM（描述为 `Default ALSA Output (currently PipeWire Media Server)`），
打开后拿到的其实是默认采集源 —— 也就是麦克风。

### 5.2 新实现

新增 `source/standalone/LinuxMonitorCapture.{h,cpp}`（零 JUCE 依赖）：

- **PipeWire（主路径）**：`pw-record --target <default-sink>.monitor --format f32
  --rate 48000 --channels 2 --container raw -`；
- **PulseAudio（回退）**：`parec --device=<default-sink>.monitor --format=float32le
  --rate=48000 --channels=2 --raw`；
- 默认 sink 的解析顺序：`pactl get-default-sink` → `wpctl inspect
  @DEFAULT_AUDIO_SINK@` → `pw-metadata` → `pw-dump`，逐级兜底；
- 采集线程按 10ms（480 帧）分块，interleaved → L/R 平面 float 回调；
- 与 Windows loopback 相同的并发约束：启动前 `detachHolderCallback()`，
  停止后 `attachHolderCallback()`，保证同一时刻只有一路在写 `AnalyserHub`。

切换语义与上游一致：下拉里仍只有 `Microphone` / `Output` 两项，
`Output` 现在直接抓系统混音输出，不需要 BlackHole/VB-Cable 之类的虚拟声卡。

### 5.3 自带验证方式

```bash
# 播放一段测试音，应用切到 Output，电平表应跟随系统输出跳动
ffplay -f lavfi -i "sine=frequency=1000:duration=5" -volume 60
# 或
pw-play /path/to/tone.wav
```

已知坑（来自实测）：

- `pw-record` 不加 `--container raw` 会在 stdout 前带 24 字节 AU 头，导致
  f32 流整体错位；实现里已固定加该参数；
- `pw-record --target <不存在的名字>` 不报错，会静默回退到默认 source
  （即麦克风）。如果 Output 表跟着环境噪音而不是系统播放声跳动，先检查
  `pactl get-default-sink` 与 `.monitor` 名字；
- 部分发行版的 `parec`（PipeWire 1.6.x）连上后不出数据；实现会以 1.5s
  超时返回失败并回退麦克风，主路径务必保证 `pw-record` 可用。

---

## 六、预设 Save / Load（.settings）

- Save：把当前 settings 物理文件复制到用户选择的路径；
- Load：覆盖 `~/.config/Y2Kmeter.settings` 后自重启；
- 本次改动：失败不再静默（弹 "Save preset failed" 并带目标路径），成功仍保持
  静默；目标若是目录会自动补 `Y2Kmeter.settings`；复制后校验目标文件非空。

---

## 七、已知限制 / 后续可做

1. **Milkdrop**：Linux 缺 libprojectM 二进制。要启用需自行编译 libprojectM 4
   并把 `libprojectM-4.so` 放到可执行文件旁，同时把 `ProjectMApi.cpp` 的
   dlopen 路径分支补上 Linux（目前只找 `.dll` / `.dylib`）。
2. **Stick 不是真占位**：见 4.3，属于 Wayland 平台能力差异。
3. **多显示器/混合缩放**：坐标换算按"窗口所在显示器的 scale"算；多显示器
   各自不同缩放组合未做过实机验证。
4. **VST3 构建**：Linux 下 `Y2Kmeter_VST3` 目标理论上可编（未安装到 `~/.vst3`
   验证），本次只交付 Standalone。
5. 上游 Windows 专属的 Direct2D 规避、AppBar、TCC 等代码在 Linux 上不会编译
   （平台宏隔离），无需移植。

---

## 八、改动文件清单（Linux 适配）

新增：

- `source/standalone/LinuxWindowSupport.{h,cpp}` —— Hyprland 浮动/置顶/移动
- `source/standalone/LinuxMonitorCapture.{h,cpp}` —— 系统输出采集

修改：

- `CMakeLists.txt` —— `JUCE_WEB_BROWSER=0`、`NEEDS_CURL TRUE`、新增 Linux 源文件
- `CMakePresets.json` —— `linux-release` / `linux-debug` 预设
- `source/perf/PerformanceCounterSystem.cpp` —— GCC 下 `jmax<int64>` 编译错误
- `source/standalone/Y2KStandaloneApp.cpp` —— 窗口收养/几何、bounds 恢复策略、
  Linux 系统输出采集接线、Save 健壮性
- `PluginEditor.{h,cpp}` —— Linux 窗口几何抽象、Stick 启用、对话框置顶挂起
- `source/ui/ModuleWorkspace.{h,cpp}` —— Linux 下显示 Stick 按钮、Save 对话框
  parent 与打开/关闭通知、拼写与注释
