@echo off
DATE /T >> %TEMP%\Dynatrace-Install.log 2>&1
TIME /T >> %TEMP%\Dynatrace-Install.log 2>&1

powershell -NoProfile -ExecutionPolicy unrestricted -File InstallDynatraceInCloudService.ps1 >> %TEMP%\Dynatrace-Install.log 2>&1
exit /B 0
