<#
.SYNOPSIS
    Diagnostic de l installation GliderUI utilisee par l interface de PSADToolkit.
.DESCRIPTION
    A lancer depuis PowerShell 7.4 ou superieur lorsque l interface refuse de
    demarrer, en particulier sur "Impossible de trouver le type [...]".

    Le script n installe et ne modifie rien. Il rapporte :
      - la version de PowerShell et la plateforme ;
      - les versions de GliderUI installees et celle qui se charge reellement ;
      - la presence du serveur GliderUI, qui porte les types generes ;
      - pour chaque type dont l interface a besoin, s il se resout ou non ;
      - les assemblys GliderUI effectivement charges dans la session.

    Le resultat se colle tel quel dans un rapport de probleme.
.EXAMPLE
    pwsh -NoProfile -File .\Tests\Test-GliderUI.ps1
#>
[CmdletBinding()]
param()

$separator = '-' * 78
function Write-ADTSection { param([string]$Title) Write-Output ''; Write-Output $separator; Write-Output $Title; Write-Output $separator }

Write-ADTSection 'Environnement'
Write-Output ('PowerShell      : {0} ({1})' -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)
Write-Output ('Plateforme      : {0}' -f [System.Runtime.InteropServices.RuntimeInformation]::OSDescription.Trim())
Write-Output ('Architecture    : {0}' -f [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture)
if ($PSVersionTable.PSVersion -lt [version]'7.4') {
    Write-Output 'VERDICT : PowerShell 7.4 ou superieur est exige par GliderUI. Lancer avec pwsh.exe.'
    return
}

Write-ADTSection 'Module GliderUI'
$available = @(Get-Module -ListAvailable -Name GliderUI | Sort-Object Version -Descending)
if (-not $available.Count) {
    Write-Output 'Aucune version installee.'
    Write-Output ''
    Write-Output 'VERDICT : installer le module et son serveur :'
    Write-Output '    Install-PSResource -Name GliderUI'
    Write-Output '    Install-GLIServer'
    return
}
foreach ($module in $available) {
    Write-Output ('  {0,-10} {1}' -f [string]$module.Version, $module.ModuleBase)
}

$loadError = $null
try { Import-Module GliderUI -ErrorAction Stop } catch { $loadError = $_ }
if ($loadError) {
    Write-Output ''
    Write-Output ('Import-Module GliderUI a echoue : {0}' -f $loadError.Exception.Message)
    Write-Output 'VERDICT : reinstaller le module, puis Install-GLIServer.'
    return
}
$loaded = Get-Module -Name GliderUI
Write-Output ('Version chargee : {0}' -f [string]$loaded.Version)

Write-ADTSection 'Serveur GliderUI'
# Les types Avalonia exposes par GliderUI sont produits par un generateur de source
# livre avec le serveur. Le serveur est un MODULE DISTINCT, propre a la plateforme,
# installe a cote de GliderUI et non a l interieur : GliderUI.Server.win-x64 par
# exemple. Sans lui, le module se charge et les types manquent. C est la cause la
# plus frequente de "Impossible de trouver le type".
$installServer = Get-Command -Name 'Install-GLIServer' -ErrorAction SilentlyContinue
if ($installServer) { Write-Output 'Install-GLIServer : disponible' }
else { Write-Output 'Install-GLIServer : ABSENT (module anterieur a la version 0.4.0)' }

$architecture = 'x64'
if ([string][System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -eq 'Arm64') { $architecture = 'arm64' }
$platform = 'win'
if ($IsLinux) { $platform = 'linux' }
if ($IsMacOS) { $platform = 'osx' }
$script:ExpectedServer = 'GliderUI.Server.{0}-{1}' -f $platform, $architecture
$script:ExpectedVersion = [string]$loaded.Version
Write-Output ('Serveur attendu : {0} version {1}' -f $script:ExpectedServer, $script:ExpectedVersion)

$serverModules = @(Get-Module -ListAvailable -Name 'GliderUI.Server.*' | Sort-Object Version -Descending)
$script:ServerMatch = $false
if ($serverModules.Count) {
    foreach ($module in $serverModules) {
        $flag = ' '
        if ($module.Name -eq $script:ExpectedServer -and [string]$module.Version -eq $script:ExpectedVersion) {
            $flag = '*'
            $script:ServerMatch = $true
        }
        Write-Output ('{0} {1,-28} {2,-10} {3}' -f $flag, $module.Name, [string]$module.Version, $module.ModuleBase)
    }
    if (-not $script:ServerMatch) { Write-Output '(aucune ligne ne correspond au serveur attendu)' }
} else {
    Write-Output 'AUCUN module GliderUI.Server.* installe.'
}

Write-ADTSection 'Types requis par l interface'
$requiredTypes = @(
    'GliderUI.Avalonia.Markup.Xaml.AvaloniaRuntimeXamlLoader',
    'GliderUI.Avalonia.Controls.Window',
    'GliderUI.Avalonia.Controls.Button',
    'GliderUI.Avalonia.Controls.TextBlock',
    'GliderUI.Avalonia.Controls.TextBox',
    'GliderUI.Avalonia.Controls.CheckBox',
    'GliderUI.Avalonia.Controls.ComboBox',
    'GliderUI.Avalonia.Controls.NumericUpDown',
    'GliderUI.Avalonia.Controls.StackPanel',
    'GliderUI.Avalonia.Controls.Grid',
    'GliderUI.Avalonia.Controls.TreeView',
    'GliderUI.Avalonia.Controls.TreeViewItem',
    'GliderUI.Avalonia.Controls.TabControl',
    'GliderUI.Avalonia.Controls.TabItem',
    'GliderUI.Avalonia.Controls.ScrollViewer',
    'GliderUI.Avalonia.Controls.ContentControl',
    'GliderUI.Avalonia.Controls.Border',
    'GliderUI.Avalonia.Controls.DataGrid',
    'GliderUI.Avalonia.Controls.ColumnDefinition',
    'GliderUI.Avalonia.Controls.RowDefinition',
    'GliderUI.Avalonia.Controls.GridLength',
    'GliderUI.Avalonia.Thickness',
    'GliderUI.Avalonia.Platform.Storage.FolderPickerOpenOptions',
    'GliderUI.Avalonia.Platform.Storage.FilePickerOpenOptions',
    'GliderUI.Avalonia.Platform.Storage.FilePickerSaveOptions',
    'GliderUI.EventCallback',
    'GliderUI.DataSource',
    'GliderUI.DataSourcePropertyComparer'
)
# Ceux-ci restent facultatifs : la console les utilise pour le confort et prevoit
# un repli par bouton si la version installee ne les expose pas.
$optionalTypes = @(
    'GliderUI.Avalonia.Controls.ContextMenu',
    'GliderUI.Avalonia.Controls.MenuItem',
    'GliderUI.Avalonia.Controls.Separator'
)

$missing = @()
foreach ($name in $requiredTypes) {
    $resolved = $name -as [type]
    if ($resolved) { Write-Output ('  OK       {0}' -f $name) }
    else { Write-Output ('  MANQUANT {0}' -f $name); $missing += $name }
}
Write-Output ''
Write-Output 'Types facultatifs (confort : menus contextuels) :'
foreach ($name in $optionalTypes) {
    $resolved = $name -as [type]
    if ($resolved) { Write-Output ('  OK       {0}' -f $name) }
    else { Write-Output ('  absent   {0}' -f $name) }
}

Write-ADTSection 'Assemblys GliderUI charges'
$assemblies = @([System.AppDomain]::CurrentDomain.GetAssemblies() |
        Where-Object { [string]$_.FullName -like 'GliderUI*' } | Sort-Object FullName)
if ($assemblies.Count) {
    foreach ($assembly in $assemblies) {
        $location = ''
        try { $location = [string]$assembly.Location } catch { $location = '(dynamique)' }
        Write-Output ('  {0}' -f $assembly.GetName().Name)
        Write-Output ('      version {0}  {1}' -f $assembly.GetName().Version, $location)
    }
} else {
    Write-Output 'Aucun assembly dont le nom commence par GliderUI n est charge.'
}

Write-ADTSection 'Verdict'
if (-not $missing.Count) {
    Write-Output 'Tous les types requis se resolvent. L erreur vient d ailleurs :'
    Write-Output 'relancer Lancer.cmd et reporter le message complet.'
    return
}
Write-Output ('{0} type(s) requis sur {1} sont introuvables.' -f $missing.Count, $requiredTypes.Count)
Write-Output ''
if (-not $script:ServerMatch) {
    Write-Output ('CAUSE : le serveur {0} version {1} n est pas installe.' -f $script:ExpectedServer, $script:ExpectedVersion)
    Write-Output 'Le module GliderUI seul ne suffit pas : les classes Avalonia viennent du serveur.'
    Write-Output ''
    Write-Output 'Si cette machine atteint PowerShell Gallery :'
    Write-Output '    Install-GLIServer -UninstallOldVersions'
    Write-Output ''
    Write-Output 'Si elle ne l atteint pas - "Hote inconnu", proxy, serveur isole - installer'
    Write-Output 'hors ligne depuis un poste connecte de MEME systeme et MEME architecture :'
    Write-Output ''
    Write-Output '  1. Sur le poste connecte, recuperer le paquet du serveur :'
    Write-Output ('       Save-PSResource -Name {0} -Version {1} ``' -f $script:ExpectedServer, $script:ExpectedVersion)
    Write-Output '           -Path C:\Transfert -AsNupkg -TrustRepository'
    Write-Output ''
    Write-Output '  2. Copier C:\Transfert sur cette machine, puis :'
    Write-Output '       Register-PSResourceRepository -Name GliderUILocal ``'
    Write-Output '           -Uri C:\Transfert -Trusted'
    Write-Output '       Install-GLIServer -Repository GliderUILocal -TrustRepository'
    Write-Output ''
    Write-Output '  Install-GLIServer accepte -Repository : c est la voie prevue par GliderUI.'
} elseif ($missing.Count -eq $requiredTypes.Count) {
    Write-Output 'Le serveur attendu est present mais aucun type ne se resout.'
    Write-Output 'Reinstaller le serveur, puis relancer dans une session neuve :'
    Write-Output '    Install-GLIServer -UninstallOldVersions'
} else {
    Write-Output 'Une partie seulement des types se resout : la version installee de GliderUI'
    Write-Output 'est vraisemblablement plus ancienne que celle attendue par l interface.'
    Write-Output '    Update-PSResource -Name GliderUI'
    Write-Output '    Install-GLIServer -UninstallOldVersions'
}
Write-Output ''
Write-Output 'Le serveur doit etre reinstalle a CHAQUE mise a jour du module.'
Write-Output 'Fermer ensuite toutes les fenetres PowerShell avant de relancer Lancer.cmd :'
Write-Output 'un assembly deja charge dans une session ne peut pas y etre remplace.'
