# 制作免安装版 Chrome 的坑与排查

需要判断「步骤到底成功没有」「文件对不对」「ZIP 能不能给别人」时读这里。

## 1. ZIP 里的文件名编码

7-Zip 在中文 Windows 上打包，会把非 ASCII 文件名按本地代码页（GBK）写入条目，
并且**不置** UTF-8 标志位（general purpose bit 11）。后果：

| 解压环境 | 结果 |
| --- | --- |
| 中文 Windows（936）+ 资源管理器 / 7-Zip | 正常 |
| 非中文 Windows、macOS、Linux | 中文名变乱码 |
| .NET `ZipArchive`、部分新版工具 | 按 UTF-8 解码，乱码 |

检测方法（Python）：

```python
import zipfile
z = zipfile.ZipFile(r"xxx.zip")
for e in z.infolist():
    print(bool(e.flag_bits & 0x800), e.filename)
    # flag_utf8=False 且名字里有非 ASCII，就是上面这种存法
```

规避方式，优先级从高到低：

1. 交付包文件名全部用 ASCII（推荐，任何环境都不会错）。
2. 必须用中文名时，改用会写 UTF-8 标志位的打包方式（Python `zipfile`、
   PowerShell `Compress-Archive`），别用带 `-tzip` 的 7z。

`7z t <zip>` 只能验证 CRC 完整性，**验证不了文件名编码**，两件事要分别查。

## 2. 跑一次浏览器就会污染程序目录

Chrome 首次运行会在**程序目录**（不是 user-data-dir）写 `Dictionaries\en-US-*.bdic`，
约 450 KB。绿色包讲究「和官方解包结果一致」，所以：

- 冒烟测试尽量在副本上做；
- 必须在交付目录里测时，测完删掉 `Chrome-bin\Dictionaries\`，再和纯净基线比一次文件清单；
- 顺带删掉测试用的 profile，别把 `UserData\` 留在交付包里。

基线参考：`Chrome-bin` 解包后是 **266 个文件、488.2 MB**，其中 `chrome.exe` 约 4.7 MB
位于 `Chrome-bin` 根目录，程序文件在同级以版本号命名的子目录里（`chrome.dll`、
`Locales\`、`WidevineCdm\` 等）。

## 3. 验证浏览器真的能跑

```powershell
Start-Process -FilePath <Chrome-bin>\chrome.exe -Wait -NoNewWindow `
  -ArgumentList '--headless=new','--disable-gpu','--no-first-run',
                "--user-data-dir=<临时profile>",'--dump-dom','data:text/html,<h1>OK</h1>' `
  -RedirectStandardOutput out.txt -RedirectStandardError err.txt
```

要点：

- 直接用 `& chrome.exe ... --dump-dom` 时 PowerShell 经常一行都收不到（退出码却是 0）。
  重定向到文件最可靠。
- **退出码 0 不等于成功**：已有实例占着同一个 user-data-dir 时，新进程会静默交接后退出。
  先确认没有残留进程，或干脆换一个全新的 profile 目录。
- stderr 里的 `external_registry_loader_win.cc ... Missing value path` 是便携版没有注册表
  项的常规噪音，不是故障。
- 测完记得结束本次启动的 chrome 进程（按 `Path` 前缀匹配，别误杀用户自己的 Chrome），
  文件被占用会导致后续删除或打包失败。

## 4. 版本判断的陷阱

实际遇到过的情形：稳定通道列表第一条是 156.0.8078.36，但它的 `fraction` 是 0；同一
时间官方离线安装包里装的是 155.0.8059.85，`fraction` 为 1。此时正确的「最新稳定版」
是 155.0.8059.85。

判断顺序：

1. `.../channels/stable/versions/all/releases` 里 `fraction` 为 1 的最大版本号；
2. Chrome for Testing 的 Stable（比前三位）；
3. 下载后读 `OfflineManifest.gup` 里 `<manifest version="...">`，这是最终事实。

三者不一致时，以解包出来的版本为交付版本，并在说明里写清原因。

## 5. 交付前最后核对

- 目录里没有非 ASCII 文件名；
- 文件数与纯净基线一致，没有 `Dictionaries\`、`UserData\` 之类测试残留；
- 没有外来文件混进来（例如别处脚本落下的 `s5cmd`、`upload.sh`，后者还可能带凭据）；
- `chrome.exe` 的 `ProductVersion` 等于说明文件里写的版本；
- 给出 ZIP 的 SHA256，并确认 `7z t` 通过。
