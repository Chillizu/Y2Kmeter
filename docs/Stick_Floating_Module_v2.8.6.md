# Stick 三槽布局与浮动模块独立存档（v2.8.6）

> 版本：v2.8.6 ｜ 涉及文件：`PluginProcessor.h/.cpp`、`PluginEditor.h/.cpp`、`source/ui/ModuleWorkspace.h/.cpp`、`source/ui/PinkXPStyle.h/.cpp`、`third_party/JUCE/modules/juce_gui_basics/menus/juce_PopupMenu.h/.cpp`
>
> 说明：代码内注释沿用本轮开发线的 `v2.8.5` 标记，本文按实际发布版本 **2.8.6** 记录。

---

## 一、背景

v2.8.1 引入 Stick（Windows AppBar 驻留）后，布局持久化只有一份 `savedLayoutXml`。条状窗口与常驻窗口形状完全不同，共用一份布局会导致：

- 进入 Stick 后条状布局覆盖普通布局，退出后原布局丢失；
- 普通态与 Stick 顶/底两侧互相覆盖；
- 脱离（pop-out）模块的记录混在布局里，切换 Stick 时被反复重建或丢失，表现为"删掉的模块又复活"。

本轮把**布局形态**与**脱离模块**彻底拆开：

1. 布局按窗口形态分三槽保存（普通 / Stick 顶 / Stick 底）；
2. 脱离模块不再属于任何布局槽，单独存档，切换 Stick 时不受影响；
3. 修复 Stick 驻留态下 ComboBox / 右键菜单被 AppBar 挤出窗口的问题；
4. 明确跨平台边界（macOS 无 Stick，行为保持不变）。

---

## 二、布局三槽

### 2.1 槽定义

```cpp
enum class LayoutSlot { normal = 0, stickTop = 1, stickBottom = 2 };
```

- `normal`：普通窗口；
- `stickTop`：Stick 顶(T)；
- `stickBottom`：Stick 底(B)。

### 2.2 当前活动槽

`Y2KmeterAudioProcessorEditor::activeLayoutSlot()`：

- Stick 激活时返回 1/2；
- 启动恢复窗口期（`pendingStickRestore`）提前返回 1/2，保证过渡态布局不会写进普通槽；
- 其它情况返回 0。

所有"保存当前布局"的路径统一走 `persistCurrentLayoutToProcessor()`，不再直接调 `processor.setSavedLayoutXml()`：

- `onLayoutChanged`
- `flushPendingUiStateBeforeSave`
- `applyLayoutPreset` 结束
- `saveStateAsSettingsFile`
- Editor 析构
- Stick 进入 / 退出 / T↔B 切换

### 2.3 存档格式

`getStateInformation()` 写入：

```xml
<PBEQ_State>
  <PBEQ_Layout>...</PBEQ_Layout>              <!-- 普通槽（旧存档兼容位） -->
  <PBEQ_LayoutStickTop>...</PBEQ_LayoutStickTop>
  <PBEQ_LayoutStickBottom>...</PBEQ_LayoutStickBottom>
  <PBEQ_FloatingModules>...</PBEQ_FloatingModules>
  ...
</PBEQ_State>
```

读盘时 `setStateInformation()` 把三个槽标签统一换回 `PBEQ_Layout` 再交给 `ModuleWorkspace::loadLayoutFromTree()`。

### 2.4 Stick 会话持久化

新增以下状态（均写入 `PBEQ_State`）：

| 键 | 含义 |
|---|---|
| `stickActive` | 上次退出时是否处于驻留态（决定重启是否自动驻留） |
| `stickBottom` | 驻留边：false=顶 T / true=底 B |
| `stickEditorHTop` / `stickEditorHBottom` | 顶 / 底各自记住的条高（Editor 逻辑高度，hide 态折算成 show 态） |
| `stickRestoreX/Y/W/H` | 进入 Stick 前的普通窗口 bounds |

启动流程：

1. 构造函数读取 `pendingStickRestore / pendingStickBottom`（仅 Windows / Standalone）；
2. `loadInitialModules()` 直接装载对应 Stick 槽（缺失则放弃自动驻留，回退普通槽）；
3. 窗口上屏后由 `timerCallback → restoreSavedStickSession()` 完成条状几何、AppBar 驻留、按钮组切换；
4. `pendingStickRestore` 在恢复期间阻止任何写盘，避免把过渡尺寸固化。

### 2.5 Stick UI

- `ModuleWorkspace::setStickActive(bool active, bool bottomAligned)`：同步按钮组、预设下拉（驻留态只保留当前一侧的 `HORIZONTAL BAR(T)/(B)` 一项）、并通知 LookAndFeel 当前驻留状态；
- `setStickUiVisible(bool)`：插件宿主（VST3/AU）下整组按钮隐藏且不占工具栏宽度，避免把宿主窗口注册成 AppBar；
- `applyStickBarGeometry()`：不重建布局，只把窗口铺成"屏幕宽 × 指定 Editor 高"并贴顶/贴底；
- 进入 / 退出 / T↔B 的顺序统一为：**先保存当前槽 → 切窗口几何 → 装载目标槽 → dock → 锁宽度**，避免模块坐标被旧 canvas 夹紧。

---

## 三、浮动模块独立存档

### 3.1 设计原则

> 脱离模块独立于布局管理：不属于 normal / stickTop / stickBottom 任何槽；切换 Stick、切换槽位都不会重建或丢失它们，但它们**仍然会写入存档**，重启后恢复。

### 3.2 实现

- `ModuleWorkspace::saveFloatingModulesTree()` / `saveFloatingModulesAsXml()`：根节点 `PBEQ_FloatingModules`，子节点为 `<Module floating="true" ...>`，记录：
  - `type` / `id`
  - dock 回位用的 workspace 内 `x/y/w/h`
  - 浮动窗口实际屏幕坐标 `sx/sy/sw/sh`
  - `<state>` 模块业务状态
- `loadFloatingModulesFromTree()` / `loadFloatingModulesFromXml()`：整体替换 `floatingModuleStates_`，并抬高 `nextIdCounter`，避免新模块 id 冲突。
- 布局槽的 `saveLayoutTree()` **只写 canvas 内模块**；`loadLayoutFromTree()` **不再清空、也不解析** 槽里的 floating 节点。
- `clearAllModules()` 不再清空浮动记录：切换布局预设 / 重建 Stick 条时，浮动窗口必须继续存在。

### 3.3 生命周期与写盘

- 弹出模块：`popOutModule()` 写入记录 → `notifyLayoutChanged()` → debounce 后 `persistCurrentLayoutToProcessor()`；
- 停靠模块：`dockModule()` 从记录移除并加回 canvas → 同样触发写盘；
- 关闭浮动模块（X）：Editor 调 `removeFloatingState(id)` → 触发写盘；
- `persistCurrentLayoutToProcessor()` 保存前统一 `syncFloatingWindowStatesToWorkspace()`，同步窗口真实位置与模块状态；
- 存档同时写：当前布局槽（canvas）+ `PBEQ_FloatingModules`（全局）。

### 3.4 启动与切换

- `loadInitialModules()` 在装载任何布局**之前**先 `loadFloatingModulesFromXml(processor.getSavedFloatingModulesXml())`，保证启动阶段 `applyLayoutPreset` 的写盘不会把记录覆盖成空；
- 窗口创建依赖 `onModulePopOutRequested`，因此统一放在构造流程后半段 `restoreFloatingWindowsFromWorkspace()`（`onModulePopOutRequested` 接线之后）；
- Stick 进入 / 退出 / T↔B：只换 canvas 布局，`floatingModuleStates_` 与浮动窗口保持不动；
- 导入 settings：读取 Processor 的独立存档后 `reloadFloatingModuleRecordsFromProcessor()` + `restoreFloatingWindowsFromWorkspace()` 对齐窗口。

### 3.5 旧存档迁移

- 旧版把 floating 节点写在布局里。`setStateInformation()` 在没有 `<PBEQ_FloatingModules>` 时，从 **normal 槽** 提取 `floating="true"` 的 `Module` 节点迁移到独立存档；
- **旧 Stick 槽里的 floating 记录一律忽略**——那正是"切换 Stick 后已删除模块复活"的来源；
- 导入旧版裸布局文件（`PBEQ_Layout`）时，`loadLayoutFromXml(xml, /*importLegacyFloating*/ true)` 会把浮动节点迁移进独立记录。

---

## 四、Stick 驻留态弹出菜单定位

### 4.1 根因

JUCE `PopupMenu::MenuWindow::getParentArea()` 把菜单窗口整体约束到 `display->userArea`。AppBar 驻留会把条带从系统工作区里挖掉，导致：

- 条带内的 ComboBox 下拉、右键"添加模块"菜单被整体推到条带上方，离控件/鼠标很远；
- 仅把锚点挪到交界线没有用——位置计算最终仍会 clamp 到工作区。

### 4.2 方案

给 JUCE 增加一个可选的约束区域覆盖：

```cpp
PopupMenu::Options::withParentAreaOverride (Rectangle<int> screenArea);
Rectangle<int> getParentAreaOverride() const noexcept;
```

`getParentArea()` 在 override 非空时改用它（默认空 → 行为与官方 JUCE 完全一致）。

应用侧：

- `PinkXPStyle.cpp`：Stick 态且 ComboBox 位于 `userArea` 之外时，把允许区域设为 `safeAreaInsets.subtractedFrom(totalArea)`，菜单按默认逻辑贴着下拉框展开（可以盖在条带上）；
- `ModuleWorkspace::showAddMenu()`：Stick 态同样放宽允许区域，右键菜单贴着点击位置弹出；
- 两处调用均用 `#if JUCE_WINDOWS` 包住，macOS 即使使用未打补丁的官方 JUCE 也能编译；JUCE 补丁本身也必须随仓库提交。

---

## 五、跨平台影响

| 项 | Windows | macOS |
|---|---|---|
| Stick / AppBar / 三槽 | 完整启用 | 全部在 `#if JUCE_WINDOWS` 内，不执行；`activeLayoutSlot()` 恒 0 |
| 浮动模块独立存档 | 启用 | 同样启用（Standalone 的 pop-out 在 mac 也可用） |
| 弹出菜单 override | AppBar 态生效 | 不生效；`isStickDockActive()` 恒 false |
| UI 密度缩放 | 用 `Display::totalArea`（避免 AppBar 压缩 userArea 误判矮屏） | 保持 `Display::userArea`（菜单栏 / Dock 属真实可用空间） |
| Stick 按钮 | Standalone 显示；插件宿主隐藏 | 按钮不创建 |

`resolveUiScaleArea()` 统一了两处缩放判据（构造函数初值与 `updateUiScaleForCurrentDisplay()`）。

---

## 六、关键代码位置

| 功能 | 位置 |
|---|---|
| 三槽枚举 / 布局存取 | `PluginProcessor.h:119-124`、`PluginProcessor.cpp:592-620` |
| Stick 会话字段 | `PluginProcessor.h:126-162` |
| 活动槽 / 统一写盘 | `PluginEditor.cpp:3858`（`activeLayoutSlot`）、`3874`（`persistCurrentLayoutToProcessor`） |
| 启动恢复 Stick | `PluginEditor.cpp:4306`（`restoreSavedStickSession`） |
| 浮动记录存档 | `ModuleWorkspace.cpp:3438`（save）、`3478`（load） |
| 布局加载 / 旧格式迁移 | `ModuleWorkspace.cpp:3251`、`3542` |
| 弹出菜单约束覆盖 | `third_party/JUCE/.../juce_PopupMenu.h`、`juce_PopupMenu.cpp` |
| ComboBox 菜单 | `PinkXPStyle.cpp` `getOptionsForComboBoxPopupMenu` |
| 添加模块菜单 | `ModuleWorkspace.cpp` `showAddMenu` |
| UI 缩放平台判据 | `PluginEditor.cpp:209` `resolveUiScaleArea` |

---

## 七、测试清单

### 布局与 Stick

1. 普通态调整布局 → 进入 Stick(T) → 调条高/模块 → 退出 → 普通布局逐像素恢复；
2. T/B 来回切换，两侧布局与条高互不覆盖；
3. Stick 中重启软件 → 自动恢复上次的边、条高、布局；
4. 插件宿主（VST3/AU）中不出现 Stick 按钮。

### 浮动模块

1. 普通态弹出模块 → 进入 Stick → 浮动窗口保持 → 退出 → 仍在；
2. Stick 中删除浮动模块 → 退出 Stick → 再进入 → 不复活；重启 → 不复活；
3. 普通态删除浮动模块 → 进入 Stick → 不复活；
4. Stick 中弹出新模块 → 退出 Stick → 仍以浮动窗口存在；
5. 重启（普通态 / Stick 态）后，浮动窗口位置、尺寸、模块业务状态恢复。

### 菜单

1. Stick(T)/(B) 下展开预设下拉，菜单贴着下拉框、可覆盖条带；
2. Stick 态右键"添加模块"，菜单贴着点击位置；
3. 浮动窗口内的下拉菜单行为与普通窗口一致。

### 跨平台

1. macOS 构建不再依赖 `withParentAreaOverride`（可用官方 JUCE）；
2. macOS UI 缩放档位不因本轮改动变化；
3. macOS Standalone 的浮动模块可跨重启恢复。

---

## 八、已知边界

1. **在 Stick 里把浮动模块停靠回条状画布**：该模块只进入当前 Stick 槽；退出 Stick 后普通布局里没有它（三槽是独立布局空间）。
2. **旧 Stick 槽里的 floating 记录被刻意忽略**：升级时只从 normal 槽迁移浮动模块；仅在 Stick 槽里出现过的历史浮动记录不会恢复。
3. 布局槽仍是"按形态独立"的：在 Stick 中新增/删除 canvas 模块，只影响当前 Stick 槽，不会同步到普通槽。
4. `third_party/JUCE` 的 `withParentAreaOverride` 是仓库内本地扩展，升级 JUCE 时需要重新应用。

---

## 九、版本与构建

- 版本：2.8.5 → **2.8.6**（`CMakeLists.txt` 三处、`Y2Kmeter_installer.iss`、`README.md`、`PluginEditor.cpp` 四处字面量）；
- Windows 构建：`cmake --build build/msvc --config Release --target Y2Kmeter_Standalone -j 8`（VST3 / milkdrop VST3 同理）；
- 安装包：`dist/Y2Kmeter_Setup_2.8.6_x64.exe`；
- **踩坑**：只改 `CMakeLists.txt` 后增量构建不会重写 JUCE 生成的 `*_resources.rc`，EXE/VST3 版本信息仍是旧值；需删除 `build/msvc/*/JuceLibraryCode/*_resources.rc` 后重新构建（或重新 configure）。
