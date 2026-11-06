<p align="center"><img src="docs/icon.png" width="128" alt="Agent Lumen icon"></p>

<h1 align="center">Agent Lumen · 灵光</h1>

<p align="center">让 AI 编程助手的状态，化成屏幕边缘的一圈光，也能点亮你的 NuPhy 键盘。<br>
A glow around your screen edge, and on your NuPhy keyboard, that tells you what your AI coding agents are doing.</p>

<p align="center"><a href="https://github.com/hongqi7/agent-lumen/releases/latest"><b>⬇︎ 下载 Download</b></a></p>

![preview](docs/preview.png)

> English is [below](#english).

## 它做什么

你让 Claude Code、Codex、Gemini CLI 等 AI 工具去执行任务，自己切到别的窗口。Agent Lumen 用灯光告诉你它当前的状态，你不用来回切换窗口查看。灯光会出现在三个位置：菜单栏图标、屏幕四周边缘、NuPhy 键盘。

| 状态 | 含义 | 灯光 |
|---|---|---|
| 🔵 **待确认** | AI 助手正在等你批准操作或回答问题 | 蓝色呼吸灯，周期 1.2 秒 |
| 🟠 **执行中** | AI 助手正在思考、运行命令或修改文件 | 橙色呼吸灯，周期 2 秒 |
| 🟢 **已完成** | AI 助手已完成本轮任务，等你查看结果 | 绿色呼吸灯，周期 3 秒 |
| 空闲 | 暂无进行中的任务 | 菜单栏图标的光圈显示蓝、绿、橙三色，不呼吸；屏幕边缘不亮；键盘恢复你原本设置的灯效 |

三个位置使用同一条明暗曲线（取自键盘固件），节奏完全一致。

## 设置面板

点击菜单栏图标打开设置面板。面板中央是一块小屏幕和一把键盘的实景预览，按所选状态的颜色、亮度和节奏实时发光；各项说明可将鼠标悬停在 ⓘ 上查看。

- **选择状态**：预览下方的「待确认」「执行中」「已完成」三个标签切换要设置的状态，打开面板时默认选中当前状态。面板的主题色随所选状态变为蓝、橙或绿。
- **显示位置**：「屏幕边缘」「键盘呼吸灯」分别控制该状态是否在屏幕边缘和键盘呼吸灯上发光，点一下切换。键盘呼吸灯在 Halo65 V2 上指左上角灯条，在 Air60 V2 上指两侧灯条。第三个方块「按键背光」控制按键和光环（HALO 标志没有独立灯珠，随光环亮灭），三种状态共用：使用 2026-11-04 之后的 Halo65 V2 固件时，关闭后按键和光环全黑；旧固件关闭后只是不再显示状态颜色，按键恢复键盘自身的灯效（NuPhy 默认灯效只点亮 F、J、↑，呈蓝色）。
- **发光的显示器**：连接两台及以上显示器时，面板中列出每台显示器，点按钮分别选择是否发光，对三种状态统一生效。设置按显示器记录，拔掉再接上、重启电脑后保持不变；新接入的显示器默认发光。
- **亮度**：每种状态各有一个亮度。拖动滑块时，预览和屏幕边缘立即按新亮度显示；键盘通过 USB 有线连接时同步调整。
- **屏幕绿光自动关闭**：你离开电脑期间，绿光保持显示。你回到电脑前、操作鼠标或键盘后，按所选时间关闭，可选「立即」「8 秒后」「30 秒后」「不关闭」，默认 8 秒后。之后如有其他会话完成，绿光重新显示。绿光显示期间，这一项旁边有「立即关闭」按钮。
- **键盘绿光自动关闭**：规则和选项与屏幕相同，两者各自计时，默认「不关闭」。关闭后键盘恢复未执行任务时的灯效。菜单栏图标不受这两项影响，保持绿色直到下一项任务开始。
  - 判断你是否在电脑前，只读取系统记录的「距上次操作的秒数」，不需要额外权限，不读取按键内容。
- **外观**：设置面板默认跟随系统，macOS 切换浅色或深色（夜间）外观时自动跟着变；也可用面板底部「外观」的三个按钮固定为浅色或深色。只影响设置面板，不影响屏幕边缘发光、键盘灯和菜单栏图标。
- **AI 助手**：面板中的这一行显示已接入的工具，点开后可用开关逐个接入或断开。开关后不用重启 App；已打开的会话需重新打开后生效。没装的工具折叠在底部。
- **多个会话、多个助手同时运行**：显示其中优先级最高的状态，顺序为 待确认 > 执行中 > 已完成。
- 屏幕边缘的灯光**不拦截鼠标点击**，在多块屏幕、全屏应用中都会显示。
- 资源占用很低：只在有灯光变化时刷新，实测 CPU 约 1%。不联网，不收集任何数据。

## 支持的 AI 工具

| 工具 | 配置文件 | 说明 |
|---|---|---|
| Claude Code（命令行、桌面版 Code 页、IDE 插件） | `~/.claude/settings.json` | |
| Codex（命令行、桌面版） | `~/.codex/hooks.json` | 接入后需在 Codex 里输入 `/hooks`，或打开桌面版「设置 → Hooks」，信任一次钩子 |
| Gemini CLI | `~/.gemini/settings.json` | |
| Qoder | `~/.qoder/settings.json` | |
| WorkBuddy | `~/.workbuddy/settings.json` | |
| Devin（本机会话） | `~/.config/devin/config.json` | 首次运行时，Devin 会询问是否「信任此工作区」，需选择信任；云端会话不会触发灯光 |
| ZCode | `~/.zcode/cli/config.json` | 接入时会打开 ZCode 的钩子总开关；断开时只移除 Agent Lumen 的钩子，总开关保持打开 |

Codex、Gemini CLI、Qoder、ZCode 是 v1.9.0 新增的，按各工具的官方文档接入，尚未逐一实机验证。如果某个工具的灯不亮，欢迎提 Issue。

这些工具都有「钩子」（hook）机制：在你发送消息、调用完一个工具、请求权限、完成一轮回复时，各运行一条命令。Agent Lumen 添加的就是这几条命令，它们只往 `~/.agent-lumen/sessions/` 写入一个表示状态的单词，不保存对话内容。

## 安装

1. 到 [Releases](https://github.com/hongqi7/agent-lumen/releases/latest) 下载 `AgentLumen-x.y.z.zip`，解压后把 **Agent Lumen.app** 拖进「应用程序」文件夹。
2. 首次打开：本 App 未经苹果公证，macOS 会提示「无法验证开发者」。请**右键点击 App，选择「打开」，再点「打开」**，只需操作一次。
   也可以在终端执行：
   ```bash
   xattr -dr com.apple.quarantine "/Applications/Agent Lumen.app"
   ```
3. 打开后，App 会列出检测到的 AI 工具，询问是否连接，点「接入」。修改前会自动备份原配置文件（文件名为 `*.bak-agent-lumen-时间戳`，保留最早的一份和最近的四份）。App 更新后如果钩子有变化，打开时会自动更新已接入的工具，同样先备份。App 只改文件里的 `hooks` 一段，其余内容、键的顺序和注释都不动；`hooks` 一段里的注释不会保留。配置文件是软链接时，链接保持不变，改动写入它指向的文件。
4. 连接前已经打开的会话，需要重新打开后才会触发灯光。
5. 菜单栏出现一个黑色显示器小图标即表示 App 正在运行。屏幕里有一圈光，平时是蓝、绿、橙三色，有任务时变成状态色并呼吸。菜单栏偏深或是彩色时屏幕半透明，以融入底栏。点击它可打开设置面板。

> 菜单栏图标较多时，新图标可能被 Bartender、Ice 等工具折叠，请把它拖出来。

支持 macOS 13 及以上版本，Apple 芯片和 Intel 芯片均可使用。

## 断开与卸载

- 在设置面板的「AI 助手」里关闭对应开关，即可移除该工具的钩子；也可以在终端执行：
  ```bash
  "/Applications/Agent Lumen.app/Contents/MacOS/AgentLumen" --disconnect
  ```
- 然后退出 App，删除 `Agent Lumen.app` 和 `~/.agent-lumen` 文件夹；开启过「开机自动启动」的，再删除 `~/Library/LaunchAgents/io.github.hongqi7.agent-lumen.plist`。

## NuPhy 键盘灯

Agent Lumen 也是 [nuphy-air60-v2-claude-light](https://github.com/hongqi7/nuphy-air60-v2-claude-light) 的 Mac 端控制程序。给 NuPhy Air60 V2 或 Halo65 V2 刷入该项目的固件后，键盘侧边灯条（Halo65 为整圈光环）会和屏幕同时亮灯，两者**共用同一套钩子**，颜色和节奏完全一致。

- **工作原理**：Mac 通过 Num Lock、Scroll Lock 两个指示灯信号（macOS 不使用这两个键）告诉键盘当前状态，USB 有线、蓝牙、2.4G 无线连接都能传送。键盘断开重连（休眠唤醒、切换连接方式）后，App 会自动重新发送状态。
- **按键背光**（面板中的方块）：开启时，按键和光环显示状态颜色；关闭时的效果取决于固件，见上文「显示位置」。三种状态共用此设置。
- **亮度需在 USB 有线连接时写入键盘**，因为键盘的无线模块只转发指示灯信号。「键盘呼吸灯」「按键背光」用两个闲置的指示灯位传送，Halo65 V2 刷入 2026-11-04 之后的固件并插线连接一次后，蓝牙下也能立即切换；其他固件仍需插线写入按键背光。之后改用蓝牙或 2.4G 无线连接，键盘会继续使用最后一次写入的设置；无线连接期间在面板中修改的设置，会在下次插上 USB 线时自动写入。需要 2026-11-03 之后的键盘固件。
- **输入监控权限**：第一次连接 NuPhy 键盘时，macOS 会请求「输入监控」权限。这是 macOS 允许 App 设置键盘指示灯的前提。Agent Lumen **只设置指示灯，不读取任何按键**。授权后需重新打开一次 App。
- **更新 App 后键盘灯不亮**：macOS 把这项权限绑定在 App 的签名上，未付费签名的 App 每个新版本签名都不同，权限会失效。请到「系统设置 → 隐私与安全性 → 输入监控」，选中旧的 Agent Lumen 点「−」删除，再重新打开 App 并点「允许」。诊断日志位于 `~/.agent-lumen/lumen.log`。
- 自己编译时，`./build.sh install` 会用钥匙串里的 Apple 开发证书（如有）给本机这份 App 签名，这样之后重新编译不会丢失权限。
- 以前安装过键盘灯项目自带钩子（`claude-light`）的，「AI 助手」页会显示「检测到旧版钩子」。点「更新」，即可换成共享钩子并删除旧钩子；键盘灯项目的后台程序也可以停用了。

## 自己编译

```bash
git clone https://github.com/hongqi7/agent-lumen.git
cd agent-lumen
./build.sh            # 生成 build/Agent Lumen.app 和 zip（通用二进制）
./build.sh install    # 顺便装到 /Applications 并打开
```

只需要 Xcode 命令行工具（`xcode-select --install`），没有任何第三方依赖。代码就一个文件：[`Sources/AgentLumen.swift`](Sources/AgentLumen.swift)；钩子脚本是 [`Resources/lumen-hook`](Resources/lumen-hook)；图标由 [`scripts/make-icon.swift`](scripts/make-icon.swift) 画出来。

## 已知限制

- 按 Esc 中断 Claude 时，不会触发「完成」钩子，状态会停在「执行中」；超过 2 小时没有新的状态，会自动按「已完成」处理。「待确认」可能本来就要等很久，超过 24 小时才这样处理，所以在批准提示处按 Esc 后如果不再继续这个会话，蓝灯最多保留 24 小时。
- Claude Code 弹出提问框、计划确认或屏幕接管确认时，按「待确认」显示。
- Claude Code 在回复正文中以文字向你提问（而不是弹出提问框）时，按「已完成」处理。
- ZCode 没有会话结束事件，App 改为查看它的进程，进程退出后清除状态。如果只是关闭窗口而进程还在，最后的状态最多保留 2 小时（「待确认」最多 24 小时）。
- Gemini CLI 的钩子文档没有明确写批准提示何时触发，「待确认」以实际表现为准。
- 只做了 macOS。

---

## English

You hand a task to Claude Code, Codex, Gemini CLI or another agent and switch to another window. Agent Lumen shows its state as a colour, in the menu bar and as a soft glow around the edge of every screen:

| State | Glow |
|---|---|
| 🔵 **Needs you**: a permission prompt or a question | blue, fast breathing |
| 🟠 **Working**: thinking or running tools | orange, breathing |
| 🟢 **Done** | green, slow breathing |

The menu bar icon (a monitor with a glowing ring inside, which takes the state's colour; its screen is black on a light bar and see-through on a dark or coloured one), the screen glow and a NuPhy keyboard flashed with [nuphy-air60-v2-claude-light](https://github.com/hongqi7/nuphy-air60-v2-claude-light) all use the same breathing curve and timing.

- Each colour has an on/off switch and a stepless brightness slider (drag to preview).
- Green goes away once you've seen it: if you're away when a task finishes, the screen stays green until you're back; after you touch the mouse or keyboard it fades out 8 seconds later (or at once, after 30 seconds, or never: your choice in the panel). The keyboard has the same choice on its own timer, set to never by default. The menu bar stays green until the next task. Presence is read from the system idle time only, never from keystrokes.
- The settings panel follows the system's light or dark appearance, or can be pinned to either.
- With two or more displays, choose which of them glow; the choice is remembered per display.
- Choose per state whether it shows on the screen edges and the keyboard's top lights (the top left strip on a Halo65 V2, the side lights on an Air60 V2). A third tile controls the keys and the halo ring, shared by all three states: with Halo65 V2 firmware from 2026-11-04 on, off means dark and switches right away over Bluetooth too (connect over USB once first); older firmware applies it over USB and shows the keyboard's own key effect when off. Click the menu bar icon to open the settings panel.
- The AI agents row opens a page with a switch for each agent, so you choose which ones to connect.
- Several sessions and agents at once: the most urgent wins (blue > orange > green).
- The glow is click-through and shows on every display and over full-screen apps. About 1% CPU, no network access, no data collection.

**Supported agents:** Claude Code (`~/.claude/settings.json`), Codex (`~/.codex/hooks.json`; trust the hooks once with `/hooks` or Settings → Hooks in the desktop app), Gemini CLI (`~/.gemini/settings.json`), Qoder (`~/.qoder/settings.json`), WorkBuddy (`~/.workbuddy/settings.json`), Devin local sessions (`~/.config/devin/config.json`; answer Devin's workspace trust prompt), ZCode (`~/.zcode/cli/config.json`; connecting turns on its hooks setting, and disconnecting leaves it on). Codex, Gemini CLI, Qoder and ZCode are new in v1.9.0: built from their official docs and not yet tested on each one. Agent Lumen adds a few hook commands that write a single word to `~/.agent-lumen/sessions/`.

**Install:** download the zip from [Releases](https://github.com/hongqi7/agent-lumen/releases/latest), unzip and move **Agent Lumen.app** to Applications. The app is not notarized, so the first time **right-click → Open → Open** (or run `xattr -dr com.apple.quarantine "/Applications/Agent Lumen.app"`). On first launch it offers to connect the agents it finds and backs up each settings file first. Only the `hooks` section is rewritten: everything else in the file, including key order and comments, stays as it was, and a settings file that is a symlink stays one. Restart sessions that were already open. macOS 13+, Apple silicon and Intel.

**Disconnect:** switch the agent off under AI agents in the panel, or run `"/Applications/Agent Lumen.app/Contents/MacOS/AgentLumen" --disconnect`. Then delete the app, `~/.agent-lumen` and, if you enabled it, `~/Library/LaunchAgents/io.github.hongqi7.agent-lumen.plist`.

**Build:** `./build.sh` (needs only the Xcode command line tools). One source file, no dependencies.

**NuPhy keyboard:** Agent Lumen is also the Mac-side controller for [nuphy-air60-v2-claude-light](https://github.com/hongqi7/nuphy-air60-v2-claude-light) (Air60 V2 and Halo65 V2 firmware). It signals the state through the Num Lock / Scroll Lock indicator bits, over USB, Bluetooth or 2.4G, and resends them after a reconnect. macOS asks for Input Monitoring the first time, which is required to set keyboard LEDs. The app never reads keystrokes. Older `claude-light` hooks are replaced with the shared ones when you connect.

Not affiliated with Anthropic, Tencent or Cognition. MIT License.
