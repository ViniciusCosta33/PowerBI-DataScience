@echo off
cd /d "%~dp0"
python robo_documentos.py >> robo_saida.log 2>&1
