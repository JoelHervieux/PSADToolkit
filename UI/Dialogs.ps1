#requires -version 7.4
using namespace GliderUI
using namespace GliderUI.Avalonia
using namespace GliderUI.Avalonia.Controls
using namespace GliderUI.Avalonia.Platform.Storage

<#
    Boites de dialogue de la console : creation d objets, mots de passe,
    appartenances, selection de membres, confirmation des ecritures.

    Toutes les ecritures passent par Invoke-ADTUiCommand, donc par les fonctions
    publiques du module : meme validation, meme journalisation, meme grille de
    resultats et meme export CSV que les onglets historiques. La console n ecrit
    jamais dans l annuaire par un chemin qui lui serait propre.
#>

function Confirm-ADTUiConsoleWrite {
    # Recapitulatif avant ecriture. La simulation court-circuite la confirmation :
    # rien ne sera modifie.
    param([string]$Action, [string[]]$Target, [string]$Detail, [bool]$Simulate)
    if ($Simulate) { return $true }
    $lines = @('Operation : ' + $Action)
    if ($Detail) { $lines += $Detail }
    $lines += ''
    $lines += ('Objets concernes : {0}' -f @($Target).Count)
    foreach ($item in (@($Target) | Select-Object -First 25)) { $lines += '  - ' + $item }
    if (@($Target).Count -gt 25) { $lines += ('  ... et {0} autre(s).' -f (@($Target).Count - 25)) }
    $lines += ''
    $lines += 'Appliquer ces modifications a Active Directory ?'
    return (Show-ADTUiDialog -Title 'Confirmer les modifications' -Message ($lines -join [Environment]::NewLine) `
            -AcceptText 'Appliquer' -CancelText 'Annuler')
}

function Show-ADTUiNewUser {
    # Formulaire de creation de compte. S appuie sur New-ADTUser : identifiant
    # calcule, mot de passe genere, groupes, dossier personnel et journalisation.
    param([string]$Path)
    $state = @{ Run = $false }

    $givenName = New-ADTUiTextField -Label 'Prenom *'
    $surname = New-ADTUiTextField -Label 'Nom *'
    $sam = New-ADTUiTextField -Label 'Identifiant (vide = calcule)'
    $title = New-ADTUiTextField -Label 'Fonction'
    $department = New-ADTUiTextField -Label 'Service'
    $mail = New-ADTUiTextField -Label 'Courriel'
    $groups = New-ADTUiTextField -Label 'Groupes (separes par ;)'
    $target = New-ADTUiTextField -Label 'OU cible' -Value $Path -ReadOnly

    $disabled = New-ADTUiCheck -Label 'Creer le compte desactive'
    $noChange = New-ADTUiCheck -Label 'Ne pas forcer le changement de mot de passe'
    $document = New-ADTUiCheck -Label 'Generer le document de remise des identifiants' -Checked $false

    $length = [GliderUI.Avalonia.Controls.NumericUpDown]::new()
    $length.Minimum = 12
    $length.Maximum = 128
    $length.Value = 16
    $lengthPanel = New-ADTUiStack -Spacing 4 -Child @((New-ADTUiText -Text 'Longueur du mot de passe'), $length)

    $browse = New-ADTUiButton -Text 'Changer d OU...' -OnClick {
        $selected = Select-ADTUiOrganizationalUnit
        if ($selected) { $target.Box.Text = $selected }
    }.GetNewClosure()

    $dialog = [GliderUI.Avalonia.Controls.Window]::new()
    $dialog.Title = 'Nouvel utilisateur'
    $dialog.Width = 820
    $dialog.Height = 680
    $dialog.WindowStartupLocation = 'CenterOwner'

    $cancel = New-ADTUiButton -Text 'Annuler' -Width 150 -OnClick { $dialog.Close() }.GetNewClosure()
    $accept = New-ADTUiButton -Text 'Creer' -Width 170 -Accent -OnClick {
        if (-not $givenName.Box.Text -or -not $surname.Box.Text) {
            Show-ADTUiError 'Le prenom et le nom sont obligatoires.'
            return
        }
        if (-not $target.Box.Text) {
            Show-ADTUiError 'Selectionner une unite d organisation cible.'
            return
        }
        $state.Run = $true
        $dialog.Close()
    }.GetNewClosure()

    $dialog.Content = New-ADTUiStack -Margin 18 -Spacing 12 -Child @(
        (New-ADTUiText -Text 'Nouvel utilisateur Active Directory' -Bold),
        $target.Panel, $browse,
        $givenName.Panel, $surname.Panel, $sam.Panel,
        $title.Panel, $department.Panel, $mail.Panel, $groups.Panel,
        $lengthPanel, $disabled, $noChange, $document,
        (New-ADTUiText -Wrap -Text 'Le mot de passe temporaire est genere par le module et affiche dans la grille des resultats si la case "Afficher / exporter les mots de passe generes" est cochee. Il n est jamais ecrit dans le journal.'),
        (New-ADTUiRow -Align 'Right' -Spacing 12 -Child @($cancel, $accept))
    )
    $dialog.Show()
    $dialog.WaitForClosed()
    if (-not $state.Run) { return $null }

    $parameters = @{
        GivenName      = ([string]$givenName.Box.Text).Trim()
        Surname        = ([string]$surname.Box.Text).Trim()
        Path           = ([string]$target.Box.Text).Trim()
        PasswordLength = [int]$length.Value
    }
    if ($sam.Box.Text) { $parameters['SamAccountName'] = ([string]$sam.Box.Text).Trim() }
    if ($title.Box.Text) { $parameters['Title'] = ([string]$title.Box.Text).Trim() }
    if ($department.Box.Text) { $parameters['Department'] = ([string]$department.Box.Text).Trim() }
    if ($mail.Box.Text) { $parameters['EmailAddress'] = ([string]$mail.Box.Text).Trim() }
    if ($groups.Box.Text) {
        $parameters['Groups'] = [string[]]@($groups.Box.Text -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    if ([bool]$disabled.IsChecked) { $parameters['Disabled'] = $true }
    if ([bool]$noChange.IsChecked) { $parameters['NoChangePasswordAtLogon'] = $true }

    return @{ Parameters = $parameters; Document = [bool]$document.IsChecked }
}

function Show-ADTUiNewGroup {
    param([string]$Path)
    $state = @{ Run = $false }

    $name = New-ADTUiTextField -Label 'Nom du groupe *'
    $sam = New-ADTUiTextField -Label 'Nom anterieur a Windows 2000 (vide = calcule)'
    $description = New-ADTUiTextField -Label 'Description'
    $target = New-ADTUiTextField -Label 'OU cible' -Value $Path -ReadOnly

    $scope = [GliderUI.Avalonia.Controls.ComboBox]::new()
    foreach ($item in @('Global', 'DomainLocal', 'Universal')) { $scope.Items.Add($item) | Out-Null }
    $scope.SelectedIndex = 0
    $scope.HorizontalAlignment = 'Stretch'

    $category = [GliderUI.Avalonia.Controls.ComboBox]::new()
    foreach ($item in @('Security', 'Distribution')) { $category.Items.Add($item) | Out-Null }
    $category.SelectedIndex = 0
    $category.HorizontalAlignment = 'Stretch'

    $dialog = [GliderUI.Avalonia.Controls.Window]::new()
    $dialog.Title = 'Nouveau groupe'
    $dialog.Width = 720
    $dialog.Height = 520
    $dialog.WindowStartupLocation = 'CenterOwner'

    $cancel = New-ADTUiButton -Text 'Annuler' -Width 150 -OnClick { $dialog.Close() }.GetNewClosure()
    $accept = New-ADTUiButton -Text 'Creer' -Width 170 -Accent -OnClick {
        if (-not $name.Box.Text) { Show-ADTUiError 'Le nom du groupe est obligatoire.'; return }
        if (-not $target.Box.Text) { Show-ADTUiError 'Aucune unite d organisation cible : charger l arborescence et en selectionner une.'; return }
        $state.Run = $true
        $dialog.Close()
    }.GetNewClosure()

    $dialog.Content = New-ADTUiStack -Margin 18 -Spacing 12 -Child @(
        (New-ADTUiText -Text 'Nouveau groupe Active Directory' -Bold),
        $target.Panel, $name.Panel, $sam.Panel, $description.Panel,
        (New-ADTUiStack -Spacing 4 -Child @((New-ADTUiText -Text 'Etendue du groupe'), $scope)),
        (New-ADTUiStack -Spacing 4 -Child @((New-ADTUiText -Text 'Type de groupe'), $category)),
        (New-ADTUiRow -Align 'Right' -Spacing 12 -Child @($cancel, $accept))
    )
    $dialog.Show()
    $dialog.WaitForClosed()
    if (-not $state.Run) { return $null }

    $parameters = @{
        Path     = ([string]$target.Box.Text).Trim()
        Name     = ([string]$name.Box.Text).Trim()
        Scope    = [string]$scope.SelectedItem
        Category = [string]$category.SelectedItem
    }
    if ($sam.Box.Text) { $parameters['SamAccountName'] = ([string]$sam.Box.Text).Trim() }
    if ($description.Box.Text) { $parameters['Description'] = ([string]$description.Box.Text).Trim() }
    return $parameters
}

function Show-ADTUiNewOrganizationalUnit {
    param([string]$Path)
    $state = @{ Run = $false }

    $name = New-ADTUiTextField -Label 'Nom de l unite d organisation *'
    $description = New-ADTUiTextField -Label 'Description'
    $target = New-ADTUiTextField -Label 'Conteneur parent' -Value $Path -ReadOnly
    $protect = New-ADTUiCheck -Label 'Proteger le conteneur contre une suppression accidentelle' -Checked $true

    $dialog = [GliderUI.Avalonia.Controls.Window]::new()
    $dialog.Title = 'Nouvelle unite d organisation'
    $dialog.Width = 720
    $dialog.Height = 440
    $dialog.WindowStartupLocation = 'CenterOwner'

    $cancel = New-ADTUiButton -Text 'Annuler' -Width 150 -OnClick { $dialog.Close() }.GetNewClosure()
    $accept = New-ADTUiButton -Text 'Creer' -Width 170 -Accent -OnClick {
        if (-not $name.Box.Text) { Show-ADTUiError 'Le nom de l unite d organisation est obligatoire.'; return }
        if (-not $target.Box.Text) { Show-ADTUiError 'Aucun conteneur parent : charger l arborescence et en selectionner un.'; return }
        $state.Run = $true
        $dialog.Close()
    }.GetNewClosure()

    $dialog.Content = New-ADTUiStack -Margin 18 -Spacing 12 -Child @(
        (New-ADTUiText -Text 'Nouvelle unite d organisation' -Bold),
        $target.Panel, $name.Panel, $description.Panel, $protect,
        (New-ADTUiRow -Align 'Right' -Spacing 12 -Child @($cancel, $accept))
    )
    $dialog.Show()
    $dialog.WaitForClosed()
    if (-not $state.Run) { return $null }

    $parameters = @{ Path = ([string]$target.Box.Text).Trim(); Name = ([string]$name.Box.Text).Trim() }
    if ($description.Box.Text) { $parameters['Description'] = ([string]$description.Box.Text).Trim() }
    if (-not [bool]$protect.IsChecked) { $parameters['NoProtection'] = $true }
    return $parameters
}

function Show-ADTUiPasswordReset {
    # Reinitialisation de mot de passe avec generateur configurable. Le document de
    # remise est une case a cocher : il n est jamais produit d office.
    param([string[]]$Account)
    $state = @{ Run = $false }
    $single = (@($Account).Count -eq 1)

    $length = [GliderUI.Avalonia.Controls.NumericUpDown]::new()
    $length.Minimum = 12
    $length.Maximum = 128
    $length.Value = 16

    $noSpecial = New-ADTUiCheck -Label 'Sans caractere special'
    $ambiguous = New-ADTUiCheck -Label 'Autoriser les caracteres ambigus (O, 0, l, 1, I)'
    $noChange = New-ADTUiCheck -Label 'Ne pas forcer le changement a la prochaine ouverture de session'
    $unlock = New-ADTUiCheck -Label 'Deverrouiller le compte' -Checked $true
    $document = New-ADTUiCheck -Label 'Generer le document de remise apres l application'

    $preview = New-ADTUiTextField -Label 'Apercu d un mot de passe genere' -ReadOnly
    $generate = New-ADTUiButton -Text 'Generer un apercu' -OnClick {
        try {
            $options = @{ NoPolicyCheck = $true; Length = [int]$length.Value }
            if ([bool]$noSpecial.IsChecked) { $options['NoSpecial'] = $true }
            if ([bool]$ambiguous.IsChecked) { $options['IncludeAmbiguous'] = $true }
            $preview.Box.Text = [string](New-ADTPassword @options).Password
        } catch { Show-ADTUiError $_.Exception.Message }
    }.GetNewClosure()

    $imposed = New-ADTUiTextField -Label 'Mot de passe impose (vide = genere pour chaque compte)'

    $dialog = [GliderUI.Avalonia.Controls.Window]::new()
    $dialog.Title = 'Reinitialiser le mot de passe'
    $dialog.Width = 780
    $dialog.Height = 640
    $dialog.WindowStartupLocation = 'CenterOwner'

    $cancel = New-ADTUiButton -Text 'Annuler' -Width 150 -OnClick { $dialog.Close() }.GetNewClosure()
    $accept = New-ADTUiButton -Text 'Reinitialiser' -Width 180 -Accent -OnClick {
        $state.Run = $true
        $dialog.Close()
    }.GetNewClosure()

    $header = 'Comptes concernes : ' + (@($Account) -join ', ')
    if (@($Account).Count -gt 6) { $header = ('Comptes concernes : {0}' -f @($Account).Count) }

    $children = @(
        (New-ADTUiText -Text 'Reinitialisation de mot de passe' -Bold),
        (New-ADTUiText -Text $header -Wrap),
        (New-ADTUiStack -Spacing 4 -Child @((New-ADTUiText -Text 'Longueur'), $length)),
        $noSpecial, $ambiguous
    )
    if ($single) { $children += $imposed.Panel }
    $children += @(
        (New-ADTUiRow -Child @($generate)), $preview.Panel,
        $noChange, $unlock, $document,
        (New-ADTUiText -Wrap -Text 'L apercu ne sert qu a verifier le format : le mot de passe applique est genere au moment de l operation, un par compte. Le mot de passe n apparait jamais dans le journal.'),
        (New-ADTUiRow -Align 'Right' -Spacing 12 -Child @($cancel, $accept))
    )
    $dialog.Content = New-ADTUiStack -Margin 18 -Spacing 12 -Child $children
    $dialog.Show()
    $dialog.WaitForClosed()
    if (-not $state.Run) { return $null }

    $parameters = @{ Length = [int]$length.Value }
    if ([bool]$noSpecial.IsChecked) { $parameters['NoSpecial'] = $true }
    if ([bool]$ambiguous.IsChecked) { $parameters['IncludeAmbiguous'] = $true }
    if ([bool]$noChange.IsChecked) { $parameters['NoChangeAtNextLogon'] = $true }
    if ([bool]$unlock.IsChecked) { $parameters['Unlock'] = $true }
    if ($single -and $imposed.Box.Text) {
        $secure = New-Object System.Security.SecureString
        foreach ($character in $imposed.Box.Text.ToCharArray()) { $secure.AppendChar($character) }
        $secure.MakeReadOnly()
        $parameters['NewPassword'] = $secure
    }
    return @{ Parameters = $parameters; Document = [bool]$document.IsChecked }
}

function Show-ADTUiGroupMembership {
    # Gestion des groupes d un ou plusieurs comptes : ajout et retrait en lot.
    param([string[]]$Account, [string[]]$CurrentGroup)
    $state = @{ Run = $false }

    $add = New-ADTUiTextField -Label 'Groupes a ajouter (separes par ;)'
    $remove = New-ADTUiTextField -Label 'Groupes a retirer (separes par ;)'

    $current = New-ADTUiTextField -Label 'Appartenances actuelles' -Height 140 -ReadOnly `
        -Value ((@($CurrentGroup) | Sort-Object) -join [Environment]::NewLine)

    $dialog = [GliderUI.Avalonia.Controls.Window]::new()
    $dialog.Title = 'Gerer les groupes'
    $dialog.Width = 760
    $dialog.Height = 560
    $dialog.WindowStartupLocation = 'CenterOwner'

    $cancel = New-ADTUiButton -Text 'Annuler' -Width 150 -OnClick { $dialog.Close() }.GetNewClosure()
    $accept = New-ADTUiButton -Text 'Appliquer' -Width 170 -Accent -OnClick {
        if (-not $add.Box.Text -and -not $remove.Box.Text) {
            Show-ADTUiError 'Indiquer au moins un groupe a ajouter ou a retirer.'
            return
        }
        $state.Run = $true
        $dialog.Close()
    }.GetNewClosure()

    $header = 'Comptes concernes : ' + (@($Account) -join ', ')
    if (@($Account).Count -gt 6) { $header = ('Comptes concernes : {0}' -f @($Account).Count) }

    $dialog.Content = New-ADTUiStack -Margin 18 -Spacing 12 -Child @(
        (New-ADTUiText -Text 'Appartenances aux groupes' -Bold),
        (New-ADTUiText -Text $header -Wrap),
        $current.Panel, $add.Panel, $remove.Panel,
        (New-ADTUiText -Wrap -Text 'Un groupe peut etre designe par son nom affiche ou par son nom anterieur a Windows 2000. Le groupe principal d un compte ne peut pas etre retire ici.'),
        (New-ADTUiRow -Align 'Right' -Spacing 12 -Child @($cancel, $accept))
    )
    $dialog.Show()
    $dialog.WaitForClosed()
    if (-not $state.Run) { return $null }

    $parameters = @{}
    if ($add.Box.Text) { $parameters['AddGroup'] = [string[]]@($add.Box.Text -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    if ($remove.Box.Text) { $parameters['RemoveGroup'] = [string[]]@($remove.Box.Text -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    return $parameters
}

function Show-ADTUiMemberSelection {
<#
    Liste les membres d un groupe avant une operation en lot et permet d en
    exclure. Repond au besoin : appliquer un horaire a un groupe tout en laissant
    quelques comptes sur un horaire different.

    Rend la liste des membres retenus, ou $null si l operateur annule.
#>
    param(
        $Member,
        [string]$Title = 'Membres concernes',
        [string]$Action = 'Appliquer',
        [string]$Detail = ''
    )
    $columns = @(
        @{ Header = 'Nom'; Path = 'Name' },
        @{ Header = 'Identifiant'; Path = 'SamAccountName' },
        @{ Header = 'Service'; Path = 'Department' },
        @{ Header = 'Etat'; Path = 'Status' }
    )

    $included = New-Object System.Collections.ArrayList
    $excluded = New-Object System.Collections.ArrayList
    foreach ($item in @($Member)) { [void]$included.Add($item) }

    $state = @{ Run = $false; Included = @(); IncludedRows = @(); ExcludedRows = @() }

    $includedGrid = New-ADTUiObjectGrid -Column $columns -Height 320
    $excludedGrid = New-ADTUiObjectGrid -Column $columns -Height 320
    $count = New-ADTUiText -Text '' -Wrap

    $refresh = {
        $state.IncludedRows = Set-ADTUiObjectGridSource -Grid $includedGrid -Column $columns -Row @($included)
        $state.ExcludedRows = Set-ADTUiObjectGridSource -Grid $excludedGrid -Column $columns -Row @($excluded)
        $count.Text = ('{0} compte(s) retenu(s), {1} exclu(s).' -f $included.Count, $excluded.Count)
    }.GetNewClosure()

    $exclude = New-ADTUiButton -Text 'Exclure >' -Width 130 -OnClick {
        $chosen = Get-ADTUiSelectedRow -Grid $includedGrid -Row $state.IncludedRows
        if (-not @($chosen).Count) { Show-ADTUiError 'Selectionner au moins un compte a exclure.'; return }
        foreach ($item in @($chosen)) {
            $included.Remove($item)
            if (-not $excluded.Contains($item)) { [void]$excluded.Add($item) }
        }
        & $refresh
    }.GetNewClosure()

    $include = New-ADTUiButton -Text '< Reintegrer' -Width 130 -OnClick {
        $chosen = Get-ADTUiSelectedRow -Grid $excludedGrid -Row $state.ExcludedRows
        if (-not @($chosen).Count) { Show-ADTUiError 'Selectionner au moins un compte a reintegrer.'; return }
        foreach ($item in @($chosen)) {
            $excluded.Remove($item)
            if (-not $included.Contains($item)) { [void]$included.Add($item) }
        }
        & $refresh
    }.GetNewClosure()

    $excludeDisabled = New-ADTUiButton -Text 'Exclure les comptes desactives' -OnClick {
        foreach ($item in @($included)) {
            if ([string]$item.Status -like '*Desactive*') {
                $included.Remove($item)
                if (-not $excluded.Contains($item)) { [void]$excluded.Add($item) }
            }
        }
        & $refresh
    }.GetNewClosure()

    $dialog = [GliderUI.Avalonia.Controls.Window]::new()
    $dialog.Title = $Title
    $dialog.Width = 1180
    $dialog.Height = 720
    $dialog.WindowStartupLocation = 'CenterOwner'

    $cancel = New-ADTUiButton -Text 'Annuler' -Width 150 -OnClick { $dialog.Close() }.GetNewClosure()
    $accept = New-ADTUiButton -Text $Action -Width 220 -Accent -OnClick {
        if (-not $included.Count) { Show-ADTUiError 'Aucun compte retenu.'; return }
        $state.Included = @($included)
        $state.Run = $true
        $dialog.Close()
    }.GetNewClosure()

    $lists = New-ADTUiGridLayout -Column @('Star', 'Auto', 'Star') -ColumnSpacing 14
    $null = Add-ADTUiGridRow -Grid $lists
    $null = Add-ADTUiGridRow -Grid $lists
    Add-ADTUiCell -Grid $lists -Child (New-ADTUiText -Text 'Comptes retenus' -Bold) -Row 0 -Column 0
    Add-ADTUiCell -Grid $lists -Child (New-ADTUiText -Text '') -Row 0 -Column 1
    Add-ADTUiCell -Grid $lists -Child (New-ADTUiText -Text 'Comptes exclus' -Bold) -Row 0 -Column 2
    Add-ADTUiCell -Grid $lists -Child $includedGrid -Row 1 -Column 0
    Add-ADTUiCell -Grid $lists -Child (New-ADTUiStack -Spacing 10 -Child @($exclude, $include)) -Row 1 -Column 1
    Add-ADTUiCell -Grid $lists -Child $excludedGrid -Row 1 -Column 2

    & $refresh
    $dialog.Content = New-ADTUiStack -Margin 18 -Spacing 12 -Child @(
        (New-ADTUiText -Text $Title -Bold),
        $(if ($Detail) { New-ADTUiText -Text $Detail -Wrap } else { $null }),
        (New-ADTUiText -Wrap -Text 'Les comptes exclus conservent leur configuration actuelle. Selectionner une ou plusieurs lignes puis utiliser les boutons du centre.'),
        $lists,
        (New-ADTUiRow -Child @($excludeDisabled)),
        $count,
        (New-ADTUiRow -Align 'Right' -Spacing 12 -Child @($cancel, $accept))
    )
    $dialog.Show()
    $dialog.WaitForClosed()
    if (-not $state.Run) { return $null }
    return @($state.Included)
}

function Show-ADTUiGroupMemberManager {
<#
    Gestion des membres d un groupe : liste, ajout, retrait, et actions en lot sur
    les membres selectionnes. Rend l action a executer par la console, sous forme
    de table (Action + donnees), pour que les ecritures restent centralisees.
#>
    param([string]$GroupIdentity, [string]$GroupName, $Member)
    $columns = @(
        @{ Header = 'Nom'; Path = 'Name' },
        @{ Header = 'Identifiant'; Path = 'SamAccountName' },
        @{ Header = 'Type'; Path = 'ObjectType' },
        @{ Header = 'Service'; Path = 'Department' },
        @{ Header = 'Etat'; Path = 'Status' },
        @{ Header = 'Derniere connexion'; Path = 'LastLogonDate' }
    )
    $state = @{ Result = $null }
    $rows = @($Member)

    $grid = New-ADTUiObjectGrid -Column $columns -Height 380
    $rows = Set-ADTUiObjectGridSource -Grid $grid -Column $columns -Row $rows

    $newMember = New-ADTUiTextField -Label 'Comptes a ajouter (identifiants separes par ;)'

    $dialog = [GliderUI.Avalonia.Controls.Window]::new()
    $dialog.Title = 'Membres du groupe ' + $GroupName
    $dialog.Width = 1180
    $dialog.Height = 760
    $dialog.WindowStartupLocation = 'CenterOwner'

    $close = New-ADTUiButton -Text 'Fermer' -Width 150 -OnClick { $dialog.Close() }.GetNewClosure()

    $finish = {
        param([hashtable]$Result)
        $state.Result = $Result
        $dialog.Close()
    }.GetNewClosure()

    $selectedAccounts = {
        $chosen = Get-ADTUiSelectedRow -Grid $grid -Row $rows
        $accounts = @()
        foreach ($item in @($chosen)) {
            if ([string]$item.ObjectClass -ne 'user') { continue }
            $accounts += [string]$item.DistinguishedName
        }
        return , $accounts
    }.GetNewClosure()

    $addButton = New-ADTUiButton -Text 'Ajouter les comptes saisis' -Accent -OnClick {
        if (-not $newMember.Box.Text) { Show-ADTUiError 'Saisir au moins un identifiant.'; return }
        $list = [string[]]@($newMember.Box.Text -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        & $finish @{ Action = 'AddMember'; Group = $GroupIdentity; Member = $list }
    }.GetNewClosure()

    $removeButton = New-ADTUiButton -Text 'Retirer la selection' -OnClick {
        $chosen = Get-ADTUiSelectedRow -Grid $grid -Row $rows
        if (-not @($chosen).Count) { Show-ADTUiError 'Selectionner au moins un membre.'; return }
        $list = @()
        foreach ($item in @($chosen)) { $list += [string]$item.DistinguishedName }
        & $finish @{ Action = 'RemoveMember'; Group = $GroupIdentity; Member = $list }
    }.GetNewClosure()

    $hoursButton = New-ADTUiButton -Text 'Horaires de connexion des membres...' -OnClick {
        & $finish @{ Action = 'LogonHours'; Group = $GroupIdentity; Member = @($rows) }
    }.GetNewClosure()

    $groupsButton = New-ADTUiButton -Text 'Groupes des comptes selectionnes...' -OnClick {
        $accounts = & $selectedAccounts
        if (-not @($accounts).Count) { Show-ADTUiError 'Selectionner au moins un compte utilisateur.'; return }
        & $finish @{ Action = 'Membership'; Member = @($accounts) }
    }.GetNewClosure()

    $disableButton = New-ADTUiButton -Text 'Desactiver les comptes selectionnes' -OnClick {
        $accounts = & $selectedAccounts
        if (-not @($accounts).Count) { Show-ADTUiError 'Selectionner au moins un compte utilisateur.'; return }
        & $finish @{ Action = 'Disable'; Member = @($accounts) }
    }.GetNewClosure()

    $passwordButton = New-ADTUiButton -Text 'Reinitialiser les mots de passe selectionnes' -OnClick {
        $accounts = & $selectedAccounts
        if (-not @($accounts).Count) { Show-ADTUiError 'Selectionner au moins un compte utilisateur.'; return }
        & $finish @{ Action = 'Password'; Member = @($accounts) }
    }.GetNewClosure()

    $dialog.Content = New-ADTUiStack -Margin 18 -Spacing 12 -Child @(
        (New-ADTUiText -Text ('Membres de ' + $GroupName) -Bold),
        (New-ADTUiText -Wrap -Text ('{0} membre(s) direct(s). Les actions en lot portent sur les lignes selectionnees ; "Horaires de connexion des membres" porte sur tout le groupe, avec possibilite d exclure des comptes a l etape suivante.' -f @($rows).Count)),
        $grid,
        $newMember.Panel,
        (New-ADTUiRow -Spacing 10 -Child @($addButton, $removeButton)),
        (New-ADTUiRow -Spacing 10 -Child @($hoursButton, $groupsButton, $disableButton, $passwordButton)),
        (New-ADTUiRow -Align 'Right' -Spacing 12 -Child @($close))
    )
    $dialog.Show()
    $dialog.WaitForClosed()
    return $state.Result
}
