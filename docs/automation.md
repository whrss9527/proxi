# 自动化：命令行、AI 助手和快捷指令

[← 回到 README](../README.zh-CN.md)

Proxi 在本机开了一个控制接口（Unix 套接字 `~/Library/Application Support/Proxi/control.sock`，只有你自己的账户能连）。命令行工具、MCP 服务器（给 AI 助手用）和 URL 命令都经它操作正在运行的 Proxi，用的是同一套工具。它们只能查看状态、开关代理、切换配置和测试连接，不能改配置。

能做到哪一步由设置 →「自动化」里的**权限**决定：

| 权限 | 能做什么 |
| --- | --- |
| 关闭 | 接口不开，命令行和 AI 助手都连不上 |
| 只能查看 | 查看状态、代理配置和日志 |
| 开关和切换（默认） | 另外可以开关代理、切换配置、测试连接 |

## 命令行

在「自动化」页点「安装命令行工具」，会在 `/usr/local/bin/proxi` 放一个小脚本（要输一次管理员密码）；用 Homebrew 安装的已经带好了。不装也可以直接运行 `/Applications/Proxi.app/Contents/MacOS/Proxi <命令>`。Proxi 没在运行时会自动在后台打开。改名前装过 `proxyswitch` 命令的，它会一直转给新程序，照样能用。

```bash
proxi status                  # 代理现在的状态、系统代理指向哪里
proxi profiles                # 代理配置
proxi on                      # 开启上次用的配置
proxi on 公司代理               # 开启某个配置
proxi use Charles             # 切换到某个配置并开启（名字可以只写一部分，唯一匹配就行）
proxi off                     # 关闭：系统代理、终端环境变量、git、npm 的代理都清掉
proxi toggle
proxi test                    # 测试全部配置能不能连上；proxi test Charles 只测一个
proxi logs 50                 # 最近 50 行日志
proxi call use_profile '{"profile":"公司代理"}'   # 直接调用某个工具
```

加 `--json` 输出完整的 JSON。退出码：0 成功，1 出错，2 用法不对，3 权限不够。

`status --json` 的 `proxy.targets` 是配置要求开启的范围，`proxy.appliedTargets` 是 Proxi 成功写入、关闭时需要清理的范围。`proxy.targetStates` 分别报告 `system`、`environment`、`git`、`npm` 的状态：`notApplied`、`applied`、`failed` 或 `changedExternally`。开启某个范围失败时，其他成功的范围仍会保留并可以关闭；查看 `lastError` 可了解本次操作的失败原因。

## AI 助手（MCP）

支持 MCP 的 AI 客户端（Claude Desktop、Claude Code、Cursor 等）加上下面的配置，就能让 AI 查看代理状态、开关代理、切换配置和测试连接：

```json
{
  "mcpServers": {
    "proxi": {
      "command": "/Applications/Proxi.app/Contents/MacOS/Proxi",
      "args": ["mcp"]
    }
  }
}
```

Claude Code 可以用命令添加：

```bash
claude mcp add proxi -- /Applications/Proxi.app/Contents/MacOS/Proxi mcp
```

「自动化」页里有现成的配置，路径是按程序实际的位置生成的，点「复制」就行。改名前加过的配置写的是 `ProxySwitch.app` 里的路径，要换成新的。

MCP 服务器初始化时会把使用规则告诉 AI 助手：先看状态再动手、只做用户要求的事、开关和切换前先说明。

### 工具

| 工具 | 权限 | 作用 |
| --- | --- | --- |
| `get_status` | 查看 | 开没开、用的哪个配置、系统代理现在指向哪里、代理服务器能不能连上 |
| `list_profiles` | 查看 | 代理配置（名字、类型、地址、生效范围） |
| `get_logs` | 查看 | Proxi 的日志（`lines`） |
| `turn_on` | 开关和切换 | 开启代理（可带 `profile`，不带就开上次用的） |
| `use_profile` | 开关和切换 | 切换到某个配置并开启（`profile`） |
| `turn_off` / `toggle` | 开关和切换 | 关闭、开关代理 |
| `test_profiles` | 开关和切换 | 经配置访问一次测试地址，看能不能连上、要多久（`profile`，不写测全部） |

## URL 命令与快捷指令

```bash
open "proxi://toggle"                     # 开关代理；on、off 同理
open "proxi://use?name=公司代理"            # 切换到某个配置并开启
open "proxi://run?tool=test_profiles"     # 执行一个工具（参数写在后面：&profile=Charles）
open "proxi://panel"                      # 打开菜单栏面板
open "proxi://settings?page=automation"   # 打开设置的某一页：profiles、automation、general、hotkey、sync、diagnostics、about
open "proxi://update"                     # 检查更新，有新版本就直接安装
```

URL 命令和命令行一样受权限限制。改名前的 `proxyswitch://` 开头的写法照样认。

快捷指令里用「打开 URL」执行这些命令，或者用「运行 Shell 脚本」调用 `proxi` 命令（先安装命令行工具）。

## 按网络自动切换

「自动化」页里加规则：连上某个 Wi‑Fi（或者路由器是某个 MAC / IP）时开启某个配置或者关闭代理；「其他网络」在上面都不符合时生效。比如在公司的 Wi‑Fi 自动开公司代理、回家自动关掉。同一个网络只切一次，之后手动改了不会被改回去，换了网络才会再按规则切；一键更新、换界面语言后重新启动也不会再切一次。

读 Wi‑Fi 名字要定位权限（macOS 14 起系统这样规定，Proxi 不读取、不保存位置）；不给的话可以按路由器的 MAC 地址认。
