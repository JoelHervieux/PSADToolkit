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
