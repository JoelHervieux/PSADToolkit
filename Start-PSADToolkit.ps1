#requires -version 7.4
using namespace GliderUI
using namespace GliderUI.Avalonia
using namespace GliderUI.Avalonia.Controls
using namespace GliderUI.Avalonia.Markup.Xaml
using namespace GliderUI.Avalonia.Platform.Storage

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
param()
$ErrorActionPreference = 'Stop'
$script:Root = $PSScriptRoot

if (-not $IsWindows) {
    throw 'PSADToolkit interroge Active Directory via System.DirectoryServices, disponible uniquement sous Windows.'
}
if (-not (Get-Module -ListAvailable -Name GliderUI)) {
    throw "Module GliderUI introuvable. Installer :`n    Install-PSResource -Name GliderUI`n    Install-GLIServer"
}
Import-Module GliderUI -ErrorAction Stop
Import-Module (Join-Path $script:Root 'PSADToolkit.psd1') -Force -ErrorAction Stop
# Helpers prives du module : l apercu d import doit calculer l OU cible et les groupes
# exactement comme l import lui-meme, la console reutilise le backend LDAP, et les
# formats regionaux comme les horaires de connexion sont partages avec les fonctions
# publiques pour que l affichage et l ecriture ne divergent jamais.
foreach ($helper in @(
        'DirectoryBackend.ps1', 'DirectoryConsole.ps1', 'DirectoryWrite.ps1',
        'CsvHelpers.ps1', 'Format-ADTDisplay.ps1', 'LogonHours.ps1', 'ObjectStatus.ps1'
    )) {
    . (Join-Path $script:Root (Join-Path 'Private' $helper))
}

# Console d administration : un fichier par domaine fonctionnel. L ordre importe
# peu, les fonctions ne sont appelees qu une fois la fenetre construite.
foreach ($module in @('Common.ps1', 'LogonHours.ps1', 'Dialogs.ps1', 'Properties.ps1', 'Console.ps1')) {
    . (Join-Path $script:Root (Join-Path 'UI' $module))
}

$script:Rows = @()
$script:Operation = ''

#--- Aides generales ----------------------------------------------------------

function Get-ADTUiConnection {
    $parameters = @{}
    $server = $serverBox.Text
    if ($server) { $server = $server.Trim() }
    if ($server) { $parameters['Server'] = $server }
    if ([bool]$otherAccount.IsChecked) {
        $user = $userBox.Text
        if ($user) { $user = $user.Trim() }
        if (-not $user -or -not $passwordBox.Text) { throw 'Indiquer le compte DOMAINE\utilisateur (ou UPN) et son mot de passe.' }
        $secure = New-Object System.Security.SecureString
        foreach ($character in $passwordBox.Text.ToCharArray()) { $secure.AppendChar($character) }
        $secure.MakeReadOnly()
        $parameters['Credential'] = New-Object System.Management.Automation.PSCredential($user, $secure)
    }
    return $parameters
}

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
    $grid = [AvaloniaRuntimeXamlLoader]::Parse($xaml.ToString(), $null)
    # Ne pas nommer cette variable $column : les noms de variables sont insensibles a
    # la casse, elle designerait le parametre $Column et sa contrainte [hashtable[]].
    foreach ($gridColumn in $grid.Columns) {
        if ($gridColumn.SortMemberPath) { $gridColumn.CustomSortComparer = [DataSourcePropertyComparer]::new($gridColumn.SortMemberPath) }
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
    $items = [GliderUI.System.Collections.ObjectModel.ObservableCollection[DataSource]]::new()
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
        $items.Add([DataSource]$values)
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

    $text = [TextBlock]::new()
    $text.Text = $Message
    $text.TextWrapping = 'Wrap'

    $scroll = [ScrollViewer]::new()
    $scroll.Content = $text
    $scroll.MaxHeight = 260

    $buttons = [StackPanel]::new()
    $buttons.Orientation = 'Horizontal'
    $buttons.Spacing = 12
    $buttons.HorizontalAlignment = 'Right'

    $dialog = [Window]::new()
    $dialog.Title = $Title
    $dialog.Width = 640
    $dialog.Height = 320
    $dialog.WindowStartupLocation = 'CenterOwner'

    if ($CancelText) {
        $cancel = [Button]::new()
        $cancel.Content = $CancelText
        $cancel.Width = 150
        $cancel.HorizontalContentAlignment = 'Center'
        $cancel.AddClick({ $dialog.Close() }.GetNewClosure())
        $buttons.Children.Add($cancel)
    }

    $accept = [Button]::new()
    $accept.Content = $AcceptText
    $accept.Width = 150
    $accept.HorizontalContentAlignment = 'Center'
    $accept.Classes.Add('accent')
    $accept.AddClick({ $state.Accepted = $true; $dialog.Close() }.GetNewClosure())
    $buttons.Children.Add($accept)

    $panel = [StackPanel]::new()
    $panel.Margin = [Thickness]::new(20)
    $panel.Spacing = 18
    $panel.Children.Add($scroll)
    $panel.Children.Add($buttons)

    $dialog.Content = $panel
    $dialog.Show()
    $dialog.WaitForClosed()
    return $state.Accepted
}

function Show-ADTUiError {
    param([string]$Message)
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

    $rootItem = [TreeViewItem]::new()
    $rootItem.Header = $domainDN
    $rootItem.Tag = $domainDN
    $rootItem.IsExpanded = $true

    $index = @{ $domainDN = $rootItem }
    foreach ($organizationalUnit in $organizationalUnits) {
        $item = [TreeViewItem]::new()
        $item.Header = $organizationalUnit.Name
        $item.Tag = $organizationalUnit.DN
        $parent = $rootItem
        $parentDN = Get-ADTUiParentDN $organizationalUnit.DN
        if ($parentDN -and $index.ContainsKey($parentDN)) { $parent = $index[$parentDN] }
        $parent.Items.Add($item) | Out-Null
        $index[$organizationalUnit.DN] = $item
    }

    $tree = [TreeView]::new()
    $tree.Height = 420
    $tree.Items.Add($rootItem) | Out-Null

    $dnBox = [TextBox]::new()
    $dnBox.IsReadOnly = $true
    $dnBox.Text = $domainDN

    $tree.AddSelectionChanged({
            $selected = $tree.SelectedItem
            if ($selected) { $dnBox.Text = [string]$selected.Tag }
        }.GetNewClosure())

    $state = @{ DN = $null }
    $dialog = [Window]::new()
    $dialog.Title = 'Selectionner une unite d organisation'
    $dialog.Width = 760
    $dialog.Height = 620
    $dialog.WindowStartupLocation = 'CenterOwner'

    $cancel = [Button]::new()
    $cancel.Content = 'Annuler'
    $cancel.Width = 150
    $cancel.HorizontalContentAlignment = 'Center'
    $cancel.AddClick({ $dialog.Close() }.GetNewClosure())

    $accept = [Button]::new()
    $accept.Content = 'Selectionner'
    $accept.Width = 150
    $accept.HorizontalContentAlignment = 'Center'
    $accept.Classes.Add('accent')
    $accept.AddClick({ $state.DN = $dnBox.Text; $dialog.Close() }.GetNewClosure())

    $buttons = [StackPanel]::new()
    $buttons.Orientation = 'Horizontal'
    $buttons.Spacing = 12
    $buttons.HorizontalAlignment = 'Right'
    $buttons.Children.Add($cancel)
    $buttons.Children.Add($accept)

    $count = [TextBlock]::new()
    $count.Text = ('{0} unite(s) d organisation lue(s) dans {1}.' -f $organizationalUnits.Count, $domainDN)
    $count.TextWrapping = 'Wrap'

    $panel = [StackPanel]::new()
    $panel.Margin = [Thickness]::new(18)
    $panel.Spacing = 12
    $panel.Children.Add($count)
    $panel.Children.Add($tree)
    $panel.Children.Add($dnBox)
    $panel.Children.Add($buttons)

    $dialog.Content = $panel
    $dialog.Show()
    $dialog.WaitForClosed()
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
    $dialog = [Window]::new()
    $dialog.Title = 'Apercu avant import'
    $dialog.Width = 1080
    $dialog.Height = 640
    $dialog.WindowStartupLocation = 'CenterOwner'

    $cancel = [Button]::new()
    $cancel.Content = 'Annuler'
    $cancel.Width = 150
    $cancel.HorizontalContentAlignment = 'Center'
    $cancel.AddClick({ $dialog.Close() }.GetNewClosure())

    $accept = [Button]::new()
    $accept.Content = 'Continuer'
    $accept.Width = 150
    $accept.HorizontalContentAlignment = 'Center'
    $accept.Classes.Add('accent')
    $accept.AddClick({ $state.Accepted = $true; $dialog.Close() }.GetNewClosure())

    $buttons = [StackPanel]::new()
    $buttons.Orientation = 'Horizontal'
    $buttons.Spacing = 12
    $buttons.HorizontalAlignment = 'Right'
    $buttons.Children.Add($cancel)
    $buttons.Children.Add($accept)

    $header = [TextBlock]::new()
    $header.Text = ('Apercu de {0} utilisateur(s). Verifier les OU et les groupes avant de continuer.' -f $rows.Count)
    $header.TextWrapping = 'Wrap'

    $panel = [StackPanel]::new()
    $panel.Margin = [Thickness]::new(18)
    $panel.Spacing = 12
    $panel.Children.Add($header)
    $panel.Children.Add($grid)
    $panel.Children.Add($buttons)

    $dialog.Content = $panel
    $dialog.Show()
    $dialog.WaitForClosed()
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
            $options = [FolderPickerOpenOptions]::new()
            $options.Title = 'Selectionner un dossier'
            $path = Get-ADTUiStoragePath ($window.StorageProvider.OpenFolderPickerAsync($options).WaitForCompleted())
            if ($path) { $Control.Text = $path }
            return
        }
        if ($Kind -eq 'open') {
            $options = [FilePickerOpenOptions]::new()
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
        $options = [FilePickerSaveOptions]::new()
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
    $panel = [StackPanel]::new()
    $panel.Spacing = 4

    if ($Kind -eq 'check') {
        $control = [CheckBox]::new()
        $control.Content = $Label
        $panel.Margin = [Thickness]::new(0, 18, 0, 0)
        $panel.Children.Add($control)
    } else {
        $caption = [TextBlock]::new()
        $caption.Text = $Label
        $panel.Children.Add($caption)

        if ($Kind -eq 'number') {
            $control = [NumericUpDown]::new()
            $control.Minimum = 1
            $control.Maximum = 3650
            $control.Value = 90
            $panel.Children.Add($control)
        } elseif ($Kind -eq 'delimiter') {
            $control = [ComboBox]::new()
            $control.Items.Add(';') | Out-Null
            $control.Items.Add(',') | Out-Null
            $control.SelectedIndex = 0
            $control.HorizontalAlignment = 'Stretch'
            $panel.Children.Add($control)
        } else {
            $control = [TextBox]::new()
            if ($Key -eq 'Reason') { $control.Text = 'Depart de l employe' }
            if (@('ou', 'open', 'savecsv', 'savehtml', 'folder') -contains $Kind) {
                $browse = [Button]::new()
                $browse.Content = '...'
                $browse.Width = 44
                $browse.HorizontalContentAlignment = 'Center'
                $browse.AddClick({ Invoke-ADTUiBrowse -Kind $Kind -Command $Command -Control $control -Fields $Fields }.GetNewClosure())

                $line = [Grid]::new()
                $line.ColumnSpacing = 6
                $textColumn = [ColumnDefinition]::new()
                $textColumn.Width = [GridLength]::new(1, 'Star')
                $buttonColumn = [ColumnDefinition]::new()
                $buttonColumn.Width = [GridLength]::Auto
                $line.ColumnDefinitions.Add($textColumn)
                $line.ColumnDefinitions.Add($buttonColumn)
                [Grid]::SetColumn($control, 0)
                [Grid]::SetColumn($browse, 1)
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
        if ($script:Operation -eq 'Test-ADTPrerequisite' -and $script:Rows.Count -and $script:Rows[0].Ready) {
            $serverBox.Text = [string]$script:Rows[0].Server
            $statusText.Text = 'Connecte a ' + [string]$script:Rows[0].DomainName + ' via ' + [string]$script:Rows[0].Server
        }
    } catch {
        $detailsBox.Text = $_.Exception.Message
        $statusText.Text = 'Operation interrompue : consulter le detail.'
    } finally {
        $progress.IsIndeterminate = $false
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
        Title="PSADToolkit 3.1.0-test1 | Administration Active Directory"
        Width="1360" Height="1000">
  <Grid RowDefinitions="Auto,Auto,Auto,Auto,*,Auto,Auto">

    <Border Grid.Row="0" Background="#162840" Padding="24,14">
      <StackPanel Orientation="Horizontal" Spacing="18">
        <TextBlock Text="PSADToolkit" Foreground="White" FontSize="24" FontWeight="Bold" VerticalAlignment="Center" />
        <TextBlock Text="Console d administration, comptes, acces et audits Active Directory" Foreground="#BED4ED" VerticalAlignment="Center" />
      </StackPanel>
    </Border>

    <Border Grid.Row="1" x:Name="connection_panel" Margin="16,14,16,0" Padding="16"
            BorderBrush="#C9D4E2" BorderThickness="1" CornerRadius="6">
      <StackPanel Spacing="10">
        <Grid ColumnDefinitions="2*,Auto,2*,2*,Auto" ColumnSpacing="14">
          <StackPanel Grid.Column="0" Spacing="4">
            <TextBlock Text="Controleur de domaine (FQDN, vide = automatique)" />
            <TextBox x:Name="server_box" Watermark="dc01.contoso.local" />
          </StackPanel>
          <StackPanel Grid.Column="1" VerticalAlignment="Bottom">
            <CheckBox x:Name="other_account" Content="Autre compte" />
          </StackPanel>
          <StackPanel Grid.Column="2" Spacing="4">
            <TextBlock Text="Compte (DOMAINE\utilisateur ou UPN)" />
            <TextBox x:Name="user_box" IsEnabled="False" />
          </StackPanel>
          <StackPanel Grid.Column="3" Spacing="4">
            <TextBlock Text="Mot de passe" />
            <TextBox x:Name="password_box" PasswordChar="*" IsEnabled="False" />
          </StackPanel>
          <StackPanel Grid.Column="4" VerticalAlignment="Bottom">
            <Button x:Name="test_button" Content="Tester la connexion" Classes="accent"
                    Width="190" HorizontalContentAlignment="Center" />
          </StackPanel>
        </Grid>
        <TextBlock Text="Compte de la session Windows utilise par defaut. Les droits AD delegues sont necessaires : etre administrateur local ne les donne pas."
                   Foreground="#4A5A6E" TextWrapping="Wrap" />
      </StackPanel>
    </Border>

    <TabControl Grid.Row="2" x:Name="tabs" Margin="16,14,16,0" />

    <Grid Grid.Row="3" Margin="16,16,16,0" ColumnDefinitions="Auto,*,Auto" ColumnSpacing="16">
      <TextBlock Grid.Column="0" Text="Resultats" FontWeight="Bold" VerticalAlignment="Center" />
      <CheckBox Grid.Column="1" x:Name="show_passwords" Content="Afficher / exporter les mots de passe generes" />
      <Button Grid.Column="2" x:Name="export_button" Content="Exporter les resultats CSV" IsEnabled="False" />
    </Grid>

    <Border Grid.Row="4" Margin="16,8,16,0" MinHeight="150"
            BorderBrush="#C9D4E2" BorderThickness="1" CornerRadius="4">
      <ContentControl x:Name="grid_host" />
    </Border>

    <TextBox Grid.Row="5" x:Name="details_box" Margin="16,10,16,0" Height="96"
             AcceptsReturn="True" IsReadOnly="True" TextWrapping="Wrap"
             Watermark="Avertissements et erreurs de la derniere operation." />

    <Grid Grid.Row="6" Margin="16,10,16,16" ColumnDefinitions="*,Auto" ColumnSpacing="16">
      <TextBlock Grid.Column="0" x:Name="status_text" VerticalAlignment="Center" TextWrapping="Wrap"
                 Text="Pret. Tester la connexion, puis charger l arborescence dans l onglet Console AD." />
      <ProgressBar Grid.Column="1" x:Name="progress" Width="220" VerticalAlignment="Center" />
    </Grid>
  </Grid>
</Window>
'@

$window = [AvaloniaRuntimeXamlLoader]::Parse($mainXaml, $null)
$connectionPanel = $window.FindControl('connection_panel')
$serverBox = $window.FindControl('server_box')
$otherAccount = $window.FindControl('other_account')
$userBox = $window.FindControl('user_box')
$passwordBox = $window.FindControl('password_box')
$testButton = $window.FindControl('test_button')
$tabs = $window.FindControl('tabs')
$showPasswords = $window.FindControl('show_passwords')
$exportButton = $window.FindControl('export_button')
$gridHost = $window.FindControl('grid_host')
$detailsBox = $window.FindControl('details_box')
$statusText = $window.FindControl('status_text')
$progress = $window.FindControl('progress')

$otherAccount.AddIsCheckedChanged({
        $enabled = [bool]$otherAccount.IsChecked
        $userBox.IsEnabled = $enabled
        $passwordBox.IsEnabled = $enabled
        if (-not $enabled) { $passwordBox.Text = '' }
    })

$testButton.AddClick([EventCallback]@{
        DisabledControlsWhileProcessing = @($testButton, $tabs)
        ScriptBlock                     = {
            try { Invoke-ADTUiCommand -Command 'Test-ADTPrerequisite' -Parameters (Get-ADTUiConnection) }
            catch { Show-ADTUiError $_.Exception.Message }
        }
    })

$showPasswords.AddIsCheckedChanged({ Update-ADTUiResultGrid })

$exportButton.AddClick({
        try {
            $options = [FilePickerSaveOptions]::new()
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

# La console d administration est le premier onglet : c est par elle qu on navigue
# dans le domaine. Les onglets historiques restent inchanges derriere.
$consoleTab = [TabItem]::new()
$consoleTab.Header = 'Console AD'
$consoleTab.Content = New-ADTUiConsoleTab -Busy @($tabs, $connectionPanel)
$tabs.Items.Add($consoleTab) | Out-Null

# Registre des champs de chaque onglet : la console pre-remplit l OU de destination
# de l import CSV et bascule dessus, plutot que de dupliquer l apercu d import.
$script:TabFields = @{}
$script:TabIndex = @{}

foreach ($spec in $specs) {
    $fields = @{}

    $content = [Grid]::new()
    $content.Margin = [Thickness]::new(16)
    $content.ColumnSpacing = 24
    $content.RowSpacing = 12
    foreach ($index in 0, 1) {
        $column = [ColumnDefinition]::new()
        $column.Width = [GridLength]::new(1, 'Star')
        $content.ColumnDefinitions.Add($column)
    }
    $rowCount = [int][Math]::Ceiling(@($spec.Fields).Count / 2) + 1
    for ($index = 0; $index -lt $rowCount; $index++) {
        $row = [RowDefinition]::new()
        $row.Height = [GridLength]::Auto
        $content.RowDefinitions.Add($row)
    }

    $position = 0
    foreach ($field in $spec.Fields) {
        $cell = New-ADTUiField -Key ([string]$field[0]) -Label ([string]$field[1]) -Kind ([string]$field[2]) -Command ([string]$spec.Command) -Fields $fields
        [Grid]::SetRow($cell, [int][Math]::Floor($position / 2))
        [Grid]::SetColumn($cell, $position % 2)
        $content.Children.Add($cell)
        $position++
    }

    $simulate = [CheckBox]::new()
    $simulate.Content = 'Simulation : verifier sans modifier Active Directory'
    $simulate.IsChecked = $true
    $simulate.VerticalAlignment = 'Center'
    $simulate.IsVisible = [bool]$spec.Write

    $note = [TextBlock]::new()
    $note.Text = 'Lecture du domaine. Le rapport HTML et les exports creent des fichiers locaux.'
    $note.VerticalAlignment = 'Center'
    $note.TextWrapping = 'Wrap'
    $note.IsVisible = -not [bool]$spec.Write

    $run = [Button]::new()
    $run.Content = 'Executer'
    if ([string]$spec.Command -eq 'Import-ADTUserFromCsv') { $run.Content = 'Apercu / Importer' }
    $run.Width = 200
    $run.HorizontalAlignment = 'Right'
    $run.HorizontalContentAlignment = 'Center'
    $run.Classes.Add('accent')
    $run.AddClick([EventCallback]@{
            # Le traitement se deroule dans le runspace principal : la fenetre reste
            # reactive, mais l onglet et la connexion sont neutralises pour interdire
            # une seconde operation simultanee.
            DisabledControlsWhileProcessing = @($run, $tabs, $connectionPanel)
            ScriptBlock                     = { Invoke-ADTUiExecute -Spec $spec -Fields $fields -Simulate $simulate }.GetNewClosure()
        })

    $footerLeft = [StackPanel]::new()
    $footerLeft.Orientation = 'Horizontal'
    $footerLeft.Spacing = 8
    $footerLeft.VerticalAlignment = 'Center'
    $footerLeft.Children.Add($simulate)
    $footerLeft.Children.Add($note)

    $footer = [Grid]::new()
    $footer.Margin = [Thickness]::new(0, 12, 0, 0)
    $footer.ColumnSpacing = 16
    $leftColumn = [ColumnDefinition]::new()
    $leftColumn.Width = [GridLength]::new(1, 'Star')
    $rightColumn = [ColumnDefinition]::new()
    $rightColumn.Width = [GridLength]::Auto
    $footer.ColumnDefinitions.Add($leftColumn)
    $footer.ColumnDefinitions.Add($rightColumn)
    [Grid]::SetColumn($footerLeft, 0)
    [Grid]::SetColumn($run, 1)
    $footer.Children.Add($footerLeft)
    $footer.Children.Add($run)
    [Grid]::SetRow($footer, $rowCount - 1)
    [Grid]::SetColumn($footer, 0)
    [Grid]::SetColumnSpan($footer, 2)
    $content.Children.Add($footer)

    $tab = [TabItem]::new()
    $tab.Header = [string]$spec.Title
    $tab.Content = $content
    $script:TabFields[[string]$spec.Command] = $fields
    $script:TabIndex[[string]$spec.Command] = $tabs.Items.Count
    $tabs.Items.Add($tab) | Out-Null
}

#--- Boucle d evenements ------------------------------------------------------

try {
    $window.Show()
    # Les callbacks sont traites ici. Fermer la fenetre pendant une operation ne
    # l interrompt pas : elle se termine avant que le script ne rende la main.
    $window.WaitForClosed()
} finally {
    $script:Rows = @()
    $script:Operation = ''
}
