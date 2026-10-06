# Proxi 使用指南

[← 回到 README](../README.zh-CN.md)

Proxi 是给开发者用的代理开关：一键把系统代理、终端、git 和 npm 指向你自己指定的代理服务器，比如公司代理、内网网关，或者本机的 Charles、Proxyman、mitmproxy 这类调试代理。Proxi 自己不提供代理服务，也不转发流量。

## 安装

1. 用 [Homebrew](https://brew.sh)：`brew install --cask whrss9527/tap/proxi`，同时装好 `proxi` 命令。
2. 或者在 [Releases](../../releases) 下载 `Proxi-macos.zip`（通用包，Intel 和 Apple 芯片都能用；`-arm64` / `-x86_64` 结尾的是只含一种芯片的精简包），解压后把 `Proxi.app` 拖到「应用程序」。
3. 用 Developer ID 签名并经过苹果公证的版本（Release 说明末尾会注明），解压后双击就能打开。没有公证的版本第一次打开会被系统拦下：macOS 15 及以后先双击一次，再到「系统设置 → 隐私与安全性」底部点「仍要打开」；macOS 14 在 `Proxi.app` 上右键 → 打开 → 再点「打开」；也可以在终端运行 `xattr -dr com.apple.quarantine /Applications/Proxi.app`。
4. 需要 macOS 14 或更新版本。
5. 之后的版本在程序里一键更新：有新版本时面板里会出现更新条，点「更新」就行，也可以在「关于」页或通知上点「立即更新」。如果程序是在下载文件夹里直接打开的（系统会把它放在只读的临时位置运行），更新时会自动装进「应用程序」，第一次可能会问能否访问「下载」文件夹（用来把旧的那份移到废纸篓）。

Windows 版在 [proxyswitch](https://github.com/whrss9527/proxyswitch)，两边功能各自演进。

### 从 0.12 及以前的版本更新

一键更新过来后，第一次启动时：

- 你自己添加的代理配置、快捷键、按网络自动切换的规则和 iCloud 同步都保留；
- 以前版本的其他设置和数据目录里的相关文件原样保留，另存一份备份，不会删除；需要时可以在「设置 → 扩展」里继续使用；
- 上次开着的配置指向一个现在没有程序监听的本机端口时，先把代理关掉（系统代理、终端环境变量、git 和 npm 代理都清掉），免得上不了网；
- 以前版本装过后台助手（在 `/Library/PrivilegedHelperTools/` 和 `/Library/LaunchDaemons/` 里）、现在用不上的，会提示可以移除，要输入一次管理员密码；也可以以后在「设置 → 通用」里移除。

### 从 ProxySwitch 更新

Proxi 以前叫 ProxySwitch，0.11.0 起改名。在旧版本里一键更新就行，第一次启动时会：

- 把程序从 `ProxySwitch.app` 改名为 `Proxi.app`，然后重新打开（当前账户没有写「应用程序」的权限时改不了名，程序照常能用）；
- 把 `~/Library/Application Support/ProxySwitch/` 整个挪到 `~/Library/Application Support/Proxi/`；
- 开着 iCloud 同步时，把 `iCloud 云盘/ProxySwitch/config.json` 复制到 `iCloud 云盘/Proxi/`；
- 装过命令行工具的，`proxyswitch` 命令接着能用，另外多一个 `proxi`（`/usr/local/bin` 要管理员密码才能写时，到「自动化」页点「更新」）；`proxyswitch://` 开头的 URL 命令照样认。

登录项和系统授权都不用重新设置。AI 助手（MCP）的配置里写着程序的路径，要换成「自动化」页上显示的新路径。

## 第一次打开

还没有任何代理配置时，Proxi 打开一个三步的引导：

1. **代理服务器**：填地址（`proxy.corp.example:3128`、`127.0.0.1:8888`，或者粘贴 `socks5://127.0.0.1:1080` 这样的整段地址），要登录的填上用户名和密码；也可以点「自动检测本机代理」，从本机正在运行的代理软件里选一个。
2. **生效范围**：选开启代理时要接管的地方：系统代理、终端环境变量、git、npm，可以先测试一下能不能连上。
3. **完成**：添加这条配置，可以选马上开启。

点「跳过」就到「设置 → 代理配置」里自己填。已经有配置的不会显示这个引导。

设置里不常用的项默认收起：关闭代理的方式、连通检查和测速地址、网速的位置和颜色、代理配置里不经代理的地址（改过的照样显示）。在「设置 → 通用」最下面打开「显示高级设置」就能看到，只影响这台 Mac。

## 功能

- **菜单栏面板**：点图标弹出，大开关、配置列表和每个配置的延迟、复制在当前终端里用代理的命令、一键测试、进设置。右键或 Control + 点击是简洁菜单。
- **代理配置**：HTTP / SOCKS5 / PAC 三种，每套配置有名字和颜色，指向你自己的代理服务器。要登录的代理可以填用户名和密码：密码只存在这台 Mac 的钥匙串里（「钥匙串访问」里名为「Proxi 代理密码」的项），配置文件和 iCloud 同步里只记「有密码」，别的 Mac 第一次开启这个配置时会请你输入一次；日志和诊断页里的密码都会隐藏成 `***`。每套配置可以选生效范围：
  - **系统代理**：浏览器和大多数软件都走它。读取和监听用 SystemConfiguration，别的程序改了代理会立刻反映在图标上，可以一键保存成配置；写入用 `networksetup`，同时设置不经代理的地址（例外列表）。
  - **终端环境变量**：`http_proxy`、`https_proxy`、`all_proxy`、`no_proxy`（大小写两种）写到 launchd（`launchctl setenv`），只影响之后新启动的程序；Terminal、iTerm、VS Code 已经运行时，新开窗口或标签页仍继承旧环境，须退出并重开整个 App，或在当前窗口使用面板里复制的 `export` 命令（zsh / bash 或 fish）。要登录的代理，复制的命令里带着密码，剪贴板上会加上 `org.nspasteboard.ConcealedType` 标记，剪贴板历史工具不会把它存下来；也可以在同一个菜单里复制不带密码的。`sudo` 默认清除这些环境变量；`sudo -E` 可请求保留，但仍取决于 sudo 策略。绕过列表留空时，launchd 和复制命令都会清除 `no_proxy` / `NO_PROXY`，不会补上默认列表。launchd 的设置重启后就没了，Proxi 启动时代理开着的话会重新设好。
  - **git**：全局的 `http.proxy` 和 `https.proxy`。带密码的地址不经命令行：写进只有自己能读的 `~/Library/Application Support/Proxi/git-proxy.inc`，`~/.gitconfig` 里用 `include.path` 引用它，关闭时一起删掉。
  - **npm / pnpm / yarn**：写进 `~/.npmrc` 的 `proxy`、`https-proxy`、`noproxy`（pnpm 和 yarn 1 也读它）；里面有密码时文件权限改成只有自己能读。
- **部分失败**：某个范围开启失败或取消授权时，面板逐项显示已开启和失败的范围，成功写入的范围仍可关闭；`proxi status --json` 中的 `proxy.appliedTargets` 和 `proxy.targetStates` 也会列出结果。
- **关闭代理**：上面设置过的地方全部清掉；系统代理可以选直接连接或者恢复开启前的设置，开启时设过、后来没在用的网络服务（比如拔掉的网线）也一起改回来。其他程序改了系统代理时，Proxi 仍记着自己实际写过的范围，面板会提示；关闭会清理这些范围，失败的保留供重试。
- **测试连接**：经代理实际访问测试地址（默认 `https://www.apple.com/library/test/success.html`，可以换成你内网里的地址）测出延迟；PAC 由系统执行，和浏览器一致。开启期间定期检查代理服务器的端口，连不上时提醒。
- **自动检测**：找出本机正在监听的代理端口（Charles 的 8888、Proxyman 的 9090、mitmproxy 的 8080 这类），确认能用后一键添加。
- **全局快捷键**：默认 ⌃⌥P 开关代理，可以在设置里录制新的（至少带 ⌃ 或 ⌘，F1~F20 可以单独用；被别的程序占用时设置里会提示）。
- **菜单栏网速**：图标旁边两行小字显示系统整体的实时上行、下行速度，可以放在图标左边或右边，也可以关掉。
- **登录时启动**：系统设置的「登录项」里可以看到和关闭。
- **退出与重新启动**：「设置 → 通用」里可以选退出 Proxi 时一起关闭代理；一键更新、换界面语言后的重新启动什么都不关，代理接着开着。设了登录时启动的，注销、重新启动电脑或关机也不关（登录后 Proxi 会再打开，接着用）。退出时没能清理完的（比如管理员密码没输完），下次启动时接着清理并提示。
- **按网络自动切换**：连上公司的 Wi‑Fi 自动开公司代理、回家自动关掉，见 [docs/automation.md](automation.md#按网络自动切换)。
- **命令行、AI 助手和 URL 命令**：`proxi status`、`proxi use 公司代理`、`proxi off`，MCP 服务器给 Claude、Cursor 这类 AI 助手用，`open proxi://toggle` 接快捷指令，见 [docs/automation.md](automation.md)。
- **iCloud 同步**：打开后代理配置和设置通过 iCloud 云盘（`iCloud 云盘/Proxi/config.json`）在多台 Mac 之间同步，几秒内生效；另一台 Mac 开启时可以选用 iCloud 的、用本机的或合并，两边同时改以改动时间晚的为准。
- **检查更新与一键更新**：启动后和每 6 小时检查一次 GitHub 上的新版本（可以关掉），有新版本时通知（通知上直接有「立即更新」按钮），面板里出现更新条，「关于」页列出从当前版本到新版本之间每一版的改动。点一下「更新」就会下载本机芯片的精简包、比对 SHA-256、替换 `Proxi.app` 并自动重新启动。下载先经系统代理，失败再直连。开发者签名的版本只安装同一个开发者签名的新版本。
- **界面语言**：中文或英文。默认跟着系统语言（系统是中文就显示中文，其他语言都显示英文），也可以在「设置 → 通用 → 界面语言」里选，点「立即重新启动」生效，代理保持开着。只影响这台 Mac，不同步。
- **诊断页**：系统代理、launchd 环境变量、git 和 npm 现在的代理设置，运行日志，一键清除所有代理设置。

## 常见用法

- **公司代理**：新建配置，类型 HTTP，主机填 `proxy.corp.example`、端口 `3128`，要登录就填用户名和密码；生效范围勾上系统代理、终端、git、npm。到公司开、回家关，或者在「自动化」页按 Wi‑Fi 自动切换。
- **抓包调试**：打开 Charles（8888）、Proxyman（9090）或 mitmproxy（8080），在 Proxi 里点「自动检测」添加，开启后浏览器、终端里的 `curl`、`git`、`npm` 都经过它；调试完点一下关掉，所有地方一起恢复。
- **内网网关**：SOCKS5 类型填网关地址，只勾终端和 git，访问内网仓库时打开。

## 权限与隐私

- 修改系统代理需要**管理员账户**。标准账户会弹出系统的授权对话框，输入一次管理员密码。
- iCloud 同步用的是 iCloud 云盘里的普通文件夹，第一次开启时系统可能会询问是否允许访问 iCloud 云盘。代理密码不同步。
- 代理密码存在登录钥匙串里（不开 iCloud 钥匙串同步）。开启配置时，密码会出现在系统代理设置、launchd 环境变量和 `~/.npmrc` 里（这些地方只能这样写），写系统代理时会短暂出现在 `networksetup` 的参数里。
- 全局快捷键用 Carbon 的热键接口，不需要辅助功能权限。
- 通知需要在第一次弹出时允许。
- 按网络自动切换要读 Wi‑Fi 名字，macOS 14 起需要定位权限（Proxi 不读取、不保存位置），不给也可以按路由器认。
- 安装命令行工具要写 `/usr/local/bin`，会请求一次管理员密码。

### 文件位置

- 配置、状态和日志：`~/Library/Application Support/Proxi/`（`config.json`、`state.json`、`proxi.log`），本机控制接口的套接字是同一目录里的 `control.sock`，开着带密码的 git 代理时还有 `git-proxy.inc`。诊断页里可以直接打开这个目录。
- 代理密码：登录钥匙串里服务为 `com.whrss9527.proxyswitch`、账户为配置 id 的通用密码。
- 偏好设置（界面语言、跳过的版本）：`~/Library/Preferences/com.whrss9527.proxyswitch.plist`。
- iCloud 同步：`~/Library/Mobile Documents/com~apple~CloudDocs/Proxi/config.json`。
- 命令行工具：`/usr/local/bin/proxi`（改名前装的还有 `/usr/local/bin/proxyswitch`）。
- Proxi 改动过的外部设置：系统代理（「系统设置 → 网络」）、launchd 的环境变量、`~/.gitconfig` 里的 `http.proxy` / `https.proxy`、`~/.npmrc` 里的 `proxy` / `https-proxy` / `noproxy`。关闭代理时都会清掉。
