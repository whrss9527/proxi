# 签名与公证

发布流程（`.github/workflows/release.yml`）在仓库的 Secrets 里找到 Developer ID 证书和公证凭据时，会：

1. 把证书导入一个临时钥匙串（`Scripts/import-certificate.sh`）；
2. 用证书签名程序，带 hardened runtime 和安全时间戳（`Scripts/build-app.sh`）；
3. 将通用包、两个精简包和可选扩展的 App 放入同一归档，共同提交一次公证；通过后钉票据，重新打包并再次解包验签、验票据和 Gatekeeper（`Scripts/notarize.sh`）；
4. 固定候选 ZIP、源码提交、版本和摘要，在 Intel 与 Apple 芯片 runner 上下载同一份候选附件，分别严格验证通用包、本机精简包和扩展；
5. 两个架构回执都与候选一致后上传草稿附件，再实际下载核对摘要，最后公开。失败不公开，也不覆盖已经发布的版本。

没有 Developer ID 证书或公证凭据时停止发布；正式验证和发布均不接受 ad-hoc 签名。`dry_run` 使用同样的签名、公证和双架构验证，只保留 Actions 候选 artifact 和回执，不创建标签或 Release。

下面是一次性的准备工作，大约半小时（不算苹果审核开发者账号的时间）。

## 一、加入 Apple Developer Program

用 Apple ID 在 [developer.apple.com/programs/enroll](https://developer.apple.com/programs/enroll/) 或 Apple Developer App 里以**个人**身份注册，年费 99 美元（中国大陆 688 元）。Apple ID 需要开启双重认证。审核通过后会收到邮件。

Developer ID 签名和公证用个人账号就可以，不需要公司。

## 二、创建并导出 Developer ID Application 证书

1. 在 Mac 上打开 Xcode → 设置 → Accounts，登录开发者账号，选中团队，点「Manage Certificates…」，左下角「+」→「Developer ID Application」。
   （也可以在开发者网站的 Certificates, Identifiers & Profiles 里创建，需要先用「钥匙串访问 → 证书助理 → 从证书颁发机构请求证书」生成 CSR。）
2. 打开「钥匙串访问」，左边选「登录」，上面选「我的证书」，找到「Developer ID Application: 你的名字 (团队 ID)」。展开能看到下面的私钥，说明私钥在这台 Mac 上。
3. 在证书上右键 →「导出…」，格式选「个人信息交换 (.p12)」，设一个密码。
4. 转成一行 base64，复制到剪贴板：

   ```bash
   base64 -i DeveloperID.p12 | pbcopy
   ```

## 三、准备公证凭据（二选一）

**A. App Store Connect API 密钥（推荐）**

1. 登录 [App Store Connect](https://appstoreconnect.apple.com) → 用户和访问 → 集成 → App Store Connect API。第一次用要先点「请求访问」。
2. 在「团队密钥」里生成一个密钥，访问权限选「开发者」。
3. 下载 `.p8` 文件（只能下载一次，保存好），记下页面上的 **密钥 ID** 和 **Issuer ID**。

用个人密钥（个人资料里生成的）也可以，这时不填 Issuer ID。

**B. Apple ID + App 专用密码**

1. 在 [account.apple.com](https://account.apple.com) → 登录与安全 → App 专用密码，生成一个。
2. 在开发者网站的「会员资格详细信息」里找到 10 位的 **团队 ID**。

## 四、填进 GitHub Secrets

仓库 → Settings → Secrets and variables → Actions → New repository secret，逐个添加：

| 名字 | 内容 |
| --- | --- |
| `MACOS_CERTIFICATE_P12` | 第二步复制的 base64 |
| `MACOS_CERTIFICATE_PASSWORD` | 导出 .p12 时设的密码 |
| `NOTARY_KEY_P8` | A：`.p8` 文件的全部内容，直接粘贴（包括 BEGIN / END 两行） |
| `NOTARY_KEY_ID` | A：密钥 ID |
| `NOTARY_ISSUER_ID` | A：Issuer ID（个人密钥不填） |
| `NOTARY_APPLE_ID` | B：Apple ID 邮箱 |
| `NOTARY_PASSWORD` | B：App 专用密码 |
| `NOTARY_TEAM_ID` | B：团队 ID |

A 和 B 填一组就行，两组都填时用 A。

## 五、发布

Actions → release → Run workflow，填未发布的版本标签（比如 `v0.17.0`）。默认 `dry_run` 开启；先验证候选，准备公开时再取消该选项。日志里：

- 「导入签名证书」会显示证书名字，应该是 `Developer ID Application: …`；
- 「共同公证、钉票据并验证最终 ZIP」必须 Accepted；票据网络错误 68 最多重试三次，其他错误立即停止。`Unnotarized Developer ID`、未知来源和签名错误均阻止发布，不能以 Accepted 或工作目录的票据代替最终 ZIP 验证。
- 「下载验证」必须在两个架构均通过；回执绑定同一源码、版本、运行 attempt 和 ZIP 摘要。公证等待最多 20 分钟，构建公证 job 最多 45 分钟，双架构验证各最多 12 分钟，公开最多 5 分钟。
- 瞬时失败后选择「重新运行所有作业」；候选与回执绑定同一 attempt，单独重跑失败 job 不会复用上一 attempt 的候选。ARM 门禁使用 macOS 26，Intel 使用 macOS 15，验证前设置临时 App 的 quarantine 并确认 Gatekeeper 已开启。

## 要知道的几件事

- **一键更新会认签名**：从第一个签名版开始，程序只安装同一个团队 ID 签名的新版本，别人重新签过名的包即使校验和对得上也不装。旧的 ad-hoc 版本更新到签名版不受影响。换证书（比如五年到期后）团队 ID 不变，更新照常；但之后不要再发 ad-hoc 签名的版本，不然签名版的用户没法一键更新，只能去发布页手动下载。Secrets 失效时自动发布会停下来，发布日志里报「没有配置 MACOS_CERTIFICATE_P12」，重新配好后再合并一次（或者手动运行 release 工作流）就会发。
- **证书过期**：Developer ID 证书有效期五年。签名带着安全时间戳，已经发布的版本过期后照样能打开；发新版本前换一张新证书，更新 `MACOS_CERTIFICATE_P12` 和密码。
- **公证不审核功能**：公证只是苹果的自动恶意软件扫描，不看功能，一般几分钟出结果。
- **私钥保管**：`.p12` 和 `.p8` 只放在 GitHub Secrets 里，不要提交进仓库。泄露了就到开发者网站吊销证书或密钥，再换新的。

## 在自己的 Mac 上签名和公证

证书在登录钥匙串里时：

```bash
CODESIGN_IDENTITY="Developer ID Application: 你的名字 (团队 ID)" VERSION=0.7.0 THIN_ARCHIVES=1 Scripts/build-app.sh
NOTARY_APPLE_ID=… NOTARY_PASSWORD=… NOTARY_TEAM_ID=… \
  Scripts/notarize.sh dist/Proxi-macos.zip dist/Proxi-macos-arm64.zip dist/Proxi-macos-x86_64.zip
```


### 草稿状态与 ID

发布器先验证候选七归档、源码/运行身份与两份原生回执。已有草稿保留查询得到的 ID；新草稿通过 REST 创建并验证响应中的正整数 ID、标签和 draft 状态，随后按 ID 查询，不依赖刚创建后标签/列表索引是否可见。原有完整分页与异常 Link 检查保留。

上传附件与公开前均按同一 ID 确认仍为草稿，并检查 GitHub CLI 实际解析到相同的 apiUrl/标签。API 不明、ID 或标签变化、已公开状态均停止；公开后再次按 ID 确认结果。标签仍必须指向候选源码，实际下载附件必须符合 canonical 摘要，公开版本不可覆盖。

恢复已有草稿时使用原标签对应的源码和现有手动发行入口，重新通过签名、公证与两架构下载门禁；原失败保留。不能通过修改原标签、替换公开附件或忽略状态检查恢复。
