@echo off
chcp 65001>nul
setlocal
title MCKSP — галочка в unsup

rem Скрипт сам находит pack.toml рядом с собой или выше по дереву.
rem Если батник лежит в стороне от пака — впишите путь сюда:
set "PACK="

set "PS1=%~dp0add-to-unsup.ps1"
if not exist "%PS1%" goto :nops1

set "PACKARG="
if not "%PACK%"=="" set "PACKARG=-PackDir "%PACK%""

echo.
echo  Галочка в unsup
echo  ---------------
echo   1 — показать клиентские моды без галочки
echo   2 — добавить галочку
echo   3 — то же, но только показать, что будет
echo.
set "CH="
set /p CH=  Выбор [1]: 
if "%CH%"=="" set "CH=1"

if "%CH%"=="1" goto :list
if "%CH%"=="2" goto :add
if "%CH%"=="3" goto :dry

echo.
echo  [!] Неизвестный вариант: %CH%
goto :done

:list
call :run -List
goto :done

:add
call :ask
call :run "%MOD%"
goto :done

:dry
call :ask
call :run "%MOD%" -DryRun
goto :done

:ask
echo.
echo  Часть названия — или Enter, чтобы выбрать из полного списка
set "MOD="
set /p MOD=  Мод: 
exit /b

:nops1
echo.
echo  [!] add-to-unsup.ps1 не найден рядом с батником.
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
