#!/usr/bin/env python3
"""DSH Quick Ask — 无编译备选方案。

当这台机器没有 Xcode Command Line Tools（swiftc）时，用这份脚本得到同样的体验：
一个悬浮输入框，回车后由 `dsh --profile headless "<任务>"` 执行，结果直接流式显示在框里。

它与首选方案的 Swift 版共用同一份配置文件和同一条执行命令，
所以两者的行为是一致的：

    ~/Library/Application Support/DSHQuickAsk/config.json

全局快捷键有三种触发方式（见 README「备选方案 B」）：
  1. `pip3 install pynput` 后直接运行本脚本，脚本自己注册全局热键；
  2. 用 macOS「快捷指令 / 自动操作」把一个键盘快捷键绑到
     `python3 <本脚本> --show`（零额外依赖，推荐）；
  3. 用 Hammerspoon / skhd 之类的工具调用同一个命令。

用法:
    python3 quickask_tk.py                常驻（有 pynput 时注册热键，否则等同 --show）
    python3 quickask_tk.py --show         立刻显示输入框（给系统快捷键调用）
    python3 quickask_tk.py --task "..."   不显示窗口，直接执行并打印（脚本/自检用）
    python3 quickask_tk.py --demo         用示例内容渲染界面，检查排版
    python3 quickask_tk.py --hotkey "ctrl+space"
"""

from __future__ import annotations

import glob
import json
import os
import subprocess
import sys
import threading
import tkinter as tk
from pathlib import Path

SUPPORT = Path.home() / "Library/Application Support/DSHQuickAsk"
CONFIG_PATH = SUPPORT / "config.json"
LOG_PATH = Path.home() / "Library/Logs/DSHQuickAsk-python.log"

BG = "#1c1d22"
FG = "#f2f2f4"
DIM = "#9a9aa5"
ACCENT = "#7b8cff"


# --------------------------------------------------------------------------- #
# 配置与路径解析（与 Swift 版保持一致）
# --------------------------------------------------------------------------- #

def log(message: str) -> None:
    try:
        LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
        with LOG_PATH.open("a", encoding="utf-8") as handle:
            handle.write(message + "\n")
    except OSError:
        pass


def load_config() -> dict:
    config = {
        "hotkey": "option+space",
        "workspace": str(Path.home() / "Desktop/harness"),
        "nodePath": "",
        "dshEntry": "",
        "mode": "inline",
    }
    try:
        config.update(json.loads(CONFIG_PATH.read_text(encoding="utf-8")))
    except (OSError, ValueError):
        pass

    workspace = os.path.expanduser(config.get("workspace") or "")
    if not os.path.isdir(workspace):
        workspace = str(Path.home())
    config["workspace"] = workspace

    if not config.get("nodePath"):
        config["nodePath"] = resolve_node()
    if not config.get("dshEntry"):
        config["dshEntry"] = resolve_dsh()
    return config


def resolve_node() -> str:
    for candidate in ("/usr/local/bin/node", "/opt/homebrew/bin/node", "/usr/bin/node"):
        if os.access(candidate, os.X_OK):
            return candidate
    for pattern in (
        str(Path.home() / ".nvm/versions/node/*/bin/node"),
        str(Path.home() / ".volta/bin/node"),
    ):
        matches = sorted(glob.glob(pattern))
        if matches:
            return matches[-1]
    return ""


def resolve_dsh() -> str:
    patterns = [
        str(Path.home() / ".npm/_npx/*/node_modules/@deepseek-ai/dsh/lib/bin.js"),
        "/usr/local/lib/node_modules/@deepseek-ai/dsh/lib/bin.js",
        "/opt/homebrew/lib/node_modules/@deepseek-ai/dsh/lib/bin.js",
        str(Path.home() / ".dsh/profiles/node_modules/@deepseek-ai/dsh/lib/bin.js"),
    ]
    matches: list[str] = []
    for pattern in patterns:
        matches.extend(glob.glob(pattern))
    if not matches:
        return ""
    return max(matches, key=lambda path: os.path.getmtime(path))


# --------------------------------------------------------------------------- #
# 直接执行（--task），不经过 Tk
# --------------------------------------------------------------------------- #

def run_once(task: str, config: dict) -> int:
    node, entry = config.get("nodePath"), config.get("dshEntry")
    if not node or not entry:
        print("quickask: 找不到 node 或 dsh 入口，请检查配置或 PATH", file=sys.stderr)
        return 2
    process = subprocess.Popen(
        [node, entry, "--profile", "headless", task],
        cwd=config["workspace"],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    assert process.stdout is not None
    for line in process.stdout:
        sys.stdout.write(line)
        sys.stdout.flush()
    return process.wait()


# --------------------------------------------------------------------------- #
# 悬浮输入框
# --------------------------------------------------------------------------- #

class QuickAskWindow:
    WIDTH = 720
    COLLAPSED = 78
    EXPANDED = 430

    def __init__(self, config: dict, demo: bool = False) -> None:
        self.config = config
        self.process: subprocess.Popen | None = None

        self.root = tk.Tk()
        self.root.title("DSH Quick Ask")
        self.root.overrideredirect(True)
        self.root.attributes("-topmost", True)
        self.root.configure(bg=ACCENT)

        # 1px 描边：Tk 没有圆角，用一个稍大的外框模拟内缩的面板。
        self.inner = tk.Frame(self.root, bg=BG)
        self.inner.pack(fill="both", expand=True, padx=1, pady=1)

        self.entry = tk.Entry(
            self.inner,
            bg=BG,
            fg=FG,
            insertbackground=FG,
            relief="flat",
            font=("SF Pro Text", 20),
            highlightthickness=0,
        )
        self.entry.pack(fill="x", padx=54, pady=(22, 0), ipady=4)
        self.entry.insert(0, "")
        self.entry.bind("<Return>", self.submit)
        self.entry.bind("<Escape>", lambda _event: self.hide())

        self.hint = tk.Label(
            self.inner,
            text="↩ 直接执行     esc 关闭",
            bg=BG,
            fg=DIM,
            font=("SF Pro Text", 11),
            anchor="w",
        )
        self.hint.pack(fill="x", padx=54)

        self.status = tk.Label(
            self.inner, text="", bg=BG, fg=DIM, font=("SF Pro Text", 11), anchor="w"
        )

        self.output = tk.Text(
            self.inner,
            bg=BG,
            fg=FG,
            relief="flat",
            highlightthickness=0,
            font=("Menlo", 11),
            wrap="word",
            height=14,
        )
        self.output.tag_configure("reasoning", foreground=DIM)
        self.output.tag_configure("answer", foreground=FG)
        self.output.tag_configure("failure", foreground="#ff6b6b")

        self.place(self.COLLAPSED)
        self.root.bind("<Escape>", lambda _event: self.hide())
        self.root.protocol("WM_DELETE_WINDOW", self.hide)
        self.root.after(60, self.focus)
        if demo:
            self.root.after(200, self.render_demo)

    # -- 显示与布局 ------------------------------------------------------- #

    def place(self, height: int) -> None:
        screen_w = self.root.winfo_screenwidth()
        screen_h = self.root.winfo_screenheight()
        x = (screen_w - self.WIDTH) // 2
        y = int(screen_h * 0.20)
        self.root.geometry(f"{self.WIDTH}x{height}+{x}+{y}")

    def focus(self) -> None:
        self.root.lift()
        self.root.attributes("-topmost", True)
        self.entry.focus_force()

    def show(self) -> None:
        """显示输入框并进入事件循环（一次性路径）。"""
        self.show_once()
        self.root.mainloop()

    def show_once(self) -> None:
        """把窗口复位并显示，不接管事件循环（常驻热键路径用）。"""
        self.place(self.COLLAPSED)
        self.status.pack_forget()
        self.output.pack_forget()
        self.entry.delete(0, "end")
        self.output.delete("1.0", "end")
        self.root.deiconify()
        self.focus()

    def hide(self) -> None:
        if self.process and self.process.poll() is None:
            self.process.terminate()
        self.root.withdraw()

    # -- 执行 ------------------------------------------------------------- #

    def submit(self, _event=None) -> None:
        task = self.entry.get().strip()
        if not task:
            self.hide()
            return

        node, entry = self.config.get("nodePath"), self.config.get("dshEntry")
        if not node or not entry:
            self.append("找不到 node 或 dsh 入口，请先跑 --task 检查配置。\n", "failure")
            self.expand()
            return

        self.expand()
        self.status.configure(text="正在执行…")
        self.append(f"$ dsh --profile headless {task}\n\n", "reasoning")

        def worker() -> None:
            try:
                self.process = subprocess.Popen(
                    [node, entry, "--profile", "headless", task],
                    cwd=self.config["workspace"],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    bufsize=1,
                )
                assert self.process.stdout is not None
                for line in self.process.stdout:
                    self.root.after(0, self.append, line, "answer")
                code = self.process.wait()
            except OSError as error:
                self.root.after(0, self.append, f"启动失败：{error}\n", "failure")
                code = 127
            self.root.after(0, self.finish, code)

        threading.Thread(target=worker, daemon=True).start()

    def expand(self) -> None:
        self.place(self.EXPANDED)
        self.status.pack(fill="x", padx=54, pady=(8, 0))
        self.output.pack(fill="both", expand=True, padx=18, pady=(8, 16))

    def append(self, text: str, tag: str) -> None:
        self.output.insert("end", text, tag)
        self.output.see("end")

    def finish(self, code: int) -> None:
        workspace = self.config["workspace"].replace(str(Path.home()), "~", 1)
        if code == 0:
            self.status.configure(text=f"完成 · 工作区 {workspace}")
        else:
            self.status.configure(text=f"退出码 {code}")
            self.append(f"\n[进程以退出码 {code} 结束]\n", "failure")

    def render_demo(self) -> None:
        self.entry.insert(0, "把桌面上的截图按日期归档")
        self.expand()
        self.status.configure(text="完成 · 用时 8.4s · 工作区 ~/Desktop/harness")
        self.append("dsh: reasoning:\n先看清桌面上的截图，再按日期分组……\n", "reasoning")
        self.append("Bash  ls -lt ~/Desktop/*.png\n", "reasoning")
        self.append(
            "\n已经整理好了：12 张截图归入 4 个文件夹，原文件已移动而非复制。\n", "answer"
        )


# --------------------------------------------------------------------------- #
# 入口
# --------------------------------------------------------------------------- #

def normalize_hotkey(hotkey: str) -> str:
    """把 `option+space` 之类的写法翻译成 pynput 的 `<alt>+<space>`。

    只做整段精确匹配，否则 "option" 里的 "opt" 会被先替换掉。
    """
    names = {
        "command": "<cmd>", "cmd": "<cmd>", "super": "<cmd>",
        "option": "<alt>", "opt": "<alt>", "alt": "<alt>",
        "control": "<ctrl>", "ctrl": "<ctrl>",
        "shift": "<shift>",
        "space": "<space>", "tab": "<tab>", "return": "<enter>", "enter": "<enter>",
    }
    parts = [part.strip().lower() for part in hotkey.split("+") if part.strip()]
    return "+".join(names.get(part, part) for part in parts)


def hotkey_loop(window: QuickAskWindow, hotkey: str) -> None:
    """用 pynput 注册全局热键；不可用时退回「只开一次窗口」。"""
    try:
        from pynput import keyboard  # type: ignore
    except ImportError:
        print(
            "未安装 pynput，无法自带全局热键。\n"
            "  · 直接显示输入框（可用系统快捷键触发）：python3 quickask_tk.py --show\n"
            "  · 或安装热键支持：pip3 install pynput（首次需在「隐私与安全性 → 辅助功能」中授权终端）",
            file=sys.stderr,
        )
        window.show()
        return

    combination = normalize_hotkey(hotkey)

    def on_activate() -> None:
        window.root.after(0, window.show_once)

    print(f"DSH Quick Ask (python) 常驻中，快捷键 {combination}", file=sys.stderr)
    listener = keyboard.GlobalHotKeys({combination: on_activate})
    listener.start()
    window.root.mainloop()


def main() -> int:
    argv = sys.argv[1:]
    config = load_config()

    if "--task" in argv:
        task = " ".join(argv[argv.index("--task") + 1:]).strip()
        if not task:
            print("quickask: --task 需要任务文本", file=sys.stderr)
            return 2
        return run_once(task, config)

    if "--hotkey" in argv:
        config["hotkey"] = argv[argv.index("--hotkey") + 1]

    window = QuickAskWindow(config, demo="--demo" in argv)
    if "--demo" in argv:
        window.show()
        return 0
    if "--show" in argv:
        window.show()
        return 0

    hotkey_loop(window, config["hotkey"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
