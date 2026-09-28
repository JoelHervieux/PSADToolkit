#requires -version 7.4
using namespace GliderUI
using namespace GliderUI.Avalonia
using namespace GliderUI.Avalonia.Controls

<#
    Console d administration Active Directory.

    Arborescence a gauche (domaine, unites d organisation et conteneurs), contenu
    de l element selectionne a droite (utilisateurs, groupes, ordinateurs et
    sous-unites), barre d actions sous la liste, recherche en haut.

    L arborescence est chargee en une seule requete LDAP puis reconstruite a partir
    des DN, comme le selecteur d OU historique : Avalonia n expose pas d evenement
    "avant expansion" exploitable pour un chargement paresseux. Le CONTENU, lui,
    n est lu qu a la selection d un conteneur : c est la partie volumineuse.

    Les menus contextuels agissent sur l element selectionne. Chaque action qu ils
    proposent est aussi accessible par un bouton : si la version de GliderUI
    installee n expose pas ContextMenu, la console reste complete.
#>

$script:Console = @{
    DomainDN      = ''
    DomainName    = ''
    ContainerDN   = ''
    ContainerName = ''
    Rows          = @()
    Tree          = $null
    Grid          = $null
    Header        = $null
    Simulate      = $null
    SearchBox     = $null
    SearchScope   = $null
    TypeFilter    = $null
    Summary       = $null
    Nodes         = @{}
    # Arborescence : chaque noeud porte une cle, decrite ici. Un DN peut contenir
    # n importe quel caractere : l inscrire dans le Tag imposerait un format fragile.
    NodeInfo      = @{}
    NodeSeq       = 0
    # Noeuds Utilisateurs / Groupes / Ordinateurs ajoutes sous chaque conteneur.
    Categories    = @{}
    # Contenu deja lu, par conteneur : passer d une categorie a l autre ne relit pas
    # l annuaire.
    Cache         = @{}
    ViewKey       = ''
    ClassFilter   = ''
    # Au-dela, un noeud "voir la liste" remplace les objets : chaque noeud coute des
    # allers-retours vers le serveur GliderUI.
    LeafLimit     = 100
}

function Get-ADTUiConsoleColumn {
    return @(
        @{ Header = 'Nom'; Path = 'Name' },
        @{ Header = 'Type'; Path = 'ObjectType' },
        @{ Header = 'Identifiant'; Path = 'SamAccountName' },
        @{ Header = 'Description'; Path = 'Description' },
        @{ Header = 'Etat'; Path = 'Status' },
        @{ Header = 'Derniere connexion'; Path = 'LastLogonDate' }
    )
}

function Get-ADTUiConsoleSelection {
    # Lignes selectionnees dans la liste. Rend un tableau vide plutot que $null :
    # les appelants comptent dessus pour verifier la selection.
    param([string]$Class)
    $rows = @(Get-ADTUiSelectedRow -Grid $script:Console.Grid -Row $script:Console.Rows)
    if ($Class) { $rows = @($rows | Where-Object { [string]$_.ObjectClass -eq $Class }) }
    return , @($rows)
}

function Get-ADTUiConsoleTarget {
    # DN des lignes selectionnees.
    param([string]$Class)
    $names = @()
    foreach ($row in (Get-ADTUiConsoleSelection -Class $Class)) { $names += [string]$row.DistinguishedName }
    return , $names
}

function Get-ADTUiConsoleLabel {
    param([string]$Class)
    $names = @()
    foreach ($row in (Get-ADTUiConsoleSelection -Class $Class)) {
        $label = [string]$row.SamAccountName
        if (-not $label) { $label = [string]$row.Name }
        $names += $label
    }
    return , $names
}

function Set-ADTUiConsoleStatus {
    param([string]$Message)
    $statusText.Text = $Message
}

function Get-ADTUiConsoleCategory {
    return @(
        @{ Class = 'user'; Label = 'Utilisateurs' },
        @{ Class = 'group'; Label = 'Groupes' },
        @{ Class = 'computer'; Label = 'Ordinateurs' }
    )
}

function New-ADTUiConsoleNode {
    param([string]$Header, [hashtable]$Info)
    $script:Console.NodeSeq++
    $key = 'n' + $script:Console.NodeSeq
    $node = [GliderUI.Avalonia.Controls.TreeViewItem]::new()
    $node.Header = $Header
    $node.Tag = $key
    $script:Console.NodeInfo[$key] = $Info
    return $node
}

function Get-ADTUiConsoleNodeInfo {
    $selected = $null
    try { $selected = $script:Console.Tree.SelectedItem } catch { $selected = $null }
    if (-not $selected) { return $null }
    $key = [string](Get-ADTUiValue -Target $selected -Name 'Tag')
    if ($key -and $script:Console.NodeInfo.ContainsKey($key)) { return $script:Console.NodeInfo[$key] }
    return $null
}

function Update-ADTUiConsoleTree {
<#
    Recharge l arborescence des conteneurs du domaine, puis affiche le conteneur vise.
#>
    param([string]$SelectDN)
    $connection = Get-ADTUiConnection
    $domain = Get-ADTNativeDomain @connection
    $domainDN = [string]$domain.DistinguishedName
    if (-not $domainDN) { throw 'Impossible de determiner le domaine Active Directory.' }

    $script:Console.DomainDN = $domainDN
    $script:Console.DomainName = [string]$domain.DNSRoot
    $script:Console.NodeInfo = @{}
    $script:Console.Categories = @{}
    $script:Console.Cache = @{}
    $script:Console.ViewKey = ''

    $scope = @{ Server = [string]$domain.Server }
    if ($connection.ContainsKey('Credential')) { $scope['Credential'] = $connection['Credential'] }

    $containers = @(Search-ADTDirectoryEntry -SearchBase $domainDN -Scope Subtree `
            -LDAPFilter '(|(objectClass=organizationalUnit)(objectClass=container)(objectClass=builtinDomain))' `
            -Property @('name', 'distinguishedName', 'objectClass') @scope |
        Sort-Object -Property @{ Expression = { Get-ADTUiDNDepth ([string]$_.DistinguishedName) } }, @{ Expression = { [string]$_.Name } })

    $root = New-ADTUiConsoleNode -Header $script:Console.DomainName -Info @{ Kind = 'Container'; ContainerDN = $domainDN }
    $root.IsExpanded = $true

    $index = @{ $domainDN = $root }
    foreach ($container in $containers) {
        $dn = [string]$container.DistinguishedName
        $node = New-ADTUiConsoleNode -Header ([string]$container.Name) -Info @{ Kind = 'Container'; ContainerDN = $dn }
        $parent = $root
        $parentDN = Get-ADTUiParentDN $dn
        if ($parentDN -and $index.ContainsKey($parentDN)) { $parent = $index[$parentDN] }
        $parent.Items.Add($node) | Out-Null
        $index[$dn] = $node
    }
    $script:Console.Nodes = $index

    $tree = $script:Console.Tree
    $tree.Items.Clear()
    $tree.Items.Add($root) | Out-Null

    $target = $SelectDN
    if (-not $target -or -not $index.ContainsKey($target)) { $target = $domainDN }
    # Deplier la branche menant a l element vise pour qu il soit visible.
    $walk = $target
    while ($walk -and $index.ContainsKey($walk)) {
        $index[$walk].IsExpanded = $true
        $walk = Get-ADTUiParentDN $walk
    }
    try { $tree.SelectedItem = $index[$target] } catch { Add-ADTUiSmokeWarning 'Selection de l arborescence non appliquee.' }

    Show-ADTUiConsoleView -ContainerDN $target -Refresh
    Set-ADTUiConsoleStatus ('{0} conteneur(s) lu(s) dans {1}.' -f $containers.Count, $script:Console.DomainName)
}

function Update-ADTUiConsoleCategoryNode {
<#
    Place sous le conteneur les noeuds Utilisateurs, Groupes et Ordinateurs, avec
    leurs objets : l arborescence montre ainsi tout le contenu, comme un explorateur
    de fichiers. Les sous-unites, deja presentes, restent en tete.
#>
    param([string]$ContainerDN, $Row)
    if (-not $script:Console.Nodes.ContainsKey($ContainerDN)) { return }
    $parent = $script:Console.Nodes[$ContainerDN]

    if ($script:Console.Categories.ContainsKey($ContainerDN)) {
        foreach ($old in @($script:Console.Categories[$ContainerDN])) {
            try { $null = $parent.Items.Remove($old) }
            catch { Add-ADTUiSmokeWarning ('Noeud de categorie non retire : ' + $_.Exception.Message) }
        }
    }

    $added = New-Object System.Collections.ArrayList
    foreach ($category in (Get-ADTUiConsoleCategory)) {
        $members = @(@($Row) | Where-Object { [string]$_.ObjectClass -eq [string]$category.Class })
        if (-not $members.Count) { continue }
        $node = New-ADTUiConsoleNode -Header ('{0} ({1})' -f $category.Label, $members.Count) `
            -Info @{ Kind = 'Category'; ContainerDN = $ContainerDN; Class = [string]$category.Class }
        $shown = 0
        foreach ($member in $members) {
            if ($shown -ge $script:Console.LeafLimit) {
                $more = New-ADTUiConsoleNode -Header ('... {0} de plus : voir la liste' -f ($members.Count - $shown)) `
                    -Info @{ Kind = 'Category'; ContainerDN = $ContainerDN; Class = [string]$category.Class }
                $node.Items.Add($more) | Out-Null
                break
            }
            $label = [string]$member.Name
            if ([string]$category.Class -ne 'group') {
                if ($member.Enabled -eq $false) { $label += ' (desactive)' }
                if ($member.LockedOut) { $label += ' (verrouille)' }
            }
            $leaf = New-ADTUiConsoleNode -Header $label -Info @{
                Kind = 'Object'; ContainerDN = $ContainerDN; Class = [string]$category.Class
                ObjectDN = [string]$member.DistinguishedName
            }
            $node.Items.Add($leaf) | Out-Null
            $shown++
        }
        $parent.Items.Add($node) | Out-Null
        [void]$added.Add($node)
    }
    $script:Console.Categories[$ContainerDN] = @($added)
    $parent.IsExpanded = $true
}

function Get-ADTUiConsoleSummary {
    # Resume du contenu d un conteneur : ce qu on voit d un coup d oeil en y entrant.
    param($Row)
    $rows = @($Row)
    $users = @($rows | Where-Object { [string]$_.ObjectClass -eq 'user' }).Count
    $groups = @($rows | Where-Object { [string]$_.ObjectClass -eq 'group' }).Count
    $computers = @($rows | Where-Object { [string]$_.ObjectClass -eq 'computer' }).Count
    $units = @($rows | Where-Object { $_.IsContainer }).Count
    return ('{0} utilisateur(s), {1} groupe(s), {2} ordinateur(s), {3} unite(s)' -f $users, $groups, $computers, $units)
}

function Show-ADTUiConsoleView {
<#
    Affiche le contenu d un conteneur, eventuellement limite a une classe d objets,
    et selectionne un objet dans la liste. Toutes les actions de la console portent
    sur la selection de la liste : selectionner un objet dans l arborescence le
    selectionne ici, et les memes boutons s appliquent.
#>
    param([string]$ContainerDN, [string]$Class = '', [string]$FocusDN = '', [switch]$Refresh)
    if (-not $ContainerDN) { return }
    $key = $ContainerDN + '|' + $Class + '|' + $FocusDN
    if (-not $Refresh -and $key -eq $script:Console.ViewKey) { return }
    $script:Console.ViewKey = $key
    $script:Console.ContainerDN = $ContainerDN
    $script:Console.ClassFilter = $Class
    $name = Get-ADTRdnValue -DistinguishedName $ContainerDN
    if ($ContainerDN -eq $script:Console.DomainDN) { $name = $script:Console.DomainName }
    $script:Console.ContainerName = $name

    $fresh = $false
    if ($Refresh -or -not $script:Console.Cache.ContainsKey($ContainerDN)) {
        $connection = Get-ADTUiConnection
        $script:Console.Cache[$ContainerDN] = @(Get-ADTDirectoryChild -Path $ContainerDN @connection)
        $fresh = $true
    }
    $all = @($script:Console.Cache[$ContainerDN])
    if ($fresh -or -not $script:Console.Categories.ContainsKey($ContainerDN)) {
        Update-ADTUiConsoleCategoryNode -ContainerDN $ContainerDN -Row $all
    }

    $rows = $all
    $scopeLabel = 'tout le contenu'
    if ($Class) {
        $rows = @($all | Where-Object { [string]$_.ObjectClass -eq $Class })
        foreach ($category in (Get-ADTUiConsoleCategory)) {
            if ([string]$category.Class -eq $Class) { $scopeLabel = [string]$category.Label }
        }
    }
    $script:Console.Rows = Set-ADTUiObjectGridSource -Grid $script:Console.Grid -Column (Get-ADTUiConsoleColumn) -Row $rows

    $script:Console.Header.Text = ('{0}  -  affichage : {1} ({2})' -f $name, $scopeLabel, @($rows).Count)
    if ($script:Console.Summary) { $script:Console.Summary.Text = Get-ADTUiConsoleSummary -Row $all }

    if ($FocusDN) {
        $position = 0
        foreach ($row in @($script:Console.Rows)) {
            if ([string]$row.DistinguishedName -eq $FocusDN) {
                try { $script:Console.Grid.SelectedIndex = $position }
                catch { Add-ADTUiSmokeWarning ('Selection de ligne non appliquee : ' + $_.Exception.Message) }
                break
            }
            $position++
        }
    }
    Set-ADTUiConsoleStatus ('{0} : {1}.' -f $ContainerDN, (Get-ADTUiConsoleSummary -Row $all))
}

function Update-ADTUiConsoleList {
<#
    Relit le conteneur designe - ou le conteneur affiche - apres une modification.
#>
    param([string]$DistinguishedName)
    if (-not $DistinguishedName) { $DistinguishedName = $script:Console.ContainerDN }
    if (-not $DistinguishedName) { return }
    Show-ADTUiConsoleView -ContainerDN $DistinguishedName -Class $script:Console.ClassFilter -Refresh
}

function Invoke-ADTUiConsoleSearch {
<#
    Recherche dans l OU selectionnee ou dans tout le domaine.
#>
    $term = ([string]$script:Console.SearchBox.Text).Trim()
    if (-not $term) {
        Update-ADTUiConsoleList -DistinguishedName $script:Console.ContainerDN
        return
    }
    $connection = Get-ADTUiConnection
    $parameters = @{ SearchTerm = $term }
    if ([string]$script:Console.SearchScope.SelectedItem -eq 'Unite selectionnee' -and $script:Console.ContainerDN) {
        $parameters['SearchBase'] = $script:Console.ContainerDN
    }
    $selected = [string]$script:Console.TypeFilter.SelectedItem
    switch ($selected) {
        'Utilisateurs' { $parameters['Type'] = @('User') }
        'Groupes' { $parameters['Type'] = @('Group') }
        'Ordinateurs' { $parameters['Type'] = @('Computer') }
        'Unites d organisation' { $parameters['Type'] = @('OrganizationalUnit') }
    }

    $columns = @(Get-ADTUiConsoleColumn) + @(@{ Header = 'Emplacement'; Path = 'Container' })
    $rows = @(Find-ADTDirectoryObject @parameters @connection)
    $script:Console.Rows = Set-ADTUiObjectGridSource -Grid $script:Console.Grid -Column $columns -Row $rows
    $script:Console.Header.Text = ('Recherche "{0}"  -  {1} resultat(s)' -f $term, @($rows).Count)
    # Une selection dans l arborescence doit ensuite relire le conteneur.
    $script:Console.ViewKey = 'recherche|' + $term
    Set-ADTUiConsoleStatus ('Recherche "{0}" : {1} resultat(s).' -f $term, @($rows).Count)
}

function Invoke-ADTUiConsoleWrite {
<#
    Execute une commande d ecriture du module avec la simulation et la confirmation
    de la console, puis rafraichit la liste.
#>
    param(
        [string]$Command,
        [hashtable]$Parameters,
        [string]$Action,
        [string[]]$Target,
        [string]$Detail,
        [switch]$NoRefresh
    )
    $simulate = [bool]$script:Console.Simulate.IsChecked
    if (-not (Confirm-ADTUiConsoleWrite -Action $Action -Target $Target -Detail $Detail -Simulate $simulate)) { return $false }

    $full = @{}
    foreach ($key in $Parameters.Keys) { $full[$key] = $Parameters[$key] }
    foreach ($item in (Get-ADTUiConnection).GetEnumerator()) { $full[$item.Key] = $item.Value }
    $full['WhatIf'] = $simulate
    $full['Confirm'] = $false

    Invoke-ADTUiCommand -Command $Command -Parameters $full
    if (-not $NoRefresh -and -not $simulate) { Update-ADTUiConsoleList -DistinguishedName $script:Console.ContainerDN }
    return $true
}

function Get-ADTUiConsoleObject {
<#
    Relit un objet selectionne avec tous ses attributs, pour la feuille de proprietes.
#>
    param([string]$DistinguishedName)
    $connection = Get-ADTUiConnection
    return (Get-ADTObjectProperty -Identity $DistinguishedName @connection)
}

function Invoke-ADTUiConsoleProperties {
    param([string]$DistinguishedName)
    if (-not $DistinguishedName) {
        $selection = Get-ADTUiConsoleTarget
        if (-not @($selection).Count) { Show-ADTUiError 'Selectionner un objet dans la liste.'; return }
        if (@($selection).Count -gt 1) { Show-ADTUiError 'Les proprietes s ouvrent sur un seul objet a la fois.'; return }
        $DistinguishedName = [string]@($selection)[0]
    }
    try {
        $item = Get-ADTUiConsoleObject -DistinguishedName $DistinguishedName
        $result = Show-ADTUiProperties -Object $item
        if (-not $result) { return }

        if ([string]$result['Action'] -eq 'ManageGroups') {
            Invoke-ADTUiConsoleMembership -Target @([string]$result['Identity']) -CurrentGroup @($item.MemberOfNames)
            return
        }
        if ([string]$result['Action'] -eq 'ManageMembers') {
            Invoke-ADTUiConsoleGroupMembers -GroupDN ([string]$result['Identity']) -GroupName ([string]$item.Name)
            return
        }

        $parameters = $result['Parameters']
        $changed = @($result['Changed'])
        $mask = [string]$result['LogonHoursMask']

        if (@($changed).Count) {
            $command = 'Set-ADTUser'
            if ([string]$result['Action'] -eq 'SetOrganizationalUnit') { $command = 'Set-ADTOrganizationalUnit' }
            $null = Invoke-ADTUiConsoleWrite -Command $command -Parameters $parameters `
                -Action ('Modifier ' + [string]$item.Name) -Target @([string]$item.Name) `
                -Detail ('Proprietes modifiees : ' + ($changed -join ', ')) -NoRefresh
        }
        if ($mask -and $mask -ne [string]$item.LogonHoursMask) {
            $null = Invoke-ADTUiConsoleWrite -Command 'Set-ADTUserLogonHours' `
                -Parameters @{ Identity = @([string]$item.DistinguishedName); Schedule = $mask; AllowNoLogonWindow = $true } `
                -Action ('Horaires de connexion de ' + [string]$item.Name) -Target @([string]$item.Name) `
                -Detail (ConvertTo-ADTLogonHoursText -Mask $mask) -NoRefresh
        }
        if (-not @($changed).Count -and -not $mask) {
            Set-ADTUiConsoleStatus 'Aucune modification a enregistrer.'
            return
        }
        Update-ADTUiConsoleList -DistinguishedName $script:Console.ContainerDN
    } catch {
        Show-ADTUiError $_.Exception.Message
    }
}

function Invoke-ADTUiConsoleMembership {
    param([string[]]$Target, [string[]]$CurrentGroup)
    if (-not @($Target).Count) {
        $Target = Get-ADTUiConsoleTarget -Class 'user'
        if (-not @($Target).Count) { Show-ADTUiError 'Selectionner au moins un compte utilisateur.'; return }
    }
    $labels = @()
    foreach ($dn in @($Target)) { $labels += (Get-ADTRdnValue -DistinguishedName $dn) }
    $parameters = Show-ADTUiGroupMembership -Account $labels -CurrentGroup $CurrentGroup
    if (-not $parameters) { return }
    $parameters['Identity'] = [string[]]@($Target)
    $null = Invoke-ADTUiConsoleWrite -Command 'Set-ADTUserGroupMembership' -Parameters $parameters `
        -Action 'Modifier les appartenances aux groupes' -Target $labels
}

function Invoke-ADTUiConsoleGroupMembers {
    param([string]$GroupDN, [string]$GroupName)
    try {
        $connection = Get-ADTUiConnection
        $members = @(Get-ADTGroupMember -Identity $GroupDN -IncludeGroup @connection)
        $result = Show-ADTUiGroupMemberManager -GroupIdentity $GroupDN -GroupName $GroupName -Member $members
        if (-not $result) { return }

        switch ([string]$result['Action']) {
            'AddMember' {
                $null = Invoke-ADTUiConsoleWrite -Command 'Set-ADTGroupMember' `
                    -Parameters @{ Identity = @($GroupDN); Member = [string[]]@($result['Member']) } `
                    -Action ('Ajouter des membres a ' + $GroupName) -Target @($result['Member'])
            }
            'RemoveMember' {
                $labels = @()
                foreach ($dn in @($result['Member'])) { $labels += (Get-ADTRdnValue -DistinguishedName ([string]$dn)) }
                $null = Invoke-ADTUiConsoleWrite -Command 'Set-ADTGroupMember' `
                    -Parameters @{ Identity = @($GroupDN); RemoveMember = [string[]]@($result['Member']) } `
                    -Action ('Retirer des membres de ' + $GroupName) -Target $labels
            }
            'LogonHours' { Invoke-ADTUiConsoleLogonHours -Member @($result['Member']) -Origin ('groupe ' + $GroupName) }
            'Membership' { Invoke-ADTUiConsoleMembership -Target @($result['Member']) }
            'Disable' {
                $labels = @()
                foreach ($dn in @($result['Member'])) { $labels += (Get-ADTRdnValue -DistinguishedName ([string]$dn)) }
                $null = Invoke-ADTUiConsoleWrite -Command 'Set-ADTAccountState' `
                    -Parameters @{ Identity = [string[]]@($result['Member']); Action = 'Disable' } `
                    -Action 'Desactiver les comptes' -Target $labels
            }
            'Password' { Invoke-ADTUiConsolePassword -Target @($result['Member']) }
        }
    } catch {
        Show-ADTUiError $_.Exception.Message
    }
}

function Invoke-ADTUiConsoleLogonHours {
<#
    Applique un horaire a une selection de comptes ou aux membres d un groupe.
    Dans les deux cas la liste des comptes vises est presentee avant l ecriture,
    avec la possibilite d en exclure.
#>
    param($Member, [string]$Origin)
    try {
        $candidates = @($Member)
        if (-not $candidates.Count) {
            $candidates = @(Get-ADTUiConsoleSelection -Class 'user')
            $Origin = 'la selection'
        }
        if (-not $candidates.Count) { Show-ADTUiError 'Selectionner au moins un compte utilisateur.'; return }

        $accounts = @()
        foreach ($item in $candidates) {
            if ($item -is [string]) {
                $accounts += (New-Object PSObject -Property @{
                        Name = (Get-ADTRdnValue -DistinguishedName $item); SamAccountName = ''
                        Department = ''; Status = ''; ObjectClass = 'user'; DistinguishedName = $item
                    })
                continue
            }
            if ([string]$item.ObjectClass -ne 'user') { continue }
            $accounts += $item
        }
        if (-not @($accounts).Count) { Show-ADTUiError 'Aucun compte utilisateur dans cette selection.'; return }

        $retained = $accounts
        if (@($accounts).Count -gt 1) {
            $retained = Show-ADTUiMemberSelection -Member $accounts -Action 'Choisir l horaire...' `
                -Title 'Comptes vises par l horaire de connexion' `
                -Detail ('Origine : ' + $Origin + '. Les comptes exclus conservent leur horaire actuel.')
            if (-not $retained) { return }
        }

        $initial = '1' * 168
        if (@($retained).Count -eq 1) {
            $connection = Get-ADTUiConnection
            $current = @(Get-ADTUserLogonHours -Identity ([string]@($retained)[0].DistinguishedName) @connection)
            if ($current.Count -and [string]$current[0].Mask) { $initial = [string]$current[0].Mask }
        }

        $subtitle = ('{0} compte(s) vise(s).' -f @($retained).Count)
        $mask = Show-ADTUiLogonHoursEditor -Mask $initial -Subtitle $subtitle
        if (-not $mask) { return }

        $targets = @()
        $labels = @()
        foreach ($item in @($retained)) {
            $targets += [string]$item.DistinguishedName
            $label = [string]$item.SamAccountName
            if (-not $label) { $label = [string]$item.Name }
            $labels += $label
        }

        $null = Invoke-ADTUiConsoleWrite -Command 'Set-ADTUserLogonHours' `
            -Parameters @{ Identity = [string[]]$targets; Schedule = $mask; AllowNoLogonWindow = $true } `
            -Action 'Appliquer des horaires de connexion' -Target $labels `
            -Detail ('Horaire : ' + (ConvertTo-ADTLogonHoursText -Mask $mask))
    } catch {
        Show-ADTUiError $_.Exception.Message
    }
}

function Invoke-ADTUiConsolePassword {
    param([string[]]$Target)
    try {
        if (-not @($Target).Count) {
            $Target = Get-ADTUiConsoleTarget -Class 'user'
            if (-not @($Target).Count) { Show-ADTUiError 'Selectionner au moins un compte utilisateur.'; return }
        }
        $labels = @()
        foreach ($dn in @($Target)) { $labels += (Get-ADTRdnValue -DistinguishedName ([string]$dn)) }

        $choice = Show-ADTUiPasswordReset -Account $labels
        if (-not $choice) { return }

        $parameters = $choice['Parameters']
        $parameters['Identity'] = [string[]]@($Target)
        $applied = Invoke-ADTUiConsoleWrite -Command 'Set-ADTUserPassword' -Parameters $parameters `
            -Action 'Reinitialiser des mots de passe' -Target $labels
        if (-not $applied) { return }
        if (-not $choice['Document']) { return }
        if ([bool]$script:Console.Simulate.IsChecked) {
            Set-ADTUiConsoleStatus 'Simulation : aucun document de remise genere.'
            return
        }
        New-ADTUiConsoleDocument
    } catch {
        Show-ADTUiError $_.Exception.Message
    }
}

function New-ADTUiConsoleDocument {
<#
    Produit les documents de remise a partir des mots de passe encore presents dans
    la grille des resultats. Action volontaire : elle n est jamais declenchee sans
    que l operateur l ait demandee et ait choisi un dossier.
#>
    $rows = @($script:Rows | Where-Object { [string]$_.Password -and [string]$_.Password -ne '(fourni par l appelant)' })
    if (-not $rows.Count) {
        Show-ADTUiError 'Aucun mot de passe genere dans les resultats courants. Le document ne peut etre produit que juste apres une creation de compte ou une reinitialisation.'
        return
    }
    $options = [GliderUI.Avalonia.Platform.Storage.FolderPickerOpenOptions]::new()
    $options.Title = 'Dossier des documents de remise'
    $folder = Get-ADTUiStoragePath ($window.StorageProvider.OpenFolderPickerAsync($options).WaitForCompleted())
    if (-not $folder) { return }

    if (-not (Show-ADTUiDialog -Title 'Documents de remise' -AcceptText 'Generer' -CancelText 'Annuler' -Message (
                ('{0} document(s) vont etre ecrits dans :' -f $rows.Count) + [Environment]::NewLine + $folder + [Environment]::NewLine + [Environment]::NewLine +
                'Ces fichiers contiennent des mots de passe en clair. Choisir un dossier dont les autorisations conviennent, et les detruire une fois remis.'))) {
        return
    }

    $connection = Get-ADTUiConnection
    $created = 0
    $failed = New-Object System.Collections.ArrayList
    foreach ($row in $rows) {
        try {
            $parameters = @{
                SamAccountName = [string]$row.SamAccountName
                Password       = [string]$row.Password
                Path           = $folder
                Confirm        = $false
            }
            if ($row.PSObject.Properties['DisplayName'] -and [string]$row.DisplayName) { $parameters['DisplayName'] = [string]$row.DisplayName }
            if ($row.PSObject.Properties['UserPrincipalName'] -and [string]$row.UserPrincipalName) { $parameters['UserPrincipalName'] = [string]$row.UserPrincipalName }
            if ($row.PSObject.Properties['Domain'] -and [string]$row.Domain) { $parameters['Domain'] = [string]$row.Domain }
            $result = New-ADTCredentialDocument @parameters @connection
            if ([string]$result.Status -eq 'Genere') { $created++ } else { [void]$failed.Add([string]$result.Error) }
        } catch {
            [void]$failed.Add($_.Exception.Message)
        }
    }
    $detailsBox.Text = ('{0} document(s) genere(s) dans {1}.' -f $created, $folder)
    if ($failed.Count) { $detailsBox.Text += [Environment]::NewLine + ($failed -join [Environment]::NewLine) }
    Set-ADTUiConsoleStatus ('{0} document(s) de remise genere(s).' -f $created)
}

function Get-ADTUiConsoleTreeDN {
    # Conteneur designe par l arborescence : le conteneur lui-meme, ou celui qui porte
    # la categorie ou l objet selectionne.
    $info = Get-ADTUiConsoleNodeInfo
    if ($info) { return [string]$info['ContainerDN'] }
    if ($script:Console.ContainerDN) { return $script:Console.ContainerDN }
    return $script:Console.DomainDN
}

function Get-ADTUiConsoleTreeTarget {
    # Element vise par le menu de l arborescence : l objet si un objet est
    # selectionne, sinon le conteneur.
    $info = Get-ADTUiConsoleNodeInfo
    if ($info -and [string]$info['Kind'] -eq 'Object') { return [string]$info['ObjectDN'] }
    return (Get-ADTUiConsoleTreeDN)
}

function Invoke-ADTUiConsoleState {
    param([ValidateSet('Enable', 'Disable', 'Unlock')][string]$Action)
    $targets = Get-ADTUiConsoleTarget -Class 'user'
    if (-not @($targets).Count) { $targets = Get-ADTUiConsoleTarget -Class 'computer' }
    if (-not @($targets).Count) { Show-ADTUiError 'Selectionner au moins un compte.'; return }
    $labels = Get-ADTUiConsoleLabel
    $wording = @{ 'Enable' = 'Activer les comptes'; 'Disable' = 'Desactiver les comptes'; 'Unlock' = 'Deverrouiller les comptes' }
    $null = Invoke-ADTUiConsoleWrite -Command 'Set-ADTAccountState' `
        -Parameters @{ Identity = [string[]]@($targets); Action = $Action } `
        -Action ([string]$wording[$Action]) -Target $labels
}

function Invoke-ADTUiConsoleMove {
    param([string]$Source)
    $targets = @()
    if ($Source) { $targets = @($Source) } else { $targets = Get-ADTUiConsoleTarget }
    if (-not @($targets).Count) { Show-ADTUiError 'Selectionner au moins un objet a deplacer.'; return }

    $destination = Select-ADTUiOrganizationalUnit
    if (-not $destination) { return }
    $labels = @()
    foreach ($dn in @($targets)) { $labels += (Get-ADTRdnValue -DistinguishedName ([string]$dn)) }

    $moved = Invoke-ADTUiConsoleWrite -Command 'Move-ADTObject' `
        -Parameters @{ Identity = [string[]]@($targets); TargetPath = $destination } `
        -Action 'Deplacer des objets' -Target $labels -Detail ('Destination : ' + $destination) -NoRefresh
    if ($moved -and -not [bool]$script:Console.Simulate.IsChecked) {
        # Un conteneur deplace change de place dans l arborescence : la recharger.
        Update-ADTUiConsoleTree -SelectDN $script:Console.ContainerDN
    }
}

function Invoke-ADTUiConsoleDelete {
    param([string]$Source)
    $targets = @()
    if ($Source) { $targets = @($Source) } else { $targets = Get-ADTUiConsoleTarget }
    if (-not @($targets).Count) { Show-ADTUiError 'Selectionner au moins un objet a supprimer.'; return }

    $labels = @()
    foreach ($dn in @($targets)) { $labels += (Get-ADTRdnValue -DistinguishedName ([string]$dn)) }

    $recursive = Show-ADTUiDialog -Title 'Supprimer definitivement' -AcceptText 'Supprimer le contenu aussi' -CancelText 'Objets vides seulement' -Message (
        ('{0} objet(s) vont etre supprimes de l annuaire.' -f @($targets).Count) + [Environment]::NewLine + [Environment]::NewLine +
        'Repondre "Supprimer le contenu aussi" autorise la suppression d une unite d organisation NON VIDE et de tout ce qu elle contient, et leve la protection contre la suppression accidentelle.' + [Environment]::NewLine + [Environment]::NewLine +
        'Repondre "Objets vides seulement" refuse ces deux cas : la suppression echouera plutot que d emporter du contenu.' + [Environment]::NewLine + [Environment]::NewLine +
        'Pour un depart d employe, preferer l onglet Depart : il sauvegarde les acces au lieu de detruire le compte.')

    $parameters = @{ Identity = [string[]]@($targets) }
    $detail = 'Objets vides ou comptes seulement.'
    if ($recursive) {
        $parameters['Recursive'] = $true
        $parameters['RemoveProtection'] = $true
        $detail = 'Suppression recursive, protection contre la suppression levee.'
    }

    $removed = Invoke-ADTUiConsoleWrite -Command 'Remove-ADTObject' -Parameters $parameters `
        -Action 'Supprimer definitivement' -Target $labels -Detail $detail -NoRefresh
    if ($removed -and -not [bool]$script:Console.Simulate.IsChecked) {
        Update-ADTUiConsoleTree -SelectDN $script:Console.ContainerDN
    }
}

function Invoke-ADTUiConsoleNewUser {
    $path = Get-ADTUiConsoleTreeDN
    if (-not $path) { Show-ADTUiError 'Charger l arborescence et selectionner un conteneur avant la creation d un compte utilisateur.'; return }
    $choice = Show-ADTUiNewUser -Path $path
    if (-not $choice) { return }
    $parameters = $choice['Parameters']
    $label = ('{0} {1}' -f [string]$parameters['GivenName'], [string]$parameters['Surname'])
    $created = Invoke-ADTUiConsoleWrite -Command 'New-ADTUser' -Parameters $parameters `
        -Action 'Creer un compte utilisateur' -Target @($label) -Detail ('OU cible : ' + [string]$parameters['Path'])
    if (-not $created) { return }
    if ($choice['Document'] -and -not [bool]$script:Console.Simulate.IsChecked) { New-ADTUiConsoleDocument }
}

function Invoke-ADTUiConsoleNewGroup {
    $path = Get-ADTUiConsoleTreeDN
    if (-not $path) { Show-ADTUiError 'Charger l arborescence et selectionner un conteneur avant la creation d un groupe.'; return }
    $parameters = Show-ADTUiNewGroup -Path $path
    if (-not $parameters) { return }
    $null = Invoke-ADTUiConsoleWrite -Command 'New-ADTGroup' -Parameters $parameters `
        -Action 'Creer un groupe' -Target @([string]$parameters['Name']) -Detail ('OU cible : ' + [string]$parameters['Path'])
}

function Invoke-ADTUiConsoleNewOrganizationalUnit {
    $path = Get-ADTUiConsoleTreeDN
    if (-not $path) { Show-ADTUiError 'Charger l arborescence et selectionner un conteneur avant la creation d une unite d organisation.'; return }
    $parameters = Show-ADTUiNewOrganizationalUnit -Path $path
    if (-not $parameters) { return }
    $created = Invoke-ADTUiConsoleWrite -Command 'New-ADTOrganizationalUnit' -Parameters $parameters `
        -Action 'Creer une unite d organisation' -Target @([string]$parameters['Name']) `
        -Detail ('Conteneur parent : ' + [string]$parameters['Path']) -NoRefresh
    if ($created -and -not [bool]$script:Console.Simulate.IsChecked) {
        Update-ADTUiConsoleTree -SelectDN $script:Console.ContainerDN
    }
}

function Invoke-ADTUiConsoleImportCsv {
<#
    Bascule vers l onglet d import en pre-remplissant l OU de destination avec le
    conteneur selectionne. L import lui-meme reste celui de l onglet : meme apercu,
    meme confirmation, meme rapport de mots de passe.
#>
    $path = Get-ADTUiConsoleTreeDN
    if (-not $path) { Show-ADTUiError 'Selectionner une unite d organisation dans l arborescence.'; return }
    if (-not $script:TabFields.ContainsKey('Import-ADTUserFromCsv')) {
        Show-ADTUiError 'Onglet d import indisponible.'
        return
    }
    $script:TabFields['Import-ADTUserFromCsv']['DefaultOU'].Control.Text = $path
    try {
        $tabs.SelectedIndex = [int]$script:ToolsTabIndex
        $script:ToolTabs.SelectedIndex = [int]$script:TabIndex['Import-ADTUserFromCsv']
    } catch { Add-ADTUiSmokeWarning 'Bascule vers l onglet d import impossible.' }
    Set-ADTUiConsoleStatus ('Outils > Importer un CSV : OU de destination pre-remplie avec {0}.' -f $path)
}

function Invoke-ADTUiConsoleGroupAction {
    # Ouvre la gestion des membres du groupe selectionne dans la liste.
    $groups = @(Get-ADTUiConsoleSelection -Class 'group')
    if (-not $groups.Count) { Show-ADTUiError 'Selectionner un groupe dans la liste.'; return }
    if ($groups.Count -gt 1) { Show-ADTUiError 'Ouvrir les membres d un seul groupe a la fois.'; return }
    Invoke-ADTUiConsoleGroupMembers -GroupDN ([string]$groups[0].DistinguishedName) -GroupName ([string]$groups[0].Name)
}

function Get-ADTUiConsoleAction {
    # Retrouve une action par son libelle. Les menus evoluent : indexer le tableau
    # par position casserait silencieusement un bouton a la premiere insertion.
    param([hashtable[]]$Item, [string]$Header)
    foreach ($entry in $Item) {
        if ([string]$entry['Header'] -eq $Header) { return [scriptblock]$entry['Action'] }
    }
    throw ('Action de console inconnue : {0}' -f $Header)
}

function New-ADTUiConsoleTab {
<#
    Construit la section Annuaire et rend son contenu : l arborescence a gauche, le
    contenu de l element selectionne a droite, les actions sous la liste.
#>
    param($Busy)

    $tree = [GliderUI.Avalonia.Controls.TreeView]::new()
    $tree.Height = 560
    $script:Console.Tree = $tree

    $grid = New-ADTUiObjectGrid -Column (Get-ADTUiConsoleColumn) -Height 470
    $script:Console.Grid = $grid

    $header = New-ADTUiText -Text 'Selectionner une unite d organisation dans l arborescence.' -Bold -Wrap
    $script:Console.Header = $header
    $summary = New-ADTUiText -Text '' -Wrap -Foreground '#4A5A6E'
    $script:Console.Summary = $summary

    $simulate = New-ADTUiCheck -Label 'Mode simulation : les actions sont verifiees sans rien modifier dans Active Directory' -Checked $true
    $script:Console.Simulate = $simulate

    $searchBox = [GliderUI.Avalonia.Controls.TextBox]::new()
    $searchBox.Watermark = 'Rechercher un nom, un identifiant, un UPN, un courriel...'
    $script:Console.SearchBox = $searchBox

    $searchScope = [GliderUI.Avalonia.Controls.ComboBox]::new()
    foreach ($item in @('Unite selectionnee', 'Tout le domaine')) { $searchScope.Items.Add($item) | Out-Null }
    $searchScope.SelectedIndex = 1
    $script:Console.SearchScope = $searchScope

    $typeFilter = [GliderUI.Avalonia.Controls.ComboBox]::new()
    foreach ($item in @('Tous les objets', 'Utilisateurs', 'Groupes', 'Ordinateurs', 'Unites d organisation')) {
        $typeFilter.Items.Add($item) | Out-Null
    }
    $typeFilter.SelectedIndex = 0
    $script:Console.TypeFilter = $typeFilter

    $guard = {
        param([scriptblock]$Body)
        try { & $Body } catch { Show-ADTUiError $_.Exception.Message }
    }

    $reload = { & $guard { Update-ADTUiConsoleTree -SelectDN $script:Console.ContainerDN } }.GetNewClosure()
    $refreshList = { & $guard { Update-ADTUiConsoleList } }.GetNewClosure()
    $search = { & $guard { Invoke-ADTUiConsoleSearch } }.GetNewClosure()

    # Un clic dans l arborescence : conteneur, categorie ou objet.
    $null = Add-ADTUiEvent -Target $tree -Name 'SelectionChanged' -Handler {
        & $guard {
            $info = Get-ADTUiConsoleNodeInfo
            if (-not $info) { return }
            $script:Console.SearchBox.Text = ''
            switch ([string]$info['Kind']) {
                'Container' { Show-ADTUiConsoleView -ContainerDN ([string]$info['ContainerDN']) }
                'Category' { Show-ADTUiConsoleView -ContainerDN ([string]$info['ContainerDN']) -Class ([string]$info['Class']) }
                'Object' {
                    Show-ADTUiConsoleView -ContainerDN ([string]$info['ContainerDN']) -Class ([string]$info['Class']) `
                        -FocusDN ([string]$info['ObjectDN'])
                }
            }
        }
    }.GetNewClosure()

    $properties = { & $guard { Invoke-ADTUiConsoleProperties } }.GetNewClosure()
    $null = Add-ADTUiEvent -Target $grid -Name 'DoubleTapped' -Handler $properties
    $null = Add-ADTUiEvent -Target $tree -Name 'DoubleTapped' -Handler {
        & $guard {
            $info = Get-ADTUiConsoleNodeInfo
            if ($info -and [string]$info['Kind'] -eq 'Object') {
                Invoke-ADTUiConsoleProperties -DistinguishedName ([string]$info['ObjectDN'])
            }
        }
    }.GetNewClosure()

    # --- Recherche ---------------------------------------------------------------
    $searchBar = New-ADTUiGridLayout -Column @('Star', 'Auto', 'Auto', 'Auto', 'Auto') -ColumnSpacing 10
    $null = Add-ADTUiGridRow -Grid $searchBar
    Add-ADTUiCell -Grid $searchBar -Row 0 -Column 0 -Child $searchBox
    Add-ADTUiCell -Grid $searchBar -Row 0 -Column 1 -Child $searchScope
    Add-ADTUiCell -Grid $searchBar -Row 0 -Column 2 -Child $typeFilter
    Add-ADTUiCell -Grid $searchBar -Row 0 -Column 3 -Child (New-ADTUiButton -Text 'Chercher' -Width 120 -Accent -OnClick $search -DisableWhileBusy $Busy)
    Add-ADTUiCell -Grid $searchBar -Row 0 -Column 4 -Child (New-ADTUiButton -Text 'Effacer' -Width 100 -OnClick {
            $script:Console.SearchBox.Text = ''
            & $refreshList
        }.GetNewClosure())

    # --- Actions sur l arborescence --------------------------------------------
    $containerActions = @(
        @{ Header = 'Nouvel utilisateur'; Action = { & $guard { Invoke-ADTUiConsoleNewUser } }.GetNewClosure() },
        @{ Header = 'Nouveau groupe'; Action = { & $guard { Invoke-ADTUiConsoleNewGroup } }.GetNewClosure() },
        @{ Header = 'Nouvelle unite d organisation'; Action = { & $guard { Invoke-ADTUiConsoleNewOrganizationalUnit } }.GetNewClosure() },
        @{ Header = '-'; Action = $null },
        @{ Header = 'Importer un CSV dans cette OU'; Action = { & $guard { Invoke-ADTUiConsoleImportCsv } }.GetNewClosure() },
        @{ Header = '-'; Action = $null },
        @{ Header = 'Actualiser'; Action = $reload },
        @{ Header = 'Deplacer...'; Action = { & $guard { Invoke-ADTUiConsoleMove -Source (Get-ADTUiConsoleTreeTarget) } }.GetNewClosure() },
        @{ Header = 'Supprimer...'; Action = { & $guard { Invoke-ADTUiConsoleDelete -Source (Get-ADTUiConsoleTreeTarget) } }.GetNewClosure() },
        @{ Header = 'Proprietes'; Action = { & $guard { Invoke-ADTUiConsoleProperties -DistinguishedName (Get-ADTUiConsoleTreeTarget) } }.GetNewClosure() }
    )
    $null = Set-ADTUiMenu -Target $tree -Menu (New-ADTUiMenu -Item $containerActions)

    $treeButtons = New-ADTUiRow -Spacing 6 -Child @(
        (New-ADTUiButton -Text 'Actualiser' -OnClick $reload -DisableWhileBusy $Busy),
        (New-ADTUiButton -Text 'Nouvelle OU...' -OnClick (Get-ADTUiConsoleAction -Item $containerActions -Header 'Nouvelle unite d organisation')),
        (New-ADTUiButton -Text 'Importer un CSV ici...' -OnClick (Get-ADTUiConsoleAction -Item $containerActions -Header 'Importer un CSV dans cette OU'))
    )

    # --- Actions sur la selection ---------------------------------------------
    $objectActions = @(
        @{ Header = 'Proprietes'; Action = $properties },
        @{ Header = 'Reinitialiser le mot de passe...'; Action = { & $guard { Invoke-ADTUiConsolePassword } }.GetNewClosure() },
        @{ Header = '-'; Action = $null },
        @{ Header = 'Activer'; Action = { & $guard { Invoke-ADTUiConsoleState -Action 'Enable' } }.GetNewClosure() },
        @{ Header = 'Desactiver'; Action = { & $guard { Invoke-ADTUiConsoleState -Action 'Disable' } }.GetNewClosure() },
        @{ Header = 'Deverrouiller'; Action = { & $guard { Invoke-ADTUiConsoleState -Action 'Unlock' } }.GetNewClosure() },
        @{ Header = '-'; Action = $null },
        @{ Header = 'Gerer les groupes...'; Action = { & $guard { Invoke-ADTUiConsoleMembership } }.GetNewClosure() },
        @{ Header = 'Membres du groupe...'; Action = { & $guard { Invoke-ADTUiConsoleGroupAction } }.GetNewClosure() },
        @{ Header = 'Horaires de connexion...'; Action = { & $guard { Invoke-ADTUiConsoleLogonHours } }.GetNewClosure() },
        @{ Header = '-'; Action = $null },
        @{ Header = 'Deplacer...'; Action = { & $guard { Invoke-ADTUiConsoleMove } }.GetNewClosure() },
        @{ Header = 'Supprimer...'; Action = { & $guard { Invoke-ADTUiConsoleDelete } }.GetNewClosure() }
    )
    $null = Set-ADTUiMenu -Target $grid -Menu (New-ADTUiMenu -Item $objectActions)

    $createRow = New-ADTUiRow -Spacing 8 -Child @(
        (New-ADTUiText -Text 'Creer :' -Bold),
        (New-ADTUiButton -Text 'Utilisateur...' -Accent -OnClick (Get-ADTUiConsoleAction -Item $containerActions -Header 'Nouvel utilisateur')),
        (New-ADTUiButton -Text 'Groupe...' -OnClick (Get-ADTUiConsoleAction -Item $containerActions -Header 'Nouveau groupe'))
    )
    $rowOne = New-ADTUiRow -Spacing 8 -Child @(
        (New-ADTUiText -Text 'Selection :' -Bold),
        (New-ADTUiButton -Text 'Proprietes' -OnClick $properties -DisableWhileBusy $Busy),
        (New-ADTUiButton -Text 'Mot de passe...' -OnClick (Get-ADTUiConsoleAction -Item $objectActions -Header 'Reinitialiser le mot de passe...')),
        (New-ADTUiButton -Text 'Activer' -OnClick (Get-ADTUiConsoleAction -Item $objectActions -Header 'Activer')),
        (New-ADTUiButton -Text 'Desactiver' -OnClick (Get-ADTUiConsoleAction -Item $objectActions -Header 'Desactiver')),
        (New-ADTUiButton -Text 'Deverrouiller' -OnClick (Get-ADTUiConsoleAction -Item $objectActions -Header 'Deverrouiller'))
    )
    $rowTwo = New-ADTUiRow -Spacing 8 -Child @(
        (New-ADTUiText -Text '' -Bold),
        (New-ADTUiButton -Text 'Groupes...' -OnClick (Get-ADTUiConsoleAction -Item $objectActions -Header 'Gerer les groupes...')),
        (New-ADTUiButton -Text 'Membres du groupe...' -OnClick (Get-ADTUiConsoleAction -Item $objectActions -Header 'Membres du groupe...')),
        (New-ADTUiButton -Text 'Horaires de connexion...' -OnClick (Get-ADTUiConsoleAction -Item $objectActions -Header 'Horaires de connexion...')),
        (New-ADTUiButton -Text 'Deplacer...' -OnClick (Get-ADTUiConsoleAction -Item $objectActions -Header 'Deplacer...')),
        (New-ADTUiButton -Text 'Supprimer...' -OnClick (Get-ADTUiConsoleAction -Item $objectActions -Header 'Supprimer...')),
        (New-ADTUiButton -Text 'Actualiser' -OnClick $refreshList)
    )

    $listPanel = New-ADTUiStack -Spacing 8 -Child @($header, $summary, $grid, $createRow, $rowOne, $rowTwo)
    $treePanel = New-ADTUiStack -Spacing 8 -Child @(
        (New-ADTUiText -Text 'Annuaire' -Bold),
        $tree,
        $treeButtons,
        (New-ADTUiText -Wrap -Foreground '#4A5A6E' -Text 'Chaque unite montre ses utilisateurs, groupes et ordinateurs. Clic droit : actions sur l element selectionne. Double-clic sur un objet : ses proprietes.')
    )

    $body = New-ADTUiGridLayout -Column @(400, 'Star') -ColumnSpacing 16
    $null = Add-ADTUiGridRow -Grid $body
    Add-ADTUiCell -Grid $body -Row 0 -Column 0 -Child $treePanel
    Add-ADTUiCell -Grid $body -Row 0 -Column 1 -Child $listPanel

    $content = New-ADTUiStack -Margin 12 -Spacing 10 -Child @(
        $searchBar,
        (New-ADTUiRow -Spacing 16 -Child @(
                $simulate,
                (New-ADTUiText -Wrap -Foreground '#4A5A6E' -Text 'Ctrl ou Maj : selection multiple dans la liste.'))),
        $body
    )
    return $content
}
