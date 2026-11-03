#Requires -Version 5.1
<#
  Build.ps1 — пересборка LAN-Switcher.exe из исходника LAN-Switcher.ps1.
  Запуск: двойной клик по Build.bat (или: powershell -File Build.ps1).
  Прав администратора НЕ требует. Перед сборкой закрой виджет (в трее «Выход»).
#>
$ErrorActionPreference = 'Stop'
$dir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$src = Join-Path $dir 'LAN-Switcher.ps1'
$exe = Join-Path $dir 'LAN-Switcher.exe'
$ico = Join-Path $dir 'LAN-Switcher.ico'

function Say($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }

function Build-Icon($out) {
    Add-Type -AssemblyName System.Drawing
    $bmp = New-Object System.Drawing.Bitmap(256, 256, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.Clear([System.Drawing.Color]::Transparent)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $x = 8; $y = 8; $w = 240; $h = 240; $d = 104
    $path.AddArc($x, $y, $d, $d, 180, 90)
    $path.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $path.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $path.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    $g.FillPath((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 31, 31, 35))), $path)
    $g.DrawPath((New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(60, 255, 255, 255), 3)), $path)
    $penTop = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 76, 194, 255), 22)
    $penTop.StartCap = 'Round'; $penTop.EndCap = 'Round'
    $penTop.CustomEndCap = New-Object System.Drawing.Drawing2D.AdjustableArrowCap(2.2, 2.4)
    $g.DrawLine($penTop, 70, 100, 180, 100)
    $penBot = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 120, 150, 170), 22)
    $penBot.StartCap = 'Round'; $penBot.EndCap = 'Round'
    $penBot.CustomEndCap = New-Object System.Drawing.Drawing2D.AdjustableArrowCap(2.2, 2.4)
    $g.DrawLine($penBot, 186, 156, 76, 156)
    $g.Dispose()
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $png = $ms.ToArray(); $ms.Dispose(); $bmp.Dispose()
    $fs = [System.IO.File]::Create($out)
    $bw = New-Object System.IO.BinaryWriter($fs)
    $bw.Write([UInt16]0); $bw.Write([UInt16]1); $bw.Write([UInt16]1)
    $bw.Write([Byte]0); $bw.Write([Byte]0); $bw.Write([Byte]0); $bw.Write([Byte]0)
    $bw.Write([UInt16]1); $bw.Write([UInt16]32)
    $bw.Write([UInt32]$png.Length); $bw.Write([UInt32]22); $bw.Write($png)
    $bw.Flush(); $fs.Close()
}

Say '=== Сборка LAN-Switcher.exe ===' 'Cyan'

# 1. Синтаксис исходника
if (-not (Test-Path $src)) { Say "Нет файла: $src" 'Red'; exit 1 }
$e = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($src, [ref]$null, [ref]$e)
if ($e) {
    Say '[1/5] Ошибки синтаксиса:' 'Red'
    $e | ForEach-Object { Say "     $($_.Message) @ строка $($_.Extent.StartLineNumber)" 'Red' }
    exit 1
}
Say '[1/5] Синтаксис OK' 'Green'

# 2. ps2exe
if (-not (Get-Module -ListAvailable ps2exe)) {
    Say '[2/5] Ставлю ps2exe...' 'Yellow'
    Install-Module ps2exe -Scope CurrentUser -Force
} else { Say '[2/5] ps2exe на месте' 'Green' }
Import-Module ps2exe

# 3. Иконка (создаём, если удалили)
if (-not (Test-Path $ico)) { Say '[3/5] Генерирую иконку...' 'Yellow'; Build-Icon $ico }
else { Say '[3/5] Иконка на месте' 'Green' }

# 4. Закрыть запущенный экземпляр (иначе файл занят)
$run = Get-Process -Name 'LAN-Switcher' -ErrorAction SilentlyContinue
if ($run) {
    Say '[4/5] Закрываю запущенный LAN-Switcher.exe...' 'Yellow'
    try { $run | Stop-Process -Force -ErrorAction Stop; Start-Sleep 1 }
    catch { Say '     Не удалось закрыть (запущен от админа). Закрой виджет вручную — «Выход» в трее — и запусти сборку снова.' 'Red'; exit 1 }
} else { Say '[4/5] Запущенных экземпляров нет' 'Green' }

# 5. Компиляция
Say '[5/5] Компилирую...' 'Yellow'
try {
    Invoke-ps2exe -inputFile $src -outputFile $exe -iconFile $ico -noConsole -requireAdmin -STA `
        -title 'LAN Switcher' -product 'LAN Switcher' -company 'LAN Switcher' `
        -version '1.0.0.0' -description 'LAN Switcher - переключатель сетевых адаптеров' | Out-Null
} catch {
    Say "Ошибка компиляции: $($_.Exception.Message)" 'Red'
    Say '(Если файл занят — закрой виджет и повтори.)' 'Red'
    exit 1
}

if (Test-Path $exe) {
    Say ""
    Say "ГОТОВО: LAN-Switcher.exe ($([math]::Round((Get-Item $exe).Length/1KB)) KB)" 'Green'
    Say "Запускай двойным кликом по LAN-Switcher.exe" 'Cyan'
} else { Say 'Ошибка: exe не создан' 'Red'; exit 1 }
