# Spectrogram 重分配谱图（Reassigned Spectrogram）显示模式

> 版本：v2.8.1 ｜ 模块：`SpectrogramModule`（2D 瀑布图）+ `AnalyserHub`（音频分析后端）

---

## 一、功能概述

Spectrogram（2D 频谱瀑布图）新增**显示模式切换**，参考 MiniMeters 的 Classic / Sharp / Sharper 三档：

| 模式 | 按钮文字 | 含义 |
|------|----------|------|
| Classic | `-` | 原始 STFT 幅度谱（不重分配） |
| Sharp | `+` | 频率重分配（reassigned spectrogram），能量凝聚成粒子 |
| Sharper | `++` | 频率 + 时间重分配（时间重分配暂同 Sharp，待后续） |

- 按钮位于模块右下角（样式/位置对齐 Spectrogram3D 模块的 TINT）。
- 三态循环：`- → + → ++ → -`，点击一次切一档；**默认 `+`（Sharp）**。
- 效果：对稳态正弦/复音，重分配把因频谱泄漏而扩散的能量重新"凝聚"到真实
  瞬时频率处，从"脏热点"变成"高分辨率粒子 / 细亮线"。

---

## 二、技术实现

### 2.1 后端（AnalyserHub）

1. **低频路 FFT 改 RealOnly**：`performFrequencyOnlyForwardTransform` →
   `performRealOnlyForwardTransform(..., true)`，保留 re/im（虚部）。
   - 主路 `magData` 语义不变（`sqrt(re²+im²)·2/fftSize`，与原 FrequencyOnly 等价）。
2. **低频路复频谱**：新增 `specReLo/specImLo`（当前帧）+ `prevSpecReLo/prevSpecImLo`
   （上一帧），在 `specLock` 下滚动发布；`specReLoWorkPrev/Work` 维护"相邻帧对"，
   避免一个音频块内多次 FFT 触发导致跳帧。
3. **重分配接口** `getSpectrumReassignedBlended(dest, numPoints, fMin, fMax)`：
   相位差法（phase-vocoder）估计瞬时频率，把能量散射到对数频率轴。

### 2.2 重分配算法（核心）

对每个 bin k：

```
Δφ = princarg( arg(X_cur·conj(X_prev)) − 2π·k·hop/N )   // heterodyne 修正
f̂ = f_k + Δφ·fs / (2π·hop)
```

- **heterodyne 修正项 `−2π·k·hop/N` 是成败关键**：JUCE 的 FFT 是"切片式"
  （窗口固定、帧信号为 `x[n+t]` 切片），其相邻帧相位差 `= 2π·f0·hop/fs` 与 bin
  无关、且对 `f0 > fs/(2·hop)` 全部折叠。必须减去"bin k 固有频率在 hop 内的
  自然相位推进"，才能得到真正的瞬时频率偏移（标准 Fitz-Haken 公式）。
- **相干性过滤**：只散射"与左/右任一邻居的瞬时频率差 ≤ 1 bin"的 bin，去除
  超出无折叠范围（`±fs/(2·hop)`）的折叠伪影。
- **帧内相对门限 −30dB**：压掉相邻旁瓣折叠到同一镜像位置的暗线。

### 2.3 为什么用低频路（8192 FFT、75% overlap）

相位差法无折叠范围 `|Δf| ≤ fs/(2·hop)`：

- 主路 2048 FFT 非重叠（hop=2048）→ 仅 ±0.5 bin，主瓣边缘全折叠；
- 低频路 8192 FFT @ 75% overlap（hop=2048）→ ±2 bin，覆盖 Hann 主瓣。

同时低频路 bin 分辨率 5.86Hz（主路 23.4Hz），粒子更细。

### 2.4 UI（SpectrogramModule）

- `DisplayMode` 枚举 + `modeBtn`（右下角）+ `setDisplayMode()`。
- `onFrame` 按模式选数据源：Classic → `getSpectrumMagnitudesBlended`；
  Sharp/Sharper → `getSpectrumReassignedBlended`。
- 切换模式后旧列随滚动自然过渡（历史数据无法重算，重分配依赖相位历史）。

---

## 三、修复历程（复盘）

| 阶段 | 问题 | 根因 |
|------|------|------|
| v1 | 只"变锐利"不"粒子" | 误用幅度域 unsharp 锐化（能量留在原 bin） |
| v2 | 影响其他模块 | `specData` 读错位（fftData 改 re/im 交错后仍当幅度读） |
| v3 | 高低频反了 | 散射行序 `(1-t)` 与 `getSpectrumMagnitudesBlended` 约定相反 |
| v4 | 低频 10 条线 | 瞬时频率系数单位错误（偏移缩小 ~550 倍） |
| v5 | 10 条等间隔线 | 相位差折叠伪影（缺相干过滤） |
| v6 | Sharp 全空 | 漏 heterodyne 修正项（f̂ 全错 → 相干过滤全拒） |

最终形态：低频路复频谱 + heterodyne 修正 + 相干过滤 + 相对门限，C2 正弦波收束
成一根线。

---

## 四、涉及文件

- `source/analysis/AnalyserHub.h/.cpp`：低频路复频谱 + 重分配接口 + FFT 改 RealOnly。
- `source/ui/modules/SpectrogramModule.h/.cpp`：DisplayMode + 模式按钮 + 数据源切换。
- `CMakeLists.txt` / `README.md` / `Y2Kmeter_installer.iss`：版本号 2.8.0 → 2.8.1。

## 五、后续待办

- **Sharper 时间重分配**：群延迟 `t̂ = t − dφ/dω` 的时间轴重分配（需跨列散射），
  当前 `++` 暂同 `+`。
- **显示层 bloom**：若需 MiniMeters 的"发光"观感，在显示层加强度曲线（`t01²`）、
  峰值保持拖尾、高能量亮色。
