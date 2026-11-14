# 给 AI 的安装说明：dsh-guard

> 这份文档是给 **AI agent** 看的：每一步都有确切命令和验收标准，照着做即可，不要即兴发挥。
> 用户通常会说：「按这份说明把 dsh-guard 装到我的机器上」。

> ⚠️ **它不是插件，装不进插件目录。**
> 仓库里没有 `package.json`，所以 `plugin_manager` / `install_bundle` / 插件管理器的
> 「安装」按钮**对它全部无效** —— 不要尝试，也不要把这当成安装失败。
> 它必须跑在 harness 进程外面（做成插件，最需要它的时候它自己也不在）。
> **唯一正确的装法是 `./install.sh`**；Windows 走 `windows\dsh-guard.ps1`。

## 它是什么

一个**进程外**的 DSH 插件体检与启动自愈工具。

- `dsh-guard --check`：列出 profile 里每个插件能不能被装起来（YAML 能否解析、入口能否 import、版本、启用状态）。
- `dsh-guard --heal-log <日志>`：从启动日志里认出是哪个插件让 web boot 失败，只给它插一行 `disabled: true`（先备份 `.bak-guard`），然后弹窗告知。
- `dsh-guard`：前台启动 `dsh web`，启动失败时自动停用肇事插件并重启一次。

**它不能做什么**（不要向用户承诺）：不能在应用内显示告示（启动失败时应用根本没挂载）；这个 bash 脚本不支持 Windows（Windows 走 `windows\dsh-guard.ps1`）；不会替你更新插件。

## 前置检查（先做，失败就停）

```bash
command -v bash python3 >/dev/null && echo ok
python3 -c "import yaml" 2>/dev/null && echo yaml-ok || echo "yaml 缺失：体检的 YAML 校验会跳过，其余功能不受影响"
test -d "$HOME/.dsh" && echo dsh-home-ok || echo "还没有 ~/.dsh：先让用户启动一次 DSH 再装"
```

若系统是 Windows：**不要装 Linux 版**，改走文末「Windows 桌面版」那一节（`windows\dsh-guard.ps1`）。

## 安装（三条命令）

```bash
cd <解压后的目录>
chmod +x install.sh dsh-guard
./install.sh --desktop
```

`install.sh` 会：把 `dsh-guard` 装到 `~/.local/bin`、立刻跑一次体检、建桌面入口「DSH（守护启动）」。
它**不会**修改用户的其它插件配置，也**不会**用 sudo。

## 验收（全过才算装好）

```bash
~/.local/bin/dsh-guard --check        # 应打印每一行 engine 与 yaml ok
test -x ~/.local/bin/dsh-guard && echo binary-ok
```

守护启动（不带参数）会走三级阶梯：停用肇事插件 → 干净启动 → 校验 harness 并告知重装，每级等 120 秒。想缩短等待用 `DSH_HEALTH_TIMEOUT=20`，换端口用 `DSH_WEB_PORT=3081`。

`--check` 的正常输出形如：

```
profile : /home/<user>/.dsh/profiles/web
patch   : .../cordis.patch.yml
yaml    : ok (11 rows)
engine  : dsh-memory    enabled  v1.4.0  可加载（./index.js）
engine  : dsh-liquid    enabled  v3.0.0  可加载（lib/index.js）
```

若某行出现「加载失败 -> …」，**把这一行原样报告给用户**，不要自行卸载任何插件。

## 接到启动路径（二选一，问用户偏好）

1. **用新入口**：以后从「DSH（守护启动）」启动，而不是原来的开关。
2. **接进现有启动脚本**（用户已有 `~/.local/bin/dsh-toggle.sh` 时）：在该脚本「启动成功」之后加一段
   `~/.local/bin/dsh-guard --heal-log ~/.cache/dsh-desktop/dsh-web.log`，命中即表示有插件拖垮了启动、已被停用。

改用户脚本前**先备份**（`cp script script.bak-$(date +%Y%m%d)`），改完 `bash -n` 验语法。

## 卸载

```bash
./install.sh --uninstall
```

只删二进制与桌面入口；`--heal-log` 留下的 `.bak-guard` 备份不动。

## 失败时怎么回报

- `--check` 抛错 → 贴完整 stderr。
- 插件「加载失败」→ 贴那一行（插件名 + 版本 + 错误前 160 字）。
- 已装但用户说没效果 → 确认他们**从哪个入口启动**的：只有走 dsh-guard（或接进启动脚本）时才有自愈。

## 给用户的模板句（可直接粘给别的 AI）

> 我有一份 dsh-guard 的压缩包。请按 `README-AI.md` 把它装到我的机器上：
> 先做前置检查，再运行 `./install.sh --desktop`，然后跑 `~/.local/bin/dsh-guard --check`
> 把完整输出贴给我。全程不要用 sudo，不要改我其它插件的配置。

---

## Windows 桌面版（另一个实现，不是同一份脚本）

Windows 上没有 bash，桌面版也从快捷方式启动、没有控制台，所以那边**不做“看日志再救”**，改成**启动前体检**：

- 用桌面版自己的运行时（Electron 的 Node）把 profile 里每个插件 import 一次；
- 导不进来就说明它一定会把启动拖垮 —— 先在 `cordis.patch.yml` 里停用它（只插一行，留 `.bak-guard`）；
- 然后才启动桌面版，并弹一个提示框告诉你停用了谁。

### 给 AI 的步骤

```powershell
cd <解压后>\windows
powershell -NoProfile -ExecutionPolicy Bypass -File .\dsh-guard.ps1 -Check
```

`-Check` 只体检、不改任何文件。确认输出里没有 `fail` 之后：

```powershell
.\dsh-guard.cmd            # 体检 → 停用坏插件 → 启动桌面版
.\dsh-guard.cmd -NoLaunch  # 体检 → 停用，但不启动
.\dsh-guard.cmd -DshHome "D:\my\.dsh"   # 桌面版数据目录不在默认位置时
```

默认数据目录：`%USERPROFILE%\.dsh\profiles\web\cordis.patch.yml`。
找不到时脚本会直接说“没有找到 profile”，**不要猜路径**，让用户告诉你 `%USERPROFILE%\.dsh` 是否存在。

### 验收

`-Check` 输出形如：

```
profile : C:\Users\me\.dsh\profiles\web\cordis.patch.yml
runtime : C:\Users\me\AppData\Local\Programs\DeepSeek Harness\DeepSeek Harness.exe
engine  : dsh-memory        ok  可加载
engine  : @deepseek-ai/...  core（在桌面版安装目录里）
```

### 它怎么判断“起没起来”

桌面版的端口是**系统分配**的（官方文档：Desktop 默认监听系统分配的端口，profile 配置可覆盖），
配置里查不到。所以脚本自己启动桌面版并重定向输出，从这一行里取端口：

```
dsh web: http://127.0.0.1:<PORT>/?token=...
```

拿到端口就对它发一个 HTTP 请求；通了算起来，120 秒还没通算失败。

### 三级阶梯

1. 启动前体检：导不进来的插件先停用；
2. 启动 → 等 120 秒 → 日志点名了某个插件就停用它再等 120 秒；
3. 还不行 → 干净启动（停用全部第三方插件）再等 120 秒；
4. 仍失败 → 校验安装目录与日志，弹窗「harness 可能彻底损坏，建议重新装」。

`-WaitSec 30` 可以缩短等待，调试时很有用。

### 已知限制

- 桌面版安装位置按三个常见路径找；不在其中就传 `-AppPath`。
- 只拦「导入失败」与「启动超时」；插件装上后工具报错这类它看不见。
- 假阳性的代价很低：停用只插一行，原文留 `.bak-guard`，随时可以删掉那行恢复。
