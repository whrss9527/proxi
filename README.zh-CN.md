<div align="center">
  <img src="docs/icon.png" width="128" height="128" alt="Proxi 图标">
  <h1>Proxi</h1>
  <p><strong>开发者的代理开关</strong></p>
  <p>住在 macOS 菜单栏里：一键把系统代理、终端、git 和 npm 指向你自己的代理服务器。原生 Swift，玻璃质感，开源免费。</p>
  <p>
    <a href="https://github.com/whrss9527/proxi/releases/latest"><img alt="最新版本" src="https://img.shields.io/github/v/release/whrss9527/proxi?include_prereleases&label=release&color=2F6BEA"></a>
    <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111827?logo=apple&logoColor=white">
    <img alt="Liquid Glass" src="https://img.shields.io/badge/UI-Liquid%20Glass-7C6CFF">
    <a href="LICENSE"><img alt="GPL-3.0" src="https://img.shields.io/badge/license-GPL--3.0-2563EB"></a>
  </p>
  <p>
    <a href="https://github.com/whrss9527/proxi/releases/latest"><b>下载</b></a> ·
    <a href="CHANGELOG.md">更新日志</a> ·
    <a href="docs/automation.md">自动化</a> ·
    <a href="https://github.com/whrss9527/proxyswitch">Windows 版</a> ·
    <a href="README.md">English</a>
  </p>
</div>

### **Proxi** /ˈprɒk.si/

念起来还是 **proxy**。

把 **y** 换成 **i**：**y** 是 *why*，**i** 是 *I*。

少一个“为什么”，多一个“我”。

写代码的时候，代理往往要在好几个地方各设一遍：系统设置、终端、git、npm……换个网络、开个抓包工具，又得挨个改回来。Proxi 把它们收进菜单栏里的一个开关：指向你自己的代理服务器，点一下全部设好，再点一下全部恢复。

Proxi 只负责切换设置，自己不提供代理服务，也不转发流量。

## 特性

- **一键切换**：系统代理、终端环境变量（`http_proxy`、`https_proxy`、`all_proxy`、`no_proxy`）、git、npm / pnpm / yarn 一起开关；配好几套，点一下就换。
- **指向你自己的代理**：公司代理、内网网关，或者本机的 Charles、Proxyman、mitmproxy 这类调试代理；HTTP、SOCKS5、PAC 都行，要登录的代理可以填用户名和密码（密码只存在这台 Mac 的钥匙串里，不同步），每套配置有自己的例外列表。
- **随手可用**：菜单栏面板、全局快捷键（默认 ⌃⌥P）、通知、连接测试、自动检测本机的调试代理，复制一行命令就能让已经打开的终端也用上代理。
- **终端提示符集成**：`proxi env` 不启动应用也能输出当前代理环境；`proxi shell-init zsh|bash|fish` 让已开的终端在下一个提示符前跟上开关。
- **交给脚本和 AI**：`proxi on / off / status / use <配置名>` 命令行、给 AI 助手用的 MCP、URL 命令；连上公司 Wi‑Fi 自动开公司代理，回家自动关掉。
- **省心**：配置用 iCloud 在几台 Mac 之间同步；有新版本，点一下就更新好。
- **中文或英文**：界面跟着系统语言，也可以在「设置 → 通用 → 界面语言」里选。

## 安装

需要 macOS 14 或更新版本，Intel 和 Apple 芯片都能用。

用 [Homebrew](https://brew.sh) 安装（同时装好 `proxi` 命令）：

```sh
brew install --cask whrss9527/tap/proxi
```

或者手动安装：

1. 在 [Releases](../../releases) 下载 `Proxi-macos.zip`，解压后把 `Proxi.app` 拖到「应用程序」。
2. 双击打开。没经过公证的版本第一次打开的办法见[使用指南](docs/guide.md#安装)。
3. 以后有新版本，面板里点「更新」就行。

从 0.12 及以前的版本更新过来的，见[使用指南](docs/guide.md#从-012-及以前的版本更新)。以前用 ProxySwitch 的，在旧版本里一键更新就会变成 Proxi，见[从 ProxySwitch 更新](docs/guide.md#从-proxyswitch-更新)。Windows 版在 [proxyswitch](https://github.com/whrss9527/proxyswitch)。

## 上手

| 操作 | 效果 |
| --- | --- |
| 第一次打开 | 三步引导：填代理服务器的地址 → 选要接管的地方（系统代理、终端、git、npm）→ 完成 |
| 设置 → 代理配置 →「新建」或「自动检测」 | 填上代理服务器的地址（比如 `proxy.corp.example:3128`、`127.0.0.1:8888`），选好要设置的地方 |
| 左键点菜单栏图标 | 打开面板：大开关、配置列表、延迟、一键测试 |
| 右键（或 Control + 点击） | 简洁菜单 |
| ⌃⌥P | 在任何地方开关代理（可以在设置里换） |
| 终端里 `proxi use 公司代理`、`proxi off` | 用命令行切换（用 Homebrew 装的直接能用，手动装的先在「自动化」页装上命令行工具） |

## 文档

- [使用指南](docs/guide.md)：安装与更新、全部功能、常见用法、权限与文件位置
- [自动化](docs/automation.md)：命令行、MCP、URL 命令、按网络自动切换
- [开发指南](docs/development.md)：构建、代码结构、CI 与发版；签名和公证见 [docs/signing.md](docs/signing.md)
- [更新日志](CHANGELOG.md)

## 支持

Proxi 免费开源。觉得好用的话，点个 ⭐ Star 就是很大的鼓励；也可以微信扫一扫请我喝杯咖啡（程序里「设置 → 关于」也有这张码）。

<p align="center"><img src="Resources/donate-wechat.png" width="240" alt="微信赞赏码：请我喝杯咖啡"></p>

## 许可证

Copyright © 2026 吴彦祖

Proxi 是自由软件，以 [GNU 通用公共许可证第 3 版（GPL-3.0）](LICENSE) 发布：可以自由使用、研究、修改和分享；分发 Proxi 或修改后的版本时，需要以同样的许可证提供源代码。

「Proxi」这个名字和 Proxi 的图标不在 GPL 授权范围内（GPL-3.0 第 7 条 e 项）。介绍 Proxi、分享未经修改的副本时可以使用；分发修改后的版本时，请换用自己的名字和图标。

贡献需接受 [CONTRIBUTING.md](CONTRIBUTING.md) 里的贡献者协议。

0.10.0 及以前的版本以 MIT 许可证发布，这些版本仍然适用 MIT 许可证。

---

<div align="center">
  <p><b>同样住在菜单栏里</b></p>
  <a href="https://github.com/whrss9527/pop"><img src="https://raw.githubusercontent.com/whrss9527/whrss9527/master/assets/cards/pop.svg" width="30%" alt="Pop：长按右键，一划即达"></a>
  <a href="https://github.com/whrss9527/meno"><img src="https://raw.githubusercontent.com/whrss9527/whrss9527/master/assets/cards/meno.svg" width="30%" alt="Meno：安静的菜单栏，由玻璃打造"></a>
  <a href="https://github.com/whrss9527/stox"><img src="https://raw.githubusercontent.com/whrss9527/whrss9527/master/assets/cards/stox.svg" width="30%" alt="Stox：一眼看盘，一键隐身"></a>
</div>
