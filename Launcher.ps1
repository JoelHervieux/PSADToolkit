#requires -version 5.1
<#
.SYNOPSIS
    Lanceur de PSADToolkit : verifie les prerequis, les installe ou les met a jour,
    puis ouvre l interface.
.DESCRIPTION
    Execute par PSADToolkit.exe (ou Lancer.cmd) avec Windows PowerShell 5.1, present
    sur tout Windows 10, 11 et Windows Server 2016 ou plus recent : c est ce qui lui
    permet d installer PowerShell 7 quand il manque.

      1. PowerShell 7 : installe s il manque ou s il est plus ancien que la version
         minimale ; mis a jour selon Launcher.settings.psd1. Le paquet livre avec
         l installateur (prereq\PowerShell-*.msi) est prefere ; a defaut, la
         derniere version du canal est telechargee depuis GitHub. L installation
         active Microsoft Update pour PowerShell : Windows Update le maintient
         ensuite a jour lui aussi.
      2. GliderUI et son serveur : Tools\Initialize-ADTEnvironment.ps1, execute par
         PowerShell 7 dans un processus a part.
      3. L interface : Start-PSADToolkit.ps1, sans console.

    Une fenetre d attente indique l etape en cours ; toute erreur est expliquee dans
    une boite de dialogue, avec le chemin du journal :
    %LOCALAPPDATA%\PSADToolkit\Logs\launcher.log
.PARAMETER InstallOnly
    Prepare les prerequis sans ouvrir l interface. Utilise par l installateur.
.PARAMETER Scope
    Portee d installation des modules : AllUsers (installateur, session elevee) ou
    CurrentUser (defaut, sans droits d administration).
.PARAMETER Silent
    Ni fenetre d attente ni boite de dialogue : le code de sortie fait foi.
.PARAMETER NoUpdate
    Ne cherche pas de mise a jour pour ce lancement.
.PARAMETER Offline
    N utilise que les paquets livres, sans contacter Internet.
#>
[CmdletBinding()]
param(
    [switch]$InstallOnly,
    [ValidateSet('CurrentUser', 'AllUsers')][string]$Scope = 'CurrentUser',
    [switch]$Silent,
    [switch]$NoUpdate,
    [switch]$Offline
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $root 'Tools\ADTDependency.ps1')

$dataFolder = Join-Path $env:LOCALAPPDATA 'PSADToolkit'
$logPath = Join-Path $dataFolder 'Logs\launcher.log'
$statePath = Join-Path $dataFolder 'launcher-state.json'
if ($Scope -eq 'AllUsers') {
    # L installateur prepare le poste pour tous : son etat ne doit pas se retrouver
    # dans le profil de l administrateur qui l execute.
    $dataFolder = Join-Path $env:ProgramData 'PSADToolkit'
    $logPath = Join-Path $dataFolder 'Logs\install.log'
    $statePath = Join-Path $dataFolder 'launcher-state.json'
}
$gliderStatePath = [System.IO.Path]::ChangeExtension($statePath, '.gliderui.json')

# --- Fenetre d attente ------------------------------------------------------------

$script:Splash = $null
$script:SplashText = $null
if (-not $Silent) {
    try {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        [System.Windows.Forms.Application]::EnableVisualStyles()
        $form = New-Object System.Windows.Forms.Form
        $form.Text = 'PSADToolkit'
        $form.FormBorderStyle = 'FixedDialog'
        $form.ControlBox = $false
        $form.StartPosition = 'CenterScreen'
        $form.ClientSize = New-Object System.Drawing.Size(460, 130)
        $form.TopMost = $true
        $form.ShowInTaskbar = $true
        $title = New-Object System.Windows.Forms.Label
        $title.Text = 'PSADToolkit'
        $title.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
        $title.SetBounds(20, 14, 420, 30)
        $text = New-Object System.Windows.Forms.Label
        $text.Font = New-Object System.Drawing.Font('Segoe UI', 9)
        $text.SetBounds(20, 50, 420, 36)
        $bar = New-Object System.Windows.Forms.ProgressBar
        $bar.Style = 'Marquee'
        $bar.MarqueeAnimationSpeed = 30
        $bar.SetBounds(20, 94, 420, 16)
        $form.Controls.AddRange(@($title, $text, $bar))
        $iconPath = Join-Path $root 'installer\PSADToolkit.ico'
        if (Test-Path -LiteralPath $iconPath) { $form.Icon = New-Object System.Drawing.Icon($iconPath) }
        $form.Show()
        $script:Splash = $form
        $script:SplashText = $text
    } catch { $script:Splash = $null }
}

function Update-Splash {
    if ($script:Splash) { [System.Windows.Forms.Application]::DoEvents() }
}

function Write-Status {
    param([string]$Text)
    Write-ADTLauncherLog -Path $logPath -Message $Text
    if ($script:SplashText) { $script:SplashText.Text = $Text }
    Update-Splash
    # Write-Host : Write-Status est appele depuis des fonctions qui rendent une valeur.
    if ($Silent) { Write-Host $Text }
}

function Close-Splash {
    if ($script:Splash) {
        try { $script:Splash.Close(); $script:Splash.Dispose() } catch { Write-Verbose 'Fenetre d attente deja fermee.' }
        $script:Splash = $null
        $script:SplashText = $null
    }
}

function Show-Failure {
    param([string]$Message)
    Write-ADTLauncherLog -Path $logPath -Message ('ECHEC : ' + $Message)
    Close-Splash
    if ($Silent) { Write-Error $Message -ErrorAction Continue; return }
    Add-Type -AssemblyName System.Windows.Forms
    $full = $Message + [Environment]::NewLine + [Environment]::NewLine + 'Journal : ' + $logPath
    $null = [System.Windows.Forms.MessageBox]::Show($full, 'PSADToolkit', 'OK', 'Error')
}

function Wait-ADTLauncherProcess {
    # Attend la fin d un processus sans figer la fenetre d attente.
    param([System.Diagnostics.Process]$Process)
    while (-not $Process.HasExited) {
        Update-Splash
        Start-Sleep -Milliseconds 100
    }
    $Process.WaitForExit()
    return $Process.ExitCode
}

function Test-Administrator {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ChannelVersion {
    # Derniere version publiee du canal, d apres les metadonnees officielles.
    param([string]$Channel)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $url = 'https://aka.ms/pwsh-buildinfo-' + $Channel.ToLowerInvariant()
    $client = New-Object System.Net.WebClient
    try {
        if ($client.Proxy) { $client.Proxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials }
        $info = ConvertFrom-Json -InputObject ($client.DownloadString($url))
    } finally { $client.Dispose() }
    return [string](ConvertTo-ADTVersion ([string]$info.ReleaseTag))
}

function Save-Download {
    param([string]$Url, [string]$Destination)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $client = New-Object System.Net.WebClient
    try {
        if ($client.Proxy) { $client.Proxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials }
        $task = $client.DownloadFileTaskAsync($Url, $Destination)
        while (-not $task.IsCompleted) {
            Update-Splash
            Start-Sleep -Milliseconds 100
        }
        if ($task.IsFaulted) { throw $task.Exception.GetBaseException() }
    } finally { $client.Dispose() }
}

function Install-PowerShellPackage {
<#
    Installe ou met a jour PowerShell 7 depuis un MSI. Une mise a jour d une version
    7.x remplace la precedente en place. Une session non elevee demande
    l elevation (UAC) ; un refus leve une erreur explicite.
#>
    param([string]$Path)
    $arguments = @(
        '/i', ('"' + $Path + '"'), '/qn', '/norestart',
        'ADD_PATH=1', 'ENABLE_MU=1', 'USE_MU=1', 'REGISTER_MANIFEST=1',
        'ADD_EXPLORER_CONTEXT_MENU_OPENPOWERSHELL=0', 'ADD_FILE_CONTEXT_MENU_RUNPOWERSHELL=0',
        '/l*v', ('"' + (Join-Path $dataFolder 'Logs\powershell-msi.log') + '"')
    )
    $options = @{ FilePath = 'msiexec.exe'; ArgumentList = $arguments; PassThru = $true }
    if (-not (Test-Administrator)) { $options['Verb'] = 'RunAs' }
    try { $process = Start-Process @options }
    catch { throw 'L installation de PowerShell 7 exige les droits d administration : elevation refusee ou impossible.' }
    $code = Wait-ADTLauncherProcess -Process $process
    if ($code -eq 1602) { throw 'Installation de PowerShell 7 annulee.' }
    if ($code -ne 0 -and $code -ne 3010 -and $code -ne 1641) {
        throw ('Installation de PowerShell 7 en echec (msiexec, code {0}). Detail : {1}' -f $code, (Join-Path $dataFolder 'Logs\powershell-msi.log'))
    }
}

function Get-PowerShellPackage {
    # MSI a installer : celui livre s il convient, sinon la derniere version du canal.
    param([version]$Minimum, [string]$Version, [bool]$Online, [string]$Channel)
    $architecture = Get-ADTArchitecture
    $pattern = '^PowerShell-(?<v>\d+\.\d+\.\d+)-win-' + $architecture + '\.msi$'
    $bundle = Find-ADTBundledPackage -Folder (Join-Path $root 'prereq') -Pattern $pattern -Version $Version
    if ($bundle -and $bundle.Version -ge $Minimum) { return $bundle.Path }
    if (-not $Online) { throw 'PowerShell 7 doit etre installe, mais aucun paquet n est livre et l acces a Internet est desactive.' }
    if (-not $Version) { $Version = Get-ChannelVersion -Channel $Channel }
    $url = Get-ADTPowerShellMsiUrl -Version $Version -Architecture $architecture
    $destination = Join-Path $env:TEMP ('PowerShell-{0}-win-{1}.msi' -f $Version, $architecture)
    Write-Status ('Telechargement de PowerShell {0}...' -f $Version)
    Save-Download -Url $url -Destination $destination
    return $destination
}

# --- Deroulement ----------------------------------------------------------------

$exitCode = 0
try {
    Write-ADTLauncherLog -Path $logPath -Message ('--- Lancement (portee {0}, Windows {1}) ---' -f $Scope, [Environment]::OSVersion.Version)
    $settings = Import-PowerShellDataFile -Path (Join-Path $root 'Launcher.settings.psd1')
    $online = [bool]$settings.AllowOnline -and -not $Offline
    $minimum = ConvertTo-ADTVersion ([string]$settings.PowerShell.MinimumVersion)
    $channel = [string]$settings.PowerShell.Channel
    $state = Read-ADTState -Path $statePath

    # --- 1. PowerShell 7 -----------------------------------------------------------
    Write-Status 'Verification de PowerShell 7...'
    $installed = @(Get-ADTPowerShellInstall)
    $pwsh = $null
    if ($installed.Count -and $installed[0].Version -ge $minimum) { $pwsh = $installed[0] }

    if (-not $pwsh) {
        $found = 'aucune'
        if ($installed.Count) { $found = [string]$installed[0].Version }
        Write-Status ('Installation de PowerShell 7 (version trouvee : {0}, minimum : {1})...' -f $found, $minimum)
        $package = Get-PowerShellPackage -Minimum $minimum -Online $online -Channel $channel
        Write-Status 'Installation de PowerShell 7 : accepter la demande d autorisation Windows.'
        Install-PowerShellPackage -Path $package
        $installed = @(Get-ADTPowerShellInstall)
        if (-not $installed.Count -or $installed[0].Version -lt $minimum) {
            throw 'PowerShell 7 a ete installe mais reste introuvable. Redemarrer la session Windows puis relancer PSADToolkit.'
        }
        $pwsh = $installed[0]
        $state['PowerShellLastCheck'] = (Get-Date).ToUniversalTime().ToString('o')
        Write-Status ('PowerShell {0} installe.' -f $pwsh.Version)
    } elseif ($online -and -not $NoUpdate -and
        (Test-ADTUpdateDue -LastCheck ([string]$state['PowerShellLastCheck']) -IntervalHours ([int]$settings.CheckIntervalHours))) {
        try {
            Write-Status 'Recherche d une mise a jour de PowerShell 7...'
            $latest = Get-ChannelVersion -Channel $channel
            $candidate = Select-ADTUpdateCandidate -Current ([string]$pwsh.Version) -Available @($latest) -Policy ([string]$settings.PowerShell.UpdatePolicy)
            if ($candidate) {
                $package = Get-PowerShellPackage -Minimum $minimum -Version $candidate -Online $true -Channel $channel
                Write-Status ('Mise a jour vers PowerShell {0} : accepter la demande d autorisation Windows.' -f $candidate)
                Install-PowerShellPackage -Path $package
                $pwsh = @(Get-ADTPowerShellInstall)[0]
                Write-Status ('PowerShell {0} installe.' -f $pwsh.Version)
            }
            $state['PowerShellLastCheck'] = (Get-Date).ToUniversalTime().ToString('o')
        } catch {
            # Une mise a jour manquee n empeche pas de travailler avec la version en place.
            Write-ADTLauncherLog -Path $logPath -Message ('Mise a jour de PowerShell non appliquee : ' + $_.Exception.Message)
        }
    }
    Write-ADTState -Path $statePath -State $state
    Write-ADTLauncherLog -Path $logPath -Message ('PowerShell retenu : {0} ({1})' -f $pwsh.Version, $pwsh.Path)

    # --- 2. GliderUI -----------------------------------------------------------------
    Write-Status 'Verification de GliderUI...'
    $resultPath = Join-Path $env:TEMP ('psadtoolkit-env-' + [Guid]::NewGuid().ToString('N') + '.json')
    $arguments = @(
        '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', ('"' + (Join-Path $root 'Tools\Initialize-ADTEnvironment.ps1') + '"'),
        '-Root', ('"' + $root + '"'), '-Scope', $Scope,
        '-StatePath', ('"' + $gliderStatePath + '"'), '-ResultPath', ('"' + $resultPath + '"'),
        '-LogPath', ('"' + $logPath + '"')
    )
    if ($NoUpdate) { $arguments += '-NoUpdate' }
    if (-not $online) { $arguments += '-Offline' }
    $process = Start-Process -FilePath $pwsh.Path -ArgumentList $arguments -WindowStyle Hidden -PassThru
    $null = Wait-ADTLauncherProcess -Process $process
    if (-not (Test-Path -LiteralPath $resultPath)) { throw 'La verification de GliderUI n a produit aucun resultat.' }
    $environment = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($resultPath))
    Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue
    if (-not $environment.Ready) {
        throw ('GliderUI n est pas utilisable :' + [Environment]::NewLine + (@($environment.Messages) -join [Environment]::NewLine))
    }
    Write-Status ('GliderUI {0} pret.' -f $environment.GliderUIVersion)

    if ($InstallOnly) {
        Write-Status 'Prerequis installes.'
    } else {
        # --- 3. Interface ------------------------------------------------------------
        Write-Status 'Ouverture de PSADToolkit...'
        $errorLog = Join-Path $dataFolder 'Logs\interface-erreur.log'
        if (Test-Path -LiteralPath $errorLog) { Remove-Item -LiteralPath $errorLog -Force -ErrorAction SilentlyContinue }
        $arguments = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-File', ('"' + (Join-Path $root 'Start-PSADToolkit.ps1') + '"'),
            '-GliderUIVersion', [string]$environment.GliderUIVersion,
            '-ErrorLogPath', ('"' + $errorLog + '"')
        )
        $interface = Start-Process -FilePath $pwsh.Path -ArgumentList $arguments -WindowStyle Hidden -PassThru
        # La fenetre d attente reste le temps que l interface apparaisse.
        $deadline = (Get-Date).AddSeconds(6)
        while (-not $interface.HasExited -and (Get-Date) -lt $deadline) {
            Update-Splash
            Start-Sleep -Milliseconds 100
        }
        Close-Splash
        $interface.WaitForExit()
        if ($interface.ExitCode -ne 0) {
            $detail = 'L interface s est arretee sur une erreur (code {0}).' -f $interface.ExitCode
            if (Test-Path -LiteralPath $errorLog) {
                $logText = [System.IO.File]::ReadAllText($errorLog).Trim()
                if ($logText.Length -gt 1500) { $logText = $logText.Substring(0, 1500) + ' [...] Suite : ' + $errorLog }
                $detail += [Environment]::NewLine + [Environment]::NewLine + $logText
            }
            throw $detail
        }
    }
} catch {
    $exitCode = 1
    Show-Failure -Message $_.Exception.Message
} finally {
    Close-Splash
}
exit $exitCode
