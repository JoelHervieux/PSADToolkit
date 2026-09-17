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
# livre avec le serveur : sans serveur a jour, le module se charge mais les types
# manquent. C est la cause la plus frequente de "Impossible de trouver le type".
$installServer = Get-Command -Name 'Install-GLIServer' -ErrorAction SilentlyContinue
if ($installServer) { Write-Output 'Install-GLIServer : disponible' }
else { Write-Output 'Install-GLIServer : ABSENT (module anterieur a la version 0.4.0)' }

$serverFiles = @()
foreach ($module in $available) {
    $found = @(Get-ChildItem -Path $module.ModuleBase -Recurse -Filter 'GliderUI.Server*' -ErrorAction SilentlyContinue)
    foreach ($file in $found) { $serverFiles += $file.FullName }
}
if ($serverFiles.Count) {
    Write-Output ('Fichiers serveur trouves : {0}' -f $serverFiles.Count)
    foreach ($file in ($serverFiles | Select-Object -First 5)) { Write-Output ('  ' + $file) }
} else {
    Write-Output 'Aucun fichier GliderUI.Server trouve sous les dossiers du module.'
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
if ($missing.Count -eq $requiredTypes.Count) {
    Write-Output 'AUCUN type ne se resout : le module est charge mais les classes generees'
    Write-Output 'ne sont pas disponibles. Le serveur est absent ou desynchronise du module.'
} else {
    Write-Output 'Une partie seulement des types se resout : la version installee de GliderUI'
    Write-Output 'est vraisemblablement plus ancienne que celle attendue par l interface.'
}
Write-Output ''
Write-Output 'A executer, dans cet ordre :'
Write-Output '    Update-PSResource -Name GliderUI'
Write-Output '    Install-GLIServer -UninstallOldVersions'
Write-Output ''
Write-Output 'Le serveur doit etre reinstalle a CHAQUE mise a jour du module.'
Write-Output 'Fermer ensuite toutes les fenetres PowerShell avant de relancer Lancer.cmd :'
Write-Output 'un assembly deja charge dans une session ne peut pas y etre remplace.'
