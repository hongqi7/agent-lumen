<p align="center"><img src="docs/icon.png" width="128" alt="Agent Lumen icon"></p>

<h1 align="center">Agent Lumen · 灵光</h1>

<p align="center">让 AI 编程助手的状态，化成屏幕边缘的一圈光，也能点亮你的 NuPhy 键盘。<br>
A glow around your screen edge, and on your NuPhy keyboard, that tells you what your AI coding agents are doing.</p>

<p align="center"><a href="https://github.com/hongqi7/agent-lumen/releases/latest"><b>⬇︎ 下载 Download</b></a></p>

![preview](docs/preview.png)

> English is [below](#english).

## 它做什么

你让 Claude Code（或 WorkBuddy、Devin）去执行任务，自己切到别的窗口。Agent Lumen 用灯光告诉你它当前的状态，你不用来回切换窗口查看。灯光会出现在三个位置：菜单栏图标、屏幕四周边缘、NuPhy 键盘。

| 状态 | 含义 | 灯光 |
|---|---|---|
| 🔵 **等待你确认** | 需要你批准一项操作，或回答它的提问 | 蓝光，每 1.2 秒明暗一次 |
| 🟠 **正在执行** | 正在思考，或正在运行命令、修改文件 | 橙光，每 2 秒明暗一次 |
| 🟢 **已完成** | 本轮任务已做完，等你查看结果 | 绿光，每 3 秒明暗一次 |
| 无任务 | 没有正在进行或刚完成的任务 | 菜单栏显示空心圆圈；屏幕边缘不亮；键盘恢复你原本设置的灯效 |

三个位置使用同一条明暗曲线（取自键盘固件），节奏完全一致。

## 设置面板

点菜单栏图标会打开设置面板：

- **每种状态各有两个开关**，分别控制屏幕边缘和键盘是否亮灯。关闭后，该位置在这个状态下不亮灯；键盘会恢复你原本设置的灯效。
- **每种状态各有一个亮度滑块**。拖动时，屏幕边缘会立即按新亮度显示该颜色，方便对比；键盘通过 USB 有线连接时，也会同步调整。
- **屏幕上的绿光何时熄灭**：任务完成时你不在电脑前，绿光会一直亮着。你回来后，只要移动鼠标或按下任意键，就按你选择的时间熄灭，可选「立即」「8 秒后」「30 秒后」「一直亮着」，默认 8 秒后。这项只影响屏幕边缘，键盘和菜单栏图标会保持绿色，直到你开始下一个任务。之后如有其他会话完成，绿光会重新亮起。绿光亮着时，面板顶部会出现「熄灭屏幕绿光」按钮，可以立即熄灭。
  - 判断你是否回来，只读取系统记录的「距上次操作的秒数」，不需要额外权限，也不读取按键内容。
- **多个会话、多个工具同时进行**：灯光显示其中最需要关注的状态，优先级为 等待你确认 > 正在执行 > 已完成。面板顶部列出每个工具各有几个会话处于什么状态。
- 屏幕边缘的灯光**不拦截鼠标点击**，在多块屏幕、全屏应用中都会显示。
- 资源占用很低：只在有灯光变化时刷新，实测 CPU 约 1%。不联网，不收集任何数据。

## 支持的 AI 工具

| 工具 | 配置文件 | 说明 |
|---|---|---|
| Claude Code（命令行、桌面版 Code 页、IDE 插件） | `~/.claude/settings.json` | |
| WorkBuddy | `~/.workbuddy/settings.json` | |
| Devin（本机会话） | `~/.config/devin/config.json` | 首次运行时，Devin 会询问是否「信任此工作区」，需选择信任；云端会话不会触发灯光 |

三个工具使用同一种「钩子」（hook）机制：工具在你发送消息、调用完一个工具、请求权限、完成一轮回复时，各运行一条命令。Agent Lumen 添加的就是这几条命令，它们只往 `~/.agent-lumen/sessions/` 写入一个表示状态的单词。

## 安装

1. 到 [Releases](https://github.com/hongqi7/agent-lumen/releases/latest) 下载 `AgentLumen-x.y.z.zip`，解压后把 **Agent Lumen.app** 拖进「应用程序」文件夹。
2. 首次打开：本 App 未经苹果公证，macOS 会提示「无法验证开发者」。请**右键点击 App，选择「打开」，再点「打开」**，只需操作一次。
   也可以在终端执行：
   ```bash
   xattr -dr com.apple.quarantine "/Applications/Agent Lumen.app"
   ```
3. 打开后，App 会列出检测到的 AI 工具，询问是否连接，点「接入」。修改前会自动备份原配置文件（文件名为 `*.bak-agent-lumen-时间戳`）。
4. 连接前已经打开的会话，需要重新打开后才会触发灯光。
5. 菜单栏出现一个小圆点即表示 App 正在运行。点击它可打开设置面板。

> 菜单栏图标较多时，新图标可能被 Bartender、Ice 等工具折叠，请把它拖出来。

支持 macOS 13 及以上版本，Apple 芯片和 Intel 芯片均可使用。

## 断开与卸载

- 在设置面板的「已连接的 AI 助手」中点「添加或移除」，选择「断开」即可移除该工具的钩子；也可以在终端执行：
  ```bash
  "/Applications/Agent Lumen.app/Contents/MacOS/AgentLumen" --disconnect
  ```
- 然后退出 App，删除 `Agent Lumen.app` 和 `~/.agent-lumen` 文件夹；开启过「开机时自动打开」的，再删除 `~/Library/LaunchAgents/io.github.hongqi7.agent-lumen.plist`。

## NuPhy 键盘灯

Agent Lumen 也是 [nuphy-air60-v2-claude-light](https://github.com/hongqi7/nuphy-air60-v2-claude-light) 的 Mac 端控制程序。给 NuPhy Air60 V2 或 Halo65 V2 刷入该项目的固件后，键盘侧边灯条（Halo65 为整圈光环）会和屏幕同时亮灯，两者**共用同一套钩子**，颜色和节奏完全一致。

- **工作原理**：Mac 通过 Num Lock、Scroll Lock 两个指示灯信号（macOS 不使用这两个键）告诉键盘当前状态，USB 有线、蓝牙、2.4G 无线连接都能传送。键盘断开重连（休眠唤醒、切换连接方式）后，App 会自动重新发送状态。
- **整块键盘一起亮**（面板中的开关）：开启后，按键背光也变成提示颜色并同步明暗；关闭时只有侧边灯条亮。
- **亮度和「整块键盘一起亮」需在 USB 有线连接时写入键盘**，因为键盘的无线模块只转发指示灯信号。之后改用蓝牙或 2.4G 无线连接，键盘会继续使用最后一次写入的设置；无线连接期间在面板中修改的设置，会在下次插上 USB 线时自动写入。需要 2026-11-03 之后的键盘固件。
- **输入监控权限**：第一次连接 NuPhy 键盘时，macOS 会请求「输入监控」权限。这是 macOS 允许 App 设置键盘指示灯的前提。Agent Lumen **只设置指示灯，不读取任何按键**。授权后需重新打开一次 App。
- **更新 App 后键盘灯不亮**：macOS 把这项权限绑定在 App 的签名上，未付费签名的 App 每个新版本签名都不同，权限会失效。请到「系统设置 → 隐私与安全性 → 输入监控」，选中旧的 Agent Lumen 点「−」删除，再重新打开 App 并点「允许」。诊断日志位于 `~/.agent-lumen/lumen.log`。
- 自己编译时，`./build.sh install` 会用钥匙串里的 Apple 开发证书（如有）给本机这份 App 签名，这样之后重新编译不会丢失权限。
- 以前安装过键盘灯项目自带钩子（`claude-light`）的，面板中该工具会标为「需更新」。在「添加或移除」中选择「更新」，即可换成共享钩子并删除旧钩子；键盘灯项目的后台程序也可以停用了。

## 自己编译

```bash
git clone https://github.com/hongqi7/agent-lumen.git
cd agent-lumen
./build.sh            # 生成 build/Agent Lumen.app 和 zip（通用二进制）
./build.sh install    # 顺便装到 /Applications 并打开
```

只需要 Xcode 命令行工具（`xcode-select --install`），没有任何第三方依赖。代码就一个文件：[`Sources/AgentLumen.swift`](Sources/AgentLumen.swift)；钩子脚本是 [`Resources/lumen-hook`](Resources/lumen-hook)；图标由 [`scripts/make-icon.swift`](scripts/make-icon.swift) 画出来。

## 已知限制

- 按 Esc 中断 Claude 时，不会触发「完成」钩子，状态会停在「正在执行」；超过 2 小时没有新的状态，会自动按「已完成」处理。
- Claude Code 在回复正文中以文字向你提问（而不是弹出提问框）时，按「已完成」处理。
- 只做了 macOS。

---

## English

You hand a task to Claude Code (or WorkBuddy, or Devin) and switch to another window. Agent Lumen shows its state as a colour, in the menu bar and as a soft glow around the edge of every screen:

| State | Glow |
|---|---|
| 🔵 **Needs you**: a permission prompt or a question | blue, fast breathing |
| 🟠 **Working**: thinking or running tools | orange, breathing |
| 🟢 **Done** | green, slow breathing |

The menu bar dot, the screen glow and a NuPhy keyboard flashed with [nuphy-air60-v2-claude-light](https://github.com/hongqi7/nuphy-air60-v2-claude-light) all use the same breathing curve and timing.

- Each colour has an on/off switch and a stepless brightness slider (drag to preview).
- Green goes away once you've seen it: if you're away when a task finishes, the screen stays green until you're back; after you touch the mouse or keyboard it fades out 8 seconds later (or at once, after 30 seconds, or never: your choice in the panel). The keyboard and menu bar stay green until the next task. Presence is read from the system idle time only, never from keystrokes.
- Choose per state whether it shows on the screen edges, the keyboard, or both. Click the menu bar icon to open the settings panel.
- Several sessions and agents at once: the most urgent wins (blue > orange > green); the panel lists every agent's sessions.
- The glow is click-through and shows on every display and over full-screen apps. About 1% CPU, no network access, no data collection.

**Supported agents:** Claude Code (`~/.claude/settings.json`), WorkBuddy (`~/.workbuddy/settings.json`), Devin local sessions (`~/.config/devin/config.json`; answer Devin's workspace trust prompt). All three use the same hook format. Agent Lumen adds a few hook commands that write a single word to `~/.agent-lumen/sessions/`.

**Install:** download the zip from [Releases](https://github.com/hongqi7/agent-lumen/releases/latest), unzip and move **Agent Lumen.app** to Applications. The app is not notarized, so the first time **right-click → Open → Open** (or run `xattr -dr com.apple.quarantine "/Applications/Agent Lumen.app"`). On first launch it offers to connect the agents it finds and backs up each settings file first. Restart sessions that were already open. macOS 13+, Apple silicon and Intel.

**Disconnect:** use Add or remove in the panel, or run `"/Applications/Agent Lumen.app/Contents/MacOS/AgentLumen" --disconnect`. Then delete the app, `~/.agent-lumen` and, if you enabled it, `~/Library/LaunchAgents/io.github.hongqi7.agent-lumen.plist`.

**Build:** `./build.sh` (needs only the Xcode command line tools). One source file, no dependencies.

**NuPhy keyboard:** Agent Lumen is also the Mac-side controller for [nuphy-air60-v2-claude-light](https://github.com/hongqi7/nuphy-air60-v2-claude-light) (Air60 V2 and Halo65 V2 firmware). It signals the state through the Num Lock / Scroll Lock indicator bits, over USB, Bluetooth or 2.4G, and resends them after a reconnect. macOS asks for Input Monitoring the first time, which is required to set keyboard LEDs. The app never reads keystrokes. Older `claude-light` hooks are replaced with the shared ones when you connect.

Not affiliated with Anthropic, Tencent or Cognition. MIT License.
