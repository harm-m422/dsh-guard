# dsh-guard

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

每一级都给足 **120 秒**——启动慢不等于启动失败；「起来了」的判据是端口在听或 HTTP 2xx/3xx。

1. **停用肇事插件**：从日志认出 `did not activate <插件>`，只往 patch 里插一行 `disabled: true`（先 YAML 校验，原文留 `.bak-guard`），弹二选一（去 GitHub 报错 / 忽略），然后重启。
2. **干净启动**：还起不来，就把**所有第三方插件**停用（核心模块的 id 覆盖不碰，例如 `compaction-basic`），patch 整份备份为 `.bak-clean`，再试一轮。
3. **校验 harness**：干净启动也失败，就检查 dsh 可执行文件在不在、能不能 `--version`、`DSH_HOME` 还有多少空间，然后弹窗告知「harness 可能彻底损坏，建议重装」。

一个细节：进程自己退出**不一定是失败**——退出码 0 或 ≥128（被信号杀掉，通常是用户关掉）视为正常结束，其它退出码才算崩溃，继续降级。

超时与端口可调：`DSH_HEALTH_TIMEOUT`（默认 120）、`DSH_WEB_PORT`（默认 3080）。

## 装

```bash
./install.sh              # 装到 ~/.local/bin
./install.sh --desktop    # 顺带建「DSH（守护启动）」桌面入口
./install.sh --uninstall  # 卸载
```

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
