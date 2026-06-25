@echo off
REM builds, then launches the tray app detached so no console window sticks around
cd /d "%~dp0"
dotnet build -c Release -v quiet -nologo
if errorlevel 1 ( echo Build failed - see the errors above. & pause & exit /b 1 )
start "" "bin\Release\net9.0-windows10.0.19041.0\nowplaying.exe" %*
