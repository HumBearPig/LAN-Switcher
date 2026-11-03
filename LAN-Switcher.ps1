#Requires -Version 5.1
# Глушим записи прогресса: ps2exe (noConsole) рисует их отдельным окном,
# которое без завершающей записи зависает на экране навсегда.
$ProgressPreference = 'SilentlyContinue'
<#
  LAN Switcher — виджет переключения приоритета сетевых адаптеров.
  Запуск: двойной клик по LAN-Switcher.bat (сам запросит права администратора).
  Клик по тоглу или по названию адаптера — переключает приоритет (метрики 1 <-> 9999).
#>

# ==================== НАСТРОЙКИ ====================
$LeftAlias  = 'Ethernet 4'     # Realtek PCIe 2.5GbE
$LeftLabel  = 'Realtek 2.5G'   # подпись слева (можно «Провайдер»)
$RightAlias = 'Ethernet 3'     # Intel I211 Gigabit
$RightLabel = 'Intel 1G'       # подпись справа (можно «Tailscale»)
$HighMetric = 25               # метрика приоритетного адаптера (25 — выше VPN-туннелей (5), метрика 1 ломает VPN!)
$LowMetric  = 9999             # метрика второстепенного
$ForceBindIPDir = 'C:\Program Files (x86)\ForceBindIP'   # папка с ForceBindIP.exe / ForceBindIP64.exe
# ===================================================

# Папка скрипта/exe — устойчиво к режиму (.ps1 или скомпилированный .exe)
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot }
             elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath }
             else { Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName) }
# Прокси-движок — программный файл, лежит рядом с exe/скриптом
$ProxyScript = Join-Path $ScriptDir 'LAN-Switcher-Proxy.ps1'

# Пользовательские данные (правила, настройки, лаунчеры) — в %APPDATA%\LANSwitcher,
# чтобы не зависеть от того, куда перенесли exe. Виджет всегда найдёт их здесь.
$DataDir = Join-Path $env:APPDATA 'LANSwitcher'
New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
$RulesPath    = Join-Path $DataDir 'rules.json'
$ConfigPath   = Join-Path $DataDir 'config.json'
$ProfilesPath = Join-Path $DataDir 'profiles.json'

# Разовая миграция старых файлов, если они лежали рядом со скриптом
foreach ($pair in @(
    @{ Old = (Join-Path $ScriptDir 'LAN-Switcher.rules.json');  New = $RulesPath },
    @{ Old = (Join-Path $ScriptDir 'LAN-Switcher.config.json'); New = $ConfigPath })) {
    if ((Test-Path $pair.Old) -and -not (Test-Path $pair.New)) {
        try { Move-Item $pair.Old $pair.New -Force } catch { }
    }
}

# Состояние запущенных прокси (ключ — IP адаптера): порт + процесс
$script:ProxyByIp   = @{}
$script:NextProxyPort = 13128
$script:SavedActiveAlias = $null
# Язык по умолчанию — по системной локали (ru → русский, иначе английский)
$script:Lang = if ((Get-Culture).TwoLetterISOLanguageName -eq 'ru') { 'ru' } else { 'en' }
# Новые настройки (v2). Значения по умолчанию, перекрываются из config.json
$script:Autostart = $false
$script:Logging   = $false
$script:LogPath   = Join-Path $DataDir 'lan-switcher.log'
$script:Hotkeys   = @{ Toggle = ''; Left = ''; Right = ''; Auto = '' }
if (Test-Path $ConfigPath) {
    try {
        $cfg = Get-Content -Raw -Encoding UTF8 $ConfigPath | ConvertFrom-Json
        if ($cfg.HighMetric) { $HighMetric = [int]$cfg.HighMetric }
        if ($cfg.LowMetric)  { $LowMetric  = [int]$cfg.LowMetric }
        if ($cfg.ActiveAlias) { $script:SavedActiveAlias = [string]$cfg.ActiveAlias }
        if ($cfg.Language)    { $script:Lang = [string]$cfg.Language }
        if ($null -ne $cfg.Autostart) { $script:Autostart = [bool]$cfg.Autostart }
        if ($null -ne $cfg.Logging)   { $script:Logging   = [bool]$cfg.Logging }
        if ($cfg.LogPath)             { $script:LogPath   = [string]$cfg.LogPath }
        if ($cfg.Hotkeys)             { $script:Hotkeys = @{ Toggle = "$($cfg.Hotkeys.Toggle)"; Left = "$($cfg.Hotkeys.Left)"; Right = "$($cfg.Hotkeys.Right)"; Auto = "$($cfg.Hotkeys.Auto)" } }
    } catch { }
}
function Save-Config {
    $activeAlias = if ($script:Active -eq 'Left') { $LeftAlias } else { $RightAlias }
    [PSCustomObject]@{ HighMetric = $HighMetric; LowMetric = $LowMetric
                       ActiveAlias = $activeAlias; Language = $script:Lang
                       Autostart = $script:Autostart; Logging = $script:Logging
                       LogPath = $script:LogPath; Hotkeys = $script:Hotkeys } |
        ConvertTo-Json | Set-Content -Path $ConfigPath -Encoding UTF8
}

function Write-AppLog([string]$msg) {
    # Пишет строку в журнал, если логирование включено
    if (-not $script:Logging) { return }
    try {
        $line = "$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))  $msg"
        Add-Content -Path $script:LogPath -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch { }
}

# ==================== АВТОЗАПУСК (Планировщик задач) ====================
$AutostartTaskName = 'LAN Switcher Autostart'

function Get-AutostartExists {
    # Задача автозапуска должна не просто существовать, а вести на актуальный файл
    # и актуального пользователя. Иначе (папку перенесли или ПК переименовали — в
    # планировщике остаётся запись со старыми путями) пересоздаём задачу заново.
    try {
        $task = Get-ScheduledTask -TaskName $AutostartTaskName -ErrorAction Stop
        if (-not $task) { return $false }
        $sl = Get-SelfLaunch
        $okPath = $false
        foreach ($a in $task.Actions) {
            $sameArgs = if ($sl.Args) { "$($a.Arguments)" -ieq $sl.Args }
                        else           { [string]::IsNullOrEmpty("$($a.Arguments)") }
            if ("$($a.Execute)" -ieq $sl.Path -and $sameArgs) { $okPath = $true; break }
        }
        $okUser = $false
        foreach ($t in $task.Triggers) {
            if ($t.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger') {
                $uid = "$($t.UserId)"
                if ($uid -ieq "$env:USERDOMAIN\$env:USERNAME" -or $uid -ieq $env:USERNAME) { $okUser = $true; break }
            }
        }
        if ($okPath -and $okUser) { return $true }
        # Задача есть, но устарела — перезаписываем актуальными данными
        Write-AppLog 'Задача автозапуска устарела (старый путь/пользователь) — обновляю'
        return Enable-Autostart
    }
    catch { return $false }
}

function Get-SelfLaunch {
    # Чем запускать виджет: скомпилированный exe (манифест админа встроен) или .ps1 через хост
    $exe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    if ([System.IO.Path]::GetFileName($exe).ToLower() -eq 'lan-switcher.exe') {
        return @{ Path = $exe; Args = '' }
    }
    $sp = $PSCommandPath
    return @{ Path = (Get-PSHost); Args = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$sp`"" }
}

function Enable-Autostart {
    try {
        $sl = Get-SelfLaunch
        $action = if ($sl.Args) { New-ScheduledTaskAction -Execute $sl.Path -Argument $sl.Args }
                  else          { New-ScheduledTaskAction -Execute $sl.Path }
        $trigger   = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
        $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
        $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero)
        Register-ScheduledTask -TaskName $AutostartTaskName -Action $action -Trigger $trigger `
            -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
        Write-AppLog 'Автозапуск включён'
        return $true
    } catch {
        [System.Windows.MessageBox]::Show((T 'err_generic') -f $_.Exception.Message, 'LAN Switcher', 'OK', 'Error') | Out-Null
        return $false
    }
}

function Disable-Autostart {
    try {
        Unregister-ScheduledTask -TaskName $AutostartTaskName -Confirm:$false -ErrorAction Stop
        Write-AppLog 'Автозапуск выключен'
        return $true
    } catch {
        [System.Windows.MessageBox]::Show((T 'err_generic') -f $_.Exception.Message, 'LAN Switcher', 'OK', 'Error') | Out-Null
        return $false
    }
}

# ==================== DNS на адаптер ====================
function Apply-Dns([string]$alias, [string]$pri, [string]$sec) {
    $servers = @()
    foreach ($v in @($pri, $sec)) {
        $v = "$v".Trim()
        if ($v) {
            $tmp = $null
            if (-not [System.Net.IPAddress]::TryParse($v, [ref]$tmp)) {
                [System.Windows.MessageBox]::Show((T 'dns_invalid'), 'LAN Switcher', 'OK', 'Warning') | Out-Null
                return $false
            }
            $servers += $v
        }
    }
    try {
        if ($servers.Count -eq 0) {
            Set-DnsClientServerAddress -InterfaceAlias $alias -ResetServerAddresses -ErrorAction Stop
            Write-AppLog "DNS $alias -> авто (DHCP)"
        } else {
            Set-DnsClientServerAddress -InterfaceAlias $alias -ServerAddresses $servers -ErrorAction Stop
            Write-AppLog "DNS $alias -> $($servers -join ', ')"
        }
        Clear-DnsClientCache -ErrorAction SilentlyContinue
        return $true
    } catch {
        [System.Windows.MessageBox]::Show((T 'err_generic') -f $_.Exception.Message, 'LAN Switcher', 'OK', 'Error') | Out-Null
        return $false
    }
}

function Reset-Dns([string]$alias) {
    try {
        Set-DnsClientServerAddress -InterfaceAlias $alias -ResetServerAddresses -ErrorAction Stop
        Clear-DnsClientCache -ErrorAction SilentlyContinue
        Write-AppLog "DNS $alias -> авто (DHCP)"
    } catch {
        [System.Windows.MessageBox]::Show((T 'err_generic') -f $_.Exception.Message, 'LAN Switcher', 'OK', 'Error') | Out-Null
    }
}

function Get-AdapterDns([string]$alias) {
    # Только СТАТИЧЕСКИ заданные DNS (пусто, если DHCP). Берём из реестра (NameServer),
    # т.к. Get-DnsClientServerAddress отдаёт и назначенные DHCP — а их показывать не нужно.
    try {
        $guid = (Get-NetAdapter -Name $alias -ErrorAction Stop).InterfaceGuid
        $key = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$guid"
        $ns = (Get-ItemProperty -Path $key -Name NameServer -ErrorAction SilentlyContinue).NameServer
        if ($ns) { return @($ns -split '[,\s]+' | Where-Object { $_ }) }
        return @()
    } catch { return @() }
}

# ==================== Горячие клавиши ====================
$script:HotkeyHwnd = [IntPtr]::Zero
$script:HotkeyIds  = @{ Toggle = 1; Left = 2; Right = 3; Auto = 4 }

function Parse-Hotkey([string]$combo) {
    # "Ctrl+Alt+L" -> @{ Mods; Vk } (Mods: Alt=1, Ctrl=2, Shift=4, Win=8)
    if (-not $combo) { return $null }
    $parts = $combo -split '\+'
    if ($parts.Count -lt 2) { return $null }
    $mods = 0
    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
        switch ($parts[$i].Trim().ToLower()) {
            'ctrl'  { $mods = $mods -bor 2 }
            'alt'   { $mods = $mods -bor 1 }
            'shift' { $mods = $mods -bor 4 }
            'win'   { $mods = $mods -bor 8 }
        }
    }
    try { $key = [System.Windows.Input.Key]($parts[-1].Trim()) } catch { return $null }
    $vk = [System.Windows.Input.KeyInterop]::VirtualKeyFromKey($key)
    if ($vk -eq 0) { return $null }
    return @{ Mods = [uint32]$mods; Vk = [uint32]$vk }
}

function Register-Hotkeys {
    if ($script:HotkeyHwnd -eq [IntPtr]::Zero) { return }
    foreach ($id in $script:HotkeyIds.Values) { [void][Native.HotKey]::UnregisterHotKey($script:HotkeyHwnd, $id) }
    foreach ($name in $script:HotkeyIds.Keys) {
        $combo = "$($script:Hotkeys[$name])"
        if ($combo) {
            $hk = Parse-Hotkey $combo
            if ($hk -and $hk.Mods -ne 0) {
                [void][Native.HotKey]::RegisterHotKey($script:HotkeyHwnd, $script:HotkeyIds[$name], $hk.Mods, $hk.Vk)
            }
        }
    }
}

function Unregister-Hotkeys {
    if ($script:HotkeyHwnd -eq [IntPtr]::Zero) { return }
    foreach ($id in $script:HotkeyIds.Values) { try { [void][Native.HotKey]::UnregisterHotKey($script:HotkeyHwnd, $id) } catch { } }
}

# Перехват WM_HOTKEY (0x0312) на окне. Храним обычным скриптблоком — к типу
# HwndSourceHook его приводит сам AddHook при вызове (иначе ps2exe не находит тип).
$script:HotkeyHook = {
    param($hwnd, $msg, $wParam, $lParam, $handled)
    if ($msg -eq 0x0312) {
        $id = [int]$wParam
        if     ($id -eq 1) { Set-ActiveSide $(if ($script:Active -eq 'Left') { 'Right' } else { 'Left' }); Write-AppLog 'Хоткей: переключение адаптера' }
        elseif ($id -eq 2) { Set-ActiveSide 'Left';  Write-AppLog 'Хоткей: левый адаптер' }
        elseif ($id -eq 3) { Set-ActiveSide 'Right'; Write-AppLog 'Хоткей: правый адаптер' }
        elseif ($id -eq 4) { Reset-AutoMetrics; Write-AppLog 'Хоткей: авто-режим' }
        try { $handled.Value = $true } catch { }
    }
    return [System.IntPtr]::Zero
}

# ==================== Профили ====================
function Get-Profiles {
    if (Test-Path $ProfilesPath) {
        try {
            $data = Get-Content -Raw -Encoding UTF8 $ProfilesPath | ConvertFrom-Json
            $data | Where-Object { $_ -and $_.Name }
        } catch { }
    }
}

function Save-Profiles {
    ConvertTo-Json -InputObject @($script:Profiles) -Depth 6 | Set-Content -Path $ProfilesPath -Encoding UTF8
}

function New-ProfileFromCurrent([string]$name) {
    # Снимок текущего состояния: приоритет+метрики, правила, DNS по адаптерам
    $activeAlias = if ($script:Active -eq 'Left') { $LeftAlias } else { $RightAlias }
    $dns = @{}
    foreach ($alias in @($LeftAlias, $RightAlias)) { $dns[$alias] = @(Get-AdapterDns $alias) }
    return [PSCustomObject]@{
        Name        = $name
        ActiveAlias = $activeAlias
        HighMetric  = $HighMetric
        LowMetric   = $LowMetric
        Rules       = @(Get-Rules)
        Dns         = $dns
    }
}

function Apply-Profile($p) {
    if ($p.HighMetric) { $script:HighMetric = [int]$p.HighMetric }
    if ($p.LowMetric)  { $script:LowMetric  = [int]$p.LowMetric }
    # Правила
    $script:Rules = @($p.Rules)
    Save-Rules
    # DNS по адаптерам
    if ($p.Dns) {
        foreach ($alias in @($LeftAlias, $RightAlias)) {
            if ($p.Dns.PSObject.Properties.Name -contains $alias) {
                $servers = @($p.Dns.$alias | Where-Object { $_ })
                if ($servers.Count -gt 0) { Set-DnsClientServerAddress -InterfaceAlias $alias -ServerAddresses $servers -ErrorAction SilentlyContinue }
                else { Set-DnsClientServerAddress -InterfaceAlias $alias -ResetServerAddresses -ErrorAction SilentlyContinue }
            }
        }
        Clear-DnsClientCache -ErrorAction SilentlyContinue
    }
    # Приоритет (применяет метрики + сохраняет конфиг)
    $side = if ($p.ActiveAlias -eq $LeftAlias) { 'Left' } elseif ($p.ActiveAlias -eq $RightAlias) { 'Right' } else { $script:Active }
    Set-ActiveSide $side
    Write-AppLog "Профиль применён: $($p.Name)"
}

function Refresh-ProfileSelector {
    if (-not $script:ProfSelTxt) { return }
    if ($script:Profiles.Count) { $script:ProfSelTxt.Text = $script:Profiles[$script:ProfileIdx].Name }
    else { $script:ProfSelTxt.Text = '—' }
}

function Flash-Button($border, $color = '#3AA55E') {
    # Кратко «нажать» кнопку: вспышка цветом + белый текст, затем возврат
    $txt = $border.Child
    $bc = [Windows.Media.BrushConverter]::new()
    $origBg = $border.Background
    $origFg = if ($txt) { $txt.Foreground } else { $null }
    $border.Background = $bc.ConvertFromString($color)
    if ($txt) { $txt.Foreground = $bc.ConvertFromString('#FFFFFFFF') }
    $t = [System.Windows.Threading.DispatcherTimer]::new()
    $t.Interval = [TimeSpan]::FromMilliseconds(450)
    $t.Add_Tick({
            $t.Stop()
            $border.Background = $origBg
            if ($txt) { $txt.Foreground = $origFg }
        }.GetNewClosure())
    $t.Start()
}

# ==================== ЯЗЫКОВОЙ ПАКЕТ ====================
# Порядок переключения языков (кнопка у заголовка листает по кругу).
$script:Langs = @('en', 'ru', 'es', 'de', 'fr', 'zh', 'ja', 'ko')

# Словарь переводов: ключ -> { код языка -> строка }. Отсутствующий язык
# для конкретного ключа автоматически откатывается на английский (en).
$script:Str = @{
    tip_rules  = @{ en = 'Bind apps to adapters'; ru = 'Привязка приложений к адаптерам'; es = 'Vincular apps a adaptadores'; de = 'Apps an Adapter binden'; fr = 'Associer des applis aux adaptateurs'; zh = '将应用绑定到网卡'; ja = 'アプリをアダプターに割り当て'; ko = '앱을 어댑터에 연결' }
    tip_lang   = @{ en = 'Change language'; ru = 'Сменить язык'; es = 'Cambiar idioma'; de = 'Sprache ändern'; fr = 'Changer de langue'; zh = '切换语言'; ja = '言語を切り替え'; ko = '언어 변경' }
    tip_min    = @{ en = 'Minimize to tray'; ru = 'Свернуть в трей'; es = 'Minimizar a la bandeja'; de = 'In den Infobereich minimieren'; fr = "Réduire dans la barre d'état"; zh = '最小化到托盘'; ja = 'トレイに最小化'; ko = '트레이로 최소화' }
    tip_close  = @{ en = 'Exit (stops proxies)'; ru = 'Выход (гасит прокси)'; es = 'Salir (detiene proxies)'; de = 'Beenden (stoppt Proxys)'; fr = 'Quitter (arrête les proxys)'; zh = '退出（停止代理）'; ja = '終了（プロキシを停止）'; ko = '종료 (프록시 중지)' }
    tip_gear   = @{ en = 'Settings'; ru = 'Настройки'; es = 'Ajustes'; de = 'Einstellungen'; fr = 'Paramètres'; zh = '设置'; ja = '設定'; ko = '설정' }
    tip_props  = @{ en = 'Open adapter properties'; ru = 'Открыть свойства адаптера'; es = 'Abrir propiedades del adaptador'; de = 'Adaptereigenschaften öffnen'; fr = "Ouvrir les propriétés de l'adaptateur"; zh = '打开网卡属性'; ja = 'アダプターのプロパティを開く'; ko = '어댑터 속성 열기' }
    btn_auto   = @{ en = 'Auto metrics'; ru = 'Авто-метрики'; es = 'Métricas auto'; de = 'Auto-Metrik'; fr = 'Métriques auto'; zh = '自动跃点'; ja = '自動メトリック'; ko = '자동 메트릭' }
    tip_auto   = @{ en = 'Restore automatic metrics for both adapters (Windows default)'; ru = 'Вернуть автоматические метрики обоим адаптерам (как по умолчанию в Windows)'; es = 'Restaurar métricas automáticas en ambos adaptadores'; de = 'Automatische Metrik für beide Adapter wiederherstellen'; fr = 'Rétablir les métriques automatiques sur les deux adaptateurs'; zh = '为两个网卡恢复自动跃点（Windows 默认）'; ja = '両アダプターの自動メトリックを復元（Windows 既定）'; ko = '두 어댑터의 자동 메트릭 복원 (Windows 기본값)' }
    btn_dns    = @{ en = 'Flush DNS'; ru = 'Сброс DNS'; es = 'Vaciar DNS'; de = 'DNS leeren'; fr = 'Vider DNS'; zh = '清空 DNS'; ja = 'DNS をクリア'; ko = 'DNS 비우기' }
    btn_reset  = @{ en = 'Network reset'; ru = 'Сброс сети'; es = 'Reiniciar red'; de = 'Netzwerk-Reset'; fr = 'Réinit. réseau'; zh = '网络重置'; ja = 'ネットワークリセット'; ko = '네트워크 초기화' }
    tip_reset  = @{ en = 'Full reset: flushdns + winsock reset + int ip reset (reboot required)'; ru = 'Полный сброс: flushdns + winsock reset + int ip reset (потребуется перезагрузка)'; es = 'Reinicio completo: flushdns + winsock reset + int ip reset (requiere reiniciar)'; de = 'Voll-Reset: flushdns + winsock reset + int ip reset (Neustart nötig)'; fr = 'Réinit. complète : flushdns + winsock reset + int ip reset (redémarrage requis)'; zh = '完全重置：flushdns + winsock reset + int ip reset（需重启）'; ja = '完全リセット：flushdns + winsock reset + int ip reset（再起動が必要）'; ko = '전체 초기화: flushdns + winsock reset + int ip reset (재부팅 필요)' }
    status_priority = @{ en = 'Priority: {0}  |  metrics {1} / {2}'; ru = 'Приоритет: {0}  |  метрики {1} / {2}'; es = 'Prioridad: {0}  |  métricas {1} / {2}'; de = 'Priorität: {0}  |  Metriken {1} / {2}'; fr = 'Priorité : {0}  |  métriques {1} / {2}'; zh = '优先: {0}  |  跃点 {1} / {2}'; ja = '優先: {0}  |  メトリック {1} / {2}'; ko = '우선: {0}  |  메트릭 {1} / {2}' }
    status_read_err = @{ en = 'Failed to read metrics'; ru = 'Не удалось прочитать метрики'; es = 'No se pudieron leer las métricas'; de = 'Metriken konnten nicht gelesen werden'; fr = 'Échec de lecture des métriques'; zh = '无法读取跃点'; ja = 'メトリックを読み取れません'; ko = '메트릭을 읽을 수 없음' }
    status_dns = @{ en = 'DNS cache cleared'; ru = 'DNS-кэш очищен'; es = 'Caché DNS vaciada'; de = 'DNS-Cache geleert'; fr = 'Cache DNS vidé'; zh = 'DNS 缓存已清空'; ja = 'DNS キャッシュをクリアしました'; ko = 'DNS 캐시를 비웠습니다' }
    status_netreset = @{ en = 'Network reset — reboot the PC'; ru = 'Сеть сброшена — перезагрузите ПК'; es = 'Red reiniciada — reinicie el PC'; de = 'Netzwerk zurückgesetzt — PC neu starten'; fr = 'Réseau réinitialisé — redémarrez le PC'; zh = '网络已重置 — 请重启电脑'; ja = 'ネットワークをリセット — PC を再起動してください'; ko = '네트워크 초기화됨 — PC를 재부팅하세요' }
    status_auto = @{ en = 'Auto'; ru = 'Авто'; es = 'Auto'; de = 'Auto'; fr = 'Auto'; zh = '自动'; ja = '自動'; ko = '자동' }
    tray_show = @{ en = 'Show'; ru = 'Показать'; es = 'Mostrar'; de = 'Anzeigen'; fr = 'Afficher'; zh = '显示'; ja = '表示'; ko = '표시' }
    tray_exit = @{ en = 'Exit'; ru = 'Выход'; es = 'Salir'; de = 'Beenden'; fr = 'Quitter'; zh = '退出'; ja = '終了'; ko = '종료' }
    tray_balloon = @{ en = 'Minimized to tray. Double-click the icon to restore.'; ru = 'Свёрнуто в трей. Двойной клик по значку — вернуть окно.'; es = 'Minimizado a la bandeja. Doble clic en el icono para restaurar.'; de = 'In den Infobereich minimiert. Doppelklick auf das Symbol zum Wiederherstellen.'; fr = "Réduit dans la barre. Double-cliquez sur l'icône pour restaurer."; zh = '已最小化到托盘。双击图标可恢复窗口。'; ja = 'トレイに最小化しました。アイコンをダブルクリックで復元。'; ko = '트레이로 최소화됨. 아이콘을 더블클릭하면 복원됩니다.' }
    rules_header = @{ en = 'APP BINDING'; ru = 'ПРИВЯЗКА ПРИЛОЖЕНИЙ'; es = 'VINCULAR APLICACIONES'; de = 'APP-BINDUNG'; fr = "ASSOCIATION D'APPLIS"; zh = '应用绑定'; ja = 'アプリの割り当て'; ko = '앱 연결' }
    rules_help = @{ en = 'The ▶ button launches the app strictly through the chosen adapter. Type “injection” — ForceBindIP (for most apps); “proxy” — a local proxy (reliable for Chromium browsers).'; ru = 'Кнопка ▶ запускает приложение строго через выбранный адаптер. Тип «инжекция» — ForceBindIP (для большинства программ), «прокси» — локальный прокси (надёжно для Chromium-браузеров).'; es = 'El botón ▶ inicia la app estrictamente por el adaptador elegido. Tipo “inyección” — ForceBindIP; “proxy” — proxy local (fiable para navegadores Chromium).'; de = 'Die ▶-Taste startet die App strikt über den gewählten Adapter. Typ „Injektion“ — ForceBindIP; „Proxy“ — lokaler Proxy (zuverlässig für Chromium-Browser).'; fr = "Le bouton ▶ lance l’appli strictement via l’adaptateur choisi. Type « injection » — ForceBindIP ; « proxy » — proxy local (fiable pour les navigateurs Chromium)."; zh = '▶ 按钮让应用严格通过所选网卡运行。类型「注入」— ForceBindIP（适用于多数程序）；「代理」— 本地代理（对 Chromium 浏览器可靠）。'; ja = '▶ ボタンはアプリを選択したアダプター経由でのみ起動します。種類「注入」— ForceBindIP（多くのアプリ向け）、「プロキシ」— ローカルプロキシ（Chromium ブラウザに最適）。'; ko = '▶ 버튼은 앱을 선택한 어댑터로만 실행합니다. 유형 「주입」— ForceBindIP(대부분 앱), 「프록시」— 로컬 프록시(Chromium 브라우저에 적합).' }
    rules_none = @{ en = 'No rules yet — add the first one'; ru = 'Правил пока нет — добавьте первое'; es = 'Aún no hay reglas — añade la primera'; de = 'Noch keine Regeln — füge die erste hinzu'; fr = 'Aucune règle — ajoutez la première'; zh = '暂无规则 — 请添加第一条'; ja = 'ルールがありません — 最初の 1 件を追加'; ko = '규칙이 없습니다 — 첫 규칙을 추가하세요' }
    rules_pick_exe = @{ en = 'choose an .exe file...'; ru = 'выберите exe-файл...'; es = 'elige un archivo .exe...'; de = 'Wähle eine .exe-Datei...'; fr = 'choisissez un fichier .exe...'; zh = '选择 .exe 文件...'; ja = '.exe ファイルを選択...'; ko = '.exe 파일 선택...' }
    rules_browse = @{ en = 'Browse'; ru = 'Обзор'; es = 'Examinar'; de = 'Durchsuchen'; fr = 'Parcourir'; zh = '浏览'; ja = '参照'; ko = '찾아보기' }
    rules_add = @{ en = 'Add'; ru = 'Добавить'; es = 'Añadir'; de = 'Hinzufügen'; fr = 'Ajouter'; zh = '添加'; ja = '追加'; ko = '추가' }
    type_fbip = @{ en = 'Type: injection (ForceBindIP)'; ru = 'Тип: инжекция (ForceBindIP)'; es = 'Tipo: inyección (ForceBindIP)'; de = 'Typ: Injektion (ForceBindIP)'; fr = 'Type : injection (ForceBindIP)'; zh = '类型：注入 (ForceBindIP)'; ja = '種類：注入 (ForceBindIP)'; ko = '유형: 주입 (ForceBindIP)' }
    type_proxy = @{ en = 'Type: proxy (HTTP/S, for browsers)'; ru = 'Тип: прокси (HTTP/S, для браузеров)'; es = 'Tipo: proxy (HTTP/S, para navegadores)'; de = 'Typ: Proxy (HTTP/S, für Browser)'; fr = 'Type : proxy (HTTP/S, pour navigateurs)'; zh = '类型：代理 (HTTP/S，用于浏览器)'; ja = '種類：プロキシ (HTTP/S、ブラウザ用)'; ko = '유형: 프록시 (HTTP/S, 브라우저용)' }
    tip_adapter = @{ en = 'Click to switch adapter'; ru = 'Клик — переключить адаптер'; es = 'Clic para cambiar de adaptador'; de = 'Klick — Adapter wechseln'; fr = "Clic — changer d'adaptateur"; zh = '点击切换网卡'; ja = 'クリックでアダプター切替'; ko = '클릭하여 어댑터 전환' }
    tip_type = @{ en = 'Click to change rule type'; ru = 'Клик — сменить тип правила'; es = 'Clic para cambiar el tipo de regla'; de = 'Klick — Regeltyp ändern'; fr = 'Clic — changer le type de règle'; zh = '点击切换规则类型'; ja = 'クリックで種類を変更'; ko = '클릭하여 규칙 유형 변경' }
    lbl_via = @{ en = 'via'; ru = 'через'; es = 'vía'; de = 'über'; fr = 'via'; zh = '经由'; ja = '経由'; ko = '경유' }
    lbl_inj = @{ en = 'injection'; ru = 'инжекция'; es = 'inyección'; de = 'Injektion'; fr = 'injection'; zh = '注入'; ja = '注入'; ko = '주입' }
    lbl_prx = @{ en = 'proxy'; ru = 'прокси'; es = 'proxy'; de = 'Proxy'; fr = 'proxy'; zh = '代理'; ja = 'プロキシ'; ko = '프록시' }
    tip_run = @{ en = 'Launch through {0}'; ru = 'Запустить через {0}'; es = 'Iniciar vía {0}'; de = 'Über {0} starten'; fr = 'Lancer via {0}'; zh = '通过 {0} 启动'; ja = '{0} 経由で起動'; ko = '{0}(으)로 실행' }
    tip_check = @{ en = 'Check which adapter the traffic really uses'; ru = 'Проверить, через какой адаптер реально идёт трафик'; es = 'Comprobar qué adaptador usa realmente el tráfico'; de = 'Prüfen, welchen Adapter der Verkehr wirklich nutzt'; fr = 'Vérifier quel adaptateur le trafic utilise réellement'; zh = '检查流量实际经过哪个网卡'; ja = 'トラフィックが実際に使うアダプターを確認'; ko = '트래픽이 실제 사용하는 어댑터 확인' }
    tip_shortcut = @{ en = 'Create a desktop shortcut'; ru = 'Создать ярлык на рабочем столе'; es = 'Crear acceso directo en el escritorio'; de = 'Desktop-Verknüpfung erstellen'; fr = 'Créer un raccourci sur le bureau'; zh = '在桌面创建快捷方式'; ja = 'デスクトップにショートカットを作成'; ko = '바탕화면에 바로가기 만들기' }
    tip_delete = @{ en = 'Delete rule'; ru = 'Удалить правило'; es = 'Eliminar regla'; de = 'Regel löschen'; fr = 'Supprimer la règle'; zh = '删除规则'; ja = 'ルールを削除'; ko = '규칙 삭제' }
    rule_dup = @{ en = 'This rule already exists — duplicate not added.'; ru = 'Такое правило уже есть — дубль не добавлен.'; es = 'Esta regla ya existe — no se añadió el duplicado.'; de = 'Diese Regel existiert bereits — Duplikat nicht hinzugefügt.'; fr = 'Cette règle existe déjà — doublon non ajouté.'; zh = '该规则已存在 — 未添加重复项。'; ja = 'このルールは既にあります — 重複は追加されません。'; ko = '이미 존재하는 규칙입니다 — 중복은 추가되지 않았습니다.' }
    rule_pick_first = @{ en = 'Choose an .exe first (Browse button).'; ru = 'Сначала выберите exe-файл (кнопка «Обзор»).'; es = 'Primero elige un .exe (botón Examinar).'; de = 'Wähle zuerst eine .exe (Schaltfläche Durchsuchen).'; fr = "Choisissez d'abord un .exe (bouton Parcourir)."; zh = '请先选择 .exe 文件（浏览按钮）。'; ja = '先に .exe を選択してください（参照ボタン）。'; ko = '먼저 .exe를 선택하세요 (찾아보기 버튼).' }
    set_header = @{ en = 'PRIORITY METRICS'; ru = 'МЕТРИКИ ПРИОРИТЕТА'; es = 'MÉTRICAS DE PRIORIDAD'; de = 'PRIORITÄTS-METRIKEN'; fr = 'MÉTRIQUES DE PRIORITÉ'; zh = '优先级跃点'; ja = '優先度メトリック'; ko = '우선순위 메트릭' }
    set_help = @{ en = 'Lower number = higher priority. The priority adapter is placed above VPN (tunnels are usually 5), so 1 breaks VPN — keep 10–30.'; ru = 'Меньше число = выше приоритет. Приоритетный ставится выше VPN (у туннелей обычно 5), поэтому 1 ломает VPN — держите 10–30.'; es = 'Menor número = mayor prioridad. El prioritario va por encima del VPN (túneles ~5), así que 1 rompe el VPN — usa 10–30.'; de = 'Kleinere Zahl = höhere Priorität. Der Prioritätsadapter steht über dem VPN (Tunnel meist 5), daher bricht 1 das VPN — nimm 10–30.'; fr = "Plus petit = plus prioritaire. L’adaptateur prioritaire passe au-dessus du VPN (tunnels ~5), donc 1 casse le VPN — restez entre 10 et 30."; zh = '数字越小优先级越高。优先网卡会排在 VPN 之上（隧道通常为 5），所以设为 1 会破坏 VPN — 请保持 10–30。'; ja = '数値が小さいほど優先度が高くなります。優先アダプターは VPN より上に置かれます（トンネルは通常 5）。そのため 1 は VPN を壊します — 10〜30 を推奨。'; ko = '숫자가 작을수록 우선순위가 높습니다. 우선 어댑터는 VPN보다 위에 놓입니다(터널은 보통 5). 따라서 1은 VPN을 망가뜨립니다 — 10–30 사이를 유지하세요.' }
    set_priority = @{ en = 'Priority:'; ru = 'Приоритетный:'; es = 'Prioritario:'; de = 'Priorität:'; fr = 'Prioritaire :'; zh = '优先:'; ja = '優先:'; ko = '우선:' }
    set_secondary = @{ en = 'Secondary:'; ru = 'Второстепенный:'; es = 'Secundario:'; de = 'Sekundär:'; fr = 'Secondaire :'; zh = '次要:'; ja = '副次:'; ko = '보조:' }
    set_save = @{ en = 'Save and apply'; ru = 'Сохранить и применить'; es = 'Guardar y aplicar'; de = 'Speichern und anwenden'; fr = 'Enregistrer et appliquer'; zh = '保存并应用'; ja = '保存して適用'; ko = '저장 후 적용' }
    set_int_err = @{ en = 'Enter whole numbers.'; ru = 'Введите целые числа.'; es = 'Introduce números enteros.'; de = 'Ganze Zahlen eingeben.'; fr = 'Entrez des nombres entiers.'; zh = '请输入整数。'; ja = '整数を入力してください。'; ko = '정수를 입력하세요.' }
    set_range_err = @{ en = 'Required: both numbers ≥ 1, and priority smaller than secondary.'; ru = 'Нужно: оба числа ≥ 1, и приоритетное меньше второстепенного.'; es = 'Se requiere: ambos ≥ 1 y el prioritario menor que el secundario.'; de = 'Erforderlich: beide ≥ 1 und Priorität kleiner als Sekundär.'; fr = 'Requis : les deux ≥ 1 et le prioritaire inférieur au secondaire.'; zh = '要求：两个数均 ≥ 1，且优先值小于次要值。'; ja = '条件：両方の数値が 1 以上で、優先値が副次値より小さいこと。'; ko = '조건: 두 숫자 모두 ≥ 1, 우선값이 보조값보다 작아야 합니다.' }
    set_title = @{ en = 'SETTINGS'; ru = 'НАСТРОЙКИ'; es = 'AJUSTES'; de = 'EINSTELLUNGEN'; fr = 'PARAMÈTRES'; zh = '设置'; ja = '設定'; ko = '설정' }
    set_sec_logs = @{ en = 'LOGS'; ru = 'ЖУРНАЛ'; es = 'REGISTRO'; de = 'PROTOKOLL'; fr = 'JOURNAL'; zh = '日志'; ja = 'ログ'; ko = '로그' }
    log_enable = @{ en = 'Keep a log'; ru = 'Вести журнал'; es = 'Mantener registro'; de = 'Protokoll führen'; fr = 'Tenir un journal'; zh = '记录日志'; ja = 'ログを記録する'; ko = '로그 기록' }
    log_folder = @{ en = 'Log folder:'; ru = 'Папка журнала:'; es = 'Carpeta del registro:'; de = 'Protokollordner:'; fr = 'Dossier du journal :'; zh = '日志文件夹：'; ja = 'ログフォルダー：'; ko = '로그 폴더:' }
    log_show = @{ en = 'Show in folder'; ru = 'Показать в папке'; es = 'Mostrar en la carpeta'; de = 'Im Ordner anzeigen'; fr = 'Afficher dans le dossier'; zh = '在文件夹中显示'; ja = 'フォルダーで表示'; ko = '폴더에서 보기' }
    set_sec_auto = @{ en = 'AUTOSTART'; ru = 'АВТОЗАПУСК'; es = 'INICIO AUTOMÁTICO'; de = 'AUTOSTART'; fr = 'DÉMARRAGE AUTO'; zh = '开机自启'; ja = '自動起動'; ko = '자동 시작' }
    autostart_enable = @{ en = 'Start with Windows'; ru = 'Запускать вместе с Windows'; es = 'Iniciar con Windows'; de = 'Mit Windows starten'; fr = 'Démarrer avec Windows'; zh = '随 Windows 启动'; ja = 'Windows と一緒に起動'; ko = 'Windows와 함께 시작' }
    autostart_note = @{ en = 'Starts elevated at logon via Task Scheduler — no UAC prompt.'; ru = 'Запускается при входе с правами админа через Планировщик — без запроса UAC.'; es = 'Se inicia con privilegios al iniciar sesión mediante el Programador — sin aviso de UAC.'; de = 'Startet beim Anmelden erhöht über die Aufgabenplanung — ohne UAC-Abfrage.'; fr = 'Démarre avec privilèges à la connexion via le Planificateur — sans invite UAC.'; zh = '通过任务计划程序在登录时以管理员权限启动 — 无 UAC 提示。'; ja = 'タスク スケジューラでログオン時に管理者権限で起動 — UAC の確認なし。'; ko = '작업 스케줄러로 로그온 시 관리자 권한으로 시작 — UAC 창 없음.' }
    dns_apply = @{ en = 'Apply'; ru = 'Применить'; es = 'Aplicar'; de = 'Übernehmen'; fr = 'Appliquer'; zh = '应用'; ja = '適用'; ko = '적용' }
    dns_auto = @{ en = 'Auto (DHCP)'; ru = 'Авто (DHCP)'; es = 'Auto (DHCP)'; de = 'Auto (DHCP)'; fr = 'Auto (DHCP)'; zh = '自动 (DHCP)'; ja = '自動 (DHCP)'; ko = '자동 (DHCP)' }
    dns_invalid = @{ en = 'Enter valid IP addresses (or leave empty for DHCP).'; ru = 'Введите корректные IP-адреса (или оставьте пустым для DHCP).'; es = 'Introduce direcciones IP válidas (o deja vacío para DHCP).'; de = 'Gültige IP-Adressen eingeben (oder für DHCP leer lassen).'; fr = 'Entrez des adresses IP valides (ou laissez vide pour DHCP).'; zh = '请输入有效的 IP 地址（留空则用 DHCP）。'; ja = '有効な IP アドレスを入力してください（空欄なら DHCP）。'; ko = '유효한 IP 주소를 입력하세요 (비우면 DHCP).' }
    set_sec_hotkeys = @{ en = 'HOTKEYS'; ru = 'ГОРЯЧИЕ КЛАВИШИ'; es = 'ATAJOS'; de = 'TASTENKÜRZEL'; fr = 'RACCOURCIS'; zh = '快捷键'; ja = 'ショートカット'; ko = '단축키' }
    hk_toggle = @{ en = 'Toggle'; ru = 'Переключить'; es = 'Alternar'; de = 'Umschalten'; fr = 'Basculer'; zh = '切换'; ja = '切替'; ko = '전환' }
    hk_left = @{ en = 'Left'; ru = 'Левый'; es = 'Izquierdo'; de = 'Links'; fr = 'Gauche'; zh = '左'; ja = '左'; ko = '왼쪽' }
    hk_right = @{ en = 'Right'; ru = 'Правый'; es = 'Derecho'; de = 'Rechts'; fr = 'Droite'; zh = '右'; ja = '右'; ko = '오른쪽' }
    hk_auto = @{ en = 'Auto'; ru = 'Авто'; es = 'Auto'; de = 'Auto'; fr = 'Auto'; zh = '自动'; ja = '自動'; ko = '자동' }
    hk_set = @{ en = 'Set'; ru = 'Задать'; es = 'Definir'; de = 'Setzen'; fr = 'Définir'; zh = '设置'; ja = '設定'; ko = '설정' }
    hk_hint = @{ en = 'Click Set, then press a combo with Ctrl/Alt/Shift. Esc — cancel.'; ru = 'Нажмите «Задать» и введите комбинацию с Ctrl/Alt/Shift. Esc — отмена.'; es = 'Pulsa Definir y presiona una combinación con Ctrl/Alt/Shift. Esc — cancelar.'; de = 'Setzen klicken und Kombination mit Strg/Alt/Umschalt drücken. Esc — Abbrechen.'; fr = 'Cliquez Définir puis appuyez une combinaison avec Ctrl/Alt/Maj. Échap — annuler.'; zh = '点击「设置」后按下含 Ctrl/Alt/Shift 的组合键。Esc 取消。'; ja = '「設定」を押し、Ctrl/Alt/Shift を含むキーを押します。Esc で取消。'; ko = '「설정」을 누른 뒤 Ctrl/Alt/Shift 조합을 누르세요. Esc — 취소.' }
    set_sec_profiles = @{ en = 'PROFILES'; ru = 'ПРОФИЛИ'; es = 'PERFILES'; de = 'PROFILE'; fr = 'PROFILS'; zh = '配置文件'; ja = 'プロファイル'; ko = '프로필' }
    prof_save = @{ en = 'Save'; ru = 'Сохранить'; es = 'Guardar'; de = 'Speichern'; fr = 'Enregistrer'; zh = '保存'; ja = '保存'; ko = '저장' }
    prof_pick = @{ en = 'Click to switch profile'; ru = 'Клик — выбрать профиль'; es = 'Clic para cambiar de perfil'; de = 'Klick — Profil wählen'; fr = 'Clic — choisir un profil'; zh = '点击切换配置'; ja = 'クリックでプロファイル切替'; ko = '클릭하여 프로필 전환' }
    prof_need_name = @{ en = 'Enter a profile name.'; ru = 'Введите имя профиля.'; es = 'Introduce un nombre de perfil.'; de = 'Profilnamen eingeben.'; fr = 'Entrez un nom de profil.'; zh = '请输入配置名称。'; ja = 'プロファイル名を入力してください。'; ko = '프로필 이름을 입력하세요.' }
    file_not_found = @{ en = "File not found:`n{0}"; ru = "Файл не найден:`n{0}"; es = "Archivo no encontrado:`n{0}"; de = "Datei nicht gefunden:`n{0}"; fr = "Fichier introuvable :`n{0}"; zh = "未找到文件：`n{0}"; ja = "ファイルが見つかりません:`n{0}"; ko = "파일을 찾을 수 없습니다:`n{0}" }
    fbip_not_found = @{ en = "ForceBindIP not found in:`n{0}"; ru = "ForceBindIP не найден в:`n{0}"; es = "ForceBindIP no encontrado en:`n{0}"; de = "ForceBindIP nicht gefunden in:`n{0}"; fr = "ForceBindIP introuvable dans :`n{0}"; zh = "在此处未找到 ForceBindIP：`n{0}"; ja = "ForceBindIP が見つかりません:`n{0}"; ko = "ForceBindIP를 찾을 수 없습니다:`n{0}" }
    adapter_no_ip = @{ en = 'Adapter “{0}” has no IP right now (not connected?).'; ru = 'У адаптера «{0}» сейчас нет IP (не подключён?).'; es = 'El adaptador «{0}» no tiene IP ahora (¿no conectado?).'; de = 'Adapter „{0}“ hat gerade keine IP (nicht verbunden?).'; fr = "L’adaptateur « {0} » n’a pas d’IP actuellement (non connecté ?)."; zh = '适配器「{0}」当前没有 IP（未连接？）。'; ja = 'アダプター「{0}」に現在 IP がありません（未接続？）。'; ko = '어댑터 「{0}」에 현재 IP가 없습니다 (연결 안 됨?).' }
    proxy_missing = @{ en = 'LAN-Switcher-Proxy.ps1 not found next to the app.'; ru = 'Не найден LAN-Switcher-Proxy.ps1 рядом со скриптом.'; es = 'LAN-Switcher-Proxy.ps1 no está junto a la app.'; de = 'LAN-Switcher-Proxy.ps1 nicht neben der App gefunden.'; fr = "LAN-Switcher-Proxy.ps1 introuvable à côté de l’app."; zh = '未在程序旁找到 LAN-Switcher-Proxy.ps1。'; ja = 'アプリの隣に LAN-Switcher-Proxy.ps1 が見つかりません。'; ko = '앱 옆에서 LAN-Switcher-Proxy.ps1을 찾을 수 없습니다.' }
    proxy_start_fail = @{ en = 'Proxy failed to start on port {0}.'; ru = 'Прокси не запустился на порту {0}.'; es = 'El proxy no pudo iniciarse en el puerto {0}.'; de = 'Proxy konnte auf Port {0} nicht starten.'; fr = "Le proxy n’a pas pu démarrer sur le port {0}."; zh = '代理无法在端口 {0} 上启动。'; ja = 'ポート {0} でプロキシを起動できませんでした。'; ko = '포트 {0}에서 프록시를 시작하지 못했습니다.' }
    proxy_nonchromium = @{ en = "Proxy is up on 127.0.0.1:{0} (via {1}).`n`n'{2}' is not a Chromium browser, auto-launch with proxy isn't possible.`nSet proxy 127.0.0.1:{0} in the app's settings manually."; ru = "Прокси поднят на 127.0.0.1:{0} (через {1}).`n`n«{2}» — не Chromium-браузер, автозапуск с прокси невозможен.`nПропишите прокси 127.0.0.1:{0} в настройках приложения вручную."; es = "El proxy está activo en 127.0.0.1:{0} (vía {1}).`n`n'{2}' no es un navegador Chromium; no es posible el autoarranque con proxy.`nConfigura el proxy 127.0.0.1:{0} manualmente en la app."; de = "Proxy läuft auf 127.0.0.1:{0} (über {1}).`n`n'{2}' ist kein Chromium-Browser, Autostart mit Proxy ist nicht möglich.`nProxy 127.0.0.1:{0} in den App-Einstellungen manuell setzen."; fr = "Le proxy est actif sur 127.0.0.1:{0} (via {1}).`n`n'{2}' n'est pas un navigateur Chromium, le lancement auto avec proxy est impossible.`nConfigurez le proxy 127.0.0.1:{0} manuellement dans l'app."; zh = "代理已在 127.0.0.1:{0} 上运行（经由 {1}）。`n`n'{2}' 不是 Chromium 浏览器，无法自动通过代理启动。`n请在应用设置中手动设置代理 127.0.0.1:{0}。"; ja = "プロキシは 127.0.0.1:{0} で稼働中（{1} 経由）。`n`n'{2}' は Chromium ブラウザではないため、プロキシでの自動起動はできません。`nアプリの設定で 127.0.0.1:{0} を手動で設定してください。"; ko = "프록시가 127.0.0.1:{0}에서 실행 중 ({1} 경유).`n`n'{2}'은(는) Chromium 브라우저가 아니어서 프록시 자동 실행이 불가능합니다.`n앱 설정에서 프록시 127.0.0.1:{0}을(를) 수동으로 설정하세요." }
    check_not_running = @{ en = '“{0}” is not running — nothing to check.'; ru = '«{0}» сейчас не запущен — проверять нечего.'; es = '«{0}» no está en ejecución — nada que comprobar.'; de = '„{0}“ läuft nicht — nichts zu prüfen.'; fr = "« {0} » n’est pas en cours — rien à vérifier."; zh = '「{0}」未在运行 — 无需检查。'; ja = '「{0}」は実行されていません — 確認するものがありません。'; ko = '「{0}」이(가) 실행 중이 아닙니다 — 확인할 것이 없습니다.' }
    check_no_conns = @{ en = '“{0}” is running but has no active external connections.'; ru = '«{0}» запущен, но активных внешних соединений нет.'; es = '«{0}» está en ejecución pero no tiene conexiones externas activas.'; de = '„{0}“ läuft, hat aber keine aktiven externen Verbindungen.'; fr = "« {0} » est en cours mais n’a aucune connexion externe active."; zh = '「{0}」正在运行，但没有活动的外部连接。'; ja = '「{0}」は実行中ですが、アクティブな外部接続がありません。'; ko = '「{0}」이(가) 실행 중이지만 활성 외부 연결이 없습니다.' }
    check_title = @{ en = 'LAN Switcher — check'; ru = 'LAN Switcher — проверка'; es = 'LAN Switcher — comprobación'; de = 'LAN Switcher — Prüfung'; fr = 'LAN Switcher — vérification'; zh = 'LAN Switcher — 检查'; ja = 'LAN Switcher — 確認'; ko = 'LAN Switcher — 확인' }
    check_report = @{ en = "{0} — connections: {1}`n`n{2}`n`nRule: via {3}`nHonored: {4}"; ru = "{0} — соединений: {1}`n`n{2}`n`nПравило: через {3}`nСоблюдается: {4}"; es = "{0} — conexiones: {1}`n`n{2}`n`nRegla: vía {3}`nCumplida: {4}"; de = "{0} — Verbindungen: {1}`n`n{2}`n`nRegel: über {3}`nEingehalten: {4}"; fr = "{0} — connexions : {1}`n`n{2}`n`nRègle : via {3}`nRespectée : {4}"; zh = "{0} — 连接数：{1}`n`n{2}`n`n规则：经由 {3}`n是否符合：{4}"; ja = "{0} — 接続数: {1}`n`n{2}`n`nルール: {3} 経由`n順守: {4}"; ko = "{0} — 연결: {1}`n`n{2}`n`n규칙: {3} 경유`n준수: {4}" }
    verdict_yes = @{ en = "YES — all traffic via the rule's adapter"; ru = 'ДА — весь трафик через адаптер правила'; es = 'SÍ — todo el tráfico por el adaptador de la regla'; de = 'JA — gesamter Verkehr über den Regel-Adapter'; fr = "OUI — tout le trafic via l’adaptateur de la règle"; zh = '是 — 所有流量都经过规则的网卡'; ja = 'はい — すべてのトラフィックがルールのアダプター経由'; ko = '예 — 모든 트래픽이 규칙 어댑터 경유' }
    verdict_partial = @{ en = 'PARTIAL — {0} of {1} connections'; ru = 'ЧАСТИЧНО — {0} из {1} соединений'; es = 'PARCIAL — {0} de {1} conexiones'; de = 'TEILWEISE — {0} von {1} Verbindungen'; fr = 'PARTIEL — {0} sur {1} connexions'; zh = '部分 — {1} 个连接中的 {0} 个'; ja = '一部 — {1} 件中 {0} 件'; ko = '부분 — {1}개 중 {0}개 연결' }
    verdict_no = @{ en = 'NO — traffic goes through another adapter!'; ru = 'НЕТ — трафик идёт через другой адаптер!'; es = 'NO — ¡el tráfico va por otro adaptador!'; de = 'NEIN — Verkehr läuft über einen anderen Adapter!'; fr = 'NON — le trafic passe par un autre adaptateur !'; zh = '否 — 流量走了另一个网卡！'; ja = 'いいえ — トラフィックが別のアダプターを通っています！'; ko = '아니요 — 트래픽이 다른 어댑터로 갑니다!' }
    conn_line = @{ en = '  {0} conn. — {1}  [{2}]'; ru = '  {0} соед. — {1}  [{2}]'; es = '  {0} conex. — {1}  [{2}]'; de = '  {0} Verb. — {1}  [{2}]'; fr = '  {0} conn. — {1}  [{2}]'; zh = '  {0} 连接 — {1}  [{2}]'; ja = '  {0} 接続 — {1}  [{2}]'; ko = '  {0} 연결 — {1}  [{2}]' }
    unknown_iface = @{ en = 'unknown interface'; ru = 'неизвестный интерфейс'; es = 'interfaz desconocida'; de = 'unbekannte Schnittstelle'; fr = 'interface inconnue'; zh = '未知接口'; ja = '不明なインターフェース'; ko = '알 수 없는 인터페이스' }
    shortcut_created = @{ en = "Shortcut created on the desktop:`n{0}"; ru = "Ярлык создан на рабочем столе:`n{0}"; es = "Acceso directo creado en el escritorio:`n{0}"; de = "Verknüpfung auf dem Desktop erstellt:`n{0}"; fr = "Raccourci créé sur le bureau :`n{0}"; zh = "已在桌面创建快捷方式：`n{0}"; ja = "デスクトップにショートカットを作成しました:`n{0}"; ko = "바탕화면에 바로가기를 만들었습니다:`n{0}" }
    shortcut_fail = @{ en = "Failed to create shortcut:`n{0}"; ru = "Не удалось создать ярлык:`n{0}"; es = "No se pudo crear el acceso directo:`n{0}"; de = "Verknüpfung konnte nicht erstellt werden:`n{0}"; fr = "Impossible de créer le raccourci :`n{0}"; zh = "无法创建快捷方式：`n{0}"; ja = "ショートカットを作成できませんでした:`n{0}"; ko = "바로가기를 만들지 못했습니다:`n{0}" }
    shortcut_nonchromium = @{ en = 'The proxy shortcut is for Chromium browsers. “{0}” is not one.'; ru = 'Прокси-ярлык рассчитан на Chromium-браузеры. «{0}» им не является.'; es = 'El acceso directo proxy es para navegadores Chromium. «{0}» no lo es.'; de = 'Die Proxy-Verknüpfung ist für Chromium-Browser. „{0}“ ist keiner.'; fr = "Le raccourci proxy est pour les navigateurs Chromium. « {0} » n’en est pas un."; zh = '代理快捷方式仅适用于 Chromium 浏览器。「{0}」不是。'; ja = 'プロキシのショートカットは Chromium ブラウザ用です。「{0}」は該当しません。'; ko = '프록시 바로가기는 Chromium 브라우저용입니다. 「{0}」은(는) 아닙니다.' }
    err_generic = @{ en = "Error: {0}"; ru = "Ошибка: {0}"; es = "Error: {0}"; de = "Fehler: {0}"; fr = "Erreur : {0}"; zh = "错误：{0}"; ja = "エラー: {0}"; ko = "오류: {0}" }
    net_confirm = @{ en = "A full network reset will run:`n`n  ipconfig /flushdns`n  netsh winsock reset`n  netsh int ip reset`n`nWARNING: metrics and static IP settings will be reset, and a REBOOT will be required.`n`nContinue?"; ru = "Полный сброс сети выполнит:`n`n  ipconfig /flushdns`n  netsh winsock reset`n  netsh int ip reset`n`nВНИМАНИЕ: сбросятся метрики и статические IP-настройки, после сброса потребуется ПЕРЕЗАГРУЗКА.`n`nПродолжить?"; es = "Un reinicio completo de red ejecutará:`n`n  ipconfig /flushdns`n  netsh winsock reset`n  netsh int ip reset`n`nADVERTENCIA: se restablecerán las métricas y la IP estática, y hará falta REINICIAR.`n`n¿Continuar?"; de = "Ein vollständiger Netzwerk-Reset führt aus:`n`n  ipconfig /flushdns`n  netsh winsock reset`n  netsh int ip reset`n`nWARNUNG: Metriken und statische IP-Einstellungen werden zurückgesetzt, ein NEUSTART ist nötig.`n`nFortfahren?"; fr = "Une réinitialisation réseau complète exécutera :`n`n  ipconfig /flushdns`n  netsh winsock reset`n  netsh int ip reset`n`nATTENTION : les métriques et l'IP statique seront réinitialisées, un REDÉMARRAGE sera nécessaire.`n`nContinuer ?"; zh = "完整网络重置将执行：`n`n  ipconfig /flushdns`n  netsh winsock reset`n  netsh int ip reset`n`n警告：跃点和静态 IP 设置将被重置，并需要重启。`n`n是否继续？"; ja = "ネットワークの完全リセットを実行します:`n`n  ipconfig /flushdns`n  netsh winsock reset`n  netsh int ip reset`n`n警告: メトリックと静的 IP 設定がリセットされ、再起動が必要です。`n`n続行しますか？"; ko = "전체 네트워크 초기화를 실행합니다:`n`n  ipconfig /flushdns`n  netsh winsock reset`n  netsh int ip reset`n`n경고: 메트릭과 고정 IP 설정이 초기화되고 재부팅이 필요합니다.`n`n계속할까요?" }
    net_title = @{ en = 'LAN Switcher — network reset'; ru = 'LAN Switcher — сброс сети'; es = 'LAN Switcher — reinicio de red'; de = 'LAN Switcher — Netzwerk-Reset'; fr = 'LAN Switcher — réinitialisation réseau'; zh = 'LAN Switcher — 网络重置'; ja = 'LAN Switcher — ネットワークリセット'; ko = 'LAN Switcher — 네트워크 초기화' }
    net_done = @{ en = "Done. Changes apply after reboot.`n`nReboot the computer now?"; ru = "Готово. Изменения применятся после перезагрузки.`n`nПерезагрузить компьютер сейчас?"; es = "Listo. Los cambios se aplican tras reiniciar.`n`n¿Reiniciar el equipo ahora?"; de = "Fertig. Änderungen gelten nach dem Neustart.`n`nComputer jetzt neu starten?"; fr = "Terminé. Les changements s'appliquent après redémarrage.`n`nRedémarrer l'ordinateur maintenant ?"; zh = "完成。更改将在重启后生效。`n`n现在重启电脑吗？"; ja = "完了しました。変更は再起動後に有効になります。`n`n今すぐ PC を再起動しますか？"; ko = "완료. 변경 사항은 재부팅 후 적용됩니다.`n`n지금 컴퓨터를 재부팅할까요?" }
    net_reset_ok = @{ en = 'Reset'; ru = 'Сброс'; es = 'Reiniciar'; de = 'Zurücksetzen'; fr = 'Réinitialiser'; zh = '重置'; ja = 'リセット'; ko = '초기화' }
    net_reset_cancel = @{ en = 'Cancel'; ru = 'Отмена'; es = 'Cancelar'; de = 'Abbrechen'; fr = 'Annuler'; zh = '取消'; ja = 'キャンセル'; ko = '취소' }
    need_two = @{ en = "The switch needs at least two physical adapters, found: {0}.`n`nAdapters on this PC:`n{1}"; ru = "Для переключателя нужно минимум два физических адаптера, найдено: {0}.`n`nАдаптеры этого ПК:`n{1}"; es = "El conmutador necesita al menos dos adaptadores físicos, encontrados: {0}.`n`nAdaptadores en este PC:`n{1}"; de = "Der Umschalter braucht mindestens zwei physische Adapter, gefunden: {0}.`n`nAdapter auf diesem PC:`n{1}"; fr = "Le commutateur nécessite au moins deux adaptateurs physiques, trouvés : {0}.`n`nAdaptateurs sur ce PC :`n{1}"; zh = "切换器至少需要两个物理网卡，找到：{0}。`n`n本机网卡：`n{1}"; ja = "切替には物理アダプターが 2 つ以上必要です。検出: {0}。`n`nこの PC のアダプター:`n{1}"; ko = "전환기는 물리 어댑터가 최소 두 개 필요합니다. 발견: {0}.`n`n이 PC의 어댑터:`n{1}" }
}

function T([string]$key) {
    $entry = $script:Str[$key]
    if (-not $entry) { return $key }
    if ($entry.ContainsKey($script:Lang)) { return $entry[$script:Lang] }
    return $entry['en']
}

# ==================== ТЕМА (следует за темой Windows) ====================
# Читаем системную настройку: 0 = тёмная тема приложений, 1 = светлая.
$script:ThemeLight = $false
try {
    $v = Get-ItemProperty -Path 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' `
                          -Name AppsUseLightTheme -ErrorAction Stop
    $script:ThemeLight = ($v.AppsUseLightTheme -eq 1)
} catch { }

# Карта «тёмный цвет -> светлый». В тёмной теме не применяется (виджет как был).
$script:ColorMap = @{
    '#EEFFFFFF' = '#F21A1A1F'; '#CCFFFFFF' = '#E61E1E22'; '#99FFFFFF' = '#D2000000'
    '#88FFFFFF' = '#C8000000'; '#77FFFFFF' = '#B4000000'; '#66FFFFFF' = '#A6000000'
    '#55FFFFFF' = '#8C000000'; '#44FFFFFF' = '#78000000'; '#33FFFFFF' = '#40000000'; '#22FFFFFF' = '#28000000'
    '#EE1F1F23' = '#F7F4F4F7'; '#2A2A30' = '#FFE7E7EC'; '#3A3A40' = '#FFCFCFD6'; '#2E2E34' = '#FFE2E2E8'
    '#234254' = '#FFD3E6F6'; '#233F4F' = '#FFD3E6F6'; '#2E4D33' = '#FFD3EDD7'; '#3A3320' = '#FFF1E6C4'
    '#3D2A2A' = '#FFF3D9D9'; '#4D2E2E' = '#FFF0D0D0'
    '#4CC2FF' = '#0C74C0'; '#884CC2FF' = '#880C74C0'; '#7DDB8A' = '#2E7D3A'; '#E8C878' = '#8A6D12'
    '#FF9E9E' = '#C0392B'; '#E08585' = '#C0392B'
}

function Fill-Theme([string]$xaml) {
    # Подменяет цвета в XAML на светлые, если включена светлая тема Windows
    if (-not $script:ThemeLight) { return $xaml }
    foreach ($k in $script:ColorMap.Keys) { $xaml = $xaml.Replace($k, $script:ColorMap[$k]) }
    return $xaml
}
function C([string]$hex) {
    # Themed-цвет для кода (кисти в скрипте)
    if ($script:ThemeLight -and $script:ColorMap.ContainsKey($hex)) { return $script:ColorMap[$hex] }
    return $hex
}

# --- Автоподнятие прав администратора ---
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    # Перезапускаемся с правами админа ТЕМ ЖЕ движком (pwsh 7 или powershell 5.1)
    $engine = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    Start-Process $engine -Verb RunAs -ArgumentList @(
        '-NoProfile','-ExecutionPolicy','Bypass','-STA','-WindowStyle','Hidden','-File',"`"$PSCommandPath`"")
    exit
}

# --- Автозапуск: если задача в планировщике устарела (перенесли папку с программой
#     или переименовали ПК) — чиним её прямо при старте, не дожидаясь открытия настроек
$null = Get-AutostartExists

# --- Спрятать консольное окно ---
Add-Type -Namespace Native -Name Win -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")]  public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@
[void][Native.Win]::ShowWindow([Native.Win]::GetConsoleWindow(), 0)

# --- Глобальные горячие клавиши (user32) ---
Add-Type -Namespace Native -Name HotKey -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
[DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
'@

# --- Поиск/поднятие окна «Свойства адаптера» (user32) ---
Add-Type -Namespace Native -Name Props -MemberDefinition @'
public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lp);
[DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
'@

# --- Зона растягивания окна настроек за края (user32 + WPF) ---
# Прозрачное окно без рамки не умеет ресайзиться само: перехватываем WM_NCHITTEST
# в C# (PS-scriptblock тут не годится — теряется возврат IntPtr) и говорим системе,
# что края окна — это рамка: за них можно хвататься курсором и тянуть.
Add-Type -TypeDefinition @'
using System;
using System.Windows;
using System.Windows.Interop;

namespace Native
{
    public static class Resize
    {
        static Window _win;
        public static void Attach(Window win)
        {
            _win = win;
            win.SourceInitialized += (s, e) =>
            {
                var h = new WindowInteropHelper(win).Handle;
                HwndSource.FromHwnd(h).AddHook(WndProcHook);
            };
        }
        static IntPtr WndProcHook(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
        {
            if (msg != 0x0084) return IntPtr.Zero;   // не WM_NCHITTEST
            long v = lParam.ToInt64();
            int x = (int)(v & 0xFFFF); if (x > 32767) x -= 65536;
            int y = (int)((v >> 16) & 0xFFFF); if (y > 32767) y -= 65536;
            var p = _win.PointFromScreen(new Point(x, y));
            double b = 8.0;   // толщина зоны захвата, px
            bool L = p.X <= b, R = p.X >= _win.ActualWidth - b;
            bool T = p.Y <= b, B = p.Y >= _win.ActualHeight - b;
            IntPtr hit = IntPtr.Zero;
            if (T && L) hit = (IntPtr)13;        // HTTOPLEFT
            else if (T && R) hit = (IntPtr)14;   // HTTOPRIGHT
            else if (B && L) hit = (IntPtr)16;   // HTBOTTOMLEFT
            else if (B && R) hit = (IntPtr)17;   // HTBOTTOMRIGHT
            else if (T) hit = (IntPtr)12;        // HTTOP
            else if (B) hit = (IntPtr)15;        // HTBOTTOM
            else if (L) hit = (IntPtr)10;        // HTLEFT
            else if (R) hit = (IntPtr)11;        // HTRIGHT
            if (hit != IntPtr.Zero) handled = true;
            return hit;
        }
    }
}
'@ -ReferencedAssemblies @('PresentationFramework', 'PresentationCore', 'WindowsBase', 'System.Xaml')

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# --- Автоопределение адаптеров ---
# Имена из НАСТРОЕК — лишь предпочтения. Если на этом ПК таких адаптеров нет,
# скрипт сам находит два физических адаптера и перезаписывает переменные.

function Get-ShortLabel([string]$desc, [string]$mediaType = '') {
    # "Realtek PCIe 2.5GbE Family Controller" -> "Realtek 2.5GbE"
    # "Intel(R) I211 Gigabit Network Connection" -> "Intel 1G"
    # "Intel(R) Wi-Fi 6 AX200 160MHz"           -> "Intel Wi-Fi"
    $vendor = (($desc -split '\s+')[0] -replace '\(R\)', '' -replace ',', '').Trim()
    # Беспроводной адаптер: определяем по типу среды или по описанию.
    $isWifi = ($mediaType -match '802\.11|Wireless') -or
              ($desc -match 'Wi-?Fi|Wireless|802\.11|\bAX\d|\bAC\b')
    if ($isWifi) {
        $label = ("$vendor Wi-Fi").Trim()
        if (-not $vendor) { $label = 'Wi-Fi' }
        return $label
    }
    $speed = if ($desc -match '(\d+(\.\d+)?\s*Gb(E|ps)?)') { $matches[1] -replace '\s','' }
             elseif ($desc -match 'Gigabit') { '1G' }
             elseif ($desc -match '(\d+)\s*Mb') { "$($matches[1])M" }
             else { '' }
    $label = ("$vendor $speed").Trim()
    if (-not $label) { $label = $desc.Substring(0, [Math]::Min(18, $desc.Length)) }
    return $label
}

$physAll = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)
# Целевые адаптеры: проводные (802.3) и беспроводные (802.11 / Wireless).
# Отсекаем Bluetooth PAN, модемы и прочую «физику», непригодную для переключения.
$cand = @($physAll | Where-Object {
    $_.PhysicalMediaType -match '802\.3|802\.11|Wireless' -or
    $_.InterfaceDescription -match 'Wi-?Fi|Wireless|Ethernet'
})
if ($cand.Count -lt 2) { $cand = $physAll }   # страховка, если фильтр отсёк лишнее
# Приоритет выбора: подключённые (Up) → Ethernet выше Wi-Fi (тай-брейкер) → имя.
# Тип адаптера не важен: два Ethernet, Ethernet+Wi-Fi или два Wi-Fi — все подходят.
$pool = @($cand | Sort-Object `
    @{ Expression = { $_.Status -ne 'Up' } }, `
    @{ Expression = { $_.PhysicalMediaType -notmatch '802\.3' } }, `
    Name)

$leftOk  = [bool]($physAll | Where-Object { $_.Name -eq $LeftAlias })
$rightOk = [bool]($physAll | Where-Object { $_.Name -eq $RightAlias })

if (-not ($leftOk -and $rightOk)) {
    if ($pool.Count -lt 2) {
        $list = ($physAll | ForEach-Object { "$($_.Name) - $($_.InterfaceDescription)" }) -join "`n"
        [System.Windows.MessageBox]::Show(
            "Для переключателя нужно минимум два физических адаптера, найдено: $($pool.Count).`n`nАдаптеры этого ПК:`n$list",
            'LAN Switcher', 'OK', 'Error') | Out-Null
        exit 1
    }
    if ($leftOk) {
        # левый совпал — правым назначаем другой реальный адаптер
        $other = $pool | Where-Object { $_.Name -ne $LeftAlias } | Select-Object -First 1
        $RightAlias = $other.Name
        $RightLabel = Get-ShortLabel $other.InterfaceDescription $other.PhysicalMediaType
    } elseif ($rightOk) {
        $other = $pool | Where-Object { $_.Name -ne $RightAlias } | Select-Object -First 1
        $LeftAlias = $other.Name
        $LeftLabel = Get-ShortLabel $other.InterfaceDescription $other.PhysicalMediaType
    } else {
        # оба не совпали — берём два лучших кандидата целиком
        $LeftAlias  = $pool[0].Name
        $LeftLabel  = Get-ShortLabel $pool[0].InterfaceDescription $pool[0].PhysicalMediaType
        $RightAlias = $pool[1].Name
        $RightLabel = Get-ShortLabel $pool[1].InterfaceDescription $pool[1].PhysicalMediaType
    }
}

# --- Автопоиск ForceBindIP, если в настройках путь неверен ---
if (-not (Test-Path (Join-Path $ForceBindIPDir 'ForceBindIP.exe'))) {
    foreach ($d in @("$env:ProgramFiles\ForceBindIP", "${env:ProgramFiles(x86)}\ForceBindIP",
                     "$env:LOCALAPPDATA\ForceBindIP", 'C:\Tools\ForceBindIP')) {
        if (Test-Path "$d\ForceBindIP.exe") { $ForceBindIPDir = $d; break }
    }
}

# --- Интерфейс (WPF/XAML) ---
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="LAN Switcher" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" Topmost="True" ResizeMode="NoResize"
        SizeToContent="WidthAndHeight" ShowInTaskbar="False"
        WindowStartupLocation="Manual" FontFamily="Segoe UI">
  <Border CornerRadius="14" Background="#EE1F1F23" BorderBrush="#33FFFFFF"
          BorderThickness="1" Padding="24,18,24,20">
    <StackPanel>
      <Grid>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <TextBlock Text="LAN SWITCHER" Foreground="#55FFFFFF" FontSize="10"
                     FontWeight="Bold" VerticalAlignment="Center"/>
          <Border x:Name="LangBtn" Background="#2A2A30" CornerRadius="5" Padding="5,1"
                  Margin="8,0,0,0" Cursor="Hand" VerticalAlignment="Center">
            <TextBlock x:Name="LangTxt" Text="EN" Foreground="#88FFFFFF" FontSize="9" FontWeight="Bold"/>
          </Border>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
          <TextBlock x:Name="MenuBtn" Text="☰" Foreground="#77FFFFFF" FontSize="13"
                     Cursor="Hand" Padding="8,0,10,4"
                     ToolTip="Привязка приложений к адаптерам"/>
          <TextBlock x:Name="MinBtn" Text="—" Foreground="#77FFFFFF" FontSize="12"
                     Cursor="Hand" Padding="0,0,10,4" ToolTip="Свернуть в трей"/>
          <TextBlock x:Name="CloseBtn" Text="X" Foreground="#77FFFFFF" FontSize="12"
                     Cursor="Hand" Padding="0,0,0,4" ToolTip="Выход (гасит прокси)"/>
        </StackPanel>
      </Grid>
      <Grid Margin="0,18,0,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <StackPanel x:Name="LeftPanel" Grid.Column="0" VerticalAlignment="Center"
                    Cursor="Hand" Margin="0,0,14,0">
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
            <TextBlock x:Name="LeftLabelTB" Text="LEFT" FontSize="17" FontWeight="SemiBold"
                       VerticalAlignment="Center"/>
            <TextBlock x:Name="LeftPropsBtn" Text="⚙" FontSize="10" Foreground="#66FFFFFF"
                       Cursor="Hand" Margin="6,0,0,0" VerticalAlignment="Center"/>
          </StackPanel>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,4,0,0">
            <Grid Width="14" Height="14" Margin="0,0,5,0" VerticalAlignment="Center">
              <Ellipse x:Name="LeftDot" Fill="#66808080"/>
              <Path x:Name="LeftGlyph" Stroke="#EEFFFFFF" StrokeThickness="1.6"
                    StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                    Data="M 3.5,7.5 L 6,10 L 10.5,4.5" Visibility="Collapsed"/>
            </Grid>
            <TextBlock x:Name="LeftIpTB" Text="—" FontSize="13"
                       Foreground="#99FFFFFF" VerticalAlignment="Center"/>
          </StackPanel>
          <TextBlock HorizontalAlignment="Center" Margin="0,4,0,0" FontSize="10">
            <Run x:Name="LeftLatRun" Text="" FontSize="11" Foreground="#88FFFFFF"/>
            <Run Text="  "/>
            <Run x:Name="LeftDnArrow" Text="" FontSize="15" FontWeight="Bold" Foreground="#4FB477"/>
            <Run x:Name="LeftDnRun" Text="" Foreground="#99FFFFFF"/>
            <Run Text="  "/>
            <Run x:Name="LeftUpArrow" Text="" FontSize="15" FontWeight="Bold" Foreground="#D98A3D"/>
            <Run x:Name="LeftUpRun" Text="" Foreground="#99FFFFFF"/>
          </TextBlock>
        </StackPanel>
        <Border x:Name="Track" Grid.Column="1" Width="96" Height="34" CornerRadius="17"
                Background="#3A3A40" Cursor="Hand" VerticalAlignment="Center">
          <Border x:Name="Thumb" Width="44" Height="26" CornerRadius="13"
                  Background="#4CC2FF" HorizontalAlignment="Left" Margin="4,0,0,0">
            <Border.RenderTransform><TranslateTransform/></Border.RenderTransform>
          </Border>
        </Border>
        <StackPanel x:Name="RightPanel" Grid.Column="2" VerticalAlignment="Center"
                    Cursor="Hand" Margin="14,0,0,0">
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
            <TextBlock x:Name="RightLabelTB" Text="RIGHT" FontSize="17" FontWeight="SemiBold"
                       VerticalAlignment="Center"/>
            <TextBlock x:Name="RightPropsBtn" Text="⚙" FontSize="10" Foreground="#66FFFFFF"
                       Cursor="Hand" Margin="6,0,0,0" VerticalAlignment="Center"/>
          </StackPanel>
          <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,4,0,0">
            <Grid Width="14" Height="14" Margin="0,0,5,0" VerticalAlignment="Center">
              <Ellipse x:Name="RightDot" Fill="#66808080"/>
              <Path x:Name="RightGlyph" Stroke="#EEFFFFFF" StrokeThickness="1.6"
                    StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                    Data="M 3.5,7.5 L 6,10 L 10.5,4.5" Visibility="Collapsed"/>
            </Grid>
            <TextBlock x:Name="RightIpTB" Text="—" FontSize="13"
                       Foreground="#99FFFFFF" VerticalAlignment="Center"/>
          </StackPanel>
          <TextBlock HorizontalAlignment="Center" Margin="0,4,0,0" FontSize="10">
            <Run x:Name="RightLatRun" Text="" FontSize="11" Foreground="#88FFFFFF"/>
            <Run Text="  "/>
            <Run x:Name="RightDnArrow" Text="" FontSize="15" FontWeight="Bold" Foreground="#4FB477"/>
            <Run x:Name="RightDnRun" Text="" Foreground="#99FFFFFF"/>
            <Run Text="  "/>
            <Run x:Name="RightUpArrow" Text="" FontSize="15" FontWeight="Bold" Foreground="#D98A3D"/>
            <Run x:Name="RightUpRun" Text="" Foreground="#99FFFFFF"/>
          </TextBlock>
        </StackPanel>
      </Grid>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,16,0,0">
        <TextBlock x:Name="StatusTB" Text="" Foreground="#88FFFFFF" FontSize="12"
                   VerticalAlignment="Center"/>
        <TextBlock x:Name="GearBtn" Text="⚙" Foreground="#66FFFFFF" FontSize="12"
                   Cursor="Hand" Margin="7,0,0,0" VerticalAlignment="Center"
                   ToolTip="Изменить числа метрик приоритета"/>
      </StackPanel>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,16,0,0">
        <Border x:Name="BtnAuto" Background="#2E2E34" CornerRadius="8" Padding="16,8"
                Cursor="Hand" Margin="0,0,12,0">
          <TextBlock x:Name="BtnAutoTxt" Text="Auto metrics" Foreground="#CCFFFFFF" FontSize="12"/>
        </Border>
        <Border x:Name="BtnDns" Background="#2E2E34" CornerRadius="8" Padding="16,8"
                Cursor="Hand" Margin="0,0,12,0" ToolTip="ipconfig /flushdns">
          <TextBlock x:Name="BtnDnsTxt" Text="Flush DNS" Foreground="#CCFFFFFF" FontSize="12"/>
        </Border>
        <Border x:Name="BtnReset" Background="#3D2A2A" CornerRadius="8" Padding="16,8"
                Cursor="Hand">
          <TextBlock x:Name="BtnResetTxt" Text="Network reset" Foreground="#FF9E9E" FontSize="12"/>
        </Border>
      </StackPanel>
    </StackPanel>
  </Border>
</Window>
'@

$window       = [Windows.Markup.XamlReader]::Parse((Fill-Theme $xaml))
$Track        = $window.FindName('Track')
$Thumb        = $window.FindName('Thumb')
$LeftLabelTB  = $window.FindName('LeftLabelTB')
$RightLabelTB = $window.FindName('RightLabelTB')
$LeftPropsBtn  = $window.FindName('LeftPropsBtn')
$RightPropsBtn = $window.FindName('RightPropsBtn')
$StatusTB     = $window.FindName('StatusTB')
$CloseBtn     = $window.FindName('CloseBtn')
$MenuBtn      = $window.FindName('MenuBtn')
$MinBtn       = $window.FindName('MinBtn')
$GearBtn      = $window.FindName('GearBtn')
$LangBtn      = $window.FindName('LangBtn')
$LangTxt      = $window.FindName('LangTxt')
$BtnAutoTxt   = $window.FindName('BtnAutoTxt')
$BtnDnsTxt    = $window.FindName('BtnDnsTxt')
$BtnResetTxt  = $window.FindName('BtnResetTxt')
$BtnAuto      = $window.FindName('BtnAuto')
$BtnDns       = $window.FindName('BtnDns')
$BtnReset     = $window.FindName('BtnReset')
$LeftPanel    = $window.FindName('LeftPanel')
$RightPanel   = $window.FindName('RightPanel')
$LeftDot      = $window.FindName('LeftDot')
$LeftGlyph    = $window.FindName('LeftGlyph')
$LeftIpTB     = $window.FindName('LeftIpTB')
$RightDot     = $window.FindName('RightDot')
$RightGlyph   = $window.FindName('RightGlyph')
$RightIpTB    = $window.FindName('RightIpTB')
$script:LeftBundle = @{
    Dot = $LeftDot; Glyph = $LeftGlyph; Ip = $LeftIpTB
    Lat = $window.FindName('LeftLatRun'); DnA = $window.FindName('LeftDnArrow'); Dn = $window.FindName('LeftDnRun')
    UpA = $window.FindName('LeftUpArrow'); Up = $window.FindName('LeftUpRun')
}
$script:RightBundle = @{
    Dot = $RightDot; Glyph = $RightGlyph; Ip = $RightIpTB
    Lat = $window.FindName('RightLatRun'); DnA = $window.FindName('RightDnArrow'); Dn = $window.FindName('RightDnRun')
    UpA = $window.FindName('RightUpArrow'); Up = $window.FindName('RightUpRun')
}

$LeftLabelTB.Text  = $LeftLabel
$RightLabelTB.Text = $RightLabel

$ThumbRightX = 44   # ход ползунка: 96 - 44 - 4 - 4

# --- Логика ---
function Get-Metric([string]$alias) {
    (Get-NetIPInterface -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction Stop).InterfaceMetric |
        Select-Object -First 1
}

$GlyphCheck = 'M 3.5,7.5 L 6,10 L 10.5,4.5'
$GlyphCross = 'M 4.5,4.5 L 9.5,9.5 M 9.5,4.5 L 4.5,9.5'

function Get-AdapterIP([string]$alias) {
    # Возвращает IPv4-адрес, если адаптер подключён и адрес не APIPA (169.254.x.x).
    # Чистый .NET вместо Get-NetIPInterface/Get-NetIPAddress: WMI-командлеты пишут
    # записи прогресса, которые ps2exe показывает отдельным окном, а конвейер,
    # оборванный Select-Object -First 1, не даёт запись закрыть — окно зависает.
    try {
        $nic = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
               Where-Object { $_.Name -eq $alias -and $_.OperationalStatus -eq 'Up' } |
               Select-Object -First 1
        if (-not $nic) { return $null }
        return ($nic.GetIPProperties().UnicastAddresses |
                Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' -and ($_.Address.ToString() -notlike '169.254.*') } |
                Select-Object -First 1).Address.ToString()
    } catch { return $null }
}

# Состояние связи по адаптерам (заполняется фоновым потоком), потокобезопасно
$script:NetState = [hashtable]::Synchronized(@{})

function Format-Bytes([double]$b) {
    if ($b -ge 1TB) { return ('{0:N2} TB' -f ($b / 1TB)) }
    if ($b -ge 1GB) { return ('{0:N2} GB' -f ($b / 1GB)) }
    if ($b -ge 1MB) { return ('{0:N1} MB' -f ($b / 1MB)) }
    if ($b -ge 1KB) { return ('{0:N0} KB' -f ($b / 1KB)) }
    return "$([int]$b) B"
}

function Get-AdapterTrafficParts([string]$alias) {
    # Накопленный трафик адаптера с загрузки ПК (приём/отдача отдельно)
    try {
        $st = Get-NetAdapterStatistics -Name $alias -ErrorAction Stop
        return @{ Down = (Format-Bytes $st.ReceivedBytes); Up = (Format-Bytes $st.SentBytes) }
    } catch { return $null }
}

function Open-AdapterProperties([string]$alias) {
    # Открывает классическое окно «Свойства» адаптера — то же, что в
    # Панель управления -> Центр управления сетями -> Изменение параметров
    # адаптера -> ПКМ -> Свойства. Если команду найти не удалось —
    # открываем саму папку сетевых подключений.
    try {
        $ncpa = (New-Object -ComObject Shell.Application).Namespace(0x31)
        $item = @($ncpa.Items()) | Where-Object { $_.Name -ieq $alias } | Select-Object -First 1
        if (-not $item) { Start-Process 'control.exe' 'ncpa.cpl'; return }
        $verb = @($item.Verbs()) | Where-Object {
            ($_.Name -replace '&', '') -in @('Properties','Свойства','Propiedades','Eigenschaften','Propriétés','属性','プロパティ','속성')
        } | Select-Object -First 1
        if (-not $verb) { Start-Process 'control.exe' 'ncpa.cpl'; return }
        # Виджет всегда поверх всех окон — временно снимаем Topmost, чтобы диалог
        # свойств не оказался под ним. PropsTimer вернёт его после закрытия диалога.
        $window.Topmost = $false
        $verb.DoIt()
        $script:PropsAlias = $alias
        $script:PropsTicks = 0
        $script:PropsFound = $false
        $script:PropsTimer.Start()
    } catch {
        Start-Process 'control.exe' 'ncpa.cpl'
    }
}

function Find-WindowByTitle([string]$fragment) {
    # Возвращает hwnd первого видимого окна, в заголовке которого есть фрагмент
    $script:FWTitle  = $fragment
    $script:FWResult = [IntPtr]::Zero
    $cb = [Native.Props+EnumWindowsProc] { param($h, $lp)
        if (-not [Native.Props]::IsWindowVisible($h)) { return $true }
        $sb = New-Object System.Text.StringBuilder 512
        [void][Native.Props]::GetWindowText($h, $sb, 512)
        if ($sb.ToString().IndexOf($script:FWTitle, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $script:FWResult = $h
            return $false
        }
        return $true
    }
    [void][Native.Props]::EnumWindows($cb, [IntPtr]::Zero)
    return $script:FWResult
}

function Test-ClickOn($src, $target) {
    # Правда ли, что клик пришёлся по элементу target (или его потомку)
    $o = $src
    while ($o -and $o -ne $target) {
        $o = try { [System.Windows.Media.VisualTreeHelper]::GetParent($o) } catch { $null }
    }
    return [bool]($o -eq $target)
}

function Set-SideIndicator($b, [string]$alias) {
    # Кружок = состояние ИНТЕРНЕТА (не приоритет): зелёный/жёлтый/красный/серый.
    # Строка 1 — IP; строка 2 — задержка и трафик (↓ зелёная, ↑ оранжевая).
    $bc = [Windows.Media.BrushConverter]::new()
    $ip = Get-AdapterIP $alias
    $net = $script:NetState[$alias]
    $state = if ($net) { [string]$net.State } elseif ($ip) { 'checking' } else { 'nolink' }
    $lat   = if ($net) { $net.Latency } else { $null }
    switch ($state) {
        'ok'       { $b.Dot.Fill = $bc.ConvertFromString((C '#8834C759')); $b.Glyph.Data = [Windows.Media.Geometry]::Parse($GlyphCheck); $b.Glyph.Visibility = 'Visible' }
        'slow'     { $b.Dot.Fill = $bc.ConvertFromString('#99E0B23A'); $b.Glyph.Visibility = 'Collapsed' }
        'down'     { $b.Dot.Fill = $bc.ConvertFromString((C '#88E04B4B')); $b.Glyph.Data = [Windows.Media.Geometry]::Parse($GlyphCross); $b.Glyph.Visibility = 'Visible' }
        'checking' { $b.Dot.Fill = $bc.ConvertFromString((C '#884CC2FF')); $b.Glyph.Visibility = 'Collapsed' }
        default    { $b.Dot.Fill = $bc.ConvertFromString('#55808080'); $b.Glyph.Visibility = 'Collapsed' }
    }
    $b.Ip.Text  = if ($ip) { $ip } else { '— . — . — . —' }
    $b.Lat.Text = if ($null -ne $lat) { "$lat ms" } else { '' }
    $tp = Get-AdapterTrafficParts $alias
    if ($tp -and $ip) {
        $b.DnA.Text = '↓'; $b.Dn.Text = $tp.Down
        $b.UpA.Text = '↑'; $b.Up.Text = $tp.Up
    } else {
        $b.DnA.Text = ''; $b.Dn.Text = ''; $b.UpA.Text = ''; $b.Up.Text = ''
    }
}

function Test-AutoMode {
    # Авто-режим = метрики адаптеров равны (Windows решает сам, приоритета нет)
    try {
        $lm = Get-Metric $LeftAlias; $rm = Get-Metric $RightAlias
        return ($null -ne $lm -and $lm -eq $rm)
    } catch { return $false }
}

function Update-Indicators {
    # Кружки/IP/трафик отражают СВЯЗЬ (не приоритет); приоритет виден по тумблеру и подсветке
    Set-SideIndicator $script:LeftBundle  $LeftAlias
    Set-SideIndicator $script:RightBundle $RightAlias
    if (Test-AutoMode) { $StatusTB.Text = T 'status_auto'; return }
    try {
        $lm = Get-Metric $LeftAlias
        $rm = Get-Metric $RightAlias
        $name = if ($script:Active -eq 'Left') { $LeftLabel } else { $RightLabel }
        $StatusTB.Text = (T 'status_priority') -f $name, $lm, $rm
    } catch { $StatusTB.Text = T 'status_read_err' }
}

function Update-UI {
    $auto   = Test-AutoMode
    $isLeft = ($script:Active -eq 'Left')
    # Трёхпозиционный тумблер: авто — по центру, иначе к выбранному адаптеру
    $targetX = if ($auto) { $ThumbRightX / 2 } elseif ($isLeft) { 0 } else { $ThumbRightX }

    $anim = [System.Windows.Media.Animation.DoubleAnimation]::new(
        $targetX, [Windows.Duration]::new([TimeSpan]::FromMilliseconds(180)))
    $anim.EasingFunction = [System.Windows.Media.Animation.CubicEase]::new()
    $Thumb.RenderTransform.BeginAnimation(
        [System.Windows.Media.TranslateTransform]::XProperty, $anim)

    $accent = [Windows.Media.BrushConverter]::new().ConvertFromString((C '#4CC2FF'))
    $dim    = [Windows.Media.BrushConverter]::new().ConvertFromString((C '#66FFFFFF'))
    if ($auto) {
        # обе подписи приглушены — приоритета нет
        $LeftLabelTB.Foreground  = $dim
        $RightLabelTB.Foreground = $dim
    } else {
        $LeftLabelTB.Foreground  = if ($isLeft) { $accent } else { $dim }
        $RightLabelTB.Foreground = if ($isLeft) { $dim } else { $accent }
    }

    Update-Indicators
}

function Apply-MainLanguage {
    # Применяет текущий язык ко всем надписям главного окна (на лету)
    $LangTxt.Text     = $script:Lang.ToUpper()
    $LangBtn.ToolTip  = T 'tip_lang'
    $MenuBtn.ToolTip  = T 'tip_rules'
    $MinBtn.ToolTip   = T 'tip_min'
    $CloseBtn.ToolTip = T 'tip_close'
    $GearBtn.ToolTip  = T 'tip_gear'
    $LeftPropsBtn.ToolTip  = T 'tip_props'
    $RightPropsBtn.ToolTip = T 'tip_props'
    $BtnAutoTxt.Text  = T 'btn_auto';  $BtnAuto.ToolTip  = T 'tip_auto'
    $BtnDnsTxt.Text   = T 'btn_dns'
    $BtnResetTxt.Text = T 'btn_reset'; $BtnReset.ToolTip = T 'tip_reset'
    if ($script:MiShow) { $script:MiShow.Text = T 'tray_show' }
    if ($script:MiExit) { $script:MiExit.Text = T 'tray_exit' }
    Update-Indicators
}

function Set-ActiveSide([string]$side) {
    $pair = if ($side -eq 'Left') { @($LeftAlias, $RightAlias) } else { @($RightAlias, $LeftAlias) }
    try {
        Set-NetIPInterface -InterfaceAlias $pair[0] -InterfaceMetric $HighMetric -ErrorAction Stop
        Set-NetIPInterface -InterfaceAlias $pair[1] -InterfaceMetric $LowMetric  -ErrorAction Stop
        Clear-DnsClientCache -ErrorAction SilentlyContinue
        # Сброс кэша путей (destination cache). Без него Windows продолжает гнать
        # новые соединения по прежнему интерфейсу, пока запись не истечёт сама.
        # Уже установленные TCP-соединения это НЕ рвёт — их надо перезапустить.
        netsh interface ipv4 delete destinationcache | Out-Null
        netsh interface ipv6 delete destinationcache | Out-Null
        $script:Active = $side
        Save-Config   # запоминаем выбор, чтобы восстановить его при следующем запуске
        $act = if ($side -eq 'Left') { $LeftAlias } else { $RightAlias }
        Write-AppLog "Приоритет -> $act (метрики $HighMetric/$LowMetric)"
    } catch {
        [System.Windows.MessageBox]::Show((T 'err_generic') -f $_.Exception.Message,
            'LAN Switcher', 'OK', 'Error') | Out-Null
    }
    Update-UI
}

function Reset-AutoMetrics {
    # Предохранитель №1: вернуть автоматические метрики (заводское поведение Windows)
    try {
        Set-NetIPInterface -InterfaceAlias $LeftAlias  -AutomaticMetric Enabled -ErrorAction Stop
        Set-NetIPInterface -InterfaceAlias $RightAlias -AutomaticMetric Enabled -ErrorAction Stop
        Clear-DnsClientCache -ErrorAction SilentlyContinue
        $script:Active = if ((Get-Metric $LeftAlias) -le (Get-Metric $RightAlias)) { 'Left' } else { 'Right' }
        Update-UI
        $StatusTB.Text = T 'status_auto'
        Write-AppLog 'Возврат к автоматическим метрикам'
    } catch {
        [System.Windows.MessageBox]::Show((T 'err_generic') -f $_.Exception.Message,
            'LAN Switcher', 'OK', 'Error') | Out-Null
    }
}

function Invoke-DnsFlush {
    Clear-DnsClientCache -ErrorAction SilentlyContinue
    $StatusTB.Text = T 'status_dns'
    Write-AppLog 'Очистка DNS-кэша'
}

function Invoke-NetworkReset {
    # Предохранитель №2: полный сброс сетевого стека
    if (-not (Show-Confirm (T 'net_confirm') (T 'net_reset_ok') (T 'net_reset_cancel'))) { return }
    try {
        ipconfig /flushdns    | Out-Null
        netsh winsock reset   | Out-Null
        netsh int ip reset    | Out-Null
        $StatusTB.Text = T 'status_netreset'
        Write-AppLog 'Полный сброс сети (flushdns + winsock + int ip)'
        $reboot = [System.Windows.MessageBox]::Show(
            (T 'net_done'), 'LAN Switcher', 'YesNo', 'Question')
        if ($reboot -eq 'Yes') { Restart-Computer -Force }
    } catch {
        [System.Windows.MessageBox]::Show((T 'err_generic') -f $_.Exception.Message,
            'LAN Switcher', 'OK', 'Error') | Out-Null
    }
}

# ======= Привязка приложений к адаптерам (ForceBindIP, по GUID) =======

function Get-Rules {
    # Отдаёт правила потоком (0..N объектов); вызывающий код оборачивает в @().
    # Where-Object отсеивает «фантомы» от пустого [] и защищает от разворачивания
    # одиночного правила (причуды ConvertFrom-Json в PS 5.1).
    if (Test-Path $RulesPath) {
        try {
            $data = Get-Content -Raw -Encoding UTF8 $RulesPath | ConvertFrom-Json
            $data | Where-Object { $_ -and $_.Exe }
        } catch { }
    }
}

function Save-Rules {
    ConvertTo-Json -InputObject @($script:Rules) -Depth 3 |
        Set-Content -Path $RulesPath -Encoding UTF8
}

function Get-ExeBitness([string]$path) {
    # Читаем PE-заголовок, чтобы выбрать правильный загрузчик ForceBindIP
    try {
        $fs = [System.IO.File]::OpenRead($path)
        try {
            $br = [System.IO.BinaryReader]::new($fs)
            [void]$fs.Seek(0x3C, 'Begin')
            $peOffset = $br.ReadInt32()
            [void]$fs.Seek($peOffset + 4, 'Begin')
            $machine = $br.ReadUInt16()
        } finally { $fs.Close() }
        if ($machine -eq 0x8664 -or $machine -eq 0xAA64) { return 64 } else { return 32 }
    } catch { return 64 }
}

function Get-FBIPLoader([string]$exe) {
    $name = if ((Get-ExeBitness $exe) -eq 64) { 'ForceBindIP64.exe' } else { 'ForceBindIP.exe' }
    $p = Join-Path $ForceBindIPDir $name
    if (Test-Path $p) { return $p }
    return $null
}

function Get-RuleType($r) {
    # Старые правила без поля Type считаем инжекцией (обратная совместимость)
    if ($r.PSObject.Properties['Type'] -and $r.Type) { return $r.Type }
    return 'FBIP'
}

$ChromiumExe = @('chrome', 'msedge', 'brave', 'vivaldi', 'opera', 'chromium', 'thorium', 'yandex')

function Test-Chromium([string]$exe) {
    return ($ChromiumExe -contains [System.IO.Path]::GetFileNameWithoutExtension($exe).ToLower())
}

function Get-PSHost {
    # Находит настоящий PowerShell-хост для запуска прокси-движка.
    # Нужно, когда виджет собран в .exe (текущий процесс — уже не PowerShell).
    $c = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $c = Get-Command powershell.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    foreach ($p in @("$env:ProgramFiles\PowerShell\7\pwsh.exe",
                     "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe")) {
        if (Test-Path $p) { return $p }
    }
    return 'powershell.exe'
}

function Stop-AllProxies {
    foreach ($e in @($script:ProxyByIp.Values)) {
        try { if ($e.Proc -and -not $e.Proc.HasExited) { $e.Proc.Kill() } } catch { }
    }
    $script:ProxyByIp = @{}
}

function Get-ProxyPort([string]$ip) {
    # Возвращает порт живого прокси для этого IP; при необходимости поднимает новый
    if ($script:ProxyByIp.ContainsKey($ip)) {
        $e = $script:ProxyByIp[$ip]
        if ($e.Proc -and -not $e.Proc.HasExited) { return $e.Port }
    }
    if (-not (Test-Path $ProxyScript)) {
        [System.Windows.MessageBox]::Show((T 'proxy_missing'),
            'LAN Switcher', 'OK', 'Error') | Out-Null
        return $null
    }
    $port = $script:NextProxyPort
    $script:NextProxyPort++
    $engine = Get-PSHost
    $proc = Start-Process $engine -WindowStyle Hidden -PassThru -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$ProxyScript`"",
        '-ListenPort', $port, '-BindIP', $ip)
    # Ждём, пока прокси начнёт слушать (до ~4 сек)
    $listening = $false
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 200
        if (Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue) { $listening = $true; break }
        if ($proc.HasExited) { break }
    }
    if (-not $listening) {
        try { if (-not $proc.HasExited) { $proc.Kill() } } catch { }
        [System.Windows.MessageBox]::Show((T 'proxy_start_fail') -f $port,
            'LAN Switcher', 'OK', 'Error') | Out-Null
        return $null
    }
    $script:ProxyByIp[$ip] = [PSCustomObject]@{ Port = $port; Proc = $proc }
    return $port
}

function Invoke-RuleLaunchFBIP($r) {
    $loader = Get-FBIPLoader $r.Exe
    if (-not $loader) {
        [System.Windows.MessageBox]::Show((T 'fbip_not_found') -f $ForceBindIPDir,
            'LAN Switcher', 'OK', 'Error') | Out-Null
        return
    }
    Start-Process -FilePath $loader -ArgumentList $r.Guid, "`"$($r.Exe)`"" `
        -WorkingDirectory (Split-Path $r.Exe)
}

function Invoke-RuleLaunchProxy($r) {
    $ip = Get-AdapterIP $r.Adapter
    if (-not $ip) {
        [System.Windows.MessageBox]::Show((T 'adapter_no_ip') -f $r.Adapter,
            'LAN Switcher', 'OK', 'Error') | Out-Null
        return
    }
    $port = Get-ProxyPort $ip
    if (-not $port) { return }

    if (Test-Chromium $r.Exe) {
        # Отдельный профиль на адаптер: гарантирует новый экземпляр, где флаг применится
        $safe = ($r.Adapter -replace '[^\w]', '_')
        $profile = Join-Path $env:LOCALAPPDATA "LANSwitcher\Profiles\$safe"
        Start-Process -FilePath $r.Exe -ArgumentList @(
            "--proxy-server=127.0.0.1:$port",
            "--user-data-dir=`"$profile`"") -WorkingDirectory (Split-Path $r.Exe)
    } else {
        [System.Windows.MessageBox]::Show(
            (T 'proxy_nonchromium') -f $port, (Get-AdapterDisplay $r.Adapter), [System.IO.Path]::GetFileName($r.Exe),
            'LAN Switcher', 'OK', 'Information') | Out-Null
    }
}

function Invoke-RuleLaunch([int]$idx) {
    $r = $script:Rules[$idx]
    if (-not (Test-Path $r.Exe)) {
        [System.Windows.MessageBox]::Show((T 'file_not_found') -f $r.Exe,
            'LAN Switcher', 'OK', 'Error') | Out-Null
        return
    }
    if ((Get-RuleType $r) -eq 'Proxy') { Invoke-RuleLaunchProxy $r } else { Invoke-RuleLaunchFBIP $r }
}

$ProxyLauncherTemplate = @'
# Автосгенерированный лаунчер LAN Switcher — правило "прокси".
$ErrorActionPreference = 'SilentlyContinue'
$adapter = '__ADAPTER__'
$exe     = '__EXE__'
$proxyPs = '__PROXYPS__'
$profile = '__PROFILE__'

$ip = (Get-NetIPAddress -InterfaceAlias $adapter -AddressFamily IPv4 |
       Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1).IPAddress
if (-not $ip) { exit }

# Свободный локальный порт
$l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$l.Start(); $port = $l.LocalEndpoint.Port; $l.Stop()

# PowerShell-хост для прокси-движка
$psh = (Get-Command pwsh.exe -EA SilentlyContinue).Source
if (-not $psh) { $psh = (Get-Command powershell.exe -EA SilentlyContinue).Source }

$proxy = Start-Process $psh -WindowStyle Hidden -PassThru -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$proxyPs`" -ListenPort $port -BindIP $ip"
Start-Sleep -Milliseconds 900

$browser = Start-Process $exe -PassThru -ArgumentList "--proxy-server=127.0.0.1:$port --user-data-dir=`"$profile`""
if ($browser) { $browser.WaitForExit() }
try { if ($proxy -and -not $proxy.HasExited) { $proxy.Kill() } } catch { }
'@

function New-ProxyLauncher($r) {
    # Генерирует самодостаточный лаунчер: поднимает прокси на IP адаптера,
    # запускает браузер, ждёт его закрытия и гасит прокси. Возвращает путь к .ps1.
    $lauDir = Join-Path $DataDir 'launchers'
    New-Item -ItemType Directory -Path $lauDir -Force | Out-Null
    $safe = (([System.IO.Path]::GetFileNameWithoutExtension($r.Exe)) + '_' + $r.Adapter) -replace '[^\w]', '_'
    $lauPath = Join-Path $lauDir "$safe.ps1"
    $profSafe = ($r.Adapter -replace '[^\w]', '_')
    $profPath = Join-Path $env:LOCALAPPDATA "LANSwitcher\Profiles\$profSafe"

    $body = $ProxyLauncherTemplate.
        Replace('__ADAPTER__', ($r.Adapter     -replace "'", "''")).
        Replace('__EXE__',     ($r.Exe         -replace "'", "''")).
        Replace('__PROXYPS__', ($ProxyScript   -replace "'", "''")).
        Replace('__PROFILE__', ($profPath      -replace "'", "''"))
    Set-Content -Path $lauPath -Value $body -Encoding UTF8
    return $lauPath
}

function New-RuleShortcut([int]$idx) {
    $r = $script:Rules[$idx]
    if (-not (Test-Path $r.Exe)) {
        [System.Windows.MessageBox]::Show("Файл не найден:`n$($r.Exe)", 'LAN Switcher', 'OK', 'Error') | Out-Null
        return
    }
    $desktop = [System.Environment]::GetFolderPath('Desktop')
    $appName = [System.IO.Path]::GetFileNameWithoutExtension($r.Exe)
    $lnkName = ("$appName ($($r.Adapter))" -replace '[\\/:*?"<>|]', '_') + '.lnk'
    $lnkPath = Join-Path $desktop $lnkName
    try {
        $ws = New-Object -ComObject WScript.Shell
        $lnk = $ws.CreateShortcut($lnkPath)
        if ((Get-RuleType $r) -eq 'Proxy') {
            if (-not (Test-Chromium $r.Exe)) {
                [System.Windows.MessageBox]::Show((T 'shortcut_nonchromium') -f $appName,
                    'LAN Switcher', 'OK', 'Warning') | Out-Null
                return
            }
            $lau = New-ProxyLauncher $r
            $engine = Get-PSHost
            $lnk.TargetPath = $engine
            $lnk.Arguments  = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$lau`""
            $lnk.WorkingDirectory = $ScriptDir
        } else {
            $loader = Get-FBIPLoader $r.Exe
            if (-not $loader) {
                [System.Windows.MessageBox]::Show((T 'fbip_not_found') -f $ForceBindIPDir,
                    'LAN Switcher', 'OK', 'Error') | Out-Null
                return
            }
            $lnk.TargetPath = $loader
            $lnk.Arguments  = "$($r.Guid) `"$($r.Exe)`""
            $lnk.WorkingDirectory = Split-Path $r.Exe
        }
        $lnk.IconLocation = "$($r.Exe),0"
        $lnk.Description   = "LAN Switcher: $appName через $($r.Adapter)"
        $lnk.Save()
        [System.Windows.MessageBox]::Show((T 'shortcut_created') -f $lnkName,
            'LAN Switcher', 'OK', 'Information') | Out-Null
    } catch {
        [System.Windows.MessageBox]::Show((T 'shortcut_fail') -f $_.Exception.Message,
            'LAN Switcher', 'OK', 'Error') | Out-Null
    }
}

function Get-AdapterDisplay([string]$name) {
    # Добавляет модель к системному имени адаптера
    if ($name -eq $LeftAlias)  { return "$name ($LeftLabel)" }
    if ($name -eq $RightAlias) { return "$name ($RightLabel)" }
    return $name
}

function Invoke-RuleCheck([int]$idx) {
    # Проверка: через какой адаптер РЕАЛЬНО идёт трафик приложения
    $r = $script:Rules[$idx]
    $procName = [System.IO.Path]::GetFileNameWithoutExtension($r.Exe)
    $procs = @(Get-Process -Name $procName -ErrorAction SilentlyContinue)
    if (-not $procs.Count) {
        [System.Windows.MessageBox]::Show((T 'check_not_running') -f $procName,
            (T 'check_title'), 'OK', 'Information') | Out-Null
        return
    }
    $conns = @(Get-NetTCPConnection -OwningProcess $procs.Id -State Established -ErrorAction SilentlyContinue |
               Where-Object { $_.LocalAddress -notmatch '^(127\.|::1|0\.0\.0\.0|::)' })
    if (-not $conns.Count) {
        [System.Windows.MessageBox]::Show((T 'check_no_conns') -f $procName,
            (T 'check_title'), 'OK', 'Information') | Out-Null
        return
    }
    $ipMap = @{}
    Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        ForEach-Object { $ipMap[$_.IPAddress] = $_.InterfaceAlias }
    $lines = $conns | Group-Object LocalAddress | Sort-Object Count -Descending | ForEach-Object {
        $ali = $ipMap[$_.Name]; if (-not $ali) { $ali = T 'unknown_iface' }
        (T 'conn_line') -f $_.Count, (Get-AdapterDisplay $ali), $_.Name
    }
    $viaRule = @($conns | Where-Object { $ipMap[$_.LocalAddress] -eq $r.Adapter })
    $verdict = if ($viaRule.Count -eq $conns.Count) { T 'verdict_yes' }
               elseif ($viaRule.Count) { (T 'verdict_partial') -f $viaRule.Count, $conns.Count }
               else { T 'verdict_no' }
    [System.Windows.MessageBox]::Show(
        (T 'check_report') -f $procName, $conns.Count, ($lines -join "`n"), (Get-AdapterDisplay $r.Adapter), $verdict,
        (T 'check_title'), 'OK', 'Information') | Out-Null
}

$RuleRowXaml = @'
<Border xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Background="#2A2A30" CornerRadius="8" Padding="10,6" Margin="0,0,0,6" ToolTip="{2}">
  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="*"/>
      <ColumnDefinition Width="Auto"/>
      <ColumnDefinition Width="Auto"/>
      <ColumnDefinition Width="Auto"/>
      <ColumnDefinition Width="Auto"/>
    </Grid.ColumnDefinitions>
    <StackPanel Grid.Column="0" VerticalAlignment="Center">
      <TextBlock Text="{0}" Foreground="#EEFFFFFF" FontSize="12" FontWeight="SemiBold"
                 TextTrimming="CharacterEllipsis"/>
      <TextBlock x:Name="RowSub" Text="" Foreground="#77FFFFFF" FontSize="10"/>
    </StackPanel>
    <Border Grid.Column="1" x:Name="RunBtn" Background="#2E4D33" CornerRadius="6"
            Padding="9,3" Cursor="Hand" Margin="6,0,0,0" VerticalAlignment="Center">
      <TextBlock Text="&#9654;" Foreground="#7DDB8A" FontSize="11"/>
    </Border>
    <Border Grid.Column="2" x:Name="CheckBtn" Background="#233F4F" CornerRadius="6"
            Padding="9,3" Cursor="Hand" Margin="6,0,0,0" VerticalAlignment="Center">
      <TextBlock Text="?" Foreground="#4CC2FF" FontSize="11" FontWeight="Bold"/>
    </Border>
    <Border Grid.Column="3" x:Name="LnkBtn" Background="#3A3320" CornerRadius="6"
            Padding="9,3" Cursor="Hand" Margin="6,0,0,0" VerticalAlignment="Center">
      <TextBlock Text="&#8599;" Foreground="#E8C878" FontSize="11" FontWeight="Bold"/>
    </Border>
    <Border Grid.Column="4" x:Name="DelBtn" Background="#4D2E2E" CornerRadius="6"
            Padding="9,3" Cursor="Hand" Margin="6,0,0,0" VerticalAlignment="Center">
      <TextBlock Text="&#10005;" Foreground="#E08585" FontSize="11"/>
    </Border>
  </Grid>
</Border>
'@

$RulesWinXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Привязка приложений" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" Topmost="True" ResizeMode="NoResize"
        SizeToContent="WidthAndHeight" ShowInTaskbar="False"
        WindowStartupLocation="CenterOwner" FontFamily="Segoe UI">
  <Border CornerRadius="14" Background="#EE1F1F23" BorderBrush="#33FFFFFF"
          BorderThickness="1" Padding="18,12,18,14">
    <StackPanel Width="330">
      <Grid>
        <TextBlock x:Name="RWHeader" Text="APP BINDING" Foreground="#55FFFFFF" FontSize="10"
                   FontWeight="Bold" VerticalAlignment="Center"/>
        <TextBlock x:Name="RWClose" Text="X" Foreground="#77FFFFFF" FontSize="12"
                   HorizontalAlignment="Right" Cursor="Hand" Padding="8,0,0,4"/>
      </Grid>
      <TextBlock x:Name="RWHelp" Text="" Foreground="#66FFFFFF" FontSize="10"
                 TextWrapping="Wrap" Margin="0,8,0,0"/>
      <StackPanel x:Name="RulesPanel" Margin="0,10,0,0"/>
      <TextBlock x:Name="NoRulesTB" Text="Правил пока нет — добавьте первое" Foreground="#44FFFFFF"
                 FontSize="11" HorizontalAlignment="Center" Margin="0,2,0,4"/>
      <Border Height="1" Background="#22FFFFFF" Margin="0,6,0,10"/>
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <Border Grid.Column="0" Background="#2A2A30" CornerRadius="8" Padding="8,5" Margin="0,0,8,0">
          <TextBlock x:Name="ExeTB" Text="выберите exe-файл..." Foreground="#66FFFFFF"
                     FontSize="11" TextTrimming="CharacterEllipsis"/>
        </Border>
        <Border Grid.Column="1" x:Name="BrowseBtn" Background="#2E2E34" CornerRadius="8"
                Padding="12,5" Cursor="Hand">
          <TextBlock x:Name="RWBrowseTxt" Text="Browse" Foreground="#CCFFFFFF" FontSize="11"/>
        </Border>
      </Grid>
      <Border x:Name="TypeBtn" Background="#2A2A30" CornerRadius="8" Padding="8,5"
              Cursor="Hand" Margin="0,8,0,0" ToolTip="Клик — сменить тип правила">
        <TextBlock x:Name="TypeTB" Text="Тип: инжекция (ForceBindIP)" Foreground="#4CC2FF"
                   FontSize="11" HorizontalAlignment="Center"/>
      </Border>
      <Grid Margin="0,8,0,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <Border Grid.Column="0" x:Name="AdapterBtn" Background="#2A2A30" CornerRadius="8"
                Padding="8,5" Cursor="Hand" Margin="0,0,8,0"
                ToolTip="Клик — переключить адаптер">
          <TextBlock x:Name="AdapterTB" Text="-" Foreground="#4CC2FF" FontSize="11"
                     HorizontalAlignment="Center"/>
        </Border>
        <Border Grid.Column="1" x:Name="AddBtn" Background="#234254" CornerRadius="8"
                Padding="12,5" Cursor="Hand">
          <TextBlock x:Name="RWAddTxt" Text="Add" Foreground="#4CC2FF" FontSize="11"/>
        </Border>
      </Grid>
    </StackPanel>
  </Border>
</Window>
'@

function Refresh-RulesPanel {
    $script:RWPanel.Children.Clear()
    $script:RWNoRules.Visibility = if ($script:Rules.Count) { 'Collapsed' } else { 'Visible' }
    for ($i = 0; $i -lt $script:Rules.Count; $i++) {
        $r    = $script:Rules[$i]
        $name = [System.Security.SecurityElement]::Escape([System.IO.Path]::GetFileName($r.Exe))
        $adp  = [System.Security.SecurityElement]::Escape((Get-AdapterDisplay $r.Adapter))
        $path = [System.Security.SecurityElement]::Escape($r.Exe)
        $tlab = if ((Get-RuleType $r) -eq 'Proxy') { T 'lbl_prx' } else { T 'lbl_inj' }
        $row  = [Windows.Markup.XamlReader]::Parse((Fill-Theme ($RuleRowXaml -f $name, $adp, $path, $tlab)))
        $adpDisplay = Get-AdapterDisplay $r.Adapter
        $row.FindName('RowSub').Text = "$tlab · $(T 'lbl_via') $adpDisplay"
        $run  = $row.FindName('RunBtn')
        $chk  = $row.FindName('CheckBtn')
        $lnk  = $row.FindName('LnkBtn')
        $del  = $row.FindName('DelBtn')
        $run.ToolTip = (T 'tip_run') -f $adpDisplay
        $chk.ToolTip = T 'tip_check'
        $lnk.ToolTip = T 'tip_shortcut'
        $del.ToolTip = T 'tip_delete'
        $run.Tag = $i
        $chk.Tag = $i
        $lnk.Tag = $i
        $del.Tag = $i
        $run.Add_PreviewMouseLeftButtonDown({ param($s, $e)
            $e.Handled = $true; Invoke-RuleLaunch ([int]$s.Tag)
        })
        $chk.Add_PreviewMouseLeftButtonDown({ param($s, $e)
            $e.Handled = $true; Invoke-RuleCheck ([int]$s.Tag)
        })
        $lnk.Add_PreviewMouseLeftButtonDown({ param($s, $e)
            $e.Handled = $true; New-RuleShortcut ([int]$s.Tag)
        })
        $del.Add_PreviewMouseLeftButtonDown({ param($s, $e)
            $e.Handled = $true
            $idx = [int]$s.Tag
            $keep = New-Object System.Collections.ArrayList
            for ($j = 0; $j -lt $script:Rules.Count; $j++) {
                if ($j -ne $idx) { [void]$keep.Add($script:Rules[$j]) }
            }
            $script:Rules = @($keep.ToArray())
            Save-Rules
            Refresh-RulesPanel
        })
        [void]$script:RWPanel.Children.Add($row)
    }
}

function Show-RulesWindow {
    $rw = [Windows.Markup.XamlReader]::Parse((Fill-Theme $RulesWinXaml))
    $rw.Owner = $window
    $script:RWPanel    = $rw.FindName('RulesPanel')
    $script:RWNoRules  = $rw.FindName('NoRulesTB')
    $script:RWExeTB    = $rw.FindName('ExeTB')
    $script:RWAdTB     = $rw.FindName('AdapterTB')
    $script:RWTypeTB   = $rw.FindName('TypeTB')
    $script:PendingType = 'FBIP'
    # Локализация статичных надписей окна
    $rw.FindName('RWHeader').Text    = T 'rules_header'
    $rw.FindName('RWHelp').Text      = T 'rules_help'
    $script:RWNoRules.Text           = T 'rules_none'
    $script:RWExeTB.Text             = T 'rules_pick_exe'
    $rw.FindName('RWBrowseTxt').Text = T 'rules_browse'
    $rw.FindName('RWAddTxt').Text     = T 'rules_add'
    $rw.FindName('AdapterBtn').ToolTip = T 'tip_adapter'
    $rw.FindName('TypeBtn').ToolTip     = T 'tip_type'
    $script:RWTypeTB.Text = T 'type_fbip'
    $script:Rules      = @(Get-Rules)
    # Самолечение GUID: правило переехало с другого ПК (или адаптер переустановлен) —
    # если GUID не найден, но адаптер с таким именем есть, обновляем GUID
    $curr = @{}
    Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
        ForEach-Object { $curr[$_.Name] = $_.InterfaceGuid }
    $healed = $false
    foreach ($r in $script:Rules) {
        if ($curr.Values -notcontains $r.Guid -and $curr.ContainsKey($r.Adapter)) {
            $r.Guid = $curr[$r.Adapter]
            $healed = $true
        }
    }
    if ($healed) { Save-Rules }
    $script:PendingExe = $null
    $script:AdList     = @(Get-NetAdapter -Physical | Sort-Object Name)
    $script:AdIdx      = 0
    if ($script:AdList.Count) { $script:RWAdTB.Text = Get-AdapterDisplay $script:AdList[0].Name }

    $rw.FindName('RWClose').Add_PreviewMouseLeftButtonDown({ param($s, $e)
        $e.Handled = $true; $s.Tag = $null
        [System.Windows.Window]::GetWindow($s).Close()
    })
    $rw.FindName('BrowseBtn').Add_PreviewMouseLeftButtonDown({ param($s, $e)
        $e.Handled = $true
        $dlg = [Microsoft.Win32.OpenFileDialog]::new()
        $dlg.Filter = 'Программы (*.exe)|*.exe'
        $dlg.Title  = 'Выберите приложение'
        if ($dlg.ShowDialog()) {
            $script:PendingExe = $dlg.FileName
            $script:RWExeTB.Text = [System.IO.Path]::GetFileName($dlg.FileName)
            $script:RWExeTB.Foreground = (C '#EEFFFFFF')
        }
    })
    $rw.FindName('AdapterBtn').Add_PreviewMouseLeftButtonDown({ param($s, $e)
        $e.Handled = $true
        if (-not $script:AdList.Count) { return }
        $script:AdIdx = ($script:AdIdx + 1) % $script:AdList.Count
        $script:RWAdTB.Text = Get-AdapterDisplay $script:AdList[$script:AdIdx].Name
    })
    $rw.FindName('TypeBtn').Add_PreviewMouseLeftButtonDown({ param($s, $e)
        $e.Handled = $true
        if ($script:PendingType -eq 'FBIP') {
            $script:PendingType = 'Proxy'
            $script:RWTypeTB.Text = T 'type_proxy'
        } else {
            $script:PendingType = 'FBIP'
            $script:RWTypeTB.Text = T 'type_fbip'
        }
    })
    $rw.FindName('AddBtn').Add_PreviewMouseLeftButtonDown({ param($s, $e)
        $e.Handled = $true
        if (-not $script:PendingExe) {
            [System.Windows.MessageBox]::Show((T 'rule_pick_first'),
                'LAN Switcher', 'OK', 'Information') | Out-Null
            return
        }
        $ad = $script:AdList[$script:AdIdx]
        foreach ($ex in $script:Rules) {
            if ($ex.Exe -eq $script:PendingExe -and $ex.Guid -eq $ad.InterfaceGuid -and (Get-RuleType $ex) -eq $script:PendingType) {
                [System.Windows.MessageBox]::Show((T 'rule_dup'),
                    'LAN Switcher', 'OK', 'Information') | Out-Null
                return
            }
        }
        $script:Rules = @($script:Rules) + [PSCustomObject]@{
            Exe     = $script:PendingExe
            Adapter = $ad.Name
            Guid    = $ad.InterfaceGuid
            Type    = $script:PendingType
        }
        Save-Rules
        Refresh-RulesPanel
        $script:PendingExe = $null
        $script:RWExeTB.Text = T 'rules_pick_exe'
        $script:RWExeTB.Foreground = (C '#66FFFFFF')
    })
    $rw.Add_MouseLeftButtonDown({ param($s, $e) try { $s.DragMove() } catch { } })

    Refresh-RulesPanel
    [void]$rw.ShowDialog()
}

$SettingsXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Settings" WindowStyle="None" AllowsTransparency="True"
        Background="Transparent" Topmost="True" ResizeMode="CanResize"
        SizeToContent="Manual" ShowInTaskbar="False"
        WindowStartupLocation="CenterOwner" FontFamily="Segoe UI">
  <Window.Resources>
    <!-- Современная тонкая полоса прокрутки вместо системной "Aero":
         без кнопок-стрелок, скруглённый thumb, подсветка при наведении -->
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="8"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="{x:Static ScrollBar.PageUpCommand}" Opacity="0" Focusable="False"/>
                </Track.DecreaseRepeatButton>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Command="{x:Static ScrollBar.PageDownCommand}" Opacity="0" Focusable="False"/>
                </Track.IncreaseRepeatButton>
                <Track.Thumb>
                  <Thumb MinHeight="30">
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Border x:Name="TB" Background="#44FFFFFF" CornerRadius="4" Margin="1.5,1,1.5,1"/>
                        <ControlTemplate.Triggers>
                          <Trigger Property="IsMouseOver" Value="True">
                            <Setter TargetName="TB" Property="Background" Value="#99FFFFFF"/>
                          </Trigger>
                        </ControlTemplate.Triggers>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>
  <Border CornerRadius="14" Background="#EE1F1F23" BorderBrush="#33FFFFFF"
          BorderThickness="1" Padding="18,12,18,14">
    <StackPanel MinWidth="300">
      <Grid>
        <TextBlock x:Name="STitle" Text="SETTINGS" Foreground="#55FFFFFF" FontSize="10"
                   FontWeight="Bold" VerticalAlignment="Center"/>
        <TextBlock x:Name="SClose" Text="X" Foreground="#77FFFFFF" FontSize="12"
                   HorizontalAlignment="Right" Cursor="Hand" Padding="8,0,0,4"/>
      </Grid>
      <ScrollViewer x:Name="SBodyScroll" VerticalScrollBarVisibility="Auto" MaxHeight="430" Margin="0,10,0,0">
        <StackPanel Margin="0,0,12,0">
          <!-- Секция: Метрики -->
          <TextBlock x:Name="SMetricsHdr" Text="PRIORITY METRICS" Foreground="#4CC2FF" FontSize="10" FontWeight="Bold"/>
          <TextBlock x:Name="SHelp" Text="" Foreground="#66FFFFFF" FontSize="10" TextWrapping="Wrap" Margin="0,4,0,8"/>
          <Grid Margin="0,0,0,8">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <TextBlock x:Name="SPrio" Grid.Column="0" Text="Priority:" Foreground="#CCFFFFFF" FontSize="12" VerticalAlignment="Center"/>
            <Border Grid.Column="1" Background="#2A2A30" CornerRadius="6" Padding="6,2">
              <TextBox x:Name="HighTB" Width="60" Background="Transparent" BorderThickness="0"
                       Foreground="#EEFFFFFF" FontSize="12" TextAlignment="Center"/>
            </Border>
          </Grid>
          <Grid Margin="0,0,0,4">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <TextBlock x:Name="SSec" Grid.Column="0" Text="Secondary:" Foreground="#CCFFFFFF" FontSize="12" VerticalAlignment="Center"/>
            <Border Grid.Column="1" Background="#2A2A30" CornerRadius="6" Padding="6,2">
              <TextBox x:Name="LowTB" Width="60" Background="Transparent" BorderThickness="0"
                       Foreground="#EEFFFFFF" FontSize="12" TextAlignment="Center"/>
            </Border>
          </Grid>
          <Border Height="1" Background="#22FFFFFF" Margin="0,10,0,10"/>
          <!-- Секция: Профили -->
          <TextBlock x:Name="SProfHdr" Text="PROFILES" Foreground="#4CC2FF" FontSize="10" FontWeight="Bold"/>
          <Grid Margin="0,6,0,0">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <Border Grid.Column="0" Background="#2A2A30" CornerRadius="6" Padding="6,3" Margin="0,0,6,0">
              <TextBox x:Name="ProfNameTB" Background="Transparent" BorderThickness="0" Foreground="#EEFFFFFF" FontSize="11"/>
            </Border>
            <Border Grid.Column="1" x:Name="ProfSave" Background="#234254" CornerRadius="6" Padding="12,3" Cursor="Hand">
              <TextBlock x:Name="ProfSaveTxt" Text="Save" Foreground="#4CC2FF" FontSize="11"/>
            </Border>
          </Grid>
          <Grid Margin="0,6,0,0">
            <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
            <Border Grid.Column="0" x:Name="ProfSel" Background="#2A2A30" CornerRadius="6" Padding="6,3" Cursor="Hand" Margin="0,0,6,0">
              <Grid>
                <TextBlock x:Name="ProfSelTxt" Text="—" Foreground="#4CC2FF" FontSize="11" HorizontalAlignment="Center"/>
                <TextBlock Text="&#9662;" Foreground="#77FFFFFF" FontSize="9" HorizontalAlignment="Right" VerticalAlignment="Center"/>
              </Grid>
            </Border>
            <Border Grid.Column="1" x:Name="ProfApply" Background="#2E4D33" CornerRadius="6" Padding="10,3" Cursor="Hand" Margin="0,0,5,0">
              <TextBlock x:Name="ProfApplyTxt" Text="Apply" Foreground="#7DDB8A" FontSize="11"/>
            </Border>
            <Border Grid.Column="2" x:Name="ProfDel" Background="#4D2E2E" CornerRadius="6" Padding="10,3" Cursor="Hand">
              <TextBlock Text="&#10005;" Foreground="#E08585" FontSize="11"/>
            </Border>
          </Grid>
          <Popup x:Name="ProfPopup" Placement="Bottom" StaysOpen="False" AllowsTransparency="True">
            <Border Background="#EE1F1F23" BorderBrush="#33FFFFFF" BorderThickness="1" CornerRadius="6" Padding="4">
              <StackPanel x:Name="ProfListPanel" MinWidth="150"/>
            </Border>
          </Popup>
          <Border Height="1" Background="#22FFFFFF" Margin="0,10,0,10"/>
          <!-- Секция: Автозапуск -->
          <TextBlock x:Name="SAutoHdr" Text="AUTOSTART" Foreground="#4CC2FF" FontSize="10" FontWeight="Bold"/>
          <StackPanel x:Name="AutoToggle" Orientation="Horizontal" Cursor="Hand" Margin="0,6,0,0">
            <Border x:Name="AutoChk" Width="16" Height="16" CornerRadius="4" Background="#2A2A30"
                    BorderBrush="#55FFFFFF" BorderThickness="1" VerticalAlignment="Center">
              <TextBlock x:Name="AutoChkMark" Text="&#10003;" Foreground="#4CC2FF" FontSize="11" FontWeight="Bold"
                         HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"/>
            </Border>
            <TextBlock x:Name="AutoLabel" Text="Start with Windows" Foreground="#CCFFFFFF" FontSize="12" Margin="8,0,0,0" VerticalAlignment="Center"/>
          </StackPanel>
          <TextBlock x:Name="AutoNote" Text="" Foreground="#66FFFFFF" FontSize="10" TextWrapping="Wrap" Margin="0,6,0,0"/>
          <Border Height="1" Background="#22FFFFFF" Margin="0,10,0,10"/>
          <!-- Секция: Горячие клавиши -->
          <TextBlock x:Name="SHkHdr" Text="HOTKEYS" Foreground="#4CC2FF" FontSize="10" FontWeight="Bold"/>
          <StackPanel x:Name="HotkeyContainer" Margin="0,6,0,0"/>
          <TextBlock x:Name="SHkHint" Text="" Foreground="#66FFFFFF" FontSize="10" TextWrapping="Wrap" Margin="0,4,0,0"/>
          <Border Height="1" Background="#22FFFFFF" Margin="0,10,0,10"/>
          <!-- Секция: DNS -->
          <TextBlock Text="DNS" Foreground="#4CC2FF" FontSize="10" FontWeight="Bold"/>
          <StackPanel x:Name="DnsContainer" Margin="0,6,0,0"/>
          <Border Height="1" Background="#22FFFFFF" Margin="0,10,0,10"/>
          <!-- Секция: Журнал -->
          <TextBlock x:Name="SLogsHdr" Text="LOGS" Foreground="#4CC2FF" FontSize="10" FontWeight="Bold"/>
          <StackPanel x:Name="LogToggle" Orientation="Horizontal" Cursor="Hand" Margin="0,6,0,0">
            <Border x:Name="LogChk" Width="16" Height="16" CornerRadius="4" Background="#2A2A30"
                    BorderBrush="#55FFFFFF" BorderThickness="1" VerticalAlignment="Center">
              <TextBlock x:Name="LogChkMark" Text="&#10003;" Foreground="#4CC2FF" FontSize="11" FontWeight="Bold"
                         HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"/>
            </Border>
            <TextBlock x:Name="LogLabel" Text="Keep a log" Foreground="#CCFFFFFF" FontSize="12" Margin="8,0,0,0" VerticalAlignment="Center"/>
          </StackPanel>
          <TextBlock x:Name="LogFolderLbl" Text="Log folder:" Foreground="#66FFFFFF" FontSize="10" Margin="0,10,0,2"/>
          <Border Background="#2A2A30" CornerRadius="6" Padding="7,4">
            <TextBlock x:Name="LogPathTB" Text="" Foreground="#99FFFFFF" FontSize="10" TextWrapping="Wrap"/>
          </Border>
          <StackPanel Orientation="Horizontal" Margin="0,6,0,0">
            <Border x:Name="LogBrowseBtn" Background="#2E2E34" CornerRadius="6" Padding="12,4" Cursor="Hand" Margin="0,0,8,0">
              <TextBlock x:Name="LogBrowseTxt" Text="Browse" Foreground="#CCFFFFFF" FontSize="11"/>
            </Border>
            <Border x:Name="LogShowBtn" Background="#2E2E34" CornerRadius="6" Padding="12,4" Cursor="Hand">
              <TextBlock x:Name="LogShowTxt" Text="Show in folder" Foreground="#CCFFFFFF" FontSize="11"/>
            </Border>
          </StackPanel>
        </StackPanel>
      </ScrollViewer>
      <Border x:Name="SSave" Background="#234254" CornerRadius="8" Padding="10,6" Cursor="Hand" Margin="0,12,0,0">
        <TextBlock x:Name="SSaveTxt" Text="Save and apply" Foreground="#4CC2FF" FontSize="12" HorizontalAlignment="Center"/>
      </Border>
    </StackPanel>
  </Border>
</Window>
'@

$ConfirmXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Confirm" WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ResizeMode="NoResize" SizeToContent="WidthAndHeight"
        ShowInTaskbar="False" WindowStartupLocation="CenterOwner" FontFamily="Segoe UI">
  <Border CornerRadius="14" Background="#EE1F1F23" BorderBrush="#33FFFFFF" BorderThickness="1" Padding="18,14,18,14">
    <StackPanel Width="300">
      <TextBlock x:Name="CfMsg" Text="" TextWrapping="Wrap" Foreground="#EEFFFFFF" FontSize="12"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0">
        <Border x:Name="CfOk" Background="#4D2E2E" CornerRadius="8" Padding="16,6" Cursor="Hand" Margin="0,0,8,0">
          <TextBlock x:Name="CfOkTxt" Text="Reset" Foreground="#FF9E9E" FontSize="12"/>
        </Border>
        <Border x:Name="CfCancel" Background="#2E2E34" CornerRadius="8" Padding="16,6" Cursor="Hand">
          <TextBlock x:Name="CfCancelTxt" Text="Cancel" Foreground="#CCFFFFFF" FontSize="12"/>
        </Border>
      </StackPanel>
    </StackPanel>
  </Border>
</Window>
'@

function Show-Confirm([string]$message, [string]$okText, [string]$cancelText) {
    $cf = [Windows.Markup.XamlReader]::Parse((Fill-Theme $ConfirmXaml))
    $cf.Owner = $window
    $cf.FindName('CfMsg').Text       = $message
    $cf.FindName('CfOkTxt').Text     = $okText
    $cf.FindName('CfCancelTxt').Text = $cancelText
    $script:CfResult = $false
    $cf.FindName('CfOk').Add_PreviewMouseLeftButtonDown({ param($s, $e)
        $e.Handled = $true; $script:CfResult = $true; [System.Windows.Window]::GetWindow($s).Close()
    })
    $cf.FindName('CfCancel').Add_PreviewMouseLeftButtonDown({ param($s, $e)
        $e.Handled = $true; $script:CfResult = $false; [System.Windows.Window]::GetWindow($s).Close()
    })
    $cf.Add_MouseLeftButtonDown({ param($s, $e) try { $s.DragMove() } catch { } })
    [void]$cf.ShowDialog()
    return $script:CfResult
}

$HotkeyRowTemplate = @'
<Grid xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
      xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Margin="0,0,0,6">
  <Grid.ColumnDefinitions>
    <ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/>
  </Grid.ColumnDefinitions>
  <TextBlock Grid.Column="0" Text="{0}" Foreground="#CCFFFFFF" FontSize="11" VerticalAlignment="Center" Width="76"/>
  <Border Grid.Column="1" Background="#2A2A30" CornerRadius="6" Padding="6,3" Margin="0,0,6,0">
    <TextBlock x:Name="HkCombo" Text="—" Foreground="#99FFFFFF" FontSize="11" HorizontalAlignment="Center"/>
  </Border>
  <Border Grid.Column="2" x:Name="HkSet" Background="#2E2E34" CornerRadius="6" Padding="9,3" Cursor="Hand" Margin="0,0,5,0">
    <TextBlock x:Name="HkSetTxt" Text="Set" Foreground="#CCFFFFFF" FontSize="10"/>
  </Border>
  <Border Grid.Column="3" x:Name="HkClr" Background="#4D2E2E" CornerRadius="6" Padding="9,3" Cursor="Hand">
    <TextBlock Text="&#10005;" Foreground="#E08585" FontSize="10"/>
  </Border>
</Grid>
'@

$DnsRowTemplate = @'
<StackPanel xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
            xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Margin="0,0,0,10">
  <TextBlock x:Name="DnsName" Text="{0}" Foreground="#CCFFFFFF" FontSize="11" FontWeight="SemiBold"/>
  <Grid Margin="0,4,0,0">
    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
    <Border Grid.Column="0" Background="#2A2A30" CornerRadius="6" Padding="6,3" Margin="0,0,4,0">
      <TextBox x:Name="DnsPri" Background="Transparent" BorderThickness="0" Foreground="#EEFFFFFF" FontSize="11"/>
    </Border>
    <Border Grid.Column="1" Background="#2A2A30" CornerRadius="6" Padding="6,3" Margin="4,0,0,0">
      <TextBox x:Name="DnsSec" Background="Transparent" BorderThickness="0" Foreground="#EEFFFFFF" FontSize="11"/>
    </Border>
  </Grid>
  <StackPanel Orientation="Horizontal" Margin="0,5,0,0">
    <Border x:Name="DnsCf" Background="#2E2E34" CornerRadius="6" Padding="8,3" Cursor="Hand" Margin="0,0,5,0"><TextBlock Text="Cloudflare" Foreground="#CCFFFFFF" FontSize="10"/></Border>
    <Border x:Name="DnsGg" Background="#2E2E34" CornerRadius="6" Padding="8,3" Cursor="Hand" Margin="0,0,5,0"><TextBlock Text="Google" Foreground="#CCFFFFFF" FontSize="10"/></Border>
    <Border x:Name="DnsQ9" Background="#2E2E34" CornerRadius="6" Padding="8,3" Cursor="Hand"><TextBlock Text="Quad9" Foreground="#CCFFFFFF" FontSize="10"/></Border>
  </StackPanel>
  <StackPanel Orientation="Horizontal" Margin="0,5,0,0">
    <Border x:Name="DnsApply" Background="#234254" CornerRadius="6" Padding="12,3" Cursor="Hand" Margin="0,0,5,0"><TextBlock x:Name="DnsApplyTxt" Text="Apply" Foreground="#4CC2FF" FontSize="11"/></Border>
    <Border x:Name="DnsAuto" Background="#2E2E34" CornerRadius="6" Padding="12,3" Cursor="Hand"><TextBlock x:Name="DnsAutoTxt" Text="Auto (DHCP)" Foreground="#CCFFFFFF" FontSize="11"/></Border>
  </StackPanel>
</StackPanel>
'@

function Show-SettingsWindow {
    $sw = [Windows.Markup.XamlReader]::Parse((Fill-Theme $SettingsXaml))
    $sw.Owner = $window

    # Окно настроек можно растягивать за края, как обычное окно Windows.
    # Стартовый размер вычисляем по содержимому — окно откроется таким же, как раньше.
    $sw.Measure([System.Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity))
    $sv = $sw.FindName('SBodyScroll')
    $script:SWChrome = $sw.DesiredSize.Height - $sv.DesiredSize.Height - $sv.Margin.Top
    if ($script:SWChrome -lt 50 -or $script:SWChrome -gt 300) { $script:SWChrome = 100 }
    $sw.Width  = if ($sw.DesiredSize.Width -gt 300) { $sw.DesiredSize.Width } else { 338 }
    $sw.Height = if ($sw.DesiredSize.Height -gt 200) { $sw.DesiredSize.Height } else { 530 }
    $sw.MinWidth  = 338
    $sw.MinHeight = 360
    # При изменении размера окна скроллер занимает всё свободное место по высоте
    $sw.Add_SizeChanged({ param($s, $e)
        $s.FindName('SBodyScroll').MaxHeight = [Math]::Max(100, $s.ActualHeight - $script:SWChrome)
    })
    # Прозрачное окно без рамки: края ведут себя как рамка обычного окна —
    # за них можно хвататься курсором и растягивать (см. Native.Resize).
    [Native.Resize]::Attach($sw)

    $sw.FindName('STitle').Text       = T 'set_title'
    $sw.FindName('SMetricsHdr').Text  = T 'set_header'
    $sw.FindName('SHelp').Text        = T 'set_help'
    $sw.FindName('SPrio').Text        = T 'set_priority'
    $sw.FindName('SSec').Text         = T 'set_secondary'
    $sw.FindName('SSaveTxt').Text     = T 'set_save'
    $sw.FindName('SLogsHdr').Text     = T 'set_sec_logs'
    $sw.FindName('LogLabel').Text     = T 'log_enable'
    $sw.FindName('LogFolderLbl').Text = T 'log_folder'
    $sw.FindName('LogBrowseTxt').Text = T 'rules_browse'
    $sw.FindName('LogShowTxt').Text    = T 'log_show'
    $sw.FindName('SAutoHdr').Text   = T 'set_sec_auto'
    $sw.FindName('AutoLabel').Text  = T 'autostart_enable'
    $sw.FindName('AutoNote').Text   = T 'autostart_note'
    $htb = $sw.FindName('HighTB'); $ltb = $sw.FindName('LowTB')
    $htb.Text = "$HighMetric"; $ltb.Text = "$LowMetric"
    $logChkMark = $sw.FindName('LogChkMark')
    $logPathTB  = $sw.FindName('LogPathTB')
    $logChkMark.Visibility = if ($script:Logging) { 'Visible' } else { 'Collapsed' }
    $logPathTB.Text = $script:LogPath
    $autoChkMark = $sw.FindName('AutoChkMark')
    $script:Autostart = Get-AutostartExists
    $autoChkMark.Visibility = if ($script:Autostart) { 'Visible' } else { 'Collapsed' }

    # Секция «Профили»
    $sw.FindName('SProfHdr').Text     = T 'set_sec_profiles'
    $sw.FindName('ProfSaveTxt').Text  = T 'prof_save'
    $sw.FindName('ProfApplyTxt').Text = T 'dns_apply'
    $sw.FindName('ProfSel').ToolTip   = T 'prof_pick'
    $profNameTB = $sw.FindName('ProfNameTB')
    $script:ProfSelTxt = $sw.FindName('ProfSelTxt')
    $profPopup = $sw.FindName('ProfPopup')
    $profListPanel = $sw.FindName('ProfListPanel')
    $profPopup.PlacementTarget = $sw.FindName('ProfSel')
    $script:Profiles = @(Get-Profiles)
    $script:ProfileIdx = 0
    Refresh-ProfileSelector
    # Нажатие «глушим» (чтобы окно не таскалось), список открываем по ОТПУСКАНИЮ —
    # иначе StaysOpen=False закрывает Popup сразу на mouse-up.
    $sw.FindName('ProfSel').Add_PreviewMouseLeftButtonDown({ param($s, $e) $e.Handled = $true })
    $sw.FindName('ProfSel').Add_PreviewMouseLeftButtonUp({ param($s, $e)
        $e.Handled = $true
        if ($profPopup.IsOpen) { $profPopup.IsOpen = $false; return }
        $profListPanel.Children.Clear()
        if (-not $script:Profiles.Count) { return }
        $bc = [Windows.Media.BrushConverter]::new()
        for ($i = 0; $i -lt $script:Profiles.Count; $i++) {
            $item = New-Object System.Windows.Controls.TextBlock
            $item.Text = $script:Profiles[$i].Name
            $item.Foreground = $bc.ConvertFromString((C '#EEFFFFFF'))
            $item.FontSize = 11
            $item.Padding = '8,4'
            $item.Cursor = 'Hand'
            $item.Tag = $i
            $item.Add_PreviewMouseLeftButtonUp({ param($a, $b)
                $b.Handled = $true
                $script:ProfileIdx = [int]$a.Tag
                Refresh-ProfileSelector
                $profPopup.IsOpen = $false
            })
            [void]$profListPanel.Children.Add($item)
        }
        $profPopup.IsOpen = $true
    })
    $sw.FindName('ProfSave').Add_PreviewMouseLeftButtonDown({ param($s, $e)
        $e.Handled = $true
        $nm = $profNameTB.Text.Trim()
        if (-not $nm) { [System.Windows.MessageBox]::Show((T 'prof_need_name'), 'LAN Switcher', 'OK', 'Warning') | Out-Null; return }
        $script:Profiles = @(@($script:Profiles) | Where-Object { $_.Name -ne $nm })
        $script:Profiles = @($script:Profiles) + (New-ProfileFromCurrent $nm)
        Save-Profiles
        $script:ProfileIdx = $script:Profiles.Count - 1
        Refresh-ProfileSelector
        $profNameTB.Text = ''
        Write-AppLog "Профиль сохранён: $nm"
    })
    $sw.FindName('ProfApply').Add_PreviewMouseLeftButtonDown({ param($s, $e)
        $e.Handled = $true
        if ($script:Profiles.Count) {
            Apply-Profile $script:Profiles[$script:ProfileIdx]
            $htb.Text = "$HighMetric"; $ltb.Text = "$LowMetric"
            Flash-Button $s
        }
    })
    $sw.FindName('ProfDel').Add_PreviewMouseLeftButtonDown({ param($s, $e)
        $e.Handled = $true
        if ($script:Profiles.Count) {
            $delName = $script:Profiles[$script:ProfileIdx].Name
            $script:Profiles = @(@($script:Profiles) | Where-Object { $_.Name -ne $delName })
            if ($script:ProfileIdx -ge $script:Profiles.Count) { $script:ProfileIdx = [Math]::Max(0, $script:Profiles.Count - 1) }
            Save-Profiles
            Refresh-ProfileSelector
            Write-AppLog "Профиль удалён: $delName"
        }
    })

    # Секция «Горячие клавиши»
    $sw.FindName('SHkHdr').Text  = T 'set_sec_hotkeys'
    $sw.FindName('SHkHint').Text = T 'hk_hint'
    $hkContainer = $sw.FindName('HotkeyContainer')
    $script:CapturingAction = $null
    $script:CaptureCombo = $null
    foreach ($a in @(@{ N = 'Toggle'; L = (T 'hk_toggle') }, @{ N = 'Left'; L = (T 'hk_left') }, @{ N = 'Right'; L = (T 'hk_right') }, @{ N = 'Auto'; L = (T 'hk_auto') })) {
        $row = [Windows.Markup.XamlReader]::Parse((Fill-Theme ($HotkeyRowTemplate -f ([System.Security.SecurityElement]::Escape($a.L)))))
        $combo = $row.FindName('HkCombo'); $setBtn = $row.FindName('HkSet'); $clrBtn = $row.FindName('HkClr')
        $row.FindName('HkSetTxt').Text = T 'hk_set'
        $cur = "$($script:Hotkeys[$a.N])"
        $combo.Text = if ($cur) { $cur } else { '—' }
        $ctx = [PSCustomObject]@{ Name = $a.N; Combo = $combo }
        $setBtn.Tag = $ctx; $clrBtn.Tag = $ctx
        $setBtn.Add_PreviewMouseLeftButtonDown({ param($s, $e)
            $e.Handled = $true
            $script:CapturingAction = $s.Tag.Name
            $script:CaptureCombo = $s.Tag.Combo
            Unregister-Hotkeys
            $s.Tag.Combo.Text = '...'
        })
        $clrBtn.Add_PreviewMouseLeftButtonDown({ param($s, $e)
            $e.Handled = $true
            $script:Hotkeys[$s.Tag.Name] = ''
            $s.Tag.Combo.Text = '—'
            Save-Config
            Register-Hotkeys
        })
        [void]$hkContainer.Children.Add($row)
    }
    $sw.Add_PreviewKeyDown({ param($s, $e)
        if (-not $script:CapturingAction) { return }
        $e.Handled = $true
        $key = if ($e.Key -eq [System.Windows.Input.Key]::System) { $e.SystemKey } else { $e.Key }
        if (@('LeftCtrl', 'RightCtrl', 'LeftAlt', 'RightAlt', 'LeftShift', 'RightShift', 'LWin', 'RWin') -contains "$key") { return }
        if ($key -eq [System.Windows.Input.Key]::Escape) {
            $c = "$($script:Hotkeys[$script:CapturingAction])"
            $script:CaptureCombo.Text = if ($c) { $c } else { '—' }
            $script:CapturingAction = $null; Register-Hotkeys; return
        }
        $m = [System.Windows.Input.Keyboard]::Modifiers
        $parts = @()
        if ($m.HasFlag([System.Windows.Input.ModifierKeys]::Control)) { $parts += 'Ctrl' }
        if ($m.HasFlag([System.Windows.Input.ModifierKeys]::Alt))     { $parts += 'Alt' }
        if ($m.HasFlag([System.Windows.Input.ModifierKeys]::Shift))   { $parts += 'Shift' }
        if ($parts.Count -eq 0) { return }   # нужна хотя бы одна модификатор-клавиша
        $parts += "$key"
        $combo = $parts -join '+'
        $script:Hotkeys[$script:CapturingAction] = $combo
        $script:CaptureCombo.Text = $combo
        $script:CapturingAction = $null
        Save-Config
        Register-Hotkeys
    })

    # DNS-строки по адаптерам (по одной на адаптер)
    $dnsContainer = $sw.FindName('DnsContainer')
    foreach ($alias in @($LeftAlias, $RightAlias)) {
        $disp = [System.Security.SecurityElement]::Escape((Get-AdapterDisplay $alias))
        $row = [Windows.Markup.XamlReader]::Parse((Fill-Theme ($DnsRowTemplate -f $disp)))
        $pri = $row.FindName('DnsPri'); $sec = $row.FindName('DnsSec')
        $row.FindName('DnsApplyTxt').Text = T 'dns_apply'
        $row.FindName('DnsAutoTxt').Text  = T 'dns_auto'
        $cur = @(Get-AdapterDns $alias)
        if ($cur.Count -ge 1) { $pri.Text = $cur[0] }
        if ($cur.Count -ge 2) { $sec.Text = $cur[1] }
        $ctx = [PSCustomObject]@{ Alias = $alias; Pri = $pri; Sec = $sec }
        foreach ($nm in 'DnsCf', 'DnsGg', 'DnsQ9', 'DnsApply', 'DnsAuto') { $row.FindName($nm).Tag = $ctx }
        $row.FindName('DnsCf').Add_PreviewMouseLeftButtonDown({ param($s, $e) $e.Handled = $true; $s.Tag.Pri.Text = '1.1.1.1'; $s.Tag.Sec.Text = '1.0.0.1' })
        $row.FindName('DnsGg').Add_PreviewMouseLeftButtonDown({ param($s, $e) $e.Handled = $true; $s.Tag.Pri.Text = '8.8.8.8'; $s.Tag.Sec.Text = '8.8.4.4' })
        $row.FindName('DnsQ9').Add_PreviewMouseLeftButtonDown({ param($s, $e) $e.Handled = $true; $s.Tag.Pri.Text = '9.9.9.9'; $s.Tag.Sec.Text = '149.112.112.112' })
        $row.FindName('DnsApply').Add_PreviewMouseLeftButtonDown({ param($s, $e) $e.Handled = $true; if (Apply-Dns $s.Tag.Alias $s.Tag.Pri.Text $s.Tag.Sec.Text) { Flash-Button $s } })
        $row.FindName('DnsAuto').Add_PreviewMouseLeftButtonDown({ param($s, $e) $e.Handled = $true; Reset-Dns $s.Tag.Alias; $s.Tag.Pri.Text = ''; $s.Tag.Sec.Text = '' })
        [void]$dnsContainer.Children.Add($row)
    }

    $sw.FindName('SClose').Add_PreviewMouseLeftButtonDown({ param($s, $e)
        $e.Handled = $true; [System.Windows.Window]::GetWindow($s).Close()
    })
    $sw.FindName('LogToggle').Add_PreviewMouseLeftButtonDown({ param($s, $e)
        $e.Handled = $true
        $script:Logging = -not $script:Logging
        $logChkMark.Visibility = if ($script:Logging) { 'Visible' } else { 'Collapsed' }
        Save-Config
        if ($script:Logging) { Write-AppLog 'Логирование включено' }
    })
    $sw.FindName('AutoToggle').Add_PreviewMouseLeftButtonDown({ param($s, $e)
        $e.Handled = $true
        if ($script:Autostart) {
            if (Disable-Autostart) { $script:Autostart = $false }
        } else {
            if (Enable-Autostart)  { $script:Autostart = $true }
        }
        $autoChkMark.Visibility = if ($script:Autostart) { 'Visible' } else { 'Collapsed' }
        Save-Config
    })
    $sw.FindName('LogBrowseBtn').Add_PreviewMouseLeftButtonDown({ param($s, $e)
        $e.Handled = $true
        Add-Type -AssemblyName System.Windows.Forms
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        if (Test-Path (Split-Path $script:LogPath)) { $dlg.SelectedPath = Split-Path $script:LogPath }
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $script:LogPath = Join-Path $dlg.SelectedPath 'lan-switcher.log'
            $logPathTB.Text = $script:LogPath
            Save-Config
        }
    })
    $sw.FindName('LogShowBtn').Add_PreviewMouseLeftButtonDown({ param($s, $e)
        $e.Handled = $true
        $folder = Split-Path $script:LogPath
        if (Test-Path $script:LogPath) {
            Start-Process explorer.exe -ArgumentList "/select,`"$($script:LogPath)`""
        } elseif (Test-Path $folder) {
            Start-Process explorer.exe -ArgumentList "`"$folder`""
        } else {
            [System.Windows.MessageBox]::Show($folder, 'LAN Switcher', 'OK', 'Information') | Out-Null
        }
    })
    $sw.FindName('SSave').Add_PreviewMouseLeftButtonDown({ param($s, $e)
        $e.Handled = $true
        $hi = 0; $lo = 0
        if (-not [int]::TryParse($htb.Text.Trim(), [ref]$hi) -or -not [int]::TryParse($ltb.Text.Trim(), [ref]$lo)) {
            [System.Windows.MessageBox]::Show((T 'set_int_err'), 'LAN Switcher', 'OK', 'Warning') | Out-Null; return
        }
        if ($hi -lt 1 -or $lo -lt 1 -or $hi -ge $lo) {
            [System.Windows.MessageBox]::Show((T 'set_range_err'),
                'LAN Switcher', 'OK', 'Warning') | Out-Null; return
        }
        $script:HighMetric = $hi; $script:LowMetric = $lo
        Save-Config
        Set-ActiveSide $script:Active   # применить новые метрики сразу
        Flash-Button $s
        $w = [System.Windows.Window]::GetWindow($s)
        $ct = [System.Windows.Threading.DispatcherTimer]::new()
        $ct.Interval = [TimeSpan]::FromMilliseconds(500)
        $ct.Add_Tick({ $ct.Stop(); $w.Close() }.GetNewClosure())
        $ct.Start()
    })
    $sw.Add_MouseLeftButtonDown({ param($s, $e) try { $s.DragMove() } catch { } })
    [void]$sw.ShowDialog()
}

# --- Следим за окном «Свойства адаптера»: выводим на передний план,
#     возвращаем виджету Topmost после закрытия диалога ---
$script:PropsTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:PropsTimer.Interval = [TimeSpan]::FromMilliseconds(300)
$script:PropsTimer.Add_Tick({
    $script:PropsTicks++
    $h = Find-WindowByTitle $script:PropsAlias
    if (-not $script:PropsFound) {
        # Ждём появления диалога (создаётся не мгновенно)
        if ($h) {
            $script:PropsFound = $true
            [void][Native.Props]::SetForegroundWindow($h)
            $script:PropsTicks = 0   # теперь ждём закрытия
        } elseif ($script:PropsTicks -ge 20) {
            # 6 секунд — окно не появилось: откат на папку сетевых подключений
            $script:PropsTimer.Stop()
            $window.Topmost = $true
            Start-Process 'control.exe' 'ncpa.cpl'
        }
    } else {
        if (-not $h) {
            # Диалог закрыли — возвращаем Topmost
            $script:PropsTimer.Stop()
            $window.Topmost = $true
        } elseif ($script:PropsTicks -ge 400) {
            # Открыт дольше 2 минут — не держим таймер вечно
            $script:PropsTimer.Stop()
            $window.Topmost = $true
        }
    }
})

# --- События ---
$Track.Add_PreviewMouseLeftButtonDown({ param($s, $e)
    $e.Handled = $true
    Set-ActiveSide $(if ($script:Active -eq 'Left') { 'Right' } else { 'Left' })
})
$LeftPanel.Add_PreviewMouseLeftButtonDown({ param($s, $e)
    $e.Handled = $true
    if (Test-ClickOn $e.OriginalSource $LeftPropsBtn) { Open-AdapterProperties $LeftAlias; return }
    Set-ActiveSide 'Left'
})
$RightPanel.Add_PreviewMouseLeftButtonDown({ param($s, $e)
    $e.Handled = $true
    if (Test-ClickOn $e.OriginalSource $RightPropsBtn) { Open-AdapterProperties $RightAlias; return }
    Set-ActiveSide 'Right'
})
$CloseBtn.Add_PreviewMouseLeftButtonDown({ param($s, $e)
    $e.Handled = $true; $window.Close()
})
$MenuBtn.Add_PreviewMouseLeftButtonDown({ param($s, $e)
    $e.Handled = $true; Show-RulesWindow
})
$GearBtn.Add_PreviewMouseLeftButtonDown({ param($s, $e)
    $e.Handled = $true; Show-SettingsWindow
})
$LangBtn.Add_PreviewMouseLeftButtonDown({ param($s, $e)
    $e.Handled = $true
    $i = [Array]::IndexOf($script:Langs, $script:Lang)
    $script:Lang = $script:Langs[($i + 1) % $script:Langs.Count]
    Save-Config
    Apply-MainLanguage
})
$BtnAuto.Add_PreviewMouseLeftButtonDown({ param($s, $e)
    $e.Handled = $true; Reset-AutoMetrics
})
$BtnDns.Add_PreviewMouseLeftButtonDown({ param($s, $e)
    $e.Handled = $true; Invoke-DnsFlush; Flash-Button $s '#C0392B'
})
$BtnReset.Add_PreviewMouseLeftButtonDown({ param($s, $e)
    $e.Handled = $true; Flash-Button $s '#C0392B'; Invoke-NetworkReset
})
$window.Add_MouseLeftButtonDown({ try { $window.DragMove() } catch { } })

# Позиция: правый нижний угол, над треем
$window.Add_ContentRendered({
    $wa = [System.Windows.SystemParameters]::WorkArea
    $window.Left = $wa.Right  - $window.ActualWidth  - 16
    $window.Top  = $wa.Bottom - $window.ActualHeight - 16
    if ($script:HotkeyHwnd -eq [IntPtr]::Zero) {
        $script:HotkeyHwnd = (New-Object System.Windows.Interop.WindowInteropHelper($window)).Handle
        try {
            $src = [System.Windows.Interop.HwndSource]::FromHwnd($script:HotkeyHwnd)
            if ($src) { $src.AddHook([System.Windows.Interop.HwndSourceHook]$script:HotkeyHook) }
        } catch { }
        Register-Hotkeys
    }
})

# --- Фоновая проверка интернета по каждому адаптеру ---
# Отдельный поток: TCP-коннект к 1.1.1.1:443 с привязкой сокета к IP адаптера
# (тот же приём, что в прокси). Результат кладётся в потокобезопасный $NetState,
# UI читает его мгновенно и не подвисает. Пул чистого .NET — без сетевых командлетов.
$netCheckScript = {
    param($aliases, $state)
    while ($true) {
        foreach ($alias in $aliases) {
            $r = @{ State = 'nolink'; Latency = $null }
            try {
                $nic = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
                       Where-Object { $_.Name -eq $alias -and $_.OperationalStatus -eq 'Up' } | Select-Object -First 1
                $ip = $null
                if ($nic) {
                    $ip = ($nic.GetIPProperties().UnicastAddresses |
                           Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' -and ($_.Address.ToString() -notlike '169.254.*') } |
                           Select-Object -First 1).Address.ToString()
                }
                if ($ip) {
                    $tcp = New-Object System.Net.Sockets.TcpClient
                    try {
                        $tcp.Client.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($ip), 0)))
                        $t0 = [System.Diagnostics.Stopwatch]::StartNew()
                        $iar = $tcp.BeginConnect('1.1.1.1', 443, $null, $null)
                        if ($iar.AsyncWaitHandle.WaitOne(1500)) {
                            $tcp.EndConnect($iar); $t0.Stop()
                            $ms = [int]$t0.ElapsedMilliseconds
                            $r.Latency = $ms
                            $r.State = if ($ms -lt 150) { 'ok' } else { 'slow' }
                        } else { $r.State = 'down' }
                    } catch { $r.State = 'down' } finally { $tcp.Close() }
                }
            } catch { $r.State = 'nolink' }
            $state[$alias] = $r
        }
        Start-Sleep -Seconds 4
    }
}
$script:NetRunspace = [runspacefactory]::CreateRunspace()
$script:NetRunspace.ApartmentState = 'MTA'
$script:NetRunspace.Open()
$script:NetPS = [powershell]::Create()
$script:NetPS.Runspace = $script:NetRunspace
[void]$script:NetPS.AddScript($netCheckScript).AddArgument(@($LeftAlias, $RightAlias)).AddArgument($script:NetState)
[void]$script:NetPS.BeginInvoke()

# --- Автообновление индикации (связь, трафик, IP, метрики) ---
$timer = [System.Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromSeconds(3)
$timer.Add_Tick({ Update-Indicators })
$timer.Start()

# --- Сворачивание в трей ---
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

function Show-Widget {
    $window.Visibility = 'Visible'
    $window.Topmost = $true
    $window.Activate()
}
function Hide-Widget {
    $window.Visibility = 'Hidden'
    try {
        $notify.ShowBalloonTip(2000, 'LAN Switcher', (T 'tray_balloon'),
            [System.Windows.Forms.ToolTipIcon]::Info)
    } catch { }
}

$IcoPath = Join-Path $ScriptDir 'LAN-Switcher.ico'
# Иконка окна (панель задач, Alt+Tab)
if (Test-Path $IcoPath) {
    try { $window.Icon = New-Object System.Windows.Media.Imaging.BitmapImage([Uri]$IcoPath) } catch { }
}
# Иконка трея: сперва из нашего .ico, иначе — из значка процесса
$trayIcon = $null
if (Test-Path $IcoPath) {
    try { $trayIcon = New-Object System.Drawing.Icon($IcoPath) } catch { }
}
if (-not $trayIcon) {
    $trayIcon = try {
        [System.Drawing.Icon]::ExtractAssociatedIcon(
            [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
    } catch { [System.Drawing.SystemIcons]::Application }
}

$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon = $trayIcon
$notify.Text = 'LAN Switcher'
$notify.Visible = $true
$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$script:MiShow = $trayMenu.Items.Add((T 'tray_show')); $script:MiShow.add_Click({ Show-Widget })
$script:MiExit = $trayMenu.Items.Add((T 'tray_exit')); $script:MiExit.add_Click({ $window.Close() })
$notify.ContextMenuStrip = $trayMenu
$notify.add_MouseDoubleClick({ Show-Widget })

$MinBtn.Add_PreviewMouseLeftButtonDown({ param($s, $e) $e.Handled = $true; Hide-Widget })

# --- Приложение с ручным завершением ---
# ВАЖНО: используем Application.Run + Show (не ShowDialog). У модального окна
# скрытие видимости завершает диалог и убивает процесс — поэтому свернуть в трей
# можно только через полноценный Application c ShutdownMode=OnExplicitShutdown.
$app = New-Object System.Windows.Application
$app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown

# --- Закрытие: гасим все прокси, убираем значок из трея, завершаем приложение ---
$window.Add_Closed({
    Unregister-Hotkeys
    Stop-AllProxies
    try { $script:NetPS.Stop(); $script:NetPS.Dispose(); $script:NetRunspace.Close() } catch { }
    try { $notify.Visible = $false; $notify.Dispose() } catch { }
    $app.Shutdown()
})

# --- Старт: определяем желаемый приоритет и ПРИНУДИТЕЛЬНО его применяем ---
# Так исключаем неоднозначное состояние после перезагрузки (например, 25/25):
# берём последний сохранённый выбор, иначе — текущий по метрикам, и утверждаем его.
$desired = $null
if ($script:SavedActiveAlias) {
    if     ($script:SavedActiveAlias -eq $LeftAlias)  { $desired = 'Left' }
    elseif ($script:SavedActiveAlias -eq $RightAlias) { $desired = 'Right' }
}
if (-not $desired) {
    $desired = if ((Get-Metric $LeftAlias) -le (Get-Metric $RightAlias)) { 'Left' } else { 'Right' }
}
$script:Active = $desired
Apply-MainLanguage        # применяем выбранный язык ко всем надписям окна
Set-ActiveSide $desired   # применяет метрики 25/9999 и обновляет UI детерминированно

[void]$app.Run($window)
