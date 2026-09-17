#requires -version 7.4
using namespace GliderUI
using namespace GliderUI.Avalonia
using namespace GliderUI.Avalonia.Controls

<#
    Editeur graphique des horaires de connexion (attribut logonHours).

    La grille compte sept lignes et vingt-quatre colonnes, dans l ordre de jours et
    avec la convention horaire de la culture de la machine. Les cases sont en HEURE
    LOCALE : la conversion vers le temps universel stocke dans l annuaire est faite
    par ConvertTo-ADTLogonHoursByte, cote module.
#>

function Get-ADTUiLogonHoursMask {
    # Lit les 168 cases et rend le masque local correspondant.
    param([hashtable]$Cell)
    $mask = New-Object System.Text.StringBuilder
    for ($slot = 0; $slot -lt 168; $slot++) {
        $box = $Cell[[string]$slot]
        if ($box -and [bool]$box.IsChecked) { [void]$mask.Append('1') } else { [void]$mask.Append('0') }
    }
    return $mask.ToString()
}

function Set-ADTUiLogonHoursMask {
    # Applique un masque aux 168 cases sans declencher le recalcul du resume a
    # chaque case : l indicateur Bulk le neutralise pendant l ecriture.
    param([hashtable]$Cell, [string]$Mask, [hashtable]$State)
    $State['Bulk'] = $true
    try {
        for ($slot = 0; $slot -lt 168; $slot++) {
            $box = $Cell[[string]$slot]
            if ($box) { $box.IsChecked = ($Mask[$slot] -eq '1') }
        }
    } finally { $State['Bulk'] = $false }
}

function Show-ADTUiLogonHoursEditor {
<#
    Affiche la grille et rend le masque choisi, ou $null si l operateur annule.
#>
    param(
        [string]$Mask = ('1' * 168),
        [string]$Title = 'Horaires de connexion',
        [string]$Subtitle = ''
    )
    if (-not (Test-ADTLogonHoursMask -Mask $Mask)) { $Mask = '1' * 168 }

    $state = @{ Mask = $null; Bulk = $false }
    $cells = @{}

    $dialog = [GliderUI.Avalonia.Controls.Window]::new()
    $dialog.Title = $Title
    $dialog.Width = 1080
    $dialog.Height = 620
    $dialog.WindowStartupLocation = 'CenterOwner'

    $summary = New-ADTUiText -Text '' -Wrap
    $refresh = {
        if ($state['Bulk']) { return }
        $current = Get-ADTUiLogonHoursMask -Cell $cells
        $summary.Text = 'Horaire retenu : ' + (ConvertTo-ADTLogonHoursText -Mask $current)
    }.GetNewClosure()

    $apply = {
        param([string]$NewMask)
        Set-ADTUiLogonHoursMask -Cell $cells -Mask $NewMask -State $state
        & $refresh
    }.GetNewClosure()

    # --- Grille : colonne des jours + 24 colonnes d heures ---------------------
    $columns = @('Auto')
    for ($hour = 0; $hour -lt 24; $hour++) { $columns += 34 }
    $grid = New-ADTUiGridLayout -Column $columns -ColumnSpacing 2 -RowSpacing 2

    $null = Add-ADTUiGridRow -Grid $grid
    Add-ADTUiCell -Grid $grid -Child (New-ADTUiText -Text '') -Row 0 -Column 0
    for ($hour = 0; $hour -lt 24; $hour++) {
        $hourIndex = $hour
        $header = New-ADTUiButton -Text (Format-ADTHourHeader -Hour $hourIndex) -OnClick {
            # Bascule toute la colonne : si une seule case est vide, on remplit.
            $current = Get-ADTUiLogonHoursMask -Cell $cells
            $fill = $false
            for ($day = 0; $day -lt 7; $day++) { if ($current[($day * 24) + $hourIndex] -ne '1') { $fill = $true } }
            $state['Bulk'] = $true
            try {
                for ($day = 0; $day -lt 7; $day++) {
                    $box = $cells[[string](($day * 24) + $hourIndex)]
                    if ($box) { $box.IsChecked = $fill }
                }
            } finally { $state['Bulk'] = $false }
            & $refresh
        }.GetNewClosure()
        try { $header.Padding = [GliderUI.Avalonia.Thickness]::new(0) } catch { Write-Verbose 'Marge de bouton refusee.' }
        Add-ADTUiCell -Grid $grid -Child $header -Row 0 -Column ($hour + 1)
    }

    $rowNumber = 0
    foreach ($dayIndex in (Get-ADTWeekDayOrder)) {
        $rowNumber = Add-ADTUiGridRow -Grid $grid
        $day = $dayIndex
        $dayButton = New-ADTUiButton -Text (Format-ADTDayName -DayOfWeek $day) -Width 120 -OnClick {
            $current = Get-ADTUiLogonHoursMask -Cell $cells
            $fill = ((Get-ADTLogonHoursDayMask -Mask $current -DayOfWeek $day) -ne ('1' * 24))
            $state['Bulk'] = $true
            try {
                for ($hour = 0; $hour -lt 24; $hour++) {
                    $box = $cells[[string](($day * 24) + $hour)]
                    if ($box) { $box.IsChecked = $fill }
                }
            } finally { $state['Bulk'] = $false }
            & $refresh
        }.GetNewClosure()
        Add-ADTUiCell -Grid $grid -Child $dayButton -Row $rowNumber -Column 0

        for ($hour = 0; $hour -lt 24; $hour++) {
            $slot = ($day * 24) + $hour
            $box = [GliderUI.Avalonia.Controls.CheckBox]::new()
            $box.IsChecked = ($Mask[$slot] -eq '1')
            $box.HorizontalAlignment = 'Center'
            try { $box.ToolTip = ((Format-ADTDayName -DayOfWeek $day) + ' ' + (Format-ADTHourLabel -Hour $hour) + ' - ' + (Format-ADTHourLabel -Hour ($hour + 1))) }
            catch { Write-Verbose 'Infobulle refusee.' }
            $null = Add-ADTUiEvent -Target $box -Name 'IsCheckedChanged' -Handler $refresh
            $cells[[string]$slot] = $box
            Add-ADTUiCell -Grid $grid -Child $box -Row $rowNumber -Column ($hour + 1)
        }
    }

    # --- Modeles ---------------------------------------------------------------
    $presets = New-ADTUiRow -Child @(
        (New-ADTUiText -Text 'Modeles :'),
        (New-ADTUiButton -Text 'Toutes les heures' -OnClick { & $apply ('1' * 168) }.GetNewClosure()),
        (New-ADTUiButton -Text 'Aucune heure' -OnClick { & $apply ('0' * 168) }.GetNewClosure()),
        (New-ADTUiButton -Text 'Semaine 8 h - 18 h' -OnClick {
                & $apply (New-ADTLogonHoursMask -Day 1, 2, 3, 4, 5 -StartHour 8 -EndHour 18)
            }.GetNewClosure()),
        (New-ADTUiButton -Text 'Semaine 7 h - 19 h + samedi matin' -OnClick {
                $base = New-ADTLogonHoursMask -Day 1, 2, 3, 4, 5 -StartHour 7 -EndHour 19
                $extra = New-ADTLogonHoursMask -Day 6 -StartHour 8 -EndHour 13
                $merged = New-Object System.Text.StringBuilder
                for ($slot = 0; $slot -lt 168; $slot++) {
                    if ($base[$slot] -eq '1' -or $extra[$slot] -eq '1') { [void]$merged.Append('1') } else { [void]$merged.Append('0') }
                }
                & $apply $merged.ToString()
            }.GetNewClosure()),
        (New-ADTUiButton -Text 'Inverser' -OnClick {
                $current = Get-ADTUiLogonHoursMask -Cell $cells
                $inverted = New-Object System.Text.StringBuilder
                for ($slot = 0; $slot -lt 168; $slot++) {
                    if ($current[$slot] -eq '1') { [void]$inverted.Append('0') } else { [void]$inverted.Append('1') }
                }
                & $apply $inverted.ToString()
            }.GetNewClosure())
    )

    # --- Pied ------------------------------------------------------------------
    $offset = Get-ADTLogonHoursOffset
    $offsetText = 'UTC'
    if ($offset -gt 0) { $offsetText = 'UTC+' + $offset }
    if ($offset -lt 0) { $offsetText = 'UTC' + $offset }
    $note = New-ADTUiText -Wrap -Text (
        'Une case cochee autorise la connexion pendant cette heure. Les heures sont celles du poste (' +
        $offsetText + ') ; Active Directory les enregistre en temps universel, comme la console Microsoft.')

    $cancel = New-ADTUiButton -Text 'Annuler' -Width 150 -OnClick { $dialog.Close() }.GetNewClosure()
    $accept = New-ADTUiButton -Text 'Valider l horaire' -Width 190 -Accent -OnClick {
        $chosen = Get-ADTUiLogonHoursMask -Cell $cells
        if ($chosen -eq ('0' * 168)) {
            if (-not (Show-ADTUiDialog -Title 'Aucune heure autorisee' -AcceptText 'Confirmer' -CancelText 'Revenir a la grille' -Message (
                        'Cet horaire n autorise aucune heure de connexion. Les comptes vises ne pourront plus ouvrir de session tant qu il ne sera pas modifie.' +
                        [Environment]::NewLine + [Environment]::NewLine + 'Confirmer ce choix ?'))) {
                return
            }
        }
        $state.Mask = $chosen
        $dialog.Close()
    }.GetNewClosure()

    $panel = New-ADTUiStack -Margin 16 -Spacing 12 -Child @(
        (New-ADTUiText -Text $Title -Bold),
        $(if ($Subtitle) { New-ADTUiText -Text $Subtitle -Wrap } else { $null }),
        $presets,
        (New-ADTUiText -Text 'Cliquer un jour ou une heure bascule toute la ligne ou toute la colonne.'),
        $grid,
        $summary,
        $note,
        (New-ADTUiRow -Align 'Right' -Spacing 12 -Child @($cancel, $accept))
    )

    $scroll = [GliderUI.Avalonia.Controls.ScrollViewer]::new()
    $scroll.Content = $panel

    & $refresh
    $dialog.Content = $scroll
    $dialog.Show()
    $dialog.WaitForClosed()
    return $state.Mask
}
