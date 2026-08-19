@echo off
chcp 65001>nul
setlocal
title MCKSP - работа с модами

set "PS1=%~dp0add-mods.ps1"
if not exist "%PS1%" (
    echo [!] add-mods.ps1 не найден рядом с батником.
    echo     Ожидался путь: "%PS1%"
    pause
    exit /b 1
)

:menu
echo.
echo  MCKSP - работа с модами
echo  -----------------------
echo   1  Добавить моды из mods\
echo   2  Проверить расстановку client/server/both - только отчёт
echo   3  Проверить и применить расстановку
echo   0  Выход
echo.
set "MODE="
set /p MODE=  Что делаем? [1]: 
if not defined MODE set "MODE=1"

if "%MODE%"=="0" exit /b 0
if "%MODE%"=="1" goto add
if "%MODE%"=="2" goto recheck
if "%MODE%"=="3" goto apply

echo  Не понял ответ.
goto menu

:recheck
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Recheck
goto done

:apply
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Recheck -Apply
goto done

:add
echo.
echo  Убедитесь, что нужные jar лежат в mods\
echo.
set "VER="
set /p VER=  Новая версия пака (Enter - не менять): 
echo.
if not defined VER (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" -Version "%VER%"
)
goto done

:done
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" echo  [!] PowerShell завершился с кодом %RC%
pause
exit /b %RC%
