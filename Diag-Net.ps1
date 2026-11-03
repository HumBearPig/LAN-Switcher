<#
  Diag-Net.ps1 — диагностика переключения приоритета (Ethernet <-> Wi-Fi)

  Зачем: виджет показывает метрики 25/9999, но трафик идёт «не туда».
  Скрипт показывает, какой интерфейс Windows выбирает ПРЯМО СЕЙЧАС и почему.

  Запуск (права администратора НЕ нужны, только чтение):
      powershell -NoProfile -ExecutionPolicy Bypass -File .\Diag-Net.ps1

  Отчёт печатается в окно и сохраняется в Diag-Net.txt рядом со скриптом.
#>

$ErrorActionPreference = 'SilentlyContinue'
$L = New-Object System.Collections.Generic.List[string]

function Say([string]$t = '') { $L.Add($t) | Out-Null; Write-Host $t }
function Head([string]$t) { Say ''; Say ('=' * 70); Say $t; Say ('=' * 70) }
function Dump($obj) {
    $txt = ($obj | Format-Table -AutoSize | Out-String -Width 200)
    foreach ($line in $txt -split "`r?`n") { if ($line.Trim()) { Say ('  ' + $line.TrimEnd()) } }
}

Say "LAN Switcher — диагностика сети"
Say ("Дата: {0}   ПК: {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $env:COMPUTERNAME)

# ---------------------------------------------------------------- 1
Head '1. ФИЗИЧЕСКИЕ АДАПТЕРЫ'
Dump (Get-NetAdapter -Physical |
      Select-Object Name, InterfaceIndex, Status, LinkSpeed, PhysicalMediaType, InterfaceDescription)

# ---------------------------------------------------------------- 2
Head '2. IP-КОНФИГУРАЦИЯ АКТИВНЫХ АДАПТЕРОВ'
$ups = @(Get-NetAdapter -Physical | Where-Object { $_.Status -eq 'Up' })
foreach ($a in $ups) {
    $ip  = Get-NetIPAddress -InterfaceIndex $a.InterfaceIndex -AddressFamily IPv4 |
           Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1
    $cfg = Get-NetIPConfiguration -InterfaceIndex $a.InterfaceIndex
    $gw  = ($cfg.IPv4DefaultGateway.NextHop | Select-Object -First 1)
    $dns = ($cfg.DNSServer | Where-Object { $_.AddressFamily -eq 2 }).ServerAddresses -join ', '
    Say ("  {0,-24} IP = {1,-16} /{2,-3} GW = {3,-16} DNS = {4}" -f `
         $a.Name, $ip.IPAddress, $ip.PrefixLength, $gw, $dns)
}

# ---------------------------------------------------------------- 3
Head '3. МЕТРИКИ ИНТЕРФЕЙСОВ (важно: IPv4 и IPv6 — РАЗНЫЕ стеки)'
Dump (Get-NetIPInterface |
      Where-Object { $_.ConnectionState -eq 'Connected' } |
      Sort-Object InterfaceAlias, AddressFamily |
      Select-Object InterfaceAlias, AddressFamily, InterfaceMetric, AutomaticMetric, ConnectionState)
Say '  Ожидаем: у приоритетного адаптера InterfaceMetric = 25, у второго = 9999,'
Say '  AutomaticMetric = Disabled У ОБОИХ и в IPv4, и в IPv6.'

# ---------------------------------------------------------------- 4
Head '4. МАРШРУТЫ ПО УМОЛЧАНИЮ IPv4 (итог = RouteMetric + InterfaceMetric)'
$rows = foreach ($r in @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -PolicyStore ActiveStore)) {
    $ifm = (Get-NetIPInterface -InterfaceIndex $r.InterfaceIndex -AddressFamily IPv4).InterfaceMetric
    [PSCustomObject]@{
        Alias       = $r.InterfaceAlias
        NextHop     = $r.NextHop
        RouteMetric = $r.RouteMetric
        IfMetric    = $ifm
        TOTAL       = ([int]$r.RouteMetric + [int]$ifm)
        Protocol    = $r.Protocol
    }
}
Dump ($rows | Sort-Object TOTAL)
Say '  >>> Windows выбирает строку с НАИМЕНЬШИМ TOTAL. Если наверху не тот'
Say '      адаптер, что выбран в виджете — причина здесь (см. RouteMetric).'

# ---------------------------------------------------------------- 5
Head '5. ПОСТОЯННЫЕ (persistent) МАРШРУТЫ — перебивают метрики'
$pers = @(Get-NetRoute -PolicyStore PersistentStore)
if ($pers.Count) {
    Dump ($pers | Select-Object DestinationPrefix, NextHop, InterfaceAlias, RouteMetric)
    Say '  !!! Есть постоянные маршруты. Если среди них 0.0.0.0/0 — он может'
    Say '      держать трафик на одном адаптере вне зависимости от метрик.'
} else {
    Say '  нет постоянных маршрутов — это нормально.'
}

# ---------------------------------------------------------------- 6
Head '6. ГЛАВНЫЙ ТЕСТ: какой интерфейс Windows ВЫБЕРЕТ для нового соединения'
foreach ($dst in @('8.8.8.8', '1.1.1.1')) {
    $fr    = @(Find-NetRoute -RemoteIPAddress $dst)
    $src   = ($fr | Where-Object { $_.IPAddress } | Select-Object -First 1).IPAddress
    $alias = ($fr | Select-Object -First 1).InterfaceAlias
    Say ("  -> {0,-9} пойдёт через `"{1}`"   (адрес источника {2})" -f $dst, $alias, $src)
}
Say ''
Say '  >>> ЭТО ВЕРДИКТ. Если здесь стоит Wi-Fi, значит маршрутизация ПЕРЕКЛЮЧИЛАСЬ,'
Say '      и проблема в старых соединениях/кэше приложений, а не в метриках.'
Say '      Если здесь Ethernet — метрики не сработали, смотри пункты 3-5.'

# ---------------------------------------------------------------- 7
Head '7. ОБА АДАПТЕРА ЗА ОДНИМ ШЛЮЗОМ?'
$gws = @()
foreach ($a in $ups) {
    $g = (Get-NetIPConfiguration -InterfaceIndex $a.InterfaceIndex).IPv4DefaultGateway.NextHop |
         Select-Object -First 1
    if ($g) { $gws += $g }
}
Say ("  шлюзы: {0}" -f ($gws -join ', '))
if ($gws.Count -ge 2 -and (@($gws | Select-Object -Unique).Count -eq 1)) {
    Say '  !!! ОБА адаптера смотрят в ОДИН шлюз (один роутер).'
    Say '      Внешний IP будет ОДИНАКОВЫМ на обоих. Проверять переключение'
    Say '      по сайту «какой у меня IP» БЕССМЫСЛЕННО — разницы не будет,'
    Say '      даже когда переключение работает идеально.'
} elseif ($gws.Count -ge 2) {
    Say '  шлюзы разные — переключение должно быть видно по внешнему IP.'
} else {
    Say '  найден только один шлюз — второй адаптер без выхода в интернет.'
}

# ---------------------------------------------------------------- 8
Head '8. ЖИВЫЕ СОЕДИНЕНИЯ: через какой адаптер идут ФАКТИЧЕСКИ'
$map = @{}
Get-NetIPAddress -AddressFamily IPv4 | ForEach-Object { $map[$_.IPAddress] = $_.InterfaceAlias }
$conns = @(Get-NetTCPConnection -State Established |
           Where-Object { $_.LocalAddress -notmatch '^(127\.|::1|0\.0\.0\.0|::)' })
if ($conns.Count) {
    $conns | Group-Object LocalAddress | Sort-Object Count -Descending | ForEach-Object {
        $ali = $map[$_.Name]; if (-not $ali) { $ali = '?' }
        Say ("  {0,-16} [{1,-22}] соединений: {2}" -f $_.Name, $ali, $_.Count)
    }
    Say ''
    Say '  Топ-процессы и их адаптер:'
    foreach ($g in @($conns | Group-Object OwningProcess | Sort-Object Count -Descending | Select-Object -First 10)) {
        $pid0  = [int]$g.Name
        $pname = (Get-Process -Id $pid0).ProcessName
        if (-not $pname) { $pname = "PID $pid0" }
        $addr  = ($g.Group | Select-Object -First 1).LocalAddress
        $ali   = $map[$addr]; if (-not $ali) { $ali = '?' }
        Say ("    {0,-22} [{1,-22}] соединений: {2}" -f $pname, $ali, $g.Count)
    }
} else {
    Say '  установленных внешних соединений нет.'
}

# ---------------------------------------------------------------- 9
Head '9. IPv6 — маршруты по умолчанию'
$r6 = @(Get-NetRoute -DestinationPrefix '::/0' -PolicyStore ActiveStore)
if ($r6.Count) {
    Dump ($r6 | Select-Object InterfaceAlias, NextHop, RouteMetric)
    Say '  Если IPv6 активен и его метрики НЕ переключены — часть трафика'
    Say '  (особенно Google/YouTube) пойдёт по IPv6 через «старый» адаптер.'
} else {
    Say '  IPv6-маршрутов по умолчанию нет — весь трафик по IPv4. Хорошо.'
}

# ---------------------------------------------------------------- 10
Head '10. WI-FI: авто-отключение при подключённом кабеле'
$wifi = @(Get-NetAdapter -Physical | Where-Object {
             $_.PhysicalMediaType -match '802\.11|Wireless' -or $_.InterfaceDescription -match 'Wi-?Fi' })
if ($wifi.Count) {
    foreach ($w in $wifi) {
        Say ("  {0}: Status = {1}" -f $w.Name, $w.Status)
        $props = @(Get-NetAdapterAdvancedProperty -Name $w.Name |
                   Where-Object { $_.DisplayName -match 'Wireless|Switch|Roam|Power|Smart' })
        if ($props.Count) { Dump ($props | Select-Object DisplayName, DisplayValue) }
    }
} else {
    Say '  Wi-Fi адаптер не найден.'
}

# ---------------------------------------------------------------- save
$dir = if ($PSScriptRoot) { $PSScriptRoot } elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { '.' }
$outFile = Join-Path $dir 'Diag-Net.txt'
try {
    ($L -join "`r`n") | Set-Content -Path $outFile -Encoding UTF8
    Say ''
    Say ("Отчёт сохранён: {0}" -f $outFile)
} catch {
    Say ''
    Say ("Не удалось сохранить отчёт: {0}" -f $_.Exception.Message)
}
Say ''
Read-Host 'Нажмите Enter для выхода'
