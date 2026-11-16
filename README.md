# dsh-guard

> ⚠️ **这不是 DSH 插件。**
>
> 仓库里没有 `package.json`，**插件管理器的「安装」按钮对它无效** —— 它必须跑在 harness
> 进程外面（做成插件，最需要它的时候它自己也不在）。
>
> 装它只有一条路：`./install.sh`（Windows 走 `windows\dsh-guard.ps1`）。见下方「装」。

DSH 插件的**体检与启动自愈**工具——一个插件把 harness 拖得起不来时，它负责把那个插件停掉、把 harness 拉回来，并告诉你发生了什么。

## 为什么在进程外

DSH 的 web boot 只要有一个插件没激活，就停在它自己的 `Failed to load plugins` 页面：
应用不会挂载，插件的 `ctx` 也不会创建。**那时候没有任何插件跑得起来**，所以「应用内报错」这条路在致命失败时是死的。

dsh-guard 站在进程外面看日志、改配置、重启。

## 用法

```bash
dsh-guard --check            # 体检：profile 里每个插件能不能装起来
dsh-guard --heal-log <日志>  # 事后：认出肇事插件，停用它并弹窗告知
dsh-guard                    # 守护启动：起 dsh web，失败则自愈并重启一次
```

`--check` 的样子：

```
profile : /home/you/.dsh/profiles/web
patch   : /home/you/.dsh/profiles/web/cordis.patch.yml
yaml    : ok (11 rows)
engine  : dsh-memory    enabled  v1.4.0  可加载（./index.js）
engine  : dsh-liquid    enabled  v3.0.0  可加载（lib/index.js）
engine  : @deepseek-ai/dsh-client-ui-theme enabled  核心包（在 dsh 安装目录里）
```

## 它怎么自愈（三级阶梯）

每一级都给足 **120 秒**——启动慢不等于启动失败；「起来了」的判据是端口在听或 HTTP 2xx/3xx，
**并且度过宽限期**（`DSH_GUARD_GRACE`，默认 120 秒）——启动后中途崩掉算假成功，继续降级。

1. **停用肇事插件**：从日志认出 `did not activate <插件>`，只往 patch 里插一行 `disabled: true`（先 YAML 校验，**动手前先落一份快照**），弹二选一（去 GitHub 报错 / 忽略），然后重启。
2. **干净启动**：还起不来，就把**所有第三方插件**停用（核心模块的 id 覆盖不碰，例如 `compaction-basic`），——同样先落快照，再试一轮。
3. **校验 harness**：干净启动也失败，就检查 dsh 可执行文件在不在、能不能 `--version`、`DSH_HOME` 还有多少空间，然后弹窗告知「harness 可能彻底损坏，建议重装」。

一个细节：进程自己退出**不一定是失败**——退出码 0 或 ≥128（被信号杀掉，通常是用户关掉）视为正常结束，其它退出码才算崩溃，继续降级。

超时与端口可调：`DSH_HEALTH_TIMEOUT`（默认 120）、`DSH_WEB_PORT`（默认 3080）。

## 装

```bash
./install.sh              # 装到 ~/.local/bin
./install.sh --desktop    # 顺带建「DSH（守护启动）」桌面入口
./install.sh --uninstall  # 卸载
```

### 更新

```bash
rm -rf dsh-guard && unzip dsh-guard-X.Y.Z.zip   # 先删旧目录，别直接覆盖解压
cd dsh-guard && ./install.sh --desktop
```

三个坑，都是实测出来的：

- **直接 `unzip` 覆盖会失败**：目标文件已存在时它会问 `replace …? [y]es, [n]o…`，
  非交互环境下读不到输入，直接 `(EOF or read error, treating as "[N]one")` 并以 **exit 1** 退出 ——
  `&&` 链断在这里，安装根本没跑。
- **`unzip -o` 能过，但不删旧文件**：新版本里去掉或改名的文件会留在原地。
- **只解压不会更新已安装的副本**：`install.sh` 做的是**拷贝**，不是软链，
  `~/.local/bin/dsh-guard` 仍是旧的。必须重跑 `./install.sh`。

快照与状态都在 `$DSH_HOME` 下，更新不会动它们。

## 边界

- **Linux/macOS** 用 `dsh-guard`（看日志自愈）；**Windows 桌面版**用 `windows\dsh-guard.ps1`：自己启动桌面版、从输出里取系统分配的端口、按同样的三级阶梯恢复（体检 → 停用点名的插件 → 干净启动 → 校验并建议重装）。
- 插件里那层「apply 不抛错」的兜底是跨平台通用的。
- 只处理**启动失败**。插件装上了但工具报错、路由 500 这类，它看不见。
- 不替用户更新插件、不自动联网。

## 文件

```
dsh-guard      主脚本（bash + python3）
install.sh     安装/卸载
README.md      这份
README-AI.md   给 AI 照着装的版本
```

---

## 1.1：改配置之前先留证

**快照，不是覆盖。** 以前写 `cordis.patch.yml.bak-guard` / `.bak-clean` 两个固定文件名，
连着自愈两次，第一次的原文就没了。现在每次动 patch 之前先落一份：

```
$DSH_HOME/guard-snapshots/<时间戳>-<原因>/
    cordis.patch.yml   # 改动前的原文
    AT                 # 什么时候
    REASON             # 为什么改
```

只留最近 5 份（`DSH_GUARD_SNAP_KEEP`），被挤出去的**挪进 `trash/`，不删**。
另外镜像一份 `last-good/`：最后一次通过宽限期确认可用的那份配置，出事后先看它。

**「起来了」不等于「好了」。** 端口在听只说明开始服务了。启动后在宽限期
（`DSH_GUARD_GRACE`，默认 120 秒）里持续盯着：进程没了、端口掉了、日志里出现失败
标记，都算没起来，继续降级。通过宽限期才写 `last-good`。

**启动命令只有一套探测。** 以前 `WEB_CMD` 写死过 `0.2.2-rc.1`，而第 4 级校验用的是
动态扫最新版本——dsh 一升级就会出现"起不来 + 体检说你好好的"。现在两处共用
`find_dsh_cli`：扫 `~/.dsh-cli/*`，再退 `~/.npm/_npx/*`，最后才回落 `dsh web`。
`dsh-guard --web-cmd` 可以直接看会执行什么。

**测试。** `node test.mjs`，24 项，全部在自己的临时 `DSH_HOME` 里跑：快照轮转、
宽限期（起来又崩 / 稳定服务）、启动命令解析、体检、幂等、注释保留、干净启动只停
第三方。不会碰真实 profile。

```
$ node test.mjs
24/24 passed
```

Windows 版另有一套，逻辑层在 Linux 上用 pwsh 7 也能跑：

```
$ pwsh -NoProfile -File windows/test.ps1
11/11 passed
```

覆盖体检、快照轮转（连着两次不覆盖 / 不写固定 `.bak`）、宽限期两分支、`last-good`。
它**不能代替 Windows 实测**：`Start-Process` 重定向、桌面版 exe 的路径探测、GUI 弹窗，
只有真 Windows 能验。

### Windows 版同步（windows/dsh-guard.ps1）

同样的三处已经一起改了：

- **快照**：`%USERPROFILE%\.dsh\guard-snapshots\<时间戳>-<原因>\`，留 5 份，旧的进 `trash\`；`last-good\` 镜像最后一次确认可用的配置
- **宽限期**：`-GraceSec`（默认 120）——端口通了之后再守一段，期间进程退出/端口掉了都算没起来
- **点名插件**：`did not activate` 两种语序都认

顺带修掉一个真 bug：`noentry`（package.json 指的入口文件不存在）和 `missing`（patch 里有、盘上没有）
以前只打印不处理，而这两种同样会让 boot 停在 "Failed to load plugins"，现在都进了停用名单。

```
cd windows
pwsh -NoProfile -File test.ps1      # 11 项，在 Linux 上也能跑
```
