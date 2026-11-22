# CapsWriter-Offline 中文化增强版（Ctrl+空格 切换录音）

> 基于 [HaujetZhao/CapsWriter-Offline](https://github.com/HaujetZhao/CapsWriter-Offline) **v2.6** 的客户端源码补丁 + Windows 守护/自启动脚本。
> 把原版「按住 CapsLock 说话」改成 **「按一下 Ctrl+空格 开始录音，再按一下结束」**，并解决「重启后不能用了」「一堆黑窗口」「没有任何提示音」「进程坏了不会自己恢复」等实际问题。

原版是完全离线、免费、中文识别质量很好的语音输入工具（SenseVoice-Small 引擎，20 秒音频 CPU 约 0.6 秒出结果）。本仓库**不改模型、不改协议**，只补客户端交互与 Windows 驻留部分。

---

## 功能与改动一览

| 功能 | 原版 v2.6 | 本补丁 |
| --- | --- | --- |
| 触发录音 | 按住 CapsLock（长按模式） | **Ctrl+空格 单击切换**（按一下开始，再按一下结束） |
| 组合键 | 文档里写了 `ctrl+shift+a`，但代码只做单键匹配，实际不支持 | 真正实现「修饰键 + 主键」匹配，只在 Ctrl 物理按下时吞掉空格 |
| 长按 | 单击模式下按住 0.24 秒就被 `cancel()` 取消 | 按下立即切换；按住不松只忽略重复按键 |
| 提示音 | 无 | 开始「叮」(1046/2093Hz)、结束「叮」(784/1568Hz)，纯代码合成，无需音频素材 |
| 静音 | 识别结果只有一个「。」时照样往光标处插一个句号 | 结果只有标点时输出空串 |
| 默认引擎 | `qwen_asr` | `sensevoice`（CPU 上更快更准，自带标点，适合无独显机器） |
| Windows 驻留 | 手动双击两个 exe，出现两个控制台窗口 | 守护进程 + 开机自启，**无控制台窗口**（`CREATE_NO_WINDOW`） |
| 故障恢复 | 卡死/管道断开/进程残留 → 必须手动重启 | 每 4 秒自检：进程缺失、进程树损坏、`BrokenPipe`、连接断开 → 自动重启对应部分 |

---

## 安装（Windows）

1. **下载官方 v2.6 发行包**（同一目录解压）：
   - `client.zip` → `CapsWriter-Offline-Client/start_client.exe`
   - `server.zip` → `CapsWriter-Offline/start_server.exe`
2. **下载模型**（release tag `models`，约 414 MB）：
   `Sensevoice-Small-ONNX.zip` → 解压到
   `<安装根目录>/server/CapsWriter-Offline/models/SenseVoice-Small/Sensevoice-Small-ONNX/`
   解压后该目录下应有：`SenseVoice-Encoder.fp16.onnx`、`SenseVoice-CTC.fp16.onnx`、`tokenizer.bpe.model`
3. **应用补丁**（二选一）：
   - 方式 A：把 `patch.diff` 放在解压后的根目录，`git apply patch.diff`
   - 方式 B：把 `overlay/` 下的文件按相同相对路径覆盖过去
4. **复制脚本**：把 `scripts/` 下的全部文件放到**安装根目录**（也就是 client、server 两个文件夹的上一级）
5. 双击 `启动语音输入.bat`（或桌面「CapsWriter 语音输入」快捷方式）

解压后的目录结构应类似：

```
CapsWriter-Offline/                ← 安装根目录（脚本放这里）
├─ server/CapsWriter-Offline/      ← 官方服务端 + models/
├─ client/CapsWriter-Offline-Client/ ← 官方客户端（打上补丁）
├─ supervisor.ps1
├─ start_supervisor.vbs
├─ stop_caps.bat
├─ 启动语音输入.bat
└─ logs/supervisor.log
```

> 说明：**模型与 exe 不在本仓库**（体积太大且非本作者所有），请从官方 release 下载。本仓库只有源码改动和脚本，合计几十 KB。

---

## 具体改了什么

### 1. 组合键支持 — `core/client/shortcut/shortcut_manager.py`
原版只有 `self.tasks: Dict[key_name, task]` 单键匹配，`'ctrl+space'` 永远不会命中。补丁新增：

```python
self.combo_tasks: Dict[str, tuple] = {}      # 主键 -> (task, 需要的修饰键集合)

# _init_tasks 中按 '+' 拆分注册
if '+' in key_name:
    *mods, main = [k.strip().lower() for k in key_name.split('+')]
    self.combo_tasks[main] = (task, frozenset(mods))
    continue

@staticmethod
def _mods_down() -> set[str]:                 # GetAsyncKeyState 读取真实物理键状态
    ...                                       # ctrl 0x11 / shift 0x10 / alt 0x12 / win 0x5B

def _handle_combo(self, key_name: str, msg) -> bool:
    task, mods = self.combo_tasks[key_name]
    down = self._mods_down()
    # 只允许多按修饰键，不允许别的键混进来；命中后只吞主键本身
    if mods <= down and not (down - mods):
        self.suppress_event()
        ...
```

关键点：**只 suppress 主键（空格）**，Ctrl 本身照常传给应用；不按 Ctrl 时打空格完全不受影响（日志里是 `修饰键=[] 匹配=False`）。

### 2. 单击切换 — `core/client/shortcut/event_handler.py`
原版单击模式在 `_manage_task` 里 `task.event.wait(timeout=task.threshold * 0.8)`（约 0.24 秒），超时即 `task.cancel()`，所以按得稍慢一点就「没反应」。补丁把状态机改成：

```python
if task.pressed:      # 按住时系统发来的重复 keydown 直接忽略
    return
task.pressed = True
task.released = False
if task.is_recording:
    task.finish()     # 第二次按下 -> 结束并上屏
else:
    task.launch()     # 第一次按下 -> 开始录音
```

`keyup` 只把 `pressed` 置回 `False`，不做任何切换。这样长按、连击都不会误触发。

### 3. 录音提示音 — `core/client/audio/cue.py`（新增）
用 sin + 指数衰减合成钟声，首次运行生成 `client/cue/start.wav`、`stop.wav`（删掉会自动重建），播放走 Win32：

```python
ctypes.windll.winmm.PlaySoundW(path, None, SND_FILENAME | SND_NODEFAULT | SND_ASYNC)
```

（客户端内置的 Python 精简环境**没有 winsound 模块**，所以必须走 `winmm`。）
`task.py` 的 `launch()` / `finish()` 各调一次 `play_cue('start'/'stop')`，开关是 `config_client.py` 里的 `sound_cue`。

### 4. 静音不插标点 — `core/client/output/text_output.py`
`strip_punc()` 里加一条：如果去掉标点后是空串，就输出空串，而不是把「。」打进当前窗口。

### 5. 配置 — `config_client.py` / `config_server.py`
- 快捷键只留一个：`{'key': 'ctrl+space', 'suppress': True, 'hold_mode': False}`（删掉会互相打断的鼠标侧键 x2；CapsLock 恢复普通功能）
- `language = 'chinese'`、`paste = False`、`sound_cue = True`
- 服务端 `model_type = 'sensevoice'`

---

## 守护进程（`supervisor.ps1`）

由 `start_supervisor.vbs` 用 `wscript` 隐藏启动，单实例（Global Mutex），每 4 秒检查：

1. `start_server.exe` 进程不存在 → 启动；
2. **进程树损坏**（只剩 1～2 个残骸进程、没有唯一的启动器进程）→ 杀掉全部残骸后整套重启。
   这是实际踩到的坑：手动结束启动器后，残留进程还占着 6016 端口、看起来「正常」，但任务提交进去永远不回结果；
3. 服务端日志出现 `BrokenPipeError` / `WinError 232` → 重启服务端（25 秒冷却）并重启客户端；
4. 端口 6016 连续约 60 秒探测不到 → 重启服务端；
5. 客户端进程不存在 → 启动；进程在但没有 ESTABLISHED 连接（连续 10 次）→ 重启客户端；
6. 子进程一律用 `CreateProcess(..., CREATE_NO_WINDOW)` 启动，**不会出现控制台黑窗**；
   守护可选暂停：在根目录放一个 `pause.flag`。

日志：`logs/supervisor.log`（超过 1 MB 自动轮转）。

---

## 常见问题

**按 Ctrl+空格 没反应？** 看 `logs/supervisor.log` 最近几行；或双击「CapsWriter 停止」再双击「CapsWriter 语音输入」。

**说完没有字？** 服务端正常时有 3 个 `start_server.exe`（启动器 + 约 1 GB 模型进程 + 约 60 MB 管理进程）。手动结束其中任何一个都会导致 `BrokenPipeError: [WinError 232] 管道正在被关闭`，所有识别失败——现在守护会自动重启。

**Ctrl+空格 冲突？** 该组合键被本软件占用（浏览器、编辑器的「自动补全」也会失效）。改键：`config_client.py` 的 `shortcuts` 里把 `key` 换成 `f9`、`alt+q` 等，重启客户端。

**模型放哪？** `server/CapsWriter-Offline/models/SenseVoice-Small/Sensevoice-Small-ONNX/`，文件名必须完全一致。

---

## 许可与致谢

- 上游项目：**HaujetZhao/CapsWriter-Offline**，MIT License，Copyright (c) 2026 Haujet Zhao。
- 本仓库的补丁与脚本同样以 MIT 发布；`patch.diff` 与 `overlay/` 中的文件均为对上游 v2.6 源码的修改，版权归上游作者。
- 软件升级会覆盖 `overlay` 里的改动，升级后需要重新打补丁。
