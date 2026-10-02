<#
.SYNOPSIS
    在本地 Windows 10/11 电脑上复刻 GitHub Actions 工作流
    .github/workflows/Build-Html-Package.yml 的完整构建流程。

.DESCRIPTION
    本脚本逐步骤复刻 Build-Html-Package.yml（"Build ModLoader"）:
      * actions/checkout             -> git clone / git submodule update
                                        并用 --remote 把每个子模块更新到最新 commit
      * actions/setup-node           -> 检查本机 Node.js 版本
      * corepack enable              -> corepack（自动下载 yarn 3.4.1）
      * Lyoko-Jeremie/js-copy-...    -> PowerShell 复制（保留目录层级）
      * thedoctor0/zip-release       -> System.IO.Compression 打包
      * softprops/action-gh-release  -> 输出到 .\release\ 目录
    最终产物与 CI 完全一致:
      output\DoL-ModLoader-<sha>.zip
        └─ Degrees of Lewdity VERSION.html.sc2patch.html.mod.html          (普通版)
        └─ Degrees of Lewdity VERSION.html.sc2patch.html.mod-polyfill.html (兼容版)
        └─ img\...
      out-GameOriginalImagePack\GameOriginalImagePack.mod.zip

    子模块版本策略（默认使用各子模块的**最新**版本）:
      git submodule sync --recursive
      git submodule update --init --recursive --remote
    DOL / ModLoader 跟踪各自 .gitmodules 里的 branch = master；
    ModLoader 下的 28 个子模块递归更新到最新。
    如需改回「父仓库记录的那个 commit」，加 -PinnedSubmodules。

.PARAMETER Version
    等价于工作流 workflow_dispatch 输入的 version（手动设定版本）。
    指定后会额外生成 output\DoL-ModLoader-<Version>-<sha>.zip，
    并把产物复制到 .\release\ 目录，供你手动上传 Release。

.PARAMETER Sha
    覆盖用于文件名的 commit sha（默认取仓库当前 HEAD 的短 sha）。

.PARAMETER SkipInit
    跳过 git clone / submodule 更新步骤（完全离线构建时使用）。

.PARAMETER PinnedSubmodules
    默认行为是给每个子模块执行 `git fetch` 并检出其跟踪分支的**最新** commit
    （`git submodule update --init --recursive --remote`），与 CI 工作流一致。
    加上本开关则改回旧行为：使用父仓库记录的那个 commit。

.PARAMETER SkipYarnInstall
    跳过所有 yarn install（node_modules 已就绪时加快重复构建）。

.PARAMETER SkipSc2
    跳过 SC2(SugarCube-2) 的 npm install + build.js -d -u -b 2。
    该步骤产出 SC2\build\twine2\sugarcube-2\format.js，仅供调试参考，
    不参与最终 HTML 的生成（工作流中复制它的步骤本身也是注释掉的）。

.PARAMETER SkipGameOriginalImagePack
    跳过 GameOriginalImagePack mod 的下载与打包。

.PARAMETER OnlyPackage
    只做 "注入 + 打包" 阶段，复用上一次已经构建好的中间产物。

.PARAMETER Clean
    构建开始前清理生成物：ModLoader\out 下的 dist-* / mod / README.md、output\、
    out-GameOriginalImagePack\ 以及 DoL 的 HTML 产物。只删生成物，受版本控制的
    源文件（modList.json / ManualPolyfill.js / insert*.bat）会被保留。

.EXAMPLE
    # 最常用：完整本地构建（不需要额外权限）
    .\Build-ModLoader-Local.ps1

.EXAMPLE
    # 模拟 workflow_dispatch + 手动填版本号
    .\Build-ModLoader-Local.ps1 -Version 0.5.12.13

.EXAMPLE
    # 第二次构建，源码没变，跳过下载依赖
    .\Build-ModLoader-Local.ps1 -SkipInit -SkipYarnInstall

.EXAMPLE
    # 使用父仓库记录的旧子模块 commit（复现历史版本）
    .\Build-ModLoader-Local.ps1 -PinnedSubmodules
#>

[CmdletBinding()]
param(
    [string]$Version = '',
    [string]$Sha = '',
    [switch]$SkipInit,
    [switch]$PinnedSubmodules,
    [switch]$SkipYarnInstall,
    [switch]$SkipSc2,
    [switch]$SkipGameOriginalImagePack,
    [switch]$OnlyPackage,
    [switch]$Clean
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ============================================================================
# 0. 基础工具函数
# ============================================================================

$script:StepIndex = 0
$script:StepTotal = 0
$script:Warnings = New-Object System.Collections.Generic.List[string]
$script:BuildStart = Get-Date

function Write-Section {
    param([string]$Text)
    Write-Host ''
    Write-Host ('=' * 78) -ForegroundColor DarkCyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ('=' * 78) -ForegroundColor DarkCyan
}

function Write-Step {
    param([string]$Text)
    $script:StepIndex++
    $label = if ($script:StepTotal -gt 0) { "[$($script:StepIndex)/$($script:StepTotal)]" } else { "[$($script:StepIndex)]" }
    Write-Host ''
    Write-Host "$label $Text" -ForegroundColor Yellow
}

function Write-Ok {
    param([string]$Text)
    Write-Host "      OK   $Text" -ForegroundColor Green
}

function Write-Info {
    param([string]$Text)
    Write-Host "      ..   $Text" -ForegroundColor DarkGray
}

function Write-Warn {
    param([string]$Text)
    Write-Host "      !!   $Text" -ForegroundColor DarkYellow
    $script:Warnings.Add($Text)
}

# 运行外部命令，失败即抛出异常（等价于 GitHub Actions 的默认 fail-fast 行为）
# 注意：PowerShell 会把函数返回值写到输出流，裸调用 `Invoke-External ...` 就会在
# 日志里多出一行 "0"（退出码）。因此本函数主动 `return`（不带值），退出码放到
# $script:LastNativeExitCode 里，需要时自行读取。
function Invoke-External {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory = '',
        [switch]$AllowFailure
    )

    $display = "$FilePath $($Arguments -join ' ')"
    Write-Host "      > $display" -ForegroundColor DarkGray

    if ($WorkingDirectory) {
        Push-Location -LiteralPath $WorkingDirectory
    }
    try {
        # 通过管道交给 Out-Host：既不吞掉原生命令的输出，也不让它混进本函数的返回值
        & $FilePath @Arguments | Out-Host
        $code = $LASTEXITCODE
    }
    finally {
        if ($WorkingDirectory) { Pop-Location }
    }

    if ($code -ne 0 -and -not $AllowFailure) {
        throw "命令执行失败 (exit code $code): $display`n工作目录: $(if ($WorkingDirectory) { $WorkingDirectory } else { (Get-Location).Path })"
    }
    $script:LastNativeExitCode = $code
    return
}

function Get-CommandPath {
    param([Parameter(Mandatory)][string]$Name)
    $cmd = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) { return $null }
    return $cmd.Source
}

function Copy-TreeContents {
    <#  等价于 js-copy-github-action 的 "source: <dir>/**/* -> target: <dir>/" ：
        把源目录内的内容（含子目录）复制进目标目录，#>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Target
    )
    if (-not (Test-Path -LiteralPath $Source)) {
        throw "复制源不存在: $Source"
    }
    if (-not (Test-Path -LiteralPath $Target)) {
        New-Item -ItemType Directory -Path $Target -Force | Out-Null
    }
    Get-ChildItem -LiteralPath $Source -Force | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $Target -Recurse -Force
    }
}

function Copy-FileToDir {
    <#  等价于 js-copy-github-action 的 "one: true"：复制单个文件到目标目录 #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$TargetDir
    )
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw "复制源文件不存在: $Source"
    }
    if (-not (Test-Path -LiteralPath $TargetDir)) {
        New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
    }
    Copy-Item -LiteralPath $Source -Destination $TargetDir -Force
}

function New-ZipFromDirectory {
    <#  等价于 thedoctor0/zip-release：把目录内容打包为 zip（条目为相对路径） #>
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$ZipPath
    )
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $dir = (Resolve-Path -LiteralPath $Directory).Path
    $zipFull = [System.IO.Path]::GetFullPath($ZipPath)

    if (Test-Path -LiteralPath $zipFull) { Remove-Item -LiteralPath $zipFull -Force }
    $zipParent = Split-Path -Parent $zipFull
    if (-not (Test-Path -LiteralPath $zipParent)) {
        New-Item -ItemType Directory -Path $zipParent -Force | Out-Null
    }

    $files = Get-ChildItem -LiteralPath $dir -Recurse -File -Force
    $count = 0
    $stream = [System.IO.File]::Open($zipFull, [System.IO.FileMode]::CreateNew)
    try {
        $archive = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($f in $files) {
                $rel = $f.FullName.Substring($dir.Length).TrimStart('\', '/') -replace '\\', '/'
                $entry = $archive.CreateEntry($rel, [System.IO.Compression.CompressionLevel]::Optimal)
                $entryStream = $entry.Open()
                try {
                    $input = [System.IO.File]::OpenRead($f.FullName)
                    try { $input.CopyTo($entryStream) } finally { $input.Dispose() }
                }
                finally { $entryStream.Dispose() }
                $count++
            }
        }
        finally { $archive.Dispose() }
    }
    finally { $stream.Dispose() }

    return $count
}

function Get-ZipEntryCount {
    param([Parameter(Mandatory)][string]$ZipPath)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try { return $z.Entries.Count } finally { $z.Dispose() }
}

function Remove-DirIfExists {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
}

function Get-SubmoduleRevisions {
    <#  读取工作区中所有子模块当前检出的 commit。
        等价于遍历 `git submodule status`（已初始化 / 会递归包含内层子模块）。
        返回 @{ '相对路径' = @{ Sha = '...'; Note = '...' } } #>
    param([Parameter(Mandatory)][string]$GitExe, [Parameter(Mandatory)][string]$BaseDir)

    $map = @{}
    $output = & $GitExe -C $BaseDir submodule status --recursive 2>$null
    foreach ($line in $output) {
        # 格式: [ |+|-|U]<sha1> <path> [(describe)]
        if ($line -notmatch '^[\s+\-U]([0-9a-f]{40})\s+(\S+)(?:\s+\((.*)\))?') { continue }
        $sha = $Matches[1]
        $rel = $Matches[2]
        $note = if ($Matches[3]) { $Matches[3] } else { '' }
        # 去掉 ModLoader\ 前缀，让主仓库与 ModLoader 两次扫描的路径可以合并比较
        $key = $rel -replace '^ModLoader[\\/]', ''
        $map[$key] = @{ Sha = $sha; Note = $note }
    }
    return $map
}

function Format-SubmoduleDelta {
    <#  对比更新前后的子模块 commit，输出「哪些子模块被移动到了新版本」 #>
    param(
        [Parameter(Mandatory)][hashtable]$Before,
        [Parameter(Mandatory)][hashtable]$After
    )
    $updated = New-Object System.Collections.Generic.List[string]

    foreach ($k in (@($After.Keys) | Sort-Object)) {
        $new = $After[$k].Sha
        $old = if ($Before.ContainsKey($k)) { $Before[$k].Sha } else { $null }
        if (-not $old) {
            $updated.Add("  + $k  (新增) -> $($new.Substring(0,8))")
        }
        elseif ($old -ne $new) {
            $updated.Add("  * $k  $($old.Substring(0,8)) -> $($new.Substring(0,8))")
        }
    }
    foreach ($k in (@($Before.Keys) | Sort-Object)) {
        if (-not $After.ContainsKey($k)) { $updated.Add("  - $k  (已移除)") }
    }
    return $updated
}

function Assert-FileHasText {
    <#  冒烟校验：确认产物里确实含有预期内容，避免"构建成功但产物是空壳" #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Needle,
        [Parameter(Mandatory)][string]$What
    )
    $f = Get-Item -LiteralPath $Path
    if ($f.Length -lt 1MB) {
        throw "$What 体积异常偏小 ($([math]::Round($f.Length / 1KB, 1)) KB)，疑似构建失败: $Path"
    }
    # 直接流式搜索，避免把上百 MB 的 HTML 一次性读进内存
    $found = $false
    $reader = New-Object System.IO.StreamReader($Path)
    try {
        $buffer = New-Object char[] (1MB)
        $tail = ''
        while (($read = $reader.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $chunk = $tail + (New-Object string ($buffer, 0, $read))
            if ($chunk.Contains($Needle)) { $found = $true; break }
            # 保留尾部，避免关键词被分块截断
            $keep = [Math]::Min(256, $chunk.Length)
            $tail = $chunk.Substring($chunk.Length - $keep)
        }
    }
    finally { $reader.Dispose() }

    if (-not $found) { throw "$What 中未找到预期标记 '$Needle': $Path" }
}

# ============================================================================
# 1. 环境准备 / 前置检查
# ============================================================================

$RepoRoot = $PSScriptRoot
if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot '.gitmodules'))) {
    throw "脚本必须放在仓库根目录（含 .gitmodules 的目录）中运行。当前目录: $RepoRoot"
}
Set-Location -LiteralPath $RepoRoot

$LogDir = Join-Path $RepoRoot 'build-logs'
if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$LogFile = Join-Path $LogDir 'Build-ModLoader-Local.latest.log'
$Stamp = Get-Date -Format 'yyyy-MM-dd-HH-mm-ss'

# --- 工具链检查 -------------------------------------------------------------
Write-Section "本地复刻构建: Build-Html-Package.yml  (Windows / PowerShell)"
Write-Host "  仓库根目录 : $RepoRoot"
Write-Host "  日志文件   : $LogFile"

Write-Step "检查本机工具链 (Node.js / npm / git / corepack)"

$NodeExe = Get-CommandPath 'node'
$NpmCmd  = Get-CommandPath 'npm'
$GitExe  = Get-CommandPath 'git'
$CorepackCmd = Get-CommandPath 'corepack'

if (-not $NodeExe) { throw '未找到 node，请先从 https://nodejs.org 安装 Node.js LTS（工作流使用 18.x）' }
if (-not $NpmCmd)  { throw '未找到 npm（随 Node.js 一起安装）' }
if (-not $GitExe)  { throw '未找到 git，请先安装 Git for Windows: https://git-scm.com/download/win' }

$NodeVersionRaw = (& $NodeExe -v).Trim()          # v18.20.4
$NodeMajor = [int]($NodeVersionRaw.TrimStart('v').Split('.')[0])
Write-Host "      node     : $NodeVersionRaw  ($NodeExe)" -ForegroundColor Gray
Write-Host "      npm      : $((& $NpmCmd -v).Trim())" -ForegroundColor Gray
Write-Host "      git      : $((& $GitExe --version).Trim())" -ForegroundColor Gray

if ($NodeMajor -lt 17) {
    throw "Node.js $NodeVersionRaw 太旧。工作流使用 18.x，SC2 构建要求 >= 17.3.0，请升级 Node.js。"
}
if ($NodeMajor -ne 18) {
    Write-Warn "本机 Node.js 为 $NodeVersionRaw，工作流使用 18.x。较新版本通常可用；若某步（webpack/babel）报错，建议安装 Node 18 LTS 后重试。"
}
else {
    Write-Ok 'Node.js 版本与工作流一致 (18.x)'
}

# corepack 是 Node 16.9+ 自带的 yarn 管理器，等价于工作流里的 `corepack enable`
$script:UseCorepackForYarn = $false
if ($CorepackCmd) {
    try { $null = & $CorepackCmd --version 2>&1; $script:UseCorepackForYarn = $true } catch { $script:UseCorepackForYarn = $false }
}
$YarnExe = Get-CommandPath 'yarn'
if ($script:UseCorepackForYarn) {
    Write-Ok "corepack 可用，将用 corepack 调用 yarn 3.4.1（无需管理员权限执行 corepack enable）"
}
elseif ($YarnExe) {
    Write-Warn "未找到可用的 corepack，将直接使用 PATH 中的 yarn: $YarnExe"
}
else {
    throw '未找到 corepack，也未找到 yarn。请安装 Node.js 16.9+（自带 corepack）或全局安装 yarn。'
}

function Invoke-Yarn {
    <#  在工作目录中执行 yarn 子命令（等价于工作流里的 `yarn run xxx` / `yarn install`） #>
    param(
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string[]]$YarnArgs
    )
    if ($script:UseCorepackForYarn) {
        Invoke-External -FilePath $CorepackCmd -Arguments (@('yarn') + $YarnArgs) -WorkingDirectory $WorkingDirectory
    }
    else {
        Invoke-External -FilePath $YarnExe -Arguments $YarnArgs -WorkingDirectory $WorkingDirectory
    }
    return
}

# 关闭 yarn 的"lockfile 必须完全一致"校验，避免 lockfile 轻微漂移导致本地构建直接失败
$env:YARN_ENABLE_IMMUTABLE_INSTALLS = 'false'
# 保证 yarn berry 使用 node_modules（仓库 .yarnrc.yml 已是该值，这里双保险）
$env:YARN_NODE_LINKER = 'node-modules'

# 版本号输入（等价于 workflow_dispatch 的 version 输入）
if (-not $Version) {
    # 仅在交互式终端里提示；在 CI / 重定向 / -NonInteractive 等场景下 Read-Host 会返回 $null
    if ([Environment]::UserInteractive) {
        $Version = Read-Host "      ? 手动设定版本号（等价于工作流 workflow_dispatch 的 version 输入，直接回车则跳过 Release 重命名）"
    }
    if ($null -eq $Version) { $Version = '' }
    $Version = $Version.Trim()
}
if ($Version) { Write-Ok "版本号: $Version" } else { Write-Info '未指定版本号：将使用自动命名 (Auto Release 等价行为)' }

# commit sha（等价于 ${{ github.sha }}）
if ($SkipInit -and -not $Sha) {
    $Sha = ''
}
if (-not $Sha) {
    $Sha = (& $GitExe -C $RepoRoot rev-parse --short=8 HEAD 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $Sha) { $Sha = 'nogit' }
    $Sha = $Sha.Trim()
}
Write-Ok "commit sha: $Sha"

# 输出目录（与工作流保持一致）
$ModLoaderDir = Join-Path $RepoRoot 'ModLoader'
$DoLDir       = Join-Path $RepoRoot 'DoL'
$Sc2Dir       = Join-Path $RepoRoot 'SC2'
$OutDir       = Join-Path $ModLoaderDir 'out'
$OutputDir    = Join-Path $RepoRoot 'output'
$GopOutDir    = Join-Path $RepoRoot 'out-GameOriginalImagePack'
$GopDir       = Join-Path $ModLoaderDir 'mod\GameOriginalImagePack'

# DoL 编译/注入链路上的关键文件路径（-OnlyPackage 时包装阶段也会用到）
$GameHtml    = Join-Path $DoLDir 'Degrees of Lewdity VERSION.html'
$PatchedHtml = "$GameHtml.sc2patch.html"
$ModHtml     = "$PatchedHtml.mod.html"
$ModPolyHtml = "$PatchedHtml.mod-polyfill.html"

Write-Host "      ModLoader  : $ModLoaderDir"
Write-Host "      DoL        : $DoLDir"
Write-Host "      产物       : $OutputDir"

if ($Clean) {
    Write-Step '清理旧输出目录 (-Clean)'

    # 注意: ModLoader\out 是 ModLoader 子模块内的目录，除构建产物外还包含
    # 受版本控制的源文件（modList.json / ManualPolyfill.js / insert*.bat / .gitkeep）。
    # 因此这里只按名字删除「生成物」，绝不整目录删除。
    $generatedInOut = @(
        'dist-BeforeSC2', 'dist-BeforeSC2-comp', 'dist-BeforeSC2-comp-babel',
        'dist-ForSC2', 'dist-insertTools', 'mod', 'README.md'
    )
    foreach ($name in $generatedInOut) {
        $p = Join-Path $OutDir $name
        if (Test-Path -LiteralPath $p) { Write-Info "rm -rf $p"; Remove-DirIfExists $p }
    }

    # 这两个目录完全由构建生成，可以整体删除
    foreach ($d in @($OutputDir, $GopOutDir)) {
        if (Test-Path -LiteralPath $d) { Write-Info "rm -rf $d"; Remove-DirIfExists $d }
    }

    # DoL 的编译产物（*.html 已被 DoL 仓库的 .gitignore 忽略，均为生成物）
    foreach ($f in @("$GameHtml", $PatchedHtml, $ModHtml, $ModPolyHtml)) {
        if (Test-Path -LiteralPath $f) { Write-Info "rm $f"; Remove-Item -LiteralPath $f -Force }
    }

    Write-Ok '已清理'
}

# 受版本控制的源文件必须存在（旧版本脚本的 -Clean 曾误删，这里做一次兜底校验）
$ModLoaderOutRequired = @('modList.json', 'ManualPolyfill.js', 'insert.bat', 'insert-comp.bat', 'insert-babel.bat')
foreach ($name in $ModLoaderOutRequired) {
    if (-not (Test-Path -LiteralPath (Join-Path $OutDir $name))) {
        throw @"
ModLoader\out\$name 缺失。它是 ModLoader 子模块中受版本控制的源文件，不是构建产物。
请在 ModLoader 目录中执行一次还原：
    git -C "$ModLoaderDir" checkout -- out
"@
    }
}

# ---------------------------------------------------------------------------
# 开始记录日志。注意必须放在 -Clean 之后：-Clean 会重建输出目录，
# 若在它之前开启转录，日志会被删掉或写进已删除的文件。
# 日志只是辅助：即使写入失败（例如上一次构建还在运行、文件被占用），构建也必须继续。
# ---------------------------------------------------------------------------
$script:TranscriptActive = $false
try {
    Start-Transcript -Path $LogFile -Force | Out-Null
    $script:TranscriptActive = $true
}
catch {
    $LogFile = Join-Path $LogDir "Build-ModLoader-Local.$Stamp.log"
    try {
        Start-Transcript -Path $LogFile -Force | Out-Null
        $script:TranscriptActive = $true
        Write-Host "  日志提示   : latest 日志被占用，已改用 $LogFile" -ForegroundColor DarkYellow
    }
    catch {
        Write-Host "  日志提示   : 无法写日志（$($_.Exception.Message)），构建继续，输出仅在控制台" -ForegroundColor DarkYellow
    }
}

# -Clean 时顺手清掉更早的带时间戳日志（保留本次正在写的那个）
if ($Clean -and $script:TranscriptActive) {
    Get-ChildItem -LiteralPath $LogDir -File -Filter 'Build-ModLoader-Local.*.log' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -ne $LogFile } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
}

# 步骤总数只用于显示进度
$script:StepTotal = 0

try {

# ============================================================================
# 2. 等价于 actions/checkout + git submodule update --init --recursive
# ============================================================================

if (-not $SkipInit) {
    Write-Section '第 1 阶段  /  获取源码 (actions/checkout@v6 + submodules)'

    # 子模块策略：
    #   默认 --remote  -> 每个子模块 fetch 远端并检出其跟踪分支的最新 commit
    #                     (等价于 CI 里新增的 "Update all submodules to latest remote" 步骤)
    #   -PinnedSubmodules -> 停留在父仓库记录的那个 commit（原 CI 行为）
    $remoteArgs = if ($PinnedSubmodules) { @() } else { @('--remote') }
    if ($PinnedSubmodules) {
        Write-Warn '子模块使用父仓库记录的 commit（-PinnedSubmodules），不拉取最新版本'
    }
    else {
        Write-Info '子模块将 fetch 远端并更新到各自跟踪分支的最新 commit (--remote)'
    }

    # 记录更新前的状态，便于最后输出「哪些子模块版本变了」
    $subBefore = @{}
    foreach ($kv in (Get-SubmoduleRevisions -GitExe $GitExe -BaseDir $RepoRoot).GetEnumerator()) { $subBefore[$kv.Key] = $kv.Value }

    Write-Step '同步并更新主仓库子模块: DOL (degrees-of-lewdity) 与 ModLoader'
    Invoke-External -FilePath $GitExe -Arguments @('submodule', 'sync', '--recursive') -WorkingDirectory $RepoRoot
    Invoke-External -FilePath $GitExe -Arguments (@('submodule', 'update', '--init', '--recursive') + $remoteArgs) -WorkingDirectory $RepoRoot
    Write-Ok '主仓库子模块就绪'

    Write-Step '更新 ModLoader 内部子模块 (等价于 workflow 的 "init ModLoader" 步骤)'
    Invoke-External -FilePath $GitExe -Arguments @('submodule', 'sync', '--recursive') -WorkingDirectory $ModLoaderDir
    Invoke-External -FilePath $GitExe -Arguments (@('submodule', 'update', '--init', '--recursive') + $remoteArgs) -WorkingDirectory $ModLoaderDir
    Write-Ok 'ModLoader 子模块就绪'

    # 输出子模块版本变化明细
    $subAfter = Get-SubmoduleRevisions -GitExe $GitExe -BaseDir $RepoRoot
    # 注意用 @() 包住：函数返回 List[string] 时 PowerShell 会把它展开成单个字符串，
    # 直接取 .Count 会失败（StrictMode 下报「找不到属性 Count」）
    $delta = @(Format-SubmoduleDelta -Before $subBefore -After $subAfter)
    if ($delta.Count -gt 0) {
        Write-Ok "共 $($delta.Count) 个子模块被更新到新版本:"
        foreach ($line in $delta) { Write-Host $line -ForegroundColor Green }
    }
    else {
        Write-Info '所有子模块都已是最新版本'
    }

    Write-Step '获取 SC2 (Lyoko-Jeremie/sugarcube-2_Vrelnir @ TS2)'
    if (Test-Path -LiteralPath (Join-Path $Sc2Dir '.git')) {
        Invoke-External -FilePath $GitExe -Arguments @('-C', $Sc2Dir, 'fetch', '--depth', '1', 'origin', 'TS2', '--force') -WorkingDirectory $RepoRoot
        Invoke-External -FilePath $GitExe -Arguments @('-C', $Sc2Dir, 'checkout', '--force', 'FETCH_HEAD') -WorkingDirectory $RepoRoot
    }
    else {
        Remove-DirIfExists $Sc2Dir
        Invoke-External -FilePath $GitExe -Arguments @('clone', '--branch', 'TS2', '--single-branch', '--depth', '1',
            'https://github.com/Lyoko-Jeremie/sugarcube-2_Vrelnir.git', 'SC2') -WorkingDirectory $RepoRoot
    }
    Write-Ok 'SC2 就绪'

    if (-not $SkipGameOriginalImagePack) {
        Write-Step '获取 GameOriginalImagePack (Lyoko-Jeremie/GameOriginalImagePackMod @ master)'
        if (Test-Path -LiteralPath (Join-Path $GopDir '.git')) {
            Invoke-External -FilePath $GitExe -Arguments @('-C', $GopDir, 'fetch', '--depth', '1', 'origin', 'master', '--force') -WorkingDirectory $RepoRoot
            Invoke-External -FilePath $GitExe -Arguments @('-C', $GopDir, 'checkout', '--force', 'FETCH_HEAD') -WorkingDirectory $RepoRoot
        }
        else {
            Remove-DirIfExists $GopDir
            Invoke-External -FilePath $GitExe -Arguments @('clone', '--branch', 'master', '--single-branch', '--depth', '1',
                'https://github.com/Lyoko-Jeremie/GameOriginalImagePackMod', 'ModLoader/mod/GameOriginalImagePack') -WorkingDirectory $RepoRoot
        }
        Write-Ok 'GameOriginalImagePack 就绪'
    }
    else {
        Write-Warn '已跳过 GameOriginalImagePack 的获取与打包 (-SkipGameOriginalImagePack)'
    }
}
else {
    Write-Section '第 1 阶段  /  获取源码  —— 已跳过 (-SkipInit)'
    foreach ($p in @($ModLoaderDir, $DoLDir, $Sc2Dir)) {
        if (-not (Test-Path -LiteralPath $p)) { throw "-SkipInit 需要本地已存在目录: $p" }
    }
}

if (-not $OnlyPackage) {

# ============================================================================
# 3. ModLoader 框架本体构建
# ============================================================================

Write-Section '第 2 阶段  /  构建 ModLoader 框架'

if (-not $SkipYarnInstall) {
    Write-Step 'ModLoader: corepack enable + yarn install (等价于工作流 corepack enable + yarn install)'
    if ($script:UseCorepackForYarn -and $NodeMajor -ge 16) {
        # corepack enable 需要写入 Node 安装目录（通常需要管理员）。
        # 这里尝试执行，失败不致命，因为后面用 `corepack yarn` 直接调用即可。
        & $CorepackCmd enable 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Info 'corepack enable 成功（yarn shim 已启用）' }
        else { Write-Info 'corepack enable 未成功（需要管理员权限），改用 `corepack yarn` 直接调用，不影响构建' }
    }
    Invoke-Yarn -WorkingDirectory $ModLoaderDir -YarnArgs @('install')
    Write-Ok 'ModLoader 依赖安装完成'
}
else {
    Write-Info '跳过 yarn install (-SkipYarnInstall)'
}

Write-Step 'ModLoader: 编译 TypeScript 与打包 (ts:BeforeSC2 / webpack:BeforeSC2 / *-comp / ts:ForSC2 / webpack:insertTools / tras:babel)'
Invoke-Yarn -WorkingDirectory $ModLoaderDir -YarnArgs @('run', 'ts:BeforeSC2')
Invoke-Yarn -WorkingDirectory $ModLoaderDir -YarnArgs @('run', 'webpack:BeforeSC2')
Invoke-Yarn -WorkingDirectory $ModLoaderDir -YarnArgs @('run', 'webpack:BeforeSC2-comp')
Invoke-Yarn -WorkingDirectory $ModLoaderDir -YarnArgs @('run', 'ts:ForSC2')
Invoke-Yarn -WorkingDirectory $ModLoaderDir -YarnArgs @('run', 'webpack:insertTools')
Invoke-Yarn -WorkingDirectory $ModLoaderDir -YarnArgs @('run', 'tras:babel')
Write-Ok 'ModLoader 框架构建完成'

foreach ($d in @('dist-BeforeSC2', 'dist-BeforeSC2-comp', 'dist-BeforeSC2-comp-babel', 'dist-ForSC2', 'dist-insertTools')) {
    if (-not (Test-Path -LiteralPath (Join-Path $ModLoaderDir $d))) { throw "构建产物缺失: ModLoader\$d" }
}
$PackTool = Join-Path $ModLoaderDir 'dist-insertTools\packModZip.js'
if (-not (Test-Path -LiteralPath $PackTool)) { throw "打包工具缺失: $PackTool" }
Write-Ok '插桩工具 (dist-insertTools) 已生成'

# ============================================================================
# 4. 逐个构建 mod（对应工作流里约 20 组 Build + Copy 步骤）
# ============================================================================

Write-Section '第 3 阶段  /  构建各个 mod 并打包 .mod.zip'

# 每一项 = 工作流中的一组 "Build Xxx" + "Copy Xxx"
#   Dir     : 工作目录（相对 ModLoader\）
#   Boots   : 传给 dist-insertTools\packModZip.js 的 boot 文件（输出 <boot.name>.mod.zip）
#   Scripts : 需要执行的 package.json 脚本（顺序敏感！TweeReplacerLinker 必须最先）
#   Name    : 用于日志
$ModJobs = @(
    [pscustomobject]@{ Name = 'ModSubUiAngularJs';  Dir = 'mod\ModSubUiAngularJs';  Boots = @('boot.json');                     Scripts = @('build:ts', 'build:webpack') }
    [pscustomobject]@{ Name = 'ModLoaderGui';       Dir = 'mod\ModLoaderGui';       Boots = @('boot.json');                     Scripts = @('build:ts', 'build:webpack') }
    [pscustomobject]@{ Name = 'ImageLoaderHook';    Dir = 'mod\ImageLoaderHook';    Boots = @('boot.json', 'boot-core.json');   Scripts = @('build:ts', 'build:webpack', 'build-core:webpack') }
    [pscustomobject]@{ Name = 'CheckGameVersion';   Dir = 'mod\CheckGameVersion';   Boots = @('boot.json');                     Scripts = @('build:ts', 'build:webpack') }
    [pscustomobject]@{ Name = 'Diff3WayMerge';      Dir = 'mod\Diff3WayMerge';      Boots = @('boot.json');                     Scripts = @('build:ts', 'build:webpack') }
    [pscustomobject]@{ Name = 'DoLTimeWrapperAddon';Dir = 'mod\DoLTimeWrapperAddon';Boots = @('boot.json');                     Scripts = @('build:ts', 'build:webpack') }
    [pscustomobject]@{ Name = 'ModdedClothesAddon'; Dir = 'mod\ModdedClothesAddon'; Boots = @('boot.json');                     Scripts = @('build:ts', 'build:webpack') }
    [pscustomobject]@{ Name = 'ModdedFeatsAddon';   Dir = 'mod\ModdedFeatsAddon';   Boots = @('boot.json');                     Scripts = @('build:ts', 'build:webpack') }
    [pscustomobject]@{ Name = 'ModdedHairAddon';    Dir = 'mod\ModdedHairAddon';    Boots = @('boot.json');                     Scripts = @('build:ts', 'build:webpack') }
    [pscustomobject]@{ Name = 'ConflictChecker';    Dir = 'mod\ConflictChecker';    Boots = @('boot.json');                     Scripts = @('build:ts', 'build:webpack') }
    [pscustomobject]@{ Name = 'SweetAlert2Mod';     Dir = 'mod\SweetAlert2Mod';     Boots = @('boot.json');                     Scripts = @('build:ts', 'build:webpack') }
    [pscustomobject]@{ Name = 'I18nTweeList';       Dir = 'mod\I18nTweeList';       Boots = @('boot.json');                     Scripts = @('build:ts', 'build:webpack') }
    [pscustomobject]@{ Name = 'I18nScriptList';     Dir = 'mod\I18nScriptList';     Boots = @('boot.json');                     Scripts = @('build:ts', 'build:webpack') }
    [pscustomobject]@{ Name = 'ReplacePatch';       Dir = 'mod\ReplacePatch';       Boots = @('boot.json');                     Scripts = @('build:ts', 'build:webpack') }
    [pscustomobject]@{ Name = 'TweePrefixPostfixAddon'; Dir = 'mod\TweePrefixPostfixAddon'; Boots = @('boot.json');             Scripts = @('build:ts', 'build:webpack') }
    # TweeReplacerLinker 必须早于 TweeReplacer 和 I18nTweeReplacer 构建
    [pscustomobject]@{ Name = 'TweeReplacerLinker'; Dir = 'mod\TweeReplacerLinker'; Boots = @('boot.json');                     Scripts = @('ts:type', 'build:ts', 'build:webpack') }
    [pscustomobject]@{ Name = 'TweeReplacer';       Dir = 'mod\TweeReplacer';       Boots = @('boot.json');                     Scripts = @('build:ts', 'build:webpack') }
    [pscustomobject]@{ Name = 'I18nTweeReplacer';   Dir = 'mod\I18nTweeReplacer';   Boots = @('boot.json');                     Scripts = @('build:ts', 'build:webpack') }
    [pscustomobject]@{ Name = 'CheckDoLCompressorDictionaries'; Dir = 'mod\CheckDoLCompressorDictionaries'; Boots = @('boot.json'); Scripts = @('build:ts', 'build:webpack') }
    [pscustomobject]@{ Name = 'ModuleCssReplacer';  Dir = 'mod\ModuleCssReplacer';  Boots = @('boot.json');                     Scripts = @('build:ts', 'build:webpack') }
    [pscustomobject]@{ Name = 'BeautySelectorAddon';Dir = 'mod\BeautySelectorAddon';Boots = @('boot.json');                     Scripts = @('build:ts', 'build:webpack') }
    [pscustomobject]@{ Name = 'DoLHookWidget';      Dir = 'mod\DoLHookWidget';      Boots = @('boot.json');                     Scripts = @() }
    [pscustomobject]@{ Name = 'DoLLinkButtonFilter';Dir = 'mod\DoLLinkButtonFilter';Boots = @('boot.json');                     Scripts = @('build:ts', 'build:webpack') }
    [pscustomobject]@{ Name = 'HookMacroRng';       Dir = 'mod\HookMacroRng';       Boots = @('boot.json');                     Scripts = @('build:ts', 'build:webpack') }
    [pscustomobject]@{ Name = 'ImageLoaderHook2BeautySelectorAddon'; Dir = 'mod\ImageLoaderHook2BeautySelectorAddon'; Boots = @('boot.json'); Scripts = @('build:ts', 'build:webpack') }
)

if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

foreach ($job in $ModJobs) {
    $workDir = Join-Path $ModLoaderDir $job.Dir
    Write-Step "构建 mod: $($job.Name)"

    if (-not (Test-Path -LiteralPath $workDir)) {
        throw "mod 目录不存在: $workDir（子模块可能未初始化，请去掉 -SkipInit 重新运行）"
    }

    if (-not $SkipYarnInstall) {
        Invoke-Yarn -WorkingDirectory $workDir -YarnArgs @('install')
    }

    foreach ($s in $job.Scripts) {
        Invoke-Yarn -WorkingDirectory $workDir -YarnArgs @('run', $s)
    }

    # 等价于: node "...\dist-insertTools\packModZip.js" "boot.json"  (cwd = mod 目录)
    foreach ($boot in $job.Boots) {
        if (-not (Test-Path -LiteralPath (Join-Path $workDir $boot))) {
            throw "boot 文件不存在: $(Join-Path $workDir $boot)"
        }
        Invoke-External -FilePath $NodeExe -Arguments @($PackTool, $boot) -WorkingDirectory $workDir
    }

    Write-Ok "$($job.Name) 打包完成"
}

# ============================================================================
# 5. 复制各个 .mod.zip 到 ModLoader\out （对应各 "Copy Xxx" 步骤）
# ============================================================================

Write-Step '复制所有 mod 产物到 ModLoader\out\mod\<ModName>\'

# 注意：modList.json 中的路径形如 "mod/ModLoaderGui/ModLoaderGui.mod.zip"，
# 由 insert2html.js 以 ModLoader\out 为工作目录解析，所以必须保留 mod\<ModName>\ 层级。
$ModZipOutputs = @(
    @{ Mod = 'ModSubUiAngularJs';  Zip = 'mod\ModSubUiAngularJs\ModSubUiAngularJs.mod.zip' }
    @{ Mod = 'ModLoaderGui';       Zip = 'mod\ModLoaderGui\ModLoaderGui.mod.zip' }
    @{ Mod = 'ImageLoaderHook';    Zip = 'mod\ImageLoaderHook\ModLoader DoL ImageLoaderHook.mod.zip' }
    @{ Mod = 'ImageLoaderHook';    Zip = 'mod\ImageLoaderHook\ModLoader ImageLoaderHookCore.mod.zip' }
    @{ Mod = 'CheckGameVersion';   Zip = 'mod\CheckGameVersion\CheckGameVersion.mod.zip' }
    @{ Mod = 'Diff3WayMerge';      Zip = 'mod\Diff3WayMerge\Diff3WayMerge.mod.zip' }
    @{ Mod = 'DoLTimeWrapperAddon';Zip = 'mod\DoLTimeWrapperAddon\DoLTimeWrapperAddon.mod.zip' }
    @{ Mod = 'ModdedClothesAddon'; Zip = 'mod\ModdedClothesAddon\ModdedClothesAddon.mod.zip' }
    @{ Mod = 'ModdedFeatsAddon';   Zip = 'mod\ModdedFeatsAddon\ModdedFeatsAddon.mod.zip' }
    @{ Mod = 'ModdedHairAddon';    Zip = 'mod\ModdedHairAddon\ModdedHairAddon.mod.zip' }
    @{ Mod = 'ConflictChecker';    Zip = 'mod\ConflictChecker\ConflictChecker.mod.zip' }
    @{ Mod = 'SweetAlert2Mod';     Zip = 'mod\SweetAlert2Mod\SweetAlert2Mod.mod.zip' }
    @{ Mod = 'I18nTweeList';       Zip = 'mod\I18nTweeList\I18nTweeList.mod.zip' }
    @{ Mod = 'I18nScriptList';     Zip = 'mod\I18nScriptList\I18nScriptList.mod.zip' }
    @{ Mod = 'ReplacePatch';       Zip = 'mod\ReplacePatch\ReplacePatcher.mod.zip' }
    @{ Mod = 'TweePrefixPostfixAddon'; Zip = 'mod\TweePrefixPostfixAddon\TweePrefixPostfixAddon.mod.zip' }
    @{ Mod = 'TweeReplacerLinker'; Zip = 'mod\TweeReplacerLinker\TweeReplacerLinker.mod.zip' }
    @{ Mod = 'TweeReplacer';       Zip = 'mod\TweeReplacer\TweeReplacer.mod.zip' }
    @{ Mod = 'I18nTweeReplacer';   Zip = 'mod\I18nTweeReplacer\I18nTweeReplacer.mod.zip' }
    @{ Mod = 'CheckDoLCompressorDictionaries'; Zip = 'mod\CheckDoLCompressorDictionaries\CheckDoLCompressorDictionaries.mod.zip' }
    @{ Mod = 'ModuleCssReplacer';  Zip = 'mod\ModuleCssReplacer\ModuleCssReplacer.mod.zip' }
    @{ Mod = 'BeautySelectorAddon';Zip = 'mod\BeautySelectorAddon\BeautySelectorAddon.mod.zip' }
    @{ Mod = 'DoLHookWidget';      Zip = 'mod\DoLHookWidget\DoLHookWidget.mod.zip' }
    @{ Mod = 'DoLLinkButtonFilter';Zip = 'mod\DoLLinkButtonFilter\DoLLinkButtonFilter.mod.zip' }
    @{ Mod = 'HookMacroRng';       Zip = 'mod\HookMacroRng\HookMacroRng.mod.zip' }
    @{ Mod = 'ImageLoaderHook2BeautySelectorAddon'; Zip = 'mod\ImageLoaderHook2BeautySelectorAddon\ImageLoaderHook2BeautySelectorAddon.mod.zip' }
)

# 清理上一次（或旧版脚本）可能残留在 out\ 根下的扁平化目录，保证幂等
foreach ($stale in ($ModZipOutputs | Select-Object -ExpandProperty Mod -Unique)) {
    $staleDir = Join-Path $OutDir $stale
    if (Test-Path -LiteralPath (Join-Path $staleDir '*.mod.zip')) { Remove-DirIfExists $staleDir }
}

foreach ($item in $ModZipOutputs) {
    $src = Join-Path $ModLoaderDir $item.Zip
    if (-not (Test-Path -LiteralPath $src)) { throw "缺少 mod 打包产物: $src" }
    $dstDir = Join-Path (Join-Path $OutDir 'mod') $item.Mod
    if (-not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
    Copy-Item -LiteralPath $src -Destination $dstDir -Force
    Write-Info "$($item.Zip)  ->  out\mod\$($item.Mod)\"
}
Write-Ok "已复制 $($ModZipOutputs.Count) 个 mod zip 到 out\mod\"

# ============================================================================
# 6. GameOriginalImagePack mod
# ============================================================================

if (-not $SkipGameOriginalImagePack) {
    Write-Section '第 4 阶段  /  构建 GameOriginalImagePack mod'

    if (-not (Test-Path -LiteralPath $GopDir)) {
        throw "GameOriginalImagePack 目录不存在: $GopDir（请去掉 -SkipInit）"
    }

    Write-Step '构建 GameOriginalImagePack (yarn install / build:ts / build:webpack / build:tools)'
    if (-not $SkipYarnInstall) {
        Invoke-Yarn -WorkingDirectory $GopDir -YarnArgs @('install')
    }
    foreach ($s in @('build:ts', 'build:webpack', 'build:tools')) {
        Invoke-Yarn -WorkingDirectory $GopDir -YarnArgs @('run', $s)
    }
    Write-Ok 'GameOriginalImagePack 构建完成'

    Write-Step '复制游戏原图 DoL\img -> mod\GameOriginalImagePack\img (等价于 "Copy img (Win)")'
    $imgSrc = Join-Path $DoLDir 'img'
    if (-not (Test-Path -LiteralPath $imgSrc)) { throw "游戏图片目录不存在: $imgSrc" }
    Copy-Item -LiteralPath $imgSrc -Destination $GopDir -Recurse -Force
    Write-Ok "已复制 img ($((Get-ChildItem -LiteralPath $imgSrc -Recurse -File | Measure-Object).Count) 个文件)"

    Write-Step '读取游戏版本号 (等价于 readGameVersion.js + GITHUB_OUTPUT 输出)'
    $SugarCubeConfigJs = Join-Path $DoLDir 'game\01-config\sugarcubeConfig.js'
    if (-not (Test-Path -LiteralPath $SugarCubeConfigJs)) { throw "找不到游戏配置文件: $SugarCubeConfigJs" }

    $GithubOutputFile = Join-Path $env:TEMP "github-output-$Stamp.txt"
    $env:GITHUB_OUTPUT = $GithubOutputFile
    try {
        Invoke-External -FilePath $NodeExe -Arguments @((Join-Path $RepoRoot 'readGameVersion.js'), $SugarCubeConfigJs) -WorkingDirectory $RepoRoot
    }
    finally {
        Remove-Item Env:\GITHUB_OUTPUT -ErrorAction SilentlyContinue
    }

    $GameVersionString = ''
    if (Test-Path -LiteralPath $GithubOutputFile) {
        $m = Select-String -Path $GithubOutputFile -Pattern '^GameVersionString=(.+)$' | Select-Object -First 1
        if ($m) { $GameVersionString = $m.Matches[0].Groups[1].Value.Trim() }
        Remove-Item -LiteralPath $GithubOutputFile -Force -ErrorAction SilentlyContinue
    }
    if (-not $GameVersionString) { throw '无法从 sugarcubeConfig.js 解析游戏版本号' }
    Write-Ok "GameVersionString = $GameVersionString"

    Write-Step '生成 boot.json 并打包 GameOriginalImagePack.mod.zip'
    $BootTemplate = Join-Path $GopDir 'bootTemplate.json'
    $BootJson = Join-Path $GopDir 'boot.json'
    if (-not (Test-Path -LiteralPath $BootTemplate)) { throw "找不到 bootTemplate.json: $BootTemplate" }

    Invoke-External -FilePath $NodeExe -Arguments @(
        (Join-Path $GopDir 'dist-tools\bootJsonFillTool.js'), 'bootTemplate.json', 'img', $GameVersionString
    ) -WorkingDirectory $GopDir
    Invoke-External -FilePath $NodeExe -Arguments @($PackTool, 'boot.json') -WorkingDirectory $GopDir

    if (-not (Test-Path -LiteralPath $GopOutDir)) { New-Item -ItemType Directory -Path $GopOutDir -Force | Out-Null }
    Copy-FileToDir -Source (Join-Path $GopDir 'GameOriginalImagePack.mod.zip') -TargetDir $GopOutDir
    Write-Ok "已生成 out-GameOriginalImagePack\GameOriginalImagePack.mod.zip"
}
else {
    Write-Section '第 4 阶段  /  GameOriginalImagePack  —— 已跳过 (-SkipGameOriginalImagePack)'
}

# ============================================================================
# 7. 复制 dist-* 与 README 到 out
# ============================================================================

Write-Section '第 5 阶段  /  组装 ModLoader\out'

foreach ($d in @('dist-BeforeSC2', 'dist-BeforeSC2-comp', 'dist-BeforeSC2-comp-babel', 'dist-ForSC2', 'dist-insertTools')) {
    Write-Step "Copy $d/**/* -> ModLoader\out\$d\"
    Copy-TreeContents -Source (Join-Path $ModLoaderDir $d) -Target (Join-Path $OutDir $d)
}

Write-Step 'Copy README.md -> ModLoader\out\'
Copy-FileToDir -Source (Join-Path $ModLoaderDir 'README.md') -TargetDir $OutDir

# ============================================================================
# 8. 构建 SC2 (SugarCube-2)
# ============================================================================

if (-not $SkipSc2) {
    Write-Section '第 6 阶段  /  构建 SC2 (SugarCube-2)'
    Write-Step 'SC2: npm install + node build.js -d -u -b 2'
    Invoke-External -FilePath $NpmCmd -Arguments @('install') -WorkingDirectory $Sc2Dir
    Invoke-External -FilePath $NodeExe -Arguments @('build.js', '-d', '-u', '-b', '2') -WorkingDirectory $Sc2Dir
    Write-Ok 'SC2 构建完成 (SC2\build\twine2\sugarcube-2\format.js)'
}
else {
    Write-Section '第 6 阶段  /  构建 SC2  —— 已跳过 (-SkipSc2)'
}

# ============================================================================
# 9. 构建 DoL 游戏本体 HTML
# ============================================================================

Write-Section '第 7 阶段  /  构建 DoL 游戏本体 (compile.bat)'

$CompileBat = Join-Path $DoLDir 'compile.bat'
if (-not (Test-Path -LiteralPath $CompileBat)) { throw "找不到 DoL 编译脚本: $CompileBat" }

Write-Step '运行 DoL\compile.bat (tweego 编译游戏)'
$CmdExe = if ($env:ComSpec) { $env:ComSpec } else { 'cmd.exe' }
Invoke-External -FilePath $CmdExe -Arguments @('/d', '/c', 'compile.bat') -WorkingDirectory $DoLDir

if (-not (Test-Path -LiteralPath $GameHtml)) { throw "DoL 编译产物缺失: $GameHtml" }
Write-Ok "已生成: $GameHtml  ($([math]::Round((Get-Item -LiteralPath $GameHtml).Length / 1MB, 2)) MB)"

# ============================================================================
# 10. 给 DoL HTML 打 SC2 补丁  +  注入 ModLoader
# ============================================================================

Write-Section '第 8 阶段  /  注入 ModLoader 到游戏 HTML'

$Sc2PatchTool   = Join-Path $OutDir 'dist-insertTools\sc2PatchTool.js'
$InsertTool     = Join-Path $OutDir 'dist-insertTools\insert2html.js'
$InsertPolyTool = Join-Path $OutDir 'dist-insertTools\insert2html-polyfill.js'
foreach ($t in @($Sc2PatchTool, $InsertTool, $InsertPolyTool)) {
    if (-not (Test-Path -LiteralPath $t)) { throw "注入工具缺失: $t（请先完整构建一次，勿使用 -OnlyPackage）" }
}

$Sc2LocaleChs = Join-Path $Sc2Dir 'locale\chs.js'
if (-not (Test-Path -LiteralPath $Sc2LocaleChs)) { throw "找不到本地化文件: $Sc2LocaleChs" }

Write-Step 'Patch SC2 In DoL Html (dist-insertTools\sc2PatchTool.js)'
Invoke-External -FilePath $NodeExe -Arguments @($Sc2PatchTool, $GameHtml, $Sc2LocaleChs) -WorkingDirectory $DoLDir
if (-not (Test-Path -LiteralPath $PatchedHtml)) { throw "SC2 补丁产物缺失: $PatchedHtml" }
Write-Ok 'sc2patch 完成'

Write-Step 'Inject ModLoader (dist-insertTools\insert2html.js)'
Invoke-External -FilePath $NodeExe -Arguments @(
    $InsertTool, $PatchedHtml, 'modList.json', (Join-Path $OutDir 'dist-BeforeSC2\BeforeSC2.js')
) -WorkingDirectory $OutDir

if (-not (Test-Path -LiteralPath $ModHtml)) { throw "注入产物缺失: $ModHtml" }
Write-Ok '普通版 HTML 注入完成'
Write-Step 'Inject ModLoader-compatibility (dist-insertTools\insert2html-polyfill.js)'
Invoke-External -FilePath $NodeExe -Arguments @(
    $InsertPolyTool, $PatchedHtml, 'modList.json',
    (Join-Path $OutDir 'dist-BeforeSC2-comp\BeforeSC2.js'),
    (Join-Path $OutDir 'dist-BeforeSC2-comp\polyfillWebpack.js'),
    'ManualPolyfill.js'
) -WorkingDirectory $OutDir

if (-not (Test-Path -LiteralPath $ModPolyHtml)) { throw "注入产物缺失: $ModPolyHtml" }
Write-Ok '兼容版 HTML 注入完成'

Write-Step '产物冒烟校验 (确认注入内容真实存在于 HTML 中)'
Assert-FileHasText -Path $ModHtml     -Needle 'window.modDataValueZipList' -What '普通版 HTML'
Assert-FileHasText -Path $ModHtml     -Needle 'modSC2DataManager'              -What '普通版 HTML'
Assert-FileHasText -Path $ModHtml     -Needle 'window.mainStart'               -What '普通版 HTML'
Assert-FileHasText -Path $ModPolyHtml -Needle 'window.modDataValueZipList' -What '兼容版 HTML'
Assert-FileHasText -Path $ModPolyHtml -Needle 'id="polyfillManual"'        -What '兼容版 HTML'
Assert-FileHasText -Path $ModPolyHtml -Needle 'window.mainStart'               -What '兼容版 HTML'
Write-Ok '两个 HTML 均已包含 ModLoader 注入内容，且保留游戏本体入口'

} # end of if (-not $OnlyPackage)

# ============================================================================
# 11. 打包 output\DoL-ModLoader-<sha>.zip
# ============================================================================

Write-Section '第 9 阶段  /  打包最终产物 (zip-release 等价)'

foreach ($f in @($ModHtml, $ModPolyHtml)) {
    if (-not (Test-Path -LiteralPath $f)) { throw "缺少待打包的 HTML: $f（若使用 -OnlyPackage，请先完整构建一次）" }
}

Write-Step '准备 output\ 目录并复制 HTML 与 img'
Remove-DirIfExists $OutputDir
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

$ReleaseDir = Join-Path $RepoRoot 'release'
if (-not (Test-Path -LiteralPath $ReleaseDir)) { New-Item -ItemType Directory -Path $ReleaseDir -Force | Out-Null }

# release\ 里先清掉「本次将要生成」的同名资产，避免旧版本被误上传；
# 其它文件（你手工放进去的东西）一律不动。
$ZipName = "DoL-ModLoader-$Sha.zip"
$AssetNames = @($ZipName)
if ($Version) { $AssetNames += "DoL-ModLoader-$Version-$Sha.zip" }
$AssetNames += 'GameOriginalImagePack.mod.zip'
foreach ($name in $AssetNames) {
    $stale = Join-Path $ReleaseDir $name
    if (Test-Path -LiteralPath $stale) { Write-Info "清理旧资产 $name"; Remove-Item -LiteralPath $stale -Force }
}

Copy-FileToDir -Source $ModHtml      -TargetDir $OutputDir
Copy-FileToDir -Source $ModPolyHtml  -TargetDir $OutputDir
Write-Ok '已复制 2 个 HTML'

Write-Step 'Copy img (Win): DoL\img -> output\'
Copy-Item -LiteralPath (Join-Path $DoLDir 'img') -Destination $OutputDir -Recurse -Force
Write-Ok "已复制 img ($((Get-ChildItem -LiteralPath (Join-Path $OutputDir 'img') -Recurse -File | Measure-Object).Count) 个文件)"

$ZipPath = Join-Path $OutputDir $ZipName
Write-Step "打包 output\ -> output\$ZipName"
$entryCount = New-ZipFromDirectory -Directory $OutputDir -ZipPath $ZipPath
Write-Ok "zip 完成，共 $entryCount 个条目，$([math]::Round((Get-Item -LiteralPath $ZipPath).Length / 1MB, 2)) MB"

# ============================================================================
# 12. 发布产物 (等价于 action-gh-release)
# ============================================================================

Write-Section '第 10 阶段  /  整理发布产物'

$GopZip = Join-Path $GopOutDir 'GameOriginalImagePack.mod.zip'

# workflow_dispatch 分支：重命名为 DoL-ModLoader-<version>-<sha>.zip
if ($Version) {
    $VersionedZipName = "DoL-ModLoader-$Version-$Sha.zip"
    Copy-Item -LiteralPath $ZipPath -Destination (Join-Path $OutputDir $VersionedZipName) -Force
    $ZipName = $VersionedZipName
    $ZipPath = Join-Path $OutputDir $VersionedZipName
    Write-Ok "Release 资产名: output\$VersionedZipName"
}
else {
    Write-Info "未指定 -Version，沿用自动命名: output\$ZipName"
}

if (-not (Test-Path -LiteralPath $ReleaseDir)) { New-Item -ItemType Directory -Path $ReleaseDir -Force | Out-Null }
Copy-Item -LiteralPath $ZipPath -Destination $ReleaseDir -Force
if (Test-Path -LiteralPath $GopZip) {
    Copy-Item -LiteralPath $GopZip -Destination $ReleaseDir -Force
}
else {
    Write-Warn "未找到 $GopZip（使用了 -SkipGameOriginalImagePack？）"
}

# ============================================================================
# 13. 构建摘要
# ============================================================================

Write-Section '构建完成'

Write-Host ''
Write-Host '  产物清单 (等价于 CI 的 Artifacts / Release 资产):' -ForegroundColor White
Write-Host "    $ZipPath" -ForegroundColor Green
if (Test-Path -LiteralPath $GopZip) {
    Write-Host "    $GopZip" -ForegroundColor Green
}
Write-Host ''
Write-Host "  已复制到 release\ 目录，可直接用于创建 GitHub Release:" -ForegroundColor White
Get-ChildItem -LiteralPath $ReleaseDir -File | ForEach-Object {
    Write-Host ("    {0}  ({1} MB)" -f $_.Name, [math]::Round($_.Length / 1MB, 2)) -ForegroundColor Green
}

Write-Host ''
Write-Host '  校验信息:' -ForegroundColor White
foreach ($f in @($ZipPath, $GopZip)) {
    if (Test-Path -LiteralPath $f) {
        $hash = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash
        Write-Host ("    {0}`n      SHA256 {1}" -f (Split-Path -Leaf $f), $hash) -ForegroundColor Gray
    }
}

if (Test-Path -LiteralPath $ZipPath) {
    $n = Get-ZipEntryCount -ZipPath $ZipPath
    Write-Host "    zip 条目数: $n" -ForegroundColor Gray
}

Write-Host ''
Write-Host '  最终 HTML 文件:' -ForegroundColor White
foreach ($f in @($ModHtml, $ModPolyHtml)) {
    if (Test-Path -LiteralPath $f) {
        Write-Host ("    {0}  ({1} MB)" -f $f, [math]::Round((Get-Item -LiteralPath $f).Length / 1MB, 2)) -ForegroundColor Gray
    }
}

Write-Host ''
Write-Host "  构建日志: $LogFile" -ForegroundColor DarkGray

if ($script:Warnings.Count -gt 0) {
    Write-Host ''
    Write-Host '  警告汇总:' -ForegroundColor DarkYellow
    $script:Warnings | ForEach-Object { Write-Host "    - $_" -ForegroundColor DarkYellow }
}

}
finally {
    # 记录构建耗时
    Write-Host ''
    Write-Host ("  总耗时: {0:hh\:mm\:ss}" -f ((Get-Date) - $script:BuildStart)) -ForegroundColor DarkGray
    if ($script:TranscriptActive) {
        try { Stop-Transcript | Out-Null } catch { }
    }
}
