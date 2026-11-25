@echo off
rem Builds NearsideCamera.dll (the virtual camera's media source) with the Visual Studio tools.
rem   build.cmd [arm64|x64]   (default: this PC's architecture)
setlocal
set ARCH=%1
if "%ARCH%"=="" if /i "%PROCESSOR_ARCHITECTURE%"=="ARM64" (set ARCH=arm64) else (set ARCH=x64)
for /f "usebackq tokens=*" %%i in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * -property installationPath`) do set VS=%%i
if /i "%PROCESSOR_ARCHITECTURE%"=="ARM64" (set HOST=arm64) else (set HOST=amd64)
rem vcvarsall's names: amd64 (not x64), and host_target only when they differ.
if /i "%ARCH%"=="x64" (set VCARCH=amd64) else (set VCARCH=%ARCH%)
if /i "%HOST%"=="%VCARCH%" (set TARGET=%VCARCH%) else (set TARGET=%HOST%_%VCARCH%)
call "%VS%\VC\Auxiliary\Build\vcvarsall.bat" %TARGET% >nul || exit /b 1
where cl >nul 2>nul || (echo error: the Visual Studio C++ tools for %TARGET% aren't installed & exit /b 1)
cd /d "%~dp0"
if not exist build\%ARCH% mkdir build\%ARCH%
cl /nologo /LD /O2 /EHsc /std:c++17 /W4 /DUNICODE /D_UNICODE NearsideCamera.cpp /Fobuild\%ARCH%\ /Febuild\%ARCH%\NearsideCamera.dll ^
   /link /DEF:NearsideCamera.def mfplat.lib mf.lib mfuuid.lib mfsensorgroup.lib ole32.lib advapi32.lib propsys.lib
