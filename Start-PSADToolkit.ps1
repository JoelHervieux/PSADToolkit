#requires -version 7.4
using namespace GliderUI
using namespace GliderUI.Avalonia
using namespace GliderUI.Avalonia.Controls
using namespace GliderUI.Avalonia.Markup.Xaml
using namespace GliderUI.Avalonia.Platform.Storage

# NE PAS raccourcir les noms de types en s appuyant sur ces directives.
#
# Les types GliderUI sont ecrits en toutes lettres - [GliderUI.Avalonia.Controls.Window]
# et non [Window] - dans ce fichier comme dans UI\. C est verbeux, et c est
# volontaire : sur Windows Server 2016 avec GliderUI 0.4.1, la resolution par nom
# court via using namespace echoue alors que le nom complet se resout, ce qui
# arretait l interface sur "Impossible de trouver le type
# [AvaloniaRuntimeXamlLoader]" juste apres la verification de demarrage. Les
# directives ci-dessus sont conservees comme filet, sans etre utilisees.
# Tests\ConsoleInterface.Tests.ps1 refuse tout retour au nom court.

<#
.SYNOPSIS
    Interface graphique francaise de PSADToolkit, batie sur GliderUI (Avalonia).
.DESCRIPTION
    Lancer avec Lancer.cmd, ou directement : pwsh -File Start-PSADToolkit.ps1

    Prerequis :
      - PowerShell 7.4 ou superieur (pwsh.exe) ;
      - le module GliderUI et son serveur : Install-PSResource -Name GliderUI puis Install-GLIServer ;
      - Windows : le backend interroge Active Directory via System.DirectoryServices.

    L interface reste reactive pendant les operations : GliderUI affiche l UI dans un
    processus serveur separe, le script PowerShell n a donc pas de fil d execution UI a
    menager. Les controles a neutraliser pendant un traitement sont declares dans
    DisabledControlsWhileProcessing.
#>
[CmdletBinding()]
param(
    # Version exacte de GliderUI a charger. Le lanceur la fixe apres avoir verifie
    # qu elle fonctionne ; vide = la plus recente installee.
    [string]$GliderUIVersion,
    # Fichier ou consigner une erreur fatale. Le lanceur execute l interface sans
    # console : c est par ce fichier qu il peut expliquer un echec a l operateur.
    [string]$ErrorLogPath,
    # Test de fumee d integration continue : annuaire simule, chaque fenetre ouverte
    # puis refermee. Exige le dossier Tests\CI, absent d une installation.
    [switch]$SmokeTest,
    [string]$SmokeReportPath
)
$ErrorActionPreference = 'Stop'
$script:Root = $PSScriptRoot

trap {
    if ($ErrorLogPath) {
        try {
            $details = ($_ | Out-String) + [Environment]::NewLine + [string]$_.ScriptStackTrace
            Set-Content -LiteralPath $ErrorLogPath -Value $details -Encoding UTF8
        } catch { Write-Warning ('Journal d erreur non ecrit : ' + $_.Exception.Message) }
    }
    break
}

if (-not $IsWindows) {
    throw 'PSADToolkit interroge Active Directory via System.DirectoryServices, disponible uniquement sous Windows.'
}
if (-not (Get-Module -ListAvailable -Name GliderUI)) {
    throw "Module GliderUI introuvable. Installer :`n    Install-PSResource -Name GliderUI`n    Install-GLIServer"
}
if ($GliderUIVersion) { Import-Module GliderUI -RequiredVersion $GliderUIVersion -ErrorAction Stop }
else { Import-Module GliderUI -ErrorAction Stop }

# Verification des types GliderUI avant de construire quoi que ce soit.
#
# GliderUI expose les classes Avalonia en prefixant leur espace de noms par
# GliderUI, et ces classes sont produites par un generateur de source livre avec
# le serveur. Si le module est installe mais que le serveur ne l est pas, ou si la
# version installee est plus ancienne que celle attendue, les types manquent et la
# premiere utilisation echoue sur un brutal "Impossible de trouver le type
# [GliderUI.Avalonia.Markup.Xaml.AvaloniaRuntimeXamlLoader]", sans dire quoi faire. On les verifie donc tout de
# suite, par leur nom complet, ce qui ne depend pas des directives using namespace.
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
$missingTypes = @()
foreach ($requiredType in $requiredTypes) {
    if (-not ($requiredType -as [type])) { $missingTypes += $requiredType }
}
if ($missingTypes.Count) {
    $installed = @(Get-Module -ListAvailable -Name GliderUI | Sort-Object Version -Descending)
    $versions = 'aucune'
    if ($installed.Count) { $versions = ($installed | ForEach-Object { [string]$_.Version }) -join ', ' }
    $loaded = 'aucune'
    $current = Get-Module -Name GliderUI
    if ($current) { $loaded = [string]$current.Version }

    $report = New-Object System.Text.StringBuilder
    [void]$report.AppendLine('Le module GliderUI est charge mais il n expose pas les types dont l interface a besoin.')
    [void]$report.AppendLine('')
    [void]$report.AppendLine('Version chargee    : ' + $loaded)
    [void]$report.AppendLine('Versions installees: ' + $versions)
    [void]$report.AppendLine('PowerShell         : ' + [string]$PSVersionTable.PSVersion)
    [void]$report.AppendLine('')
    [void]$report.AppendLine(('Types introuvables ({0} sur {1}) :' -f $missingTypes.Count, $requiredTypes.Count))
    foreach ($missingType in ($missingTypes | Select-Object -First 8)) { [void]$report.AppendLine('  - ' + $missingType) }
    if ($missingTypes.Count -gt 8) { [void]$report.AppendLine(('  ... et {0} autre(s).' -f ($missingTypes.Count - 8))) }
    [void]$report.AppendLine('')

    # Le serveur est un module DISTINCT, propre a la plateforme, installe a cote de
    # GliderUI : GliderUI.Server.win-x64 par exemple. C est lui qui porte les classes
    # Avalonia. Nommer precisement celui qui manque evite de chercher au mauvais endroit.
    $architecture = 'x64'
    if ([string][System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -eq 'Arm64') { $architecture = 'arm64' }
    $expectedServer = 'GliderUI.Server.win-{0}' -f $architecture
    $serverModules = @(Get-Module -ListAvailable -Name 'GliderUI.Server.*')
    $serverPresent = $false
    foreach ($serverModule in $serverModules) {
        if ($serverModule.Name -eq $expectedServer -and [string]$serverModule.Version -eq $loaded) { $serverPresent = $true }
    }

    if (-not $serverPresent) {
        [void]$report.AppendLine(('CAUSE : le serveur {0} version {1} n est pas installe.' -f $expectedServer, $loaded))
        [void]$report.AppendLine('Le module GliderUI seul ne suffit pas : les classes Avalonia viennent du serveur,')
        [void]$report.AppendLine('qui est un module distinct a installer a cote.')
        [void]$report.AppendLine('')
        [void]$report.AppendLine('    Install-GLIServer -UninstallOldVersions')
        [void]$report.AppendLine('')
        [void]$report.AppendLine('Si cette machine n atteint pas PowerShell Gallery - "Hote inconnu", proxy,')
        [void]$report.AppendLine('serveur isole - voir la procedure hors ligne dans README.md, section')
        [void]$report.AppendLine('"Connexion et depannage".')
    } else {
        [void]$report.AppendLine('Le serveur attendu est present mais ses types ne se resolvent pas. Le reinstaller,')
        [void]$report.AppendLine('puis relancer dans une session neuve :')
        [void]$report.AppendLine('')
        [void]$report.AppendLine('    Update-PSResource -Name GliderUI')
        [void]$report.AppendLine('    Install-GLIServer -UninstallOldVersions')
    }
    [void]$report.AppendLine('')
    [void]$report.AppendLine('Rapport detaille : pwsh -NoProfile -File .\Tests\Test-GliderUI.ps1')
    throw $report.ToString()
}

Import-Module (Join-Path $script:Root 'PSADToolkit.psd1') -Force -ErrorAction Stop
# Helpers prives du module : l apercu d import doit calculer l OU cible et les groupes
# exactement comme l import lui-meme, la console reutilise le backend LDAP, et les
# formats regionaux comme les horaires de connexion sont partages avec les fonctions
# publiques pour que l affichage et l ecriture ne divergent jamais.
foreach ($helper in @(
        'DirectoryBackend.ps1', 'DirectoryConsole.ps1', 'DirectoryWrite.ps1',
        'CsvHelpers.ps1', 'Format-ADTDisplay.ps1', 'LogonHours.ps1', 'ObjectStatus.ps1',
        'DomainDiscovery.ps1'
    )) {
    . (Join-Path $script:Root (Join-Path 'Private' $helper))
}

# Console d administration : un fichier par domaine fonctionnel. L ordre importe
# peu, les fonctions ne sont appelees qu une fois la fenetre construite.
foreach ($module in @('Common.ps1', 'Connection.ps1', 'LogonHours.ps1', 'Dialogs.ps1', 'Properties.ps1', 'Console.ps1')) {
    . (Join-Path $script:Root (Join-Path 'UI' $module))
}

# Test de fumee : l annuaire simule remplace les fonctions de lecture et d ecriture.
# Charge apres le module et les helpers, il les masque pour tout appel fait depuis
# l interface.
if ($SmokeTest) {
    $script:ADTUiSmoke.Enabled = $true
    . (Join-Path $script:Root 'Tests\CI\Smoke-FakeDirectory.ps1')
}

$script:Rows = @()
$script:Operation = ''

#--- Aides generales ----------------------------------------------------------

function Get-ADTUiParentDN {
    param([string]$DN)
    for ($i = 0; $i -lt $DN.Length; $i++) {
        if ($DN[$i] -eq ',' -and ($i -eq 0 -or $DN[$i - 1] -ne '\')) { return $DN.Substring($i + 1) }
    }
    return ''
}

function Get-ADTUiDNDepth {
    param([string]$DN)
    $depth = 0
    for ($i = 0; $i -lt $DN.Length; $i++) {
        if ($DN[$i] -eq ',' -and ($i -eq 0 -or $DN[$i - 1] -ne '\')) { $depth++ }
    }
    return $depth
}

function New-ADTUiDataGrid {
    # Les colonnes des resultats changent d une commande a l autre. Les colonnes d un
    # DataGrid Avalonia se declarent en XAML : on genere donc la grille a chaque fois.
    param([hashtable[]]$Column)
    $xaml = New-Object System.Text.StringBuilder
    [void]$xaml.AppendLine('<DataGrid xmlns="https://github.com/avaloniaui" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"')
    [void]$xaml.AppendLine('    IsReadOnly="True" CanUserResizeColumns="True" CanUserSortColumns="True" GridLinesVisibility="Horizontal">')
    [void]$xaml.AppendLine('  <DataGrid.Columns>')
    foreach ($item in $Column) {
        $header = [System.Security.SecurityElement]::Escape([string]$item['Header'])
        [void]$xaml.AppendLine(('    <DataGridTextColumn Header="{0}" Binding="{{Binding {1}}}" SortMemberPath="{1}" />' -f $header, [string]$item['Path']))
    }
    [void]$xaml.AppendLine('  </DataGrid.Columns>')
    [void]$xaml.AppendLine('</DataGrid>')
    $grid = [GliderUI.Avalonia.Markup.Xaml.AvaloniaRuntimeXamlLoader]::Parse($xaml.ToString(), $null)
    # Ne pas nommer cette variable $column : les noms de variables sont insensibles a
    # la casse, elle designerait le parametre $Column et sa contrainte [hashtable[]].
    foreach ($gridColumn in $grid.Columns) {
        if ($gridColumn.SortMemberPath) { $gridColumn.CustomSortComparer = [GliderUI.DataSourcePropertyComparer]::new($gridColumn.SortMemberPath) }
    }
    return $grid
}

function Format-ADTUiCellValue {
    # Valeur telle qu elle doit APPARAITRE a l ecran. Les dates suivent le format
    # regional de la machine plutot qu une conversion implicite en chaine, qui rend
    # un format invariant, et les booleens se lisent en francais.
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [datetime]) { return (Format-ADTDateTime -Value $Value) }
    if ($Value -is [bool]) { if ($Value) { return 'Oui' } else { return 'Non' } }
    return [string]$Value
}

function New-ADTUiDataSourceList {
    # $Extra ajoute des valeurs a la source sans leur donner de colonne : la grille
    # transporte ainsi le DN et la classe de chaque ligne, dont les actions ont
    # besoin, sans les afficher.
    param([hashtable[]]$Column, $Row, [string[]]$Extra)
    $items = [GliderUI.System.Collections.ObjectModel.ObservableCollection[GliderUI.DataSource]]::new()
    foreach ($item in $Row) {
        $values = @{}
        foreach ($definition in $Column) {
            $path = [string]$definition['Path']
            $values[$path] = Format-ADTUiCellValue $item.$path
        }
        foreach ($path in @($Extra)) {
            if (-not $path -or $values.ContainsKey($path)) { continue }
            if (-not $item.PSObject.Properties[$path]) { continue }
            $values[$path] = Format-ADTUiCellValue $item.$path
        }
        $items.Add([GliderUI.DataSource]$values)
    }
    # Virgule unaire : sans elle PowerShell deroule la collection et le DataGrid
    # recevrait des elements isoles au lieu de la source liee.
    return , $items
}

#--- Fenetres secondaires -----------------------------------------------------

function Show-ADTUiDialog {
    # Avalonia n a pas de MessageBox. Une fenetre fille affichee puis attendue avec
    # WaitForClosed joue le role d une boite modale : les callbacks continuent d etre
    # traites pendant l attente.
    param(
        [string]$Title,
        [string]$Message,
        [string]$AcceptText = 'Fermer',
        [string]$CancelText
    )
    $state = @{ Accepted = $false }

    $text = [GliderUI.Avalonia.Controls.TextBlock]::new()
    $text.Text = $Message
    $text.TextWrapping = 'Wrap'

    $scroll = [GliderUI.Avalonia.Controls.ScrollViewer]::new()
    $scroll.Content = $text
    $scroll.MaxHeight = 260

    $buttons = [GliderUI.Avalonia.Controls.StackPanel]::new()
    $buttons.Orientation = 'Horizontal'
    $buttons.Spacing = 12
    $buttons.HorizontalAlignment = 'Right'

    $dialog = [GliderUI.Avalonia.Controls.Window]::new()
    $dialog.Title = $Title
    $dialog.Width = 640
    $dialog.Height = 320
    $dialog.WindowStartupLocation = 'CenterOwner'

    if ($CancelText) {
        $cancel = [GliderUI.Avalonia.Controls.Button]::new()
        $cancel.Content = $CancelText
        $cancel.Width = 150
        $cancel.HorizontalContentAlignment = 'Center'
        $cancel.AddClick({ $dialog.Close() }.GetNewClosure())
        $buttons.Children.Add($cancel)
    }

    $accept = [GliderUI.Avalonia.Controls.Button]::new()
    $accept.Content = $AcceptText
    $accept.Width = 150
    $accept.HorizontalContentAlignment = 'Center'
    $accept.Classes.Add('accent')
    $accept.AddClick({ $state.Accepted = $true; $dialog.Close() }.GetNewClosure())
    $buttons.Children.Add($accept)

    $panel = [GliderUI.Avalonia.Controls.StackPanel]::new()
    $panel.Margin = [GliderUI.Avalonia.Thickness]::new(20)
    $panel.Spacing = 18
    $panel.Children.Add($scroll)
    $panel.Children.Add($buttons)

    $dialog.Content = $panel
    Show-ADTUiModal -Window $dialog
    return $state.Accepted
}

function Show-ADTUiError {
    param([string]$Message)
    if ($script:ADTUiSmoke.Enabled) { [void]$script:ADTUiSmoke.Errors.Add($Message) }
    $null = Show-ADTUiDialog -Title 'PSADToolkit - erreur' -Message $Message
}

function Get-ADTUiOrganizationalUnit {
    param([string]$SearchBase, [string]$Server, [System.Management.Automation.PSCredential]$Credential)
    $scope = @{ DN = $SearchBase }
    if ($Server) { $scope['Server'] = $Server }
    if ($Credential) { $scope['Credential'] = $Credential }
    $entry = Open-ADTEntry @scope
    $search = New-Object System.DirectoryServices.DirectorySearcher($entry)
    $results = $null
    try {
        $search.Filter = '(objectClass=organizationalUnit)'
        $search.SearchScope = [System.DirectoryServices.SearchScope]::Subtree
        $search.PageSize = 1000
        $search.ClientTimeout = New-TimeSpan -Seconds 60
        $search.ServerTimeLimit = New-TimeSpan -Seconds 60
        $search.ReferralChasing = [System.DirectoryServices.ReferralChasingOption]::None
        [void]$search.PropertiesToLoad.Add('distinguishedName')
        [void]$search.PropertiesToLoad.Add('name')
        $results = $search.FindAll()
        foreach ($result in $results) {
            [PSCustomObject]@{
                Name = [string]$result.Properties['name'][0]
                DN   = [string]$result.Properties['distinguishedname'][0]
            }
        }
    } finally {
        if ($results) { $results.Dispose() }
        $search.Dispose()
        $entry.Dispose()
    }
}

function Select-ADTUiOrganizationalUnit {
    # L arbre est charge en une seule requete puis reconstruit a partir des DN. Avalonia
    # n expose pas d evenement "avant expansion" exploitable pour un chargement paresseux.
    $connection = Get-ADTUiConnection
    $domain = Get-ADTNativeDomain @connection
    $domainDN = [string]$domain.DistinguishedName
    if (-not $domainDN) { throw 'Impossible de determiner le domaine Active Directory.' }

    $scope = @{ Server = [string]$domain.Server }
    if ($connection.ContainsKey('Credential')) { $scope['Credential'] = $connection['Credential'] }
    $organizationalUnits = @(Get-ADTUiOrganizationalUnit -SearchBase $domainDN @scope |
        Sort-Object -Property @{ Expression = { Get-ADTUiDNDepth $_.DN } }, Name)

    $rootItem = [GliderUI.Avalonia.Controls.TreeViewItem]::new()
    $rootItem.Header = $domainDN
    $rootItem.Tag = $domainDN
    $rootItem.IsExpanded = $true

    $index = @{ $domainDN = $rootItem }
    foreach ($organizationalUnit in $organizationalUnits) {
        $item = [GliderUI.Avalonia.Controls.TreeViewItem]::new()
        $item.Header = $organizationalUnit.Name
        $item.Tag = $organizationalUnit.DN
        $parent = $rootItem
        $parentDN = Get-ADTUiParentDN $organizationalUnit.DN
        if ($parentDN -and $index.ContainsKey($parentDN)) { $parent = $index[$parentDN] }
        $parent.Items.Add($item) | Out-Null
        $index[$organizationalUnit.DN] = $item
    }

    $tree = [GliderUI.Avalonia.Controls.TreeView]::new()
    $tree.Height = 420
    $tree.Items.Add($rootItem) | Out-Null

    $dnBox = [GliderUI.Avalonia.Controls.TextBox]::new()
    $dnBox.IsReadOnly = $true
    $dnBox.Text = $domainDN

    $tree.AddSelectionChanged({
            $selected = $tree.SelectedItem
            if ($selected) { $dnBox.Text = [string]$selected.Tag }
        }.GetNewClosure())

    $state = @{ DN = $null }
    $dialog = [GliderUI.Avalonia.Controls.Window]::new()
    $dialog.Title = 'Selectionner une unite d organisation'
    $dialog.Width = 760
    $dialog.Height = 620
    $dialog.WindowStartupLocation = 'CenterOwner'

    $cancel = [GliderUI.Avalonia.Controls.Button]::new()
    $cancel.Content = 'Annuler'
    $cancel.Width = 150
    $cancel.HorizontalContentAlignment = 'Center'
    $cancel.AddClick({ $dialog.Close() }.GetNewClosure())

    $accept = [GliderUI.Avalonia.Controls.Button]::new()
    $accept.Content = 'Selectionner'
    $accept.Width = 150
    $accept.HorizontalContentAlignment = 'Center'
    $accept.Classes.Add('accent')
    $accept.AddClick({ $state.DN = $dnBox.Text; $dialog.Close() }.GetNewClosure())

    $buttons = [GliderUI.Avalonia.Controls.StackPanel]::new()
    $buttons.Orientation = 'Horizontal'
    $buttons.Spacing = 12
    $buttons.HorizontalAlignment = 'Right'
    $buttons.Children.Add($cancel)
    $buttons.Children.Add($accept)

    $count = [GliderUI.Avalonia.Controls.TextBlock]::new()
    $count.Text = ('{0} unite(s) d organisation lue(s) dans {1}.' -f $organizationalUnits.Count, $domainDN)
    $count.TextWrapping = 'Wrap'

    $panel = [GliderUI.Avalonia.Controls.StackPanel]::new()
    $panel.Margin = [GliderUI.Avalonia.Thickness]::new(18)
    $panel.Spacing = 12
    $panel.Children.Add($count)
    $panel.Children.Add($tree)
    $panel.Children.Add($dnBox)
    $panel.Children.Add($buttons)

    $dialog.Content = $panel
    Show-ADTUiModal -Window $dialog
    return $state.DN
}

function Show-ADTUiImportPreview {
    param([hashtable]$Parameters)
    if (-not $Parameters['Path']) { throw 'Selectionner un fichier CSV.' }
    if (-not $Parameters['DefaultOU']) { throw 'Selectionner l OU de destination avant de poursuivre l import.' }
    $delimiter = [char]';'
    if ($Parameters.ContainsKey('Delimiter')) { $delimiter = [char]$Parameters['Delimiter'] }
    $rows = @(Read-ADTFlexibleCsv -Path ([string]$Parameters['Path']) -Delimiter $delimiter)
    if (-not $rows.Count) { throw 'Le fichier CSV ne contient aucune ligne.' }

    $defaultGroups = @()
    if ($Parameters['DefaultGroups']) { $defaultGroups = [string[]]@($Parameters['DefaultGroups']) }
    $createDepartmentOUs = [bool]$Parameters['CreateDepartmentOUs']
    $defaultOU = [string]$Parameters['DefaultOU']

    $preview = @()
    foreach ($row in $rows) {
        $preview += [PSCustomObject]@{
            Prenom      = [string]$row.GivenName
            Nom         = [string]$row.Surname
            Departement = [string]$row.Department
            OU          = [string](Get-ADTImportTargetOU -Row $row -DefaultOU $defaultOU -CreateDepartmentOUs $createDepartmentOUs)
            Groupes     = ((Get-ADTCsvRowGroups -Row $row -DefaultGroups $defaultGroups) -join '; ')
        }
    }

    $columns = @(
        @{ Header = 'Prenom'; Path = 'Prenom' },
        @{ Header = 'Nom'; Path = 'Nom' },
        @{ Header = 'Departement'; Path = 'Departement' },
        @{ Header = 'OU cible'; Path = 'OU' },
        @{ Header = 'Groupes'; Path = 'Groupes' }
    )
    $grid = New-ADTUiDataGrid -Column $columns
    $grid.ItemsSource = New-ADTUiDataSourceList -Column $columns -Row $preview
    $grid.Height = 420

    $state = @{ Accepted = $false }
    $dialog = [GliderUI.Avalonia.Controls.Window]::new()
    $dialog.Title = 'Apercu avant import'
    $dialog.Width = 1080
    $dialog.Height = 640
    $dialog.WindowStartupLocation = 'CenterOwner'

    $cancel = [GliderUI.Avalonia.Controls.Button]::new()
    $cancel.Content = 'Annuler'
    $cancel.Width = 150
    $cancel.HorizontalContentAlignment = 'Center'
    $cancel.AddClick({ $dialog.Close() }.GetNewClosure())

    $accept = [GliderUI.Avalonia.Controls.Button]::new()
    $accept.Content = 'Continuer'
    $accept.Width = 150
    $accept.HorizontalContentAlignment = 'Center'
    $accept.Classes.Add('accent')
    $accept.AddClick({ $state.Accepted = $true; $dialog.Close() }.GetNewClosure())

    $buttons = [GliderUI.Avalonia.Controls.StackPanel]::new()
    $buttons.Orientation = 'Horizontal'
    $buttons.Spacing = 12
    $buttons.HorizontalAlignment = 'Right'
    $buttons.Children.Add($cancel)
    $buttons.Children.Add($accept)

    $header = [GliderUI.Avalonia.Controls.TextBlock]::new()
    $header.Text = ('Apercu de {0} utilisateur(s). Verifier les OU et les groupes avant de continuer.' -f $rows.Count)
    $header.TextWrapping = 'Wrap'

    $panel = [GliderUI.Avalonia.Controls.StackPanel]::new()
    $panel.Margin = [GliderUI.Avalonia.Thickness]::new(18)
    $panel.Spacing = 12
    $panel.Children.Add($header)
    $panel.Children.Add($grid)
    $panel.Children.Add($buttons)

    $dialog.Content = $panel
    Show-ADTUiModal -Window $dialog
    return $state.Accepted
}

#--- Definition des onglets ---------------------------------------------------

# Un champ est un tableau de trois chaines : cle du parametre, libelle, type de controle.
# Un libelle termine par * marque un champ obligatoire. La virgule unaire de l onglet
# Privileges conserve le tableau imbrique alors qu il n a qu un seul champ : sans elle,
# PowerShell aplatit le tableau et l interface traite chaque caractere comme un champ.
$specs = @(
    @{ Title = 'Creer un compte'; Command = 'New-ADTUser'; Write = $true; Fields = @(
            @('GivenName', 'Prenom *', 'text'),
            @('Surname', 'Nom *', 'text'),
            @('Path', 'OU cible (DN) *', 'ou'),
            @('SamAccountName', 'Identifiant (vide = automatique)', 'text'),
            @('Department', 'Service', 'text'),
            @('Title', 'Fonction', 'text'),
            @('Groups', 'Groupes (separes par ;)', 'list'),
            @('EmailAddress', 'Courriel', 'text'),
            @('HomeDirectoryRoot', 'Racine du dossier personnel (UNC)', 'text'),
            @('HomeDrive', 'Lecteur (ex. H:)', 'text'),
            @('Disabled', 'Creer le compte desactive', 'check')
        )
    },
    @{ Title = 'Importer un CSV'; Command = 'Import-ADTUserFromCsv'; Write = $true; Fields = @(
            @('Path', 'Fichier CSV *', 'open'),
            @('DefaultOU', 'OU de destination *', 'ou'),
            @('DefaultGroups', 'Groupes par defaut (;)', 'list'),
            @('Delimiter', 'Separateur du CSV', 'delimiter'),
            @('CreateDepartmentOUs', 'Creer automatiquement une sous-OU par departement', 'check'),
            @('PasswordReportPath', 'Rapport des mots de passe (facultatif)', 'savecsv'),
            @('SkipExisting', 'Ignorer les identifiants deja existants', 'check')
        )
    },
    @{ Title = 'Groupes'; Command = 'Set-ADTUserGroupMembership'; Write = $true; Fields = @(
            @('Identity', 'Utilisateurs (identifiants separes par ;) *', 'list'),
            @('AddGroup', 'Groupes a ajouter (;)', 'list'),
            @('RemoveGroup', 'Groupes a retirer (;)', 'list')
        )
    },
    @{ Title = 'Depart'; Command = 'Start-ADTUserOffboarding'; Write = $true; Fields = @(
            @('Identity', 'Utilisateurs (identifiants separes par ;) *', 'list'),
            @('BackupPath', 'Dossier des sauvegardes *', 'folder'),
            @('DisabledOU', 'OU de destination (DN, facultatif)', 'ou'),
            @('Reason', 'Motif', 'text'),
            @('KeepGroups', 'Conserver les groupes secondaires', 'check'),
            @('NoPasswordReset', 'Conserver le mot de passe actuel', 'check')
        )
    },
    @{ Title = 'Comptes inactifs'; Command = 'Get-ADTInactiveAccount'; Write = $false; Fields = @(
            @('DaysInactive', 'Seuil en jours', 'number'),
            @('SearchBase', 'Limiter a une OU (DN)', 'ou'),
            @('IncludeDisabled', 'Inclure les comptes desactives', 'check'),
            @('ExcludeNeverLoggedOn', 'Exclure les comptes jamais connectes', 'check')
        )
    },
    @{ Title = 'Privileges'; Command = 'Get-ADTPrivilegedGroupMember'; Write = $false; Fields = @(
            , @('IncludeBuiltin', 'Inclure les groupes integres', 'check')
        )
    },
    @{ Title = 'Rapport HTML'; Command = 'Export-ADTAccessReport'; Write = $false; Fields = @(
            @('Path', 'Fichier HTML *', 'savehtml'),
            @('DaysInactive', 'Seuil en jours', 'number'),
            @('SearchBase', 'Limiter les comptes a une OU (DN)', 'ou'),
            @('CsvFolder', 'Dossier CSV complementaire (facultatif)', 'folder')
        )
    }
)

#--- Selecteurs de fichiers ---------------------------------------------------

function Get-ADTUiStoragePath {
    param($StorageItem)
    if (-not $StorageItem) { return '' }
    foreach ($item in $StorageItem) {
        if (-not $item) { continue }
        $uri = $item.Path
        if (-not $uri) { continue }
        $path = [string]$uri.LocalPath
        if (-not $path) {
            # AbsolutePath rend un chemin de la forme /C:/dossier/fichier.csv, encode.
            $path = [System.Uri]::UnescapeDataString([string]$uri.AbsolutePath)
            if ($path -match '^/[A-Za-z]:') { $path = $path.Substring(1) }
            $path = $path.Replace('/', '\')
        }
        if ($path) { return $path }
    }
    return ''
}

function Invoke-ADTUiBrowse {
    param([string]$Kind, [string]$Command, $Control, [hashtable]$Fields)
    try {
        if ($Kind -eq 'ou') {
            $selected = Select-ADTUiOrganizationalUnit
            if ($selected) { $Control.Text = $selected }
            return
        }
        if ($Kind -eq 'folder') {
            $options = [GliderUI.Avalonia.Platform.Storage.FolderPickerOpenOptions]::new()
            $options.Title = 'Selectionner un dossier'
            $path = Get-ADTUiStoragePath ($window.StorageProvider.OpenFolderPickerAsync($options).WaitForCompleted())
            if ($path) { $Control.Text = $path }
            return
        }
        if ($Kind -eq 'open') {
            $options = [GliderUI.Avalonia.Platform.Storage.FilePickerOpenOptions]::new()
            $options.Title = 'Selectionner un fichier CSV'
            $path = Get-ADTUiStoragePath ($window.StorageProvider.OpenFilePickerAsync($options).WaitForCompleted())
            if (-not $path) { return }
            $Control.Text = $path
            if ($Command -eq 'Import-ADTUserFromCsv') {
                # L OU de destination est obligatoire : la demander dans la foulee.
                $selected = Select-ADTUiOrganizationalUnit
                if (-not $selected) { $Control.Text = ''; return }
                if ($Fields.ContainsKey('DefaultOU')) { $Fields['DefaultOU'].Control.Text = $selected }
            }
            return
        }
        $options = [GliderUI.Avalonia.Platform.Storage.FilePickerSaveOptions]::new()
        if ($Kind -eq 'savehtml') {
            $options.Title = 'Enregistrer le rapport HTML'
            $options.DefaultExtension = 'html'
            $options.SuggestedFileName = 'rapport-acces.html'
        } else {
            $options.Title = 'Enregistrer le fichier CSV'
            $options.DefaultExtension = 'csv'
            $options.SuggestedFileName = 'psadtoolkit.csv'
        }
        $path = Get-ADTUiStoragePath ($window.StorageProvider.SaveFilePickerAsync($options).WaitForCompleted())
        if ($path) { $Control.Text = $path }
    } catch {
        Show-ADTUiError $_.Exception.Message
    }
}

#--- Construction des champs --------------------------------------------------

function New-ADTUiField {
    param([string]$Key, [string]$Label, [string]$Kind, [string]$Command, [hashtable]$Fields)
    $panel = [GliderUI.Avalonia.Controls.StackPanel]::new()
    $panel.Spacing = 4

    if ($Kind -eq 'check') {
        $control = [GliderUI.Avalonia.Controls.CheckBox]::new()
        $control.Content = $Label
        $panel.Margin = [GliderUI.Avalonia.Thickness]::new(0, 18, 0, 0)
        $panel.Children.Add($control)
    } else {
        $caption = [GliderUI.Avalonia.Controls.TextBlock]::new()
        $caption.Text = $Label
        $panel.Children.Add($caption)

        if ($Kind -eq 'number') {
            $control = [GliderUI.Avalonia.Controls.NumericUpDown]::new()
            $control.Minimum = 1
            $control.Maximum = 3650
            $control.Value = 90
            $panel.Children.Add($control)
        } elseif ($Kind -eq 'delimiter') {
            $control = [GliderUI.Avalonia.Controls.ComboBox]::new()
            $control.Items.Add(';') | Out-Null
            $control.Items.Add(',') | Out-Null
            $control.SelectedIndex = 0
            $control.HorizontalAlignment = 'Stretch'
            $panel.Children.Add($control)
        } else {
            $control = [GliderUI.Avalonia.Controls.TextBox]::new()
            if ($Key -eq 'Reason') { $control.Text = 'Depart de l employe' }
            if (@('ou', 'open', 'savecsv', 'savehtml', 'folder') -contains $Kind) {
                $browse = [GliderUI.Avalonia.Controls.Button]::new()
                $browse.Content = '...'
                $browse.Width = 44
                $browse.HorizontalContentAlignment = 'Center'
                $browse.AddClick({ Invoke-ADTUiBrowse -Kind $Kind -Command $Command -Control $control -Fields $Fields }.GetNewClosure())

                $line = [GliderUI.Avalonia.Controls.Grid]::new()
                $line.ColumnSpacing = 6
                $textColumn = [GliderUI.Avalonia.Controls.ColumnDefinition]::new()
                $textColumn.Width = [GliderUI.Avalonia.Controls.GridLength]::new(1, 'Star')
                $buttonColumn = [GliderUI.Avalonia.Controls.ColumnDefinition]::new()
                $buttonColumn.Width = [GliderUI.Avalonia.Controls.GridLength]::Auto
                $line.ColumnDefinitions.Add($textColumn)
                $line.ColumnDefinitions.Add($buttonColumn)
                [GliderUI.Avalonia.Controls.Grid]::SetColumn($control, 0)
                [GliderUI.Avalonia.Controls.Grid]::SetColumn($browse, 1)
                $line.Children.Add($control)
                $line.Children.Add($browse)
                $panel.Children.Add($line)
            } else {
                $panel.Children.Add($control)
            }
        }
    }

    $Fields[$Key] = @{ Control = $control; Kind = $Kind; Required = [bool]$Label.EndsWith('*') }
    return $panel
}

#--- Execution ----------------------------------------------------------------

function Confirm-ADTUiWrite {
    param($Spec, [hashtable]$Parameters)
    $target = 'Domaine de la session'
    if ($Parameters['Server']) { $target = [string]$Parameters['Server'] }
    $summary = 'Operation : ' + [string]$Spec.Title + [Environment]::NewLine + 'Serveur : ' + $target + [Environment]::NewLine
    foreach ($key in @('Identity', 'GivenName', 'Surname', 'Path', 'DefaultOU', 'Groups', 'DefaultGroups', 'AddGroup', 'RemoveGroup', 'DisabledOU', 'BackupPath')) {
        if ($Parameters[$key]) { $summary += $key + ' : ' + ($Parameters[$key] -join '; ') + [Environment]::NewLine }
    }
    if ($Parameters['CreateDepartmentOUs']) { $summary += 'Sous-OU par departement : OUI' + [Environment]::NewLine }
    $summary += [Environment]::NewLine + 'Appliquer ces modifications a Active Directory ?'
    return (Show-ADTUiDialog -Title 'Confirmer les modifications' -Message $summary -AcceptText 'Appliquer' -CancelText 'Annuler')
}

function Update-ADTUiResultGrid {
    $columns = @()
    if ($script:Rows.Count) {
        foreach ($property in $script:Rows[0].PSObject.Properties) {
            if ($property.Name -eq 'Password' -and -not [bool]$showPasswords.IsChecked) { continue }
            # Une liaison Avalonia vise un nom de propriete : ecarter tout nom exotique.
            if ($property.Name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { continue }
            $columns += @{ Header = $property.Name; Path = $property.Name }
        }
    }
    if (-not $columns.Count) {
        $gridHost.Content = $null
        $exportButton.IsEnabled = $false
        return
    }
    $grid = New-ADTUiDataGrid -Column $columns
    $grid.ItemsSource = New-ADTUiDataSourceList -Column $columns -Row $script:Rows
    $gridHost.Content = $grid
    $exportButton.IsEnabled = ($script:Rows.Count -gt 0)
}

function Invoke-ADTUiCommand {
    param([string]$Command, [hashtable]$Parameters)
    $script:Operation = $Command
    $script:Rows = @()
    $gridHost.Content = $null
    $detailsBox.Text = ''
    $exportButton.IsEnabled = $false
    $statusText.Text = 'Traitement en cours : ' + $Command
    $progress.IsIndeterminate = $true
    try {
        $commandWarnings = $null
        $commandErrors = $null
        $script:Rows = @(& $Command @Parameters -WarningVariable commandWarnings -ErrorVariable commandErrors -ErrorAction Continue)
        $messages = @()
        foreach ($warning in @($commandWarnings)) { if ($warning) { $messages += 'AVERTISSEMENT : ' + $warning.Message } }
        foreach ($failure in @($commandErrors)) { if ($failure) { $messages += 'ERREUR : ' + $failure.ToString() } }
        $detailsBox.Text = $messages -join [Environment]::NewLine
        Update-ADTUiResultGrid
        $failed = @($script:Rows | Where-Object {
                $_.Status -eq 'Echec' -or $_.Status -eq 'Partiel' -or ($_.PSObject.Properties['Ready'] -and -not $_.Ready)
            }).Count
        $statusText.Text = ('{0} resultat(s). Verifier les colonnes Status, Error et Messages.' -f $script:Rows.Count)
        if ($failed -or @($commandErrors).Count) { $statusText.Text = 'Termine avec erreurs : consulter les resultats et les messages.' }
    } catch {
        $detailsBox.Text = $_.Exception.Message
        $statusText.Text = 'Operation interrompue : consulter le detail.'
    } finally {
        $progress.IsIndeterminate = $false
        # Le journal est replie par defaut pour laisser la place a l annuaire ; il
        # s ouvre de lui-meme des qu une operation produit un resultat a lire.
        try { $journal.IsExpanded = $true } catch { Add-ADTUiSmokeWarning 'Journal des operations non deplie.' }
    }
}

function Invoke-ADTUiExecute {
    param($Spec, [hashtable]$Fields, $Simulate)
    try {
        $parameters = Get-ADTUiConnection
        foreach ($key in @($Fields.Keys)) {
            $field = $Fields[$key]
            $control = $field['Control']
            $kind = [string]$field['Kind']
            if ($kind -eq 'check') {
                if ([bool]$control.IsChecked) { $parameters[$key] = $true }
                continue
            }
            if ($kind -eq 'number') {
                $parameters[$key] = [int]$control.Value
                continue
            }
            if ($kind -eq 'delimiter') {
                $parameters[$key] = [char][string]$control.SelectedItem
                continue
            }
            $value = [string]$control.Text
            if ($value) { $value = $value.Trim() }
            if ($field['Required'] -and -not $value) { throw ('Champ obligatoire : ' + $key) }
            if (-not $value) { continue }
            if ($kind -eq 'list') {
                $parameters[$key] = [string[]]@($value -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            } else {
                $parameters[$key] = $value
            }
        }
        if ([string]$Spec.Command -eq 'Import-ADTUserFromCsv') {
            if (-not (Show-ADTUiImportPreview -Parameters $parameters)) { return }
        }
        if ($Spec.Write) {
            $parameters['WhatIf'] = [bool]$Simulate.IsChecked
            $parameters['Confirm'] = $false
            if (-not [bool]$Simulate.IsChecked) {
                if (-not (Confirm-ADTUiWrite -Spec $Spec -Parameters $parameters)) { return }
            }
        }
        Invoke-ADTUiCommand -Command ([string]$Spec.Command) -Parameters $parameters
    } catch {
        Show-ADTUiError $_.Exception.Message
    }
}

#--- Fenetre principale -------------------------------------------------------

$mainXaml = @'
<Window xmlns="https://github.com/avaloniaui"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="PSADToolkit 3.2.0-test1 | Administration Active Directory"
        Width="1440" Height="980">
  <Grid RowDefinitions="Auto,*,Auto,Auto">

    <Border Grid.Row="0" Background="#162840" Padding="20,12">
      <Grid ColumnDefinitions="Auto,*,Auto" ColumnSpacing="24">
        <TextBlock Grid.Column="0" Text="PSADToolkit" Foreground="White" FontSize="22" FontWeight="Bold" VerticalAlignment="Center" />
        <StackPanel Grid.Column="1" Spacing="2" VerticalAlignment="Center">
          <TextBlock x:Name="domain_text" Text="Aucun domaine" Foreground="White" FontWeight="Bold" />
          <TextBlock x:Name="domain_detail" Text="" Foreground="#BED4ED" />
        </StackPanel>
        <Button Grid.Column="2" x:Name="change_domain" Content="Changer de domaine" VerticalAlignment="Center" />
      </Grid>
    </Border>

    <TabControl Grid.Row="1" x:Name="tabs" Margin="12,8,12,0" />

    <Expander Grid.Row="2" x:Name="journal" Header="Journal des operations" IsExpanded="False"
              Margin="12,8,12,0" HorizontalAlignment="Stretch">
      <StackPanel Spacing="8">
        <Grid ColumnDefinitions="*,Auto" ColumnSpacing="16">
          <CheckBox Grid.Column="0" x:Name="show_passwords" Content="Afficher / exporter les mots de passe generes" />
          <Button Grid.Column="1" x:Name="export_button" Content="Exporter les resultats CSV" IsEnabled="False" />
        </Grid>
        <Border Height="220" BorderBrush="#C9D4E2" BorderThickness="1" CornerRadius="4">
          <ContentControl x:Name="grid_host" />
        </Border>
        <TextBox x:Name="details_box" Height="80" AcceptsReturn="True" IsReadOnly="True" TextWrapping="Wrap"
                 Watermark="Avertissements et erreurs de la derniere operation." />
      </StackPanel>
    </Expander>

    <Grid Grid.Row="3" Margin="12,8,12,12" ColumnDefinitions="*,Auto" ColumnSpacing="16">
      <TextBlock Grid.Column="0" x:Name="status_text" VerticalAlignment="Center" TextWrapping="Wrap" Text="Pret." />
      <ProgressBar Grid.Column="1" x:Name="progress" Width="220" VerticalAlignment="Center" />
    </Grid>
  </Grid>
</Window>
'@

$window = [GliderUI.Avalonia.Markup.Xaml.AvaloniaRuntimeXamlLoader]::Parse($mainXaml, $null)
$domainText = $window.FindControl('domain_text')
$domainDetail = $window.FindControl('domain_detail')
$changeDomain = $window.FindControl('change_domain')
$tabs = $window.FindControl('tabs')
$journal = $window.FindControl('journal')
$showPasswords = $window.FindControl('show_passwords')
$exportButton = $window.FindControl('export_button')
$gridHost = $window.FindControl('grid_host')
$detailsBox = $window.FindControl('details_box')
$statusText = $window.FindControl('status_text')
$progress = $window.FindControl('progress')

$changeDomain.AddClick([GliderUI.EventCallback]@{
        DisabledControlsWhileProcessing = @($changeDomain, $tabs)
        ScriptBlock                     = {
            try {
                $chosen = Show-ADTUiDomainChooser -AllowCancel
                if (-not $chosen) { return }
                Set-ADTUiConnection -Connection $chosen
                $script:Rows = @()
                Update-ADTUiResultGrid
                $detailsBox.Text = ''
                Update-ADTUiConsoleTree
                $tabs.SelectedIndex = 0
            } catch { Show-ADTUiError $_.Exception.Message }
        }
    })

$showPasswords.AddIsCheckedChanged({ Update-ADTUiResultGrid })

$exportButton.AddClick({
        try {
            $options = [GliderUI.Avalonia.Platform.Storage.FilePickerSaveOptions]::new()
            $options.Title = 'Exporter les resultats'
            $options.DefaultExtension = 'csv'
            $options.SuggestedFileName = 'psadtoolkit-resultats.csv'
            $path = Get-ADTUiStoragePath ($window.StorageProvider.SaveFilePickerAsync($options).WaitForCompleted())
            if (-not $path) { return }
            $data = $script:Rows
            if (-not [bool]$showPasswords.IsChecked) { $data = @($data | Select-Object * -ExcludeProperty Password) }
            $data | Export-Csv -Path $path -Delimiter ';' -Encoding UTF8 -NoTypeInformation -ErrorAction Stop
            $statusText.Text = 'Export enregistre : ' + $path
        } catch {
            Show-ADTUiError $_.Exception.Message
        }
    })

#--- Onglets ------------------------------------------------------------------

# L annuaire est la section principale : c est par lui qu on navigue dans le
# domaine. Les traitements en lot historiques sont regroupes dans Outils, ou chacun
# garde son onglet, ses champs et son apercu.
$consoleTab = [GliderUI.Avalonia.Controls.TabItem]::new()
$consoleTab.Header = 'Annuaire'
$consoleTab.Content = New-ADTUiConsoleTab -Busy @($tabs, $changeDomain)
$tabs.Items.Add($consoleTab) | Out-Null

$script:ToolTabs = [GliderUI.Avalonia.Controls.TabControl]::new()
$script:ToolTabs.Margin = [GliderUI.Avalonia.Thickness]::new(4)
$toolsTab = [GliderUI.Avalonia.Controls.TabItem]::new()
$toolsTab.Header = 'Outils'
$toolsTab.Content = $script:ToolTabs
$script:ToolsTabIndex = $tabs.Items.Count
$tabs.Items.Add($toolsTab) | Out-Null

# Registre des champs de chaque onglet : la console pre-remplit l OU de destination
# de l import CSV et bascule dessus, plutot que de dupliquer l apercu d import.
$script:TabFields = @{}
$script:TabIndex = @{}

foreach ($spec in $specs) {
    $fields = @{}

    $content = [GliderUI.Avalonia.Controls.Grid]::new()
    $content.Margin = [GliderUI.Avalonia.Thickness]::new(16)
    $content.ColumnSpacing = 24
    $content.RowSpacing = 12
    foreach ($index in 0, 1) {
        $column = [GliderUI.Avalonia.Controls.ColumnDefinition]::new()
        $column.Width = [GliderUI.Avalonia.Controls.GridLength]::new(1, 'Star')
        $content.ColumnDefinitions.Add($column)
    }
    $rowCount = [int][Math]::Ceiling(@($spec.Fields).Count / 2) + 1
    for ($index = 0; $index -lt $rowCount; $index++) {
        $row = [GliderUI.Avalonia.Controls.RowDefinition]::new()
        $row.Height = [GliderUI.Avalonia.Controls.GridLength]::Auto
        $content.RowDefinitions.Add($row)
    }

    $position = 0
    foreach ($field in $spec.Fields) {
        $cell = New-ADTUiField -Key ([string]$field[0]) -Label ([string]$field[1]) -Kind ([string]$field[2]) -Command ([string]$spec.Command) -Fields $fields
        [GliderUI.Avalonia.Controls.Grid]::SetRow($cell, [int][Math]::Floor($position / 2))
        [GliderUI.Avalonia.Controls.Grid]::SetColumn($cell, $position % 2)
        $content.Children.Add($cell)
        $position++
    }

    $simulate = [GliderUI.Avalonia.Controls.CheckBox]::new()
    $simulate.Content = 'Simulation : verifier sans modifier Active Directory'
    $simulate.IsChecked = $true
    $simulate.VerticalAlignment = 'Center'
    $simulate.IsVisible = [bool]$spec.Write

    $note = [GliderUI.Avalonia.Controls.TextBlock]::new()
    $note.Text = 'Lecture du domaine. Le rapport HTML et les exports creent des fichiers locaux.'
    $note.VerticalAlignment = 'Center'
    $note.TextWrapping = 'Wrap'
    $note.IsVisible = -not [bool]$spec.Write

    $run = [GliderUI.Avalonia.Controls.Button]::new()
    $run.Content = 'Executer'
    if ([string]$spec.Command -eq 'Import-ADTUserFromCsv') { $run.Content = 'Apercu / Importer' }
    $run.Width = 200
    $run.HorizontalAlignment = 'Right'
    $run.HorizontalContentAlignment = 'Center'
    $run.Classes.Add('accent')
    $run.AddClick([GliderUI.EventCallback]@{
            # Le traitement se deroule dans le runspace principal : la fenetre reste
            # reactive, mais l onglet et la connexion sont neutralises pour interdire
            # une seconde operation simultanee.
            DisabledControlsWhileProcessing = @($run, $tabs, $changeDomain)
            ScriptBlock                     = { Invoke-ADTUiExecute -Spec $spec -Fields $fields -Simulate $simulate }.GetNewClosure()
        })

    $footerLeft = [GliderUI.Avalonia.Controls.StackPanel]::new()
    $footerLeft.Orientation = 'Horizontal'
    $footerLeft.Spacing = 8
    $footerLeft.VerticalAlignment = 'Center'
    $footerLeft.Children.Add($simulate)
    $footerLeft.Children.Add($note)

    $footer = [GliderUI.Avalonia.Controls.Grid]::new()
    $footer.Margin = [GliderUI.Avalonia.Thickness]::new(0, 12, 0, 0)
    $footer.ColumnSpacing = 16
    $leftColumn = [GliderUI.Avalonia.Controls.ColumnDefinition]::new()
    $leftColumn.Width = [GliderUI.Avalonia.Controls.GridLength]::new(1, 'Star')
    $rightColumn = [GliderUI.Avalonia.Controls.ColumnDefinition]::new()
    $rightColumn.Width = [GliderUI.Avalonia.Controls.GridLength]::Auto
    $footer.ColumnDefinitions.Add($leftColumn)
    $footer.ColumnDefinitions.Add($rightColumn)
    [GliderUI.Avalonia.Controls.Grid]::SetColumn($footerLeft, 0)
    [GliderUI.Avalonia.Controls.Grid]::SetColumn($run, 1)
    $footer.Children.Add($footerLeft)
    $footer.Children.Add($run)
    [GliderUI.Avalonia.Controls.Grid]::SetRow($footer, $rowCount - 1)
    [GliderUI.Avalonia.Controls.Grid]::SetColumn($footer, 0)
    [GliderUI.Avalonia.Controls.Grid]::SetColumnSpan($footer, 2)
    $content.Children.Add($footer)

    $tab = [GliderUI.Avalonia.Controls.TabItem]::new()
    $tab.Header = [string]$spec.Title
    $tab.Content = $content
    $script:TabFields[[string]$spec.Command] = $fields
    $script:TabIndex[[string]$spec.Command] = $script:ToolTabs.Items.Count
    $script:ToolTabs.Items.Add($tab) | Out-Null
}

#--- Demarrage -----------------------------------------------------------------

if ($SmokeTest) {
    # Integration continue : parcours scripte de toute l interface, puis sortie.
    . (Join-Path $script:Root 'Tests\CI\Smoke-Sequence.ps1')
    return
}

# On choisit le domaine avant d entrer : l annuaire s ouvre deja charge.
$initial = Show-ADTUiDomainChooser
if (-not $initial) { return }
Set-ADTUiConnection -Connection $initial
try { Update-ADTUiConsoleTree }
catch { Show-ADTUiError ('Lecture de l annuaire impossible : ' + $_.Exception.Message) }

try {
    $window.Show()
    # Les callbacks sont traites ici. Fermer la fenetre pendant une operation ne
    # l interrompt pas : elle se termine avant que le script ne rende la main.
    $window.WaitForClosed()
} finally {
    $script:Rows = @()
    $script:Operation = ''
    $script:Connection = @{ Server = ''; DomainName = ''; Credential = $null; Account = '' }
}
