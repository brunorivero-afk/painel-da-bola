$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$scriptPath = Join-Path $root 'atualizar_painel.ps1'
$taskName = 'PainelDaBola-AtualizacaoDiaria'

function Install-StartupShortcut {
  $startupFolder = [Environment]::GetFolderPath('Startup')
  $shortcutPath = Join-Path $startupFolder 'AtualizarPainelDaBola.lnk'
  $WshShell = New-Object -ComObject WScript.Shell
  $shortcut = $WshShell.CreateShortcut($shortcutPath)
  $shortcut.TargetPath = 'powershell.exe'
  $shortcut.Arguments = "-NoProfile -WindowStyle Hidden -File `"$scriptPath`""
  $shortcut.WorkingDirectory = $root
  $shortcut.WindowStyle = 7
  $shortcut.Description = 'Atualiza o Painel da Bola (jogos, clima e notícias do Fluminense) automaticamente ao logar no Windows.'
  $shortcut.Save()
  return $shortcutPath
}

# Tenta primeiro via Agendador de Tarefas (mais robusto).
$usouAgendador = $false
try{
  if(Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue){
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
  }
  $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -File `"$scriptPath`""
  $trigger = New-ScheduledTaskTrigger -AtLogOn
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
  Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings `
    -Description 'Atualiza o Painel da Bola (jogos, clima e notícias do Fluminense) automaticamente ao fazer logon no Windows.' -ErrorAction Stop | Out-Null

  if(Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue){
    $usouAgendador = $true
  }
}catch{
  Write-Output "Agendador de Tarefas bloqueado neste computador (comum em máquinas de domínio/corporativas): $($_.Exception.Message)"
}

if($usouAgendador){
  Write-Output "Tarefa '$taskName' instalada no Agendador de Tarefas do Windows. Vai rodar sozinha a cada logon."
}else{
  # Alternativa que não depende de permissão nenhuma: atalho na pasta Inicializar do Windows.
  try{
    $shortcutPath = Install-StartupShortcut
    Write-Output "Instalei via pasta 'Inicializar' do Windows em vez do Agendador de Tarefas (o Agendador está bloqueado nesta máquina)."
    Write-Output "Atalho criado em: $shortcutPath"
    Write-Output "Vai rodar automaticamente sempre que alguém fizer login no Windows."
  }catch{
    Write-Output "ERRO: não consegui instalar nem pelo Agendador nem pela pasta Inicializar ($($_.Exception.Message))."
    Write-Output "Rode 'atualizar_painel.ps1' manualmente sempre que quiser atualizar os dados."
    exit 1
  }
}
