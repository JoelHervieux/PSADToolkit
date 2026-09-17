#requires -version 7.4
using namespace GliderUI
using namespace GliderUI.Avalonia
using namespace GliderUI.Avalonia.Controls
using namespace GliderUI.Avalonia.Markup.Xaml

<#
    Briques communes de la console d administration.

    Ce fichier est charge par Start-PSADToolkit.ps1. Il n est pas concerne par la
    compatibilite Windows PowerShell 2.0 : seule l interface exige PowerShell 7.4.

    Principe de robustesse : GliderUI relaie les controles Avalonia vers un
    processus serveur. Tous les evenements ne sont pas forcement exposes selon la
    version installee. Les interactions de confort - menu contextuel, double-clic,
    selection multiple - sont donc branchees de maniere defensive, et CHAQUE action
    accessible par ces moyens reste accessible par un bouton de la barre d actions.
    Une version de GliderUI qui n exposerait pas ces evenements degrade l ergonomie,
    jamais les fonctionnalites.
#>

function Add-ADTUiEvent {
    # Branche un gestionnaire si la methode Add<Nom> existe sur le controle.
    # Rend $true si le branchement a reussi, $false sinon : l appelant peut alors
    # prevoir un repli sans faire echouer la construction de la fenetre.
    param($Target, [string]$Name, [scriptblock]$Handler)
    if (-not $Target -or -not $Handler) { return $false }
    $member = 'Add' + $Name
    try {
        $method = $Target.$member
        if (-not $method) { return $false }
        $null = $method.Invoke($Handler)
        return $true
    } catch {
        Write-Verbose ('Evenement {0} indisponible : {1}' -f $member, $_.Exception.Message)
        return $false
    }
}

function Get-ADTUiValue {
    # Lecture tolerante d une propriete : propriete .NET, puis indexeur.
    # Les lignes d une grille sont des DataSource GliderUI, dont l acces varie.
    param($Target, [string]$Name, $Default = '')
    if (-not $Target) { return $Default }
    try {
        $value = $Target.$Name
        if ($null -ne $value) { return $value }
    } catch { Write-Verbose ('Propriete {0} illisible.' -f $Name) }
    try {
        $value = $Target[$Name]
        if ($null -ne $value) { return $value }
    } catch { Write-Verbose ('Index {0} illisible.' -f $Name) }
    return $Default
}

function New-ADTUiButton {
    param([string]$Text, [int]$Width = 0, [switch]$Accent, [scriptblock]$OnClick, $DisableWhileBusy)
    $button = [Button]::new()
    $button.Content = $Text
    $button.HorizontalContentAlignment = 'Center'
    if ($Width -gt 0) { $button.Width = $Width }
    if ($Accent) { $button.Classes.Add('accent') }
    if ($OnClick) {
        if ($DisableWhileBusy) {
            $button.AddClick([EventCallback]@{
                    DisabledControlsWhileProcessing = @($DisableWhileBusy)
                    ScriptBlock                     = $OnClick
                })
        } else {
            $button.AddClick($OnClick)
        }
    }
    return $button
}

function New-ADTUiText {
    param([string]$Text, [switch]$Bold, [switch]$Wrap, [string]$Foreground)
    $block = [TextBlock]::new()
    $block.Text = $Text
    if ($Bold) { $block.FontWeight = 'Bold' }
    if ($Wrap) { $block.TextWrapping = 'Wrap' }
    if ($Foreground) { try { $block.Foreground = $Foreground } catch { Write-Verbose 'Couleur de texte refusee.' } }
    $block.VerticalAlignment = 'Center'
    return $block
}

function New-ADTUiRow {
    param([object[]]$Child, [int]$Spacing = 8, [string]$Align = 'Left')
    $panel = [StackPanel]::new()
    $panel.Orientation = 'Horizontal'
    $panel.Spacing = $Spacing
    $panel.HorizontalAlignment = $Align
    foreach ($item in $Child) { if ($item) { $panel.Children.Add($item) | Out-Null } }
    return $panel
}

function New-ADTUiStack {
    param([object[]]$Child, [int]$Spacing = 10, [int]$Margin = 0)
    $panel = [StackPanel]::new()
    $panel.Spacing = $Spacing
    if ($Margin -gt 0) { $panel.Margin = [Thickness]::new($Margin) }
    foreach ($item in $Child) { if ($item) { $panel.Children.Add($item) | Out-Null } }
    return $panel
}

function New-ADTUiTextField {
    # Etiquette au-dessus d une zone de saisie. Rend le panneau et la zone.
    param([string]$Label, [string]$Value = '', [switch]$ReadOnly, [int]$Height = 0)
    $box = [TextBox]::new()
    $box.Text = $Value
    if ($ReadOnly) { $box.IsReadOnly = $true }
    if ($Height -gt 0) {
        $box.Height = $Height
        $box.AcceptsReturn = $true
        $box.TextWrapping = 'Wrap'
    }
    $panel = [StackPanel]::new()
    $panel.Spacing = 4
    $panel.Children.Add((New-ADTUiText -Text $Label)) | Out-Null
    $panel.Children.Add($box) | Out-Null
    return @{ Panel = $panel; Box = $box }
}

function New-ADTUiCheck {
    param([string]$Label, [bool]$Checked = $false, [switch]$Disabled)
    $check = [CheckBox]::new()
    $check.Content = $Label
    $check.IsChecked = $Checked
    if ($Disabled) { $check.IsEnabled = $false }
    return $check
}

function New-ADTUiGridLayout {
    # Grille a colonnes etoilees ou automatiques. $Column contient 'Star', 'Auto'
    # ou une largeur en pixels.
    param([object[]]$Column, [int]$ColumnSpacing = 12, [int]$RowSpacing = 8)
    $grid = [Grid]::new()
    $grid.ColumnSpacing = $ColumnSpacing
    $grid.RowSpacing = $RowSpacing
    foreach ($item in $Column) {
        $definition = [ColumnDefinition]::new()
        if ($item -is [string] -and $item -eq 'Auto') { $definition.Width = [GridLength]::Auto }
        elseif ($item -is [string] -and $item -eq 'Star') { $definition.Width = [GridLength]::new(1, 'Star') }
        else { $definition.Width = [GridLength]::new([double]$item) }
        $grid.ColumnDefinitions.Add($definition)
    }
    return $grid
}

function Add-ADTUiGridRow {
    param($Grid, [string]$Height = 'Auto')
    $row = [RowDefinition]::new()
    if ($Height -eq 'Star') { $row.Height = [GridLength]::new(1, 'Star') }
    else { $row.Height = [GridLength]::Auto }
    $Grid.RowDefinitions.Add($row)
    return ($Grid.RowDefinitions.Count - 1)
}

function Add-ADTUiCell {
    param($Grid, $Child, [int]$Row, [int]$Column, [int]$ColumnSpan = 1)
    [Grid]::SetRow($Child, $Row)
    [Grid]::SetColumn($Child, $Column)
    if ($ColumnSpan -gt 1) { [Grid]::SetColumnSpan($Child, $ColumnSpan) }
    $Grid.Children.Add($Child) | Out-Null
}

function New-ADTUiMenu {
    # Construit un menu contextuel. Rend $null si GliderUI n expose pas ContextMenu :
    # la barre d actions prend alors le relais.
    param([hashtable[]]$Item)
    try {
        $menu = [ContextMenu]::new()
        foreach ($definition in $Item) {
            if ([string]$definition['Header'] -eq '-') {
                try { $menu.Items.Add([Separator]::new()) | Out-Null } catch { Write-Verbose 'Separateur de menu indisponible.' }
                continue
            }
            $entry = [MenuItem]::new()
            $entry.Header = [string]$definition['Header']
            $action = $definition['Action']
            if ($action) { $null = Add-ADTUiEvent -Target $entry -Name 'Click' -Handler $action }
            $menu.Items.Add($entry) | Out-Null
        }
        return $menu
    } catch {
        Write-Verbose ('Menu contextuel indisponible : {0}' -f $_.Exception.Message)
        return $null
    }
}

function Set-ADTUiMenu {
    param($Target, $Menu)
    if (-not $Target -or -not $Menu) { return $false }
    try { $Target.ContextMenu = $Menu; return $true }
    catch {
        Write-Verbose ('Menu contextuel non attache : {0}' -f $_.Exception.Message)
        return $false
    }
}

function New-ADTUiObjectGrid {
    # Grille des objets de l annuaire. SelectionMode Extended autorise la selection
    # multiple : les operations en lot en dependent.
    param([hashtable[]]$Column, [int]$Height = 0, [switch]$SingleSelection)
    $mode = 'Extended'
    if ($SingleSelection) { $mode = 'Single' }
    $xaml = New-Object System.Text.StringBuilder
    [void]$xaml.AppendLine('<DataGrid xmlns="https://github.com/avaloniaui" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"')
    [void]$xaml.AppendLine(('    IsReadOnly="True" CanUserResizeColumns="True" CanUserSortColumns="True" SelectionMode="{0}" GridLinesVisibility="Horizontal">' -f $mode))
    [void]$xaml.AppendLine('  <DataGrid.Columns>')
    foreach ($item in $Column) {
        $header = [System.Security.SecurityElement]::Escape([string]$item['Header'])
        [void]$xaml.AppendLine(('    <DataGridTextColumn Header="{0}" Binding="{{Binding {1}}}" SortMemberPath="{1}" />' -f $header, [string]$item['Path']))
    }
    [void]$xaml.AppendLine('  </DataGrid.Columns>')
    [void]$xaml.AppendLine('</DataGrid>')
    $grid = [AvaloniaRuntimeXamlLoader]::Parse($xaml.ToString(), $null)
    foreach ($gridColumn in $grid.Columns) {
        if ($gridColumn.SortMemberPath) { $gridColumn.CustomSortComparer = [DataSourcePropertyComparer]::new($gridColumn.SortMemberPath) }
    }
    if ($Height -gt 0) { $grid.Height = $Height }
    return $grid
}

function Get-ADTUiSelectedRow {
    # Lignes selectionnees, sous forme d objets PowerShell d origine.
    # La correspondance passe par une cle unique portee par chaque ligne plutot que
    # par l identite des objets : les controles vivent dans un autre processus et
    # ne peuvent pas etre compares par reference.
    param($Grid, $Row, [string]$KeyPath = 'RowKey')
    $selected = New-Object System.Collections.ArrayList
    $index = @{}
    foreach ($item in @($Row)) {
        $key = [string]$item.$KeyPath
        if ($key) { $index[$key] = $item }
    }

    $collection = $null
    try { $collection = $Grid.SelectedItems } catch { $collection = $null }
    if ($collection) {
        try {
            foreach ($entry in $collection) {
                $key = [string](Get-ADTUiValue -Target $entry -Name $KeyPath)
                if ($key -and $index.ContainsKey($key)) { [void]$selected.Add($index[$key]) }
            }
        } catch { Write-Verbose 'Selection multiple illisible, repli sur la ligne courante.' }
    }

    if (-not $selected.Count) {
        $current = $null
        try { $current = $Grid.SelectedItem } catch { $current = $null }
        if ($current) {
            $key = [string](Get-ADTUiValue -Target $current -Name $KeyPath)
            if ($key -and $index.ContainsKey($key)) { [void]$selected.Add($index[$key]) }
        }
    }

    if (-not $selected.Count) {
        # Dernier repli : l index de ligne, toujours expose meme lorsque la
        # selection multiple ne l est pas.
        $position = -1
        try { $position = [int]$Grid.SelectedIndex } catch { $position = -1 }
        $rows = @($Row)
        if ($position -ge 0 -and $position -lt $rows.Count) { [void]$selected.Add($rows[$position]) }
    }

    return @($selected)
}

function Set-ADTUiObjectGridSource {
    # Alimente une grille et rend les lignes affichees, cle de correspondance incluse.
    param($Grid, [hashtable[]]$Column, $Row, [string[]]$Hidden = @('DistinguishedName', 'ObjectClass', 'RowKey'))
    $rows = @($Row)
    $counter = 0
    foreach ($item in $rows) {
        if (-not $item.PSObject.Properties['RowKey']) {
            $item | Add-Member -MemberType NoteProperty -Name 'RowKey' -Value ('r{0}-{1}' -f $counter, ([string]$item.DistinguishedName))
        }
        $counter++
    }
    $Grid.ItemsSource = New-ADTUiDataSourceList -Column $Column -Row $rows -Extra $Hidden
    return $rows
}
