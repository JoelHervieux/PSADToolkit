<#
    PSADToolkit 3.0.0-test2 - version autonome
    Generee le 2026-09-17 13:47 par Build.ps1 - NE PAS MODIFIER A LA MAIN.

    Utilisation :
        . .\PSADToolkit-Standalone.ps1     # sourcer le fichier
        Test-ADTPrerequisite               # les fonctions sont alors disponibles

    Compatible PowerShell 2.0 et superieur (Windows Server 2008 SP2 -> 2025).
    Backend LDAP / ADSI sans RSAT. Windows PowerShell 2.0 a 5.1.
#>

# Journal par defaut (equivalent de ce que fait le .psm1)
if ($env:LOCALAPPDATA) {
    $script:ADTLogPath = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'PSADToolkit\PSADToolkit.log'
} else {
    $script:ADTLogPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath 'PSADToolkit.log'
}

#==============================================================================
#  FONCTIONS INTERNES
#==============================================================================

#--- ConvertTo-ADTAsciiString.ps1 ------------------------------------------

function ConvertTo-ADTAsciiString {
<#
.SYNOPSIS
    Retire les accents et les caracteres non ASCII d une chaine.
.DESCRIPTION
    Indispensable en environnement francophone : "Joel Cote-Tremblay" doit devenir
    un SamAccountName valide sans accent ni caractere special.
    Utilise la normalisation Unicode FormD, disponible depuis .NET 2.0.
.EXAMPLE
    ConvertTo-ADTAsciiString -Text 'Jose Andre Gagne'
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) { return '' }

    $normalized = $Text.Normalize([System.Text.NormalizationForm]::FormD)
    $builder = New-Object System.Text.StringBuilder

    foreach ($char in $normalized.ToCharArray()) {
        $category = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($char)
        if ($category -ne [System.Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$builder.Append($char)
        }
    }

    $clean = $builder.ToString()
    # On ne garde que lettres, chiffres, point, tiret et souligne
    $clean = [System.Text.RegularExpressions.Regex]::Replace($clean, '[^A-Za-z0-9\.\-_]', '')
    return $clean
}


#--- ConvertTo-ADTSecurePassword.ps1 ---------------------------------------

function ConvertTo-ADTSecurePassword {
    param([Parameter(Mandatory=$true)][string]$Text)
    $secure=New-Object System.Security.SecureString
    foreach ($character in $Text.ToCharArray()) { $secure.AppendChar($character) }
    $secure.MakeReadOnly()
    return $secure
}


#--- CsvHelpers.ps1 --------------------------------------------------------

function Read-ADTFlexibleCsv {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [char]$Delimiter = ';'
    )

    Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop
    $full = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
    $parser = New-Object Microsoft.VisualBasic.FileIO.TextFieldParser($full,[Text.Encoding]::UTF8,$true)
    $result = New-Object System.Collections.ArrayList
    try {
        $parser.TextFieldType = [Microsoft.VisualBasic.FileIO.FieldType]::Delimited
        $parser.SetDelimiters(@([string]$Delimiter))
        $parser.HasFieldsEnclosedInQuotes = $true
        $header = $parser.ReadFields()
        if (-not $header -or $header.Count -lt 2) { throw 'En-tete CSV invalide : verifier le separateur.' }

        $seen = @{}
        $groupIndex = -1
        $i = 0
        foreach ($rawName in $header) {
            $name = [string]$rawName
            if ($i -eq 0) { $name = $name.TrimStart([char]0xFEFF) }
            $name = $name.Trim()
            if (-not $name -or $seen.ContainsKey($name)) { throw ('Colonne CSV vide ou dupliquee : ' + $name) }
            $header[$i] = $name
            $seen[$name] = $true
            if ($name -eq 'Groups') { $groupIndex = $i }
            $i++
        }

        while (-not $parser.EndOfData) {
            $lineNumber = $parser.LineNumber
            $cells = $parser.ReadFields()
            if (-not $cells) { continue }

            # Beaucoup de CSV administratifs utilisent ; comme separateur du fichier ET
            # dans la cellule Groups sans guillemets. On rattache alors les cellules
            # excedentaires a la colonne Groups au lieu de perdre les groupes suivants.
            if ($cells.Count -gt $header.Count) {
                if ($groupIndex -lt 0) {
                    throw ('Ligne CSV {0} : {1} cellules au lieu de {2}, sans colonne Groups pour absorber les valeurs supplementaires.' -f $lineNumber,$cells.Count,$header.Count)
                }
                $extra = $cells.Count - $header.Count
                $fixed = New-Object string[] $header.Count
                for ($j=0; $j -lt $groupIndex; $j++) { $fixed[$j] = [string]$cells[$j] }
                $groupParts = New-Object System.Collections.ArrayList
                for ($j=$groupIndex; $j -le ($groupIndex + $extra); $j++) {
                    if ([string]$cells[$j]) { [void]$groupParts.Add(([string]$cells[$j]).Trim()) }
                }
                $fixed[$groupIndex] = [string]($groupParts -join ';')
                for ($j=$groupIndex+1; $j -lt $header.Count; $j++) { $fixed[$j] = [string]$cells[$j+$extra] }
                $cells = $fixed
            }

            if ($cells.Count -lt $header.Count) {
                $fixed = New-Object string[] $header.Count
                for ($j=0; $j -lt $header.Count; $j++) {
                    if ($j -lt $cells.Count) { $fixed[$j] = [string]$cells[$j] } else { $fixed[$j] = '' }
                }
                $cells = $fixed
            }

            $obj = New-Object PSObject
            for ($j=0; $j -lt $header.Count; $j++) {
                $obj | Add-Member -MemberType NoteProperty -Name $header[$j] -Value ([string]$cells[$j])
            }
            $obj | Add-Member -MemberType NoteProperty -Name '__ADTLineNumber' -Value ([int]$lineNumber)
            [void]$result.Add($obj)
        }
    } finally {
        $parser.Close()
        $parser.Dispose()
    }
    # Ne pas utiliser la virgule unaire ici : elle transformerait toutes les lignes
    # en un seul objet Object[], et $rows[0] exposerait alors Count/Length au lieu
    # des colonnes du CSV (GivenName, Surname, etc.).
    return $result.ToArray()
}

function Get-ADTCsvRowGroups {
    param($Row,[string[]]$DefaultGroups)
    $items = New-Object System.Collections.ArrayList
    if ($DefaultGroups) {
        foreach ($g in $DefaultGroups) { if ($g -and $g.Trim()) { [void]$items.Add($g.Trim()) } }
    }
    if ($Row.PSObject.Properties['Groups'] -and $Row.Groups) {
        foreach ($g in (([string]$Row.Groups) -split ';')) { if ($g -and $g.Trim()) { [void]$items.Add($g.Trim()) } }
    }
    $seen = @{}
    $result = New-Object System.Collections.ArrayList
    foreach ($g in $items) {
        $key = ([string]$g).ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) { $seen[$key] = $true; [void]$result.Add([string]$g) }
    }
    # Laisser PowerShell enumerer les chaines; les appelants utilisent @() pour
    # obtenir un tableau plat de groupes.
    return [string[]]@($result)
}

function Get-ADTImportTargetOU {
    param($Row,[string]$DefaultOU,[bool]$CreateDepartmentOUs)
    if ($CreateDepartmentOUs) {
        if (-not $DefaultOU) { throw 'Une OU parente doit etre selectionnee pour creer les sous-OU de departement.' }
        $department = ''
        if ($Row.PSObject.Properties['Department']) { $department = ([string]$Row.Department).Trim() }
        if (-not $department) { return $DefaultOU }
        return ('OU=' + (ConvertTo-ADTRdnValue $department) + ',' + $DefaultOU)
    }
    # Lorsqu une OU est choisie dans l interface, elle doit avoir priorite sur toute
    # colonne OU eventuellement presente dans le CSV. Le comportement historique
    # reste disponible en ligne de commande si -DefaultOU n est pas fourni.
    if ($DefaultOU) { return $DefaultOU }
    if ($Row.PSObject.Properties['OU'] -and $Row.OU) { return ([string]$Row.OU).Trim() }
    return $null
}


#--- DirectoryBackend.ps1 --------------------------------------------------

# LDAP backend: Windows PowerShell 2.0+, .NET Framework, no RSAT/ADWS.
# Private adapters deliberately do not shadow Microsoft's AD cmdlets.
function ConvertTo-ADTLdapValue {
    param([AllowEmptyString()][string]$Value)
    return $Value.Replace('\','\5c').Replace('*','\2a').Replace('(','\28').Replace(')','\29').Replace([string][char]0,'\00')
}
function ConvertTo-ADTRdnValue {
    param([string]$Value)
    $s = $Value.Replace('\','\\').Replace(',','\,').Replace('+','\+').Replace('"','\"').Replace('<','\<').Replace('>','\>').Replace(';','\;').Replace('=','\=').Replace('/','\2f').Replace([string][char]0,'\00')
    if ($s.StartsWith('#')) { $s = '\' + $s }
    if ($s.StartsWith(' ')) { $s = '\20' + $s.Substring(1) }
    if ($s.EndsWith(' ')) { $s = $s.Substring(0,$s.Length-1) + '\20' }
    return $s
}
function Open-ADTEntry {
    param([string]$DN = 'RootDSE', [string]$Server, [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential)
    if ($Server -and $Server -notmatch '^[a-zA-Z0-9][a-zA-Z0-9.\-]*$') { throw 'Server doit etre le nom DNS du controleur de domaine (sans LDAP:// ni port).' }
    $path = 'LDAP://'
    if ($Server) { $path += $Server + '/' }
    $path += $DN.Replace('/','\2f')
    $entry = New-Object System.DirectoryServices.DirectoryEntry
    $entry.Path = $path
    $entry.AuthenticationType = [System.DirectoryServices.AuthenticationTypes]::Secure -bor [System.DirectoryServices.AuthenticationTypes]::Signing -bor [System.DirectoryServices.AuthenticationTypes]::Sealing
    if ($Credential) {
        $entry.Username = $Credential.UserName
        $entry.Password = $Credential.GetNetworkCredential().Password
    }
    try { $null = $entry.NativeObject; return ,$entry }
    catch { $entry.Dispose(); throw }
}
function Get-ADTNativeDomain {
    [CmdletBinding()]
    param([string]$Server,[System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential)
    $root = Open-ADTEntry -Server $Server -Credential $Credential
    try {
        $dn = [string]$root.Properties['defaultNamingContext'][0]
        $dc = [string]$root.Properties['dnsHostName'][0]
        $forestDN = [string]$root.Properties['rootDomainNamingContext'][0]
        if (-not $dn -or -not $dc) { throw 'Le serveur ne fournit pas de domaine AD DS.' }
        $domain = Open-ADTEntry -DN $dn -Server $dc -Credential $Credential
        try {
            $sid = New-Object System.Security.Principal.SecurityIdentifier($domain.Properties['objectSid'][0],0)
            New-Object PSObject -Property @{ DNSRoot = (($dn -split ',' | ForEach-Object { $_ -replace '^DC=','' }) -join '.'); DomainSID = $sid; DistinguishedName = $dn; DomainMode = [string]$root.Properties['domainFunctionality'][0]; Server = $dc; ForestRootDN = $forestDN }
        } finally { $domain.Dispose() }
    } finally { $root.Dispose() }
}
function ConvertFrom-ADTSearchResult {
    param($Result)
    $p = $Result.Properties
    foreach ($name in $p.PropertyNames) {
        if ($name -like 'memberOf;range=*') { throw 'Appartenances memberOf tronquees par le serveur. Operation interrompue pour eviter une sauvegarde incomplete.' }
    }
    $sid = $null
    if ($p['objectsid'].Count) { $sid = New-Object System.Security.Principal.SecurityIdentifier($p['objectsid'][0],0) }
    $uac = 0
    if ($p['useraccountcontrol'].Count) { $uac = [int]$p['useraccountcontrol'][0] }
    $last = $null; $passwordSetDate = $null; $created = $null
    if ($p['lastlogontimestamp'].Count -and [long]$p['lastlogontimestamp'][0] -gt 0) { $last = [DateTime]::FromFileTimeUtc([long]$p['lastlogontimestamp'][0]).ToLocalTime() }
    if ($p['pwdlastset'].Count -and [long]$p['pwdlastset'][0] -gt 0) { $passwordSetDate = [DateTime]::FromFileTimeUtc([long]$p['pwdlastset'][0]).ToLocalTime() }
    if ($p['whencreated'].Count) { $created = [datetime]$p['whencreated'][0] }
    New-Object PSObject -Property @{
        Name = [string]$p['name'][0]; SamAccountName = [string]$p['samaccountname'][0]; DistinguishedName = [string]$p['distinguishedname'][0]
        ObjectClass = [string]$p['objectclass'][$p['objectclass'].Count-1]; SID = $sid; Enabled = (($uac -band 2) -eq 0)
        PasswordNeverExpires = (($uac -band 65536) -ne 0); PasswordNotRequired = (($uac -band 32) -ne 0)
        LastLogonDate = $last; PasswordLastSet = $passwordSetDate; whenCreated = $created; MemberOf = @($p['memberof'])
        Description = [string]$p['description'][0]; Department = [string]$p['department'][0]; Title = [string]$p['title'][0]
        UserPrincipalName = [string]$p['userprincipalname'][0]; PrimaryGroupID = [string]$p['primarygroupid'][0]
    }
}
function Search-ADTDirectory {
    param([string]$LDAPFilter,[string]$SearchBase,[string]$Server,[System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential)
    if (-not $SearchBase) { $SearchBase = (Get-ADTNativeDomain -Server $Server -Credential $Credential).DistinguishedName }
    $entry = Open-ADTEntry -DN $SearchBase -Server $Server -Credential $Credential
    $search = New-Object System.DirectoryServices.DirectorySearcher($entry)
    $results = $null
    try {
        $search.Filter = $LDAPFilter; $search.PageSize = 500
        $search.ClientTimeout = New-TimeSpan -Seconds 60
        $search.ServerTimeLimit = New-TimeSpan -Seconds 60
        $search.ReferralChasing = [System.DirectoryServices.ReferralChasingOption]::None
        foreach ($p in @('name','samAccountName','distinguishedName','objectClass','objectSid','userAccountControl','lastLogonTimestamp','pwdLastSet','whenCreated','memberOf','description','department','title','userPrincipalName','primaryGroupID')) { [void]$search.PropertiesToLoad.Add($p) }
        $results = $search.FindAll()
        foreach ($r in $results) { ConvertFrom-ADTSearchResult $r }
    } finally {
        if ($results) { $results.Dispose() }
        $search.Dispose(); $entry.Dispose()
    }
}
function Get-ADTIdentityFilter {
    param([string]$Identity)
    if (-not $Identity.Trim()) { throw 'Identite vide.' }
    if ($Identity -match '^S-1-') {
        $sid = New-Object System.Security.Principal.SecurityIdentifier($Identity)
        $bytes = New-Object byte[] $sid.BinaryLength; $sid.GetBinaryForm($bytes,0)
        return '(objectSid=' + (($bytes | ForEach-Object { '\{0:x2}' -f $_ }) -join '') + ')'
    }
    $v = ConvertTo-ADTLdapValue $Identity
    if ($Identity -match '^[A-Za-z]+=') { return '(distinguishedName=' + $v + ')' }
    return '(|(sAMAccountName=' + $v + ')(userPrincipalName=' + $v + '))'
}
function Get-ADTNativeObject {
    [CmdletBinding()]
    param([string]$Identity,[string]$Server,[System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential,[string]$ObjectFilter = '(objectClass=*)')
    $found = @(Search-ADTDirectory -LDAPFilter ('(&' + $ObjectFilter + (Get-ADTIdentityFilter $Identity) + ')') -Server $Server -Credential $Credential)
    if ($found.Count -ne 1) { throw ('Identite introuvable ou ambigue : {0} ({1} resultat(s)).' -f $Identity,$found.Count) }
    return $found[0]
}
function Get-ADTNativeUser {
    [CmdletBinding()]
    param([string]$Identity,[string]$Filter,[string[]]$Properties,[string]$SearchBase,[string]$Server,[System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential)
    $type = '(&(objectCategory=person)(objectClass=user))'
    if ($Identity) { return Get-ADTNativeObject -Identity $Identity -ObjectFilter $type -Server $Server -Credential $Credential }
    if ($Filter -eq '*') { $f = $type }
    elseif ($Filter -match "^SamAccountName -eq '([A-Za-z0-9._-]+)'$") { $f = '(&' + $type + '(sAMAccountName=' + $Matches[1] + '))' }
    else { throw 'Filtre interne non pris en charge.' }
    Search-ADTDirectory -LDAPFilter $f -SearchBase $SearchBase -Server $Server -Credential $Credential
}
function Get-ADTNativeGroup {
    [CmdletBinding()]
    param([string]$Identity,[string]$Server,[System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential)

    if (-not $Identity -or -not $Identity.Trim()) { throw 'Nom de groupe vide.' }

    # SID et DN : la resolution generique reste la plus sure.
    if ($Identity -match '^S-1-' -or $Identity -match '^[A-Za-z]+=') {
        return Get-ADTNativeObject -Identity $Identity -ObjectFilter '(objectClass=group)' -Server $Server -Credential $Credential
    }

    # Pour un groupe saisi dans un CSV, accepter le sAMAccountName mais aussi
    # le Name/CN affiche dans ADUC. Beaucoup d environnements utilisent un CN
    # lisible qui ne correspond pas exactement au sAMAccountName.
    $v = ConvertTo-ADTLdapValue $Identity
    $bySam = @(Search-ADTDirectory -LDAPFilter ('(&(objectClass=group)(sAMAccountName=' + $v + '))') -Server $Server -Credential $Credential)
    if ($bySam.Count -eq 1) { return $bySam[0] }
    if ($bySam.Count -gt 1) { throw ('Groupe ambigu par sAMAccountName : {0} ({1} resultats).' -f $Identity,$bySam.Count) }

    $byName = @(Search-ADTDirectory -LDAPFilter ('(&(objectClass=group)(|(name=' + $v + ')(cn=' + $v + ')))') -Server $Server -Credential $Credential)
    if ($byName.Count -eq 1) { return $byName[0] }
    if ($byName.Count -gt 1) { throw ('Groupe ambigu par nom/CN : {0} ({1} resultats).' -f $Identity,$byName.Count) }

    throw ('Groupe introuvable : {0}' -f $Identity)
}
function Get-ADTNativeGroupMember {
    [CmdletBinding()]
    param([string]$Identity,[switch]$Recursive,[string]$Server,[System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential)
    $g = Get-ADTNativeGroup -Identity $Identity -Server $Server -Credential $Credential
    $dn = ConvertTo-ADTLdapValue $g.DistinguishedName
    $membership = '(memberOf=' + $dn + ')'
    if ($Recursive) { $membership = '(memberOf:1.2.840.113556.1.4.1941:=' + $dn + ')' }
    $groups = @($g)
    if ($Recursive) { $groups += @(Search-ADTDirectory -LDAPFilter ('(&(objectClass=group)' + $membership + ')') -Server $Server -Credential $Credential) }
    # memberOf does not contain primary-group membership; include it explicitly.
    $primary = ''
    $domainSid = (Get-ADTNativeDomain -Server $Server -Credential $Credential).DomainSID.Value
    foreach ($nested in $groups) {
        if ($nested.SID.Value.StartsWith($domainSid + '-')) { $primary += '(primaryGroupID=' + ($nested.SID.Value -split '-')[-1] + ')' }
    }
    $f = '(&(!(objectClass=group))(|' + $membership + $primary + '))'
    Search-ADTDirectory -LDAPFilter $f -Server $Server -Credential $Credential
}
function Set-ADTNativeUser {
    [CmdletBinding()]
    param([string]$Identity,[string]$Description,[string]$HomeDirectory,[string]$HomeDrive,[string]$Server,[System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential)
    $user = Get-ADTNativeUser -Identity $Identity -Server $Server -Credential $Credential
    $e = Open-ADTEntry -DN $user.DistinguishedName -Server $Server -Credential $Credential
    try {
        foreach ($key in @('Description','HomeDirectory','HomeDrive')) { if ($PSBoundParameters.ContainsKey($key)) { $e.Properties[$key].Value = $PSBoundParameters[$key] } }
        $e.CommitChanges()
    } finally { $e.Dispose() }
}
function Set-ADTEntryPassword {
    param($Entry,[System.Security.SecureString]$Password)
    $ptr = [IntPtr]::Zero
    try {
        $ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
        $null = $Entry.Invoke('SetPassword',@($plain))
    } finally {
        $plain = $null
        if ($ptr -ne [IntPtr]::Zero) { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
    }
}
function Set-ADTNativePassword {
    [CmdletBinding()]
    param([string]$Identity,[System.Security.SecureString]$NewPassword,[switch]$Reset,[string]$Server,[System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential)
    $u = Get-ADTNativeUser -Identity $Identity -Server $Server -Credential $Credential
    $e = Open-ADTEntry -DN $u.DistinguishedName -Server $Server -Credential $Credential
    try { Set-ADTEntryPassword -Entry $e -Password $NewPassword } finally { $e.Dispose() }
}
function Disable-ADTNativeAccount {
    [CmdletBinding()]
    param([string]$Identity,[string]$Server,[System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential)
    $u = Get-ADTNativeUser -Identity $Identity -Server $Server -Credential $Credential
    $e = Open-ADTEntry -DN $u.DistinguishedName -Server $Server -Credential $Credential
    try { $e.Properties['userAccountControl'].Value = ([int]$e.Properties['userAccountControl'][0] -bor 2); $e.CommitChanges() } finally { $e.Dispose() }
}
function Set-ADTNativeMembership {
    param([string]$Identity,[string[]]$Members,[bool]$Remove,[string]$Server,[System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential)
    $g = Get-ADTNativeGroup -Identity $Identity -Server $Server -Credential $Credential
    $e = Open-ADTEntry -DN $g.DistinguishedName -Server $Server -Credential $Credential
    try {
        foreach ($id in $Members) {
            $u = Get-ADTNativeUser -Identity $id -Server $Server -Credential $Credential
            $memberPath = 'LDAP://'
            if ($Server) { $memberPath += $Server + '/' }
            $memberPath += $u.DistinguishedName.Replace('/','\2f')
            $exists = [bool]$e.Invoke('IsMember',@($memberPath))
            if ($Remove -and $exists) { $null = $e.Invoke('Remove',@($memberPath)) }
            if (-not $Remove -and -not $exists) { $null = $e.Invoke('Add',@($memberPath)) }
        }
    } finally { $e.Dispose() }
}
function Add-ADTNativeGroupMember {
    [CmdletBinding()] param([string]$Identity,[string[]]$Members,[string]$Server,[System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential)
    Set-ADTNativeMembership -Identity $Identity -Members $Members -Remove $false -Server $Server -Credential $Credential
}
function Remove-ADTNativeGroupMember {
    [CmdletBinding(SupportsShouldProcess=$true)] param([string]$Identity,[string[]]$Members,[string]$Server,[System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential)
    if ($PSCmdlet.ShouldProcess($Identity,'Retirer les membres')) { Set-ADTNativeMembership -Identity $Identity -Members $Members -Remove $true -Server $Server -Credential $Credential }
}
function Move-ADTNativeObject {
    [CmdletBinding()] param([string]$Identity,[string]$TargetPath,[string]$Server,[System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential)
    $e = Open-ADTEntry -DN $Identity -Server $Server -Credential $Credential
    try {
        $target = Open-ADTEntry -DN $TargetPath -Server $Server -Credential $Credential
        try { $e.MoveTo($target); $e.CommitChanges() } finally { $target.Dispose() }
    } finally { $e.Dispose() }
}
function New-ADTNativeUser {
    [CmdletBinding()]
    param([string]$Name,[string]$GivenName,[string]$Surname,[string]$SamAccountName,[string]$UserPrincipalName,[string]$DisplayName,[string]$Path,[System.Security.SecureString]$AccountPassword,[bool]$Enabled,[bool]$ChangePasswordAtLogon,[string]$Title,[string]$Department,[string]$Company,[string]$Office,[string]$EmailAddress,[string]$Manager,[string]$Server,[System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential)
    $parent = Open-ADTEntry -DN $Path -Server $Server -Credential $Credential
    $e = $null; $committed = $false
    try {
        $e = $parent.Children.Add(('CN=' + (ConvertTo-ADTRdnValue $Name)),'user')
        $attrs = @{ givenName=$GivenName; sn=$Surname; sAMAccountName=$SamAccountName; userPrincipalName=$UserPrincipalName; displayName=$DisplayName; title=$Title; department=$Department; company=$Company; physicalDeliveryOfficeName=$Office; mail=$EmailAddress; manager=$Manager }
        foreach ($key in $attrs.Keys) { if ($attrs[$key]) { $e.Properties[$key].Value = $attrs[$key] } }
        $e.Properties['userAccountControl'].Value = 514
        $e.CommitChanges(); $committed = $true
        Set-ADTEntryPassword -Entry $e -Password $AccountPassword
        if ($ChangePasswordAtLogon) { $e.Properties['pwdLastSet'].Value = 0 }
        if ($Enabled) { $e.Properties['userAccountControl'].Value = 512 }
        $e.CommitChanges()
    } catch {
        if ($committed) {
            $failure = New-Object System.InvalidOperationException(('Compte {0} cree mais configuration interrompue; verifier son etat avant toute relance. Detail : {1}' -f $SamAccountName,$_.Exception.Message))
            $failure.Data['ADTPartialIdentity'] = $SamAccountName
            throw $failure
        }
        throw
    } finally { if ($e) { $e.Dispose() }; $parent.Dispose() }
}

function Ensure-ADTNativeOU {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)][string]$BaseDN,
        [Parameter(Mandatory=$true)][string]$Name,
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential
    )
    $cleanName = ([string]$Name).Trim()
    if (-not $cleanName) { return $BaseDN }
    $targetDN = 'OU=' + (ConvertTo-ADTRdnValue $cleanName) + ',' + $BaseDN

    $existing = $null
    try { $existing = Open-ADTEntry -DN $targetDN -Server $Server -Credential $Credential; return $targetDN }
    catch { }
    finally { if ($existing) { $existing.Dispose() } }

    $parent = Open-ADTEntry -DN $BaseDN -Server $Server -Credential $Credential
    $entry = $null
    try {
        $entry = $parent.Children.Add(('OU=' + (ConvertTo-ADTRdnValue $cleanName)),'organizationalUnit')
        $entry.CommitChanges()
        return $targetDN
    } catch {
        # Une creation concurrente peut avoir gagne la course; verifier avant d echouer.
        $check = $null
        try { $check = Open-ADTEntry -DN $targetDN -Server $Server -Credential $Credential; return $targetDN }
        catch { throw }
        finally { if ($check) { $check.Dispose() } }
    } finally {
        if ($entry) { $entry.Dispose() }
        $parent.Dispose()
    }
}


#--- New-ADTRandomPassword.ps1 ---------------------------------------------

function New-ADTRandomPassword {
<#
.SYNOPSIS
    Genere un mot de passe aleatoire conforme aux exigences de complexite d Active Directory.
.DESCRIPTION
    Utilise RNGCryptoServiceProvider (aleatoire cryptographique) plutot que Get-Random,
    qui n est pas sur pour du materiel de securite.
    Garantit au moins une majuscule, une minuscule, un chiffre et un caractere special.
    Les caracteres ambigus (O, 0, l, 1, I) sont exclus pour limiter les erreurs de saisie
    lors de la remise du mot de passe a l employe.
.PARAMETER Length
    Longueur du mot de passe. Minimum 12, defaut 16.
.EXAMPLE
    New-ADTRandomPassword -Length 20
#>
    [CmdletBinding()]
    param(
        [ValidateRange(12, 128)]
        [int]$Length = 16
    )

    $upper   = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower   = 'abcdefghijkmnopqrstuvwxyz'
    $digit   = '23456789'
    $special = '!#$%&*+-=?@'
    $all     = $upper + $lower + $digit + $special

    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    try {
        $bytes = New-Object 'System.Byte[]' 4

        $pickChar = {
            param($set)
            $rng.GetBytes($bytes)
            $value = [System.BitConverter]::ToUInt32($bytes, 0)
            $set[[int]($value % $set.Length)]
        }

        $chars = New-Object System.Collections.ArrayList
        [void]$chars.Add((& $pickChar $upper))
        [void]$chars.Add((& $pickChar $lower))
        [void]$chars.Add((& $pickChar $digit))
        [void]$chars.Add((& $pickChar $special))

        while ($chars.Count -lt $Length) {
            [void]$chars.Add((& $pickChar $all))
        }

        # Melange Fisher-Yates pour que les 4 premiers caracteres ne soient pas previsibles
        for ($i = $chars.Count - 1; $i -gt 0; $i--) {
            $rng.GetBytes($bytes)
            $j = [int]([System.BitConverter]::ToUInt32($bytes, 0) % ($i + 1))
            $tmp = $chars[$i]
            $chars[$i] = $chars[$j]
            $chars[$j] = $tmp
        }

        return (-join $chars)
    } finally {
        if ($rng -and $rng.PSObject.Methods['Dispose']) { $rng.Dispose() }
    }
}


#--- Resolve-ADTSamAccountName.ps1 -----------------------------------------

function Resolve-ADTSamAccountName {
<#
.SYNOPSIS
    Determine un SamAccountName unique et valide.
.DESCRIPTION
    Construit l identifiant a partir du prenom et du nom (premiere lettre + nom),
    retire les accents, tronque a 20 caracteres (limite AD) puis verifie l unicite
    dans le domaine en ajoutant un suffixe numerique au besoin.
#>
    [CmdletBinding()]
    param(
        [string]$GivenName,
        [string]$Surname,
        [string]$Requested,
        [int]$MaxLength = 20,
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential
    )

    if ($Requested) {
        $base = ConvertTo-ADTAsciiString -Text $Requested
    } else {
        $g = ConvertTo-ADTAsciiString -Text $GivenName
        $s = ConvertTo-ADTAsciiString -Text $Surname
        if (-not $s) { throw "Impossible de construire un SamAccountName : nom de famille manquant." }
        if ($g) { $base = ($g.Substring(0, 1) + $s) } else { $base = $s }
    }

    $base = $base.ToLower()
    if ($base.Length -gt $MaxLength) { $base = $base.Substring(0, $MaxLength) }
    if (-not $base) { throw "SamAccountName calcule vide." }

    $common = @{}
    if ($Server)     { $common['Server'] = $Server }
    if ($Credential) { $common['Credential'] = $Credential }

    $candidate = $base
    $counter   = 1

    while ($true) {
        $existing = $null
        try {
            $existing = Get-ADTNativeUser -Filter "SamAccountName -eq '$candidate'" -ErrorAction Stop @common
        } catch {
            throw ("Verification d unicite impossible : {0}" -f $_.Exception.Message)
        }

        if (-not $existing) { return $candidate }
        if ($Requested) { throw ("L identifiant impose existe deja : {0}" -f $candidate) }

        $counter++
        $suffix = [string]$counter
        $trim   = $MaxLength - $suffix.Length
        if ($base.Length -gt $trim) { $candidate = $base.Substring(0, $trim) + $suffix }
        else { $candidate = $base + $suffix }

        if ($counter -gt 99) { throw "Impossible de trouver un SamAccountName unique pour '$base'." }
    }
}


#--- Test-ADTCsvShape.ps1 --------------------------------------------------

function Test-ADTCsvShape {
    param([string]$Path,[char]$Delimiter)
    $rows = @(Read-ADTFlexibleCsv -Path $Path -Delimiter $Delimiter)
    if ($rows.Count -eq 0) { throw 'Le fichier CSV ne contient aucune ligne.' }
    return $true
}


#--- Write-ADTLog.ps1 ------------------------------------------------------

function Write-ADTLog {
<#
.SYNOPSIS
    Ecrit une entree horodatee dans le journal du module.
.DESCRIPTION
    Toute action ecrivant dans Active Directory doit laisser une trace : qui, quoi, quand.
    C est une exigence de base en audit et en conformite.
    Le journal est un fichier texte simple, lisible sur n importe quel serveur.
.PARAMETER Message
    Texte a journaliser.
.PARAMETER Level
    INFO, SUCCESS, WARN ou ERROR.
.PARAMETER Path
    Chemin du journal. Par defaut %LOCALAPPDATA%\PSADToolkit\PSADToolkit.log
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Message,

        [ValidateSet('INFO', 'SUCCESS', 'WARN', 'ERROR')]
        [string]$Level = 'INFO',

        [string]$Path
    )

    if (-not $Path) {
        if ($script:ADTLogPath) { $Path = $script:ADTLogPath }
        else { $Path = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath 'PSADToolkit.log' }
    }

    try {
        $directory = Split-Path -Parent $Path
        if ($directory -and -not (Test-Path -Path $directory)) {
            New-Item -Path $directory -ItemType Directory -Force | Out-Null
        }

        $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $line  = '{0} [{1,-7}] [{2}\{3}] {4}' -f $stamp, $Level, $env:USERDOMAIN, $env:USERNAME, $Message
        Add-Content -Path $Path -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-Warning ("Ecriture du journal impossible ({0}) : {1}" -f $Path, $_.Exception.Message)
    }

    switch ($Level) {
        'ERROR'   { Write-Warning $Message }
        'WARN'    { Write-Warning $Message }
        default   { Write-Verbose $Message }
    }
}


#==============================================================================
#  FONCTIONS PUBLIQUES
#==============================================================================

#--- Export-ADTAccessReport.ps1 --------------------------------------------

function Export-ADTAccessReport {
<#
.SYNOPSIS
    Genere un rapport HTML complet sur l etat des identites et des acces du domaine.
.DESCRIPTION
    Rassemble en un seul document les elements qu un gestionnaire TI ou un auditeur
    demande chaque trimestre :
      - resume du domaine (niveau fonctionnel, nombre de comptes)
      - membres des groupes a privileges
      - comptes inactifs et jamais utilises
      - mots de passe qui n expirent jamais
      - comptes desactives toujours presents dans l annuaire

    Le HTML est genere sans dependance externe (ConvertTo-Html natif), donc le rapport
    s ouvre sur n importe quel poste, sans Excel ni navigateur particulier.
    Concu pour etre planifie dans le Planificateur de taches Windows.
.PARAMETER Path
    Chemin du fichier HTML a produire.
.PARAMETER CsvFolder
    Si fourni, exporte aussi chaque section en CSV dans ce dossier.
.EXAMPLE
    Export-ADTAccessReport -Path C:\Rapports\AD-2026-09.html
.EXAMPLE
    Export-ADTAccessReport -Path C:\Rapports\AD.html -DaysInactive 120 -CsvFolder C:\Rapports\CSV
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [ValidateRange(1, 3650)]
        [int]$DaysInactive = 90,

        [string]$SearchBase,
        [string]$CsvFolder,
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential,
        [string]$LogPath
    )

    if ($LogPath) { $script:ADTLogPath = $LogPath }

    $prereq = Test-ADTPrerequisite -Server $Server -Credential $Credential
    if (-not $prereq.Ready) { throw ("Prerequis non satisfaits : {0}" -f $prereq.Messages) }

    $common = @{}
    if ($Server)     { $common['Server'] = $Server }
    if ($Credential) { $common['Credential'] = $Credential }

    Write-ADTLog -Level 'INFO' -Message "=== Debut de la generation du rapport d acces ==="

    $domain = Get-ADTNativeDomain -ErrorAction Stop @common
    $Server=$domain.Server; $common['Server']=$Server

    $scope = @{}
    foreach ($key in $common.Keys) { $scope[$key] = $common[$key] }
    if ($SearchBase) { $scope['SearchBase'] = $SearchBase }

    $allUsers = @(Get-ADTNativeUser -Filter * -Properties Enabled, PasswordNeverExpires, LastLogonDate -ErrorAction Stop @scope)
    $enabledCount  = @($allUsers | Where-Object { $_.Enabled }).Count
    $disabledCount = @($allUsers | Where-Object { -not $_.Enabled }).Count

    # --- Sections ---------------------------------------------------------
    $privileged = @(Get-ADTPrivilegedGroupMember -IncludeBuiltin -Server $Server -Credential $Credential |
                    Select-Object GroupName, MemberName, SamAccountName, ObjectClass, Enabled, LastLogonDate)

    $inactive = @(Get-ADTInactiveAccount -DaysInactive $DaysInactive -SearchBase $SearchBase -Server $Server -Credential $Credential |
                  Sort-Object DaysSinceLastLogon -Descending |
                  Select-Object SamAccountName, Name, Enabled, Department, LastLogonDate, DaysSinceLastLogon, Risks)

    $neverExpires = @($allUsers | Where-Object { $_.PasswordNeverExpires -and $_.Enabled } |
                      Select-Object SamAccountName, Name, Enabled, LastLogonDate)

    $disabled = @($allUsers | Where-Object { -not $_.Enabled } |
                  Select-Object SamAccountName, Name, LastLogonDate)

    # --- Resume -----------------------------------------------------------
    $privilegedUsers=@($privileged | Where-Object { $_.ObjectClass -eq 'user' } | Select-Object -ExpandProperty SamAccountName -Unique).Count
    $auditIssues=@($privileged | Where-Object { $_.ObjectClass -eq 'Erreur' -or $_.ObjectClass -eq 'foreignSecurityPrincipal' }).Count
    $summary = @()
    $summary += New-Object PSObject -Property @{ Indicateur = 'Limite des comptes (DN)'; Valeur = $SearchBase }
    $summary += New-Object PSObject -Property @{ Indicateur = 'Entrees non resolues / non auditees'; Valeur = $auditIssues }
    $summary += New-Object PSObject -Property @{ Indicateur = 'Domaine';                        Valeur = $domain.DNSRoot }
    $summary += New-Object PSObject -Property @{ Indicateur = 'Niveau fonctionnel';             Valeur = [string]$domain.DomainMode }
    $summary += New-Object PSObject -Property @{ Indicateur = 'Comptes utilisateurs (total)';   Valeur = $allUsers.Count }
    $summary += New-Object PSObject -Property @{ Indicateur = 'Comptes actifs';                 Valeur = $enabledCount }
    $summary += New-Object PSObject -Property @{ Indicateur = 'Comptes desactives';             Valeur = $disabledCount }
    $summary += New-Object PSObject -Property @{ Indicateur = ('Comptes inactifs (> {0} j)' -f $DaysInactive); Valeur = $inactive.Count }
    $summary += New-Object PSObject -Property @{ Indicateur = 'Comptes a privileges';           Valeur = $privilegedUsers }
    $summary += New-Object PSObject -Property @{ Indicateur = 'Mots de passe sans expiration';  Valeur = $neverExpires.Count }
    $summary += New-Object PSObject -Property @{ Indicateur = 'Genere le';                      Valeur = (Get-Date -Format 'yyyy-MM-dd HH:mm') }
    $summary += New-Object PSObject -Property @{ Indicateur = 'Genere par';                     Valeur = ('{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME) }

    $summary = $summary | Select-Object Indicateur, Valeur

    # --- Assemblage HTML ---------------------------------------------------
    $css = @"
<style>
body { font-family: Segoe UI, Arial, sans-serif; margin: 24px; color: #1c1c1c; background: #fafafa; }
h1 { font-size: 22px; border-bottom: 3px solid #2f5d8f; padding-bottom: 8px; }
h2 { font-size: 16px; margin-top: 32px; color: #2f5d8f; }
table { border-collapse: collapse; width: 100%; background: #fff; font-size: 12px; margin-top: 8px; }
th { background: #2f5d8f; color: #fff; text-align: left; padding: 7px 9px; }
td { border-bottom: 1px solid #e3e3e3; padding: 6px 9px; }
tr:nth-child(even) td { background: #f5f7fa; }
.note { color: #666; font-size: 11px; margin-top: 4px; }
.empty { color: #666; font-style: italic; padding: 8px 0; }
</style>
"@

    $toFragment = {
        param($data, $title, $note)
        $html = "<h2>$title</h2>"
        if ($note) { $html += "<div class='note'>$note</div>" }
        if ($data -and @($data).Count -gt 0) {
            $html += ($data | ConvertTo-Html -Fragment) -join "`n"
        } else {
            $html += "<div class='empty'>Aucun element.</div>"
        }
        return $html
    }

    $body  = "<h1>Rapport d acces Active Directory - $($domain.DNSRoot)</h1>"
    $body += & $toFragment $summary     'Resume' ''
    $body += & $toFragment $privileged  'Comptes a privileges' 'Domaine selectionne uniquement (pas toute la foret). Groupes resolus par SID, membres imbriques et groupes principaux. NON AUDITE / foreignSecurityPrincipal indiquent une couverture incomplete.'
    $body += & $toFragment $inactive    ("Comptes inactifs (plus de $DaysInactive jours)") 'Base sur lastLogonTimestamp : precision de 9 a 14 jours.'
    $body += & $toFragment $neverExpires 'Comptes actifs dont le mot de passe n expire jamais' ''
    $body += & $toFragment $disabled    'Comptes desactives encore presents dans l annuaire' ''

    $html = ConvertTo-Html -Head $css -Body $body -Title 'Rapport d acces Active Directory'

    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path -Path $directory)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }

    $html | Out-File -FilePath $Path -Encoding UTF8 -Force -ErrorAction Stop

    # --- Exports CSV optionnels --------------------------------------------
    if ($CsvFolder) {
        if (-not (Test-Path -Path $CsvFolder)) { New-Item -Path $CsvFolder -ItemType Directory -Force | Out-Null }
        $privileged   | Export-Csv -Path (Join-Path $CsvFolder 'comptes-privileges.csv')   -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
        $inactive     | Export-Csv -Path (Join-Path $CsvFolder 'comptes-inactifs.csv')     -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
        $neverExpires | Export-Csv -Path (Join-Path $CsvFolder 'mdp-sans-expiration.csv')  -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
        $disabled     | Export-Csv -Path (Join-Path $CsvFolder 'comptes-desactives.csv')   -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
    }

    Write-ADTLog -Level 'SUCCESS' -Message ("Rapport genere : {0}" -f $Path)

    $result = New-Object PSObject -Property @{
        ReportPath        = $Path
        Domain            = $domain.DNSRoot
        TotalUsers        = $allUsers.Count
        EnabledUsers      = $enabledCount
        DisabledUsers     = $disabledCount
        InactiveUsers     = $inactive.Count
        PrivilegedEntries = $privileged.Count
        NeverExpires      = $neverExpires.Count
    }

    return ($result | Select-Object ReportPath, Domain, TotalUsers, EnabledUsers, DisabledUsers, InactiveUsers, PrivilegedEntries, NeverExpires)
}


#--- Get-ADTInactiveAccount.ps1 --------------------------------------------

function Get-ADTInactiveAccount {
<#
.SYNOPSIS
    Recherche les comptes inactifs, jamais utilises ou a risque.
.DESCRIPTION
    Les comptes dormants sont l un des vecteurs d attaque les plus exploites :
    personne ne surveille un compte que personne n utilise.

    Signale egalement, car c est ce qu un auditeur regarde en premier :
      - les comptes n ayant jamais ouvert de session
      - les mots de passe qui n expirent jamais (PasswordNeverExpires)
      - les comptes dont le mot de passe n est pas requis (PasswordNotRequired)

    Note sur LastLogonDate : il s agit de l attribut repliqu2 lastLogonTimestamp,
    dont la precision est de 9 a 14 jours par defaut. C est suffisant pour un seuil
    de 90 jours, pas pour du temps reel.
.PARAMETER DaysInactive
    Seuil d inactivite en jours. Defaut 90.
.PARAMETER SearchBase
    Limiter la recherche a une OU. Fortement recommande sur un gros domaine.
.PARAMETER IncludeDisabled
    Inclure les comptes deja desactives.
.EXAMPLE
    Get-ADTInactiveAccount -DaysInactive 90 | Format-Table -AutoSize
.EXAMPLE
    Get-ADTInactiveAccount -DaysInactive 180 -SearchBase 'OU=Employes,DC=contoso,DC=local' |
        Export-Csv .\comptes-inactifs.csv -NoTypeInformation -Encoding UTF8
#>
    [CmdletBinding()]
    param(
        [ValidateRange(1, 3650)]
        [int]$DaysInactive = 90,

        [string]$SearchBase,
        [switch]$IncludeDisabled,
        [switch]$ExcludeNeverLoggedOn,
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential
    )

    $prereq = Test-ADTPrerequisite -Server $Server -Credential $Credential
    if (-not $prereq.Ready) { throw ("Prerequis non satisfaits : {0}" -f $prereq.Messages) }

    $common = @{}
    if ($Server)     { $common['Server'] = $Server }
    if ($Credential) { $common['Credential'] = $Credential }
    if ($SearchBase) { $common['SearchBase'] = $SearchBase }

    $threshold = (Get-Date).AddDays(-1 * $DaysInactive)
    $properties = @('LastLogonDate', 'PasswordLastSet', 'PasswordNeverExpires', 'PasswordNotRequired',
                    'whenCreated', 'Enabled', 'Description', 'Department', 'Title', 'DistinguishedName')

    $users = Get-ADTNativeUser -Filter * -Properties $properties -ErrorAction Stop @common

    foreach ($user in $users) {

        if (-not $IncludeDisabled -and -not $user.Enabled) { continue }

        $lastLogon    = $user.LastLogonDate
        $neverLoggedOn = $false
        $daysSince    = $null

        if ($lastLogon) {
            $daysSince = [int]((Get-Date) - $lastLogon).TotalDays
        } else {
            $neverLoggedOn = $true
            if ($user.whenCreated) { $daysSince = [int]((Get-Date) - $user.whenCreated).TotalDays }
        }

        if ($neverLoggedOn -and $ExcludeNeverLoggedOn) { continue }

        $isInactive = $false
        if ($neverLoggedOn) { $isInactive = ($user.whenCreated -and $user.whenCreated -lt $threshold) }
        elseif ($lastLogon -lt $threshold) { $isInactive = $true }

        if (-not $isInactive) { continue }

        $risks = New-Object System.Collections.ArrayList
        if ($neverLoggedOn)             { [void]$risks.Add('Jamais connecte') }
        if ($user.PasswordNeverExpires) { [void]$risks.Add('Mot de passe sans expiration') }
        if ($user.PasswordNotRequired)  { [void]$risks.Add('Mot de passe non requis') }
        if ($user.Enabled)              { [void]$risks.Add('Encore actif') }

        $out = New-Object PSObject -Property @{
            SamAccountName       = $user.SamAccountName
            Name                 = $user.Name
            Enabled              = $user.Enabled
            Department           = $user.Department
            Title                = $user.Title
            LastLogonDate        = $lastLogon
            DaysSinceLastLogon   = $daysSince
            PasswordLastSet      = $user.PasswordLastSet
            PasswordNeverExpires = $user.PasswordNeverExpires
            Created              = $user.whenCreated
            Risks                = ($risks -join ', ')
            DistinguishedName    = $user.DistinguishedName
        }

        $out | Select-Object SamAccountName, Name, Enabled, Department, Title, LastLogonDate,
                             DaysSinceLastLogon, PasswordLastSet, PasswordNeverExpires, Created,
                             Risks, DistinguishedName
    }
}


#--- Get-ADTPrivilegedGroupMember.ps1 --------------------------------------

function Get-ADTPrivilegedGroupMember {
<#
.SYNOPSIS
    Inventorie les membres des groupes a privileges du domaine.
.DESCRIPTION
    "Qui est administrateur du domaine ?" est la premiere question posee lors d un audit
    de securite, et la reponse surprend presque toujours.

    Les groupes sont resolus par SID bien connu et non par nom. C est essentiel :
    sur un Active Directory installe en francais, "Domain Admins" s appelle
    "Admins du domaine". Une recherche par nom echouerait silencieusement.

    La recherche est recursive : un utilisateur membre d un groupe imbrique dans
    Admins du domaine est un administrateur du domaine, et il sera signale.
.PARAMETER IncludeBuiltin
    Inclure les groupes integres locaux (Administrateurs, Operateurs de compte, etc.).
.EXAMPLE
    Get-ADTPrivilegedGroupMember | Format-Table -AutoSize
.EXAMPLE
    Get-ADTPrivilegedGroupMember | Export-Csv .\audit-privileges.csv -NoTypeInformation -Encoding UTF8
#>
    [CmdletBinding()]
    param(
        [switch]$IncludeBuiltin,
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential
    )

    $prereq = Test-ADTPrerequisite -Server $Server -Credential $Credential
    if (-not $prereq.Ready) { throw ("Prerequis non satisfaits : {0}" -f $prereq.Messages) }

    $common = @{}
    if ($Server)     { $common['Server'] = $Server }
    if ($Credential) { $common['Credential'] = $Credential }

    $domain    = Get-ADTNativeDomain -ErrorAction Stop @common
    $domainSid = $domain.DomainSID.Value
    $common['Server'] = $domain.Server
    if ($domain.ForestRootDN -ne $domain.DistinguishedName) {
        Write-Warning 'Audit limite au domaine selectionne. Les groupes Schema Admins / Enterprise Admins du domaine racine ne sont pas audites ici.'
    }

    # SID relatifs au domaine
    $targets = @(
        ('{0}-512' -f $domainSid),  # Admins du domaine
        ('{0}-519' -f $domainSid),  # Administrateurs de l entreprise
        ('{0}-518' -f $domainSid),  # Administrateurs du schema
        ('{0}-520' -f $domainSid)   # Proprietaires createurs de la strategie de groupe
    )

    if ($IncludeBuiltin) {
        # SID integres, identiques sur tous les domaines
        $targets += @(
            'S-1-5-32-544',  # Administrateurs
            'S-1-5-32-548',  # Operateurs de compte
            'S-1-5-32-549',  # Operateurs de serveur
            'S-1-5-32-550',  # Operateurs d impression
            'S-1-5-32-551'   # Operateurs de sauvegarde
        )
    }

    foreach ($sid in $targets) {

        $group = $null
        try {
            $group = Get-ADTNativeGroup -Identity $sid -ErrorAction Stop @common
        } catch {
            Write-Warning ("Groupe non audite {0} : {1}" -f $sid,$_.Exception.Message)
            New-Object PSObject -Property @{ GroupName=$sid; GroupSID=$sid; MemberName='NON AUDITE'; SamAccountName=''; ObjectClass='Erreur'; Enabled=''; LastLogonDate=$null; PasswordLastSet=$null; DistinguishedName=''; Error=$_.Exception.Message }
            continue
        }

        $members = @()
        try {
            $members = @(Get-ADTNativeGroupMember -Identity $group.DistinguishedName -Recursive -ErrorAction Stop @common)
        } catch {
            Write-Warning ("Enumeration impossible pour {0} : {1}" -f $group.Name, $_.Exception.Message)
            New-Object PSObject -Property @{ GroupName=$group.Name; GroupSID=$sid; MemberName='NON AUDITE'; SamAccountName=''; ObjectClass='Erreur'; Enabled=''; LastLogonDate=$null; PasswordLastSet=$null; DistinguishedName=''; Error=$_.Exception.Message }
            continue
        }

        if ($members.Count -eq 0) {
            $empty = New-Object PSObject -Property @{
                GroupName = $group.Name; GroupSID = $sid; MemberName = '(aucun membre)'
                SamAccountName = ''; ObjectClass = ''; Enabled = ''; LastLogonDate = $null
                PasswordLastSet = $null; DistinguishedName = ''
            }
            $empty | Select-Object GroupName, GroupSID, MemberName, SamAccountName, ObjectClass, Enabled, LastLogonDate, PasswordLastSet, DistinguishedName
            continue
        }

        foreach ($member in $members) {

            $enabled = ''
            $lastLogon = $null
            $passwordSet = $null

            if ($member.objectClass -eq 'user') {
                try {
                    $detail = Get-ADTNativeUser -Identity $member.DistinguishedName -Properties LastLogonDate, PasswordLastSet, Enabled -ErrorAction Stop @common
                    $enabled     = $detail.Enabled
                    $lastLogon   = $detail.LastLogonDate
                    $passwordSet = $detail.PasswordLastSet
                } catch { $enabled='INCONNU'; Write-Warning ("Details du membre inaccessibles : {0}" -f $member.DistinguishedName) }
            }

            $out = New-Object PSObject -Property @{
                GroupName         = $group.Name
                GroupSID          = $sid
                MemberName        = $member.Name
                SamAccountName    = $member.SamAccountName
                ObjectClass       = $member.objectClass
                Enabled           = $enabled
                LastLogonDate     = $lastLogon
                PasswordLastSet   = $passwordSet
                DistinguishedName = $member.DistinguishedName
            }

            $out | Select-Object GroupName, GroupSID, MemberName, SamAccountName, ObjectClass, Enabled, LastLogonDate, PasswordLastSet, DistinguishedName
        }
    }
}


#--- Import-ADTUserFromCsv.ps1 ---------------------------------------------

function Import-ADTUserFromCsv {
<#
.SYNOPSIS
    Cree en masse des comptes Active Directory a partir d un fichier CSV.
.DESCRIPTION
    Compatible Windows PowerShell 2.0+ et Windows Server 2008 SP2 a 2025.
    Accepte les groupes multiples dans la colonne Groups, meme si les points-virgules
    n ont pas ete entoures de guillemets dans un CSV separe par des points-virgules.
    Lorsque -DefaultOU est fourni, il a priorite sur une eventuelle colonne OU du CSV.
    Avec -CreateDepartmentOUs, -DefaultOU devient l OU parente et une sous-OU est
    creee automatiquement pour chaque valeur Department.
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateScript({ Test-Path -Path $_ -PathType Leaf })]
        [string]$Path,
        [char]$Delimiter = ';',
        [string]$DefaultOU,
        [string[]]$DefaultGroups,
        [switch]$CreateDepartmentOUs,
        [string]$PasswordReportPath,
        [string]$HomeDirectoryRoot,
        [string]$HomeDrive,
        [ValidateRange(12, 128)][int]$PasswordLength = 16,
        [switch]$SkipExisting,
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential,
        [string]$LogPath
    )

    if ($LogPath) { $script:ADTLogPath = $LogPath }
    Write-ADTLog -Level 'INFO' -Message ("=== Debut import CSV : {0} ===" -f $Path)

    [void](Test-ADTCsvShape -Path $Path -Delimiter $Delimiter)
    $rows = @(Read-ADTFlexibleCsv -Path $Path -Delimiter $Delimiter)
    if ($rows.Count -eq 0) { throw 'Le fichier CSV ne contient aucune ligne.' }

    $columns = @($rows[0].PSObject.Properties | ForEach-Object { $_.Name })
    foreach ($column in @('GivenName','Surname')) {
        $found = $false
        foreach ($existing in $columns) { if ($existing -eq $column) { $found = $true } }
        if (-not $found) { throw ("Colonne obligatoire absente : {0}. Colonnes trouvees : {1}" -f $column,($columns -join ', ')) }
    }

    $hasOUColumn = $false
    foreach ($existing in $columns) { if ($existing -eq 'OU') { $hasOUColumn = $true } }
    if ($CreateDepartmentOUs -and -not $DefaultOU) { throw 'Selectionner une OU parente avant de demander la creation automatique des sous-OU.' }
    if (-not $CreateDepartmentOUs -and -not $hasOUColumn -and -not $DefaultOU) { throw "Aucune colonne 'OU' dans le CSV et aucun -DefaultOU fourni." }

    $common = @{}
    if ($Credential) { $common['Credential'] = $Credential }
    $prereq = Test-ADTPrerequisite -Server $Server -Credential $Credential
    if (-not $prereq.Ready) { throw $prereq.Messages }
    $Server = $prereq.Server
    $common['Server'] = $Server

    if ($CreateDepartmentOUs) {
        try { Get-ADTNativeObject -Identity $DefaultOU @common -ErrorAction Stop | Out-Null }
        catch { throw ("OU parente inaccessible : {0}" -f $DefaultOU) }
    }

    $seen = @{}
    $validation = New-Object System.Collections.ArrayList
    $groupWarnings = @{}
    foreach ($row in $rows) {
        $line = [int]$row.__ADTLineNumber
        if (-not ([string]$row.GivenName).Trim() -or -not ([string]$row.Surname).Trim()) { [void]$validation.Add("Ligne $line : prenom/nom manquant.") }

        $targetOU = Get-ADTImportTargetOU -Row $row -DefaultOU $DefaultOU -CreateDepartmentOUs ([bool]$CreateDepartmentOUs)
        if (-not $targetOU) { [void]$validation.Add("Ligne $line : OU manquante.") }
        elseif (-not $CreateDepartmentOUs) {
            try { Get-ADTNativeObject -Identity $targetOU @common -ErrorAction Stop | Out-Null }
            catch { [void]$validation.Add("Ligne $line : OU inaccessible : $targetOU") }
        }

        $rowGroups = @(Get-ADTCsvRowGroups -Row $row -DefaultGroups $DefaultGroups)
        $lineGroupWarnings = New-Object System.Collections.ArrayList
        foreach ($g in $rowGroups) {
            try { Get-ADTNativeGroup -Identity $g @common -ErrorAction Stop | Out-Null }
            catch {
                $detail = $_.Exception.Message
                [void]$lineGroupWarnings.Add(('Groupe non applique {0} : {1}' -f $g,$detail))
                Write-Warning ("Ligne $line : groupe non resolu : $g - $detail")
            }
        }
        if ($lineGroupWarnings.Count) { $groupWarnings[$line] = ($lineGroupWarnings -join ' | ') }

        if ($row.PSObject.Properties['SamAccountName'] -and $row.SamAccountName) {
            $normalized = (ConvertTo-ADTAsciiString $row.SamAccountName).ToLowerInvariant()
            if ($normalized.Length -gt 20) { $normalized = $normalized.Substring(0,20) }
            if (-not $normalized) { [void]$validation.Add("Ligne $line : identifiant invalide.") }
            elseif ($seen.ContainsKey($normalized)) { [void]$validation.Add("Ligne $line : identifiant duplique apres normalisation : $normalized") }
            else { $seen[$normalized] = $true }
        }
    }
    if ($validation.Count) { throw ($validation -join "`n") }

    if (-not $PSCmdlet.ShouldProcess($Path,('Importer {0} ligne(s) dans {1}' -f $rows.Count,$Server))) {
        if (-not $WhatIfPreference) { return }
    }

    $results = New-Object System.Collections.ArrayList
    $createdOUs = @{}

    foreach ($row in $rows) {
        $lineNumber = [int]$row.__ADTLineNumber
        if (-not $row.GivenName -and -not $row.Surname) { continue }

        $targetOU = Get-ADTImportTargetOU -Row $row -DefaultOU $DefaultOU -CreateDepartmentOUs ([bool]$CreateDepartmentOUs)
        $groupList = @(Get-ADTCsvRowGroups -Row $row -DefaultGroups $DefaultGroups)

        if ($WhatIfPreference) {
            $previewError = ''
            if ($groupWarnings.ContainsKey($lineNumber)) { $previewError = [string]$groupWarnings[$lineNumber] }
            [void]$results.Add((New-Object PSObject -Property @{
                SamAccountName = [string]$row.SamAccountName
                DisplayName = (([string]$row.GivenName + ' ' + [string]$row.Surname).Trim())
                Status = 'Simulation'
                Password = ''
                DistinguishedName = $targetOU
                Groups = ($groupList -join ';')
                HomeDirectory = ''
                Error = $previewError
            } | Select-Object SamAccountName,DisplayName,Status,Password,DistinguishedName,Groups,HomeDirectory,Error))
            continue
        }

        if ($CreateDepartmentOUs) {
            $department = ''
            if ($row.PSObject.Properties['Department']) { $department = ([string]$row.Department).Trim() }
            if ($department) {
                $deptKey = $department.ToLowerInvariant()
                if (-not $createdOUs.ContainsKey($deptKey)) {
                    $targetOU = Ensure-ADTNativeOU -BaseDN $DefaultOU -Name $department -Server $Server -Credential $Credential
                    $createdOUs[$deptKey] = $targetOU
                    Write-ADTLog -Level 'INFO' -Message ("OU departement prete : {0}" -f $targetOU)
                } else { $targetOU = $createdOUs[$deptKey] }
            }
        }

        $params = @{
            GivenName = $row.GivenName
            Surname = $row.Surname
            Path = $targetOU
            PasswordLength = $PasswordLength
            ErrorAction = 'Stop'
            Confirm = $false
        }
        foreach ($optional in @('SamAccountName','DisplayName','Title','Department','Company','Office','EmailAddress','Manager')) {
            if ($row.PSObject.Properties[$optional] -and $row.$optional) { $params[$optional] = $row.$optional }
        }
        if ($groupList.Count -gt 0) { $params['Groups'] = [string[]]$groupList }
        if ($HomeDirectoryRoot) { $params['HomeDirectoryRoot'] = $HomeDirectoryRoot }
        if ($HomeDrive) { $params['HomeDrive'] = $HomeDrive }
        if ($Server) { $params['Server'] = $Server }
        if ($Credential) { $params['Credential'] = $Credential }

        if ($SkipExisting -and $row.PSObject.Properties['SamAccountName'] -and $row.SamAccountName) {
            $normalized = (ConvertTo-ADTAsciiString $row.SamAccountName).ToLowerInvariant()
            if ($normalized.Length -gt 20) { $normalized = $normalized.Substring(0,20) }
            $exists = Get-ADTNativeUser -Filter "SamAccountName -eq '$normalized'" -ErrorAction Stop @common
            if ($exists) {
                [void]$results.Add((New-Object PSObject -Property @{
                    SamAccountName=$row.SamAccountName; DisplayName=''; Status='Ignore'; Password=''; DistinguishedName=$targetOU; Groups=($groupList -join ';'); HomeDirectory=''; Error='Compte deja existant'
                } | Select-Object SamAccountName,DisplayName,Status,Password,DistinguishedName,Groups,HomeDirectory,Error))
                continue
            }
        }

        $result = New-ADTUser @params
        if ($result) { [void]$results.Add($result) }
    }

    if ($PasswordReportPath -and -not $WhatIfPreference) {
        try {
            $results | Where-Object { $_.Status -eq 'Cree' -or $_.Status -eq 'Partiel' } | Select-Object SamAccountName,DisplayName,Password | Export-Csv -Path $PasswordReportPath -NoTypeInformation -Delimiter $Delimiter -Encoding UTF8 -ErrorAction Stop
            Write-Warning ("Mots de passe exportes en clair vers {0}. Supprimer ce fichier des qu il a servi." -f $PasswordReportPath)
        } catch { Write-ADTLog -Level 'ERROR' -Message ("Export des mots de passe echoue : " + $_.Exception.Message) }
    }

    $created = @($results | Where-Object { $_.Status -eq 'Cree' }).Count
    $failed = @($results | Where-Object { $_.Status -eq 'Echec' }).Count
    $skipped = @($results | Where-Object { $_.Status -eq 'Ignore' }).Count
    Write-ADTLog -Level 'INFO' -Message ("=== Fin import : {0} crees, {1} echecs, {2} ignores ===" -f $created,$failed,$skipped)
    return $results
}


#--- New-ADTUser.ps1 -------------------------------------------------------

function New-ADTUser {
<#
.SYNOPSIS
    Cree un compte Active Directory complet (arrivee d un employe).
.DESCRIPTION
    Automatise le processus d arrivee ("onboarding") de bout en bout :
      1. calcul d un SamAccountName unique, sans accent
      2. generation d un mot de passe aleatoire cryptographiquement sur
      3. creation du compte dans la bonne unite d organisation
      4. ajout aux groupes de securite
      5. creation du dossier personnel avec les permissions NTFS
      6. journalisation de chaque etape

    Supporte -WhatIf et -Confirm : rien n est ecrit dans AD tant que l on n a pas valide.
.PARAMETER GivenName
    Prenom de l employe.
.PARAMETER Surname
    Nom de famille.
.PARAMETER Path
    DN de l unite d organisation cible. Ex : 'OU=Employes,DC=contoso,DC=local'
.PARAMETER SamAccountName
    Identifiant impose. Si omis, il est calcule (premiere lettre du prenom + nom).
.PARAMETER Groups
    Groupes de securite auxquels ajouter l employe.
.PARAMETER HomeDirectoryRoot
    Racine UNC des dossiers personnels. Ex : '\\FS01\Users$'
.PARAMETER HomeDrive
    Lettre du lecteur reseau. Ex : 'H:'
.PARAMETER Password
    Mot de passe impose (SecureString). Si omis, il est genere.
.PARAMETER NoChangePasswordAtLogon
    Ne pas forcer le changement de mot de passe a la premiere ouverture de session.
.EXAMPLE
    New-ADTUser -GivenName 'Joel' -Surname 'Cote' -Path 'OU=Employes,DC=contoso,DC=local' -Groups 'GS-VPN','GS-Comptabilite' -WhatIf

.EXAMPLE
    New-ADTUser -GivenName 'Marie' -Surname 'Tremblay' -Path 'OU=Employes,DC=contoso,DC=local' `
                -Title 'Technicienne' -Department 'TI' -HomeDirectoryRoot '\\FS01\Users$' -HomeDrive 'H:'
.NOTES
    Le mot de passe en clair est retourne dans l objet resultat afin de pouvoir etre
    transmis a l employe. Il ne doit jamais etre conserve en clair sur disque.
#>
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams','',Justification='UserPrincipalNameSuffix and PasswordLength are metadata; Password is SecureString and authentication uses PSCredential.') ]
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()][string]$GivenName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()][string]$Surname,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [string]$SamAccountName,
        [string]$DisplayName,
        [string]$Title,
        [string]$Department,
        [string]$Company,
        [string]$Office,
        [string]$EmailAddress,
        [string]$Manager,
        [string]$UserPrincipalNameSuffix,
        [string[]]$Groups,
        [string]$HomeDirectoryRoot,
        [ValidatePattern('^[A-Za-z]:$')][string]$HomeDrive,
        [System.Security.SecureString]$Password,
        [ValidateRange(12, 128)]
        [int]$PasswordLength = 16,
        [switch]$NoChangePasswordAtLogon,
        [switch]$Disabled,
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential,
        [string]$LogPath
    )

    begin {
        if ($LogPath) { $script:ADTLogPath = $LogPath }
        $prereq = Test-ADTPrerequisite -Server $Server -Credential $Credential
        if ($prereq.Ready) { $Server = $prereq.Server }
        if (-not $prereq.Ready) {
            throw ("Prerequis non satisfaits : {0}" -f $prereq.Messages)
        }
    }

    process {
        $common = @{}
        if ($Server)     { $common['Server'] = $Server }
        if ($Credential) { $common['Credential'] = $Credential }

        $accountCreated = $false
        $status     = 'Echec'
        $errorText  = ''
        $issues = New-Object System.Collections.ArrayList
        $addedGroups = New-Object System.Collections.ArrayList
        $resolvedGroups = New-Object System.Collections.ArrayList
        $plainPassword = ''
        $homePath   = ''
        $sam        = ''
        $dn         = ''

        try {
            # --- 1. Identifiant unique -------------------------------------
            $sam = Resolve-ADTSamAccountName -GivenName $GivenName -Surname $Surname `
                                             -Requested $SamAccountName -Server $Server -Credential $Credential

            # --- 2. UPN ----------------------------------------------------
            if ($UserPrincipalNameSuffix) {
                $upnSuffix = $UserPrincipalNameSuffix.TrimStart('@')
            } else {
                $upnSuffix = (Get-ADTNativeDomain -ErrorAction Stop @common).DNSRoot
            }
            $upn = '{0}@{1}' -f $sam, $upnSuffix

            # --- 3. Verification de l OU -----------------------------------
            $ouExists = $true
            try { Get-ADTNativeObject -Identity $Path -ErrorAction Stop @common | Out-Null }
            catch { $ouExists = $false }
            if (-not $ouExists) { throw ("Unite d organisation introuvable : {0}" -f $Path) }

            foreach ($g in $Groups) {
                if (-not $g) { continue }
                try {
                    $resolvedGroup = Get-ADTNativeGroup -Identity $g -ErrorAction Stop @common
                    [void]$resolvedGroups.Add((New-Object PSObject -Property @{ Name = [string]$g; Identity = [string]$resolvedGroup.DistinguishedName }))
                } catch {
                    [void]$issues.Add(('Groupe non applique {0} : {1}' -f $g,$_.Exception.Message))
                    Write-ADTLog -Level 'WARN' -Message ("Groupe non resolu avant creation de $sam : $g - " + $_.Exception.Message)
                }
            }

            # --- 4. Mot de passe -------------------------------------------
            if ($Password) {
                $securePassword = $Password
                $plainPassword  = '(fourni par l appelant)'
            } else {
                $plainPassword  = New-ADTRandomPassword -Length $PasswordLength
                $securePassword = ConvertTo-ADTSecurePassword -Text $plainPassword
            }

            if (-not $DisplayName) { $DisplayName = '{0} {1}' -f $GivenName, $Surname }

            $newUserParams = @{
                Name                  = $sam
                GivenName             = $GivenName
                Surname               = $Surname
                SamAccountName        = $sam
                UserPrincipalName     = $upn
                DisplayName           = $DisplayName
                Path                  = $Path
                AccountPassword       = $securePassword
                Enabled               = (-not $Disabled)
                ChangePasswordAtLogon = (-not $NoChangePasswordAtLogon)
                ErrorAction           = 'Stop'
            }

            if ($Title)        { $newUserParams['Title'] = $Title }
            if ($Department)   { $newUserParams['Department'] = $Department }
            if ($Company)      { $newUserParams['Company'] = $Company }
            if ($Office)       { $newUserParams['Office'] = $Office }
            if ($EmailAddress) { $newUserParams['EmailAddress'] = $EmailAddress }

            if ($Manager) {
                try {
                    $mgr = Get-ADTNativeUser -Identity $Manager -ErrorAction Stop @common
                    $newUserParams['Manager'] = $mgr.DistinguishedName
                } catch { throw ("Gestionnaire introuvable : {0}" -f $Manager) }
            }

            foreach ($key in $common.Keys) { $newUserParams[$key] = $common[$key] }

            # --- 5. Creation -----------------------------------------------
            if ($PSCmdlet.ShouldProcess($sam, "Creer le compte Active Directory")) {
                New-ADTNativeUser @newUserParams
                $accountCreated = $true
                Write-ADTLog -Level 'SUCCESS' -Message ("Compte cree : {0} ({1}) dans {2}" -f $sam, $DisplayName, $Path)

                $created = Get-ADTNativeUser -Identity $sam -ErrorAction Stop @common
                $dn = $created.DistinguishedName

                # --- 6. Groupes ---------------------------------------------
                if ($resolvedGroups.Count -gt 0) {
                    foreach ($groupInfo in $resolvedGroups) {
                        try {
                            Add-ADTNativeGroupMember -Identity $groupInfo.Identity -Members $sam -ErrorAction Stop @common
                            [void]$addedGroups.Add($groupInfo.Name)
                            Write-ADTLog -Level 'INFO' -Message ("{0} ajoute au groupe {1}" -f $sam, $groupInfo.Name)
                        } catch {
                            [void]$issues.Add(('Ajout groupe {0} : {1}' -f $groupInfo.Name,$_.Exception.Message))
                            Write-ADTLog -Level 'WARN' -Message ("Ajout au groupe {0} echoue pour {1} : {2}" -f $groupInfo.Name, $sam, $_.Exception.Message)
                        }
                    }
                }

                # --- 7. Dossier personnel ------------------------------------
                if ($HomeDirectoryRoot) {
                    $homePath = Join-Path -Path $HomeDirectoryRoot -ChildPath $sam
                    try {
                        if (-not (Test-Path -Path $homePath)) {
                            New-Item -Path $homePath -ItemType Directory -Force -ErrorAction Stop | Out-Null
                        }

                        $acl = Get-Acl -Path $homePath -ErrorAction Stop
                        $account = $created.SID
                        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                            $account,
                            [System.Security.AccessControl.FileSystemRights]::Modify,
                            ([System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit),
                            [System.Security.AccessControl.PropagationFlags]::None,
                            [System.Security.AccessControl.AccessControlType]::Allow)
                        $acl.AddAccessRule($rule)
                        Set-Acl -Path $homePath -AclObject $acl -ErrorAction Stop

                        $homeParams = @{ Identity = $sam; HomeDirectory = $homePath; ErrorAction = 'Stop' }
                        if ($HomeDrive) { $homeParams['HomeDrive'] = $HomeDrive }
                        foreach ($key in $common.Keys) { $homeParams[$key] = $common[$key] }
                        Set-ADTNativeUser @homeParams

                        Write-ADTLog -Level 'INFO' -Message ("Dossier personnel cree : {0}" -f $homePath)
                    } catch {
                        [void]$issues.Add($_.Exception.Message)
                        Write-ADTLog -Level 'WARN' -Message ("Dossier personnel non configure pour {0} : {1}" -f $sam, $_.Exception.Message)
                    }
                }

                $status = 'Cree'
                if ($issues.Count) { $status = 'Partiel'; $errorText = $issues -join ' | ' }
            } else {
                $plainPassword = ''
                $status = 'Annule'
                if ($WhatIfPreference) { $status = 'Simulation' }
            }
        } catch {
            $errorText = $_.Exception.Message
            if ($_.Exception.Data['ADTPartialIdentity'] -or $accountCreated) { $status = 'Partiel' }
            Write-ADTLog -Level 'ERROR' -Message ("Creation echouee pour {0} {1} : {2}" -f $GivenName, $Surname, $errorText)
        }

        $output = New-Object PSObject -Property @{
            SamAccountName    = $sam
            DisplayName       = $DisplayName
            Status            = $status
            Password          = $plainPassword
            DistinguishedName = $dn
            Groups            = ($addedGroups -join ';')
            HomeDirectory     = $homePath
            Error             = $errorText
        }

        return ($output | Select-Object SamAccountName, DisplayName, Status, Password, DistinguishedName, Groups, HomeDirectory, Error)
    }
}


#--- Set-ADTUserGroupMembership.ps1 ----------------------------------------

function Set-ADTUserGroupMembership {
<#
.SYNOPSIS
    Ajoute ou retire un ou plusieurs utilisateurs de groupes de securite, en masse.
.DESCRIPTION
    Gestion des acces par lot, avec journalisation et prise en charge de -WhatIf.
    Accepte les identites par le pipeline, ce qui permet de chainer avec Get-ADTNativeUser :

        Get-ADTNativeUser -Filter "Department -eq 'TI'" | Set-ADTUserGroupMembership -AddGroup 'GS-VPN'
.PARAMETER Identity
    Un ou plusieurs utilisateurs (SamAccountName, DN ou objet AD).
.PARAMETER AddGroup
    Groupes auxquels ajouter les utilisateurs.
.PARAMETER RemoveGroup
    Groupes desquels retirer les utilisateurs.
.EXAMPLE
    Set-ADTUserGroupMembership -Identity 'jcote','mtremblay' -AddGroup 'GS-VPN' -RemoveGroup 'GS-Stagiaires'
.EXAMPLE
    Get-Content .\liste.txt | Set-ADTUserGroupMembership -AddGroup 'GS-Comptabilite' -WhatIf
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('SamAccountName', 'User')]
        [string[]]$Identity,

        [string[]]$AddGroup,
        [string[]]$RemoveGroup,
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential,
        [string]$LogPath
    )

    begin {
        if ($LogPath) { $script:ADTLogPath = $LogPath }
        if (-not $AddGroup -and -not $RemoveGroup) {
            throw "Preciser au moins -AddGroup ou -RemoveGroup."
        }
        $pre = Test-ADTPrerequisite -Server $Server -Credential $Credential
        if (-not $pre.Ready) { throw $pre.Messages }
        $Server = $pre.Server
        foreach ($g in $AddGroup) { if ($RemoveGroup -contains $g) { throw ('Groupe present dans ajout ET retrait : ' + $g) } }
        $common = @{}
        if ($Server)     { $common['Server'] = $Server }
        if ($Credential) { $common['Credential'] = $Credential }
    }

    process {
        foreach ($user in $Identity) {
            if (-not $user) { continue }

            $adUser = $null
            try {
                $adUser = Get-ADTNativeUser -Identity $user -ErrorAction Stop @common
            } catch {
                Write-ADTLog -Level 'ERROR' -Message ("Utilisateur introuvable : {0}" -f $user)
                $failed = New-Object PSObject -Property @{
                    SamAccountName = $user; Action = 'Recherche'; Group = ''
                    Status = 'Echec'; Error = 'Utilisateur introuvable'
                }
                $failed | Select-Object SamAccountName, Action, Group, Status, Error
                continue
            }

            foreach ($group in $AddGroup) {
                if (-not $group) { continue }
                $status = 'Echec'; $errorText = ''
                try {
                    if ($PSCmdlet.ShouldProcess($adUser.SamAccountName, ("Ajouter au groupe {0}" -f $group))) {
                        Add-ADTNativeGroupMember -Identity $group -Members $adUser.DistinguishedName -ErrorAction Stop @common
                        $status = 'Ajoute'
                        Write-ADTLog -Level 'SUCCESS' -Message ("{0} ajoute a {1}" -f $adUser.SamAccountName, $group)
                    } else { $status = 'Simulation' }
                } catch {
                    $errorText = $_.Exception.Message
                    Write-ADTLog -Level 'ERROR' -Message ("Ajout de {0} a {1} echoue : {2}" -f $adUser.SamAccountName, $group, $errorText)
                }
                $out = New-Object PSObject -Property @{
                    SamAccountName = $adUser.SamAccountName; Action = 'Ajout'; Group = $group
                    Status = $status; Error = $errorText
                }
                $out | Select-Object SamAccountName, Action, Group, Status, Error
            }

            foreach ($group in $RemoveGroup) {
                if (-not $group) { continue }
                $status = 'Echec'; $errorText = ''
                try {
                    if ($PSCmdlet.ShouldProcess($adUser.SamAccountName, ("Retirer du groupe {0}" -f $group))) {
                        Remove-ADTNativeGroupMember -Identity $group -Members $adUser.DistinguishedName -Confirm:$false -ErrorAction Stop @common
                        $status = 'Retire'
                        Write-ADTLog -Level 'SUCCESS' -Message ("{0} retire de {1}" -f $adUser.SamAccountName, $group)
                    } else { $status = 'Simulation' }
                } catch {
                    $errorText = $_.Exception.Message
                    Write-ADTLog -Level 'ERROR' -Message ("Retrait de {0} de {1} echoue : {2}" -f $adUser.SamAccountName, $group, $errorText)
                }
                $out = New-Object PSObject -Property @{
                    SamAccountName = $adUser.SamAccountName; Action = 'Retrait'; Group = $group
                    Status = $status; Error = $errorText
                }
                $out | Select-Object SamAccountName, Action, Group, Status, Error
            }
        }
    }
}


#--- Start-ADTUserOffboarding.ps1 ------------------------------------------

function Start-ADTUserOffboarding {
<#
.SYNOPSIS
    Sauvegarde les acces, desactive un compte puis execute son depart.
.DESCRIPTION
    Le CSV des groupes et le CLIXML de l etat initial doivent tous deux etre ecrits
    avant de modifier AD. Le mot de passe precedent et les sessions deja ouvertes
    ne sont pas restaurables par cette sauvegarde. Les echecs partiels sont exposes.
.EXAMPLE
    Start-ADTUserOffboarding -Identity 'jcote' -BackupPath C:\Offboarding -WhatIf
#>
    [CmdletBinding(SupportsShouldProcess=$true,ConfirmImpact='High')]
    param(
        [Parameter(Mandatory=$true,ValueFromPipeline=$true,ValueFromPipelineByPropertyName=$true)]
        [Alias('SamAccountName','User')][string[]]$Identity,
        [string]$DisabledOU,[string]$BackupPath='.',[switch]$KeepGroups,[switch]$NoPasswordReset,
        [string]$Reason='Depart de l employe',[string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential,[string]$LogPath
    )
    begin {
        if ($LogPath) { $script:ADTLogPath=$LogPath }
        $pre = Test-ADTPrerequisite -Server $Server -Credential $Credential
        if (-not $pre.Ready) { throw $pre.Messages }
        $common = @{ Server=$pre.Server }
        if ($Credential) { $common['Credential']=$Credential }
        if ($DisabledOU) { Get-ADTNativeObject -Identity $DisabledOU @common -ErrorAction Stop | Out-Null }
    }
    process {
        foreach ($id in $Identity) {
            $steps=New-Object System.Collections.ArrayList; $errors=New-Object System.Collections.ArrayList
            $status='Echec'; $sam=$id; $backupFile=''; $stateFile=''
            try {
                $u = Get-ADTNativeUser -Identity $id @common -ErrorAction Stop
                $sam=$u.SamAccountName
                if ($PSCmdlet.ShouldProcess($u.DistinguishedName,'Sauvegarder, desactiver et traiter le depart')) {
                    if (-not (Test-Path -LiteralPath $BackupPath)) { New-Item -Path $BackupPath -ItemType Directory -ErrorAction Stop | Out-Null }
                    $token=(Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N')
                    $backupFile=Join-Path $BackupPath ('offboarding-'+$sam+'-'+$token+'.csv')
                    $stateFile=Join-Path $BackupPath ('offboarding-'+$sam+'-'+$token+'.clixml')
                    $u | Export-Clixml -Path $stateFile -ErrorAction Stop
                    $rows=@()
                    foreach ($dn in $u.MemberOf) { if ($dn) { $rows += New-Object PSObject -Property @{ SamAccountName=$sam; GroupDN=$dn; OriginalDN=$u.DistinguishedName; BackupDate=(Get-Date).ToString('o') } } }
                    if ($rows.Count) { $rows | Select-Object SamAccountName,GroupDN,OriginalDN,BackupDate | Export-Csv -Path $backupFile -NoTypeInformation -Encoding UTF8 -ErrorAction Stop }
                    else { Set-Content -Path $backupFile -Value '"SamAccountName","GroupDN","OriginalDN","BackupDate"' -Encoding UTF8 -ErrorAction Stop }
                    [void]$steps.Add('Sauvegardes ecrites')
                    # Disable first; a later password/group failure must not leave the account enabled.
                    Disable-ADTNativeAccount -Identity $u.DistinguishedName @common -ErrorAction Stop
                    [void]$steps.Add('Compte desactive')
                    if (-not $NoPasswordReset) {
                        try {
                            $password=ConvertTo-ADTSecurePassword -Text (New-ADTRandomPassword -Length 24)
                            Set-ADTNativePassword -Identity $u.DistinguishedName -NewPassword $password -Reset @common -ErrorAction Stop
                            [void]$steps.Add('Mot de passe reinitialise')
                        } catch { [void]$errors.Add('Mot de passe : '+$_.Exception.Message) }
                        finally { if ($password) { $password.Dispose(); $password=$null } }
                    }
                    if (-not $KeepGroups) {
                        foreach ($dn in $u.MemberOf) {
                            if (-not $dn) { continue }
                            try { Remove-ADTNativeGroupMember -Identity $dn -Members $u.DistinguishedName -Confirm:$false @common -ErrorAction Stop; [void]$steps.Add('Retire : '+$dn) }
                            catch { [void]$errors.Add('Groupe '+$dn+' : '+$_.Exception.Message) }
                        }
                    }
                    try {
                        $note='[{0}] {1} - {2}\{3}' -f (Get-Date -Format 'yyyy-MM-dd'),$Reason,$env:USERDOMAIN,$env:USERNAME
                        if ($u.Description) { $note += ' | '+$u.Description }
                        if ($note.Length -gt 1024) { $note=$note.Substring(0,1024) }
                        Set-ADTNativeUser -Identity $u.DistinguishedName -Description $note @common -ErrorAction Stop
                        [void]$steps.Add('Description mise a jour')
                    } catch { [void]$errors.Add('Description : '+$_.Exception.Message) }
                    if ($DisabledOU) {
                        try { Move-ADTNativeObject -Identity $u.DistinguishedName -TargetPath $DisabledOU @common -ErrorAction Stop; [void]$steps.Add('Compte deplace') }
                        catch { [void]$errors.Add('Deplacement : '+$_.Exception.Message) }
                    }
                    $status='Termine'
                    if ($errors.Count) { $status='Partiel' }
                } else { $status='Annule'; if ($WhatIfPreference) { $status='Simulation' } }
            } catch { [void]$errors.Add($_.Exception.Message); if ($steps.Count) { $status='Partiel' } }
            if (-not $WhatIfPreference) { Write-ADTLog -Message ('Depart {0} : {1}. Etapes: {2}. Erreurs: {3}' -f $sam,$status,($steps -join '; '),($errors -join ' | ')) }
            New-Object PSObject -Property @{ SamAccountName=$sam; Status=$status; Steps=($steps -join ' > '); BackupFile=$backupFile; StateFile=$stateFile; Error=($errors -join ' | ') }
        }
    }
}


#--- Test-ADTPrerequisite.ps1 ----------------------------------------------

function Test-ADTPrerequisite {
<#
.SYNOPSIS
    Verifie le moteur PowerShell, LDAP et l acces au domaine sans exiger RSAT.
.EXAMPLE
    Test-ADTPrerequisite -Server 'dc01.contoso.local'
#>
    [CmdletBinding()]
    param([string]$Server,[System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential)
    $messages = New-Object System.Collections.ArrayList
    $ready = $false; $domainName = ''; $mode = ''; $dc = ''; $elevated = $false
    try {
        if ($PSVersionTable.PSVersion.Major -lt 2) { throw 'PowerShell 2.0 minimum requis.' }
        if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Ce module LDAP necessite Windows et System.DirectoryServices.' }
        # Windows PowerShell 2.0 a 5.1 et PowerShell 7 sur Windows conviennent : la seule
        # exigence est System.DirectoryServices. L interface graphique, elle, demande 7.4.
        try { Add-Type -AssemblyName System.DirectoryServices -ErrorAction Stop }
        catch { if (-not ('System.DirectoryServices.DirectoryEntry' -as [type])) { throw } }
        $domain = Get-ADTNativeDomain -Server $Server -Credential $Credential -ErrorAction Stop
        $domainName = $domain.DNSRoot; $mode = $domain.DomainMode; $dc = $domain.Server; $ready = $true
        [void]$messages.Add('Connexion LDAP reussie. Les droits d ecriture dependent des delegations AD du compte.')
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        try { $principal = New-Object System.Security.Principal.WindowsPrincipal($id); $elevated = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator) } finally { $id.Dispose() }
    } catch { [void]$messages.Add($_.Exception.Message) }
    New-Object PSObject -Property @{ PowerShellVersion=[string]$PSVersionTable.PSVersion; IsElevated=$elevated; ADModuleAvailable=([bool](Get-Module -ListAvailable -Name ActiveDirectory)); ADModuleLoaded=([bool](Get-Module ActiveDirectory)); Backend='LDAP signe et chiffre (ADSI)'; DomainReachable=$ready; DomainName=$domainName; DomainMode=$mode; Server=$dc; Ready=$ready; Messages=($messages -join ' | ') }
}

