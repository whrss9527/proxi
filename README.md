<div align="center">
  <img src="docs/icon.png" width="128" height="128" alt="Proxi icon">
  <h1>Proxi</h1>
  <p><strong>A proxy switch for developers</strong></p>
  <p>Lives in the macOS menu bar and points the system proxy, Terminal, git and npm at your own proxy server in one click. Native Swift, glass design, free and open source.</p>
  <p>
    <a href="https://github.com/whrss9527/proxi/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/whrss9527/proxi?include_prereleases&label=release&color=2F6BEA"></a>
    <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111827?logo=apple&logoColor=white">
    <img alt="Liquid Glass" src="https://img.shields.io/badge/UI-Liquid%20Glass-7C6CFF">
    <a href="LICENSE"><img alt="GPL-3.0" src="https://img.shields.io/badge/license-GPL--3.0-2563EB"></a>
  </p>
  <p>
    <a href="https://github.com/whrss9527/proxi/releases/latest"><b>Download</b></a> ·
    <a href="CHANGELOG.md">Changelog</a> ·
    <a href="docs/automation.md">Automation</a> ·
    <a href="https://github.com/whrss9527/proxyswitch">Windows version</a> ·
    <a href="README.zh-CN.md">简体中文</a>
  </p>
</div>

### **Proxi** /ˈprɒk.si/

Say it out loud and it's still **proxy**.

Swap the **y** for an **i**: **y** is *why*, **i** is *I*.

One less "why", one more "I".

When you write code, a proxy usually has to be set in several places: System Settings, Terminal, git, npm… and when you change networks or open a debugging proxy, you have to change them all back one by one. Proxi puts them behind one switch in the menu bar: point it at your own proxy server, click once to set everything, click again to restore everything.

Proxi only switches settings. It doesn't provide a proxy service or relay any traffic itself.

The interface is in English when your system language isn't Chinese, and you can pick the language under Settings → General → Language.

## Features

- **One-click switching**: the system proxy, Terminal environment variables (`http_proxy`, `https_proxy`, `all_proxy`, `no_proxy`), git and npm / pnpm / yarn switch together; set up several profiles and change between them with a click.
- **Your own proxies**: a corporate proxy, an intranet gateway, or a local debugging proxy such as Charles, Proxyman or mitmproxy. HTTP, SOCKS5 and PAC are supported, proxies that require signing in can have a user name and password (the password stays in this Mac's keychain and is never synced), and each profile has its own bypass list.
- **Always at hand**: a menu bar panel, a global hotkey (⌃⌥P by default), notifications, connection tests, detection of debugging proxies running on this Mac, and a one-line command that brings the proxy to Terminal windows that are already open.
- **Terminal prompt integration**: `proxi env` works without launching the app; `proxi shell-init zsh|bash|fish` refreshes existing terminal windows before the next prompt.
- **Scripts and AI**: the `proxi on / off / status / use <profile>` command line, MCP for AI assistants and URL commands; turn on the corporate proxy on the office Wi‑Fi and off at home automatically.
- **Low maintenance**: profiles sync across your Macs with iCloud; new versions install with one click.
- **English or Chinese**: the interface follows your system language, or pick one under Settings → General.

## Install

Requires macOS 14 or later, on Intel or Apple silicon.

With [Homebrew](https://brew.sh), which also puts the `proxi` command on your PATH:

```sh
brew install --cask whrss9527/tap/proxi
```

Or by hand:

1. Download `Proxi-macos.zip` from [Releases](../../releases), unzip it and drag `Proxi.app` to Applications.
2. Double-click to open it. For opening versions that weren't notarized, see the [user guide](docs/guide.md#安装) (in Chinese).
3. When a new version comes out, click "Update" in the panel.

If you're updating from 0.12 or earlier, see [updating from 0.12 and earlier](docs/guide.md#从-012-及以前的版本更新): your own proxy profiles and other settings are kept, and nothing is deleted. If you used ProxySwitch, updating from the old version in one click turns it into Proxi and keeps your settings; see [updating from ProxySwitch](docs/guide.md#从-proxyswitch-更新). The Windows version is [proxyswitch](https://github.com/whrss9527/proxyswitch).

## Getting started

| Action | Result |
| --- | --- |
| First launch | A three-step guide: enter your proxy server's address, choose what to take over (system proxy, terminal, git, npm), done |
| Settings → Proxy Profiles → "New" or "Detect" | Enter your proxy server's address (for example `proxy.corp.example:3128` or `127.0.0.1:8888`) and choose where to apply it |
| Left-click the menu bar icon | Opens the panel: the big switch, profiles, latency and one-click testing |
| Right-click (or Control-click) | A compact menu |
| ⌃⌥P | Turns the proxy on or off from anywhere (you can change it in Settings) |
| `proxi use "Work proxy"`, `proxi off` in Terminal | Switch from the command line (ready to use with Homebrew; otherwise install the command-line tool on the Automation page first) |

## Documentation

The documents are in Chinese for now.

- [User guide](docs/guide.md): installing and updating, every feature, common setups, permissions and file locations
- [Automation](docs/automation.md): the command line, MCP, URL commands and switching by network
- [Development guide](docs/development.md): building, code layout, CI and releases; signing and notarization are in [docs/signing.md](docs/signing.md)
- [Changelog](CHANGELOG.md)

## Support

Proxi is free and open source. If you find it useful, a ⭐ Star means a lot; you can also buy me a coffee with WeChat (the code is also in Settings → About).

<p align="center"><img src="Resources/donate-wechat.png" width="240" alt="WeChat tip code: buy me a coffee"></p>

## License

Copyright © 2026 吴彦祖

Proxi is free software released under the [GNU General Public License v3 (GPL-3.0)](LICENSE): you can use, study, modify and share it freely; when you distribute Proxi or a modified version, you must provide the source code under the same license.

The name "Proxi" and the Proxi icon aren't covered by the GPL (GPL-3.0 section 7(e)). You may use them to talk about Proxi or to share unmodified copies; when distributing a modified version, please use your own name and icon.

Contributions require accepting the contributor agreement in [CONTRIBUTING.md](CONTRIBUTING.md).

Versions 0.10.0 and earlier were released under the MIT license, which still applies to those versions.

---

<div align="center">
  <p><b>Also living in the menu bar</b></p>
  <a href="https://github.com/whrss9527/pop"><img src="https://raw.githubusercontent.com/whrss9527/whrss9527/master/assets/cards/pop.svg" width="30%" alt="Pop: long-press right-click, one swipe away"></a>
  <a href="https://github.com/whrss9527/meno"><img src="https://raw.githubusercontent.com/whrss9527/whrss9527/master/assets/cards/meno.svg" width="30%" alt="Meno: a quiet menu bar made of glass"></a>
  <a href="https://github.com/whrss9527/stox"><img src="https://raw.githubusercontent.com/whrss9527/whrss9527/master/assets/cards/stox.svg" width="30%" alt="Stox: quotes at a glance, gone in a click"></a>
</div>
