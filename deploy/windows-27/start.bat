@echo off
REM ========================================================
REM 27 Windows 搜索主机启动脚本
REM 前置条件：
REM   1. stunnel Windows 服务已启动（承担 TLS 桥接）
REM   2. 已执行 pip install -e . 和 playwright install chromium
REM   3. backend-web\.env 已配置
REM ========================================================

setlocal
chcp 65001 > nul

REM 请按本机实际路径修改
set PROJECT_ROOT=F:\xianyu-search\xianyu-auto-reply
set VENV_ACTIVATE=%PROJECT_ROOT%\backend-web\.venv\Scripts\activate.bat

if not exist "%VENV_ACTIVATE%" (
    echo [错误] 虚拟环境不存在：%VENV_ACTIVATE%
    echo 请先在 backend-web 目录执行：
    echo   python -m venv .venv
    echo   .venv\Scripts\activate
    echo   pip install -e .
    echo   python -m playwright install chromium
    pause
    exit /b 1
)

REM 检查 stunnel 本地端口
echo [1/3] 检查 stunnel 是否正常（127.0.0.1:3306 / 6380）...
powershell -NoProfile -Command "$a=(Test-NetConnection -ComputerName 127.0.0.1 -Port 3306 -WarningAction SilentlyContinue).TcpTestSucceeded; $b=(Test-NetConnection -ComputerName 127.0.0.1 -Port 6380 -WarningAction SilentlyContinue).TcpTestSucceeded; if (-not ($a -and $b)) { exit 1 }"
if errorlevel 1 (
    echo [错误] stunnel 端口不通，请先启动 stunnel Windows 服务
    pause
    exit /b 1
)

echo [2/3] 激活 Python 虚拟环境...
call "%VENV_ACTIVATE%"

echo [3/3] 启动 backend-web（仅搜索/登录接口）...
cd /d "%PROJECT_ROOT%\backend-web"
python main.py

REM 退出后保留窗口便于查看日志
pause
