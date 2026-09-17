# Lecture de l annuaire pour la console d administration (arborescence, listes,
# recherche, fiches de proprietes). Meme contrainte que DirectoryBackend.ps1 :
# System.DirectoryServices uniquement, ni RSAT ni ADWS, Windows PowerShell 2.0.
#
# Search-ADTDirectory reste la fonction des commandes historiques : elle charge
# une liste fixe d attributs et refuse un memberOf tronque, ce qui est le bon
# comportement pour une sauvegarde de depart. La console, elle, doit choisir ses
# attributs, limiter la portee a un seul niveau et ne jamais echouer parce qu un
# gros groupe tronque memberOf. D ou une seconde fonction de recherche.

function Get-ADTDirectoryAttribute {
<#
.SYNOPSIS
    Liste des attributs LDAP charges par la console selon le besoin.
.PARAMETER Set
    List (grilles et arborescence) ou Detail (fiche de proprietes complete).
.EXAMPLE
    Get-ADTDirectoryAttribute -Set List
#>
    [CmdletBinding()]
    param([ValidateSet('List', 'Detail')][string]$Set = 'List')
    $list = @(
        'name', 'displayName', 'sAMAccountName', 'distinguishedName', 'objectClass', 'objectSid',
        'userAccountControl', 'lastLogonTimestamp', 'pwdLastSet', 'accountExpires', 'lockoutTime',
        'whenCreated', 'whenChanged', 'description', 'department', 'title', 'userPrincipalName',
        'mail', 'groupType', 'operatingSystem', 'dNSHostName', 'primaryGroupID'
    )
    if ($Set -eq 'List') { return [string[]]$list }
    return [string[]]($list + @(
            'givenName', 'sn', 'initials', 'company', 'physicalDeliveryOfficeName', 'manager',
            'telephoneNumber', 'mobile', 'homeDirectory', 'homeDrive', 'profilePath', 'scriptPath',
            'logonHours', 'memberOf', 'managedBy', 'streetAddress', 'l', 'st', 'postalCode', 'co',
            'employeeID', 'operatingSystemVersion', 'badPwdCount', 'info'
        ))
}

function Get-ADTDirectoryClassLabel {
<#
.SYNOPSIS
    Libelle francais d une classe d objet Active Directory.
.EXAMPLE
    Get-ADTDirectoryClassLabel -ObjectClass 'organizationalUnit'
#>
    [CmdletBinding()]
    param([Parameter(Position = 0)][AllowEmptyString()][string]$ObjectClass)
    switch ([string]$ObjectClass) {
        'organizationalUnit' { return 'Unite d organisation' }
        'container' { return 'Conteneur' }
        'builtinDomain' { return 'Conteneur integre' }
        'user' { return 'Utilisateur' }
        'computer' { return 'Ordinateur' }
        'group' { return 'Groupe' }
        'contact' { return 'Contact' }
        'domainDNS' { return 'Domaine' }
        default { return [string]$ObjectClass }
    }
}

function Get-ADTGroupTypeLabel {
<#
.SYNOPSIS
    Traduit groupType en etendue et en categorie, comme la console Microsoft.
.EXAMPLE
    Get-ADTGroupTypeLabel -GroupType -2147483646
#>
    [CmdletBinding()]
    param([Parameter(Position = 0)][int]$GroupType)
    $scope = 'Globale'
    if (($GroupType -band 4) -ne 0) { $scope = 'Domaine local' }
    if (($GroupType -band 8) -ne 0) { $scope = 'Universelle' }
    $category = 'Distribution'
    if (($GroupType -band ([int]::MinValue)) -ne 0) { $category = 'Securite' }
    return New-Object PSObject -Property @{ GroupScope = $scope; GroupCategory = $category }
}

function ConvertFrom-ADTDirectoryProperty {
<#
.SYNOPSIS
    Transforme les proprietes brutes d un resultat LDAP en objet exploitable.
.DESCRIPTION
    Accepte indifferemment un SearchResult (Properties indexees en minuscules) ou
    une DirectoryEntry. Contrairement a ConvertFrom-ADTSearchResult, un memberOf
    tronque n interrompt pas la lecture : la console affiche une liste, elle ne
    prepare pas une sauvegarde. L etat de verrouillage est calcule avec la duree
    de verrouillage du domaine quand l appelant la fournit.
.EXAMPLE
    ConvertFrom-ADTDirectoryProperty -Property $result.Properties
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]$Property,
        [long]$LockoutDurationTicks = 0
    )
    $p = $Property
    $read = {
        param($Name)
        $values = $p[$Name]
        if ($null -eq $values -or $values.Count -eq 0) { return $null }
        return $values[0]
    }
    $readString = {
        param($Name)
        $value = & $read $Name
        if ($null -eq $value) { return '' }
        return [string]$value
    }
    $readLong = {
        param($Name)
        $value = & $read $Name
        if ($null -eq $value) { return [long]0 }
        # ADSI rend parfois un COM LargeInteger (HighPart/LowPart) au lieu d un Int64.
        if ($value -is [string] -or $value -is [long] -or $value -is [int]) { return [long]$value }
        try {
            $high = [long]$value.GetType().InvokeMember('HighPart', 'GetProperty', $null, $value, $null)
            $low = [long]$value.GetType().InvokeMember('LowPart', 'GetProperty', $null, $value, $null)
            if ($low -lt 0) { $low = $low + 4294967296 }
            return ($high * 4294967296) + $low
        } catch { return [long]0 }
    }
    $readFileTime = {
        param($Name)
        $ticks = & $readLong $Name
        if ($ticks -le 0 -or $ticks -ge 9223372036854775807) { return $null }
        try { return [DateTime]::FromFileTimeUtc($ticks).ToLocalTime() } catch { return $null }
    }

    $classes = @($p['objectclass'])
    $objectClass = ''
    if ($classes.Count) { $objectClass = [string]$classes[$classes.Count - 1] }

    $sid = $null
    if ($p['objectsid'] -and $p['objectsid'].Count) {
        try { $sid = New-Object System.Security.Principal.SecurityIdentifier($p['objectsid'][0], 0) } catch { $sid = $null }
    }

    $uac = 0
    $uacValue = & $read 'useraccountcontrol'
    if ($null -ne $uacValue) { $uac = [int]$uacValue }

    $lockoutTicks = & $readLong 'lockouttime'
    $lockedOut = $false
    if ($lockoutTicks -gt 0) {
        if ($LockoutDurationTicks -eq 0) { $lockedOut = $true }
        else {
            # lockoutDuration est une duree negative en intervalles de 100 ns.
            $expiry = [DateTime]::FromFileTimeUtc($lockoutTicks).AddTicks([Math]::Abs($LockoutDurationTicks))
            $lockedOut = ($expiry -gt [DateTime]::UtcNow)
        }
    }

    $logonHours = $null
    if ($p['logonhours'] -and $p['logonhours'].Count) {
        try { $logonHours = [byte[]]$p['logonhours'][0] } catch { $logonHours = $null }
    }

    $groupType = 0
    $groupTypeValue = & $read 'grouptype'
    if ($null -ne $groupTypeValue) { $groupType = [int]$groupTypeValue }
    $groupScope = ''
    $groupCategory = ''
    if ($objectClass -eq 'group') {
        $labels = Get-ADTGroupTypeLabel -GroupType $groupType
        $groupScope = [string]$labels.GroupScope
        $groupCategory = [string]$labels.GroupCategory
    }

    $pwdLastSetTicks = & $readLong 'pwdlastset'

    $created = $null
    $createdValue = & $read 'whencreated'
    if ($null -ne $createdValue) { try { $created = [datetime]$createdValue } catch { $created = $null } }
    $changed = $null
    $changedValue = & $read 'whenchanged'
    if ($null -ne $changedValue) { try { $changed = [datetime]$changedValue } catch { $changed = $null } }

    $name = & $readString 'name'
    $displayName = & $readString 'displayname'
    if (-not $displayName) { $displayName = $name }

    $result = New-Object PSObject -Property @{
        Name                     = $name
        DisplayName              = $displayName
        SamAccountName           = & $readString 'samaccountname'
        DistinguishedName        = & $readString 'distinguishedname'
        ObjectClass              = $objectClass
        ObjectType               = (Get-ADTDirectoryClassLabel -ObjectClass $objectClass)
        SID                      = $sid
        Enabled                  = (($uac -band 2) -eq 0)
        LockedOut                = $lockedOut
        PasswordNeverExpires     = (($uac -band 65536) -ne 0)
        PasswordNotRequired      = (($uac -band 32) -ne 0)
        SmartcardLogonRequired   = (($uac -band 262144) -ne 0)
        AccountNotDelegated      = (($uac -band 1048576) -ne 0)
        DoesNotRequirePreAuth    = (($uac -band 4194304) -ne 0)
        CannotChangePassword     = (($uac -band 64) -ne 0)
        UserAccountControl       = $uac
        MustChangePassword       = ($pwdLastSetTicks -eq 0)
        LastLogonDate            = & $readFileTime 'lastlogontimestamp'
        PasswordLastSet          = & $readFileTime 'pwdlastset'
        AccountExpirationDate    = & $readFileTime 'accountexpires'
        LockoutTime              = & $readFileTime 'lockouttime'
        whenCreated              = $created
        whenChanged              = $changed
        Description              = & $readString 'description'
        Department               = & $readString 'department'
        Title                    = & $readString 'title'
        Company                  = & $readString 'company'
        Office                   = & $readString 'physicaldeliveryofficename'
        UserPrincipalName        = & $readString 'userprincipalname'
        EmailAddress             = & $readString 'mail'
        GivenName                = & $readString 'givenname'
        Surname                  = & $readString 'sn'
        Initials                 = & $readString 'initials'
        Manager                  = & $readString 'manager'
        ManagedBy                = & $readString 'managedby'
        OfficePhone              = & $readString 'telephonenumber'
        MobilePhone              = & $readString 'mobile'
        HomeDirectory            = & $readString 'homedirectory'
        HomeDrive                = & $readString 'homedrive'
        ProfilePath              = & $readString 'profilepath'
        ScriptPath               = & $readString 'scriptpath'
        StreetAddress            = & $readString 'streetaddress'
        City                     = & $readString 'l'
        State                    = & $readString 'st'
        PostalCode               = & $readString 'postalcode'
        Country                  = & $readString 'co'
        EmployeeID               = & $readString 'employeeid'
        Notes                    = & $readString 'info'
        OperatingSystem          = & $readString 'operatingsystem'
        OperatingSystemVersion   = & $readString 'operatingsystemversion'
        DnsHostName              = & $readString 'dnshostname'
        PrimaryGroupID           = & $readString 'primarygroupid'
        GroupType                = $groupType
        GroupScope               = $groupScope
        GroupCategory            = $groupCategory
        LogonHours               = $logonHours
        MemberOf                 = @($p['memberof'])
        BadPasswordCount         = & $readString 'badpwdcount'
    }
    return $result
}

function Search-ADTDirectoryEntry {
<#
.SYNOPSIS
    Recherche LDAP parametrable : portee, attributs, plafond de resultats.
.PARAMETER LDAPFilter
    Filtre LDAP deja echappe par l appelant (ConvertTo-ADTLdapValue).
.PARAMETER SearchBase
    DN de depart. Par defaut, le domaine courant.
.PARAMETER Scope
    Base (l objet seul), OneLevel (enfants directs) ou Subtree.
.PARAMETER SizeLimit
    Nombre maximal de resultats. 0 = sans limite. Protege l interface d une
    recherche trop large sur un gros domaine.
.EXAMPLE
    Search-ADTDirectoryEntry -LDAPFilter '(objectClass=group)' -Scope OneLevel -SearchBase 'OU=Test,DC=contoso,DC=local'
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$LDAPFilter,
        [string]$SearchBase,
        [ValidateSet('Base', 'OneLevel', 'Subtree')][string]$Scope = 'Subtree',
        [string[]]$Property,
        [int]$SizeLimit = 0,
        [long]$LockoutDurationTicks = 0,
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential
    )
    if (-not $SearchBase) { $SearchBase = (Get-ADTNativeDomain -Server $Server -Credential $Credential).DistinguishedName }
    if (-not $Property) { $Property = Get-ADTDirectoryAttribute -Set List }

    $entry = Open-ADTEntry -DN $SearchBase -Server $Server -Credential $Credential
    $search = New-Object System.DirectoryServices.DirectorySearcher($entry)
    $results = $null
    try {
        $search.Filter = $LDAPFilter
        $search.SearchScope = [System.DirectoryServices.SearchScope]$Scope
        $search.PageSize = 500
        if ($SizeLimit -gt 0) {
            $search.SizeLimit = $SizeLimit
            # Sans cette remise a zero, la pagination ignore SizeLimit et le
            # serveur renvoie tout l annuaire malgre le plafond demande.
            $search.PageSize = 0
        }
        $search.ClientTimeout = New-TimeSpan -Seconds 60
        $search.ServerTimeLimit = New-TimeSpan -Seconds 60
        $search.ReferralChasing = [System.DirectoryServices.ReferralChasingOption]::None
        foreach ($attribute in $Property) { [void]$search.PropertiesToLoad.Add($attribute) }
        $results = $search.FindAll()
        foreach ($item in $results) {
            ConvertFrom-ADTDirectoryProperty -Property $item.Properties -LockoutDurationTicks $LockoutDurationTicks
        }
    } finally {
        if ($results) { $results.Dispose() }
        $search.Dispose()
        $entry.Dispose()
    }
}

function Get-ADTNativeContainerChild {
<#
.SYNOPSIS
    Enfants directs d un conteneur : OU, conteneurs, utilisateurs, groupes, ordinateurs.
.PARAMETER Include
    Classes a retenir. Par defaut toutes celles que la console sait afficher.
.EXAMPLE
    Get-ADTNativeContainerChild -DistinguishedName 'OU=Employes,DC=contoso,DC=local'
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$DistinguishedName,
        [string[]]$Include = @('organizationalUnit', 'container', 'user', 'group', 'computer'),
        [int]$SizeLimit = 0,
        [long]$LockoutDurationTicks = 0,
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential
    )
    $clauses = New-Object System.Collections.ArrayList
    foreach ($class in $Include) {
        switch ($class) {
            'organizationalUnit' { [void]$clauses.Add('(objectClass=organizationalUnit)') }
            'container' { [void]$clauses.Add('(objectClass=container)'); [void]$clauses.Add('(objectClass=builtinDomain)') }
            'user' { [void]$clauses.Add('(&(objectCategory=person)(objectClass=user))') }
            'group' { [void]$clauses.Add('(objectClass=group)') }
            'computer' { [void]$clauses.Add('(objectCategory=computer)') }
            default { throw ('Classe non prise en charge par la console : {0}' -f $class) }
        }
    }
    if (-not $clauses.Count) { return }
    $filter = '(|' + ($clauses -join '') + ')'
    # Un ordinateur est aussi un user : sans exclusion, il apparaitrait deux fois
    # lorsque les deux classes sont demandees.
    if (($Include -contains 'user') -and -not ($Include -contains 'computer')) {
        $filter = '(&' + $filter + '(!(objectCategory=computer)))'
    }
    Search-ADTDirectoryEntry -LDAPFilter $filter -SearchBase $DistinguishedName -Scope OneLevel `
        -SizeLimit $SizeLimit -LockoutDurationTicks $LockoutDurationTicks -Server $Server -Credential $Credential
}

function Get-ADTNativeObjectDetail {
<#
.SYNOPSIS
    Lit tous les attributs de la fiche de proprietes d un objet designe par son DN.
.EXAMPLE
    Get-ADTNativeObjectDetail -DistinguishedName 'CN=jcote,OU=Employes,DC=contoso,DC=local'
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$DistinguishedName,
        [long]$LockoutDurationTicks = 0,
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential
    )
    $found = @(Search-ADTDirectoryEntry -LDAPFilter '(objectClass=*)' -SearchBase $DistinguishedName -Scope Base `
            -Property (Get-ADTDirectoryAttribute -Set Detail) -LockoutDurationTicks $LockoutDurationTicks `
            -Server $Server -Credential $Credential)
    if ($found.Count -ne 1) { throw ('Objet introuvable : {0}' -f $DistinguishedName) }
    return $found[0]
}

function Get-ADTNativeDirectMember {
<#
.SYNOPSIS
    Membres directs d un groupe, y compris son groupe principal.
.DESCRIPTION
    La recherche part de memberOf plutot que de l attribut member du groupe :
    au-dela d environ 1500 entrees, member est renvoye par tranches et une
    lecture naive perdrait des membres sans le signaler. memberOf n a pas cette
    limite. Le groupe principal (Utilisateurs du domaine par defaut) n apparait
    dans aucun des deux : il est ajoute via primaryGroupID.
.EXAMPLE
    Get-ADTNativeDirectMember -GroupDN 'CN=GS-VPN,OU=Groupes,DC=contoso,DC=local'
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$GroupDN,
        [switch]$Recursive,
        [long]$LockoutDurationTicks = 0,
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential
    )
    $escaped = ConvertTo-ADTLdapValue $GroupDN
    $membership = '(memberOf=' + $escaped + ')'
    if ($Recursive) { $membership = '(memberOf:1.2.840.113556.1.4.1941:=' + $escaped + ')' }

    $primary = ''
    try {
        $group = Get-ADTNativeObjectDetail -DistinguishedName $GroupDN -Server $Server -Credential $Credential
        $domainSid = (Get-ADTNativeDomain -Server $Server -Credential $Credential).DomainSID.Value
        if ($group.SID -and $group.SID.Value.StartsWith($domainSid + '-')) {
            $primary = '(primaryGroupID=' + ($group.SID.Value -split '-')[-1] + ')'
        }
    } catch {
        Write-Verbose ('Groupe principal non verifie pour {0} : {1}' -f $GroupDN, $_.Exception.Message)
    }

    $filter = '(&(!(objectClass=foreignSecurityPrincipal))(|' + $membership + $primary + '))'
    Search-ADTDirectoryEntry -LDAPFilter $filter -LockoutDurationTicks $LockoutDurationTicks -Server $Server -Credential $Credential
}

function Get-ADTNativePasswordPolicy {
<#
.SYNOPSIS
    Politique de mot de passe et de verrouillage du domaine.
.DESCRIPTION
    Lit la strategie par defaut sur la racine du domaine. Lorsqu un utilisateur
    est fourni et que le domaine expose msDS-ResultantPSO (niveau 2008 et plus),
    la strategie affinee applicable a ce compte est lue et prend le dessus.
    Les durees sont des intervalles de 100 ns negatifs dans AD ; elles sont
    converties en jours et en minutes.
.EXAMPLE
    Get-ADTNativePasswordPolicy -Server 'dc01.contoso.local'
#>
    [CmdletBinding()]
    param(
        [string]$UserDistinguishedName,
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential
    )
    $domain = Get-ADTNativeDomain -Server $Server -Credential $Credential
    $entry = Open-ADTEntry -DN $domain.DistinguishedName -Server $domain.Server -Credential $Credential
    $minLength = 7
    $complexity = $true
    $historyLength = 0
    $maxAgeDays = 0
    $minAgeDays = 0
    $lockoutThreshold = 0
    $lockoutDurationTicks = [long]0
    $source = 'Strategie de domaine par defaut'
    try {
        $readAttribute = {
            param($Name)
            $values = $entry.Properties[$Name]
            if ($null -eq $values -or $values.Count -eq 0) { return $null }
            return $values[0]
        }
        $value = & $readAttribute 'minPwdLength'
        if ($null -ne $value) { $minLength = [int]$value }
        $value = & $readAttribute 'pwdProperties'
        if ($null -ne $value) { $complexity = ((([int]$value) -band 1) -ne 0) }
        $value = & $readAttribute 'pwdHistoryLength'
        if ($null -ne $value) { $historyLength = [int]$value }
        $value = & $readAttribute 'lockoutThreshold'
        if ($null -ne $value) { $lockoutThreshold = [int]$value }

        $readInterval = {
            param($Name)
            $raw = $entry.Properties[$Name]
            if ($null -eq $raw -or $raw.Count -eq 0) { return [long]0 }
            $item = $raw[0]
            if ($item -is [long] -or $item -is [int] -or $item -is [string]) { return [long]$item }
            try {
                $high = [long]$item.GetType().InvokeMember('HighPart', 'GetProperty', $null, $item, $null)
                $low = [long]$item.GetType().InvokeMember('LowPart', 'GetProperty', $null, $item, $null)
                if ($low -lt 0) { $low = $low + 4294967296 }
                return ($high * 4294967296) + $low
            } catch { return [long]0 }
        }
        $maxAgeTicks = & $readInterval 'maxPwdAge'
        $minAgeTicks = & $readInterval 'minPwdAge'
        $lockoutDurationTicks = & $readInterval 'lockoutDuration'
        if ($maxAgeTicks -ne 0 -and $maxAgeTicks -ne -9223372036854775808) { $maxAgeDays = [int][Math]::Round([Math]::Abs($maxAgeTicks) / 864000000000) }
        if ($minAgeTicks -ne 0) { $minAgeDays = [int][Math]::Round([Math]::Abs($minAgeTicks) / 864000000000) }
    } finally { $entry.Dispose() }

    if ($UserDistinguishedName) {
        try {
            # msDS-ResultantPSO est un attribut construit : il n est renvoye que
            # lorsqu on lit l objet lui-meme, jamais par une recherche en sous-arbre.
            $psoDN = ''
            $psoEntry = Open-ADTEntry -DN $UserDistinguishedName -Server $domain.Server -Credential $Credential
            try {
                $values = $psoEntry.Properties['msDS-ResultantPSO']
                if ($values -and $values.Count) { $psoDN = [string]$values[0] }
            } finally { $psoEntry.Dispose() }

            if ($psoDN) {
                $settings = Open-ADTEntry -DN $psoDN -Server $domain.Server -Credential $Credential
                try {
                    $values = $settings.Properties['msDS-MinimumPasswordLength']
                    if ($values -and $values.Count) { $minLength = [int]$values[0] }
                    $values = $settings.Properties['msDS-PasswordComplexityEnabled']
                    if ($values -and $values.Count) { $complexity = [bool]$values[0] }
                    $values = $settings.Properties['msDS-PasswordHistoryLength']
                    if ($values -and $values.Count) { $historyLength = [int]$values[0] }
                    $source = 'Strategie affinee : ' + $psoDN
                } finally { $settings.Dispose() }
            }
        } catch {
            Write-Verbose ('Strategie affinee non lisible pour {0} : {1}' -f $UserDistinguishedName, $_.Exception.Message)
        }
    }

    New-Object PSObject -Property @{
        DomainName             = [string]$domain.DNSRoot
        MinimumPasswordLength  = $minLength
        ComplexityEnabled      = $complexity
        PasswordHistoryLength  = $historyLength
        MaximumPasswordAgeDays = $maxAgeDays
        MinimumPasswordAgeDays = $minAgeDays
        LockoutThreshold       = $lockoutThreshold
        LockoutDurationTicks   = $lockoutDurationTicks
        LockoutDurationMinutes = [int][Math]::Round([Math]::Abs($lockoutDurationTicks) / 600000000)
        Source                 = $source
    }
}

function Get-ADTConsoleIdentityFilter {
<#
.SYNOPSIS
    Filtre LDAP correspondant a une identite saisie dans la console.
.DESCRIPTION
    Get-ADTIdentityFilter ne connait que le SID, le DN, sAMAccountName et l UPN :
    c est suffisant pour un compte, pas pour une OU ni pour un groupe designe par
    le nom affiche. Ce filtre accepte en plus name et cn.
.EXAMPLE
    Get-ADTConsoleIdentityFilter -Identity 'GS-VPN'
#>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true, Position = 0)][string]$Identity)
    if (-not $Identity.Trim()) { throw 'Identite vide.' }
    if ($Identity -match '^S-1-') {
        $sid = New-Object System.Security.Principal.SecurityIdentifier($Identity)
        $bytes = New-Object 'System.Byte[]' $sid.BinaryLength
        $sid.GetBinaryForm($bytes, 0)
        return '(objectSid=' + (($bytes | ForEach-Object { '\{0:x2}' -f $_ }) -join '') + ')'
    }
    $value = ConvertTo-ADTLdapValue $Identity
    if ($Identity -match '^[A-Za-z]+=') { return '(distinguishedName=' + $value + ')' }
    return '(|(sAMAccountName=' + $value + ')(userPrincipalName=' + $value + ')(name=' + $value + ')(cn=' + $value + '))'
}

function Resolve-ADTConsoleObject {
<#
.SYNOPSIS
    Resout une identite en un objet de la console, avec attributs enrichis.
.PARAMETER ObjectFilter
    Restreint la resolution a une classe, pour eviter qu un groupe et un
    utilisateur homonymes ne rendent l identite ambigue.
.EXAMPLE
    Resolve-ADTConsoleObject -Identity 'jcote' -ObjectFilter '(&(objectCategory=person)(objectClass=user))'
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Identity,
        [string]$ObjectFilter = '(objectClass=*)',
        [switch]$Detail,
        [long]$LockoutDurationTicks = 0,
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential
    )
    $filter = '(&' + $ObjectFilter + (Get-ADTConsoleIdentityFilter $Identity) + ')'
    $properties = Get-ADTDirectoryAttribute -Set List
    if ($Detail) { $properties = Get-ADTDirectoryAttribute -Set Detail }
    $found = @(Search-ADTDirectoryEntry -LDAPFilter $filter -Property $properties `
            -LockoutDurationTicks $LockoutDurationTicks -Server $Server -Credential $Credential)
    if ($found.Count -eq 0) { throw ('Objet introuvable : {0}' -f $Identity) }
    if ($found.Count -gt 1) { throw ('Identite ambigue : {0} ({1} resultats). Utiliser le DN.' -f $Identity, $found.Count) }
    return $found[0]
}

function Get-ADTConsoleClassFilter {
<#
.SYNOPSIS
    Filtre LDAP d une classe manipulee par la console.
.EXAMPLE
    Get-ADTConsoleClassFilter -Type User
#>
    [CmdletBinding()]
    param([ValidateSet('Any', 'User', 'Group', 'Computer', 'OrganizationalUnit', 'Account')][string]$Type = 'Any')
    switch ($Type) {
        'User' { return '(&(objectCategory=person)(objectClass=user))' }
        'Group' { return '(objectClass=group)' }
        'Computer' { return '(objectCategory=computer)' }
        'OrganizationalUnit' { return '(objectClass=organizationalUnit)' }
        'Account' { return '(|(&(objectCategory=person)(objectClass=user))(objectCategory=computer))' }
        default { return '(objectClass=*)' }
    }
}
