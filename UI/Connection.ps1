#requires -version 7.4

<#
    Connexion a un domaine : choisie a l ouverture, conservee pour toute la session.

    La fenetre "Choisir un domaine" s ouvre avant l interface. La connexion y est
    verifiee par Test-ADTPrerequisite : on n entre dans l annuaire qu une fois le
    domaine joint. Le controleur retenu par cette verification est ensuite utilise
    par TOUTES les operations, pour que deux requetes successives ne tombent pas sur
    deux controleurs differents et ne lisent pas un annuaire non encore replique.

    Le mot de passe d un autre compte est converti en SecureString des la connexion
    et la zone de saisie videe aussitot. Les domaines recents sont memorises sans
    aucun secret : nom, controleur, compte.
#>

$script:Connection = @{
    Server     = ''
    DomainName = ''
    Credential = $null
    Account    = ''
}

function Get-ADTUiConnection {
    # Parametres de connexion communs, a passer par splat aux fonctions du module.
    if (-not $script:Connection.Server) {
        throw 'Aucun domaine selectionne. Utiliser "Changer de domaine".'
    }
    $parameters = @{ Server = [string]$script:Connection.Server }
    if ($script:Connection.Credential) { $parameters['Credential'] = $script:Connection.Credential }
    return $parameters
}

function Get-ADTUiRecentDomainPath {
    $root = [Environment]::GetFolderPath('ApplicationData')
    if (-not $root) { $root = [System.IO.Path]::GetTempPath() }
    return (Join-Path $root 'PSADToolkit\domaines-recents.json')
}

function Get-ADTUiRecentDomain {
    $path = Get-ADTUiRecentDomainPath
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    try { return @(Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json) }
    catch { return @() }
}

function Save-ADTUiRecentDomain {
    param([string]$Name, [string]$Server, [string]$Account)
    try {
        $entries = New-Object System.Collections.ArrayList
        [void]$entries.Add([pscustomobject]@{ Name = $Name; Server = $Server; Account = $Account; LastUsed = (Get-Date).ToString('o') })
        foreach ($entry in (Get-ADTUiRecentDomain)) {
            if ([string]$entry.Name -eq $Name) { continue }
            if ($entries.Count -ge 8) { break }
            [void]$entries.Add($entry)
        }
        $path = Get-ADTUiRecentDomainPath
        $folder = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $folder)) { $null = New-Item -Path $folder -ItemType Directory -Force }
        ConvertTo-Json -InputObject @($entries) -Depth 3 | Set-Content -LiteralPath $path -Encoding UTF8
    } catch {
        # Ne pas memoriser un domaine recent n empeche pas de travailler.
        Add-ADTUiSmokeWarning ('Domaines recents non enregistres : ' + $_.Exception.Message)
    }
}

function Get-ADTUiDomainChoice {
    # Domaines proposes : recents d abord, puis ceux que l annuaire laisse detecter.
    $rows = New-Object System.Collections.ArrayList
    $seen = @{}
    foreach ($entry in (Get-ADTUiRecentDomain)) {
        $name = ([string]$entry.Name).ToLowerInvariant()
        if (-not $name -or $seen.ContainsKey($name)) { continue }
        $seen[$name] = $true
        $origin = 'Utilise recemment'
        if ([string]$entry.Account) { $origin += ' (' + [string]$entry.Account + ')' }
        [void]$rows.Add([pscustomobject]@{ Name = $name; Source = $origin; DistinguishedName = $name })
    }
    try {
        foreach ($candidate in @(Get-ADTNativeDomainCandidate)) {
            $name = ([string]$candidate.Name).ToLowerInvariant()
            if (-not $name -or $seen.ContainsKey($name)) { continue }
            $seen[$name] = $true
            [void]$rows.Add([pscustomobject]@{ Name = $name; Source = [string]$candidate.Source; DistinguishedName = $name })
        }
    } catch { Add-ADTUiSmokeWarning ('Detection des domaines : ' + $_.Exception.Message) }
    return , @($rows)
}

function Connect-ADTUiDomain {
<#
    Verifie la connexion a un domaine et rend la connexion a conserver. Leve une
    erreur explicite si le domaine ne repond pas : la fenetre l affiche sans se fermer.
#>
    param([string]$Target, [System.Management.Automation.PSCredential]$Credential)
    $clean = ([string]$Target).Trim()
    if (-not $clean) { throw 'Choisir un domaine dans la liste, ou en saisir un.' }
    if ($clean -notmatch '^[a-zA-Z0-9][a-zA-Z0-9.\-]*$') {
        throw ('"{0}" n est pas un nom de domaine ni de controleur valide. Exemple : contoso.local ou dc01.contoso.local' -f $clean)
    }
    $parameters = @{ Server = $clean }
    if ($Credential) { $parameters['Credential'] = $Credential }
    $check = Test-ADTPrerequisite @parameters
    if (-not $check.Ready) { throw ('Connexion a {0} impossible : {1}' -f $clean, [string]$check.Messages) }

    $account = 'session Windows (' + (Get-ADTOperatorName) + ')'
    if ($Credential) { $account = [string]$Credential.UserName }
    return @{
        Server     = [string]$check.Server
        DomainName = [string]$check.DomainName
        Credential = $Credential
        Account    = $account
    }
}

function Set-ADTUiConnection {
    # Adopte une connexion et l affiche dans le bandeau de la fenetre principale.
    param([hashtable]$Connection)
    $script:Connection = $Connection
    if ($domainText) { $domainText.Text = 'Domaine : ' + [string]$Connection.DomainName }
    if ($domainDetail) {
        $domainDetail.Text = 'Controleur : ' + [string]$Connection.Server + '   -   Compte : ' + [string]$Connection.Account
    }
    Save-ADTUiRecentDomain -Name ([string]$Connection.DomainName) -Server ([string]$Connection.Server) `
        -Account $(if ($Connection.Credential) { [string]$Connection.Credential.UserName } else { '' })
}

function Show-ADTUiDomainChooser {
<#
    Fenetre d ouverture : choisir le domaine a gerer. Rend la connexion etablie, ou
    $null si l operateur quitte.
#>
    param([switch]$AllowCancel)

    $state = @{ Result = $null }
    $choices = Get-ADTUiDomainChoice

    $dialog = [GliderUI.Avalonia.Controls.Window]::new()
    $dialog.Title = 'PSADToolkit - Choisir un domaine'
    $dialog.Width = 700
    $dialog.Height = 640
    $dialog.WindowStartupLocation = 'CenterScreen'

    $columns = @(
        @{ Header = 'Domaine'; Path = 'Name' },
        @{ Header = 'Origine'; Path = 'Source' }
    )
    $grid = New-ADTUiObjectGrid -Column $columns -Height 200 -SingleSelection
    $rows = Set-ADTUiObjectGridSource -Grid $grid -Column $columns -Row $choices
    if (@($rows).Count) { try { $grid.SelectedIndex = 0 } catch { Add-ADTUiSmokeWarning 'Premier domaine non preselectionne.' } }

    $typed = New-ADTUiTextField -Label 'Ou saisir un domaine, ou le nom d un controleur de domaine'
    $typed.Box.Watermark = 'contoso.local  ou  dc01.contoso.local'

    $other = New-ADTUiCheck -Label 'Utiliser un autre compte que celui de la session Windows'
    $user = New-ADTUiTextField -Label 'Compte (DOMAINE\utilisateur ou UPN)'
    $password = New-ADTUiTextField -Label 'Mot de passe'
    $password.Box.PasswordChar = '*'
    $user.Box.IsEnabled = $false
    $password.Box.IsEnabled = $false
    $null = Add-ADTUiEvent -Target $other -Name 'IsCheckedChanged' -Handler {
        $enabled = [bool]$other.IsChecked
        $user.Box.IsEnabled = $enabled
        $password.Box.IsEnabled = $enabled
        if (-not $enabled) { $password.Box.Text = '' }
    }.GetNewClosure()

    $credentialRow = New-ADTUiGridLayout -Column @('Star', 'Star') -ColumnSpacing 12
    $null = Add-ADTUiGridRow -Grid $credentialRow
    Add-ADTUiCell -Grid $credentialRow -Row 0 -Column 0 -Child $user.Panel
    Add-ADTUiCell -Grid $credentialRow -Row 0 -Column 1 -Child $password.Panel

    $status = New-ADTUiText -Text '' -Wrap -Foreground '#B3261E'

    $connect = {
        try {
            $target = ([string]$typed.Box.Text).Trim()
            if (-not $target) {
                $picked = @(Get-ADTUiSelectedRow -Grid $grid -Row $rows)
                if ($picked.Count) { $target = [string]$picked[0].Name }
            }
            $credential = $null
            if ([bool]$other.IsChecked) {
                $name = ([string]$user.Box.Text).Trim()
                $secretText = [string]$password.Box.Text
                if (-not $name -or -not $secretText) { throw 'Indiquer le compte et son mot de passe.' }
                $secure = New-Object System.Security.SecureString
                foreach ($character in $secretText.ToCharArray()) { $secure.AppendChar($character) }
                $secure.MakeReadOnly()
                $secretText = $null
                $credential = New-Object System.Management.Automation.PSCredential($name, $secure)
            }
            $status.Text = 'Connexion en cours...'
            $state.Result = Connect-ADTUiDomain -Target $target -Credential $credential
            $password.Box.Text = ''
            $dialog.Close()
        } catch {
            $status.Text = $_.Exception.Message
        }
    }.GetNewClosure()

    $connectButton = New-ADTUiButton -Text 'Se connecter' -Width 180 -Accent
    $quitLabel = 'Quitter'
    if ($AllowCancel) { $quitLabel = 'Annuler' }
    $quitButton = New-ADTUiButton -Text $quitLabel -Width 150 -OnClick { $dialog.Close() }.GetNewClosure()
    $connectButton.AddClick([GliderUI.EventCallback]@{
            DisabledControlsWhileProcessing = @($connectButton, $quitButton)
            ScriptBlock                     = $connect
        })
    $null = Add-ADTUiEvent -Target $grid -Name 'DoubleTapped' -Handler $connect

    $intro = 'Choisir un domaine detecte, ou en saisir un. La connexion est verifiee avant d ouvrir l annuaire.'
    if (-not @($rows).Count) { $intro = 'Aucun domaine detecte depuis ce poste : saisir le nom du domaine, ou celui d un controleur de domaine.' }

    $dialog.Content = New-ADTUiStack -Margin 22 -Spacing 12 -Child @(
        (New-ADTUiText -Text 'Quel domaine voulez-vous gerer ?' -Bold),
        (New-ADTUiText -Text $intro -Wrap),
        $grid,
        $typed.Panel,
        $other,
        $credentialRow,
        (New-ADTUiText -Wrap -Foreground '#4A5A6E' -Text 'Les droits delegues dans Active Directory sont necessaires : etre administrateur local ne les donne pas.'),
        $status,
        (New-ADTUiRow -Align 'Right' -Spacing 12 -Child @($quitButton, $connectButton))
    )
    Show-ADTUiModal -Window $dialog
    return $state.Result
}
