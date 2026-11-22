# coding: utf-8
"""
录音提示音模块

按下快捷键开始录音、再按一次结束录音时，各播放一声「叮」，让用户不看屏幕也知道
当前是"正在录音"还是"已经停止"。

- 音效不依赖任何素材文件：首次使用时用正弦波 + 指数衰减包络现场合成，
  写到客户端目录下的 cue\start.wav 与 cue\stop.wav，之后直接播放。
- 播放使用 winsound 的异步模式，不会阻塞快捷键回调。
- 想关掉提示音：把 config_client.py 里的 sound_cue 改成 False，重启客户端即可。
"""

from __future__ import annotations

import math
import struct
import wave
from pathlib import Path
from threading import Lock

from . import logger

_SAMPLE_RATE = 44100
_GENERATE_LOCK = Lock()
_CACHE: dict[str, Path] = {}

# 开始 / 结束 两种提示音的分音频率与时长（低音更"沉"，高音更"亮"）
_SPECS = {
    'start': {'freqs': (1046.5, 2093.0), 'duration': 0.16, 'decay': 11.0},
    'stop': {'freqs': (783.99, 1567.98), 'duration': 0.30, 'decay': 7.0},
}


def _cue_dir() -> Path:
    """提示音缓存目录（客户端根目录下的 cue 文件夹）"""
    root = Path(__file__).resolve().parents[3]
    d = root / 'cue'
    d.mkdir(parents=True, exist_ok=True)
    return d


def _bell_wav(path: Path, freqs, duration: float, decay: float, amp: float = 0.32) -> None:
    """合成一声钟响：几个分音叠加 + 8ms 起音 + 指数衰减，写成 16bit 单声道 wav"""
    n = int(_SAMPLE_RATE * duration)
    frames = bytearray()
    two_pi = 2.0 * math.pi
    for i in range(n):
        t = i / _SAMPLE_RATE
        attack = min(1.0, t / 0.008)          # 起音，避免爆音
        env = attack * math.exp(-t * decay)   # 指数衰减
        s = 0.0
        for k, f in enumerate(freqs):
            s += math.sin(two_pi * f * t) / (k + 1)
        v = int(max(-1.0, min(1.0, s * env * amp)) * 32767)
        frames += struct.pack('<h', v)
    with wave.open(str(path), 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(_SAMPLE_RATE)
        w.writeframes(bytes(frames))


def _cue_file(kind: str) -> Path | None:
    """取（必要时生成）提示音文件路径"""
    spec = _SPECS.get(kind)
    if spec is None:
        return None
    with _GENERATE_LOCK:
        cached = _CACHE.get(kind)
        if cached is not None and cached.exists():
            return cached
        try:
            path = _cue_dir() / f'{kind}.wav'
            _bell_wav(path, spec['freqs'], spec['duration'], spec['decay'])
            _CACHE[kind] = path
            return path
        except Exception as e:
            logger.warning(f"生成提示音失败: {e}")
            return None


def _enabled() -> bool:
    """读取配置开关（config_client.sound_cue）"""
    try:
        from config_client import ClientConfig
        return bool(getattr(ClientConfig, 'sound_cue', True))
    except Exception:
        return True


def play_cue(kind: str) -> None:
    """
    播放提示音（异步，不阻塞调用线程）

    Args:
        kind: 'start' 开始录音；'stop' 结束录音
    """
    if not _enabled():
        return
    path = _cue_file(kind)
    if path is None:
        return
    try:
        import ctypes
        # 直接调用 winmm.PlaySoundW（异步、失败不回落系统提示音），
        # 客户端内置的解释器没有 winsound 模块，只能走 Win32 API。
        SND_FILENAME = 0x00020000
        SND_NODEFAULT = 0x00000002
        SND_ASYNC = 0x00000001
        ok = ctypes.windll.winmm.PlaySoundW(
            str(path),
            None,
            SND_FILENAME | SND_NODEFAULT | SND_ASYNC,
        )
        if not ok:
            logger.debug(f"播放提示音失败: PlaySoundW 返回 0, {path}")
    except Exception as e:
        logger.debug(f"播放提示音失败: {e}")
