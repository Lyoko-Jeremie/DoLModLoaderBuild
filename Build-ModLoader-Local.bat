@echo off
rem ===========================================================================
rem  本地一键构建  ——  等价于 GitHub Actions 的 Build-Html-Package.yml
rem
rem  双击本文件即可开始构建（无需管理员权限）。
rem  想自定义参数时，请直接在 PowerShell 中运行 Build-ModLoader-Local.ps1，例如：
rem      .\Build-ModLoader-Local.ps1 -Version 0.5.12.13
rem      .\Build-ModLoader-Local.ps1 -SkipInit -SkipYarnInstall
rem
rem  完整构建日志（含所有工具输出）会写入 build-logs\Build-ModLoader-Local.latest.log
rem ===========================================================================

setlocal

rem 切到脚本所在目录（仓库根目录）
cd /d "%~dp0"

pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0Build-ModLoader-Local.ps1" %*
set "EXITCODE=%ERRORLEVEL%"

echo.
if "%EXITCODE%"=="0" (
    echo [完成] 构建成功，产物在 output\ 与 release\ 目录中。
) else (
    echo [失败] 构建中断，错误码 %EXITCODE%，详见 build-logs\Build-ModLoader-Local.latest.log。
)

echo.
pause
exit /b %EXITCODE%
