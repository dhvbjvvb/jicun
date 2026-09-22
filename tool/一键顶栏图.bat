@echo off
rem One-key header art. ASCII only on purpose: once chcp 65001 runs, cmd.exe
rem re-reads a batch file with wrong byte offsets and shreds non-ASCII lines.
rem All Chinese prompts are printed by make_header_art.py instead.
rem
rem Usage: double-click this file, drag a transparent-background PNG into the
rem window, press Enter. Or drop the PNG straight onto this file. An optional
rem second argument names the settings sub-page to update (default: notification
rem page). This file must keep CRLF line endings.

setlocal
cd /d "%~dp0.."
python "tool\make_header_art.py" "%~1" --preview --patch "%~2"
if errorlevel 1 goto fail

echo.
echo Done. Hot-restart the app to see it.
goto done

:fail
echo.
echo Failed: no image, or python / Pillow unavailable.
echo Manual: python tool\make_header_art.py "image.png" --patch

:done
if not defined NO_PAUSE pause
exit /b 0
