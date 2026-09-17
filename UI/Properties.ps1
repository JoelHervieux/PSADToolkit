#requires -version 7.4
using namespace GliderUI
using namespace GliderUI.Avalonia
using namespace GliderUI.Avalonia.Controls

<#
    Feuille de proprietes d un objet Active Directory, organisee en sections comme
    la console Microsoft : General, Compte, Organisation, Adresse, Profil, Groupes
    et Horaires de connexion.

    La fenetre ne modifie rien elle-meme : elle rend la liste des proprietes
    reellement changees, que la console applique ensuite par Set-ADTUser ou
    Set-ADTOrganizationalUnit. Seuls les champs modifies sont transmis, pour qu un
    champ laisse tel quel ne soit jamais reecrit.
#>

function New-ADTUiPropertySection {
    param([string]$Header, [object[]]$Child)
    $tab = [GliderUI.Avalonia.Controls.TabItem]::new()
    $tab.Header = $Header
    $scroll = [GliderUI.Avalonia.Controls.ScrollViewer]::new()
    $scroll.Content = New-ADTUiStack -Margin 16 -Spacing 12 -Child $Child
    $tab.Content = $scroll
    return $tab
}

function Show-ADTUiProperties {
<#
    Affiche la feuille de proprietes. Rend $null si l operateur ferme sans
    enregistrer, sinon une table decrivant l action a executer.
#>
    param($Object)

    $class = [string]$Object.ObjectClass
    $isUser = ($class -eq 'user')
    $isGroup = ($class -eq 'group')
    $isUnit = ($class -eq 'organizationalUnit')

    $state = @{ Run = $false; LogonHoursMask = $null; ManageGroups = $false; ManageMembers = $false }
    $fields = @{}

    # La fenetre est creee avant les boutons : plusieurs d entre eux la ferment,
    # et .GetNewClosure() fige la valeur des variables au moment ou le bloc est
    # cree. Declaree plus bas, elle vaudrait $null dans ces closures.
    $propertiesWindow = [GliderUI.Avalonia.Controls.Window]::new()
    $propertiesWindow.Title = 'Proprietes de ' + [string]$Object.Name
    $propertiesWindow.Width = 900
    $propertiesWindow.Height = 760
    $propertiesWindow.WindowStartupLocation = 'CenterOwner'

    $addField = {
        param([string]$Key, [string]$Label, [string]$Property, [switch]$ReadOnly, [int]$Height)
        $value = [string]$Object.$Property
        $field = New-ADTUiTextField -Label $Label -Value $value -ReadOnly:$ReadOnly -Height $Height
        $fields[$Key] = @{ Box = $field.Box; Original = $value; Property = $Property; ReadOnly = [bool]$ReadOnly }
        return $field.Panel
    }.GetNewClosure()

    $checks = @{}
    $addCheck = {
        param([string]$Key, [string]$Label, [string]$Property, [switch]$ReadOnly)
        $value = [bool]$Object.$Property
        $check = New-ADTUiCheck -Label $Label -Checked $value -Disabled:$ReadOnly
        $checks[$Key] = @{ Control = $check; Original = $value; ReadOnly = [bool]$ReadOnly }
        return $check
    }.GetNewClosure()

    $tabs = [GliderUI.Avalonia.Controls.TabControl]::new()

    # --- General ---------------------------------------------------------------
    $general = @(
        (& $addField 'Name' 'Nom (CN)' 'Name'),
        (& $addField 'Description' 'Description' 'Description')
    )
    if ($isUser) {
        $general = @(
            (& $addField 'GivenName' 'Prenom' 'GivenName'),
            (& $addField 'Initials' 'Initiales' 'Initials'),
            (& $addField 'Surname' 'Nom' 'Surname'),
            (& $addField 'DisplayName' 'Nom affiche' 'DisplayName'),
            (& $addField 'Name' 'Nom de l objet (CN)' 'Name'),
            (& $addField 'Description' 'Description' 'Description'),
            (& $addField 'Office' 'Bureau' 'Office'),
            (& $addField 'OfficePhone' 'Telephone' 'OfficePhone'),
            (& $addField 'MobilePhone' 'Mobile' 'MobilePhone'),
            (& $addField 'EmailAddress' 'Courriel' 'EmailAddress')
        )
    }
    $general += (New-ADTUiText -Wrap -Text ('Emplacement : ' + [string]$Object.Container))
    $general += (New-ADTUiText -Wrap -Text ('Cree le ' + (Format-ADTDateTime -Value $Object.whenCreated) +
            '   -   Modifie le ' + (Format-ADTDateTime -Value $Object.whenChanged)))
    $tabs.Items.Add((New-ADTUiPropertySection -Header 'General' -Child $general)) | Out-Null

    # --- Compte ----------------------------------------------------------------
    $expiryBox = $null
    $neverExpires = $null
    if ($isUser) {
        $expiryValue = ''
        if ($Object.AccountExpiresEndOfDay) { $expiryValue = Format-ADTDateTime -Value $Object.AccountExpiresEndOfDay -Kind Date }
        $expiryField = New-ADTUiTextField -Label ('Dernier jour ouvert du compte (format ' + (Format-ADTDateTime -Value (Get-Date) -Kind Date) + ')') -Value $expiryValue
        $expiryBox = $expiryField.Box
        $neverExpires = New-ADTUiCheck -Label 'Le compte n expire jamais' -Checked (-not $Object.AccountExpirationDate)

        $account = @(
            (& $addField 'SamAccountName' 'Identifiant (anterieur a Windows 2000)' 'SamAccountName' -ReadOnly),
            (& $addField 'UserPrincipalName' 'Nom d utilisateur principal (UPN)' 'UserPrincipalName'),
            (New-ADTUiText -Text ('Etat : ' + [string]$Object.Status)),
            (New-ADTUiText -Text ('Mot de passe defini le ' + (Format-ADTDateTime -Value $Object.PasswordLastSet))),
            (New-ADTUiText -Text ('Derniere connexion : ' + (Format-ADTDateTime -Value $Object.LastLogonDate) + ' (lastLogonTimestamp, precision de 9 a 14 jours)')),
            (New-ADTUiText -Text 'Options de compte' -Bold),
            (& $addCheck 'MustChangePassword' 'L utilisateur doit changer de mot de passe a la prochaine ouverture de session' 'MustChangePassword'),
            (& $addCheck 'CannotChangePassword' 'L utilisateur ne peut pas changer de mot de passe (porte par les autorisations, lecture seule)' 'CannotChangePassword' -ReadOnly),
            (& $addCheck 'PasswordNeverExpires' 'Le mot de passe n expire jamais' 'PasswordNeverExpires'),
            (& $addCheck 'PasswordNotRequired' 'Aucun mot de passe requis' 'PasswordNotRequired'),
            (& $addCheck 'SmartcardLogonRequired' 'Une carte a puce est necessaire pour ouvrir une session' 'SmartcardLogonRequired'),
            (& $addCheck 'AccountNotDelegated' 'Le compte est sensible et ne peut pas etre delegue' 'AccountNotDelegated'),
            (& $addCheck 'DoesNotRequirePreAuth' 'La pre-authentification Kerberos n est pas necessaire' 'DoesNotRequirePreAuth'),
            (New-ADTUiText -Text 'Expiration du compte' -Bold),
            $neverExpires,
            $expiryField.Panel,
            (New-ADTUiText -Wrap -Text 'Le compte reste utilisable toute la journee indiquee et expire a minuit, comme dans la console Microsoft.')
        )
        $tabs.Items.Add((New-ADTUiPropertySection -Header 'Compte' -Child $account)) | Out-Null

        # --- Organisation ------------------------------------------------------
        $organisation = @(
            (& $addField 'Title' 'Fonction' 'Title'),
            (& $addField 'Department' 'Service' 'Department'),
            (& $addField 'Company' 'Societe' 'Company'),
            (& $addField 'EmployeeID' 'Matricule' 'EmployeeID'),
            (New-ADTUiText -Text ('Gestionnaire actuel : ' + (Get-ADTRdnValue -DistinguishedName ([string]$Object.Manager)))),
            (& $addField 'Manager' 'Gestionnaire (identifiant ou DN, vide pour effacer)' 'Manager')
        )
        $tabs.Items.Add((New-ADTUiPropertySection -Header 'Organisation' -Child $organisation)) | Out-Null

        # --- Adresse -----------------------------------------------------------
        $address = @(
            (& $addField 'StreetAddress' 'Rue' 'StreetAddress'),
            (& $addField 'City' 'Ville' 'City'),
            (& $addField 'State' 'Province ou etat' 'State'),
            (& $addField 'PostalCode' 'Code postal' 'PostalCode'),
            (& $addField 'Country' 'Pays' 'Country')
        )
        $tabs.Items.Add((New-ADTUiPropertySection -Header 'Adresse' -Child $address)) | Out-Null

        # --- Profil ------------------------------------------------------------
        $profileTab = @(
            (& $addField 'ProfilePath' 'Chemin du profil' 'ProfilePath'),
            (& $addField 'ScriptPath' 'Script d ouverture de session' 'ScriptPath'),
            (& $addField 'HomeDirectory' 'Dossier personnel' 'HomeDirectory'),
            (& $addField 'HomeDrive' 'Lecteur reseau (ex. H:)' 'HomeDrive'),
            (& $addField 'Notes' 'Notes' 'Notes' -Height 120)
        )
        $tabs.Items.Add((New-ADTUiPropertySection -Header 'Profil' -Child $profileTab)) | Out-Null
    }

    # --- Groupes ---------------------------------------------------------------
    if ($isUser) {
        $memberOf = ((@($Object.MemberOfNames) | Sort-Object) -join [Environment]::NewLine)
        $groupsField = New-ADTUiTextField -Label 'Membre de' -Value $memberOf -ReadOnly -Height 260
        $manageGroups = New-ADTUiButton -Text 'Gerer les groupes...' -OnClick {
            $state.ManageGroups = $true
            $state.Run = $true
            $propertiesWindow.Close()
        }.GetNewClosure()
        $tabs.Items.Add((New-ADTUiPropertySection -Header 'Groupes' -Child @(
                    (New-ADTUiText -Wrap -Text ('{0} appartenance(s) directe(s). Le groupe principal n apparait pas dans memberOf.' -f @($Object.MemberOfNames).Count)),
                    $groupsField.Panel,
                    $manageGroups
                ))) | Out-Null
    }

    # --- Horaires de connexion -------------------------------------------------
    if ($isUser) {
        $hoursText = New-ADTUiText -Wrap -Text ('Horaire actuel : ' + [string]$Object.LogonHoursText)
        $editHours = New-ADTUiButton -Text 'Modifier l horaire...' -OnClick {
            $start = $state.LogonHoursMask
            if (-not $start) { $start = [string]$Object.LogonHoursMask }
            $chosen = Show-ADTUiLogonHoursEditor -Mask $start -Subtitle ('Compte : ' + [string]$Object.SamAccountName)
            if ($chosen) {
                $state.LogonHoursMask = $chosen
                $hoursText.Text = 'Horaire retenu (non encore applique) : ' + (ConvertTo-ADTLogonHoursText -Mask $chosen)
            }
        }.GetNewClosure()
        $tabs.Items.Add((New-ADTUiPropertySection -Header 'Horaires de connexion' -Child @(
                    $hoursText, $editHours,
                    (New-ADTUiText -Wrap -Text 'L horaire choisi est applique en meme temps que les autres modifications, au moment de l enregistrement.')
                ))) | Out-Null
    }

    # --- Groupe ----------------------------------------------------------------
    if ($isGroup) {
        $manageMembers = New-ADTUiButton -Text 'Gerer les membres...' -OnClick {
            $state.ManageMembers = $true
            $state.Run = $true
            $propertiesWindow.Close()
        }.GetNewClosure()
        $tabs.Items.Add((New-ADTUiPropertySection -Header 'Groupe' -Child @(
                    (New-ADTUiText -Text ('Etendue : ' + [string]$Object.GroupScope)),
                    (New-ADTUiText -Text ('Type : ' + [string]$Object.GroupCategory)),
                    (New-ADTUiText -Text ('Identifiant : ' + [string]$Object.SamAccountName)),
                    $manageMembers
                ))) | Out-Null
    }

    # --- Unite d organisation --------------------------------------------------
    $protect = $null
    if ($isUnit) {
        $protect = New-ADTUiCheck -Label 'Proteger le conteneur contre une suppression accidentelle' -Checked ([bool]$Object.ProtectedFromDeletion)
        $tabs.Items.Add((New-ADTUiPropertySection -Header 'Unite d organisation' -Child @(
                    (& $addField 'ManagedBy' 'Gere par (identifiant ou DN, vide pour effacer)' 'ManagedBy'),
                    $protect,
                    (New-ADTUiText -Wrap -Text 'La protection est une entree de refus pour Tout le monde sur les droits de suppression. La lever demande le droit de modifier les autorisations de l objet.')
                ))) | Out-Null
    }

    # --- Objet -----------------------------------------------------------------
    $identity = @(
        (New-ADTUiText -Text ('Type : ' + [string]$Object.ObjectType)),
        (New-ADTUiText -Wrap -Text ('Nom unique : ' + [string]$Object.DistinguishedName)),
        (New-ADTUiText -Wrap -Text ('SID : ' + [string]$Object.SID))
    )
    if ($null -ne $Object.ProtectedFromDeletion) {
        $protectionLabel = 'non'
        if ([bool]$Object.ProtectedFromDeletion) { $protectionLabel = 'oui' }
        $identity += (New-ADTUiText -Text ('Protege contre la suppression accidentelle : ' + $protectionLabel))
    }
    if ([string]$Object.OperatingSystem) {
        $identity += (New-ADTUiText -Text ('Systeme : ' + [string]$Object.OperatingSystem + ' ' + [string]$Object.OperatingSystemVersion))
        $identity += (New-ADTUiText -Text ('Nom DNS : ' + [string]$Object.DnsHostName))
    }
    $tabs.Items.Add((New-ADTUiPropertySection -Header 'Objet' -Child $identity)) | Out-Null

    # --- Fenetre ---------------------------------------------------------------
    $cancel = New-ADTUiButton -Text 'Fermer sans enregistrer' -Width 210 -OnClick { $propertiesWindow.Close() }.GetNewClosure()
    $accept = New-ADTUiButton -Text 'Enregistrer' -Width 170 -Accent -OnClick {
        $state.Run = $true
        $propertiesWindow.Close()
    }.GetNewClosure()
    if (-not ($isUser -or $isUnit)) { $accept.IsEnabled = $false }

    $propertiesWindow.Content = New-ADTUiStack -Margin 16 -Spacing 12 -Child @(
        (New-ADTUiText -Text ([string]$Object.ObjectType + ' : ' + [string]$Object.Name) -Bold),
        $tabs,
        (New-ADTUiRow -Align 'Right' -Spacing 12 -Child @($cancel, $accept))
    )
    $propertiesWindow.Show()
    $propertiesWindow.WaitForClosed()
    if (-not $state.Run) { return $null }

    if ($state.ManageGroups) { return @{ Action = 'ManageGroups'; Identity = [string]$Object.DistinguishedName; Object = $Object } }
    if ($state.ManageMembers) { return @{ Action = 'ManageMembers'; Identity = [string]$Object.DistinguishedName; Object = $Object } }

    # --- Recolte des modifications ---------------------------------------------
    $parameters = @{ Identity = [string]$Object.DistinguishedName }
    $changed = New-Object System.Collections.ArrayList

    foreach ($key in @($fields.Keys)) {
        $field = $fields[$key]
        if ($field['ReadOnly']) { continue }
        $value = [string]$field['Box'].Text
        if ($value -eq [string]$field['Original']) { continue }
        if ($key -eq 'Name') { $parameters['NewName'] = $value }
        else { $parameters[$key] = $value }
        [void]$changed.Add($key)
    }
    foreach ($key in @($checks.Keys)) {
        $check = $checks[$key]
        if ($check['ReadOnly']) { continue }
        $value = [bool]$check['Control'].IsChecked
        if ($value -eq [bool]$check['Original']) { continue }
        $parameters[$key] = $value
        [void]$changed.Add($key)
    }

    if ($isUser) {
        $originalNever = (-not $Object.AccountExpirationDate)
        $wantNever = [bool]$neverExpires.IsChecked
        $expiryText = ''
        if ($expiryBox) { $expiryText = ([string]$expiryBox.Text).Trim() }
        $originalExpiry = ''
        if ($Object.AccountExpiresEndOfDay) { $originalExpiry = Format-ADTDateTime -Value $Object.AccountExpiresEndOfDay -Kind Date }

        if ($wantNever -and -not $originalNever) {
            $parameters['NeverExpires'] = $true
            [void]$changed.Add('AccountExpirationDate')
        } elseif (-not $wantNever -and $expiryText -and $expiryText -ne $originalExpiry) {
            $parsed = [datetime]::MinValue
            if (-not [datetime]::TryParse($expiryText, (Get-ADTDisplayCulture), [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
                Show-ADTUiError ('Date d expiration illisible : "{0}". Format attendu : {1}' -f $expiryText, (Format-ADTDateTime -Value (Get-Date) -Kind Date))
                return $null
            }
            $parameters['AccountExpirationDate'] = $parsed
            [void]$changed.Add('AccountExpirationDate')
        }
    }

    if ($isUnit -and $protect) {
        if ([bool]$protect.IsChecked -ne [bool]$Object.ProtectedFromDeletion) {
            $parameters['ProtectFromAccidentalDeletion'] = [bool]$protect.IsChecked
            [void]$changed.Add('Protection')
        }
    }

    $action = 'SetUser'
    if ($isUnit) { $action = 'SetOrganizationalUnit' }

    return @{
        Action         = $action
        Parameters     = $parameters
        Changed        = @($changed)
        LogonHoursMask = $state.LogonHoursMask
        Object         = $Object
    }
}
