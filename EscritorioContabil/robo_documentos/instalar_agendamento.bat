@echo off
REM Agenda o robo para rodar a cada 10 minutos neste computador.
schtasks /Create /TN "Robo de documentos - Escritorio" /TR "\"%~dp0rodar.bat\"" /SC MINUTE /MO 10 /F
echo.
echo Agendado. Para remover: schtasks /Delete /TN "Robo de documentos - Escritorio" /F
pause
