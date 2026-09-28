<#
    Parcours scripte de l interface pour le test de fumee d integration continue.

    Dot-source par Start-PSADToolkit.ps1 -SmokeTest une fois la fenetre principale
    construite. L annuaire est celui de Smoke-FakeDirectory.ps1. Chaque fenetre
    secondaire s affiche puis se referme d elle-meme (Show-ADTUiModal) ; une capture
    d ecran est prise a chaque etape quand un dossier de capture est fourni.

    Echoue - code de sortie 1 - si une erreur a ete presentee a l operateur, si une
    etape leve une exception ou si une verification ne tient pas.
#>

$smokeChecks = New-Object System.Collections.ArrayList
$smokeSteps = New-Object System.Collections.ArrayList

if ($SmokeReportPath) {
    $folder = Split-Path -Parent $SmokeReportPath
    if ($folder) {
        $captures = Join-Path $folder 'captures'
        if (-not (Test-Path -LiteralPath $captures)) { $null = New-Item -Path $captures -ItemType Directory -Force }
        $script:ADTUiSmoke.CaptureFolder = $captures
    }
}

# Le selecteur d OU lit l annuaire par une requete directe : le remplacer aussi.
function Get-ADTUiOrganizationalUnit {
    param([string]$SearchBase, [string]$Server, [System.Management.Automation.PSCredential]$Credential)
    foreach ($item in $script:FakeContainers) {
        if ([string]$item.Class -eq 'organizationalUnit') { [pscustomobject]@{ Name = $item.Name; DN = $item.DN } }
    }
}

function Invoke-SmokeStep {
    param([string]$Name, [scriptblock]$Action)
    $entry = [ordered]@{ Name = $Name; Ok = $true; Error = '' }
    try { & $Action }
    catch {
        $entry.Ok = $false
        $entry.Error = $_.Exception.Message + ' | ' + [string]$_.ScriptStackTrace
    }
    [void]$smokeSteps.Add([pscustomobject]$entry)
}

function Test-SmokeCondition {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    [void]$smokeChecks.Add([pscustomobject]@{ Name = $Name; Ok = $Condition; Detail = $Detail })
}

function Save-SmokeScreen {
    # Capture d une vue de la fenetre principale, apres le temps de rendu.
    param([string]$Name)
    [void]$script:ADTUiSmoke.Shown.Add('Vue : ' + $Name)
    if (-not $script:ADTUiSmoke.CaptureFolder) { return }
    Start-Sleep -Milliseconds $script:ADTUiSmoke.RenderDelayMs
    Save-ADTUiSmokeScreenshot -Name $Name
}

function Get-SmokeCategoryHeader {
    param([string]$ContainerDN)
    $headers = @()
    foreach ($node in @($script:Console.Categories[$ContainerDN])) { $headers += [string]$node.Header }
    return , $headers
}

$employes = 'OU=Employes,DC=lab,DC=local'
$volume = 'OU=Volume,DC=lab,DC=local'
$joel = 'CN=Joel Cote,OU=Employes,DC=lab,DC=local'
$ventes = 'CN=GS-Ventes,OU=Employes,DC=lab,DC=local'

# --- Ouverture : choix du domaine -----------------------------------------------

Invoke-SmokeStep 'Fenetre de choix du domaine' {
    $choices = @(Get-ADTUiDomainChoice)
    Test-SmokeCondition 'Domaines proposes' ($choices.Count -ge 2) ('{0} domaine(s)' -f $choices.Count)
    $null = Show-ADTUiDomainChooser
}

Invoke-SmokeStep 'Connexion au domaine simule' {
    $connection = Connect-ADTUiDomain -Target 'lab.local'
    Set-ADTUiConnection -Connection $connection
    Test-SmokeCondition 'Bandeau du domaine' ([string]$domainText.Text -eq 'Domaine : lab.local') ([string]$domainText.Text)
}

Invoke-SmokeStep 'Nom de domaine invalide refuse' {
    $refused = $false
    try { $null = Connect-ADTUiDomain -Target 'lab local; rm' } catch { $refused = $true }
    Test-SmokeCondition 'Validation du nom de domaine' $refused
}

# --- Annuaire -----------------------------------------------------------------

Invoke-SmokeStep 'Chargement de l arborescence' {
    Update-ADTUiConsoleTree
    Test-SmokeCondition 'Conteneurs indexes' ($script:Console.Nodes.Count -eq 7) ('{0} noeud(s)' -f $script:Console.Nodes.Count)
}

Invoke-SmokeStep 'Fenetre principale' {
    $window.Show()
    Save-SmokeScreen 'annuaire-domaine'
}

Invoke-SmokeStep 'Ouverture d une OU' {
    $script:Console.Tree.SelectedItem = $script:Console.Nodes[$employes]
    Show-ADTUiConsoleView -ContainerDN $employes
    $headers = Get-SmokeCategoryHeader -ContainerDN $employes
    Test-SmokeCondition 'Categories sous l OU' (($headers -join '|') -eq 'Utilisateurs (3)|Groupes (2)|Ordinateurs (1)') ($headers -join '|')
    Test-SmokeCondition 'Liste de l OU' (@($script:Console.Rows).Count -eq 7) ('{0} ligne(s)' -f @($script:Console.Rows).Count)
    Test-SmokeCondition 'Resume de l OU' ([string]$script:Console.Summary.Text -eq '3 utilisateur(s), 2 groupe(s), 1 ordinateur(s), 1 unite(s)') ([string]$script:Console.Summary.Text)
    Save-SmokeScreen 'annuaire-ou-employes'
}

Invoke-SmokeStep 'Categorie Groupes' {
    Show-ADTUiConsoleView -ContainerDN $employes -Class 'group'
    Test-SmokeCondition 'Filtre par categorie' (@($script:Console.Rows).Count -eq 2) ('{0} ligne(s)' -f @($script:Console.Rows).Count)
    Save-SmokeScreen 'annuaire-groupes'
}

Invoke-SmokeStep 'Objet choisi dans l arborescence' {
    Show-ADTUiConsoleView -ContainerDN $employes -Class 'user' -FocusDN $joel
    $selected = @(Get-ADTUiConsoleTarget)
    Test-SmokeCondition 'Objet selectionne dans la liste' (($selected -join '|') -eq $joel) ($selected -join '|')
    Save-SmokeScreen 'annuaire-utilisateur'
}

Invoke-SmokeStep 'OU volumineuse' {
    Show-ADTUiConsoleView -ContainerDN $volume
    $category = @($script:Console.Categories[$volume])[0]
    $leaves = @($category.Items).Count
    Test-SmokeCondition 'Plafond des noeuds' ($leaves -eq ($script:Console.LeafLimit + 1)) ('{0} noeud(s)' -f $leaves)
    Test-SmokeCondition 'Liste complete' (@($script:Console.Rows).Count -eq 150) ('{0} ligne(s)' -f @($script:Console.Rows).Count)
}

Invoke-SmokeStep 'Recherche' {
    $script:Console.SearchBox.Text = 'Cote'
    Invoke-ADTUiConsoleSearch
    Test-SmokeCondition 'Resultat de recherche' (@($script:Console.Rows).Count -eq 1) ('{0} ligne(s)' -f @($script:Console.Rows).Count)
    Save-SmokeScreen 'annuaire-recherche'
    $script:Console.SearchBox.Text = ''
}

Invoke-SmokeStep 'Retour a l OU apres recherche' {
    Show-ADTUiConsoleView -ContainerDN $employes
    Test-SmokeCondition 'Liste relue apres recherche' (@($script:Console.Rows).Count -eq 7) ('{0} ligne(s)' -f @($script:Console.Rows).Count)
}

# --- Fenetres secondaires -------------------------------------------------------

Invoke-SmokeStep 'Proprietes d un utilisateur' { Invoke-ADTUiConsoleProperties -DistinguishedName $joel }
Invoke-SmokeStep 'Proprietes d un groupe' { Invoke-ADTUiConsoleProperties -DistinguishedName $ventes }
Invoke-SmokeStep 'Proprietes d une OU' { Invoke-ADTUiConsoleProperties -DistinguishedName $employes }
Invoke-SmokeStep 'Membres d un groupe' { Invoke-ADTUiConsoleGroupMembers -GroupDN $ventes -GroupName 'GS-Ventes' }
Invoke-SmokeStep 'Appartenances aux groupes' { Invoke-ADTUiConsoleMembership -Target @($joel) -CurrentGroup @('GS-VPN') }
Invoke-SmokeStep 'Mot de passe' { Invoke-ADTUiConsolePassword -Target @($joel) }
Invoke-SmokeStep 'Horaires de connexion' { Invoke-ADTUiConsoleLogonHours -Member @($joel) -Origin 'la selection' }
Invoke-SmokeStep 'Grille des horaires' {
    $null = Show-ADTUiLogonHoursEditor -Mask (New-ADTLogonHoursMask -Day 1, 2, 3, 4, 5 -StartHour 8 -EndHour 18) -Subtitle 'Test'
}
Invoke-SmokeStep 'Selection des membres' {
    $null = Show-ADTUiMemberSelection -Member @(Get-ADTGroupMember -Identity $ventes) -Detail 'Test'
}
Invoke-SmokeStep 'Nouvel utilisateur' { Invoke-ADTUiConsoleNewUser }
Invoke-SmokeStep 'Nouveau groupe' { Invoke-ADTUiConsoleNewGroup }
Invoke-SmokeStep 'Nouvelle OU' { Invoke-ADTUiConsoleNewOrganizationalUnit }
Invoke-SmokeStep 'Selecteur d OU' { $null = Select-ADTUiOrganizationalUnit }
Invoke-SmokeStep 'Confirmation' {
    $null = Confirm-ADTUiConsoleWrite -Action 'Test' -Target @('jcote') -Detail 'Detail' -Simulate $false
}
Invoke-SmokeStep 'Apercu d import CSV' {
    $csv = Join-Path $script:Root 'Examples\nouveaux-employes.csv'
    $null = Show-ADTUiImportPreview -Parameters @{ Path = $csv; DefaultOU = $employes }
}
Invoke-SmokeStep 'Bascule vers l import CSV' {
    Invoke-ADTUiConsoleImportCsv
    Test-SmokeCondition 'Onglet Outils affiche' ([int]$tabs.SelectedIndex -eq [int]$script:ToolsTabIndex) ([string]$tabs.SelectedIndex)
    Save-SmokeScreen 'outils-import'
    $tabs.SelectedIndex = 0
}

# --- Ecritures simulees -------------------------------------------------------

Invoke-SmokeStep 'Ecriture en simulation' {
    Test-SmokeCondition 'Simulation cochee par defaut' ([bool]$script:Console.Simulate.IsChecked)
    $applied = Invoke-ADTUiConsoleWrite -Command 'Set-ADTAccountState' `
        -Parameters @{ Identity = @($joel); Action = 'Disable' } -Action 'Desactiver' -Target @('jcote')
    Test-SmokeCondition 'Ecriture simulee executee' ([bool]$applied)
    Test-SmokeCondition 'Resultat au journal' (@($script:Rows).Count -eq 1 -and [string]@($script:Rows)[0].Status -eq 'Simulation') ([string]$statusText.Text)
    Save-SmokeScreen 'journal-simulation'
}

Invoke-SmokeStep 'Onglet historique' {
    $spec = $specs | Where-Object { $_.Command -eq 'Get-ADTInactiveAccount' } | Select-Object -First 1
    $fields = $script:TabFields['Get-ADTInactiveAccount']
    Test-SmokeCondition 'Onglet historique enregistre' ($null -ne $fields)
    $simulate = [GliderUI.Avalonia.Controls.CheckBox]::new()
    $simulate.IsChecked = $true
    Invoke-ADTUiExecute -Spec $spec -Fields $fields -Simulate $simulate
}

Invoke-SmokeStep 'Changement de domaine' { $null = Show-ADTUiDomainChooser -AllowCancel }

Invoke-SmokeStep 'Fermeture' { $window.Close() }

# --- Rapport ------------------------------------------------------------------

$failedSteps = @($smokeSteps | Where-Object { -not $_.Ok })
$failedChecks = @($smokeChecks | Where-Object { -not $_.Ok })
$report = [ordered]@{
    PowerShell = [string]$PSVersionTable.PSVersion
    OS         = [string][Environment]::OSVersion.VersionString
    GliderUI   = [string](Get-Module -Name GliderUI).Version
    Steps      = @($smokeSteps)
    Checks     = @($smokeChecks)
    Shown      = @($script:ADTUiSmoke.Shown)
    Errors     = @($script:ADTUiSmoke.Errors)
    Warnings   = @($script:ADTUiSmoke.Warnings)
}
$json = ConvertTo-Json -InputObject $report -Depth 4
if ($SmokeReportPath) { Set-Content -LiteralPath $SmokeReportPath -Value $json -Encoding UTF8 }
Write-Output $json

if ($failedSteps.Count -or $failedChecks.Count -or $script:ADTUiSmoke.Errors.Count) {
    Write-Error ('Test de fumee en echec : {0} etape(s), {1} verification(s), {2} erreur(s) affichee(s).' -f `
            $failedSteps.Count, $failedChecks.Count, $script:ADTUiSmoke.Errors.Count) -ErrorAction Continue
    exit 1
}
Write-Output 'Test de fumee reussi.'
