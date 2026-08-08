@echo off
chcp 65001>nul
setlocal
title MCKSP — обновление модов

rem Скрипт сам находит pack.toml рядом с собой или выше по дереву.
rem Если батник лежит совсем в стороне от пака — впишите путь сюда:
set "PACK="

set "PS1=%~dp0update-mods.ps1"
if not exist "%PS1%" goto :nops1

set "PACKARG="
if not "%PACK%"=="" set "PACKARG=-PackDir "%PACK%""

echo.
echo  Обновление модов в паке
echo  -----------------------
echo   1 — только проверить, что доступно
echo   2 — обновить всё, закоммитить и запушить
echo   3 — обновить всё, закоммитить без отправки
echo   4 — обновить один мод
echo.
set "CH="
set /p CH=  Выбор [1]: 
if "%CH%"=="" set "CH=1"

if "%CH%"=="1" goto :check
if "%CH%"=="2" goto :full
if "%CH%"=="3" goto :nopush
if "%CH%"=="4" goto :single

echo.
echo  [!] Неизвестный вариант: %CH%
goto :done

:check
call :run -CheckOnly
goto :done

:full
call :run
goto :done

:nopush
call :run -NoPush
goto :done

:single
echo.
echo  Укажите имя метафайла без .pw.toml — например create-aeroworks
set "MOD="
set /p MOD=  Имя мода: 
if "%MOD%"=="" goto :nomod
call :run -Mod "%MOD%"
goto :done

:nomod
echo.
echo  [!] Имя не указано.
goto :done

:nops1
echo.
echo  [!] update-mods.ps1 не найден рядом с батником.
goto :done

:run
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1%" %PACKARG% %*
if errorlevel 1 echo.
if errorlevel 1 echo  [!] Скрипт завершился с ошибкой, код %errorlevel%.
exit /b

:done
echo.
pause
exit /b 0
