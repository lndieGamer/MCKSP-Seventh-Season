@echo off
chcp 65001>nul
setlocal
title MCKSP — сторона мода

rem Скрипт сам находит pack.toml рядом с собой или выше по дереву.
rem Если батник лежит в стороне от пака — впишите путь сюда:
set "PACK="

set "PS1=%~dp0set-side.ps1"
if not exist "%PS1%" goto :nops1

set "PACKARG="
if not "%PACK%"=="" set "PACKARG=-PackDir "%PACK%""

echo.
echo  Сторона мода
echo  ------------
echo   1 — показать текущую раскладку
echo   2 — найти мод и сменить сторону
echo   3 — то же, но только показать, что будет
echo.
set "CH="
set /p CH=  Выбор [2]: 
if "%CH%"=="" set "CH=2"

if "%CH%"=="1" goto :list
if "%CH%"=="2" goto :change
if "%CH%"=="3" goto :dry

echo.
echo  [!] Неизвестный вариант: %CH%
goto :done

:list
call :run -List
goto :done

:change
call :ask
call :run "%MOD%"
goto :done

:dry
call :ask
call :run "%MOD%" -DryRun
goto :done

:ask
echo.
echo  Можно ввести часть названия — например sodium или карт
set "MOD="
set /p MOD=  Мод: 
exit /b

:nops1
echo.
echo  [!] set-side.ps1 не найден рядом с батником.
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
