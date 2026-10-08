# Proxi 开发指南

[← 回到 README](../README.zh-CN.md)

## 开发

需要 Xcode 16 或更新版本（用 Xcode 26 编译才有 Liquid Glass）。

```bash
swift build                          # 编译
swift test                           # 单元测试（纯逻辑：命令生成、状态解析、配置读写……）
VERSION=0.1.0 Scripts/build-app.sh   # 组装通用二进制的 dist/Proxi.app 和 zip，ad-hoc 签名
```

设置 `CODESIGN_IDENTITY="Developer ID Application: …"` 时用开发者证书签名；发布时的签名和公证怎么配置见 [docs/signing.md](signing.md)。

代码结构：

| 目录 | 内容 |
| --- | --- |
| `Sources/Proxi/App` | 入口、`AppState`（配置、状态、开关逻辑）、本机控制接口、命令行、按网络自动切换、iCloud 同步、更新、从旧版本更新过来时的清理（`LegacyCleanup`） |
| `Sources/Proxi/Models` | 配置、系统代理快照、networksetup 命令的生成、粘贴地址的解析、引导里填的内容、自动化、界面语言 |
| `Sources/Proxi/System` | 系统代理、环境变量、git / npm、测试连接与自动检测、快捷键、登录项、通知、URL 命令、更新、iCloud 文件、控制接口的套接字与 MCP、命令行工具的安装 |
| `Sources/Proxi/UI` | 菜单栏图标与面板、第一次打开时的引导、设置窗口各页（代理配置、自动化、通用、快捷键、iCloud 同步、诊断、关于）、更新说明、毛玻璃样式、快捷键录制 |
| `Tests` | XCTest |
| `Scripts/build-app.sh` | 组装 .app（通用二进制）、签名、打 zip |
| `Scripts/import-certificate.sh`、`Scripts/notarize.sh` | 发布时导入 Developer ID 证书、提交苹果公证并钉上票据 |
| `Scripts/check-localization.py` | 检查英文和简体中文的界面文字齐不齐、有没有漏掉 `L()` 的中文 |
| `Resources` | Info.plist、权限声明、图标，英文（`en.lproj`）和简体中文（`zh-Hans.lproj`）的界面文字 |

### 界面语言

界面有英文和简体中文。代码里显示给用户的文字写中文原文，经 `L("中文原文", 参数…)` 翻译（见 `Sources/Proxi/App/AppLanguage.swift`）；中文原文就是 `Resources/en.lproj/Localizable.strings` 和 `Resources/zh-Hans.lproj/Localizable.strings` 里的键，`Scripts/build-app.sh` 把它们拷进程序。参数用 `%@` 占位，译文里可以用 `%1$@`、`%2$@` 调换顺序；同一个中文在不同地方要译成不同的英文时，键后面加「‖」和说明（`L("关闭‖按钮")`），中文界面只显示「‖」前面的部分。日志不翻译；脚本内容、参数里认的中文写法这类数据也不翻译，行尾标 `// l10n-ignore`。

加了或改了文字，两个表都要改，再跑一遍 `python3 Scripts/check-localization.py`，CI 每次推送都会跑。界面语言跟着系统，设置 → 通用 → 界面语言可以单独选（写在 Proxi 自己偏好设置的 `AppleLanguages` 里，重新启动生效）。不改系统语言试英文界面：

```bash
defaults write com.whrss9527.proxyswitch AppleLanguages -array en   # 删掉这个键就是跟随系统
```

开合并请求（之后每次往分支推送）和推到 main 时 GitHub Actions 会检查界面文字的翻译，在 macOS 上编译、测试、打包并启动一次截图（中文界面，经命令行、MCP 和 URL 命令切换配置，确认终端环境变量、git 和 npm 的代理都设对了、关掉后都清干净；再用 0.12 的配置启动一次，确认以前版本的数据原样保留、指向本机空端口的代理被关掉；最后用英文界面启动几次截图，确认界面、命令行和跟随系统都是英文），然后用本地 HTTP 服务器假装发布一个 9.9.9 版本，走一遍下载、校验、替换、重新启动的完整更新流程，再用一张临时的自签名证书把签名流程走一遍；推送 `v*` 标签会自动打包并发布 Release，用证书签名并公证（没配证书时不发布，见 [signing.md](signing.md)）。

本仓库分支开的合并请求（草稿除外）测试全部通过后自动合并进 main。合并后，如果 `CHANGELOG.md` 最上面的版本还没有发布，就自动打包、公证，成功后打上 `v版本号` 的标签并发布 Release；所以要发版时，在 `CHANGELOG.md` 最上面加一节新版本就行（标题写成 `## 0.8.1（2026-09-29）`，写错了会报错）。中途失败的版本不会留下标签，下次合并时再发。测试期间 main 有了新提交时不会自动合并，把 main 合进分支再推一次即可。

本机调试更新流程时可以把环境变量 `PROXI_UPDATE_URL` 指向一个返回 GitHub releases 格式 JSON 的地址（这时不去 GitHub 取新版本标签上的 `CHANGELOG.md`，「关于」页只显示这个 JSON 里的发布说明）；调试 iCloud 同步时可以用 `PROXI_SYNC_DIR` 把同步文件夹指到任意目录（见 `.github/workflows/ci.yml` 里的做法）。

### 配置格式与跨版本同步

从 0.16.3 起，`AppConfig.format` 和 iCloud 外层 `SyncedConfig.format` 写入 2；无版本号的旧文件按 1 读取。读写未知 JSON 键时保留原始值（包括嵌套字段和配置条目的附加字段），已知值的编辑优先，删除已识别配置不会把它恢复。合并两台机器时也保留两边的附加字段；旧内置配置和已经移除的设置仍按原迁移规则清理。

未知 `targets` 名称原样写回。混合范围只应用本机支持的部分；仅有未知范围时显示「这台 Mac 不支持」，面板和开启入口均拒绝执行，不会回落到系统代理。缺少 `targets` 的旧配置仍默认系统代理。

iCloud 拉取先检查外层和内层格式；遇到超过 2 的格式，提示更新 Proxi，不应用其内容。写入也在文件协调区内重新检查目标，冲突解决在确认所有版本可读、成功写入后才清理冲突，旧目录迁移也不会覆盖未来格式。此保护要求客户端已经升级到 0.16.3 或更高版本，无法改变旧二进制的写回行为。

### CI 的独立检查

`.github/workflows/ci.yml` 调用 `Scripts/ci/` 的脚本。先检查脚本，再编译、跑单元测试和打包；将 `dist/` 和截图封装成一个 tar 上传，保留应用的可执行权限与符号链接。后续各项在独立的 macOS runner 上读取同一份产物并行执行：

| 检查 | 脚本 |
| --- | --- |
| 中文、英文冒烟 | `smoke-zh.sh`、`smoke-en.sh` |
| 旧配置迁移 | `migration-config.sh` |
| 一键更新、临时位置安装 | `update-e2e.sh` |
| 改名前版本更新 | `rename-e2e.sh` |
| 签名与公证流程自测 | `signing-selftest.sh` |
| 扩展端到端 | 先运行 `migration-config.sh`，再运行 `extension-e2e.sh` |

每项通过 `prepare.sh` 创建自己的配置、假同步目录和临时钥匙串，通过 `cleanup.sh` 清理进程、钥匙串和假发布服务；失败时也运行清理，并保留日志、状态和截图。汇总检查沿用「编译、测试、打包」这个名字，所有分项成功才允许自动合并。缺失、跳过或取消的检查也算未通过；自动合并仍核对测试的分支提交和 main 提交。

本机可安全运行脚本静态检查和轮询函数的测试，不启动应用或修改代理设置：

```bash
bash Scripts/ci/check-scripts.sh       # bash 语法、shellcheck 和 Python 测试
python3 Scripts/check-localization.py # 两种语言的界面文字
```

界面和更新脚本会写测试账户的偏好设置、配置与钥匙串；只在 CI 或独立的专用测试账户中运行。专用账户重现时，先准备 `RUNNER_TEMP` 临时目录、可写的 `GITHUB_ENV` 文件，以及打包好的 `dist/`；显式设置 `PROXI_CI_ALLOW_GUI=1`，然后先执行 `prepare.sh`，读取其输出的环境变量，再运行所需脚本，结束时执行 `cleanup.sh`。不要在日常使用的账户中运行这些脚本。

等待统一使用有截止时间的 `wait_for`。`status --json` 增加 `busy`、`interface`（实际语言、可见窗口数、设置页和是否显示）以及存在新版本时的 `update`；单次 CLI 读取也有超时。启动、切页和替换后的版本按这些状态确认，更新下载按假服务实际收到并成功响应的请求确认。需要检查日志事件时只匹配稳定的机器标记，例如 `event=extension.request`；特权错误的机器标记仅在设置 `PROXI_CI_DIAGNOSTICS=1` 时输出，正常错误说明保持原样。
