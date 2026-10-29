---
name: build-portable-chrome
description: 从 Google 官方离线安装包制作 Windows 版 Chrome 免安装（绿色便携）版本：确认真正全量下发的稳定版号、下载 standalone 安装包、逐层解包出 Chrome-bin、组装启动器与说明文件并打包 ZIP。当用户要求制作或更新离线免安装版 Chrome，或给出一份把安装包解包成免安装版的教程要求照做时使用。
---

# 制作 Chrome 离线免安装版

产出物是一个能整体拷贝走的绿色版目录，外加一个分发给别人的 ZIP。完整流程在
`scripts/build-portable-chrome.ps1` 里，通常直接跑脚本，不要手工重敲一遍：

```powershell
pwsh -File scripts/build-portable-chrome.ps1 -OutputDir <交付目录> -WorkDir <临时目录> -MakeZip
```

已经下过安装包时用 `-InstallerPath` 指过去，避免重复下载 159 MB。用户指定了版本就加
`-ExpectedVersion`，脚本会在版本不符时直接报错退出。

## 先解决「哪个才是最新稳定版」

这一步最容易做错，**不要取版本列表的第一条**。

- `versionhistory.googleapis.com/v1/chrome/platforms/win64/channels/stable/versions`
  的第一条是「已经在稳定通道排队/灰度」的版本，灰度比例可能还是 0%，并不对外下发。
- 同一路径换成 `.../versions/all/releases?pageSize=50`，看每条记录的 `fraction`
  （灰度比例），**只有 `fraction` 为 1 的那条才是全量版本**。版本号更高但灰度 0% 的
  属于下一波，不能当作当前稳定版交付。
- 交叉验证 Chrome for Testing 的 Stable：
  `googlechromelabs.github.io/chrome-for-testing/last-known-good-versions.json`。
  它的末位 build 号常和渠道版差 1（例如渠道 155.0.8059.85 对 CfT 155.0.8059.84），
  比较前三位即可。
- 最终以安装包内的 `OfflineManifest.gup` 的 `manifest version` 为准：官方直链有时比
  灰度版本旧，安装包里装的才是真东西。

脚本会自动做这三步比对，不一致时给出警告。

## 流程

1. 下载官方离线安装包（只解包，不安装）：
   `https://dl.google.com/chrome/install/standalonesetup64.exe`（64 位 Windows）。
   网页入口是 `google.cn/chrome?standalone=1&platform=win64`，改 `platform=mac|linux`
   就是其他平台，但本技能只负责 Windows。
2. 四层解包，每层都用 7-Zip：

   ```text
   ChromeStandaloneSetup64.exe    ->  updater.7z
   updater.7z                     ->  bin\Offline\{GUID}\{GUID}\<版本>_chrome_installer.exe
   <版本>_chrome_installer.exe    ->  chrome.7z
   chrome.7z                      ->  Chrome-bin\      （266 个文件，约 488 MB）
   ```

   第 1、3 层必然报「警告 / 解压错误」，那是资源段的正常现象。判断成败看 7z 退出码：
   0 正常、1 警告（可接受）、2 及以上才是真失败。
3. 组装免安装目录：`Chrome-bin\` 原样保留，加启动器和说明文件。
4. 冒烟测试：headless 渲染一个 data: 页面，确认能启动并产出 DOM。
5. 打包 ZIP，输出 SHA256。

## 交付物必须满足

- 启动器让数据跟着文件夹走，而不是写进 `%LOCALAPPDATA%`：
  `--user-data-dir="%ROOT%UserData"`，再加 `--no-first-run --no-default-browser-check`
  免掉首次运行和「设为默认浏览器」弹窗。
- 说明文件写清版本号、来源直链、SHA256，以及升级方法（重新解包覆盖 `Chrome-bin`，
  `UserData\` 不动）。
- 包内**不含 GoogleUpdate**，所以不会自动升级、不写安装信息，这正是「免安装」的来源，
  要如实告诉用户，不要暗示它还能自己更新。
- 交付包里只用 ASCII 文件名，中文说明写在文件内容里，不要写进文件名。

## 必须避开的坑

细节和排查方法见 [references/pitfalls.md](references/pitfalls.md)，其中三条最容易翻车：

- **ZIP 里的中文文件名**：7-Zip 会按本机 ANSI（中文系统是 GBK）存名且不置 UTF-8
  标志位，换到非中文系统解压就是乱码。所以交付包文件名只用 ASCII。
- **测试会污染交付物**：任何一次运行 Chrome 都会在 `Chrome-bin\Dictionaries\` 落下
  拼写词典。要在副本上测，或测完删掉并重新核对文件数。
- **PowerShell 抓不到 headless 输出**：`& chrome.exe --dump-dom ...` 可能一行都拿不到
  （进程却正常退出）。用 `Start-Process -RedirectStandardOutput -Wait -NoNewWindow` 取。
