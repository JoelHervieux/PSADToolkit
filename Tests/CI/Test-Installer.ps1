<#
    Test d integration du programme d installation, sur une machine Windows jetable
    (pipeline .github/workflows/windows.yml). Execute par Windows PowerShell 5.1 :
    PowerShell 7 peut avoir ete desinstalle juste avant, pour eprouver son
    installation par le programme.

    Installe en silence, verifie les fichiers, PowerShell 7, GliderUI pour tous les
    utilisateurs et le journal ; relance le lanceur ; parcourt l interface
    installee avec l annuaire simule ; ouvre PSADToolkit.exe et controle que
    l interface demarre ; desinstalle et verifie le nettoyage.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Setup,
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$OutputFolder,
    [switch]$ExpectPowerShellInstall
)
$ErrorActionPreference = 'Stop'
$null = New-Item -ItemType Directory -Force -Path $OutputFolder
$app = Join-Path $env:ProgramFiles 'PSADToolkit'
$failures = New-Object System.Collections.ArrayList

function Test-Step {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) { Write-Output ('[OK]    ' + $Name + $(if ($Detail) { ' : ' + $Detail } else { '' })) }
    else {
        Write-Output ('[ECHEC] ' + $Name + $(if ($Detail) { ' : ' + $Detail } else { '' }))
        [void]$failures.Add($Name)
    }
}

function Save-Screen {
    param([string]$Name)
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $bitmap = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
        $bitmap.Save((Join-Path $OutputFolder ($Name + '.png')), [System.Drawing.Imaging.ImageFormat]::Png)
        $graphics.Dispose(); $bitmap.Dispose()
    } catch { Write-Output ('Capture impossible : ' + $_.Exception.Message) }
}

. (Join-Path $Repository 'Tools\ADTDependency.ps1')
$before = @(Get-ADTPowerShellInstall)
Write-Output ('PowerShell 7 avant installation : ' + $(if ($before.Count) { ($before | ForEach-Object { [string]$_.Version + ' ' + $_.Path }) -join ' ; ' } else { 'aucun' }))
if ($ExpectPowerShellInstall) { Test-Step 'Poste sans PowerShell 7' (-not $before.Count) }

# --- Installation silencieuse ---------------------------------------------------
$log = Join-Path $OutputFolder 'setup.log'
$started = Get-Date
$process = Start-Process -FilePath $Setup -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', ('/LOG="' + $log + '"') -Wait -PassThru
Test-Step 'Programme d installation' ($process.ExitCode -eq 0) ('code {0}, {1:N0} s' -f $process.ExitCode, ((Get-Date) - $started).TotalSeconds)

foreach ($relative in @('PSADToolkit.exe', 'Launcher.ps1', 'Launcher.settings.psd1', 'Start-PSADToolkit.ps1', 'PSADToolkit.psd1',
        'UI\Console.ps1', 'Tools\Initialize-ADTEnvironment.ps1', 'installer\PSADToolkit.ico', 'LICENSE', 'unins000.exe')) {
    Test-Step ('Fichier ' + $relative) (Test-Path -LiteralPath (Join-Path $app $relative))
}
Test-Step 'Prerequis livres' (@(Get-ChildItem -LiteralPath (Join-Path $app 'prereq') -ErrorAction SilentlyContinue).Count -ge 3)
Test-Step 'Tests absents de l installation' (-not (Test-Path -LiteralPath (Join-Path $app 'Tests')))
$shortcut = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\PSADToolkit.lnk'
Test-Step 'Raccourci du menu Demarrer' (Test-Path -LiteralPath $shortcut)
$version = [System.Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $app 'PSADToolkit.exe'))
Write-Output ('PSADToolkit.exe : ' + $version.ProductVersion)

$installLog = Join-Path $env:ProgramData 'PSADToolkit\Logs\install.log'
if (Test-Path -LiteralPath $installLog) {
    Copy-Item -LiteralPath $installLog -Destination $OutputFolder
    Write-Output '--- install.log ---'
    Get-Content -LiteralPath $installLog | Write-Output
    Write-Output '-------------------'
}
Test-Step 'Journal d installation' (Test-Path -LiteralPath $installLog)

# --- PowerShell 7 et GliderUI --------------------------------------------------------
$after = @(Get-ADTPowerShellInstall)
Test-Step 'PowerShell 7.4 ou plus present' ($after.Count -and $after[0].Version -ge [version]'7.4.0') $(if ($after.Count) { [string]$after[0].Version } else { 'aucun' })
if (-not $after.Count) { throw 'PowerShell 7 absent : impossible de poursuivre.' }
$pwsh = $after[0].Path

$modulesRoot = Join-Path $env:ProgramFiles 'PowerShell\Modules'
$settings = Import-PowerShellDataFile -Path (Join-Path $app 'Launcher.settings.psd1')
$baseline = [string]$settings.GliderUI.BaselineVersion
foreach ($name in @('GliderUI', 'GliderUI.Server.win-x64')) {
    Test-Step ('{0} {1} pour tous les utilisateurs' -f $name, $baseline) (Test-Path -LiteralPath (Join-Path $modulesRoot (Join-Path $name (Join-Path $baseline ($name + '.psd1')))))
}
$probe = "Import-Module GliderUI -RequiredVersion '$baseline' -ErrorAction Stop; if ('GliderUI.Avalonia.Markup.Xaml.AvaloniaRuntimeXamlLoader' -as [type]) { 'types OK' } else { exit 3 }"
$output = & $pwsh -NoProfile -NonInteractive -Command $probe 2>&1
Test-Step 'GliderUI se charge et expose ses types' ($LASTEXITCODE -eq 0) ([string]($output | Select-Object -Last 1))

# --- Lanceur, compte courant -------------------------------------------------------
$launcherLog = Join-Path $env:LOCALAPPDATA 'PSADToolkit\Logs\launcher.log'
& (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -ExecutionPolicy Bypass `
    -File (Join-Path $app 'Launcher.ps1') -InstallOnly -Silent 2>&1 | Write-Output
Test-Step 'Lanceur -InstallOnly' ($LASTEXITCODE -eq 0)

# --- Interface installee, annuaire simule -------------------------------------------
# Les tests ne sont pas installes : les copier a cote de l application le temps du
# parcours, pour eprouver GliderUI tel que le programme l a installe.
$ciFolder = Join-Path $app 'Tests\CI'
$null = New-Item -ItemType Directory -Force -Path $ciFolder
Copy-Item -Path (Join-Path $Repository 'Tests\CI\Smoke-*.ps1') -Destination $ciFolder
$smokeFolder = Join-Path $OutputFolder 'interface'
$null = New-Item -ItemType Directory -Force -Path $smokeFolder
$report = Join-Path $smokeFolder 'rapport.json'
& $pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $app 'Start-PSADToolkit.ps1') -SmokeTest -GliderUIVersion $baseline -SmokeReportPath $report | Out-Null
$passed = $false
if (Test-Path -LiteralPath $report) {
    $content = Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
    $passed = [bool]$content.Passed
    if (-not $passed) { Get-Content -LiteralPath $report | Write-Output }
}
Test-Step 'Parcours de l interface installee' $passed
Remove-Item -LiteralPath (Join-Path $app 'Tests') -Recurse -Force

# --- PSADToolkit.exe ---------------------------------------------------------------
$exe = Start-Process -FilePath (Join-Path $app 'PSADToolkit.exe') -PassThru
Start-Sleep -Seconds 3
Save-Screen -Name 'exe-attente'
$interface = $null
$deadline = (Get-Date).AddSeconds(90)
while ((Get-Date) -lt $deadline -and -not $interface) {
    Start-Sleep -Seconds 2
    $interface = @(Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe'" |
            Where-Object { [string]$_.CommandLine -like '*Start-PSADToolkit.ps1*' }) | Select-Object -First 1
}
Test-Step 'PSADToolkit.exe ouvre l interface' ($null -ne $interface) $(if ($interface) { [string]$interface.CommandLine } else { 'aucun processus Start-PSADToolkit.ps1' })
Start-Sleep -Seconds 12
Save-Screen -Name 'exe-choix-du-domaine'
Test-Step 'Interface toujours ouverte' ($interface -and (Get-Process -Id $interface.ProcessId -ErrorAction SilentlyContinue)) 'fenetre Choisir un domaine en attente'
if (Test-Path -LiteralPath $launcherLog) {
    Copy-Item -LiteralPath $launcherLog -Destination $OutputFolder
    Write-Output '--- launcher.log ---'
    Get-Content -LiteralPath $launcherLog | Select-Object -Last 30 | Write-Output
    Write-Output '--------------------'
}
foreach ($id in @($exe.Id) + @(if ($interface) { $interface.ProcessId })) {
    Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
}
Get-Process -Name 'GliderUI*' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
# Le lanceur (powershell.exe) attend l interface : l arreter aussi, sans quoi son
# dossier de travail - celui de l application - resterait verrouille.
Get-CimInstance Win32_Process -Filter "Name = 'pwsh.exe' OR Name = 'powershell.exe'" |
    Where-Object { [string]$_.CommandLine -like '*Start-PSADToolkit.ps1*' -or [string]$_.CommandLine -like '*PSADToolkit\Launcher.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 3

# --- Desinstallation -----------------------------------------------------------------
$uninstall = Start-Process -FilePath (Join-Path $app 'unins000.exe') -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -Wait -PassThru
# unins000.exe se relance depuis un dossier temporaire : attendre qu il ait fini.
$deadline = (Get-Date).AddSeconds(60)
while ((Test-Path -LiteralPath (Join-Path $app 'PSADToolkit.exe')) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
Start-Sleep -Seconds 3
$left = @(Get-ChildItem -LiteralPath $app -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName.Substring($app.Length + 1) })
Test-Step 'Desinstallation' ($uninstall.ExitCode -eq 0 -and -not (Test-Path -LiteralPath $app)) ('code {0} ; restant : {1}' -f $uninstall.ExitCode, $(if ($left.Count) { $left -join ', ' } elseif (Test-Path -LiteralPath $app) { 'dossier vide' } else { 'rien' }))
Test-Step 'Raccourci retire' (-not (Test-Path -LiteralPath $shortcut))
Test-Step 'PowerShell 7 conserve' (@(Get-ADTPowerShellInstall).Count -gt 0)

if ($failures.Count) { throw ('{0} verification(s) en echec : {1}' -f $failures.Count, ($failures -join ', ')) }
Write-Output 'Installation, lancement et desinstallation reussis.'
