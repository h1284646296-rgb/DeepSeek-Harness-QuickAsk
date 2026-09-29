# DSH Quick Ask

**连按两下 `Shift`，屏幕中央「duang」一声弹出一个转着彩虹跑马灯的输入框；敲一句话、
选好模型和推理深度，回车，DeepSeek Harness 就去做。**

```
         ⇧ ⇧  （连按两下 Shift，400ms 内）
          │
          ▼   duang ~  ✨ 彩虹跑马灯转起来
  ┌──────────────────────────────────────────────────────┐
  │ ✨  把桌面上的截图按日期归档                            │
  │     ↩ 执行  ⌥↩ 终端  esc 关闭   [DeepSeek-V41-Flash ▾] [推理 低 ▾] │
  │     完成 · 用时 8.4s · DeepSeek-V41-Flash · 推理 低     │
  │     dsh: reasoning:                                   │
  │     先看清楚桌面上有哪些截图，再按拍摄日期分组……        │
  │     Bash  ls -lt ~/Desktop/*.png                      │
  │                                                       │
  │     已经整理好了：12 张截图归入 4 个文件夹。            │
  └──────────────────────────────────────────────────────┘
       ↑ 四周是持续旋转的彩虹跑马灯边框
```

## 快速开始

```bash
curl -fsSL https://raw.githubusercontent.com/h1284646296-rgb/DeepSeek-Harness-QuickAsk/main/install.sh | bash
```

不想跑一行命令，就去 [Releases](https://github.com/h1284646296-rgb/DeepSeek-Harness-QuickAsk/releases/latest)
下载 `DSH-QuickAsk-app.zip`，解压后双击 **`安装.command`**。

装完还需要**授权一次**：系统设置 → 隐私与安全性 → 给「DSH Quick Ask」打开
「输入监视」或「辅助功能」（任一项即可），然后点菜单栏 ✨ →「重启 DSH Quick Ask」。
只需一次，之后长期有效。详见[第 4 节](#4-安装配置启动)。

**前提**：机器上已经装好 DeepSeek Harness，终端里 `dsh --version` 能跑。

---

这不是皮肤层面的改装：模型和推理深度是**真的按次传进 harness** 的
（见第 5 节，有证伪测试）。

---

## 1. 环境判断与选型

### 这台机器的实测环境

| 项目 | 实测值 |
| --- | --- |
| 系统 | macOS 27.0 (26A428)，Apple M4 |
| DSH | `@deepseek-ai/dsh` 0.1.5-rc.3，`.bin/dsh` 在 npx 缓存里 |
| Node | `/usr/local/bin/node` v24.18.0 |
| 编译器 | `swiftc` Apple Swift 6.4（`/Library/Developer/CommandLineTools`） |
| Python | 3.11.9（带 PyYAML 6.0.3，但本方案不依赖它） |
| 其它 | **没有** Hammerspoon、skhd、Karabiner；**没有** iTerm/Warp，只有系统 Terminal |
| 工作区 | `~/Desktop/harness` |

### 关键发现 1：DSH 自带一次性执行入口

```
dsh --profile headless "run the tests"
```

官方描述：**Answer one task, stream reasoning to stderr, print the final assistant
message, and exit.** 任何进程用一行命令就能驱动 DSH 干活，不必逆向 Web GUI 的
token + cookie + `/api/remote.mux` 私有协议。

### 关键发现 2：`--patch` 能按次换 settings 文档

`agent-default-model` 段来自 settings 文档，而**存储层压过 composition 里的同名行**——
所以单纯用 `--patch` 改插件 config 是没用的。但 `@deepseek-ai/dsh-settings-file`
自己有 `path` 配置，而 `--patch` overlay 在整条 patch 栈里最后生效：

```yaml
- id: settings
  config:
    path: "/…/runs/run-<uuid>/settings.yaml"
```

于是每次执行都可以用自己的模型与推理档位，而全局 `~/.dsh/settings.yaml`
**一个字节都不会被动到**（它是热重载的，直接改会和正在跑的 GUI 打架）。

### 被否掉的方案

| 方案 | 结论 |
| --- | --- |
| 驱动 DSH Web GUI（`127.0.0.1:3080`） | **否**。一次性 token 换签名 cookie，客户端到宿主只有一条私有复用协议；复刻它脆弱且升级即失效。 |
| Cordis 客户端插件在 GUI 里加 ⌘K | **否（本轮）**。动态插件不跨进程存活；且只覆盖「浏览器在前台」。 |
| Hammerspoon / skhd / Karabiner | **否**。本机没装；装了也只是多一个第三方依赖。 |
| 用 Carbon 热键表达「双击 Shift」 | **做不到**。Carbon 只能绑定「一个键 + 一组修饰键」，表达不了同一修饰键的时序手势。 |
| Python + `pynput` | **降级为备选 B**。要 pip 安装且同样需要辅助功能授权。 |

### 选定的架构

```
      ⇧ ⇧
       │  CGEventTap(.listenOnly, flagsChanged)   ← 只旁听，不吞事件
       ▼
  DoubleShiftDetector   ← 纯逻辑状态机，可离线自测 9 项
       │ 命中
       ▼
  ┌────────────────────────────────────────────────────────┐
  │  DSH Quick Ask.app  (Swift, 菜单栏常驻)                 │
  │   NSPanel + 磨砂底衬 + 旋转的圆锥渐变彩虹边框            │
  │   NSSound(duang.wav)  ← tools/make-duang.py 合成         │
  │   模型下拉 + 推理深度下拉（数据来自 settings.yaml）       │
  └────────────────────────────────────────────────────────┘
       │ ↩ 回车
       ▼
  写 <run>/settings.yaml（只换 agent-default-model 块）
  + <run>/patch.yml
       │
       ▼  node …/bin.js --profile headless --patch <run>/patch.yml "<任务>"
  ~/.dsh 里的会话与凭据（复用现成的）
```

三个关键取舍：

1. **CGEventTap 而不是 Carbon。** 双击修饰键是时序手势，Carbon 表达不了。
   代价是「输入监视」授权（见第 4 节）—— 但 tap 用 `.listenOnly`，只旁听不消费，
   Shift 的大写、连选功能完全不受影响。
2. **`.command` 文件而不是 AppleScript `do script`。** 后者要索求「控制 Terminal」
   的自动化权限；前者只是一次普通的 `open`，不触发 TCC 弹窗。
3. **不直接改 `~/.dsh/settings.yaml`。** 复制一份、只替换一个顶层块、用 `--patch`
   指过去。全局文件保持字节不变，也不会和 GUI 抢热重载。

---

## 2. 三个改动点各自是怎么做的

### 2.1 触发：连按两下 Shift

`Sources/DoubleShiftMonitor.swift` 分两层：

- **`DoubleShiftDetector`** —— 纯逻辑状态机。只认左右 Shift（键码 56/60）的
  **按下沿**，忽略长按产生的重复事件；两次按下间隔 ≤ `doubleShiftWindowMs`
  就算双击；触发后有 500ms 冷却，所以连按三下、四下只算一次。
  因为它是纯函数式的，可以离线自测 —— `--selftest-trigger` 跑 9 项断言（见第 6 节）。
- **`DoubleShiftMonitor`** —— `CGEvent.tapCreate(tap:.cgSessionEventTap,
  options:.listenOnly, eventsOfInterest: flagsChangedMask)`，挂在主 runloop 上；
  被系统因超时/用户输入关掉时自动重开。

没授权时**不会把 App 变成哑巴**：自动保留组合键兜底，菜单栏写明原因，
并提供跳转到系统设置的入口。

### 2.2 彩虹跑马灯 + duang

**跑马灯**（`Sources/RainbowBorderView.swift`）：
把一整块 `.conic` 圆锥渐变铺满面板（图层取外接正方形，旋转时始终盖满），
内层 `scrim` 四周内缩 4pt 压在上面 —— 露出来的那一圈就是边框。
然后让渐变图层绕中心匀速自转（`CABasicAnimation(transform.rotation.z)`，
3.2s 一圈）。

> 第一版用「CAShapeLayer 蒙版把渐变裁成环」，结果因为翻转父视图下的坐标系
> 算错，画成了穿心的放射线（截图确认）。换成现在这个做法后不需要任何路径数学，
> 也不会有坐标系陷阱。全程在 GPU 上跑，CPU 占用为零，不用定时器。

**duang**（`tools/make-duang.py` → `Resources/duang.wav`）：
纯标准库合成，不下载任何素材。结构是四层叠加 —— 82/61Hz 的闷响、
6ms 噪声脆音、660→132Hz 指数扫频 + 16Hz 颤音的本体、以及 0.15s/0.30s
两次低幅回弹。频率用解析相位积分，避免扫频时出现爆音；最后软削波归一化。
0.85 秒、44.1kHz 单声道。配置 `sound` 也可以填系统音效名（`Hero`、`Glass`…）
或 `""` 静音。

### 2.3 模型与推理深度

**数据从哪来**：`tools/model-catalog.js`（Node，用 dsh 自带的 `js-yaml`，
不引入新依赖）解析 `~/.dsh/settings.yaml`，抽出：

- DeepSeek 原生路由的模型（含适配器内置的 4 个）与它接受的 `off/low/high/max`；
- `llm-pi-ai.providers.*` 下每个 provider 的每个模型，以及它声明的推理阶梯
  （百炼是 `off/minimal/low/medium/high/xhigh/max` 七档，Ollama 模型是 `false` → 只有 `off`）。

本机实测：**18 个模型，来自 3 个 provider（deepseek-official / bailian / ollama）**。

**怎么传进去**：`Sources/SettingsOverride.swift`
复制 `settings.yaml`，**按行**只替换 `agent-default-model:` 这个顶层块，
再写一个指向副本的 patch overlay。刻意不做完整 YAML 解析 ——
这份文件里有大量注释和锚点（`&bailian_efforts`），重新序列化会全部丢掉。

**面板上**：输入框右下两个下拉（`NSPopUpButton`）。切换模型时推理档位列表跟着重建；
选择写回 `config.json`，下次打开还记得。选中的档位显示成 `推理 关闭/最小/低/中/高/极高/最大`。

---

## 3. 交付的文件

```
dsh-quickask/
├── Sources/                        Swift 源码（11 个文件）
│   ├── main.swift                  命令行分流（--ask / --diagnose / --catalog / GUI）
│   ├── AppDelegate.swift           生命周期、菜单栏、编辑菜单（⌘V 靠它）、权限引导
│   ├── DoubleShiftMonitor.swift    CGEventTap 双击 Shift + 可自测的判定状态机
│   ├── GlobalHotKey.swift          Carbon 全局热键（兜底 / --trigger hotkey）
│   ├── QuickAskPanel.swift         悬浮面板全部 UI（输入、结果卡片、两个下拉）
│   ├── RainbowBorderView.swift     彩虹跑马灯（圆锥渐变 + 自转）
│   ├── SoundPlayer.swift           音效播放（自带 wav 或系统音效）
│   ├── HeadlessRunner.swift        headless 执行器 + 终端模式脚本
│   ├── SettingsOverride.swift      按次 settings 覆盖（不改全局文件）
│   ├── Config.swift                配置读写、热键解析、模型目录解析、路径探测
│   ├── Diagnostics.swift           诊断、触发器自检、模型目录提取、前台执行
│   └── Support.swift               路径常量、日志、shell 转义
├── Resources/
│   ├── Info.plist                  LSUIElement=true（无 Dock 图标）
│   └── duang.wav                   合成出来的音效（build.sh 缺失时自动生成）
├── tools/
│   ├── make-icon.swift / .sh        纯 CoreGraphics 画图标
│   ├── make-duang.py                合成 duang.wav
│   ├── model-catalog.js             从 settings.yaml 抽模型与推理档位
│   ├── make-signing-identity.sh     建本地自签身份（让 TCC 授权不再随重编译失效）
│   └── sign.sh                      统一签名入口（自签优先，退回 ad-hoc）
├── build.sh                        编译 + 打包资源 + 签名
├── install.sh                      编译 + 安装 + 提取目录 + 写配置 + 注册 LaunchAgent
├── uninstall.sh                    卸载（--purge 连配置日志一起清）
├── test.sh                         冒烟测试（--e2e 真跑一次）
├── bin/dsh-quickask                CLI 包装
├── fallback/quickask_tk.py         备选方案 B：Python + Tkinter，零编译
└── build/  dist/                   构建产物（dist/DSH Quick Ask.app）
```

---

## 4. 安装、配置、启动

### 安装：三种方式，任选一种

#### 方式一：一行命令（最省事）

```bash
curl -fsSL https://raw.githubusercontent.com/h1284646296-rgb/DeepSeek-Harness-QuickAsk/main/install.sh | bash
```

它会先尝试下载本仓库 Release 里的**预编译包**（不需要编译器），
拿不到才自动下载源码在本机编译（需要 Xcode Command Line Tools，缺了会提示你装）。

#### 方式二：下载 Release 里的 zip

到 [Releases](https://github.com/h1284646296-rgb/DeepSeek-Harness-QuickAsk/releases/latest)
下载 `DSH-QuickAsk-app.zip`，解压后：

```
DSH Quick Ask.app      双击即用的应用
安装.command            ← 双击它
卸载.command
使用说明.txt
tools/                  安装时会用来建本地签名身份
```

双击 `安装.command`；若 macOS 提示「来自身份不明的开发者」，
**右键点它 → 打开 → 再点「打开」**（未做公证的应用，第一次都这样）。
命令行等效：

```bash
cd <解压目录> && bash 安装.command
```

#### 方式三：克隆自己编译

```bash
git clone https://github.com/h1284646296-rgb/DeepSeek-Harness-QuickAsk.git
cd DeepSeek-Harness-QuickAsk
bash install.sh
```

### 安装器会做什么

不管哪种方式，最后都走同一段逻辑（`tools/install-app.sh`）：

1. 去掉 `com.apple.quarantine`（从网上下载的 app 会被 Gatekeeper 拦住）；
2. 建一个**本地自签的代码签名身份**并重新签名 —— 这样签名不再随重新编译变化，
   「输入监视」授权一次就长期有效（见下一节）；
3. 装到 `/Applications`（不可写则 `~/Applications`）；
4. 用应用自带的 `--catalog` 从 `~/.dsh/settings.yaml` 提取模型目录，
   写进 `config.json`；
5. 写 `~/Library/LaunchAgents/local.dsh.quickask.plist` 并 `launchctl bootstrap`，
   立刻启动 + 以后每次登录自动启动。

**不需要 sudo，不往 `/Library` 写任何东西。**

### ⚠️ 连按两下 Shift 需要一次授权（只做一次，之后永久有效）

双击 Shift 用 `CGEventTap` 旁听键盘，由 macOS 的 TCC 管辖，必须由你本人点一次。

**为什么以前要反复授权**：ad-hoc 签名下，App 的 designated requirement 是
`cdhash H"…"` —— 二进制一变（每次重编译）系统就认为这是一个**新 App**，
设置里会多出一条同名的旧记录，你打开的那条并不是正在跑的那个。
现在改用**本地自签证书**签名，DR 变成

```
designated => identifier "local.dsh.quickask" and certificate root = H"6053b481…"
```

只跟证书有关，重编译多少次都不变，**授权一次就永久有效**。

**怎么做**：

1. 打开 **系统设置 → 隐私与安全性 → 输入监视**（或 **辅助功能**，任一项即可）。
2. 找到 **DSH Quick Ask**，把开关打开。
   如果列表里有好几条同名记录，只保留最新那条 —— 或者直接清干净重来：
   ```bash
   tccutil reset ListenEvent local.dsh.quickask
   tccutil reset Accessibility local.dsh.quickask
   ```
   然后重启 App，列表里会重新出现**唯一一条**。
3. 点菜单栏 ✨ →「重启 DSH Quick Ask」（或
   `launchctl kickstart -k gui/$(id -u)/local.dsh.quickask`）。
   应用每 3 秒自查一次权限，若系统即时放行，它会自己弹「权限已生效」。

确认：

```bash
tail -5 ~/Library/Logs/DSHQuickAsk.log
# 双击 Shift 监听已启用（窗口 400ms，输入监视授权=true）   ← 成功
```

> 手动在终端里跑 `--diagnose` 会显示 `true`，因为 TCC 把权限算在终端头上；
> **以 launchd 常驻实例的日志为准**。

#### 不想授权？还有一条免授权的路

菜单栏 ✨ →「改用免授权的 Carbon 模式」：把 Shift 键本身注册成 Carbon 热键
（和 ⌥Space 同一条免授权通道，实测可注册成功）。

代价是 Carbon 热键可能把 Shift「吃掉」，导致打不出大写 —— 所以它是**显式选项**
而不是默认值。切换后请立刻试打几个大写字母；一旦失灵，菜单栏 ✨ →
「切回标准模式」即可还原。

### 可选项

```bash
bash install.sh --trigger both            # 双击 Shift 和组合键都行
bash install.sh --trigger hotkey --hotkey "control+space"   # 只用组合键
bash install.sh --sound Hero              # 换成系统音效
bash install.sh --sound ""                # 静音
bash install.sh --mode terminal           # 默认走终端窗口执行
bash install.sh --workspace ~/Desktop     # 换工作目录
bash install.sh --no-agent                # 只装 App，不注册开机自启
```

### 日常操作

| 操作 | 效果 |
| --- | --- |
| 连按两下 `Shift` | 弹出 / 收起面板（duang + 彩虹跑马灯） |
| 输入后 `↩` | 在面板里执行，推理与答复流式显示 |
| 输入后 `⌥↩` | 开 Terminal 窗口执行，完整过程可见（长任务用这个） |
| `esc` | 关闭；正在执行则中止 |
| 右下两个下拉 | 选模型 / 选推理深度，选择会被记住 |

菜单栏 ✨：打开输入框 / 当前模型 / 授权入口 / 刷新模型列表 / 重新载入配置 /
打开配置文件 / 打开日志 / 退出。

### 改配置

`~/Library/Application Support/DSHQuickAsk/config.json`，改完点菜单栏 ✨ →
「重新载入配置」，不用重启：

```json
{
  "trigger": "double-shift",
  "hotkey": "option+space",
  "doubleShiftWindowMs": 400,
  "workspace": "~/Desktop/harness",
  "nodePath": "/usr/local/bin/node",
  "dshEntry": "~/.npm/_npx/…/node_modules/@deepseek-ai/dsh/lib/bin.js",
  "mode": "inline",
  "rainbow": true,
  "sound": "duang",
  "provider": "deepseek-official",
  "model": "deepseek-flash",
  "effort": "low",
  "catalog": { "models": [ … ] }
}
```

`trigger` 取 `double-shift` / `hotkey` / `both`；`rainbow: false` 关掉跑马灯；
`sound: ""` 静音。

### 卸载

```bash
bash uninstall.sh           # 保留配置和日志
bash uninstall.sh --purge   # 全部清干净
```

---

## 5. 模型与推理深度：它真的生效吗

**生效，而且有证伪测试。** 把配置里的模型改成一个不存在的名字：

```bash
$ DSH_QUICKASK_CONFIG=…/bogus-config.json "DSHQuickAsk" --ask "只回复两个字：通过"
dsh: INVALID_REQUEST: The supported API model names are deepseek-flash, deepseek-v4-pro,
     but you passed model-that-does-not-exist. (request_id: a82f629f-…)
```

服务端明确拒绝了那个名字 —— 说明**这次的 settings 覆盖确实抵达了 harness**。

再用真实模型 `deepseek-v4-pro` + 推理 `max` 跑一次：

```
$ DSH_QUICKASK_CONFIG=…/pro-config.json "DSHQuickAsk" --ask "用一句话说明你是什么模型"
我是 DeepSeek 的 deepseek-v4-pro 模型，一个由深度求索开发、运行在 Harness 平台上的 AI 编程代理。
```

生成的中间产物（都在 `~/Library/Application Support/DSHQuickAsk/runs/run-<uuid>/`）：

```yaml
# patch.yml
- id: settings
  config:
    path: "/…/run-1308DC14-…/settings.yaml"
```

```yaml
# settings.yaml 里被替换的那一段
agent-default-model:
  provider: "deepseek-official"
  model: "deepseek-v4-pro"
  reasoningEffort: "max"
# 本机 Ollama（http://127.0.0.1:11434）导入为一条 pi-ai 路由。   ← 后面原样保留
```

实测对比：除 `agent-default-model` 块外，副本与 `~/.dsh/settings.yaml`
**逐行完全一致**（`bailian_efforts` 锚点等 9 处引用都在）。
每次执行完，一天前的 run 目录会被自动清理。

---

## 6. 怎么测试

### 6.1 自动冒烟测试

```bash
bash test.sh          # 不花钱：产物、资源、触发器逻辑、模型目录、配置
bash test.sh --e2e    # 额外真跑一次 headless 任务
```

实测输出：

```
==> 4. 打包资源（音效 / 模型目录脚本）
    ✓ duang.wav 已打包      ✓ model-catalog.js 已打包      ✓ duang.wav 是合法音频
==> 5. 双击 Shift 判定逻辑自检
    ✓ 快速两下（间隔 200ms）    trigger ✓
    ✓ 间隔 600ms 的第一下       no     ✓
    ✓ 紧接着的下一对            trigger ✓
    ✓ 单按一下                  no     ✓
    ✓ 连按三下的第二下          trigger ✓
    ✓ 连按三下的第三下（冷却中） no     ✓
    ✓ 右 Shift 两下             trigger ✓
    ✓ 长按重复事件              no     ✓
    ✓ 按 A、S 两下              no     ✓
  全部通过（9 项）
==> 6. 模型目录提取
    ✓ 提取到 18 个模型          ✓ 含推理档位信息
==> 9. 端到端：真的执行一次 headless 任务
    任务：在 shell 里运行 pwd，然后只回复它输出的绝对路径
    ~/Desktop/harness
    ✓ 退出码 0（3s）
全部通过。
```

### 6.2 不用鼠标键盘的检查

```bash
BIN="/Applications/DSH Quick Ask.app/Contents/MacOS/DSHQuickAsk"

"$BIN" --diagnose                      # 触发方式、音效、模型目录、路径
"$BIN" --selftest-trigger              # 双击判定逻辑（9 项断言）
"$BIN" --catalog | head -40            # 模型目录 JSON
"$BIN" --print-terminal-script "列目录" # 终端模式会执行的脚本（含 --patch）
"$BIN" --ask "在 shell 里运行 pwd"       # 不弹窗直接执行一次
"$BIN" --demo                          # 用示例内容渲染展开后的面板
```

### 6.3 手动验收（必须由人按）

1. **连按两下 `Shift`。**
   预期：**「duang」一声**，屏幕中央偏上浮出面板，四周是**持续旋转的彩虹边框**。
   若没反应 → `tail -20 ~/Library/Logs/DSHQuickAsk.log`：
   - `监听已启用（… 输入监视授权=false）` → 去授权，然后重启 App；
   - `监听建立失败` → 同样是没有授权；
   - 菜单栏 ✨ 也有对应提示和跳转入口。

2. **确认跑马灯真的在跑。** 隔一秒截两张图对比，边框颜色位置应当明显移动
   （本仓库的 `build/v3-panel-a.png` / `v3-panel-b.png` 就是这么验的）。

3. **敲 `现在几点了`，`↩`。** 面板向下展开，状态行先显示「正在执行…（模型 · 推理 档）」，
   灰色区出现 `dsh: reasoning:` 推理流，结束后答案在下方，
   状态行变成「完成 · 用时 x.xs · 模型 · 推理 档」。

4. **测模型选择真的生效。** 把模型下拉切到 `DeepSeek-V4-Pro`，推理切到「最大」，
   输入 `用一句话说明你是什么模型`，回车。答复里应当自称 deepseek-v4-pro。
   然后重开面板，确认两个下拉**还记得刚才的选择**。

5. **测工具调用**：`在 shell 里运行 pwd，然后只回复它输出的绝对路径`
   → 答案应当是 `~/Desktop/harness`（配置里的工作区）。

6. **测终端模式**：输入 `列出桌面上的文件`，按 `⌥↩`。
   预期：Terminal 打开一个 `quickask-<时间戳>.command` 窗口，先打印任务和模型，
   然后 dsh 的输出，最后停在「按回车关闭窗口」。

7. **测跨 App**：切到 Safari 或访达，再连按两下 `Shift`，面板照样浮在最前面。

8. **测不打扰输入**：在任意文本框里正常用 Shift 打大写、按住 Shift 连选 —— 
   都不应被拦截（listenOnly 不消费事件）。快速打两个大写字母**不会**误触发面板。

### 6.4 备选方案 B 的测试

```bash
python3 fallback/quickask_tk.py --demo
python3 fallback/quickask_tk.py --task "只回复两个字：收到"
# 实测输出：收到   （退出码 0）
```

---

## 7. 首选方案与备选方案

### 首选：方案 A — 原生 Swift 常驻代理（本文档主角）

- **依赖**：只有 Xcode Command Line Tools + Python3（生成音效，或直接用已生成的 wav）。
- **权限**：**一次「输入监视」授权**（仅当使用双击 Shift；`--trigger hotkey` 则零权限）。
- **优点**：任意 App 里可用；面板 `< 50ms` 弹出；无 Electron、无运行时；菜单栏常驻、开机自启；
  内联结果 + 终端窗口两种执行方式；真·按次切模型与推理深度。
- **代价**：要编译一次（~10 秒）；改代码要重新 `build.sh` 并重新授权（ad-hoc 签名会变）。

### 备选 B：Python + Tkinter（`fallback/quickask_tk.py`）

什么时候用：本机**没有** `swiftc`；想改行为但不想碰 Swift；想把逻辑并进别的 Python 脚本。

它与首选**共用同一份配置文件和同一条执行命令**，行为一致。区别：

| | 方案 A（Swift） | 方案 B（Python） |
| --- | --- | --- |
| 触发 | 双击 Shift（CGEventTap）或 Carbon 组合键 | Carbon 组合键不可用；需 `pynput` 或系统快捷键 |
| 外观 | 圆角 + 磨砂 + 彩虹跑马灯 | 直角深色面板，无跑马灯 |
| 模型/档位 | 面板内下拉 | 读配置文件 |
| 编译 | 需要 swiftc | 不需要 |

零依赖触发方式：**快捷指令 App** → 「运行 Shell 脚本」填
`/usr/local/bin/python3 "~/Desktop/harness/dsh-quickask/fallback/quickask_tk.py" --show`
→ 添加键盘快捷键。

### 被明确放弃的第三条路

DSH Web GUI 内置 ⌘K 输入框（Cordis 客户端插件）：动态插件不跨进程存活，
做成常驻能力要改 agent preset / composition；且只覆盖浏览器前台。**本轮不做。**

---

## 8. 交付清单 / 启动方式 / 验证 / 已知限制

### 交付清单

| # | 产物 | 路径 |
| --- | --- | --- |
| 1 | 应用 | `dsh-quickask/dist/DSH Quick Ask.app`（安装后 `/Applications/DSH Quick Ask.app`） |
| 2 | 源码 | `dsh-quickask/Sources/*.swift`（11 个） |
| 3 | 工具 | `tools/make-icon.{swift,sh}`、`tools/make-duang.py`、`tools/model-catalog.js` |
| 4 | 脚本 | `build.sh`、`install.sh`、`uninstall.sh`、`test.sh`、`bin/dsh-quickask` |
| 5 | 备选 | `fallback/quickask_tk.py` |
| 6 | 用户配置 | `~/Library/Application Support/DSHQuickAsk/config.json` |
| 7 | 按次覆盖产物 | `~/Library/Application Support/DSHQuickAsk/runs/run-<uuid>/{settings.yaml,patch.yml}` |
| 8 | 开机自启 | `~/Library/LaunchAgents/local.dsh.quickask.plist` |
| 9 | 日志 | `~/Library/Logs/DSHQuickAsk.log` |

### 启动方式

```bash
bash ~/Desktop/harness/dsh-quickask/install.sh   # 一次性安装
# 之后登录即自动运行；连按两下 Shift 使用
launchctl kickstart -k gui/$(id -u)/local.dsh.quickask    # 重启常驻实例
```

### 验证方法（本机已实测）

| 验证项 | 结果 |
| --- | --- |
| Swift 编译 + ad-hoc 签名 + 资源打包 | ✅ |
| CGEventTap 建立（`flagsChanged`，listenOnly） | ✅ 日志：`双击 Shift 监听已启用（窗口 400ms…）` |
| 双击判定逻辑 9 项时序断言 | ✅ 全部通过 |
| 彩虹跑马灯渲染 + 确实在旋转 | ✅ 两张间隔 1s 的截图颜色位置明显不同 |
| duang.wav 合成与打包 | ✅ 0.85s / 44.1kHz 单声道，`afinfo` 通过 |
| 模型目录提取 | ✅ 18 个模型 / 3 个 provider / 含推理阶梯 |
| **按次模型覆盖生效（证伪）** | ✅ 不存在的模型名被服务端拒绝 |
| **按次模型覆盖生效（正向）** | ✅ `deepseek-v4-pro` + `max`，模型自称 deepseek-v4-pro |
| 覆盖不污染全局 | ✅ 除 `agent-default-model` 块外逐行一致 |
| 端到端：任务 → bash 工具 → 答复 | ✅ 3 秒，退出码 0 |
| 终端模式脚本（含 `--patch`） | ✅ 内容正确 |
| `test.sh` / `test.sh --e2e` | ✅ 全部通过 |
| LaunchAgent 常驻 | ✅ `state = running` |
| 备选方案 B 执行 | ✅ `--task` 返回「收到」 |

**没有自动化的两件事**，必须由人做：
① 真的用手指连按两下 Shift（本环境无法合成按键：`osascript` 报
`A privilege violation occurred (-10004)`，即调用方没有辅助功能权限）；
② 在系统设置里勾选「输入监视」。

### 已知限制

1. **双击 Shift 需要一次系统授权。** 这是 macOS 对键盘监听的硬性要求，绕不开。
   没授权时不拦路：菜单栏写明原因，并提供「改用免授权的 Carbon 模式」一键切换。
2. **授权后要重启 App**，macOS 通常不会给已运行的进程补发权限（应用每 3 秒自查一次，
   若系统即时放行会自动生效并提示）。
3. **不要再用 ad-hoc 签名。** `build.sh` 会优先用 `tools/sign.sh` 找到的自签身份；
   如果那个钥匙串被删了，会退回 ad-hoc，此时授权又会随重编译失效 ——
   重跑 `bash tools/make-signing-identity.sh` 即可恢复。
4. **一次执行 = 一个新会话。** `--profile headless` 每次跑完即退，不接续 GUI 里
   的长会话；也没有对话上下文，追问要重新说清背景。
5. **面板里看不到工具调用过程。** headless 只把 provider 推理流到 stderr；
   想看完整过程用 `⌥↩` 的终端模式，或事后去 `~/.dsh/sessions` 翻。
6. **审批策略是 `ask`。** headless 没有交互界面，需要审批的操作按 fail-closed 处理；
   真正要授权的重活儿请用终端模式（那里仍有 TTY）。
7. **推理档位必须被模型支持。** 给不支持推理的模型（例如 `reasoningEfforts: false`
   的 Ollama 模型）发高档位，harness 会报 `UNSUPPORTED_REASONING_EFFORT`；
   面板只列出该模型声明的档位，所以正常操作不会踩到。
8. **模型名要端点认。** 适配器内置列表里有 `deepseek-v4-flash`、`deepseek-v4-flash-vision-exp`，
   但本机账号的 API 只接受 `deepseek-flash` 和 `deepseek-v4-pro`（服务端报错原文），
   选了前者会被拒。这是账号/端点侧的差异，不是本工具的问题。
9. **只支持单行输入。** 适合一句话任务；超长 prompt 建议用 Web GUI。
10. **结果不渲染 Markdown**，面板里是纯文本 + 颜色区分。
11. **DSH 升级换 npx 缓存目录后** `dshEntry` 会失效，重跑 `install.sh`
   即可（应用启动时也有兜底搜索，取最新的一份）。
