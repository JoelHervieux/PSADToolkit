#requires -version 7.4
<#
.SYNOPSIS
    Installe GliderUI et son serveur, les tient a jour et designe la version a charger.
.DESCRIPTION
    Appele par Launcher.ps1 avec le PowerShell 7 retenu. Travaille dans un processus
    distinct de l interface : GliderUI ne peut pas etre installe ou mis a jour dans
    une session ou il est deja charge.

    1. Installe la version de reference (Launcher.settings.psd1) si elle manque :
       d abord depuis les paquets livres avec l installateur (dossier prereq), sinon
       depuis PowerShell Gallery.
    2. Si la verification est due et autorisee, cherche une version plus recente
       permise par la politique (Patch par defaut), l installe avec le serveur de la
       MEME version, puis la verifie dans un processus neuf.
    3. Retient la plus haute version verifiee. Une version qui echoue est ecartee
       definitivement ; la precedente reste utilisee.

    Le resultat est ecrit en JSON dans ResultPath : Ready, GliderUIVersion, Messages.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Root,
    [ValidateSet('CurrentUser', 'AllUsers')][string]$Scope = 'CurrentUser',
    [Parameter(Mandatory = $true)][string]$StatePath,
    [Parameter(Mandatory = $true)][string]$ResultPath,
    [string]$LogPath,
    [switch]$NoUpdate,
    [switch]$Offline
)
$ErrorActionPreference = 'Stop'
. (Join-Path $Root 'Tools\ADTDependency.ps1')

$messages = New-Object System.Collections.ArrayList
function Write-Step {
    param([string]$Text)
    [void]$messages.Add($Text)
    Write-ADTLauncherLog -Path $LogPath -Message ('[GliderUI] ' + $Text)
}

$result = [ordered]@{ Ready = $false; GliderUIVersion = ''; Messages = @() }
try {
    $settings = Import-PowerShellDataFile -Path (Join-Path $Root 'Launcher.settings.psd1')
    $baseline = [string]$settings.GliderUI.BaselineVersion
    $policy = [string]$settings.GliderUI.UpdatePolicy
    $online = [bool]$settings.AllowOnline -and -not $Offline
    $serverName = 'GliderUI.Server.win-' + (Get-ADTArchitecture)
    $moduleRoot = Get-ADTModuleRoot -Scope $Scope
    $prereq = Join-Path $Root 'prereq'

    $state = Read-ADTState -Path $StatePath
    foreach ($key in @('KnownGood', 'Rejected')) { if (-not $state.ContainsKey($key)) { $state[$key] = @() } }
    $state['KnownGood'] = @($state['KnownGood'] | Where-Object { $_ })
    $state['Rejected'] = @($state['Rejected'] | Where-Object { $_ })

    function Get-ReadyVersion {
        # Versions dont le module ET le serveur de meme version sont presents.
        $modules = @(Get-Module -ListAvailable -Name GliderUI | ForEach-Object { [string]$_.Version })
        $servers = @(Get-Module -ListAvailable -Name $serverName | ForEach-Object { [string]$_.Version })
        return @($modules | Where-Object { $servers -contains $_ } | Sort-Object -Unique)
    }

    function Test-Version {
        # Le module se charge-t-il et expose-t-il ses types ? Verifie dans un processus
        # neuf : une session ou GliderUI est deja charge ne peut pas en changer.
        param([string]$Version)
        $pwsh = Join-Path $PSHOME 'pwsh.exe'
        $probe = "Import-Module GliderUI -RequiredVersion '$Version' -ErrorAction Stop; " +
        "if (-not ('GliderUI.Avalonia.Markup.Xaml.AvaloniaRuntimeXamlLoader' -as [type])) { exit 3 }; exit 0"
        & $pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $probe *> $null
        return ($LASTEXITCODE -eq 0)
    }

    function Install-Version {
        param([string]$Version, [switch]$AllowBundled)
        foreach ($name in @('GliderUI', $serverName)) {
            if (@(Get-Module -ListAvailable -Name $name | Where-Object { [string]$_.Version -eq $Version }).Count) { continue }
            $bundle = $null
            if ($AllowBundled) {
                $pattern = '^' + [regex]::Escape($name) + '\.(?<v>\d+\.\d+\.\d+)\.nupkg$'
                $bundle = Find-ADTBundledPackage -Folder $prereq -Pattern $pattern -Version $Version
            }
            if ($bundle) {
                $target = Install-ADTNupkgModule -Path $bundle.Path -ModuleRoot $moduleRoot
                Write-Step ('{0} {1} installe depuis le paquet livre : {2}' -f $name, $Version, $target)
                continue
            }
            if (-not $online) { throw ('{0} {1} absent, et l acces a Internet est desactive.' -f $name, $Version) }
            Install-PSResource -Name $name -Version $Version -Scope $Scope -TrustRepository -Reinstall -Quiet -ErrorAction Stop
            Write-Step ('{0} {1} installe depuis PowerShell Gallery ({2}).' -f $name, $Version, $Scope)
        }
    }

    # --- 1. Version de reference ----------------------------------------------
    if ((Get-ReadyVersion) -notcontains $baseline) {
        Write-Step ('Installation de GliderUI {0}.' -f $baseline)
        try { Install-Version -Version $baseline -AllowBundled }
        catch { Write-Step ('Installation de GliderUI {0} impossible : {1}' -f $baseline, $_.Exception.Message) }
    }

    # --- 2. Mise a jour -----------------------------------------------------------
    $due = Test-ADTUpdateDue -LastCheck ([string]$state['LastCheck']) -IntervalHours ([int]$settings.CheckIntervalHours)
    if ($online -and -not $NoUpdate -and $policy -ne 'None' -and $due) {
        try {
            $available = @(Find-PSResource -Name GliderUI -Version '*' -Repository PSGallery -ErrorAction Stop |
                ForEach-Object { [string]$_.Version })
            $current = @(Get-ReadyVersion | Sort-Object { [version]$_ } -Descending | Select-Object -First 1)
            $reference = $baseline
            if ($current.Count -and [version]$current[0] -gt [version]$baseline) { $reference = $current[0] }
            $candidate = Select-ADTUpdateCandidate -Current $reference -Available $available -Policy $policy -Rejected $state['Rejected']
            if ($candidate) {
                Write-Step ('Mise a jour disponible : GliderUI {0}.' -f $candidate)
                Install-Version -Version $candidate
                if (Test-Version -Version $candidate) {
                    $state['KnownGood'] = @(@($state['KnownGood']) + $candidate | Sort-Object -Unique)
                    Write-Step ('GliderUI {0} verifie : il sera utilise.' -f $candidate)
                } else {
                    $state['Rejected'] = @(@($state['Rejected']) + $candidate | Sort-Object -Unique)
                    Write-Step ('GliderUI {0} ne fonctionne pas avec PSADToolkit : version ecartee, la precedente est conservee.' -f $candidate)
                }
            }
            $state['LastCheck'] = (Get-Date).ToUniversalTime().ToString('o')
        } catch {
            # Hors ligne, proxy, galerie indisponible : on continue avec l existant.
            Write-Step ('Recherche de mise a jour impossible : ' + $_.Exception.Message)
        }
    }

    # --- 3. Choix de la version -------------------------------------------------
    $ready = @(Get-ReadyVersion | Where-Object { @($state['Rejected']) -notcontains $_ } |
        Sort-Object { [version]$_ } -Descending)
    foreach ($version in $ready) {
        # Une version jamais utilisee est verifiee avant d etre retenue.
        if (@($state['KnownGood']) -notcontains $version) {
            if (-not (Test-Version -Version $version)) {
                $state['Rejected'] = @(@($state['Rejected']) + $version | Sort-Object -Unique)
                Write-Step ('GliderUI {0} installe mais inutilisable : ecarte.' -f $version)
                continue
            }
            $state['KnownGood'] = @(@($state['KnownGood']) + $version | Sort-Object -Unique)
        }
        $result.GliderUIVersion = $version
        $result.Ready = $true
        break
    }
    if (-not $result.Ready) {
        Write-Step ('Aucune version utilisable de GliderUI. Attendu : GliderUI et {0} {1}.' -f $serverName, $baseline)
    }
    Write-ADTState -Path $StatePath -State $state
} catch {
    Write-Step ('Erreur : ' + $_.Exception.Message)
}

$result.Messages = @($messages)
[System.IO.File]::WriteAllText($ResultPath, (ConvertTo-Json -InputObject $result -Depth 3), (New-Object System.Text.UTF8Encoding($false)))
if ($result.Ready) { exit 0 }
exit 1
