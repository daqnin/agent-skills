<#
.SYNOPSIS
    从官方离线安装包构建 Windows 版 Chrome 免安装（绿色便携）包。

.DESCRIPTION
    下载官方 standalone 离线安装包，逐层解开四层嵌套压缩包，组装出可整体拷贝的
    免安装目录（含启动器与说明文件），做 headless 冒烟测试，并可选打包 ZIP。

    包内文件名一律使用 ASCII：7-Zip 会把非 ASCII 条目名按本地 ANSI 代码页写入且不置
    UTF-8 标志位，换到其他语言系统解压会乱码。

.PARAMETER OutputDir
    免安装目录的输出位置。目录非空时需要 -Force。

.PARAMETER WorkDir
    下载与解包用的临时目录。默认在系统临时目录下新建。

.PARAMETER InstallerPath
    已有的 ChromeStandaloneSetup64.exe，指定后不再下载。

.PARAMETER InstallerUrl
    官方离线安装包直链。

.PARAMETER ExpectedVersion
    期望的版本号，解包结果不符时直接报错退出。

.PARAMETER MakeZip
    额外生成 <OutputDir>.zip。

.PARAMETER KeepWork
    保留解包中间产物（默认只保留下载下来的安装包）。

.EXAMPLE
    pwsh -File build-portable-chrome.ps1 -OutputDir .\out\ChromePortable -WorkDir .\work -MakeZip
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$OutputDir,
    [string]$WorkDir,
    [string]$InstallerPath,
    [string]$InstallerUrl = 'https://dl.google.com/chrome/install/standalonesetup64.exe',
    [string]$ExpectedVersion,
    [switch]$MakeZip,
    [switch]$KeepWork,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-SevenZipPath {
    $cmd = Get-Command 7z -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA, $env:USERPROFILE) |
        Where-Object { $_ }
    foreach ($root in $roots) {
        foreach ($relative in '7-Zip\7z.exe', 'Programs\7-Zip\7z.exe', 'scoop\shims\7z.exe') {
            $candidate = Join-Path $root $relative
            if (Test-Path -LiteralPath $candidate) { return $candidate }
        }
    }
    throw '找不到 7z.exe，请先安装 7-Zip（例如 scoop install 7zip）。'
}

function Expand-NestedArchive {
    param(
        [Parameter(Mandatory = $true)][string]$SevenZip,
        [Parameter(Mandatory = $true)][string]$Archive,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    if (Test-Path -LiteralPath $Destination) { throw "解包目标已存在：$Destination" }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null

    $log = & $SevenZip x $Archive "-o$Destination" -y 2>&1
    $code = $LASTEXITCODE
    # 7z 退出码：0 正常，1 警告（外层两层的资源段必然如此），>=2 才是失败。
    if ($code -gt 1) {
        throw "7z 解包失败 (exit=$code)：$Archive`n$((@($log) | Select-Object -Last 15) -join "`n")"
    }
    return @($log)
}

function Find-FirstFile {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Filter
    )
    $file = Get-ChildItem -LiteralPath $Root -Recurse -File -Filter $Filter -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $file) { throw "在 $Root 下找不到 $Filter" }
    return $file.FullName
}

function Get-VersionBase {
    param([string]$Version)
    if (-not $Version) { return '' }
    $parts = $Version.Split('.')
    if ($parts.Count -ge 3) { return ($parts[0..2] -join '.') }
    return $Version
}

function Get-StableVersionInfo {
    $info = [ordered]@{ RolloutFull = $null; CfTStable = $null }
    try {
        $releases = (Invoke-RestMethod -TimeoutSec 60 -Uri `
                'https://versionhistory.googleapis.com/v1/chrome/platforms/win64/channels/stable/versions/all/releases?pageSize=50').releases
        $full = $releases |
            Where-Object { $_.fraction -ge 1 } |
            Sort-Object { [datetime]$_.serving.startTime } -Descending |
            Select-Object -First 1
        if ($full) { $info.RolloutFull = $full.version }
    }
    catch { Write-Warning "查询稳定通道灰度失败：$($_.Exception.Message)" }

    try {
        $cft = Invoke-RestMethod -TimeoutSec 60 -Uri `
            'https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions.json'
        $info.CfTStable = $cft.channels.Stable.version
    }
    catch { Write-Warning "查询 Chrome for Testing 失败：$($_.Exception.Message)" }

    return [pscustomobject]$info
}

function Remove-DirectoryInside {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Boundary
    )
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    $root = (Resolve-Path -LiteralPath $Boundary).Path
    if (-not $resolved.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "拒绝删除边界外的目录：$resolved"
    }
    [System.IO.Directory]::Delete($resolved, $true)
}

function Stop-ChromeUnder {
    param([Parameter(Mandatory = $true)][string]$Path)
    $mine = @(Get-Process chrome -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.StartsWith($Path, [System.StringComparison]::OrdinalIgnoreCase) })
    foreach ($process in $mine) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
    if ($mine.Count -gt 0) { Start-Sleep -Seconds 3 }
    return $mine.Count
}

$sevenZip = Get-SevenZipPath

$OutputDir = [System.IO.Path]::GetFullPath($OutputDir)
if (-not $WorkDir) {
    $WorkDir = Join-Path ([System.IO.Path]::GetTempPath()) `
        ('build-portable-chrome-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
}
$WorkDir = [System.IO.Path]::GetFullPath($WorkDir)

if ((Test-Path -LiteralPath $OutputDir) -and
    (Get-ChildItem -LiteralPath $OutputDir -Force -ErrorAction SilentlyContinue)) {
    if (-not $Force) { throw "输出目录非空：$OutputDir（确认覆盖请加 -Force）" }
}
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

Write-Host '==> 1/6 获取官方离线安装包'
if ($InstallerPath) {
    $installer = (Resolve-Path -LiteralPath $InstallerPath).Path
}
else {
    $installer = Join-Path $WorkDir 'ChromeStandaloneSetup64.exe'
    if (-not (Test-Path -LiteralPath $installer)) {
        Write-Host "    下载 $InstallerUrl"
        & curl.exe -L -sS --fail --retry 3 --max-time 1800 -o $installer $InstallerUrl
        if ($LASTEXITCODE -ne 0) { throw "下载失败：$InstallerUrl" }
    }
}
Write-Host ('    安装包 {0:N1} MB' -f ((Get-Item -LiteralPath $installer).Length / 1MB))

Write-Host '==> 2/6 四层解包'
$layer1 = Join-Path $WorkDir 'layer1'
$layer2 = Join-Path $WorkDir 'layer2'
$layer3 = Join-Path $WorkDir 'layer3'
$layer4 = Join-Path $WorkDir 'layer4'
$null = Expand-NestedArchive -SevenZip $sevenZip -Archive $installer -Destination $layer1
$updater = Find-FirstFile -Root $layer1 -Filter 'updater.7z'
$null = Expand-NestedArchive -SevenZip $sevenZip -Archive $updater -Destination $layer2
$installerExe = Find-FirstFile -Root $layer2 -Filter '*_chrome_installer.exe'
$manifestFile = Find-FirstFile -Root $layer2 -Filter 'OfflineManifest.gup'
$null = Expand-NestedArchive -SevenZip $sevenZip -Archive $installerExe -Destination $layer3
$chromeArchive = Find-FirstFile -Root $layer3 -Filter 'chrome.7z'
$null = Expand-NestedArchive -SevenZip $sevenZip -Archive $chromeArchive -Destination $layer4

$chromeBin = Join-Path $layer4 'Chrome-bin'
$sourceExe = Join-Path $chromeBin 'chrome.exe'
if (-not (Test-Path -LiteralPath $sourceExe)) { throw "解包结果里没有 Chrome-bin\chrome.exe：$layer4" }

$version = (Get-Item -LiteralPath $sourceExe).VersionInfo.ProductVersion
$manifestVersion = $null
try {
    $manifestVersion = ([xml](Get-Content -LiteralPath $manifestFile -Raw)).response.app.updatecheck.manifest.version
}
catch { Write-Warning "读取 OfflineManifest.gup 失败：$($_.Exception.Message)" }

$versionInfo = Get-StableVersionInfo
Write-Host "    安装包内版本 : $version"
if ($manifestVersion) { Write-Host "    官方清单版本 : $manifestVersion" }
Write-Host "    全量灰度版本 : $($versionInfo.RolloutFull)"
Write-Host "    CfT Stable   : $($versionInfo.CfTStable)"

if ($ExpectedVersion -and $version -ne $ExpectedVersion) {
    throw "版本不符：期望 $ExpectedVersion，安装包内是 $version"
}
if ($versionInfo.RolloutFull -and (Get-VersionBase $version) -ne (Get-VersionBase $versionInfo.RolloutFull)) {
    Write-Warning "安装包 ($version) 与全量灰度版本 ($($versionInfo.RolloutFull)) 的主版本不同，官方直链可能尚未更新。"
}

Write-Host '==> 3/6 组装免安装目录'
$baseline = [ordered]@{}
Get-ChildItem -LiteralPath $chromeBin -Recurse -File | ForEach-Object {
    $baseline[$_.FullName.Substring($chromeBin.Length).TrimStart('\')] = $_.Length
}

$destinationBin = Join-Path $OutputDir 'Chrome-bin'
robocopy $chromeBin $destinationBin /E /NFL /NDL /NJH /NJS /NP /R:2 /W:2 | Out-Null
if ($LASTEXITCODE -gt 7) { throw "复制 Chrome-bin 失败 (robocopy exit=$LASTEXITCODE)" }

$launcherLines = @(
    '@echo off'
    'setlocal'
    'set "ROOT=%~dp0"'
    ''
    'if not exist "%ROOT%Chrome-bin\chrome.exe" ('
    '    echo [ERROR] Chrome-bin\chrome.exe not found.'
    '    echo Put this launcher in the root of the portable folder.'
    '    pause'
    '    exit /b 1'
    ')'
    ''
    'rem Keep the profile inside this folder so the whole package stays self-contained.'
    'start "Google Chrome Portable" "%ROOT%Chrome-bin\chrome.exe" --user-data-dir="%ROOT%UserData" --no-first-run --no-default-browser-check'
    ''
    'exit /b 0'
)
[System.IO.File]::WriteAllText(
    (Join-Path $OutputDir 'Start-Chrome.cmd'),
    (($launcherLines -join "`r`n") + "`r`n"),
    [System.Text.Encoding]::ASCII)

$exeHash = (Get-FileHash -LiteralPath $sourceExe -Algorithm SHA256).Hash
$installerHash = (Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash
$binFiles = Get-ChildItem -LiteralPath $chromeBin -Recurse -File
$fileCount = $binFiles.Count
$totalMb = [math]::Round((($binFiles | Measure-Object -Sum Length).Sum / 1MB), 1)

$readme = @"
Google Chrome 离线免安装版（64 位）
=====================================

版本：$version
架构：Windows x64（64 位系统）
大小：约 $totalMb MB / $fileCount 个程序文件
制作日期：$(Get-Date -Format 'yyyy-MM-dd')

说明：包内文件名使用英文，是为了避免在不同语言版本的 Windows 上解压时出现中文乱码。
下面用中文说明用法。


一、目录结构
------------

$(Split-Path -Leaf $OutputDir)\
├─ Chrome-bin\            浏览器本体（不要改名、不要拆散）
│  ├─ chrome.exe          主程序
│  ├─ chrome_proxy.exe
│  └─ $version\      该版本的程序文件与资源
├─ Start-Chrome.cmd       双击这个启动
└─ README.txt             本文件

首次运行后会自动生成 UserData\ 目录，存放书签、密码、扩展、缓存等个人数据。


二、使用方法
------------

1. 把整个文件夹解压/复制到任意位置（U 盘、D 盘、桌面都可以）。
2. 双击「Start-Chrome.cmd」启动。

启动参数说明：
  --user-data-dir=".\UserData"   个人数据保存在本文件夹内，真正做到免安装、可整体拷贝
  --no-first-run                 跳过首次运行向导
  --no-default-browser-check     不弹出「设为默认浏览器」的提示

想固定一个快捷方式：右键 chrome.exe → 发送到 → 桌面快捷方式，然后把快捷方式的
「目标」改成（把 X:\你的路径 换成实际路径，注意保留引号）：
  "X:\你的路径\Chrome-bin\chrome.exe" --user-data-dir="X:\你的路径\UserData" --no-first-run --no-default-browser-check

直接双击 Chrome-bin\chrome.exe 也能用，但数据会存到系统默认位置，就不是便携版了。


三、关于便携性与更新
--------------------

· 本版本由官方离线安装包解包而来，不含 Google 更新服务（GoogleUpdate），因此不会自动
  升级，也不会在系统里注册安装信息，属于纯绿色版本。
· 整个文件夹可以直接拷到另一台电脑使用，个人数据一并带走。
· 想升级到更高版本时，用同样的解包流程重新解一次，把新的 Chrome-bin 覆盖过来即可；
  UserData\ 不要动，书签和密码都会完整保留。


四、校验值（SHA256）
--------------------

来源安装包 ChromeStandaloneSetup64.exe：
  $installerHash

Chrome-bin\chrome.exe：
  $exeHash

程序属性显示：Google Chrome / $version / Google LLC


五、制作方法与来源
------------------

官方离线安装包直链：
  $InstallerUrl
（网页入口：https://www.google.cn/chrome?standalone=1&platform=win64）

解包步骤：
  1. 7z x ChromeStandaloneSetup64.exe   → updater.7z
  2. 7z x updater.7z                    → <版本号>_chrome_installer.exe
  3. 7z x <版本号>_chrome_installer.exe  → chrome.7z
  4. 7z x chrome.7z                     → Chrome-bin\

第 1、3 步会提示「警告 / 解压错误」，属于正常现象，文件其实已经解出来了。
"@
[System.IO.File]::WriteAllText(
    (Join-Path $OutputDir 'README.txt'),
    $readme,
    (New-Object System.Text.UTF8Encoding($true)))

Write-Host '==> 4/6 冒烟测试（headless 渲染）'
$smokeProfile = Join-Path $WorkDir 'smoke-profile'
$smokeOut = Join-Path $WorkDir 'smoke-stdout.txt'
$smokeErr = Join-Path $WorkDir 'smoke-stderr.txt'
New-Item -ItemType Directory -Path $smokeProfile -Force | Out-Null
$smoke = Start-Process -FilePath (Join-Path $destinationBin 'chrome.exe') -Wait -NoNewWindow -PassThru `
    -RedirectStandardOutput $smokeOut -RedirectStandardError $smokeErr `
    -ArgumentList @(
        '--headless=new'
        '--disable-gpu'
        '--no-first-run'
        "--user-data-dir=$smokeProfile"
        '--dump-dom'
        'data:text/html,<h1>PORTABLE_OK</h1>'
    )
$dom = if (Test-Path -LiteralPath $smokeOut) { Get-Content -LiteralPath $smokeOut -Raw } else { '' }
if ($dom -notmatch 'PORTABLE_OK') {
    throw "冒烟测试失败：headless 没有渲染出预期内容（exit=$($smoke.ExitCode)）。详见 $smokeErr"
}
Write-Host "    渲染正常，退出码 $($smoke.ExitCode)"

Write-Host '==> 5/6 清理测试痕迹并核对文件清单'
$killed = Stop-ChromeUnder -Path $destinationBin
if ($killed -gt 0) { Write-Host "    结束测试进程 $killed 个" }

# 运行过的 Chrome 会在程序目录落下拼写词典，交付包要还原成纯净解包结果。
Remove-DirectoryInside -Path (Join-Path $destinationBin 'Dictionaries') -Boundary $destinationBin
Remove-DirectoryInside -Path $smokeProfile -Boundary $WorkDir

$actual = [ordered]@{}
Get-ChildItem -LiteralPath $destinationBin -Recurse -File | ForEach-Object {
    $actual[$_.FullName.Substring($destinationBin.Length).TrimStart('\')] = $_.Length
}
$diff = Compare-Object -ReferenceObject @($baseline.Keys) -DifferenceObject @($actual.Keys)
if ($diff) {
    Write-Warning '交付目录与解包基线不一致：'
    $diff | ForEach-Object { Write-Warning ("    {0} {1}" -f $_.SideIndicator, $_.InputObject) }
}
else {
    Write-Host "    与解包基线一致（$($actual.Count) 个文件）"
}

$badNames = @(Get-ChildItem -LiteralPath $OutputDir -Recurse -File |
    Where-Object { $_.Name -match '[^\x00-\x7F]' })
if ($badNames) {
    Write-Warning "存在非 ASCII 文件名，打进 ZIP 后可能在其他语言系统上乱码：$($badNames.Name -join ', ')"
}

$zipPath = "$OutputDir.zip"
if ($MakeZip) {
    Write-Host '==> 6/6 打包 ZIP'
    if (Test-Path -LiteralPath $zipPath) { [System.IO.File]::Delete($zipPath) }
    Push-Location (Split-Path -Parent $OutputDir)
    try {
        $null = & $sevenZip a -tzip -mx=5 -mmt=on $zipPath (Split-Path -Leaf $OutputDir) 2>&1
        $zipCode = $LASTEXITCODE
    }
    finally { Pop-Location }
    if ($zipCode -gt 1) { throw "打包失败 (exit=$zipCode)" }
    Write-Host ('    {0}  {1:N1} MB' -f (Split-Path -Leaf $zipPath), ((Get-Item -LiteralPath $zipPath).Length / 1MB))
}

if (-not $KeepWork) {
    foreach ($layer in $layer1, $layer2, $layer3, $layer4) {
        Remove-DirectoryInside -Path $layer -Boundary $WorkDir
    }
}

Write-Host ''
Write-Host '完成'
Write-Host "    版本      : $version"
Write-Host "    交付目录  : $OutputDir"
if ($MakeZip) {
    Write-Host "    ZIP       : $zipPath"
    Write-Host "    ZIP SHA256: $((Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash)"
}
Write-Host "    临时目录  : $WorkDir"
