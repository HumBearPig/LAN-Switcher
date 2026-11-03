<#
  LAN Switcher — прокси-движок.
  Крошечный локальный HTTP/HTTPS(CONNECT) прокси. Слушает 127.0.0.1:<порт>
  и весь исходящий трафик отправляет с привязкой к IP конкретного адаптера
  (Socket.Bind), поэтому Windows гонит его строго через нужную сетевую.
  Запускается виджетом как отдельный процесс; гасится закрытием виджета.

  Запуск вручную (для теста):
    powershell -NoProfile -File LAN-Switcher-Proxy.ps1 -ListenPort 13128 -BindIP 192.168.50.26
#>
param(
    [Parameter(Mandatory)][int]$ListenPort,
    [Parameter(Mandatory)][string]$BindIP,
    [string]$LogFile
)

$ErrorActionPreference = 'Stop'

function Write-Log($msg) {
    if ($LogFile) {
        try { "$([DateTime]::Now.ToString('HH:mm:ss')) $msg" | Add-Content -Path $LogFile -Encoding UTF8 } catch { }
    }
}

# Обработчик одного клиентского соединения (выполняется в отдельном runspace)
$handler = {
    param($client, $bindIP, $logFile)

    function LogH($m) {
        if ($logFile) { try { "$([DateTime]::Now.ToString('HH:mm:ss')) [h] $m" | Add-Content -Path $logFile -Encoding UTF8 } catch { } }
    }

    function New-BoundConnection($targetHost, $targetPort, $bindIP) {
        $ips = [System.Net.Dns]::GetHostAddresses($targetHost) |
               Where-Object { $_.AddressFamily -eq 'InterNetwork' }
        if (-not $ips) { return $null }
        $srv = New-Object System.Net.Sockets.TcpClient
        $srv.NoDelay = $true
        # Ключевой момент: привязываем исходящий сокет к IP нужного адаптера
        $srv.Client.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($bindIP), 0)))
        $srv.Connect($ips[0], $targetPort)
        return $srv
    }

    function Relay($a, $b) {
        # Двунаправленная перекачка байтов, пока одна из сторон не закроется
        try {
            $t1 = $a.CopyToAsync($b)
            $t2 = $b.CopyToAsync($a)
            [System.Threading.Tasks.Task]::WaitAny(@($t1, $t2)) | Out-Null
        } catch { }
    }

    $srv = $null
    try {
        $client.NoDelay = $true
        $client.ReceiveTimeout = 20000
        $cs = $client.GetStream()

        # Читаем блок заголовков до пустой строки (CRLF CRLF)
        $bytes = New-Object System.Collections.Generic.List[byte]
        while ($true) {
            $bb = $cs.ReadByte()
            if ($bb -lt 0) { break }
            $bytes.Add([byte]$bb)
            $n = $bytes.Count
            if ($n -ge 4 -and $bytes[$n-4] -eq 13 -and $bytes[$n-3] -eq 10 -and $bytes[$n-2] -eq 13 -and $bytes[$n-1] -eq 10) { break }
            if ($n -gt 65536) { return }
        }
        if ($bytes.Count -eq 0) { return }

        $headerText = [System.Text.Encoding]::ASCII.GetString($bytes.ToArray())
        $lines = $headerText -split "`r`n"
        $parts = $lines[0] -split ' '
        if ($parts.Count -lt 2) { return }
        $method = $parts[0]
        $target = $parts[1]
        $ver = if ($parts.Count -ge 3) { $parts[2] } else { 'HTTP/1.1' }

        if ($method -eq 'CONNECT') {
            # HTTPS: host:port, открываем туннель и релеим вслепую
            $hp = $target -split ':'
            $th = $hp[0]
            $tp = if ($hp.Count -ge 2) { [int]$hp[1] } else { 443 }
            $srv = New-BoundConnection $th $tp $bindIP
            if (-not $srv) { return }
            $ok = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 Connection established`r`n`r`n")
            $cs.Write($ok, 0, $ok.Length); $cs.Flush()
            $client.ReceiveTimeout = 0
            Relay $cs ($srv.GetStream())
        }
        else {
            # Обычный HTTP: цель в absolute-form (GET http://host/path)
            try { $uri = [System.Uri]$target } catch { return }
            $th = $uri.Host
            $tp = if ($uri.Port -gt 0) { $uri.Port } else { 80 }
            $pathq = $uri.PathAndQuery
            if ([string]::IsNullOrEmpty($pathq)) { $pathq = '/' }
            $srv = New-BoundConnection $th $tp $bindIP
            if (-not $srv) { return }
            $ss = $srv.GetStream()
            # Пересобираем запрос в origin-form, убираем proxy-заголовки, форсим close
            $newLines = New-Object System.Collections.Generic.List[string]
            $newLines.Add("$method $pathq $ver")
            for ($i = 1; $i -lt $lines.Count; $i++) {
                $ln = $lines[$i]
                if ($ln -eq '') { continue }
                if ($ln -match '^\s*Proxy-Connection\s*:') { continue }
                if ($ln -match '^\s*Connection\s*:') { continue }
                $newLines.Add($ln)
            }
            $newLines.Add('Connection: close')
            $reqText = ($newLines -join "`r`n") + "`r`n`r`n"
            $rb = [System.Text.Encoding]::ASCII.GetBytes($reqText)
            $ss.Write($rb, 0, $rb.Length); $ss.Flush()
            $client.ReceiveTimeout = 0
            Relay $cs $ss
        }
    } catch {
        LogH "err: $($_.Exception.Message)"
    } finally {
        if ($srv) { try { $srv.Close() } catch { } }
        try { $client.Close() } catch { }
    }
}

# ---- Главный цикл: принимаем соединения, раздаём по runspace-пулу ----
$pool = [runspacefactory]::CreateRunspacePool(1, 100)
$pool.Open()
$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $ListenPort)
$listener.Start()
Write-Log "listen 127.0.0.1:$ListenPort -> bind $BindIP"

$running = New-Object System.Collections.ArrayList
try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($handler).AddArgument($client).AddArgument($BindIP).AddArgument($LogFile)
        $h = $ps.BeginInvoke()
        [void]$running.Add([pscustomobject]@{ PS = $ps; H = $h })
        # Чистим завершённые обработчики, чтобы не копить объекты
        for ($i = $running.Count - 1; $i -ge 0; $i--) {
            if ($running[$i].H.IsCompleted) {
                try { $running[$i].PS.EndInvoke($running[$i].H) } catch { }
                try { $running[$i].PS.Dispose() } catch { }
                $running.RemoveAt($i)
            }
        }
    }
} finally {
    try { $listener.Stop() } catch { }
    try { $pool.Close() } catch { }
}
