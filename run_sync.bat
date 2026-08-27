@echo off
REM Windows Task Scheduler action target.
REM Task Scheduler action: Program/script = full path to this .bat file
REM                        Start in       = this folder
cd /d "%~dp0"
python sync_attendance_to_erp.py
