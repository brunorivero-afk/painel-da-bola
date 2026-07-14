param(
  [switch]$NoOpen
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$htmlPath = Join-Path $root 'painel_bola_tv.html'
$dadosJsonPath = Join-Path $root 'dados.json'
$dadosJsPath = Join-Path $root 'dados.js'
$logPath = Join-Path $root 'atualizar_painel.log'

$ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'

# O horário do sistema varia conforme onde o script roda (PC local em horário
# de Brasília, mas o runner do GitHub Actions usa UTC) — por isso convertemos
# explicitamente pra Brasília em vez de confiar no relógio local da máquina.
function Get-AgoraBrasilia(){
  try{ $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById('America/Sao_Paulo') }
  catch{ $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById('E. South America Standard Time') }
  return [System.TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, $tz)
}

function Write-Log($msg){
  $line = "[{0}] {1}" -f (Get-AgoraBrasilia).ToString('yyyy-MM-dd HH:mm:ss'), $msg
  Add-Content -Path $logPath -Value $line -Encoding UTF8
}

# Invoke-WebRequest às vezes detecta o charset errado quando o servidor não
# declara "charset" no header Content-Type (vira ISO-8859-1 em vez de UTF-8).
# Por isso pegamos os bytes crus e decodificamos como UTF-8 manualmente.
function Get-Utf8Text($url, $ua){
  $resp = Invoke-WebRequest -Uri $url -UserAgent $ua -UseBasicParsing -TimeoutSec 20
  $bytes = $resp.RawContentStream.ToArray()
  return [System.Text.Encoding]::UTF8.GetString($bytes)
}

# dado anterior, usado como fallback se alguma seção falhar
$dadosAnteriores = $null
if(Test-Path $dadosJsonPath){
  try{ $dadosAnteriores = Get-Content $dadosJsonPath -Raw | ConvertFrom-Json }catch{ $dadosAnteriores = $null }
}

$avisos = New-Object System.Collections.Generic.List[string]
$agoraBrasilia = Get-AgoraBrasilia
$hojeISO = $agoraBrasilia.ToString('yyyy-MM-dd')

# ---------- 1) Futebol na TV (futebolnatv.com.br) — hoje e amanhã ----------
function Get-FutebolDoDia($url, $dataISO, $ua){
  $html = Get-Utf8Text $url $ua
  $blockPattern = '<a href="/aovivo/[^"]+" class="block">([\s\S]*?)</article>\s*</a>'
  $blocks = [regex]::Matches($html, $blockPattern)
  $vistos = New-Object System.Collections.Generic.HashSet[string]
  $resultado = @()

  foreach($b in $blocks){
    $chunk = $b.Groups[1].Value

    $timeM = [regex]::Match($chunk, '<time[^>]*>\s*([0-9]{1,2}:[0-9]{2})\s*</time>')
    $compM = [regex]::Match($chunk, 'font-bold[^"]*">\s*([^<]+?)\s*</span>')
    $teamAM = [regex]::Match($chunk, 'id="jogo-card-team-a-[^"]*"[\s\S]{0,400}?class="truncate[^"]*"[^>]*>\s*([^<]+?)\s*</span>')
    $teamBM = [regex]::Match($chunk, 'id="jogo-card-team-b-[^"]*"[\s\S]{0,400}?class="truncate[^"]*"[^>]*>\s*([^<]+?)\s*</span>')

    $chanMatches = [regex]::Matches($chunk, 'hero-tv[\s\S]{0,200}?uppercase[^"]*"[^>]*>\s*([^<]+?)\s*</span>')
    $channels = @()
    foreach($cm in $chanMatches){ $channels += $cm.Groups[1].Value.Trim() }

    if($timeM.Success -and $teamAM.Success -and $teamBM.Success){
      $matchTxt = "$($teamAM.Groups[1].Value.Trim()) x $($teamBM.Groups[1].Value.Trim())"
      $key = "$($timeM.Groups[1].Value.Trim())|$matchTxt"
      if(-not $vistos.Add($key)){ continue }
      $resultado += [PSCustomObject]@{
        sport       = 'futebol'
        date        = $dataISO
        time        = $timeM.Groups[1].Value.Trim()
        competition = if($compM.Success){ $compM.Groups[1].Value.Trim() } else { 'Futebol' }
        match       = $matchTxt
        channels    = $channels
      }
    }
  }
  return $resultado
}

$jogosFutebol = @()
$amanhaISO = $agoraBrasilia.AddDays(1).ToString('yyyy-MM-dd')
try{
  $jogosFutebol += Get-FutebolDoDia 'https://www.futebolnatv.com.br/' $hojeISO $ua
  try{
    $jogosFutebol += Get-FutebolDoDia 'https://www.futebolnatv.com.br/jogos-amanha' $amanhaISO $ua
  }catch{
    Write-Log "Falha ao buscar futebol de amanhã (mantendo só hoje): $($_.Exception.Message)"
  }

  if($jogosFutebol.Count -eq 0){ throw 'Nenhum jogo de futebol encontrado no HTML (o site pode ter mudado de layout).' }
  Write-Log "Futebol: $($jogosFutebol.Count) jogo(s) extraído(s) (hoje + amanhã)."
}catch{
  $msg = "Falha ao buscar futebol na TV: $($_.Exception.Message)"
  Write-Log $msg
  $avisos.Add($msg)
  if($dadosAnteriores -and $dadosAnteriores.jogos){
    $jogosFutebol = @($dadosAnteriores.jogos | Where-Object { $_.sport -eq 'futebol' })
    $avisos.Add('Futebol: mantendo dados do último sucesso.')
  }
}

# ---------- 2) Vôlei na TV (meuguia.tv - grade SporTV2) ----------
$jogosVolei = @()
try{
  $html = Get-Utf8Text 'https://meuguia.tv/programacao/canal/SP2' $ua

  $itemPattern = "<div class='lileft time'>\s*([0-9]{1,2}:[0-9]{2})\s*</div>\s*<div class=`"licontent`">\s*<h2>\s*([\s\S]*?)\s*</h2>\s*<h3>\s*([^<]*?)\s*</h3>"
  $items = [regex]::Matches($html, $itemPattern)
  $vistosVolei = New-Object System.Collections.Generic.HashSet[string]

  foreach($it in $items){
    $categoria = $it.Groups[3].Value.Trim()
    if($categoria -notmatch '[Vv]\S*lei'){ continue }

    $titulo = $it.Groups[2].Value.Trim()
    # a grade lista cada partida várias vezes (reprises marcadas com "VT -");
    # mantemos só as exibições "Ao Vivo" pra não inundar o painel de reprise
    if($titulo -notmatch '-\s*Ao Vivo\s*$'){ continue }
    $titulo = $titulo -replace '\s*-\s*Ao Vivo\s*$', ''

    $tempo = $it.Groups[1].Value.Trim()
    $key = "$tempo|$titulo"
    if(-not $vistosVolei.Add($key)){ continue }

    $jogosVolei += [PSCustomObject]@{
      sport       = 'volei'
      date        = $hojeISO
      time        = $tempo
      competition = 'Vôlei (SporTV2)'
      match       = $titulo
      channels    = @('SporTV2')
    }
  }

  if($jogosVolei.Count -eq 0){ throw 'Nenhum jogo de vôlei ao vivo encontrado na grade (pode não ter vôlei programado hoje, ou o site mudou de layout).' }
  Write-Log "Vôlei: $($jogosVolei.Count) item(ns) extraído(s)."
}catch{
  $msg = "Falha ao buscar vôlei na TV: $($_.Exception.Message)"
  Write-Log $msg
  $avisos.Add($msg)
  if($dadosAnteriores -and $dadosAnteriores.jogos){
    $jogosVolei = @($dadosAnteriores.jogos | Where-Object { $_.sport -eq 'volei' })
  }
}

$jogos = @($jogosFutebol) + @($jogosVolei)

# ---------- 3) Clima (Open-Meteo) ----------
$cidades = @(
  @{ nome = 'Rio de Janeiro'; lat = -22.9068; lon = -43.1729 },
  @{ nome = 'Araruama';       lat = -22.8725; lon = -42.3428 },
  @{ nome = 'Itaipava (Petrópolis)'; lat = -22.3808; lon = -43.1486 },
  @{ nome = 'Teresópolis';    lat = -22.4127; lon = -42.9662 }
)

function CondicaoDoCodigo($codigo){
  switch ($codigo){
    0 { 'Céu limpo' }
    1 { 'Poucas nuvens' }
    2 { 'Parcialmente nublado' }
    3 { 'Nublado' }
    45 { 'Neblina' }
    48 { 'Neblina com geada' }
    51 { 'Garoa fraca' }
    53 { 'Garoa' }
    55 { 'Garoa forte' }
    61 { 'Chuva fraca' }
    63 { 'Chuva' }
    65 { 'Chuva forte' }
    80 { 'Pancadas de chuva' }
    81 { 'Pancadas de chuva' }
    82 { 'Pancadas de chuva fortes' }
    95 { 'Trovoada' }
    96 { 'Trovoada com granizo' }
    99 { 'Trovoada com granizo' }
    default { 'Sem descrição' }
  }
}

$clima = @()
foreach($c in $cidades){
  try{
    $url = "https://api.open-meteo.com/v1/forecast?latitude=$($c.lat)&longitude=$($c.lon)&daily=temperature_2m_max,temperature_2m_min,precipitation_probability_max,weathercode&timezone=America%2FSao_Paulo&forecast_days=1"
    $r = Invoke-RestMethod -Uri $url -TimeoutSec 15
    $clima += [PSCustomObject]@{
      cidade        = $c.nome
      temp_max      = $r.daily.temperature_2m_max[0]
      temp_min      = $r.daily.temperature_2m_min[0]
      chance_chuva  = $r.daily.precipitation_probability_max[0]
      condicao      = CondicaoDoCodigo($r.daily.weathercode[0])
    }
  }catch{
    $msg = "Falha ao buscar clima de $($c.nome): $($_.Exception.Message)"
    Write-Log $msg
    $avisos.Add($msg)
    $anterior = $null
    if($dadosAnteriores -and $dadosAnteriores.clima){
      $anterior = $dadosAnteriores.clima | Where-Object { $_.cidade -eq $c.nome } | Select-Object -First 1
    }
    if($anterior){ $clima += $anterior }
  }
}

# ---------- 4) Notícias do Fluminense (Google News RSS) ----------
$noticias = @()
try{
  $url = 'https://news.google.com/rss/search?q=Fluminense%20Futebol%20Clube&hl=pt-BR&gl=BR&ceid=BR:pt-419'
  $xmlText = Get-Utf8Text $url $ua
  $rssDoc = New-Object System.Xml.XmlDocument
  $rssDoc.LoadXml($xmlText)
  $items = $rssDoc.SelectNodes('//item') | Select-Object -First 5
  foreach($it in $items){
    $dataFmt = ''
    try{
      $dt = [datetime]::Parse($it.pubDate, [System.Globalization.CultureInfo]::InvariantCulture)
      $dataFmt = $dt.ToString('dd/MM HH:mm')
    }catch{ $dataFmt = '' }
    $noticias += [PSCustomObject]@{
      titulo = $it.title
      link   = $it.link
      data   = $dataFmt
    }
  }
  if($noticias.Count -eq 0){ throw 'RSS não retornou itens.' }
  Write-Log "Notícias: $($noticias.Count) manchete(s) extraída(s)."
}catch{
  $msg = "Falha ao buscar notícias do Fluminense: $($_.Exception.Message)"
  Write-Log $msg
  $avisos.Add($msg)
  if($dadosAnteriores -and $dadosAnteriores.noticias){ $noticias = $dadosAnteriores.noticias }
}

# ---------- Grava dados.json e dados.js ----------
$painelData = [PSCustomObject]@{
  atualizado_em = $agoraBrasilia.ToString('dd/MM/yyyy HH:mm')
  jogos         = $jogos
  clima         = $clima
  noticias      = $noticias
  avisos        = $avisos
}

$json = $painelData | ConvertTo-Json -Depth 6
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($dadosJsonPath, $json, $utf8NoBom)
[System.IO.File]::WriteAllText($dadosJsPath, "window.PAINEL_DATA = $json;", $utf8NoBom)

Write-Log "Atualização concluída. Jogos: $($jogos.Count) | Clima: $($clima.Count) | Notícias: $($noticias.Count) | Avisos: $($avisos.Count)"

if(-not $NoOpen){
  try{ Start-Process $htmlPath }catch{ Write-Log "Não consegui abrir o navegador automaticamente: $($_.Exception.Message)" }
}
