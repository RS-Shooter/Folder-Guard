@echo off
set "FL_BAT=%~f0"
set "FL_ARGS=%*"
powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "$t=[IO.File]::ReadAllText($env:FL_BAT,[Text.Encoding]::UTF8); iex ($t.Substring($t.IndexOf('#PS'+'_START#')+10))"
exit /b
#PS_START#
# File Locker: блокировка файлов и папок, пароль, окно, трей, автозапуск.
# Программа никогда не удаляет и не изменяет сами файлы: она только удерживает их открытыми.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class NativeLock {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
    // share = 0: никто другой не сможет открыть файл/папку, пока дескриптор открыт
    public static SafeFileHandle OpenExclusive(string path, bool dir, out int err) {
        SafeFileHandle h = CreateFileW(path, 0x80000000u, 0u, IntPtr.Zero, 3u, dir ? 0x02000000u : 0x80u, IntPtr.Zero);
        err = h.IsInvalid ? Marshal.GetLastWin32Error() : 0;
        return h;
    }
}
'@

$script:AppName  = 'FileLocker'
$script:cfgDir   = Join-Path $env:APPDATA $script:AppName
$script:cfg      = Join-Path $script:cfgDir 'locked.json'
$script:authFile = Join-Path $script:cfgDir 'auth.json'
$script:helper   = Join-Path $script:cfgDir 'autostart.ps1'
$script:runKey   = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$script:approvedKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
$script:bat      = $env:FL_BAT
$script:entries  = [ordered]@{}   # путь -> @{Handles; Skipped; IsDir; Locked}
$script:lbKeys   = @()
$script:quitting = $false
$script:authed   = $false
$script:asking   = $false
$script:authSalt = $null
$script:authHash = $null
$script:authStream = $null

if (-not (Test-Path $script:cfgDir)) { New-Item -ItemType Directory -Path $script:cfgDir | Out-Null }

# --- одна копия: повторный запуск просит первую копию показать окно ---
$script:showEvt = New-Object System.Threading.EventWaitHandle($false, 'AutoReset', 'Local\FileLockerBatShow')
$created = $false
$script:mutex = New-Object System.Threading.Mutex($true, 'Local\FileLockerBat', [ref]$created)
if (-not $created) { [void]$script:showEvt.Set(); return }

# ---------- вспомогательные окна ----------
function New-TopOwner {
    $o = New-Object Windows.Forms.Form
    $o.TopMost = $true
    $o.ShowInTaskbar = $false
    $o.FormBorderStyle = 'None'
    $o.StartPosition = 'Manual'
    $o.Location = New-Object Drawing.Point(-3000, -3000)
    $o.Size = New-Object Drawing.Size(1, 1)
    $o.Show()
    return $o
}

function Msg($text, $icon = 'Information') {
    $o = New-TopOwner
    [void][Windows.Forms.MessageBox]::Show($o, $text, 'File Locker', 'OK', $icon)
    $o.Dispose()
}

function Show-DialogTop($dlg) {
    $o = New-TopOwner
    try { return $dlg.ShowDialog($o) } finally { $o.Dispose() }
}

# ---------- иконка ----------
$bmp = New-Object Drawing.Bitmap 32, 32
$g = [Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = 'AntiAlias'
$pen = New-Object Drawing.Pen ([Drawing.Color]::DimGray), 3
$g.DrawArc($pen, 9, 3, 14, 14, 180, 180)
$g.DrawLine($pen, 9, 10, 9, 15)
$g.DrawLine($pen, 23, 10, 23, 15)
$g.FillRectangle((New-Object Drawing.SolidBrush ([Drawing.Color]::Goldenrod)), 6, 14, 20, 15)
$g.FillEllipse((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(51, 51, 51))), 14, 19, 4, 4)
$g.Dispose()
$script:icon = [Drawing.Icon]::FromHandle($bmp.GetHicon())

# ---------- пароль ----------
function Ask-Password($title, $prompt) {
    $f = New-Object Windows.Forms.Form
    $f.Text = $title
    $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox = $false
    $f.MinimizeBox = $false
    $f.StartPosition = 'CenterScreen'
    $f.TopMost = $true
    $f.Icon = $script:icon
    $f.ClientSize = New-Object Drawing.Size(330, 115)

    $l = New-Object Windows.Forms.Label
    $l.Text = $prompt
    $l.Location = New-Object Drawing.Point(12, 12)
    $l.AutoSize = $true
    $f.Controls.Add($l)

    $t = New-Object Windows.Forms.TextBox
    $t.Location = New-Object Drawing.Point(12, 38)
    $t.Width = 306
    $t.UseSystemPasswordChar = $true
    $f.Controls.Add($t)

    $ok = New-Object Windows.Forms.Button
    $ok.Text = 'OK'
    $ok.Location = New-Object Drawing.Point(160, 74)
    $ok.Size = New-Object Drawing.Size(75, 28)
    $ok.DialogResult = 'OK'
    $f.Controls.Add($ok)

    $cn = New-Object Windows.Forms.Button
    $cn.Text = 'Отмена'
    $cn.Location = New-Object Drawing.Point(243, 74)
    $cn.Size = New-Object Drawing.Size(75, 28)
    $cn.DialogResult = 'Cancel'
    $f.Controls.Add($cn)

    $f.AcceptButton = $ok
    $f.CancelButton = $cn
    $f.ActiveControl = $t

    $r = $f.ShowDialog()
    if ($r -eq 'OK') { $val = $t.Text } else { $val = $null }
    $f.Dispose()
    return $val
}

function Get-PwdHash($pwd, [byte[]]$salt) {
    $d = New-Object Security.Cryptography.Rfc2898DeriveBytes($pwd, $salt, 100000)
    return [Convert]::ToBase64String($d.GetBytes(32))
}

function Test-Password($pwd) {
    $calc = Get-PwdHash $pwd $script:authSalt
    return [string]::Equals($calc, $script:authHash, [StringComparison]::Ordinal)
}

function Save-Password($pwd) {
    if ($script:authStream) { $script:authStream.Close(); $script:authStream = $null }
    $salt = New-Object byte[] 16
    $rng = New-Object Security.Cryptography.RNGCryptoServiceProvider
    $rng.GetBytes($salt)
    $hash = Get-PwdHash $pwd $salt
    $json = ConvertTo-Json -InputObject @{ salt = [Convert]::ToBase64String($salt); hash = $hash }
    [IO.File]::WriteAllText($script:authFile, $json, [Text.Encoding]::UTF8)
    $script:authSalt = $salt
    $script:authHash = $hash
    # пока программа работает, файл с паролем нельзя изменить или удалить снаружи
    $script:authStream = [IO.File]::Open($script:authFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
}

function Load-Auth {
    try {
        $o = [IO.File]::ReadAllText($script:authFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $script:authSalt = [Convert]::FromBase64String($o.salt)
        $script:authHash = [string]$o.hash
        $script:authStream = [IO.File]::Open($script:authFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        return $true
    } catch { return $false }
}

function Read-NewPassword {
    while ($true) {
        $a = Ask-Password 'Новый пароль' 'Придумайте пароль (минимум 4 символа):'
        if ($null -eq $a) { return $null }
        if ($a.Length -lt 4) { Msg 'Пароль слишком короткий.' 'Warning'; continue }
        $b = Ask-Password 'Новый пароль' 'Повторите пароль:'
        if ($null -eq $b) { return $null }
        if (-not [string]::Equals($a, $b, [StringComparison]::Ordinal)) { Msg 'Пароли не совпадают.' 'Warning'; continue }
        return $a
    }
}

function Require-Auth {
    if ($script:authed) { return $true }
    if ($script:asking) { return $false }
    $script:asking = $true
    try {
        for ($i = 0; $i -lt 3; $i++) {
            $p = Ask-Password 'File Locker' 'Введите пароль:'
            if ($null -eq $p) { return $false }
            if (Test-Password $p) { $script:authed = $true; return $true }
            Start-Sleep -Milliseconds 800
            Msg 'Неверный пароль.' 'Error'
        }
        return $false
    } finally { $script:asking = $false }
}

function Change-Password {
    $old = Ask-Password 'Смена пароля' 'Текущий пароль:'
    if ($null -eq $old) { return }
    if (-not (Test-Password $old)) { Msg 'Неверный пароль.' 'Error'; return }
    $new = Read-NewPassword
    if ($null -eq $new) { return }
    Save-Password $new
    Msg 'Пароль изменён.'
}

# ---------- блокировка файлов и папок ----------
# Элементы остаются в списке и после разблокировки: меняется только состояние (Locked).
function Save-List {
    $arr = @()
    foreach ($k in $script:entries.Keys) {
        $arr += ,@{ path = $k; locked = [bool]$script:entries[$k].Locked }
    }
    $json = ConvertTo-Json -InputObject $arr
    [IO.File]::WriteAllText($script:cfg, $json, [Text.Encoding]::UTF8)
}

function Norm-Path($path) {
    $p = [IO.Path]::GetFullPath($path)
    if ($p.Length -gt 3) { $p = $p.TrimEnd('\') }
    return $p
}

function Add-Unlocked($path) {
    $p = Norm-Path $path
    if ($script:entries.Contains($p)) { return }
    $script:entries[$p] = @{
        Handles = (New-Object 'System.Collections.Generic.List[object]')
        Skipped = 0
        IsDir   = (Test-Path -LiteralPath $p -PathType Container)
        Locked  = $false
    }
}

function Lock-Path($path) {
    $p = Norm-Path $path
    if ($script:entries.Contains($p) -and $script:entries[$p].Locked) {
        return [pscustomobject]@{ Ok = $true; Msg = ''; Skipped = 0 }
    }
    $isDir = Test-Path -LiteralPath $p -PathType Container
    if (-not $isDir -and -not (Test-Path -LiteralPath $p -PathType Leaf)) {
        return [pscustomobject]@{ Ok = $false; Msg = 'не найден'; Skipped = 0 }
    }

    $list = New-Object 'System.Collections.Generic.List[object]'
    $err = 0
    $h = [NativeLock]::OpenExclusive($p, $isDir, [ref]$err)
    if ($h.IsInvalid) {
        $m = (New-Object ComponentModel.Win32Exception($err)).Message
        return [pscustomobject]@{ Ok = $false; Msg = $m; Skipped = 0 }
    }
    $list.Add($h)

    $skipped = 0
    if ($isDir) {
        $items = Get-ChildItem -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
        foreach ($it in $items) {
            if ($it.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            $h2 = [NativeLock]::OpenExclusive($it.FullName, $it.PSIsContainer, [ref]$err)
            if ($h2.IsInvalid) { $skipped++ } else { $list.Add($h2) }
        }
    }
    $script:entries[$p] = @{ Handles = $list; Skipped = $skipped; IsDir = $isDir; Locked = $true }
    Save-List
    return [pscustomobject]@{ Ok = $true; Msg = ''; Skipped = $skipped }
}

function Release-Handles($p) {
    $e = $script:entries[$p]
    foreach ($h in $e.Handles) { $h.Dispose() }
    $e.Handles.Clear()
}

# Разблокировать: дескрипторы закрываются, файл НЕ удаляется, запись остаётся в списке
function Unlock-Entry($p) {
    if (-not $script:entries.Contains($p)) { return }
    Release-Handles $p
    $script:entries[$p].Locked = $false
    $script:entries[$p].Skipped = 0
    Save-List
}

function Remove-Entry($p) {
    if (-not $script:entries.Contains($p)) { return }
    Release-Handles $p
    $script:entries.Remove($p)
    Save-List
}

function Unlock-All {
    foreach ($k in @($script:entries.Keys)) { Unlock-Entry $k }
}

function Lock-All {
    $failed = @(); $skipped = 0
    foreach ($k in @($script:entries.Keys)) {
        $r = Lock-Path $k
        if (-not $r.Ok) { $failed += "$k  ($($r.Msg))" }
        $skipped += $r.Skipped
    }
    return [pscustomobject]@{ Failed = $failed; Skipped = $skipped }
}

# ---------- автозапуск ----------
# В реестр (Run) пишется короткая команда запуска PowerShell со вспомогательным скриптом
# autostart.ps1 в %APPDATA%\FileLocker. Он запускает этот .bat в режиме трея.
function Get-Autostart {
    return ($null -ne (Get-ItemProperty -Path $script:runKey -Name $script:AppName -ErrorAction SilentlyContinue))
}

function Set-Autostart($on) {
    if ($on) {
        if (-not $script:bat -or -not (Test-Path -LiteralPath $script:bat)) {
            throw 'не найден путь к file_locker.bat'
        }
        $q = $script:bat.Replace("'", "''")
        $tpl = @'
$env:FL_BAT = '{0}'
$env:FL_ARGS = '--tray'
$t = [IO.File]::ReadAllText($env:FL_BAT, [Text.Encoding]::UTF8)
iex ($t.Substring($t.IndexOf('#PS' + '_START#') + 10))
'@
        [IO.File]::WriteAllText($script:helper, ($tpl -f $q), (New-Object Text.UTF8Encoding($true)))

        $cmd = 'powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $script:helper
        if (-not (Test-Path $script:runKey)) { New-Item -Path $script:runKey -Force | Out-Null }
        Set-ItemProperty -Path $script:runKey -Name $script:AppName -Value $cmd -Type String
        # если запись когда-то отключали в «Автозагрузке» диспетчера задач, снимаем этот запрет
        Remove-ItemProperty -Path $script:approvedKey -Name $script:AppName -ErrorAction SilentlyContinue

        $back = (Get-ItemProperty -Path $script:runKey -Name $script:AppName -ErrorAction Stop).($script:AppName)
        if ($back -ne $cmd) { throw 'запись в реестре не сохранилась' }
    } else {
        Remove-ItemProperty -Path $script:runKey -Name $script:AppName -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:helper -Force -ErrorAction SilentlyContinue
    }
}

# ---------- главное окно ----------
$script:form = New-Object Windows.Forms.Form
$form = $script:form
$form.Text = 'File Locker'
$form.Icon = $script:icon
$form.ClientSize = New-Object Drawing.Size(560, 480)
$form.MinimumSize = New-Object Drawing.Size(580, 520)
$form.StartPosition = 'CenterScreen'

$lbl = New-Object Windows.Forms.Label
$lbl.Text = 'Файлы и папки:'
$lbl.Location = New-Object Drawing.Point(10, 8)
$lbl.AutoSize = $true
$form.Controls.Add($lbl)

$script:lb = New-Object Windows.Forms.ListBox
$script:lb.Location = New-Object Drawing.Point(10, 30)
$script:lb.Size = New-Object Drawing.Size(540, 270)
$script:lb.SelectionMode = 'MultiExtended'
$script:lb.HorizontalScrollbar = $true
$script:lb.Anchor = 'Top,Bottom,Left,Right'
$form.Controls.Add($script:lb)

function New-Button($text, $x, $y, $w) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $text
    $b.Location = New-Object Drawing.Point($x, $y)
    $b.Size = New-Object Drawing.Size($w, 30)
    $b.Anchor = 'Bottom,Left'
    $form.Controls.Add($b)
    return $b
}
$btnAdd    = New-Button 'Добавить файлы…'         10  310 170
$btnDir    = New-Button 'Добавить папку…'         190 310 170
$btnPwd    = New-Button 'Сменить пароль'          370 310 170
$btnUnlSel = New-Button 'Разблокировать выбранные' 10  347 170
$btnLckSel = New-Button 'Заблокировать выбранные'  190 347 170
$btnRemove = New-Button 'Убрать из списка'        370 347 170
$btnUnlAll = New-Button 'Разблокировать все'      10  384 265
$btnLckAll = New-Button 'Заблокировать все'       275 384 265

$script:chk = New-Object Windows.Forms.CheckBox
$script:chk.Text = 'Запускать вместе с Windows (в трее)'
$script:chk.Location = New-Object Drawing.Point(10, 427)
$script:chk.AutoSize = $true
$script:chk.Anchor = 'Bottom,Left'
$form.Controls.Add($script:chk)

$script:status = New-Object Windows.Forms.Label
$script:status.Location = New-Object Drawing.Point(10, 452)
$script:status.AutoSize = $true
$script:status.ForeColor = [Drawing.Color]::Gray
$script:status.Anchor = 'Bottom,Left'
$form.Controls.Add($script:status)

function Refresh-UI {
    $script:lb.Items.Clear()
    $script:lbKeys = @($script:entries.Keys)
    $locked = 0
    foreach ($k in $script:lbKeys) {
        $e = $script:entries[$k]
        if ($e.Locked) { $state = 'ЗАБЛОКИРОВАН'; $locked++ } else { $state = 'разблокирован' }
        if ($e.IsDir) { $kind = '(папка) ' } else { $kind = '' }
        [void]$script:lb.Items.Add("[$state] $kind$k")
    }
    $script:chk.Checked = (Get-Autostart)
    $script:status.Text = "Заблокировано: $locked из $($script:entries.Count). Закрытие окна сворачивает программу в трей."
}

function Get-SelectedKeys {
    $r = @()
    foreach ($i in $script:lb.SelectedIndices) { $r += $script:lbKeys[$i] }
    return $r
}

function Show-Form {
    $script:form.Show()
    $script:form.WindowState = 'Normal'
    $script:form.Activate()
}

function Hide-Form {
    $script:form.Hide()
    $script:authed = $false   # после сворачивания пароль нужен снова
}

function Open-Window {
    if (Require-Auth) { Show-Form }
}

function Report-Results($failed, $skippedTotal) {
    $text = ''
    if ($failed.Count -gt 0) {
        $text += "Не удалось заблокировать:`n`n" + ($failed -join "`n")
    }
    if ($skippedTotal -gt 0) {
        if ($text) { $text += "`n`n" }
        $text += "В папках пропущено файлов (заняты другой программой или нет прав): $skippedTotal"
    }
    if ($text) { Msg $text 'Warning' }
}

function Add-Files {
    Show-Form
    $dlg = New-Object Windows.Forms.OpenFileDialog
    $dlg.Multiselect = $true
    $dlg.CheckFileExists = $true
    $dlg.Title = 'Выберите файлы для блокировки'
    if ((Show-DialogTop $dlg) -eq 'OK') {
        $failed = @(); $skipped = 0
        foreach ($f in $dlg.FileNames) {
            $r = Lock-Path $f
            if (-not $r.Ok) { $failed += "$f  ($($r.Msg))" }
            $skipped += $r.Skipped
        }
        Refresh-UI
        Report-Results $failed $skipped
    }
}

function Add-Folder {
    Show-Form
    $dlg = New-Object Windows.Forms.FolderBrowserDialog
    $dlg.Description = 'Выберите папку для блокировки (вместе со всем содержимым)'
    $dlg.ShowNewFolderButton = $false
    if ((Show-DialogTop $dlg) -eq 'OK') {
        $r = Lock-Path $dlg.SelectedPath
        Refresh-UI
        $failed = @()
        if (-not $r.Ok) { $failed += "$($dlg.SelectedPath)  ($($r.Msg))" }
        Report-Results $failed $r.Skipped
    }
}

function Toggle-Autostart($on) {
    try {
        Set-Autostart $on
        if ($on) { Msg 'Автозапуск включён: программа будет запускаться в трее при входе в Windows.' }
        else     { Msg 'Автозапуск выключен.' }
    } catch {
        Msg "Не удалось изменить автозапуск:`n$_" 'Error'
    }
    Refresh-UI
}

function Quit-App {
    $script:quitting = $true
    # дескрипторы закрываются, но файл списка не меняется: при следующем запуске всё вернётся как было
    foreach ($k in @($script:entries.Keys)) { Release-Handles $k }
    $script:timer.Stop()
    $script:notify.Visible = $false
    $script:notify.Dispose()
    if ($script:authStream) { $script:authStream.Close() }
    $script:ctx.ExitThread()
}

$btnAdd.Add_Click({ Add-Files })
$btnDir.Add_Click({ Add-Folder })
$btnPwd.Add_Click({ Change-Password })
$btnUnlSel.Add_Click({
    foreach ($k in @(Get-SelectedKeys)) { Unlock-Entry $k }
    Refresh-UI
})
$btnLckSel.Add_Click({
    $failed = @(); $skipped = 0
    foreach ($k in @(Get-SelectedKeys)) {
        $r = Lock-Path $k
        if (-not $r.Ok) { $failed += "$k  ($($r.Msg))" }
        $skipped += $r.Skipped
    }
    Refresh-UI
    Report-Results $failed $skipped
})
$btnRemove.Add_Click({
    foreach ($k in @(Get-SelectedKeys)) { Remove-Entry $k }
    Refresh-UI
})
$btnUnlAll.Add_Click({ Unlock-All; Refresh-UI })
$btnLckAll.Add_Click({
    $r = Lock-All
    Refresh-UI
    Report-Results $r.Failed $r.Skipped
})
$script:chk.Add_Click({ Toggle-Autostart $script:chk.Checked })
$form.Add_FormClosing({
    param($s, $e)
    if ($e.CloseReason -eq 'UserClosing' -and -not $script:quitting) {
        $e.Cancel = $true
        Hide-Form
    }
})

# ---------- трей (все действия требуют пароль) ----------
$menu = New-Object Windows.Forms.ContextMenuStrip
$miOpen = $menu.Items.Add('Открыть окно');         $miOpen.Add_Click({ Open-Window })
$miAdd  = $menu.Items.Add('Заблокировать файлы…'); $miAdd.Add_Click({ if (Require-Auth) { Add-Files } })
$miDir  = $menu.Items.Add('Заблокировать папку…'); $miDir.Add_Click({ if (Require-Auth) { Add-Folder } })
$miLAll = $menu.Items.Add('Заблокировать все');    $miLAll.Add_Click({ if (Require-Auth) { $r = Lock-All; Refresh-UI; Report-Results $r.Failed $r.Skipped } })
$miUAll = $menu.Items.Add('Разблокировать все');   $miUAll.Add_Click({ if (Require-Auth) { Unlock-All; Refresh-UI } })
$script:miAuto = New-Object Windows.Forms.ToolStripMenuItem 'Автозапуск'
$script:miAuto.Add_Click({ if (Require-Auth) { Toggle-Autostart (-not (Get-Autostart)) } })
[void]$menu.Items.Add($script:miAuto)
[void]$menu.Items.Add('-')
$miExit = $menu.Items.Add('Выход');                $miExit.Add_Click({ if (Require-Auth) { Quit-App } })
$menu.Add_Opening({ $script:miAuto.Checked = (Get-Autostart) })

$script:notify = New-Object Windows.Forms.NotifyIcon
$script:notify.Icon = $script:icon
$script:notify.Text = 'File Locker'
$script:notify.ContextMenuStrip = $menu
$script:notify.Add_DoubleClick({ Open-Window })

# повторный запуск .bat -> первая копия просит пароль и показывает окно
$script:timer = New-Object Windows.Forms.Timer
$script:timer.Interval = 400
$script:timer.Add_Tick({ if ($script:showEvt.WaitOne(0)) { Open-Window } })

# ---------- запуск ----------
$isTray = ("$env:FL_ARGS" -match '--tray')

if (Test-Path $script:authFile) { $haveAuth = Load-Auth } else { $haveAuth = $false }
if (-not $haveAuth) {
    Msg 'Первый запуск: задайте пароль. Он будет нужен для открытия программы, снятия блокировок и выхода.'
    $pw = Read-NewPassword
    if ($null -eq $pw) { return }
    Save-Password $pw
    $script:authed = $true
}

if (-not $isTray) {
    if (-not (Require-Auth)) { return }
}

# если автозапуск включён, обновляем запись (на случай, если .bat переместили)
if (Get-Autostart) { try { Set-Autostart $true } catch {} }

# восстановить список; заблокированные ранее элементы блокируются снова
if (Test-Path $script:cfg) {
    try {
        $saved = @(ConvertFrom-Json ([IO.File]::ReadAllText($script:cfg, [Text.Encoding]::UTF8)))
        foreach ($it in $saved) {
            if ($it -is [string]) { $p = $it; $lk = $true }
            else { $p = $it.path; $lk = [bool]$it.locked }
            if (-not $p) { continue }
            if (-not (Test-Path -LiteralPath $p)) { continue }
            if ($lk) { [void](Lock-Path $p) } else { Add-Unlocked $p }
        }
    } catch {}
}

# при автозапуске ждём, пока загрузится рабочий стол, чтобы иконка в трее появилась
if ($isTray) {
    for ($i = 0; $i -lt 30; $i++) {
        if (Get-Process -Name explorer -ErrorAction SilentlyContinue) { break }
        Start-Sleep -Seconds 2
    }
    Start-Sleep -Seconds 2
}

$script:notify.Visible = $true
Refresh-UI
$script:ctx = New-Object Windows.Forms.ApplicationContext
$script:timer.Start()
if (-not $isTray) { Show-Form } else { $script:authed = $false }
[Windows.Forms.Application]::Run($script:ctx)
