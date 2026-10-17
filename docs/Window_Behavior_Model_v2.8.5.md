# 窗口行为模型重构（L / Hide / Stick）—— v2.8.5

> 版本：v2.8.5 ｜ 涉及文件：`PluginEditor.h`、`PluginEditor.cpp`、`source/ui/ModuleWorkspace.h/.cpp`、`source/standalone/Y2KStandaloneApp.cpp`

---

## 一、背景

Stick（AppBar 驻留）上线后，暴露出一组互相纠缠的窗口行为问题：

| # | 现象 | 影响面 |
|---|------|--------|
| 1 | 开启 Stick 后再开 Hide，鼠标每次移入窗口，窗口向下闪一下再恢复（后期恶化为连续多次闪现） | Stick + Hide 组合 |
| 2 | Stick 下右上角只剩 `L` / `X`，按钮排版未收拢 | Stick |
| 3 | 已脱离（浮动）的模块在进入 Stick 后丢失，退出 Stick 也无法恢复 | Stick + 脱离态 |
| 4 | 开启 Hide 后再关闭 `L`：窗口拖不动；强行拖动后会闪回原位 | Hide + L |

问题 2 / 3 已在上一轮修复（按钮几何按 stick 状态重算；浮动模块状态在 stick 切换与预设重建前后快照/写回）。
问题 1 / 4 的根因都不在各自功能内部，而在 **L / Hide / Stick 三者共用同一批窗口几何手段**（`setResizeLimits`、`setBounds`、悬停时翻转 chrome 可见性），互相污染。因此本轮不是打补丁，而是重新定义三者的职责边界。

---

## 二、根因分析

### 2.1 Stick 下窗口向下闪现

`juce::ResizableWindow` 默认给顶层 constrainer 设置：

```cpp
constrainer.setMinimumOnscreenAmounts (0x10000, 16, 24, 16); // top, left, bottom, right
```

含义是「窗口顶边必须完整落在 `display->userArea` 内」。而 **AppBar 驻留后，工作区已经被自己的占位从顶部（或底部）压缩掉了整整一条窗口高度**。于是：

1. 任何走 `setBoundsConstrained` 的路径（`setResizeLimits` 内部会调用、`ResizableWindow` 的边框拖拽、以及 Windows peer 在 `WM_WINDOWPOSCHANGING` 里的 constraining）；
2. 都会把窗口 `y` 夹到 `userArea.getY()`，即「占位厚度」处；
3. 下一轮 tick 里 `updateStickDockGeometry()` 又把窗口搬回 `stickDockRectPx`；
4. 若该路径被 Hide 的悬停逻辑反复触发，就变成**连续多次闪现**。

旧版试图用「stick 时跳过 `setResizeLimits`」绕开，但 Hide 的悬停逻辑本身仍在改 limits / resize，因此无效。

### 2.2 Hide 悬停抖动

旧 Hide 实现把「chrome 是否可见」当作唯一的窗口状态量，悬停时真的去：

```
改 chromeVisible → resize 窗口（±62px）→ 改 resizeLimits → 触发 mouseEnter/Exit → 再次改状态…
```

窗口一 resize，鼠标相对窗口的位置就变，进而产生新的 enter/exit 事件，形成正反馈。计时器里还叠加了「焦点保护」自动 show/hide 的纠偏逻辑，进一步放大抖动。

### 2.3 L 与窗口限制耦合

旧 L 用 `setResizeLimits(w, h, w, h)` 把窗口锁成固定尺寸。副作用：

- `setResizeLimits` → `setBoundsConstrained` → 窗口被夹进（可能已被 stick 压缩的）工作区；
- 解锁时若窗口处于 Hide 态，快照的尺寸/位置已经失真，`setBounds` 回去就表现为「拖一下又闪回原位」；
- 拖窗逻辑还在 `mouseDown` 里被 L 拦住，用户看到的是「拖不动」。

---

## 三、新模型（v2.8.2 设计，v2.8.5 发布）

三者的职责严格分离：

| 能力 | 负责者 | 具体手段 |
|------|--------|----------|
| 禁止拖窗 / 禁止缩放 / 禁止编辑模块 | **L** | 交互闸门（不碰任何几何与 limits） |
| 收起标题栏与工具栏 | **Hide** | 一次性收缩窗口；悬停只用浮层，不改几何 |
| 贴边驻留、宽度铺满 | **Stick** | AppBar 占位，仅在几何真正变化时重提交 |

### 3.1 L —— 纯交互闸门

- `applyLayoutLocked(locked, initial)`：同步 `workspace->setLayoutLocked()` 与所有浮动窗口，调用 `applyUserResizeGate()`，持久化 `layoutLocked`，重绘标题栏。**不再调用 `setResizeLimits`，也不再移动窗口。**
- `applyUserResizeGate()`：遍历 Editor 与顶层窗口的子组件，把 `ResizableCornerComponent` / `ResizableBorderComponent` 设为 `setInterceptsMouseClicks(allow, false)` + `setAlpha(allow ? 1 : 0)`。插件宿主形态直接 return（窗口归宿主管理，L 只锁模块编辑，与旧行为一致）。
- `childrenChanged()` override：`AudioProcessorEditor::setResizeLimits` 每次都会重建右下角手柄，因此子组件变化后重新套一次闸门。
- 拖窗在 `mouseDown` 里由 `layoutLocked` 早退；双击伪全屏也新增了 `layoutLocked && !pseudoFullScreen` 早退。

因为不再改 limits，解锁后不会再有「被拉回原位」；Hide 与 L 也不再共享任何尺寸快照。

### 3.2 Hide —— 几何收缩 + 悬停浮层

**进入 / 退出（一次性）**：`setAutoHideMode(shouldHide)`

1. 清空所有按钮 hover/pressed 残留、复位 `draggingWindow`、收起浮层；
2. 计算锚点：Stick 时用驻留边（`stickBottomAligned`）；否则窗口中心在上半屏固定顶边、下半屏固定底边；
3. 基于**当前**窗口高度 ± `getChromeHeightPx()`（= `PinkXP::ui(26) + PinkXP::ui(36)`，与 Standalone 端 `kChromeShrink` 一致）算出新 bounds 并 `setBounds`；
4. Hide 时把 Editor 的 `minH` 放宽一个 chrome（保存到 `hideSavedMin*`），Show 时还原 —— 只放宽高度，宽度锁（stick）不受影响；
5. Stick 下调用 `redockStickAfterGeometryChange()` 重新提交占位厚度；
6. 更新 `chromeHiddenOverlay` 可见性、`resized()`、`repaint()`、`updateWorkspaceHitTestHoles()`；
7. Hide 时自动置顶（沿用旧行为），并启动 30Hz `chromeRevealPoller`；Show 时停表。

**悬停（不改几何）**：`updateChromeReveal()`

- 30Hz 轮询鼠标是否落在顶层窗口的 screen bounds 内（不依赖任何 enter/exit 事件，因此窗口 resize 不会造成误判）；
- 离开有 250ms 宽限期，鼠标擦过边缘不闪烁；
- 鼠标按下 / 有 modal 组件时维持现状（拖窗、选下拉菜单过程中浮层不消失）；
- 刚点完 Hide 时鼠标通常还在窗口内，因此 `revealArmed=false`，必须先离开窗口一次才允许浮现。

浮现时：

- `workspace->setToolbarOverlayRevealed(true)` → 工具栏（含 Stick / Hide 按钮）以**浮层**形式绘制在模块之上，并在其后绘制 `ToolbarOverlayBackdrop`（半透明底 + 投影）；
- Editor 在 `paintOverChildren()` 里绘制标题栏，保证盖在模块之上；
- `workspace->setOverlayPassThroughRect(titleBar)` → `hitTest` 在标题栏区域返回 false，点击穿透到 Editor，标题栏上的 `L` / `X` / 拖窗全部可用。

**关键点**：整个悬停过程窗口 bounds、resizeLimits、TopLevelWindow 位置都不变，因此不存在「反复触发 constraining → 闪现」的通道。

### 3.3 Stick —— AppBar 驻留

- `setStickOnscreenRelaxed(true/false)`：进入 Stick 时保存并清零顶层 constrainer 的四个 `MinimumWhenOffThe*`，退出时还原。这是问题 1 的**直接修复点**（见 2.1）。
- `redockStickAfterGeometryChange()`：立即重跑 `y2kAppBarDock()`，同步 `stickDockedHeightPx / stickPendingHeightPx / stickStableTicks`。只在 Hide 切换这类「几何真正变了」的时机调用。
- `updateStickDockGeometry()`（10Hz）：高度变化需稳定 2 个 tick（~200ms）才重新 `SETPOS`；窗口被挪走则搬回 `stickDockRectPx`。
- 进入 / 退出 / T·B 切边时若处于 Hide 态，采用**展开 → 执行 → 再收起**的包裹顺序，保证备份的窗口 bounds 与 limits 永远是 Show 态的值，Hide 的 limits 快照始终嵌套在 Stick 之内。

### 3.4 组合矩阵

| 场景 | 行为 |
|------|------|
| Stick 开 + Hide 开 | 窗口高度 = 常驻条 − chrome；鼠标移入 → 浮层；不重提交占位 |
| Stick 开 + Hide 下拖高度 | 稳定 200ms 后 AppBar 占位跟随新高度 |
| Hide 态下进入 / 退出 Stick | 先展开、执行、再收起；退出后回到进入前尺寸并重新 Hide |
| L 开 + Hide 开 | 可拖窗（在浮现的标题栏上）、不可缩放、不可编辑模块 |
| L 开 + 双击标题栏 | 忽略（已有伪全屏时允许退出） |

---

## 四、逐文件改动

### 4.1 `PluginEditor.h`

- 删除：`windowWasForeground`、`suppressAutoShowCounter`、`autoHideNeedsExitFirst`、`temporaryChromeShow`、`hasSavedBoundsBeforeHide`、`savedTopBoundsBeforeHide`、`savedResizeM*`、`savedLock*`、`pendingLockApplyOnAttach`、`TopLevelExitWatcher`、`AutoHideChildWatcher`。
- 新增 Hide 状态：`chromeDim`（几何已收缩）、`autoHideMode`（模式开关）、`chromeRevealed`（浮层是否浮现）、`revealArmed`、`revealLastInsideMs`、`hideLimitsSaved` / `hideSavedMinW..MaxH`、`LambdaTimer chromeRevealPoller`。
- 新增方法声明：`paintOverChildren()`、`childrenChanged()`、`applyUserResizeGate()`、`getChromeHeightPx()`、`setAutoHideMode()`、`setChromeRevealed()`、`updateChromeReveal()`、`isTitleBarInteractive()`。
- Stick 侧新增：`redockStickAfterGeometryChange()`、`setStickOnscreenRelaxed()`、`stickSavedOnscreenTop/Left/Bottom/Right`、`stickOnscreenSaved`。

### 4.2 `PluginEditor.cpp`

- **旧 Hide 状态机整段删除**：约 400 行的 `onChromeVisibleChanged` 状态机替换为一行 `setAutoHideMode(!visible)`；`workspace->onMouseEntered / onMouseMoved / onMouseExited` 全部置空。
- **定时器清理**：删除「v1.8.6 焦点保护」块（自动 show/hide 纠偏）与 `suppressAutoShowCounter` 递减。
- **L 重写**：`handleLockClicked` / `applyLayoutLocked` 精简为「同步 workspace + 闸门 + 持久化 + 重绘」；新增 `applyUserResizeGate()`、`childrenChanged()`。
- **Hide 新增**：`setAutoHideMode()`、`setChromeRevealed()`、`updateChromeReveal()`、`getChromeHeightPx()`。
- **绘制**：`paint()` 中 `if (!chromeDim) drawTitleBar(g)`；新增 `paintOverChildren()`；原内联标题栏绘制抽成 `drawTitleBar(g)`。
- **鼠标**：`mouseDown` / `mouseUp` / `mouseMove` 的隐藏态分支统一为 `chromeDim && !chromeRevealed`；`mouseDoubleClick` 增加 `layoutLocked` 早退。
- **Stick**：新增 `setStickOnscreenRelaxed()` 与 `redockStickAfterGeometryChange()`；`enterStickMode` / `exitStickMode` / `toggleStickTopBottom` 增加 Hide 包裹；dock 失败回滚时恢复 onscreen 设置。
- **伪全屏**：`toggleFakeFullScreen()` 退出路径不再处理 `savedLock*`（L 已不改 limits），只还原进入前的 limits。

### 4.3 `source/ui/ModuleWorkspace.h/.cpp`

- 新增工具栏浮层：`setToolbarOverlayRevealed()` / `isToolbarOverlayRevealed()` / `raiseToolbarOverlay()` / `setOverlayPassThroughRect()`、`ToolbarOverlayBackdrop`（半透明底 + 投影）、`paintToolbarBackground()`。
- 工具栏显示条件收敛为 `isToolbarShown()` = `!minimalMode_ && (chromeVisible || toolbarOverlayRevealed)`。
- Hide 态下 Stick 按钮与 Hide 按钮一并隐藏（不再保留旧的「悬浮 Show 按钮」）。
- `hitTest` 命中 `overlayPassThroughRect` 时返回 false（标题栏区域点击穿透到 Editor）。
- 模块 `toFront()` 后，浮层显示时调用 `raiseToolbarOverlay()`，否则 `hideBtn.toFront()`，保证浮层始终在模块之上。
- `setChromeVisible()`：可见时清除浮层状态；按钮文案 `Hide` / `Show`。

### 4.4 `source/standalone/Y2KStandaloneApp.cpp`

- 仅注释更新：`kChromeShrink` 说明改为「必须与 `Editor::getChromeHeightPx()` 一致」，锚点说明改为「与 `setAutoHideMode` 的判定一致」。逻辑不变。

---

## 五、存档兼容

| 键 | 语义 | 变化 |
|----|------|------|
| `ui.chromeVisible` | Hide 开关 | 不变 |
| `layoutLocked`（Processor state） | L 开关 | 不变（但不再影响窗口 limits） |
| `window.{x,y,w,h}` | 窗口 bounds，**始终按 Show 态等效尺寸保存** | 不变 |
| `ui.alwaysOnTop` / `ui.fpsLimit` / `milkdrop.*` | — | 不变 |

- 退出时若处于 Hide 态，`saveMainWindowBounds()` 仍按 `kChromeShrink` 反算回 Show 态尺寸；启动时 `restoreMainWindowBounds()` 恢复 Show 态，再由 `setChromeVisible(savedChrome)` 走标准收缩路径还原 Hide 态。
- 老用户升级后：Hide / L 状态与窗口位置看起来与升级前一致；差别只在交互细节（L 下不再锁死尺寸、Hide 下不再改窗口几何）。

---

## 六、边界与已知约束

1. **插件宿主形态**：`isPluginHost` 时 L 仍只锁模块编辑（窗口尺寸归宿主），Hide 不做窗口收缩，只切换 workspace 的 chrome 显示。
2. **Stick 仅 Windows**：非 Windows 下 `stickActive` 恒 false，所有相关分支被 `#if JUCE_WINDOWS` 隔离。
3. **Stick 下双击标题栏**：直接忽略（全屏会破坏 AppBar 占位）。
4. **Hide 自动置顶**：进入 Hide 时强制置顶，退出后不自动取消（与旧行为一致）。
5. **切换布局预设会先退出 Hide**：`applyLayoutPreset` 依赖 Show 态反推 canvas overhead，因此预设切换时自动展开 chrome（与旧行为一致）。

---

## 七、测试清单

1. **Hide 基本**：点 Hide → 收缩；鼠标移入 → 标题栏 + 工具栏浮出且窗口不动；移出 → 收起；快速划过边缘不闪烁。
2. **Hide + 拖窗**：浮现后拖标题栏 → 窗口跟随；松手不回弹；四边吸附仍生效。
3. **Hide + 缩放**：右下角手柄可调高度；`L` 开启后手柄消失且无法缩放。
4. **Hide + L 交叉**：开 Hide → 开关 L 若干次 → 拖动标题栏，确认始终可拖、松手不回弹。
5. **Stick 基本**：进入 → 贴边、宽度铺满工作区；鼠标移入移出，窗口不闪。
6. **Stick + Hide**：开 Hide → 反复移入移出，窗口**零位移**；拖高度后 200ms 占位跟随。
7. **Stick 切边**：T↔B 切换后重复 5 / 6。
8. **手动拖窗检测**：Stick 下用 Win32 外部工具移动窗口，确认被搬回驻留矩形。
9. **浮动模块**：脱离模块 → 进入 Stick（模块仍浮动）→ 退出 Stick（布局与浮动窗口恢复）→ 再进入/退出一次。
10. **存档**：Hide 态下退出程序 → 重开；以及 Stick 态下退出 → 重开；检查窗口尺寸与 chrome 状态。

---

## 八、版本号

- 2.8.1 → **2.8.5**：`CMakeLists.txt` 三处（`project(... VERSION)` + 两个 `juce_add_plugin(... VERSION)`）、`Y2Kmeter_installer.iss`、`README.md` 徽章、`PluginEditor.cpp` 四处版本字面量、`docs/Spectrogram_Reassignment_Spectrogram.md`（历史文档，保留原版本）。
- 安装包：`dist/Y2Kmeter_Setup_2.8.5_x64.exe`（Standalone + 完整版 VST3 + milkdrop-only VST3）。
- 注意：修改版本号后**必须重新 configure**（`cmake --preset msvc`），因为 JUCE 生成的 `*_resources.rc` 只在文件缺失或被判定过期时重写；仅 `cmake --build --target ...` 可能沿用旧版本资源。
