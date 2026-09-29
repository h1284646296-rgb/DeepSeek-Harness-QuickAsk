#!/usr/bin/env python3
"""合成一声「duang」。

纯标准库（`wave` + `math`），不依赖 numpy。所谓 duang，是一种带弹簧感的
低频拟声：一记闷响开头，随后是一段音高快速下滑、带颤音的余韵，中间还有两下
回弹。这里按这个结构叠四层：

  1. 闷响   —— 82Hz / 61Hz 正弦，极快衰减
  2. 脆音   —— 6ms 噪声，负责起手的「啪」
  3. 本体   —— 660→132Hz 指数扫频 + 16Hz 颤音
  4. 回弹   —— 0.15s / 0.30s 两次低幅重复，负责「弹」

用法: python3 tools/make-duang.py Resources/duang.wav
"""

from __future__ import annotations

import math
import random
import struct
import sys
import wave

RATE = 44100
DURATION = 0.85
TAU = 2 * math.pi

# (起始时刻, 起始频率, 终止频率, 幅度)
BOUNCES = (
    (0.000, 660.0, 132.0, 0.75),
    (0.150, 470.0, 118.0, 0.42),
    (0.300, 360.0, 104.0, 0.20),
)
SWEEP = 3.4          # 频率下滑速度
VIBRATO_HZ = 16.0    # 颤音频率
VIBRATO_DEPTH = 0.11 # 颤音深度


def envelope(dt: float, attack: float, decay: float) -> float:
    """从起点起算的「快起慢落」包络；dt 为负表示尚未开始。"""
    if dt < 0:
        return 0.0
    if dt < attack:
        return dt / attack
    return math.exp(-(dt - attack) / decay)


def spring_phase(dt: float, f_start: float, f_end: float) -> float:
    """频率 f(t)=f_end+(f_start-f_end)·e^(-SWEEP·t) 的解析相位积分。

    用解析式而不是逐样本累加，是为了避免重采样/拼接处出现相位跳变造成的爆音。
    """
    return TAU * (f_end * dt + (f_start - f_end) / SWEEP * (1.0 - math.exp(-SWEEP * dt)))


def render() -> list[float]:
    total = int(RATE * DURATION)
    samples: list[float] = []
    rng = random.Random(20140224)  # 「duang」成名的年份，图个彩蛋

    for index in range(total):
        t = index / RATE
        value = 0.0

        # 1) 闷响
        value += 0.55 * envelope(t, 0.002, 0.055) * math.sin(TAU * 82.0 * t)
        value += 0.28 * envelope(t, 0.002, 0.035) * math.sin(TAU * 61.0 * t)

        # 2) 起手脆音
        if t < 0.006:
            value += 0.35 * (1.0 - t / 0.006) * (rng.random() * 2 - 1)

        # 3)+4) 本体与回弹
        for t0, f_start, f_end, amplitude in BOUNCES:
            dt = t - t0
            if dt < 0:
                continue
            carrier = math.sin(spring_phase(dt, f_start, f_end))
            # 颤音：对载波做频率调制，等价于在上面解析相位上叠加一个小正弦
            vibrato = VIBRATO_DEPTH * math.sin(TAU * VIBRATO_HZ * dt)
            value += amplitude * envelope(dt, 0.004, 0.20) * carrier * (1.0 + vibrato)

        samples.append(value)

    # 软削波 + 归一化，避免数字爆音
    peak = max(abs(sample) for sample in samples) or 1.0
    scale = 0.92 / peak
    return [math.tanh(sample * scale * 1.15) * 0.95 for sample in samples]


def write_wav(path: str, samples: list[float]) -> None:
    with wave.open(path, "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(RATE)
        frames = bytearray()
        for sample in samples:
            clipped = max(-1.0, min(1.0, sample))
            frames += struct.pack("<h", int(clipped * 32767))
        handle.writeframes(bytes(frames))


def main() -> int:
    path = sys.argv[1] if len(sys.argv) > 1 else "duang.wav"
    write_wav(path, render())
    print(f"make-duang: wrote {path} ({DURATION:.2f}s, {RATE}Hz mono)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
