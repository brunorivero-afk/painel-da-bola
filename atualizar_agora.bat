@echo off
echo Atualizando o Painel da Bola (jogos, clima e noticias)...
powershell -NoProfile -File "%~dp0atualizar_painel.ps1"
echo.
echo Pronto! O painel foi atualizado e deve abrir no navegador.
pause
