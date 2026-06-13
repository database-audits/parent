@echo off

echo Running...

set FILE=%~dp0\versions-updates.log
echo  > %FILE%
call .\mvnw versions:display-property-updates >> %FILE%

pause
