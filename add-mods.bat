@echo off
chcp 65001>nul
setlocal
title MCKSP — добавление модов

set "PS1=%~dp0add-mods.ps1"
if not exist "%PS1%" (
    echo [!] add-mods.ps1 не найден рядом с батником.
    pause & exit /b 1
)

echo.
echo  Добавление модов в пак
echo  ----------------------
echo  Убедитесь, что нужные jar лежат в mods\
echo.
set "VER="
set /p VER=  Новая версия пака (Enter — не менять): 

echo.
if "%VER%"=="" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Version "%VER%"
)

echo.
pause
