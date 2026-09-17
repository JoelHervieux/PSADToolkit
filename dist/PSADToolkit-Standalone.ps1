<#
    PSADToolkit 3.1.0-test2 - version autonome
    Generee le 2026-09-17 18:07 par Build.ps1 - NE PAS MODIFIER A LA MAIN.

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


#--- DirectoryConsole.ps1 --------------------------------------------------

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


#--- DirectoryWrite.ps1 ----------------------------------------------------

# Ecritures LDAP de la console d administration. Toutes les fonctions travaillent
# sur un DN deja resolu : la resolution d identite et la confirmation appartiennent
# a la couche publique, qui porte ShouldProcess et la journalisation.

function Set-ADTNativeObjectAttribute {
<#
.SYNOPSIS
    Ecrit ou efface des attributs sur un objet designe par son DN.
.DESCRIPTION
    Une valeur $null ou une chaine vide efface l attribut, comme laisser un champ
    vide dans la console Microsoft. Les attributs restants ne sont pas touches.
.EXAMPLE
    Set-ADTNativeObjectAttribute -DistinguishedName $dn -Attribute @{ title = 'Technicien'; department = 'TI' }
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$DistinguishedName,
        [Parameter(Mandatory = $true)][hashtable]$Attribute,
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential
    )
    if (-not $Attribute.Count) { return }
    $entry = Open-ADTEntry -DN $DistinguishedName -Server $Server -Credential $Credential
    try {
        foreach ($key in @($Attribute.Keys)) {
            $value = $Attribute[$key]
            $isEmpty = ($null -eq $value)
            if (-not $isEmpty -and ($value -is [string]) -and ([string]$value).Length -eq 0) { $isEmpty = $true }
            if ($isEmpty) {
                if ($entry.Properties[$key].Count -gt 0) { $entry.Properties[$key].Clear() }
            } else {
                $entry.Properties[$key].Value = $value
            }
        }
        $entry.CommitChanges()
    } finally { $entry.Dispose() }
}

function Set-ADTNativeAccountControl {
<#
.SYNOPSIS
    Positionne ou retire des indicateurs de userAccountControl.
.PARAMETER SetFlag
    Bits a activer. Ex. 2 = compte desactive, 65536 = mot de passe sans expiration.
.PARAMETER ClearFlag
    Bits a desactiver.
.EXAMPLE
    Set-ADTNativeAccountControl -DistinguishedName $dn -ClearFlag 2
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$DistinguishedName,
        [int]$SetFlag = 0,
        [int]$ClearFlag = 0,
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential
    )
    if ($SetFlag -eq 0 -and $ClearFlag -eq 0) { return }
    $entry = Open-ADTEntry -DN $DistinguishedName -Server $Server -Credential $Credential
    try {
        $current = 0
        if ($entry.Properties['userAccountControl'].Count) { $current = [int]$entry.Properties['userAccountControl'][0] }
        $updated = ($current -bor $SetFlag) -band (-bnot $ClearFlag)
        if ($updated -ne $current) {
            $entry.Properties['userAccountControl'].Value = $updated
            $entry.CommitChanges()
        }
        return $updated
    } finally { $entry.Dispose() }
}

function Enable-ADTNativeAccount {
<#
.SYNOPSIS
    Reactive un compte utilisateur ou ordinateur.
.EXAMPLE
    Enable-ADTNativeAccount -DistinguishedName 'CN=jcote,OU=Employes,DC=contoso,DC=local'
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$DistinguishedName,
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential
    )
    $null = Set-ADTNativeAccountControl -DistinguishedName $DistinguishedName -ClearFlag 2 -Server $Server -Credential $Credential
}

function Unlock-ADTNativeAccount {
<#
.SYNOPSIS
    Deverrouille un compte bloque par la strategie de verrouillage.
.DESCRIPTION
    Le deverrouillage consiste a remettre lockoutTime a zero. L indicateur
    LOCKOUT de userAccountControl est calcule par le controleur et n est pas
    modifiable directement.
.EXAMPLE
    Unlock-ADTNativeAccount -DistinguishedName $dn
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$DistinguishedName,
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential
    )
    $entry = Open-ADTEntry -DN $DistinguishedName -Server $Server -Credential $Credential
    try {
        $entry.Properties['lockoutTime'].Value = 0
        $entry.CommitChanges()
    } finally { $entry.Dispose() }
}

function Set-ADTNativeAccountExpiration {
<#
.SYNOPSIS
    Definit ou supprime la date d expiration d un compte.
.PARAMETER ExpiresAfter
    Instant a partir duquel le compte n est plus utilisable. $null ou chaine vide
    signifie "n expire jamais". Type non contraint : Windows PowerShell 2.0 rend
    les parametres [Nullable[datetime]] peu previsibles a travers un splat.
.DESCRIPTION
    La console Microsoft affiche "Fin de : <date>" : le compte reste utilisable
    toute la journee indiquee et expire a minuit. L appelant passe donc l instant
    reel d expiration, soit le debut du jour suivant.
.EXAMPLE
    Set-ADTNativeAccountExpiration -DistinguishedName $dn -ExpiresAfter ([datetime]'2027-01-01')
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$DistinguishedName,
        [AllowNull()][AllowEmptyString()]$ExpiresAfter,
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential
    )
    $moment = $null
    if ($null -ne $ExpiresAfter -and ([string]$ExpiresAfter).Length -gt 0) { $moment = [datetime]$ExpiresAfter }
    $entry = Open-ADTEntry -DN $DistinguishedName -Server $Server -Credential $Credential
    try {
        if ($null -eq $moment) {
            # 0 est la seule valeur "jamais" ecrivable sans passer par un
            # LargeInteger COM ; c est aussi celle qu ecrit la console Microsoft.
            $entry.Properties['accountExpires'].Value = 0
        } else {
            $null = $entry.InvokeSet('AccountExpirationDate', $moment)
        }
        $entry.CommitChanges()
    } finally { $entry.Dispose() }
}

function Set-ADTNativeLogonHours {
<#
.SYNOPSIS
    Ecrit l attribut logonHours a partir d un masque local de 168 caracteres.
.PARAMETER Mask
    Masque local. Un masque entierement autorise efface l attribut, ce qui
    correspond a "toutes les heures" dans la console Microsoft.
.EXAMPLE
    Set-ADTNativeLogonHours -DistinguishedName $dn -Mask (New-ADTLogonHoursMask -AllowAll)
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$DistinguishedName,
        [Parameter(Mandatory = $true)][string]$Mask,
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential
    )
    if (-not (Test-ADTLogonHoursMask -Mask $Mask)) { throw 'Masque d horaires invalide : 168 caracteres 0 ou 1 attendus.' }
    $entry = Open-ADTEntry -DN $DistinguishedName -Server $Server -Credential $Credential
    try {
        if ($Mask -eq ('1' * 168)) {
            if ($entry.Properties['logonHours'].Count -gt 0) { $entry.Properties['logonHours'].Clear() }
        } else {
            $entry.Properties['logonHours'].Value = (ConvertTo-ADTLogonHoursByte -Mask $Mask)
        }
        $entry.CommitChanges()
    } finally { $entry.Dispose() }
}

function Set-ADTNativeMustChangePassword {
<#
.SYNOPSIS
    Active ou desactive "l utilisateur doit changer de mot de passe".
.DESCRIPTION
    pwdLastSet a 0 force le changement, -1 le repousse en marquant le mot de
    passe comme change a l instant. Aucune autre valeur n est acceptee par AD.
.EXAMPLE
    Set-ADTNativeMustChangePassword -DistinguishedName $dn -Required $true
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$DistinguishedName,
        [Parameter(Mandatory = $true)][bool]$Required,
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential
    )
    $entry = Open-ADTEntry -DN $DistinguishedName -Server $Server -Credential $Credential
    try {
        if ($Required) { $entry.Properties['pwdLastSet'].Value = 0 }
        else { $entry.Properties['pwdLastSet'].Value = -1 }
        $entry.CommitChanges()
    } finally { $entry.Dispose() }
}

function New-ADTNativeGroup {
<#
.SYNOPSIS
    Cree un groupe dans une unite d organisation.
.PARAMETER Scope
    Global, DomainLocal ou Universal.
.PARAMETER Category
    Security ou Distribution.
.EXAMPLE
    New-ADTNativeGroup -Path 'OU=Groupes,DC=contoso,DC=local' -Name 'GS-VPN' -SamAccountName 'GS-VPN'
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$SamAccountName,
        [ValidateSet('Global', 'DomainLocal', 'Universal')][string]$Scope = 'Global',
        [ValidateSet('Security', 'Distribution')][string]$Category = 'Security',
        [string]$Description,
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential
    )
    $type = 2
    if ($Scope -eq 'DomainLocal') { $type = 4 }
    if ($Scope -eq 'Universal') { $type = 8 }
    if ($Category -eq 'Security') { $type = $type -bor ([int]::MinValue) }

    $parent = Open-ADTEntry -DN $Path -Server $Server -Credential $Credential
    $entry = $null
    try {
        $entry = $parent.Children.Add(('CN=' + (ConvertTo-ADTRdnValue $Name)), 'group')
        $entry.Properties['sAMAccountName'].Value = $SamAccountName
        $entry.Properties['groupType'].Value = $type
        if ($Description) { $entry.Properties['description'].Value = $Description }
        $entry.CommitChanges()
        return ('CN=' + (ConvertTo-ADTRdnValue $Name) + ',' + $Path)
    } finally {
        if ($entry) { $entry.Dispose() }
        $parent.Dispose()
    }
}

function New-ADTNativeOrganizationalUnit {
<#
.SYNOPSIS
    Cree une unite d organisation et echoue si elle existe deja.
.DESCRIPTION
    Ensure-ADTNativeOU est idempotente parce que l import CSV cree les sous-OU de
    departement a la volee. Une creation demandee explicitement dans la console
    doit au contraire signaler le doublon.
.EXAMPLE
    New-ADTNativeOrganizationalUnit -Path 'DC=contoso,DC=local' -Name 'Employes'
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Description,
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential
    )
    $cleanName = ([string]$Name).Trim()
    if (-not $cleanName) { throw 'Nom d unite d organisation vide.' }
    $targetDN = 'OU=' + (ConvertTo-ADTRdnValue $cleanName) + ',' + $Path

    $existing = $null
    try { $existing = Open-ADTEntry -DN $targetDN -Server $Server -Credential $Credential }
    catch { $existing = $null }
    if ($existing) {
        $existing.Dispose()
        throw ('Une unite d organisation porte deja ce nom : {0}' -f $targetDN)
    }

    $parent = Open-ADTEntry -DN $Path -Server $Server -Credential $Credential
    $entry = $null
    try {
        $entry = $parent.Children.Add(('OU=' + (ConvertTo-ADTRdnValue $cleanName)), 'organizationalUnit')
        if ($Description) { $entry.Properties['description'].Value = $Description }
        $entry.CommitChanges()
        return $targetDN
    } finally {
        if ($entry) { $entry.Dispose() }
        $parent.Dispose()
    }
}

function Rename-ADTNativeObject {
<#
.SYNOPSIS
    Renomme un objet, c est-a-dire change son RDN.
.DESCRIPTION
    Le prefixe du RDN depend de la classe : OU= pour une unite d organisation,
    CN= pour les autres objets de la console.
.EXAMPLE
    Rename-ADTNativeObject -DistinguishedName $dn -NewName 'Comptabilite' -ObjectClass 'organizationalUnit'
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$DistinguishedName,
        [Parameter(Mandatory = $true)][string]$NewName,
        [string]$ObjectClass = 'user',
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential
    )
    $cleanName = ([string]$NewName).Trim()
    if (-not $cleanName) { throw 'Nouveau nom vide.' }
    $prefix = 'CN='
    if ($ObjectClass -eq 'organizationalUnit') { $prefix = 'OU=' }
    $rdn = $prefix + (ConvertTo-ADTRdnValue $cleanName)

    $entry = Open-ADTEntry -DN $DistinguishedName -Server $Server -Credential $Credential
    try {
        $entry.Rename($rdn)
        $entry.CommitChanges()
        return ($rdn + ',' + (Get-ADTParentDistinguishedName -DistinguishedName $DistinguishedName))
    } finally { $entry.Dispose() }
}

function Get-ADTParentDistinguishedName {
<#
.SYNOPSIS
    DN du conteneur parent, en respectant les virgules echappees.
.EXAMPLE
    Get-ADTParentDistinguishedName -DistinguishedName 'CN=Cote\, Joel,OU=Employes,DC=contoso,DC=local'
#>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true, Position = 0)][string]$DistinguishedName)
    for ($index = 0; $index -lt $DistinguishedName.Length; $index++) {
        if ($DistinguishedName[$index] -eq ',' -and ($index -eq 0 -or $DistinguishedName[$index - 1] -ne '\')) {
            return $DistinguishedName.Substring($index + 1)
        }
    }
    return ''
}

function Test-ADTNativeHasChild {
<#
.SYNOPSIS
    Indique si un conteneur possede au moins un objet enfant.
.EXAMPLE
    Test-ADTNativeHasChild -DistinguishedName 'OU=Employes,DC=contoso,DC=local'
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$DistinguishedName,
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential
    )
    $found = @(Search-ADTDirectoryEntry -LDAPFilter '(objectClass=*)' -SearchBase $DistinguishedName -Scope OneLevel `
            -Property @('distinguishedName') -SizeLimit 1 -Server $Server -Credential $Credential)
    return ($found.Count -gt 0)
}

function Get-ADTNativeDeletionProtection {
<#
.SYNOPSIS
    Indique si l objet est protege contre la suppression accidentelle.
.DESCRIPTION
    La protection de la console Microsoft est une entree de refus explicite pour
    Tout le monde (S-1-1-0) sur les droits Supprimer et Supprimer l arborescence.
.EXAMPLE
    Get-ADTNativeDeletionProtection -DistinguishedName $dn
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$DistinguishedName,
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential
    )
    $entry = Open-ADTEntry -DN $DistinguishedName -Server $Server -Credential $Credential
    try {
        $security = $entry.ObjectSecurity
        if (-not $security) { return $false }
        $everyone = 'S-1-1-0'
        $deleteRights = [int][System.DirectoryServices.ActiveDirectoryRights]::Delete -bor [int][System.DirectoryServices.ActiveDirectoryRights]::DeleteTree
        $rules = $security.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier])
        foreach ($rule in $rules) {
            if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Deny) { continue }
            if ([string]$rule.IdentityReference -ne $everyone) { continue }
            if (([int]$rule.ActiveDirectoryRights -band $deleteRights) -ne 0) { return $true }
        }
        return $false
    } finally { $entry.Dispose() }
}

function Set-ADTNativeDeletionProtection {
<#
.SYNOPSIS
    Active ou retire la protection contre la suppression accidentelle.
.EXAMPLE
    Set-ADTNativeDeletionProtection -DistinguishedName $dn -Protected $false
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$DistinguishedName,
        [Parameter(Mandatory = $true)][bool]$Protected,
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential
    )
    $entry = Open-ADTEntry -DN $DistinguishedName -Server $Server -Credential $Credential
    try {
        $security = $entry.ObjectSecurity
        if (-not $security) { throw 'Descripteur de securite illisible sur cet objet.' }
        $everyone = New-Object System.Security.Principal.SecurityIdentifier('S-1-1-0')
        $rights = [System.DirectoryServices.ActiveDirectoryRights]::Delete -bor [System.DirectoryServices.ActiveDirectoryRights]::DeleteTree
        $rule = New-Object System.DirectoryServices.ActiveDirectoryAccessRule($everyone, $rights, [System.Security.AccessControl.AccessControlType]::Deny)
        if ($Protected) { $security.AddAccessRule($rule) }
        else {
            $null = $security.RemoveAccessRule($rule)
            # La console Microsoft ecrit parfois les deux droits dans des entrees
            # separees : les retirer une a une evite de laisser un refus orphelin.
            foreach ($single in @([System.DirectoryServices.ActiveDirectoryRights]::Delete, [System.DirectoryServices.ActiveDirectoryRights]::DeleteTree)) {
                $one = New-Object System.DirectoryServices.ActiveDirectoryAccessRule($everyone, $single, [System.Security.AccessControl.AccessControlType]::Deny)
                $null = $security.RemoveAccessRule($one)
            }
        }
        $entry.ObjectSecurity = $security
        $entry.CommitChanges()
    } finally { $entry.Dispose() }
}

function Remove-ADTNativeObject {
<#
.SYNOPSIS
    Supprime un objet Active Directory.
.PARAMETER Recursive
    Autorise la suppression d un conteneur non vide (DeleteTree).
.DESCRIPTION
    Un conteneur non vide n est jamais supprime sans -Recursive : la console
    Microsoft impose la meme confirmation explicite.
.EXAMPLE
    Remove-ADTNativeObject -DistinguishedName $dn
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$DistinguishedName,
        [switch]$Recursive,
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential
    )
    $entry = Open-ADTEntry -DN $DistinguishedName -Server $Server -Credential $Credential
    try {
        if ($Recursive) { $entry.DeleteTree() }
        else {
            $parentDN = Get-ADTParentDistinguishedName -DistinguishedName $DistinguishedName
            if (-not $parentDN) { throw ('Impossible de determiner le conteneur parent de {0}.' -f $DistinguishedName) }
            $parent = Open-ADTEntry -DN $parentDN -Server $Server -Credential $Credential
            try { $parent.Children.Remove($entry) } finally { $parent.Dispose() }
        }
    } finally { $entry.Dispose() }
}


#--- Format-ADTDisplay.ps1 -------------------------------------------------

# Formats regionaux. Tout ce que PSADToolkit AFFICHE (grilles, dialogues, rapports)
# doit suivre la culture de la machine qui execute l application, jamais un format
# code en dur. Le journal fait exception : Write-ADTLog garde un horodatage ISO
# 8601, trie et lisible quel que soit le poste qui relit le fichier d audit.

function Get-ADTDisplayCulture {
<#
.SYNOPSIS
    Culture d affichage courante de la machine.
.DESCRIPTION
    CurrentCulture suit le format regional de l utilisateur Windows. En cas de
    culture invariante (service, tache planifiee), on retombe sur la culture de
    l interface utilisateur puis sur la culture installee.
.EXAMPLE
    (Get-ADTDisplayCulture).Name
#>
    [CmdletBinding()]
    param()
    $culture = [System.Globalization.CultureInfo]::CurrentCulture
    if ($culture -and -not $culture.Name) { $culture = [System.Globalization.CultureInfo]::CurrentUICulture }
    if ($culture -and -not $culture.Name) { $culture = [System.Globalization.CultureInfo]::InstalledUICulture }
    return $culture
}

function Format-ADTDateTime {
<#
.SYNOPSIS
    Met en forme une date/heure selon le format regional de la machine.
.PARAMETER Value
    DateTime, chaine convertible ou $null. $null et les dates vides rendent ''.
.PARAMETER Kind
    DateTime (defaut), Date, Time ou Long.
.EXAMPLE
    Format-ADTDateTime -Value (Get-Date) -Kind Date
#>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][AllowNull()]$Value,
        [ValidateSet('DateTime', 'Date', 'Time', 'Long')]
        [string]$Kind = 'DateTime'
    )
    if ($null -eq $Value) { return '' }
    if ($Value -is [string] -and -not $Value) { return '' }

    $moment = $null
    if ($Value -is [datetime]) { $moment = [datetime]$Value }
    else {
        try { $moment = [datetime]::Parse([string]$Value, (Get-ADTDisplayCulture)) }
        catch { return [string]$Value }
    }
    if ($moment -eq [datetime]::MinValue) { return '' }

    $culture = Get-ADTDisplayCulture
    switch ($Kind) {
        'Date' { return $moment.ToString('d', $culture) }
        'Time' { return $moment.ToString('t', $culture) }
        'Long' { return $moment.ToString('F', $culture) }
        default { return $moment.ToString('g', $culture) }
    }
}

function Format-ADTDayName {
<#
.SYNOPSIS
    Nom du jour de la semaine dans la langue de la machine.
.PARAMETER DayOfWeek
    0 = dimanche ... 6 = samedi, ou une valeur System.DayOfWeek.
.PARAMETER Abbreviated
    Rend l abreviation (lun., mar., ...) au lieu du nom complet.
.EXAMPLE
    Format-ADTDayName -DayOfWeek 1 -Abbreviated
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]$DayOfWeek,
        [switch]$Abbreviated
    )
    $index = [int]$DayOfWeek
    if ($index -lt 0 -or $index -gt 6) { throw ('Jour de la semaine hors bornes : {0}' -f $index) }
    $format = (Get-ADTDisplayCulture).DateTimeFormat
    if ($Abbreviated) { return [string]$format.AbbreviatedDayNames[$index] }
    return [string]$format.DayNames[$index]
}

function Get-ADTWeekDayOrder {
<#
.SYNOPSIS
    Ordre d affichage des sept jours selon la culture de la machine.
.DESCRIPTION
    Rend les indices 0..6 (dimanche..samedi) reordonnes a partir du premier jour
    de la semaine de la culture : lundi en France et au Canada francais, dimanche
    aux Etats-Unis. La grille des horaires de connexion suit cet ordre.
.EXAMPLE
    Get-ADTWeekDayOrder
#>
    [CmdletBinding()]
    param()
    $first = [int](Get-ADTDisplayCulture).DateTimeFormat.FirstDayOfWeek
    $order = New-Object System.Collections.ArrayList
    for ($step = 0; $step -lt 7; $step++) { [void]$order.Add((($first + $step) % 7)) }
    return [int[]]@($order)
}

function Format-ADTHourLabel {
<#
.SYNOPSIS
    Libelle d une heure pleine selon le format regional (24 h ou AM/PM).
.PARAMETER Hour
    Heure locale de 0 a 24. 24 designe minuit de fin de journee.
.EXAMPLE
    Format-ADTHourLabel -Hour 13
#>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true, Position = 0)][int]$Hour)
    if ($Hour -lt 0 -or $Hour -gt 24) { throw ('Heure hors bornes : {0}' -f $Hour) }
    $culture = Get-ADTDisplayCulture
    $moment = (New-Object System.DateTime(2000, 1, 1, 0, 0, 0)).AddHours($Hour)
    return $moment.ToString($culture.DateTimeFormat.ShortTimePattern, $culture)
}

function Test-ADTUses24HourClock {
<#
.SYNOPSIS
    Indique si la culture de la machine affiche l heure sur 24 h.
.DESCRIPTION
    Sert a dimensionner les en-tetes de la grille des horaires de connexion :
    "13" tient dans une colonne etroite, "1 PM" demande plus de place.

    Les litteraux du motif sont retires avant l analyse : le francais du Canada
    utilise "HH 'h' mm", ou le h entre apostrophes est le separateur d heure et non
    le specificateur d heure sur 12. Sans ce nettoyage, une horloge de 24 heures
    serait prise pour une horloge de 12 heures.
.EXAMPLE
    Test-ADTUses24HourClock
#>
    [CmdletBinding()]
    param()
    $pattern = [string](Get-ADTDisplayCulture).DateTimeFormat.ShortTimePattern
    $pattern = [System.Text.RegularExpressions.Regex]::Replace($pattern, '\\.', '')
    $pattern = [System.Text.RegularExpressions.Regex]::Replace($pattern, "'[^']*'", '')
    $pattern = [System.Text.RegularExpressions.Regex]::Replace($pattern, '"[^"]*"', '')
    return ($pattern -cnotmatch 'h' -and $pattern -cnotmatch 't')
}

function Format-ADTHourHeader {
<#
.SYNOPSIS
    Etiquette compacte d une heure pour l en-tete de la grille des horaires.
.DESCRIPTION
    Une colonne de la grille des horaires de connexion fait quelques pixels de
    large : "13" y tient, "1:00 PM" non. La fonction respecte tout de meme la
    convention horaire de la culture : 00 a 23 sur une horloge de 24 heures,
    12a / 1p sur une horloge de 12 heures, avec le designateur de la culture.
.EXAMPLE
    Format-ADTHourHeader -Hour 13
#>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true, Position = 0)][int]$Hour)
    if ($Hour -lt 0 -or $Hour -gt 23) { throw ('Heure hors bornes : {0}' -f $Hour) }
    if (Test-ADTUses24HourClock) { return ('{0:00}' -f $Hour) }

    $format = (Get-ADTDisplayCulture).DateTimeFormat
    $designator = [string]$format.AMDesignator
    if ($Hour -ge 12) { $designator = [string]$format.PMDesignator }
    if ($designator) { $designator = $designator.Substring(0, 1).ToLower() }
    $display = $Hour % 12
    if ($display -eq 0) { $display = 12 }
    return ([string]$display + $designator)
}


#--- Initialize-ADTConnection.ps1 ------------------------------------------

function Initialize-ADTConnection {
<#
.SYNOPSIS
    Verifie les prerequis puis rend les parametres de connexion communs.
.DESCRIPTION
    Toutes les fonctions publiques commencent par la meme sequence : fixer le
    journal, verifier LDAP et le domaine, puis constituer le splat Server /
    Credential passe au backend. Ce helper evite d en recopier une variante par
    fonction, et garantit que le controleur retenu par Test-ADTPrerequisite est
    bien celui utilise ensuite : sans cela, deux requetes successives pourraient
    tomber sur deux controleurs differents et lire un annuaire non replique.
.EXAMPLE
    $common = Initialize-ADTConnection -Server $Server -Credential $Credential
#>
    [CmdletBinding()]
    param(
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential,
        [string]$LogPath
    )
    if ($LogPath) { $script:ADTLogPath = $LogPath }
    $prerequisite = Test-ADTPrerequisite -Server $Server -Credential $Credential
    if (-not $prerequisite.Ready) { throw ('Prerequis non satisfaits : {0}' -f $prerequisite.Messages) }
    $common = @{}
    if ($prerequisite.Server) { $common['Server'] = [string]$prerequisite.Server }
    if ($Credential) { $common['Credential'] = $Credential }
    return $common
}


#--- LogonHours.ps1 --------------------------------------------------------

# Horaires de connexion Active Directory (attribut logonHours).
#
# L attribut est une chaine d octets de 21 octets, soit 168 bits : un bit par
# heure de la semaine. Le bit 0 de l octet 0 est le dimanche de 00 h a 01 h
# EN TEMPS UNIVERSEL. Un bit a 1 autorise la connexion.
#
#   indice UTC i (0..167) -> octet i \ 8, bit i % 8 (bit de poids faible d abord)
#
# ADUC affiche la grille en heure locale : il decale les bits du biais UTC du
# poste. PSADToolkit fait de meme, sinon un horaire "08 h - 18 h" saisi a Montreal
# deviendrait "03 h - 13 h" dans la console Microsoft. Toutes les fonctions qui
# manipulent un MASQUE travaillent donc en HEURE LOCALE, et la conversion en
# octets applique le decalage.
#
# Le masque est une chaine de 168 caracteres 0 ou 1, indice = jour * 24 + heure,
# jour 0 = dimanche local. Format texte volontaire : lisible dans un journal,
# transmissible en ligne de commande et comparable sans objet intermediaire.

function Get-ADTLogonHoursOffset {
<#
.SYNOPSIS
    Decalage horaire local a appliquer aux bits de logonHours, en heures entieres.
.DESCRIPTION
    System.TimeZone existe depuis .NET 2.0, contrairement a TimeZoneInfo : le
    module doit rester utilisable sous Windows PowerShell 2.0.
    logonHours n a qu une resolution d une heure. Les fuseaux a la demi-heure
    (Inde, Terre-Neuve) sont arrondis a l heure la plus proche, comme le fait ADUC.
.EXAMPLE
    Get-ADTLogonHoursOffset
#>
    [CmdletBinding()]
    param([datetime]$Reference = (Get-Date))
    $offset = [System.TimeZone]::CurrentTimeZone.GetUtcOffset($Reference)
    return [int][Math]::Round($offset.TotalHours, 0, [System.MidpointRounding]::AwayFromZero)
}

function Test-ADTLogonHoursMask {
<#
.SYNOPSIS
    Valide un masque d horaires de connexion.
.DESCRIPTION
    Un masque valide compte exactement 168 caracteres 0 ou 1.
.EXAMPLE
    Test-ADTLogonHoursMask -Mask ('1' * 168)
#>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true, Position = 0)][AllowEmptyString()][string]$Mask)
    if ($Mask.Length -ne 168) { return $false }
    return ($Mask -match '^[01]{168}$')
}

function New-ADTLogonHoursMask {
<#
.SYNOPSIS
    Construit un masque d horaires de connexion en heure locale.
.PARAMETER Day
    Jours autorises : Sunday..Saturday, ou 0..6. Vide avec -AllowAll = toute la semaine.
.PARAMETER StartHour
    Premiere heure autorisee (0..23).
.PARAMETER EndHour
    Heure de fin exclue (1..24). 18 signifie "jusqu a 18 h 00".
.PARAMETER AllowAll
    Autorise les 168 heures, en ignorant les autres parametres.
.PARAMETER DenyAll
    Interdit les 168 heures. Un compte sans aucune heure autorisee ne peut plus
    ouvrir de session : l appelant doit confirmer ce choix.
.EXAMPLE
    New-ADTLogonHoursMask -Day 'Monday','Tuesday','Wednesday','Thursday','Friday' -StartHour 8 -EndHour 18
#>
    [CmdletBinding()]
    param(
        [object[]]$Day,
        [ValidateRange(0, 23)][int]$StartHour = 0,
        [ValidateRange(1, 24)][int]$EndHour = 24,
        [switch]$AllowAll,
        [switch]$DenyAll
    )
    if ($AllowAll -and $DenyAll) { throw 'AllowAll et DenyAll s excluent.' }
    if ($AllowAll) { return ('1' * 168) }
    if ($DenyAll) { return ('0' * 168) }
    if ($EndHour -le $StartHour) { throw ('EndHour ({0}) doit etre superieure a StartHour ({1}).' -f $EndHour, $StartHour) }

    $days = New-Object System.Collections.ArrayList
    if (-not $Day -or @($Day).Count -eq 0) {
        for ($index = 0; $index -lt 7; $index++) { [void]$days.Add($index) }
    } else {
        foreach ($item in $Day) {
            if ($null -eq $item) { continue }
            $value = -1
            if ($item -is [int]) { $value = [int]$item }
            else {
                $text = ([string]$item).Trim()
                if ($text -match '^[0-6]$') { $value = [int]$text }
                else {
                    try { $value = [int][System.DayOfWeek]$text }
                    catch { throw ('Jour inconnu : {0}. Utiliser Sunday..Saturday ou 0..6.' -f $text) }
                }
            }
            if ($value -lt 0 -or $value -gt 6) { throw ('Jour hors bornes : {0}' -f $item) }
            if (-not $days.Contains($value)) { [void]$days.Add($value) }
        }
    }

    $mask = New-Object System.Text.StringBuilder
    for ($slot = 0; $slot -lt 168; $slot++) { [void]$mask.Append('0') }
    foreach ($dayIndex in $days) {
        for ($hour = $StartHour; $hour -lt $EndHour; $hour++) {
            $mask[($dayIndex * 24) + $hour] = '1'
        }
    }
    return $mask.ToString()
}

function ConvertFrom-ADTLogonHoursByte {
<#
.SYNOPSIS
    Convertit les 21 octets de logonHours en masque local de 168 caracteres.
.PARAMETER Byte
    Valeur brute de l attribut. $null ou vide signifie "aucune restriction" et
    rend un masque entierement autorise, comme l affiche ADUC.
.EXAMPLE
    ConvertFrom-ADTLogonHoursByte -Byte $user.LogonHours
#>
    [CmdletBinding()]
    param([AllowNull()][byte[]]$Byte, [int]$OffsetHours = ([int]::MinValue))
    if (-not $Byte -or $Byte.Length -eq 0) { return ('1' * 168) }
    if ($Byte.Length -ne 21) { throw ('logonHours doit contenir 21 octets, {0} recu(s).' -f $Byte.Length) }
    if ($OffsetHours -eq [int]::MinValue) { $OffsetHours = Get-ADTLogonHoursOffset }

    # Poids des huit bits d un octet : -shl et -shr n existent qu a partir de
    # PowerShell 3.0, et ce module doit tourner sous 2.0.
    $weight = @(1, 2, 4, 8, 16, 32, 64, 128)
    $mask = New-Object System.Text.StringBuilder
    for ($local = 0; $local -lt 168; $local++) {
        $utc = ((($local - $OffsetHours) % 168) + 168) % 168
        $bit = [int]$Byte[[int][Math]::Floor($utc / 8)] -band [int]$weight[$utc % 8]
        if ($bit -ne 0) { [void]$mask.Append('1') } else { [void]$mask.Append('0') }
    }
    return $mask.ToString()
}

function ConvertTo-ADTLogonHoursByte {
<#
.SYNOPSIS
    Convertit un masque local de 168 caracteres en 21 octets logonHours (UTC).
.EXAMPLE
    ConvertTo-ADTLogonHoursByte -Mask (New-ADTLogonHoursMask -AllowAll)
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Mask,
        [int]$OffsetHours = ([int]::MinValue)
    )
    if (-not (Test-ADTLogonHoursMask -Mask $Mask)) { throw 'Masque d horaires invalide : 168 caracteres 0 ou 1 attendus.' }
    if ($OffsetHours -eq [int]::MinValue) { $OffsetHours = Get-ADTLogonHoursOffset }

    $weight = @(1, 2, 4, 8, 16, 32, 64, 128)
    $bytes = New-Object 'System.Byte[]' 21
    for ($local = 0; $local -lt 168; $local++) {
        if ($Mask[$local] -ne '1') { continue }
        $utc = ((($local - $OffsetHours) % 168) + 168) % 168
        $index = [int][Math]::Floor($utc / 8)
        $bytes[$index] = [byte]([int]$bytes[$index] -bor [int]$weight[$utc % 8])
    }
    return , $bytes
}

function Get-ADTLogonHoursDayMask {
<#
.SYNOPSIS
    Extrait les 24 heures d un jour a partir d un masque complet.
.EXAMPLE
    Get-ADTLogonHoursDayMask -Mask $mask -DayOfWeek 1
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Mask,
        [Parameter(Mandatory = $true)][int]$DayOfWeek
    )
    if (-not (Test-ADTLogonHoursMask -Mask $Mask)) { throw 'Masque d horaires invalide.' }
    if ($DayOfWeek -lt 0 -or $DayOfWeek -gt 6) { throw ('Jour hors bornes : {0}' -f $DayOfWeek) }
    return $Mask.Substring($DayOfWeek * 24, 24)
}

function ConvertTo-ADTLogonHoursText {
<#
.SYNOPSIS
    Resume lisible d un masque d horaires, dans la langue et le format de la machine.
.DESCRIPTION
    Les jours dont l horaire est identique sont regroupes. Les noms de jours et
    les heures suivent la culture courante (Format-ADTDayName, Format-ADTHourLabel).
.EXAMPLE
    ConvertTo-ADTLogonHoursText -Mask $mask
#>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true, Position = 0)][string]$Mask)
    if (-not (Test-ADTLogonHoursMask -Mask $Mask)) { throw 'Masque d horaires invalide.' }
    if ($Mask -eq ('1' * 168)) { return 'Toutes les heures autorisees' }
    if ($Mask -eq ('0' * 168)) { return 'Aucune heure autorisee' }

    # Regrouper les jours consecutifs (dans l ordre d affichage de la culture)
    # qui partagent exactement le meme horaire.
    $segments = New-Object System.Collections.ArrayList
    $order = Get-ADTWeekDayOrder
    $currentDays = New-Object System.Collections.ArrayList
    $currentPattern = $null
    foreach ($dayIndex in $order) {
        $pattern = Get-ADTLogonHoursDayMask -Mask $Mask -DayOfWeek $dayIndex
        if ($null -ne $currentPattern -and $pattern -eq $currentPattern) {
            [void]$currentDays.Add($dayIndex)
            continue
        }
        if ($null -ne $currentPattern) { [void]$segments.Add((New-Object PSObject -Property @{ Days = @($currentDays); Pattern = $currentPattern })) }
        $currentDays = New-Object System.Collections.ArrayList
        [void]$currentDays.Add($dayIndex)
        $currentPattern = $pattern
    }
    if ($null -ne $currentPattern) { [void]$segments.Add((New-Object PSObject -Property @{ Days = @($currentDays); Pattern = $currentPattern })) }

    $parts = New-Object System.Collections.ArrayList
    foreach ($segment in $segments) {
        $days = @($segment.Days)
        $label = Format-ADTDayName -DayOfWeek $days[0] -Abbreviated
        if ($days.Count -gt 1) { $label = $label + '-' + (Format-ADTDayName -DayOfWeek $days[$days.Count - 1] -Abbreviated) }
        [void]$parts.Add(($label + ' ' + (ConvertTo-ADTLogonHoursRangeText -DayPattern ([string]$segment.Pattern))))
    }
    return ($parts -join ' ; ')
}

function ConvertTo-ADTLogonHoursRangeText {
<#
.SYNOPSIS
    Traduit les 24 bits d un jour en plages horaires lisibles.
.EXAMPLE
    ConvertTo-ADTLogonHoursRangeText -DayPattern ('0' * 8 + '1' * 10 + '0' * 6)
#>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true, Position = 0)][string]$DayPattern)
    if ($DayPattern.Length -ne 24) { throw 'Un jour compte 24 heures.' }
    if ($DayPattern -eq ('0' * 24)) { return 'aucune' }
    if ($DayPattern -eq ('1' * 24)) { return '24 h' }

    $ranges = New-Object System.Collections.ArrayList
    $start = -1
    for ($hour = 0; $hour -le 24; $hour++) {
        $allowed = $false
        if ($hour -lt 24 -and $DayPattern[$hour] -eq '1') { $allowed = $true }
        if ($allowed -and $start -lt 0) { $start = $hour }
        if (-not $allowed -and $start -ge 0) {
            [void]$ranges.Add(((Format-ADTHourLabel -Hour $start) + '-' + (Format-ADTHourLabel -Hour $hour)))
            $start = -1
        }
    }
    return ($ranges -join ', ')
}


#--- New-ADTRandomPassword.ps1 ---------------------------------------------

function New-ADTRandomPassword {
<#
.SYNOPSIS
    Genere un mot de passe aleatoire conforme aux exigences de complexite d Active Directory.
.DESCRIPTION
    Utilise RNGCryptoServiceProvider (aleatoire cryptographique) plutot que Get-Random,
    qui n est pas sur pour du materiel de securite.
    Par defaut, garantit au moins une majuscule, une minuscule, un chiffre et un
    caractere special, et exclut les caracteres ambigus (O, 0, l, 1, I) pour limiter
    les erreurs de saisie lors de la remise du mot de passe a l employe.

    Les classes de caracteres sont selectionnables. Une classe desactivee n est ni
    imposee ni tiree. Active Directory exige, lorsque la complexite est activee,
    des caracteres d au moins trois classes sur quatre : desactiver deux classes
    produit donc un mot de passe que le domaine refusera. La fonction ne l interdit
    pas, l appelant reste maitre de sa politique, mais Test-ADTPasswordComplexity
    permet de le verifier avant d ecrire dans l annuaire.
.PARAMETER Length
    Longueur du mot de passe. Minimum 12, defaut 16. PSADToolkit ne descend jamais
    sous 12 caracteres, meme si la strategie du domaine autorise plus court.
.PARAMETER UseUppercase
    Inclure des majuscules. Actif par defaut.
.PARAMETER UseLowercase
    Inclure des minuscules. Actif par defaut.
.PARAMETER UseDigit
    Inclure des chiffres. Actif par defaut.
.PARAMETER UseSpecial
    Inclure des caracteres speciaux. Actif par defaut.
.PARAMETER IncludeAmbiguous
    Reintegrer les caracteres ambigus O, 0, l, 1 et I.
.PARAMETER SpecialCharacter
    Jeu de caracteres speciaux a utiliser. Par defaut !#$%&*+-=?@, volontairement
    limite aux symboles qui se saisissent sans difficulte sur un clavier francais
    comme sur un clavier anglais.
.EXAMPLE
    New-ADTRandomPassword -Length 20
.EXAMPLE
    New-ADTRandomPassword -Length 24 -UseSpecial $false
#>
    [CmdletBinding()]
    param(
        [ValidateRange(12, 128)]
        [int]$Length = 16,
        [bool]$UseUppercase = $true,
        [bool]$UseLowercase = $true,
        [bool]$UseDigit = $true,
        [bool]$UseSpecial = $true,
        [switch]$IncludeAmbiguous,
        [string]$SpecialCharacter = '!#$%&*+-=?@'
    )

    if ($IncludeAmbiguous) {
        $upper = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
        $lower = 'abcdefghijklmnopqrstuvwxyz'
        $digit = '0123456789'
    } else {
        $upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
        $lower = 'abcdefghijkmnopqrstuvwxyz'
        $digit = '23456789'
    }
    $special = $SpecialCharacter

    $sets = New-Object System.Collections.ArrayList
    if ($UseUppercase) { [void]$sets.Add($upper) }
    if ($UseLowercase) { [void]$sets.Add($lower) }
    if ($UseDigit) { [void]$sets.Add($digit) }
    if ($UseSpecial -and $special) { [void]$sets.Add($special) }
    if (-not $sets.Count) { throw 'Aucune classe de caracteres selectionnee pour le mot de passe.' }
    if ($sets.Count -gt $Length) { throw ('Longueur {0} insuffisante pour couvrir {1} classes de caracteres.' -f $Length, $sets.Count) }

    $all = ''
    foreach ($set in $sets) { $all += $set }

    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    try {
        $bytes = New-Object 'System.Byte[]' 4

        # Rejet des tirages qui tomberaient dans la tranche incomplete de l espace
        # 32 bits : un simple modulo favoriserait les premiers caracteres du jeu.
        $pickChar = {
            param($set)
            $size = [long]$set.Length
            if ($size -le 1) { return $set[0] }
            $threshold = [long]4294967296 - ([long]4294967296 % $size)
            while ($true) {
                $rng.GetBytes($bytes)
                $value = [long][System.BitConverter]::ToUInt32($bytes, 0)
                if ($value -lt $threshold) { return $set[[int]($value % $size)] }
            }
        }

        $chars = New-Object System.Collections.ArrayList
        foreach ($set in $sets) { [void]$chars.Add((& $pickChar $set)) }

        while ($chars.Count -lt $Length) {
            [void]$chars.Add((& $pickChar $all))
        }

        # Melange Fisher-Yates pour que les premiers caracteres imposes ne soient
        # pas previsibles.
        for ($i = $chars.Count - 1; $i -gt 0; $i--) {
            $rng.GetBytes($bytes)
            $j = [int]([long][System.BitConverter]::ToUInt32($bytes, 0) % [long]($i + 1))
            $tmp = $chars[$i]
            $chars[$i] = $chars[$j]
            $chars[$j] = $tmp
        }

        return (-join $chars)
    } finally {
        if ($rng -and $rng.PSObject.Methods['Dispose']) { $rng.Dispose() }
    }
}

function Test-ADTPasswordComplexity {
<#
.SYNOPSIS
    Verifie qu un mot de passe satisfait la complexite Active Directory.
.DESCRIPTION
    Regle Microsoft : au moins trois des cinq categories (majuscule, minuscule,
    chiffre, caractere non alphanumerique, caractere Unicode hors categories
    precedentes), et longueur au moins egale au minimum du domaine.
    Le controle du nom de compte et du nom complet dans le mot de passe n est pas
    reproduit ici : il depend d un decoupage que seul le controleur applique.
.PARAMETER Password
    Mot de passe a verifier, en clair. N est jamais journalise.
.PARAMETER MinimumLength
    Longueur minimale exigee par la strategie.
.PARAMETER ComplexityEnabled
    Appliquer ou non la regle des trois categories.
.EXAMPLE
    Test-ADTPasswordComplexity -Password $clear -MinimumLength 12
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Password,
        [int]$MinimumLength = 7,
        [bool]$ComplexityEnabled = $true
    )
    $issues = New-Object System.Collections.ArrayList
    if ($Password.Length -lt $MinimumLength) {
        [void]$issues.Add(('Longueur {0} inferieure au minimum du domaine ({1}).' -f $Password.Length, $MinimumLength))
    }
    $categories = 0
    if ($Password -cmatch '[A-Z]') { $categories++ }
    if ($Password -cmatch '[a-z]') { $categories++ }
    if ($Password -match '[0-9]') { $categories++ }
    if ($Password -match '[^a-zA-Z0-9]') { $categories++ }
    if ($ComplexityEnabled -and $categories -lt 3) {
        [void]$issues.Add(('Complexite insuffisante : {0} categorie(s) sur les 3 exigees.' -f $categories))
    }
    New-Object PSObject -Property @{
        Valid      = ($issues.Count -eq 0)
        Categories = $categories
        Length     = $Password.Length
        Issues     = ($issues -join ' ')
    }
}


#--- ObjectStatus.ps1 ------------------------------------------------------

# Etat lisible d un objet de l annuaire, partage par les listes, la recherche et
# les fiches de proprietes pour qu une meme situation s affiche partout pareil.

function Test-ADTObjectIsContainer {
<#
.SYNOPSIS
    Indique si une classe d objet peut contenir d autres objets.
.EXAMPLE
    Test-ADTObjectIsContainer -ObjectClass 'organizationalUnit'
#>
    [CmdletBinding()]
    param([Parameter(Position = 0)][AllowEmptyString()][string]$ObjectClass)
    return (@('organizationalUnit', 'container', 'builtinDomain', 'domainDNS') -contains [string]$ObjectClass)
}

function Get-ADTObjectStatusText {
<#
.SYNOPSIS
    Resume l etat d un compte : actif, desactive, verrouille, expire.
.DESCRIPTION
    Les conteneurs et les groupes n ont pas d etat de compte : la fonction rend
    une chaine vide plutot qu un statut trompeur.
.EXAMPLE
    Get-ADTObjectStatusText -Object $user
#>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true, Position = 0)]$Object)
    $class = [string]$Object.ObjectClass
    if (@('user', 'computer') -notcontains $class) { return '' }

    $states = New-Object System.Collections.ArrayList
    if ($Object.Enabled) { [void]$states.Add('Actif') } else { [void]$states.Add('Desactive') }
    if ($Object.LockedOut) { [void]$states.Add('Verrouille') }
    if ($Object.AccountExpirationDate -and ([datetime]$Object.AccountExpirationDate) -lt (Get-Date)) { [void]$states.Add('Expire') }
    if ($Object.MustChangePassword) { [void]$states.Add('Mot de passe a changer') }
    return ($states -join ', ')
}

function Get-ADTRdnValue {
<#
.SYNOPSIS
    Valeur lisible du premier composant d un DN, sans son prefixe ni ses echappements.
.DESCRIPTION
    'CN=Cote\, Joel,OU=Employes,DC=contoso,DC=local' rend 'Cote, Joel'.
    Sert a afficher un groupe ou un gestionnaire sans imposer son DN complet.
.EXAMPLE
    Get-ADTRdnValue -DistinguishedName 'CN=GS-VPN,OU=Groupes,DC=contoso,DC=local'
#>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true, Position = 0)][AllowEmptyString()][string]$DistinguishedName)
    if (-not $DistinguishedName) { return '' }
    $rdn = $DistinguishedName
    for ($index = 0; $index -lt $DistinguishedName.Length; $index++) {
        if ($DistinguishedName[$index] -eq ',' -and ($index -eq 0 -or $DistinguishedName[$index - 1] -ne '\')) {
            $rdn = $DistinguishedName.Substring(0, $index)
            break
        }
    }
    $separator = $rdn.IndexOf('=')
    if ($separator -ge 0) { $rdn = $rdn.Substring($separator + 1) }
    # Les echappements RDN doivent etre defaits dans l ordre inverse de leur pose.
    foreach ($pair in @(',', '+', '"', '<', '>', ';', '=')) { $rdn = $rdn.Replace('\' + $pair, $pair) }
    $rdn = $rdn.Replace('\2f', '/').Replace('\20', ' ')
    $rdn = $rdn.Replace('\\', '\')
    return $rdn
}

function Get-ADTOperatorName {
<#
.SYNOPSIS
    Identite de l operateur courant, pour les traces et les documents produits.
.DESCRIPTION
    USERDOMAIN n est pas renseigne partout : sur un poste hors domaine ou sous
    PowerShell 7 multiplateforme, seul USERNAME l est. La fonction rend alors le
    seul nom d utilisateur plutot qu un '\' isole.
.EXAMPLE
    Get-ADTOperatorName
#>
    [CmdletBinding()]
    param()
    $domain = [string]$env:USERDOMAIN
    $user = [string]$env:USERNAME
    if (-not $user) { $user = [string]$env:USER }
    if ($domain -and $user) { return ('{0}\{1}' -f $domain, $user) }
    if ($user) { return $user }
    return 'compte inconnu'
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
    # Date de generation au format regional du poste, comme tout ce que PSADToolkit affiche.
    $summary += New-Object PSObject -Property @{ Indicateur = 'Genere le';                      Valeur = (Format-ADTDateTime -Value (Get-Date)) }
    $summary += New-Object PSObject -Property @{ Indicateur = 'Genere par';                     Valeur = (Get-ADTOperatorName) }

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


#--- Find-ADTDirectoryObject.ps1 -------------------------------------------

function Find-ADTDirectoryObject {
<#
.SYNOPSIS
    Recherche des utilisateurs, groupes, ordinateurs ou unites d organisation.
.DESCRIPTION
    Recherche par nom, sAMAccountName, UPN, nom affiche, courriel ou description.
    Par defaut la recherche est partielle et couvre tout le domaine ; -SearchBase
    la limite a une unite d organisation et a ses sous-unites, ce qui correspond
    a "rechercher dans l OU selectionnee" dans l interface.

    Le terme recherche est echappe avant d etre injecte dans le filtre LDAP :
    un utilisateur ne peut pas elargir sa recherche a tout l annuaire en saisissant
    une parenthese ou une etoile.
.PARAMETER SearchTerm
    Texte recherche. Les caracteres speciaux LDAP sont traites comme du texte.
.PARAMETER Type
    Classes a interroger : All, User, Group, Computer, OrganizationalUnit.
.PARAMETER SearchBase
    DN limitant la recherche. Vide = tout le domaine.
.PARAMETER Attribute
    Attributs interroges. Par defaut name, sAMAccountName, userPrincipalName,
    displayName, mail et description.
.PARAMETER Exact
    Exige une correspondance exacte au lieu d une correspondance partielle.
.PARAMETER SizeLimit
    Plafond de resultats, 200 par defaut. 0 = sans limite.
.EXAMPLE
    Find-ADTDirectoryObject -SearchTerm 'tremblay'
.EXAMPLE
    Find-ADTDirectoryObject -SearchTerm 'GS-' -Type Group -SearchBase 'OU=Groupes,DC=contoso,DC=local'
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()][string]$SearchTerm,

        [ValidateSet('All', 'User', 'Group', 'Computer', 'OrganizationalUnit')]
        [string[]]$Type = @('All'),

        [string]$SearchBase,
        [string[]]$Attribute,
        [switch]$Exact,
        [int]$SizeLimit = 200,
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential,
        [string]$LogPath
    )

    begin {
        $common = Initialize-ADTConnection -Server $Server -Credential $Credential -LogPath $LogPath
        $lockoutTicks = [long]0
        try { $lockoutTicks = [long](Get-ADTNativePasswordPolicy @common).LockoutDurationTicks } catch { $lockoutTicks = [long]0 }
    }

    process {
        $term = $SearchTerm.Trim()
        if (-not $term) { throw 'Terme de recherche vide.' }

        if (-not $Attribute -or @($Attribute).Count -eq 0) {
            $Attribute = @('name', 'sAMAccountName', 'userPrincipalName', 'displayName', 'mail', 'description')
        }

        # L echappement precede l ajout des jokers : sinon une etoile saisie par
        # l operateur deviendrait un joker LDAP et la recherche remonterait tout.
        $escaped = ConvertTo-ADTLdapValue $term
        $pattern = $escaped
        if (-not $Exact) { $pattern = '*' + $escaped + '*' }

        $conditions = New-Object System.Collections.ArrayList
        foreach ($name in $Attribute) {
            $clean = ([string]$name).Trim()
            if (-not $clean) { continue }
            if ($clean -notmatch '^[A-Za-z][A-Za-z0-9-]*$') { throw ('Nom d attribut LDAP invalide : {0}' -f $clean) }
            [void]$conditions.Add('(' + $clean + '=' + $pattern + ')')
        }
        if (-not $conditions.Count) { throw 'Aucun attribut a interroger.' }

        $classes = New-Object System.Collections.ArrayList
        foreach ($item in $Type) {
            if ($item -eq 'All') {
                foreach ($class in @('User', 'Group', 'Computer', 'OrganizationalUnit')) {
                    $clause = Get-ADTConsoleClassFilter -Type $class
                    if (-not $classes.Contains($clause)) { [void]$classes.Add($clause) }
                }
                continue
            }
            $clause = Get-ADTConsoleClassFilter -Type $item
            if (-not $classes.Contains($clause)) { [void]$classes.Add($clause) }
        }
        $classFilter = '(|' + ($classes -join '') + ')'
        if ($classes.Count -eq 1) { $classFilter = [string]$classes[0] }

        $filter = '(&' + $classFilter + '(|' + ($conditions -join '') + '))'

        $found = @(Search-ADTDirectoryEntry -LDAPFilter $filter -SearchBase $SearchBase -Scope Subtree `
                -SizeLimit $SizeLimit -LockoutDurationTicks $lockoutTicks @common)

        $scope = 'Domaine complet'
        if ($SearchBase) { $scope = $SearchBase }
        Write-ADTLog -Level 'INFO' -Message ('Recherche annuaire "{0}" dans {1} : {2} resultat(s).' -f $term, $scope, $found.Count)
        if ($SizeLimit -gt 0 -and $found.Count -ge $SizeLimit) {
            Write-Warning ('Recherche tronquee a {0} resultats. Preciser le terme ou limiter a une OU.' -f $SizeLimit)
        }

        foreach ($item in ($found | Sort-Object -Property @{ Expression = { [string]$_.ObjectClass } }, @{ Expression = { [string]$_.Name } })) {
            $row = New-Object PSObject -Property @{
                Name              = [string]$item.Name
                ObjectType        = [string]$item.ObjectType
                SamAccountName    = [string]$item.SamAccountName
                UserPrincipalName = [string]$item.UserPrincipalName
                Description       = [string]$item.Description
                Status            = (Get-ADTObjectStatusText -Object $item)
                Enabled           = $item.Enabled
                LockedOut         = $item.LockedOut
                LastLogonDate     = $item.LastLogonDate
                Container         = (Get-ADTParentDistinguishedName -DistinguishedName ([string]$item.DistinguishedName))
                ObjectClass       = [string]$item.ObjectClass
                DistinguishedName = [string]$item.DistinguishedName
                IsContainer       = (Test-ADTObjectIsContainer -ObjectClass ([string]$item.ObjectClass))
            }
            $row | Select-Object Name, ObjectType, SamAccountName, UserPrincipalName, Description, Status,
            Enabled, LockedOut, LastLogonDate, Container, ObjectClass, DistinguishedName, IsContainer
        }
    }
}


#--- Get-ADTDirectoryChild.ps1 ---------------------------------------------

function Get-ADTDirectoryChild {
<#
.SYNOPSIS
    Liste le contenu direct d une unite d organisation ou d un conteneur.
.DESCRIPTION
    Equivalent du volet droit de la console Utilisateurs et ordinateurs Active
    Directory : les objets immediatement contenus dans le conteneur designe, sans
    descendre dans les sous-unites. La lecture passe par LDAP, sans RSAT.

    Les conteneurs sont rendus en premier, puis les autres objets par nom, dans
    l ordre de tri de la culture de la machine.
.PARAMETER Path
    DN du conteneur a lire. Ex : 'OU=Employes,DC=contoso,DC=local'
.PARAMETER Type
    Classes a retenir : All, Container, User, Group, Computer. Cumulables.
.PARAMETER SizeLimit
    Plafond de resultats. 0 = sans limite. Protege l interface d une OU contenant
    des dizaines de milliers d objets.
.PARAMETER Server
    Controleur de domaine. Vide = detection automatique.
.PARAMETER Credential
    Compte autre que celui de la session Windows.
.EXAMPLE
    Get-ADTDirectoryChild -Path 'OU=Employes,DC=contoso,DC=local'
.EXAMPLE
    Get-ADTDirectoryChild -Path 'OU=Employes,DC=contoso,DC=local' -Type User,Group | Format-Table Name, ObjectType, Status
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipelineByPropertyName = $true)]
        [Alias('DistinguishedName', 'SearchBase')]
        [string]$Path,

        [ValidateSet('All', 'Container', 'User', 'Group', 'Computer')]
        [string[]]$Type = @('All'),

        [int]$SizeLimit = 0,
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential,
        [string]$LogPath
    )

    begin {
        $common = Initialize-ADTConnection -Server $Server -Credential $Credential -LogPath $LogPath
        $policy = $null
        try { $policy = Get-ADTNativePasswordPolicy @common } catch { $policy = $null }
        $lockoutTicks = [long]0
        if ($policy) { $lockoutTicks = [long]$policy.LockoutDurationTicks }
    }

    process {
        $include = New-Object System.Collections.ArrayList
        foreach ($item in $Type) {
            switch ($item) {
                'All' {
                    foreach ($class in @('organizationalUnit', 'container', 'user', 'group', 'computer')) {
                        if (-not $include.Contains($class)) { [void]$include.Add($class) }
                    }
                }
                'Container' {
                    foreach ($class in @('organizationalUnit', 'container')) {
                        if (-not $include.Contains($class)) { [void]$include.Add($class) }
                    }
                }
                'User' { if (-not $include.Contains('user')) { [void]$include.Add('user') } }
                'Group' { if (-not $include.Contains('group')) { [void]$include.Add('group') } }
                'Computer' { if (-not $include.Contains('computer')) { [void]$include.Add('computer') } }
            }
        }

        $children = @(Get-ADTNativeContainerChild -DistinguishedName $Path -Include ([string[]]@($include)) `
                -SizeLimit $SizeLimit -LockoutDurationTicks $lockoutTicks @common)

        $rows = @()
        foreach ($child in $children) {
            $rows += New-Object PSObject -Property @{
                Name              = [string]$child.Name
                ObjectType        = [string]$child.ObjectType
                SamAccountName    = [string]$child.SamAccountName
                UserPrincipalName = [string]$child.UserPrincipalName
                Description       = [string]$child.Description
                Status            = (Get-ADTObjectStatusText -Object $child)
                Enabled           = $child.Enabled
                LockedOut         = $child.LockedOut
                LastLogonDate     = $child.LastLogonDate
                whenCreated       = $child.whenCreated
                ObjectClass       = [string]$child.ObjectClass
                DistinguishedName = [string]$child.DistinguishedName
                IsContainer       = (Test-ADTObjectIsContainer -ObjectClass ([string]$child.ObjectClass))
            }
        }

        $sorted = @($rows | Sort-Object -Property @{ Expression = { if ($_.IsContainer) { 0 } else { 1 } } }, @{ Expression = { [string]$_.Name } })
        foreach ($row in $sorted) {
            $row | Select-Object Name, ObjectType, SamAccountName, UserPrincipalName, Description, Status,
            Enabled, LockedOut, LastLogonDate, whenCreated, ObjectClass, DistinguishedName, IsContainer
        }
    }
}


#--- Get-ADTGroupMember.ps1 ------------------------------------------------

function Get-ADTGroupMember {
<#
.SYNOPSIS
    Liste les membres d un groupe de securite ou de distribution.
.DESCRIPTION
    La lecture part de memberOf plutot que de l attribut member du groupe :
    au-dela d environ 1500 entrees, member est renvoye par tranches par le
    controleur et une lecture naive perdrait des membres sans le signaler.
    Le groupe principal (Utilisateurs du domaine par defaut) n apparait dans
    aucun des deux attributs : il est ajoute a partir de primaryGroupID.

    Avec -Recursive, les membres des groupes imbriques sont inclus.
.PARAMETER Identity
    Groupe : nom affiche, sAMAccountName, DN ou SID.
.PARAMETER Recursive
    Inclut les membres des groupes imbriques.
.PARAMETER IncludeGroup
    Conserve les groupes membres dans le resultat. Par defaut, seuls les comptes
    sont rendus, ce qui correspond a ce que l on veut appliquer en lot.
.EXAMPLE
    Get-ADTGroupMember -Identity 'GS-VPN'
.EXAMPLE
    Get-ADTGroupMember -Identity 'GS-Comptabilite' -Recursive | Select-Object SamAccountName, Status
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('Group', 'GroupName')]
        [string[]]$Identity,

        [switch]$Recursive,
        [switch]$IncludeGroup,
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential,
        [string]$LogPath
    )

    begin {
        $common = Initialize-ADTConnection -Server $Server -Credential $Credential -LogPath $LogPath
        $lockoutTicks = [long]0
        try { $lockoutTicks = [long](Get-ADTNativePasswordPolicy @common).LockoutDurationTicks } catch { $lockoutTicks = [long]0 }
    }

    process {
        foreach ($id in $Identity) {
            if (-not $id) { continue }
            $group = Resolve-ADTConsoleObject -Identity $id -ObjectFilter (Get-ADTConsoleClassFilter -Type Group) @common
            $groupDN = [string]$group.DistinguishedName
            $groupName = [string]$group.Name

            $members = @(Get-ADTNativeDirectMember -GroupDN $groupDN -Recursive:$Recursive -LockoutDurationTicks $lockoutTicks @common)
            foreach ($member in ($members | Sort-Object -Property @{ Expression = { [string]$_.Name } })) {
                if (-not $IncludeGroup -and [string]$member.ObjectClass -eq 'group') { continue }
                $row = New-Object PSObject -Property @{
                    GroupName         = $groupName
                    GroupDN           = $groupDN
                    Name              = [string]$member.Name
                    SamAccountName    = [string]$member.SamAccountName
                    UserPrincipalName = [string]$member.UserPrincipalName
                    ObjectType        = [string]$member.ObjectType
                    ObjectClass       = [string]$member.ObjectClass
                    Department        = [string]$member.Department
                    Title             = [string]$member.Title
                    Status            = (Get-ADTObjectStatusText -Object $member)
                    Enabled           = $member.Enabled
                    LockedOut         = $member.LockedOut
                    LastLogonDate     = $member.LastLogonDate
                    DistinguishedName = [string]$member.DistinguishedName
                }
                $row | Select-Object GroupName, Name, SamAccountName, UserPrincipalName, ObjectType, Department,
                Title, Status, Enabled, LockedOut, LastLogonDate, ObjectClass, DistinguishedName, GroupDN
            }
        }
    }
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


#--- Get-ADTObjectProperty.ps1 ---------------------------------------------

function Get-ADTObjectProperty {
<#
.SYNOPSIS
    Fiche complete d un objet Active Directory, pour la feuille de proprietes.
.DESCRIPTION
    Lit en une fois tous les attributs presentes dans les sections General,
    Compte, Organisation, Groupes, Profil et Horaires de connexion, et y ajoute
    les valeurs calculees : etat du compte, horaires en clair, appartenances
    resolues en noms lisibles, protection contre la suppression accidentelle.

    Les horaires de connexion sont convertis en heure locale de la machine, comme
    le fait la console Microsoft : l attribut logonHours est stocke en temps
    universel dans l annuaire.
.PARAMETER Identity
    DN, sAMAccountName, UPN, SID ou nom affiche de l objet.
.PARAMETER SkipDeletionProtection
    N interroge pas le descripteur de securite. Utile lorsque le compte n a pas
    le droit de lire les autorisations, ou pour accelerer un affichage en lot.
.EXAMPLE
    Get-ADTObjectProperty -Identity 'jcote'
.EXAMPLE
    Get-ADTObjectProperty -Identity 'OU=Employes,DC=contoso,DC=local' | Format-List
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('DistinguishedName', 'SamAccountName')]
        [string[]]$Identity,

        [switch]$SkipDeletionProtection,
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential,
        [string]$LogPath
    )

    begin {
        $common = Initialize-ADTConnection -Server $Server -Credential $Credential -LogPath $LogPath
        $policy = $null
        try { $policy = Get-ADTNativePasswordPolicy @common } catch { $policy = $null }
        $lockoutTicks = [long]0
        if ($policy) { $lockoutTicks = [long]$policy.LockoutDurationTicks }
    }

    process {
        foreach ($id in $Identity) {
            if (-not $id) { continue }
            $item = Resolve-ADTConsoleObject -Identity $id -Detail -LockoutDurationTicks $lockoutTicks @common

            $mask = ConvertFrom-ADTLogonHoursByte -Byte $item.LogonHours
            $restricted = ($mask -ne ('1' * 168))

            $groupNames = New-Object System.Collections.ArrayList
            foreach ($groupDN in @($item.MemberOf)) {
                if (-not $groupDN) { continue }
                [void]$groupNames.Add((Get-ADTRdnValue -DistinguishedName ([string]$groupDN)))
            }

            $protected = $null
            if (-not $SkipDeletionProtection) {
                try { $protected = Get-ADTNativeDeletionProtection -DistinguishedName ([string]$item.DistinguishedName) @common }
                catch { $protected = $null }
            }

            $expiresOn = $null
            if ($item.AccountExpirationDate) {
                # accountExpires designe l instant ou le compte cesse d etre
                # utilisable. La console Microsoft affiche le dernier jour ouvert.
                $expiresOn = ([datetime]$item.AccountExpirationDate).AddSeconds(-1).Date
            }

            $output = New-Object PSObject -Property @{
                Name                    = [string]$item.Name
                DisplayName             = [string]$item.DisplayName
                ObjectClass             = [string]$item.ObjectClass
                ObjectType              = [string]$item.ObjectType
                DistinguishedName       = [string]$item.DistinguishedName
                Container               = (Get-ADTParentDistinguishedName -DistinguishedName ([string]$item.DistinguishedName))
                SamAccountName          = [string]$item.SamAccountName
                UserPrincipalName       = [string]$item.UserPrincipalName
                SID                     = [string]$item.SID
                GivenName               = [string]$item.GivenName
                Surname                 = [string]$item.Surname
                Initials                = [string]$item.Initials
                Description             = [string]$item.Description
                EmailAddress            = [string]$item.EmailAddress
                OfficePhone             = [string]$item.OfficePhone
                MobilePhone             = [string]$item.MobilePhone
                Office                  = [string]$item.Office
                Title                   = [string]$item.Title
                Department              = [string]$item.Department
                Company                 = [string]$item.Company
                Manager                 = [string]$item.Manager
                ManagedBy               = [string]$item.ManagedBy
                StreetAddress           = [string]$item.StreetAddress
                City                    = [string]$item.City
                State                   = [string]$item.State
                PostalCode              = [string]$item.PostalCode
                Country                 = [string]$item.Country
                EmployeeID              = [string]$item.EmployeeID
                Notes                   = [string]$item.Notes
                HomeDirectory           = [string]$item.HomeDirectory
                HomeDrive               = [string]$item.HomeDrive
                ProfilePath             = [string]$item.ProfilePath
                ScriptPath              = [string]$item.ScriptPath
                Enabled                 = $item.Enabled
                LockedOut               = $item.LockedOut
                Status                  = (Get-ADTObjectStatusText -Object $item)
                MustChangePassword      = $item.MustChangePassword
                CannotChangePassword    = $item.CannotChangePassword
                PasswordNeverExpires    = $item.PasswordNeverExpires
                PasswordNotRequired     = $item.PasswordNotRequired
                SmartcardLogonRequired  = $item.SmartcardLogonRequired
                AccountNotDelegated     = $item.AccountNotDelegated
                DoesNotRequirePreAuth   = $item.DoesNotRequirePreAuth
                UserAccountControl      = $item.UserAccountControl
                PasswordLastSet         = $item.PasswordLastSet
                LastLogonDate           = $item.LastLogonDate
                AccountExpirationDate   = $item.AccountExpirationDate
                AccountExpiresEndOfDay  = $expiresOn
                whenCreated             = $item.whenCreated
                whenChanged             = $item.whenChanged
                LogonHoursMask          = $mask
                LogonHoursText          = (ConvertTo-ADTLogonHoursText -Mask $mask)
                LogonHoursRestricted    = $restricted
                MemberOf                = @($item.MemberOf)
                MemberOfNames           = ([string[]]@($groupNames))
                GroupScope              = [string]$item.GroupScope
                GroupCategory           = [string]$item.GroupCategory
                OperatingSystem         = [string]$item.OperatingSystem
                OperatingSystemVersion  = [string]$item.OperatingSystemVersion
                DnsHostName             = [string]$item.DnsHostName
                ProtectedFromDeletion   = $protected
                PasswordPolicySource    = ''
                MinimumPasswordLength   = 0
            }
            if ($policy) {
                $output.PasswordPolicySource = [string]$policy.Source
                $output.MinimumPasswordLength = [int]$policy.MinimumPasswordLength
            }
            $output
        }
    }
}


#--- Get-ADTPasswordPolicy.ps1 ---------------------------------------------

function Get-ADTPasswordPolicy {
<#
.SYNOPSIS
    Lit la strategie de mot de passe et de verrouillage applicable.
.DESCRIPTION
    Rend la strategie par defaut du domaine. Lorsqu un utilisateur est precise et
    que le domaine expose les strategies affinees (niveau fonctionnel 2008 et
    superieur), la strategie reellement applicable a ce compte est utilisee et la
    propriete Source l indique.

    Le generateur de mots de passe s appuie sur ces valeurs pour proposer une
    longueur et une complexite compatibles avec le domaine.
.PARAMETER Identity
    Compte dont on veut la strategie applicable. Facultatif.
.EXAMPLE
    Get-ADTPasswordPolicy
.EXAMPLE
    Get-ADTPasswordPolicy -Identity 'jcote' | Format-List
#>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('SamAccountName', 'User')]
        [string]$Identity,

        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential,
        [string]$LogPath
    )

    begin { $common = Initialize-ADTConnection -Server $Server -Credential $Credential -LogPath $LogPath }

    process {
        $userDN = ''
        if ($Identity) {
            $user = Resolve-ADTConsoleObject -Identity $Identity -ObjectFilter (Get-ADTConsoleClassFilter -Type User) @common
            $userDN = [string]$user.DistinguishedName
        }
        $policy = Get-ADTNativePasswordPolicy -UserDistinguishedName $userDN @common
        $policy | Select-Object DomainName, MinimumPasswordLength, ComplexityEnabled, PasswordHistoryLength,
        MaximumPasswordAgeDays, MinimumPasswordAgeDays, LockoutThreshold, LockoutDurationMinutes, Source
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


#--- Get-ADTUserLogonHours.ps1 ---------------------------------------------

function Get-ADTUserLogonHours {
<#
.SYNOPSIS
    Lit les horaires de connexion autorises d un ou plusieurs comptes.
.DESCRIPTION
    L attribut logonHours est stocke en temps universel dans l annuaire. Cette
    fonction le convertit en HEURE LOCALE de la machine, comme le fait la console
    Microsoft, et rend a la fois le masque brut de 168 caracteres et un resume
    lisible dans la langue et le format horaire du poste.

    Un compte sans restriction n a pas d attribut logonHours : le masque rendu est
    alors entierement autorise et Restricted vaut faux.
.PARAMETER Identity
    Comptes vises : sAMAccountName, UPN, DN ou SID.
.EXAMPLE
    Get-ADTUserLogonHours -Identity 'jcote'
.EXAMPLE
    Get-ADTGroupMember -Identity 'GS-Ventes' | Get-ADTUserLogonHours | Format-Table SamAccountName, Summary
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('SamAccountName', 'User', 'DistinguishedName')]
        [string[]]$Identity,

        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential,
        [string]$LogPath
    )

    begin { $common = Initialize-ADTConnection -Server $Server -Credential $Credential -LogPath $LogPath }

    process {
        foreach ($id in $Identity) {
            if (-not $id) { continue }
            $sam = $id
            try {
                $user = Resolve-ADTConsoleObject -Identity $id -ObjectFilter (Get-ADTConsoleClassFilter -Type User) -Detail @common
                $sam = [string]$user.SamAccountName
                $mask = ConvertFrom-ADTLogonHoursByte -Byte $user.LogonHours
                $allowed = 0
                for ($slot = 0; $slot -lt 168; $slot++) { if ($mask[$slot] -eq '1') { $allowed++ } }
                $row = New-Object PSObject -Property @{
                    SamAccountName    = $sam
                    Name              = [string]$user.Name
                    Mask              = $mask
                    Summary           = (ConvertTo-ADTLogonHoursText -Mask $mask)
                    AllowedHours      = $allowed
                    Restricted        = ($mask -ne ('1' * 168))
                    OffsetHours       = (Get-ADTLogonHoursOffset)
                    DistinguishedName = [string]$user.DistinguishedName
                    Error             = ''
                }
                $row | Select-Object SamAccountName, Name, Summary, AllowedHours, Restricted, Mask, OffsetHours, DistinguishedName, Error
            } catch {
                $row = New-Object PSObject -Property @{
                    SamAccountName    = $sam
                    Name              = ''
                    Mask              = ''
                    Summary           = ''
                    AllowedHours      = 0
                    Restricted        = $false
                    OffsetHours       = (Get-ADTLogonHoursOffset)
                    DistinguishedName = ''
                    Error             = $_.Exception.Message
                }
                $row | Select-Object SamAccountName, Name, Summary, AllowedHours, Restricted, Mask, OffsetHours, DistinguishedName, Error
            }
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
.PARAMETER Path
    Fichier CSV a importer. Colonnes obligatoires : GivenName et Surname.
.PARAMETER DefaultOU
    OU de destination. Prioritaire sur une colonne OU presente dans le CSV.
.PARAMETER PasswordReportPath
    Fichier CSV recevant les mots de passe generes. Il contient des mots de passe en
    clair : choisir un emplacement dont les autorisations conviennent.
.EXAMPLE
    Import-ADTUserFromCsv -Path .\nouveaux-employes.csv -DefaultOU 'OU=Employes,DC=contoso,DC=local' -WhatIf
.EXAMPLE
    Import-ADTUserFromCsv -Path .\arrivees.csv -DefaultOU 'OU=Employes,DC=contoso,DC=local' -CreateDepartmentOUs -SkipExisting
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


#--- Move-ADTObject.ps1 ----------------------------------------------------

function Move-ADTObject {
<#
.SYNOPSIS
    Deplace des objets Active Directory vers une autre unite d organisation.
.DESCRIPTION
    Deplace utilisateurs, groupes, ordinateurs et unites d organisation, un par un
    ou en lot. Le conteneur de destination est verifie avant toute ecriture.

    Deplacer une unite d organisation dans elle-meme ou dans l une de ses propres
    sous-unites est refuse : Active Directory rejetterait l operation avec un
    message peu parlant, et le controle est immediat.

    Un objet protege contre la suppression accidentelle se deplace normalement :
    la protection porte sur la suppression, pas sur le deplacement. En revanche,
    la console Microsoft protege aussi le conteneur parent ; un refus d acces sur
    le deplacement vient generalement de la delegation, pas de cette protection.
.PARAMETER Identity
    Objets a deplacer : DN, sAMAccountName, nom ou SID.
.PARAMETER TargetPath
    DN de l unite d organisation ou du conteneur de destination.
.EXAMPLE
    Move-ADTObject -Identity 'jcote' -TargetPath 'OU=Desactives,DC=contoso,DC=local' -WhatIf
.EXAMPLE
    Get-ADTGroupMember -Identity 'GS-Stagiaires' | Move-ADTObject -TargetPath 'OU=Stagiaires,DC=contoso,DC=local'
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('SamAccountName', 'DistinguishedName')]
        [string[]]$Identity,

        [Parameter(Mandatory = $true, Position = 1)]
        [Alias('Destination', 'Path')]
        [string]$TargetPath,

        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential,
        [string]$LogPath
    )

    begin {
        $common = Initialize-ADTConnection -Server $Server -Credential $Credential -LogPath $LogPath
        $destination = Resolve-ADTConsoleObject -Identity $TargetPath @common
        if (-not (Test-ADTObjectIsContainer -ObjectClass ([string]$destination.ObjectClass))) {
            throw ('La destination n est pas un conteneur : {0} ({1}).' -f $TargetPath, $destination.ObjectType)
        }
        $destinationDN = [string]$destination.DistinguishedName
    }

    process {
        foreach ($id in $Identity) {
            if (-not $id) { continue }
            $label = $id
            $status = 'Echec'
            $errorText = ''
            $sourceDN = ''
            try {
                $item = Resolve-ADTConsoleObject -Identity $id @common
                $sourceDN = [string]$item.DistinguishedName
                $label = [string]$item.SamAccountName
                if (-not $label) { $label = [string]$item.Name }

                $currentParent = Get-ADTParentDistinguishedName -DistinguishedName $sourceDN
                if ($currentParent -eq $destinationDN) { throw 'L objet est deja dans ce conteneur.' }
                if ($destinationDN -eq $sourceDN -or $destinationDN.EndsWith(',' + $sourceDN)) {
                    throw 'Impossible de deplacer un conteneur dans lui-meme ou dans l une de ses sous-unites.'
                }

                if ($PSCmdlet.ShouldProcess($label, ('Deplacer vers {0}' -f $destinationDN))) {
                    Move-ADTNativeObject -Identity $sourceDN -TargetPath $destinationDN -ErrorAction Stop @common
                    $status = 'Deplace'
                    Write-ADTLog -Level 'SUCCESS' -Message ('{0} deplace de {1} vers {2}' -f $label, $currentParent, $destinationDN)
                } else {
                    $status = 'Simulation'
                }
            } catch {
                $errorText = $_.Exception.Message
                Write-ADTLog -Level 'ERROR' -Message ('Deplacement de {0} echoue : {1}' -f $label, $errorText)
            }
            $row = New-Object PSObject -Property @{
                Name = $label; Status = $status; Source = $sourceDN; Destination = $destinationDN; Error = $errorText
            }
            $row | Select-Object Name, Status, Source, Destination, Error
        }
    }
}


#--- New-ADTCredentialDocument.ps1 -----------------------------------------

function New-ADTCredentialDocument {
<#
.SYNOPSIS
    Produit un document HTML de remise des identifiants a un employe.
.DESCRIPTION
    Genere une fiche imprimable contenant le nom de l employe, son identifiant,
    son UPN, son domaine et son mot de passe temporaire, avec les consignes de
    premiere connexion.

    Cette generation est une action volontaire : elle ne se declenche jamais
    automatiquement a la creation d un compte ou a la reinitialisation d un mot
    de passe. C est l administrateur qui la demande, et qui choisit ou le fichier
    est ecrit.

    Le fichier contient un mot de passe en clair. Il est cree avec les seules
    autorisations heritees du dossier choisi : deposer ce dossier sur un partage
    largement accessible reviendrait a publier les mots de passe. Le journal du
    module ne consigne que le compte concerne et le chemin du document, jamais le
    mot de passe lui-meme.

    Accepte la sortie de New-ADTUser et de Set-ADTUserPassword par le pipeline.
.PARAMETER SamAccountName
    Identifiant de connexion.
.PARAMETER Password
    Mot de passe temporaire a imprimer.
.PARAMETER DisplayName
    Nom complet de l employe.
.PARAMETER UserPrincipalName
    UPN du compte.
.PARAMETER Domain
    Nom du domaine. Lu dans l annuaire si absent et si -NoDirectoryLookup n est pas utilise.
.PARAMETER Path
    Fichier HTML a ecrire. Un dossier DEJA EXISTANT, ou un chemin se terminant par
    un separateur, est traite comme un dossier : le nom du fichier est alors
    derive de l identifiant et de l horodatage. Tout autre chemin designe le
    fichier lui-meme, dont les dossiers manquants sont crees.
.PARAMETER Force
    Ecrase un fichier existant.
.PARAMETER NoDirectoryLookup
    N interroge pas l annuaire pour completer les champs manquants.
.EXAMPLE
    Set-ADTUserPassword -Identity 'jcote' | New-ADTCredentialDocument -Path 'C:\Remises'
.EXAMPLE
    New-ADTCredentialDocument -SamAccountName 'jcote' -Password 'Exemple123!' -DisplayName 'Joel Cote' -Path 'C:\Remises\jcote.html' -NoDirectoryLookup
#>
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'Le document remis a l employe doit contenir le mot de passe temporaire en clair; sa protection releve du choix du dossier de destination.')]
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('Identity', 'User')]
        [string]$SamAccountName,

        [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)]
        [string]$Password,

        [Parameter(ValueFromPipelineByPropertyName = $true)][string]$DisplayName,
        [Parameter(ValueFromPipelineByPropertyName = $true)][string]$UserPrincipalName,
        [Parameter(ValueFromPipelineByPropertyName = $true)][string]$Domain,
        [Parameter(ValueFromPipelineByPropertyName = $true)][string]$DistinguishedName,
        [Parameter(ValueFromPipelineByPropertyName = $true)][string]$EmailAddress,

        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Title = 'Vos identifiants de connexion',
        [string]$Note,
        [switch]$Force,
        [switch]$NoDirectoryLookup,
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential,
        [string]$LogPath
    )

    begin {
        $common = @{}
        if (-not $NoDirectoryLookup) {
            try { $common = Initialize-ADTConnection -Server $Server -Credential $Credential -LogPath $LogPath }
            catch {
                Write-Warning ('Annuaire non joignable, document produit avec les seules valeurs fournies. {0}' -f $_.Exception.Message)
                $NoDirectoryLookup = $true
            }
        } elseif ($LogPath) {
            $script:ADTLogPath = $LogPath
        }
    }

    process {
        if (-not $Password) { throw 'Aucun mot de passe a inscrire dans le document.' }

        $account = $null
        if (-not $NoDirectoryLookup -and (-not $DisplayName -or -not $UserPrincipalName -or -not $Domain)) {
            try { $account = Resolve-ADTConsoleObject -Identity $SamAccountName -ObjectFilter (Get-ADTConsoleClassFilter -Type User) @common }
            catch { Write-Warning ('Compte {0} non relu dans l annuaire : {1}' -f $SamAccountName, $_.Exception.Message) }
        }
        if ($account) {
            if (-not $DisplayName) { $DisplayName = [string]$account.DisplayName }
            if (-not $UserPrincipalName) { $UserPrincipalName = [string]$account.UserPrincipalName }
            if (-not $DistinguishedName) { $DistinguishedName = [string]$account.DistinguishedName }
            if (-not $EmailAddress) { $EmailAddress = [string]$account.EmailAddress }
        }
        if (-not $Domain -and $UserPrincipalName -and $UserPrincipalName.Contains('@')) {
            $Domain = $UserPrincipalName.Substring($UserPrincipalName.IndexOf('@') + 1)
        }
        if (-not $DisplayName) { $DisplayName = $SamAccountName }

        $target = $Path
        $isDirectory = (Test-Path -LiteralPath $Path -PathType Container)
        if ($isDirectory -or $Path.EndsWith('\') -or $Path.EndsWith('/')) {
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $target = Join-Path -Path $Path -ChildPath ('identifiants-' + (ConvertTo-ADTAsciiString -Text $SamAccountName) + '-' + $stamp + '.html')
        }
        $folder = Split-Path -Parent $target
        if ($folder -and -not (Test-Path -LiteralPath $folder)) {
            New-Item -Path $folder -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }
        if ((Test-Path -LiteralPath $target) -and -not $Force) {
            throw ('Le fichier existe deja : {0}. Utiliser -Force pour l ecraser.' -f $target)
        }

        $status = 'Echec'
        $errorText = ''
        if ($PSCmdlet.ShouldProcess($target, ('Ecrire le document de remise des identifiants de {0}' -f $SamAccountName))) {
            try {
                $rows = @()
                $rows += New-Object PSObject -Property @{ Label = 'Nom'; Value = $DisplayName }
                $rows += New-Object PSObject -Property @{ Label = 'Identifiant de connexion'; Value = $SamAccountName }
                if ($UserPrincipalName) { $rows += New-Object PSObject -Property @{ Label = 'Nom d utilisateur principal (UPN)'; Value = $UserPrincipalName } }
                if ($Domain) { $rows += New-Object PSObject -Property @{ Label = 'Domaine'; Value = $Domain } }
                if ($EmailAddress) { $rows += New-Object PSObject -Property @{ Label = 'Courriel'; Value = $EmailAddress } }
                $rows += New-Object PSObject -Property @{ Label = 'Mot de passe temporaire'; Value = $Password }

                $html = New-Object System.Text.StringBuilder
                [void]$html.AppendLine('<!DOCTYPE html><html lang="fr"><head><meta charset="utf-8" />')
                [void]$html.AppendLine('<title>' + [System.Security.SecurityElement]::Escape($Title) + '</title>')
                [void]$html.AppendLine('<style>')
                [void]$html.AppendLine('body { font-family: Segoe UI, Arial, sans-serif; margin: 32px; color: #1c1c1c; }')
                [void]$html.AppendLine('h1 { font-size: 20px; border-bottom: 3px solid #2f5d8f; padding-bottom: 8px; }')
                [void]$html.AppendLine('table { border-collapse: collapse; margin-top: 18px; font-size: 14px; }')
                [void]$html.AppendLine('th { background: #2f5d8f; color: #fff; text-align: left; padding: 8px 14px; width: 260px; }')
                [void]$html.AppendLine('td { border: 1px solid #c9d4e2; padding: 8px 14px; font-family: Consolas, monospace; }')
                [void]$html.AppendLine('.avis { margin-top: 22px; padding: 12px 14px; border-left: 4px solid #b3541e; background: #fdf3ec; font-size: 13px; }')
                [void]$html.AppendLine('.pied { margin-top: 26px; color: #666; font-size: 11px; }')
                [void]$html.AppendLine('</style></head><body>')
                [void]$html.AppendLine('<h1>' + [System.Security.SecurityElement]::Escape($Title) + '</h1>')
                [void]$html.AppendLine('<table>')
                foreach ($row in $rows) {
                    [void]$html.AppendLine('<tr><th>' + [System.Security.SecurityElement]::Escape([string]$row.Label) + '</th><td>' +
                        [System.Security.SecurityElement]::Escape([string]$row.Value) + '</td></tr>')
                }
                [void]$html.AppendLine('</table>')
                [void]$html.AppendLine('<div class="avis">Ce mot de passe est temporaire. Il doit etre change a la premiere ouverture de session et ne doit etre communique a personne. Detruire ce document une fois le mot de passe change.</div>')
                if ($Note) { [void]$html.AppendLine('<div class="avis">' + [System.Security.SecurityElement]::Escape($Note) + '</div>') }
                [void]$html.AppendLine('<div class="pied">Document genere le ' + [System.Security.SecurityElement]::Escape((Format-ADTDateTime -Value (Get-Date))) +
                    ' par ' + [System.Security.SecurityElement]::Escape((Get-ADTOperatorName)) + '.</div>')
                [void]$html.AppendLine('</body></html>')

                Set-Content -Path $target -Value $html.ToString() -Encoding UTF8 -ErrorAction Stop
                $status = 'Genere'
                # Le mot de passe ne figure jamais dans le journal, seulement le
                # fait qu un document a ete produit et ou.
                Write-ADTLog -Level 'INFO' -Message ('Document de remise genere pour {0} : {1}' -f $SamAccountName, $target)
            } catch {
                $errorText = $_.Exception.Message
                Write-ADTLog -Level 'ERROR' -Message ('Document de remise non genere pour {0} : {1}' -f $SamAccountName, $errorText)
            }
        } else {
            $status = 'Simulation'
        }

        $output = New-Object PSObject -Property @{
            SamAccountName = $SamAccountName; DisplayName = $DisplayName; Path = $target; Status = $status; Error = $errorText
        }
        $output | Select-Object SamAccountName, DisplayName, Path, Status, Error
    }
}


#--- New-ADTGroup.ps1 ------------------------------------------------------

function New-ADTGroup {
<#
.SYNOPSIS
    Cree un groupe de securite ou de distribution dans une unite d organisation.
.DESCRIPTION
    Reprend les choix de la boite "Nouvel objet - Groupe" de la console Microsoft :
    nom, nom anterieur a Windows 2000 (sAMAccountName), etendue et type de groupe.

    Le sAMAccountName est derive du nom lorsqu il n est pas impose : accents
    retires, caracteres non valides supprimes, longueur ramenee a 64 caracteres.
    Son unicite est verifiee avant la creation, ce qui evite un echec brut du
    controleur de domaine.

    Les membres initiaux peuvent etre fournis : chacun est ajoute apres la
    creation, et un ajout refuse n annule pas le groupe deja cree. Le statut
    Partiel signale ce cas.
.PARAMETER Path
    DN de l unite d organisation qui recevra le groupe.
.PARAMETER Name
    Nom du groupe.
.PARAMETER SamAccountName
    Nom anterieur a Windows 2000. Calcule a partir du nom si omis.
.PARAMETER Scope
    Global, DomainLocal ou Universal.
.PARAMETER Category
    Security ou Distribution.
.PARAMETER Member
    Membres a ajouter juste apres la creation.
.EXAMPLE
    New-ADTGroup -Path 'OU=Groupes,DC=contoso,DC=local' -Name 'GS-VPN' -WhatIf
.EXAMPLE
    New-ADTGroup -Path 'OU=Groupes,DC=contoso,DC=local' -Name 'GS-Ventes' -Scope Universal -Member 'jcote','mtremblay'
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()][string]$Path,

        [Parameter(Mandatory = $true, Position = 1, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()][string]$Name,

        [Parameter(ValueFromPipelineByPropertyName = $true)][string]$SamAccountName,
        [ValidateSet('Global', 'DomainLocal', 'Universal')][string]$Scope = 'Global',
        [ValidateSet('Security', 'Distribution')][string]$Category = 'Security',
        [string]$Description,
        [string[]]$Member,
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential,
        [string]$LogPath
    )

    begin { $common = Initialize-ADTConnection -Server $Server -Credential $Credential -LogPath $LogPath }

    process {
        $status = 'Echec'
        $errorText = ''
        $dn = ''
        $added = New-Object System.Collections.ArrayList
        $issues = New-Object System.Collections.ArrayList
        $sam = $SamAccountName

        try {
            if (-not $sam) {
                $sam = ConvertTo-ADTAsciiString -Text $Name
                if (-not $sam) { throw ('Impossible de deriver un identifiant de groupe a partir de "{0}". Preciser -SamAccountName.' -f $Name) }
            }
            if ($sam.Length -gt 64) { $sam = $sam.Substring(0, 64) }

            $container = Resolve-ADTConsoleObject -Identity $Path @common
            if (-not (Test-ADTObjectIsContainer -ObjectClass ([string]$container.ObjectClass))) {
                throw ('La destination n est pas un conteneur : {0}' -f $Path)
            }
            $containerDN = [string]$container.DistinguishedName

            $existing = @(Search-ADTDirectoryEntry -LDAPFilter ('(&(objectClass=group)(sAMAccountName=' + (ConvertTo-ADTLdapValue $sam) + '))') -SizeLimit 1 @common)
            if ($existing.Count) { throw ('Un groupe porte deja l identifiant {0} : {1}' -f $sam, [string]$existing[0].DistinguishedName) }

            if ($PSCmdlet.ShouldProcess($Name, ('Creer le groupe {0} {1} dans {2}' -f $Scope, $Category, $containerDN))) {
                $dn = New-ADTNativeGroup -Path $containerDN -Name $Name -SamAccountName $sam -Scope $Scope `
                    -Category $Category -Description $Description -ErrorAction Stop @common
                Write-ADTLog -Level 'SUCCESS' -Message ('Groupe cree : {0} ({1} {2}) dans {3}' -f $sam, $Scope, $Category, $containerDN)
                $status = 'Cree'

                foreach ($candidate in @($Member)) {
                    if (-not $candidate) { continue }
                    try {
                        $target = Resolve-ADTConsoleObject -Identity $candidate @common
                        Add-ADTNativeGroupMember -Identity $dn -Members ([string]$target.DistinguishedName) -ErrorAction Stop @common
                        [void]$added.Add([string]$target.SamAccountName)
                        Write-ADTLog -Level 'INFO' -Message ('{0} ajoute au groupe {1}' -f $candidate, $sam)
                    } catch {
                        [void]$issues.Add(('Membre {0} : {1}' -f $candidate, $_.Exception.Message))
                        Write-ADTLog -Level 'WARN' -Message ('Ajout de {0} au groupe {1} echoue : {2}' -f $candidate, $sam, $_.Exception.Message)
                    }
                }
                if ($issues.Count) { $status = 'Partiel'; $errorText = ($issues -join ' | ') }
            } else {
                $status = 'Simulation'
            }
        } catch {
            $errorText = $_.Exception.Message
            Write-ADTLog -Level 'ERROR' -Message ('Creation du groupe {0} echouee : {1}' -f $Name, $errorText)
        }

        $row = New-Object PSObject -Property @{
            Name = $Name; SamAccountName = $sam; GroupScope = $Scope; GroupCategory = $Category
            Status = $status; Members = ($added -join ';'); DistinguishedName = $dn; Error = $errorText
        }
        $row | Select-Object Name, SamAccountName, GroupScope, GroupCategory, Status, Members, DistinguishedName, Error
    }
}


#--- New-ADTLogonHourSchedule.ps1 ------------------------------------------

function New-ADTLogonHourSchedule {
<#
.SYNOPSIS
    Construit un horaire de connexion reutilisable, en heure locale.
.DESCRIPTION
    Un horaire est decrit par un masque de 168 caracteres 0 ou 1 : une heure de la
    semaine par caractere, du dimanche 00 h au samedi 23 h, en HEURE LOCALE.
    Set-ADTUserLogonHours applique ce masque a un ou plusieurs comptes ; la
    conversion vers le temps universel attendu par l annuaire est automatique.

    Plusieurs appels peuvent etre combines avec -BaseSchedule pour cumuler des
    plages : une plage de semaine puis une plage du samedi matin, par exemple.
.PARAMETER Day
    Jours vises : Sunday..Saturday ou 0..6. Vide = les sept jours.
.PARAMETER StartHour
    Premiere heure autorisee, de 0 a 23.
.PARAMETER EndHour
    Heure de fin, exclue, de 1 a 24. 18 signifie "jusqu a 18 h 00".
.PARAMETER AllowAll
    Autorise les 168 heures : aucune restriction.
.PARAMETER DenyAll
    Interdit toutes les heures. Le compte ne peut alors plus ouvrir de session.
.PARAMETER BaseSchedule
    Masque existant auquel ajouter la nouvelle plage.
.EXAMPLE
    New-ADTLogonHourSchedule -Day Monday,Tuesday,Wednesday,Thursday,Friday -StartHour 8 -EndHour 18
.EXAMPLE
    $semaine = New-ADTLogonHourSchedule -Day Monday,Tuesday,Wednesday,Thursday,Friday -StartHour 7 -EndHour 19
    New-ADTLogonHourSchedule -Day Saturday -StartHour 9 -EndHour 13 -BaseSchedule $semaine.Mask
#>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][object[]]$Day,
        [ValidateRange(0, 23)][int]$StartHour = 0,
        [ValidateRange(1, 24)][int]$EndHour = 24,
        [switch]$AllowAll,
        [switch]$DenyAll,
        [string]$BaseSchedule
    )

    $addition = New-ADTLogonHoursMask -Day $Day -StartHour $StartHour -EndHour $EndHour -AllowAll:$AllowAll -DenyAll:$DenyAll

    $mask = $addition
    if ($BaseSchedule) {
        if (-not (Test-ADTLogonHoursMask -Mask $BaseSchedule)) { throw 'BaseSchedule invalide : 168 caracteres 0 ou 1 attendus.' }
        if ($DenyAll) { $mask = $addition }
        else {
            $merged = New-Object System.Text.StringBuilder
            for ($slot = 0; $slot -lt 168; $slot++) {
                if ($BaseSchedule[$slot] -eq '1' -or $addition[$slot] -eq '1') { [void]$merged.Append('1') }
                else { [void]$merged.Append('0') }
            }
            $mask = $merged.ToString()
        }
    }

    $allowed = 0
    for ($slot = 0; $slot -lt 168; $slot++) { if ($mask[$slot] -eq '1') { $allowed++ } }

    $result = New-Object PSObject -Property @{
        Mask         = $mask
        Summary      = (ConvertTo-ADTLogonHoursText -Mask $mask)
        AllowedHours = $allowed
        Restricted   = ($mask -ne ('1' * 168))
        OffsetHours  = (Get-ADTLogonHoursOffset)
    }
    return ($result | Select-Object Mask, Summary, AllowedHours, Restricted, OffsetHours)
}


#--- New-ADTOrganizationalUnit.ps1 -----------------------------------------

function New-ADTOrganizationalUnit {
<#
.SYNOPSIS
    Cree une unite d organisation.
.DESCRIPTION
    Equivalent de "Nouvel objet - Unite d organisation" de la console Microsoft,
    y compris la case "Proteger le conteneur contre une suppression accidentelle",
    active par defaut comme dans la console.

    La protection est une entree de refus pour Tout le monde sur les droits de
    suppression. Si le compte utilise n a pas le droit de modifier les
    autorisations de l objet, l unite est tout de meme creee : le statut Partiel
    signale alors que la protection n a pas pu etre posee.
.PARAMETER Path
    DN du conteneur parent. Ex : 'DC=contoso,DC=local'
.PARAMETER Name
    Nom de l unite d organisation.
.PARAMETER NoProtection
    Ne pas proteger l unite contre la suppression accidentelle.
.EXAMPLE
    New-ADTOrganizationalUnit -Path 'DC=contoso,DC=local' -Name 'Employes' -WhatIf
.EXAMPLE
    New-ADTOrganizationalUnit -Path 'OU=Employes,DC=contoso,DC=local' -Name 'Comptabilite' -Description 'Service comptable'
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()][string]$Path,

        [Parameter(Mandatory = $true, Position = 1, ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()][string]$Name,

        [string]$Description,
        [switch]$NoProtection,
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential,
        [string]$LogPath
    )

    begin { $common = Initialize-ADTConnection -Server $Server -Credential $Credential -LogPath $LogPath }

    process {
        $status = 'Echec'
        $errorText = ''
        $dn = ''
        $protectedState = $false
        try {
            $container = Resolve-ADTConsoleObject -Identity $Path @common
            if (-not (Test-ADTObjectIsContainer -ObjectClass ([string]$container.ObjectClass))) {
                throw ('La destination n est pas un conteneur : {0}' -f $Path)
            }
            $containerDN = [string]$container.DistinguishedName

            if ($PSCmdlet.ShouldProcess($Name, ('Creer l unite d organisation dans {0}' -f $containerDN))) {
                $dn = New-ADTNativeOrganizationalUnit -Path $containerDN -Name $Name -Description $Description -ErrorAction Stop @common
                $status = 'Creee'
                Write-ADTLog -Level 'SUCCESS' -Message ('Unite d organisation creee : {0}' -f $dn)

                if (-not $NoProtection) {
                    try {
                        Set-ADTNativeDeletionProtection -DistinguishedName $dn -Protected $true -ErrorAction Stop @common
                        $protectedState = $true
                    } catch {
                        $status = 'Partiel'
                        $errorText = 'Protection contre la suppression non posee : ' + $_.Exception.Message
                        Write-ADTLog -Level 'WARN' -Message ('Protection non posee sur {0} : {1}' -f $dn, $_.Exception.Message)
                    }
                }
            } else {
                $status = 'Simulation'
            }
        } catch {
            $errorText = $_.Exception.Message
            Write-ADTLog -Level 'ERROR' -Message ('Creation de l unite d organisation {0} echouee : {1}' -f $Name, $errorText)
        }

        $row = New-Object PSObject -Property @{
            Name = $Name; Status = $status; DistinguishedName = $dn; Protected = $protectedState; Error = $errorText
        }
        $row | Select-Object Name, Status, DistinguishedName, Protected, Error
    }
}


#--- New-ADTPassword.ps1 ---------------------------------------------------

function New-ADTPassword {
<#
.SYNOPSIS
    Genere un mot de passe aleatoire configurable, conforme a la strategie du domaine.
.DESCRIPTION
    Generateur cryptographique du module, expose avec ses reglages : longueur,
    classes de caracteres, caracteres ambigus, jeu de symboles.

    Par defaut, la strategie du domaine est lue et la longueur demandee est
    relevee si elle est inferieure au minimum exige. PSADToolkit ne descend jamais
    sous 12 caracteres, meme lorsque le domaine autorise plus court : un mot de
    passe temporaire circule par courriel ou sur papier, il merite cette marge.
    -NoPolicyCheck evite l aller-retour vers l annuaire lorsqu il n est pas joignable.

    Le mot de passe genere n est jamais journalise. Seul l appelant en dispose.
.PARAMETER Length
    Longueur demandee. Minimum 12, defaut 16.
.PARAMETER Count
    Nombre de mots de passe a generer.
.PARAMETER NoUppercase
    Exclut les majuscules.
.PARAMETER NoLowercase
    Exclut les minuscules.
.PARAMETER NoDigit
    Exclut les chiffres.
.PARAMETER NoSpecial
    Exclut les caracteres speciaux.
.PARAMETER IncludeAmbiguous
    Reintegre O, 0, l, 1 et I, exclus par defaut pour eviter les erreurs de saisie.
.PARAMETER SpecialCharacter
    Jeu de symboles autorises.
.PARAMETER NoPolicyCheck
    N interroge pas l annuaire et n ajuste pas la longueur.
.EXAMPLE
    New-ADTPassword
.EXAMPLE
    New-ADTPassword -Length 24 -NoSpecial -Count 5
#>
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'Cette fonction produit un mot de passe temporaire a remettre a l employe; il doit etre lisible par l appelant.')]
    [CmdletBinding()]
    param(
        [ValidateRange(12, 128)][int]$Length = 16,
        [ValidateRange(1, 500)][int]$Count = 1,
        [switch]$NoUppercase,
        [switch]$NoLowercase,
        [switch]$NoDigit,
        [switch]$NoSpecial,
        [switch]$IncludeAmbiguous,
        [string]$SpecialCharacter = '!#$%&*+-=?@',
        [switch]$NoPolicyCheck,
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential,
        [string]$LogPath
    )

    $effectiveLength = $Length
    $policySource = 'Non consultee'
    $minimum = 0
    $complexity = $true

    if (-not $NoPolicyCheck) {
        try {
            $common = Initialize-ADTConnection -Server $Server -Credential $Credential -LogPath $LogPath
            $policy = Get-ADTNativePasswordPolicy @common
            $minimum = [int]$policy.MinimumPasswordLength
            $complexity = [bool]$policy.ComplexityEnabled
            $policySource = [string]$policy.Source
            if ($effectiveLength -lt $minimum) {
                Write-Warning ('Longueur portee de {0} a {1} pour respecter la strategie du domaine.' -f $Length, $minimum)
                $effectiveLength = $minimum
            }
        } catch {
            $policySource = 'Strategie illisible : ' + $_.Exception.Message
            Write-Warning ('Strategie du domaine non lue, longueur demandee conservee. {0}' -f $_.Exception.Message)
        }
    }
    if ($effectiveLength -gt 128) { $effectiveLength = 128 }

    $generator = @{
        Length           = $effectiveLength
        UseUppercase     = (-not $NoUppercase)
        UseLowercase     = (-not $NoLowercase)
        UseDigit         = (-not $NoDigit)
        UseSpecial       = (-not $NoSpecial)
        SpecialCharacter = $SpecialCharacter
    }
    if ($IncludeAmbiguous) { $generator['IncludeAmbiguous'] = $true }

    for ($index = 0; $index -lt $Count; $index++) {
        $clear = New-ADTRandomPassword @generator
        $check = Test-ADTPasswordComplexity -Password $clear -MinimumLength $minimum -ComplexityEnabled $complexity
        $result = New-Object PSObject -Property @{
            Password         = $clear
            Length           = $clear.Length
            MeetsPolicy      = $check.Valid
            PolicyIssues     = [string]$check.Issues
            PolicySource     = $policySource
            CharacterClasses = [int]$check.Categories
        }
        $result | Select-Object Password, Length, MeetsPolicy, PolicyIssues, CharacterClasses, PolicySource
    }
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


#--- Remove-ADTObject.ps1 --------------------------------------------------

function Remove-ADTObject {
<#
.SYNOPSIS
    Supprime des objets Active Directory, avec les garde-fous de la console Microsoft.
.DESCRIPTION
    Supprime utilisateurs, groupes, ordinateurs et unites d organisation.

    Trois protections sont appliquees avant toute suppression :
      - ConfirmImpact eleve : la confirmation est demandee par defaut ;
      - un conteneur non vide n est supprime qu avec -Recursive, et le nombre
        d objets emportes est indique ;
      - la protection contre la suppression accidentelle est detectee et
        signalee ; elle n est levee qu avec -RemoveProtection.

    Une suppression est definitive du point de vue de PSADToolkit : la corbeille
    Active Directory, lorsqu elle est activee dans le domaine, reste le seul
    moyen de restaurer l objet.

    Pour un depart d employe, preferer Start-ADTUserOffboarding : il sauvegarde
    les acces et desactive le compte au lieu de le detruire.
.PARAMETER Identity
    Objets a supprimer : DN, sAMAccountName, nom ou SID.
.PARAMETER Recursive
    Autorise la suppression d un conteneur et de tout son contenu.
.PARAMETER RemoveProtection
    Leve la protection contre la suppression accidentelle avant de supprimer.
.EXAMPLE
    Remove-ADTObject -Identity 'CN=test,OU=Bac,DC=contoso,DC=local' -WhatIf
.EXAMPLE
    Remove-ADTObject -Identity 'OU=Ancien,DC=contoso,DC=local' -Recursive -RemoveProtection
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('SamAccountName', 'DistinguishedName')]
        [string[]]$Identity,

        [switch]$Recursive,
        [switch]$RemoveProtection,
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential,
        [string]$LogPath
    )

    begin { $common = Initialize-ADTConnection -Server $Server -Credential $Credential -LogPath $LogPath }

    process {
        foreach ($id in $Identity) {
            if (-not $id) { continue }
            $label = $id
            $status = 'Echec'
            $errorText = ''
            $objectType = ''
            $dn = ''
            try {
                $item = Resolve-ADTConsoleObject -Identity $id @common
                $dn = [string]$item.DistinguishedName
                $objectType = [string]$item.ObjectType
                $label = [string]$item.SamAccountName
                if (-not $label) { $label = [string]$item.Name }

                $childCount = 0
                if (Test-ADTObjectIsContainer -ObjectClass ([string]$item.ObjectClass)) {
                    $children = @(Get-ADTNativeContainerChild -DistinguishedName $dn @common)
                    $childCount = $children.Count
                    if ($childCount -gt 0 -and -not $Recursive) {
                        throw ('Ce conteneur contient {0} objet(s). Utiliser -Recursive pour tout supprimer.' -f $childCount)
                    }
                }

                $protected = $false
                try { $protected = Get-ADTNativeDeletionProtection -DistinguishedName $dn @common }
                catch { Write-Verbose ('Protection non lisible sur {0} : {1}' -f $dn, $_.Exception.Message) }
                if ($protected -and -not $RemoveProtection) {
                    throw 'Objet protege contre la suppression accidentelle. Utiliser -RemoveProtection pour lever la protection.'
                }

                $action = 'Supprimer'
                if ($childCount -gt 0) { $action = ('Supprimer avec {0} objet(s) contenu(s)' -f $childCount) }

                if ($PSCmdlet.ShouldProcess($dn, $action)) {
                    if ($protected) {
                        Set-ADTNativeDeletionProtection -DistinguishedName $dn -Protected $false -ErrorAction Stop @common
                        Write-ADTLog -Level 'WARN' -Message ('Protection contre la suppression levee sur {0}' -f $dn)
                    }
                    Remove-ADTNativeObject -DistinguishedName $dn -Recursive:$Recursive -ErrorAction Stop @common
                    $status = 'Supprime'
                    Write-ADTLog -Level 'SUCCESS' -Message ('{0} supprime ({1}, {2} objet(s) contenu(s))' -f $dn, $objectType, $childCount)
                } else {
                    $status = 'Simulation'
                }
            } catch {
                $errorText = $_.Exception.Message
                Write-ADTLog -Level 'ERROR' -Message ('Suppression de {0} refusee : {1}' -f $label, $errorText)
            }
            $row = New-Object PSObject -Property @{
                Name = $label; ObjectType = $objectType; Status = $status; DistinguishedName = $dn; Error = $errorText
            }
            $row | Select-Object Name, ObjectType, Status, DistinguishedName, Error
        }
    }
}


#--- Set-ADTAccountState.ps1 -----------------------------------------------

function Set-ADTAccountState {
<#
.SYNOPSIS
    Active, desactive ou deverrouille des comptes, en lot.
.DESCRIPTION
    Regroupe les trois gestes quotidiens de la console Microsoft sur un compte
    d utilisateur ou d ordinateur. Chaque compte produit une ligne de resultat,
    ce qui permet de traiter une selection multiple et de voir immediatement ce
    qui a echoue.

    Le deverrouillage remet lockoutTime a zero : c est la seule operation possible,
    l indicateur de verrouillage de userAccountControl etant calcule par le
    controleur de domaine. Deverrouiller un compte deja deverrouille est sans
    effet et n est pas signale comme une erreur.

    -Action Enable et -Unlock peuvent etre combines : c est le cas courant apres
    un blocage suivi d une desactivation preventive.
.PARAMETER Identity
    Comptes vises : sAMAccountName, UPN, DN ou SID.
.PARAMETER Action
    Enable, Disable ou Unlock.
.PARAMETER Unlock
    Deverrouille en plus de l action demandee.
.EXAMPLE
    Set-ADTAccountState -Identity 'jcote' -Action Unlock
.EXAMPLE
    Set-ADTAccountState -Identity 'jcote','mtremblay' -Action Disable -WhatIf
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('SamAccountName', 'User', 'DistinguishedName')]
        [string[]]$Identity,

        [Parameter(Mandatory = $true, Position = 1)]
        [ValidateSet('Enable', 'Disable', 'Unlock')]
        [string]$Action,

        [switch]$Unlock,
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential,
        [string]$LogPath
    )

    begin {
        $common = Initialize-ADTConnection -Server $Server -Credential $Credential -LogPath $LogPath
        $labels = @{ 'Enable' = 'Activer le compte'; 'Disable' = 'Desactiver le compte'; 'Unlock' = 'Deverrouiller le compte' }
    }

    process {
        foreach ($id in $Identity) {
            if (-not $id) { continue }
            $sam = $id
            $status = 'Echec'
            $errorText = ''
            $steps = New-Object System.Collections.ArrayList
            try {
                $account = Resolve-ADTConsoleObject -Identity $id -ObjectFilter (Get-ADTConsoleClassFilter -Type Account) @common
                $sam = [string]$account.SamAccountName
                if (-not $sam) { $sam = [string]$account.Name }
                $dn = [string]$account.DistinguishedName

                if ($PSCmdlet.ShouldProcess($sam, [string]$labels[$Action])) {
                    switch ($Action) {
                        'Enable' {
                            Enable-ADTNativeAccount -DistinguishedName $dn -ErrorAction Stop @common
                            [void]$steps.Add('Active')
                        }
                        'Disable' {
                            Disable-ADTNativeAccount -Identity $dn -ErrorAction Stop @common
                            [void]$steps.Add('Desactive')
                        }
                        'Unlock' {
                            Unlock-ADTNativeAccount -DistinguishedName $dn -ErrorAction Stop @common
                            [void]$steps.Add('Deverrouille')
                        }
                    }
                    if ($Unlock -and $Action -ne 'Unlock') {
                        Unlock-ADTNativeAccount -DistinguishedName $dn -ErrorAction Stop @common
                        [void]$steps.Add('Deverrouille')
                    }
                    $status = 'Termine'
                    Write-ADTLog -Level 'SUCCESS' -Message ('{0} : {1}' -f $sam, ($steps -join ', '))
                } else {
                    $status = 'Simulation'
                }
            } catch {
                $errorText = $_.Exception.Message
                Write-ADTLog -Level 'ERROR' -Message ('{0} sur {1} echoue : {2}' -f $Action, $sam, $errorText)
            }
            $row = New-Object PSObject -Property @{
                SamAccountName = $sam; Action = $Action; Status = $status; Steps = ($steps -join ', '); Error = $errorText
            }
            $row | Select-Object SamAccountName, Action, Status, Steps, Error
        }
    }
}


#--- Set-ADTGroupMember.ps1 ------------------------------------------------

function Set-ADTGroupMember {
<#
.SYNOPSIS
    Ajoute ou retire des membres sur un groupe donne.
.DESCRIPTION
    Vue "par groupe" de la gestion des appartenances, complementaire de
    Set-ADTUserGroupMembership, qui raisonne "par utilisateur". C est la forme
    attendue quand on ouvre un groupe et qu on gere sa liste de membres.

    Accepte plusieurs groupes et plusieurs membres, rend une ligne de resultat par
    couple groupe/membre, et prend en charge -WhatIf.

    Le retrait du groupe principal d un compte est refuse : Active Directory
    l interdit, et l echec brut du controleur n est pas explicite.
.PARAMETER Identity
    Groupes a modifier : nom, sAMAccountName, DN ou SID.
.PARAMETER Member
    Comptes ou groupes a ajouter.
.PARAMETER RemoveMember
    Comptes ou groupes a retirer.
.EXAMPLE
    Set-ADTGroupMember -Identity 'GS-VPN' -Member 'jcote','mtremblay' -WhatIf
.EXAMPLE
    $sortants = @(Get-ADTGroupMember -Identity 'GS-Stagiaires' | Select-Object -ExpandProperty SamAccountName)
    Set-ADTGroupMember -Identity 'GS-Stagiaires' -RemoveMember $sortants
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [Alias('Group', 'GroupName')]
        [string[]]$Identity,

        [Parameter(ValueFromPipelineByPropertyName = $true)]
        [Alias('Add', 'AddMember')]
        [string[]]$Member,

        [Alias('Remove')]
        [string[]]$RemoveMember,

        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential,
        [string]$LogPath
    )

    begin {
        if (-not $Member -and -not $RemoveMember) { throw 'Preciser au moins -Member ou -RemoveMember.' }
        $common = Initialize-ADTConnection -Server $Server -Credential $Credential -LogPath $LogPath
        foreach ($candidate in @($Member)) {
            if ($candidate -and (@($RemoveMember) -contains $candidate)) {
                throw ('Membre present dans l ajout ET le retrait : ' + $candidate)
            }
        }
    }

    process {
        foreach ($groupId in $Identity) {
            if (-not $groupId) { continue }

            $group = $null
            try {
                $group = Resolve-ADTConsoleObject -Identity $groupId -ObjectFilter (Get-ADTConsoleClassFilter -Type Group) @common
            } catch {
                Write-ADTLog -Level 'ERROR' -Message ('Groupe introuvable : {0}' -f $groupId)
                $failure = New-Object PSObject -Property @{
                    GroupName = $groupId; Member = ''; Action = 'Recherche'; Status = 'Echec'; Error = $_.Exception.Message
                }
                $failure | Select-Object GroupName, Member, Action, Status, Error
                continue
            }
            $groupDN = [string]$group.DistinguishedName
            $groupName = [string]$group.Name

            $operations = @()
            foreach ($item in @($Member)) { if ($item) { $operations += (New-Object PSObject -Property @{ Identity = $item; Action = 'Ajout' }) } }
            foreach ($item in @($RemoveMember)) { if ($item) { $operations += (New-Object PSObject -Property @{ Identity = $item; Action = 'Retrait' }) } }

            foreach ($operation in $operations) {
                $memberId = [string]$operation.Identity
                $action = [string]$operation.Action
                $status = 'Echec'
                $errorText = ''
                $memberName = $memberId
                try {
                    $target = Resolve-ADTConsoleObject -Identity $memberId @common
                    $memberName = [string]$target.SamAccountName
                    if (-not $memberName) { $memberName = [string]$target.Name }

                    if ($action -eq 'Retrait' -and [string]$target.PrimaryGroupID -and $group.SID) {
                        $primaryRid = ($group.SID.Value -split '-')[-1]
                        if ([string]$target.PrimaryGroupID -eq $primaryRid) {
                            throw 'Ce groupe est le groupe principal du compte. Changer le groupe principal avant de retirer le membre.'
                        }
                    }

                    if ($PSCmdlet.ShouldProcess($groupName, ('{0} de {1}' -f $action, $memberName))) {
                        if ($action -eq 'Ajout') {
                            Add-ADTNativeGroupMember -Identity $groupDN -Members ([string]$target.DistinguishedName) -ErrorAction Stop @common
                            $status = 'Ajoute'
                        } else {
                            Remove-ADTNativeGroupMember -Identity $groupDN -Members ([string]$target.DistinguishedName) -Confirm:$false -ErrorAction Stop @common
                            $status = 'Retire'
                        }
                        Write-ADTLog -Level 'SUCCESS' -Message ('{0} : {1} de {2}' -f $groupName, $status, $memberName)
                    } else {
                        $status = 'Simulation'
                    }
                } catch {
                    $errorText = $_.Exception.Message
                    Write-ADTLog -Level 'ERROR' -Message ('{0} : {1} de {2} echoue : {3}' -f $groupName, $action, $memberName, $errorText)
                }
                $row = New-Object PSObject -Property @{
                    GroupName = $groupName; Member = $memberName; Action = $action; Status = $status; Error = $errorText
                }
                $row | Select-Object GroupName, Member, Action, Status, Error
            }
        }
    }
}


#--- Set-ADTOrganizationalUnit.ps1 -----------------------------------------

function Set-ADTOrganizationalUnit {
<#
.SYNOPSIS
    Modifie une unite d organisation : nom, description, protection, gestionnaire.
.DESCRIPTION
    Seuls les parametres fournis sont ecrits. Renommer une unite change le DN de
    tous les objets qu elle contient : les scripts, les strategies de groupe liees
    par DN et les raccourcis qui referencent l ancien DN doivent etre revus.
    Le nouveau DN est rendu dans le resultat.
.PARAMETER Identity
    Unite d organisation visee : DN ou nom.
.PARAMETER NewName
    Nouveau nom de l unite.
.PARAMETER Description
    Nouvelle description. Chaine vide pour l effacer.
.PARAMETER ManagedBy
    Compte ou groupe responsable de l unite. Chaine vide pour l effacer.
.PARAMETER ProtectFromAccidentalDeletion
    Active ou retire la protection contre la suppression accidentelle.
.EXAMPLE
    Set-ADTOrganizationalUnit -Identity 'OU=Ventes,DC=contoso,DC=local' -Description 'Service des ventes' -WhatIf
.EXAMPLE
    Set-ADTOrganizationalUnit -Identity 'OU=Ventes,DC=contoso,DC=local' -ProtectFromAccidentalDeletion $false
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('DistinguishedName')]
        [string[]]$Identity,

        [string]$NewName,
        [string]$Description,
        [string]$ManagedBy,
        [bool]$ProtectFromAccidentalDeletion,
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential,
        [string]$LogPath
    )

    begin { $common = Initialize-ADTConnection -Server $Server -Credential $Credential -LogPath $LogPath }

    process {
        foreach ($id in $Identity) {
            if (-not $id) { continue }
            $label = $id
            $status = 'Echec'
            $errorText = ''
            $dn = ''
            $changes = New-Object System.Collections.ArrayList
            try {
                $unit = Resolve-ADTConsoleObject -Identity $id -ObjectFilter (Get-ADTConsoleClassFilter -Type OrganizationalUnit) @common
                $dn = [string]$unit.DistinguishedName
                $label = [string]$unit.Name

                $attributes = @{}
                if ($PSBoundParameters.ContainsKey('Description')) { $attributes['description'] = $Description; [void]$changes.Add('Description') }
                if ($PSBoundParameters.ContainsKey('ManagedBy')) {
                    if ($ManagedBy) {
                        $owner = Resolve-ADTConsoleObject -Identity $ManagedBy @common
                        $attributes['managedBy'] = [string]$owner.DistinguishedName
                    } else { $attributes['managedBy'] = '' }
                    [void]$changes.Add('ManagedBy')
                }
                if ($PSBoundParameters.ContainsKey('ProtectFromAccidentalDeletion')) { [void]$changes.Add('Protection') }
                if ($NewName) { [void]$changes.Add('NewName') }
                if (-not $changes.Count) { throw 'Aucune propriete a modifier : preciser au moins un parametre.' }

                if ($PSCmdlet.ShouldProcess($label, ('Modifier : {0}' -f ($changes -join ', ')))) {
                    if ($attributes.Count) {
                        Set-ADTNativeObjectAttribute -DistinguishedName $dn -Attribute $attributes -ErrorAction Stop @common
                    }
                    if ($PSBoundParameters.ContainsKey('ProtectFromAccidentalDeletion')) {
                        Set-ADTNativeDeletionProtection -DistinguishedName $dn -Protected $ProtectFromAccidentalDeletion -ErrorAction Stop @common
                    }
                    if ($NewName) {
                        $dn = Rename-ADTNativeObject -DistinguishedName $dn -NewName $NewName -ObjectClass 'organizationalUnit' -ErrorAction Stop @common
                        $label = $NewName
                    }
                    $status = 'Modifiee'
                    Write-ADTLog -Level 'SUCCESS' -Message ('Unite d organisation {0} modifiee : {1}' -f $dn, ($changes -join ', '))
                } else {
                    $status = 'Simulation'
                }
            } catch {
                $errorText = $_.Exception.Message
                Write-ADTLog -Level 'ERROR' -Message ('Modification de l unite {0} echouee : {1}' -f $label, $errorText)
            }
            $row = New-Object PSObject -Property @{
                Name = $label; Status = $status; Changed = ($changes -join ', '); DistinguishedName = $dn; Error = $errorText
            }
            $row | Select-Object Name, Status, Changed, DistinguishedName, Error
        }
    }
}


#--- Set-ADTUser.ps1 -------------------------------------------------------

function Set-ADTUser {
<#
.SYNOPSIS
    Modifie les proprietes d un compte utilisateur Active Directory.
.DESCRIPTION
    Couvre les sections General, Adresse, Compte, Organisation et Profil de la
    feuille de proprietes de la console Microsoft.

    Seuls les parametres explicitement fournis sont ecrits : les autres attributs
    ne sont pas touches. Passer une chaine vide efface l attribut, exactement
    comme vider un champ dans la console.

    Les options de compte sont des booleens : -PasswordNeverExpires $true active
    l option, $false la retire, l omettre ne change rien.

    "L utilisateur ne peut pas changer de mot de passe" n est pas modifiable ici :
    dans Active Directory, cette option est portee par les autorisations de
    l objet et non par userAccountControl. Get-ADTObjectProperty la rend en
    lecture seule.
.PARAMETER Identity
    Comptes vises : sAMAccountName, UPN, DN ou SID.
.PARAMETER NewName
    Nouveau nom de l objet (CN). Renomme l objet sans le deplacer.
.PARAMETER AccountExpirationDate
    Dernier jour ouvert du compte. Le compte expire a la fin de cette journee,
    comme l affiche la console Microsoft.
.PARAMETER NeverExpires
    Retire toute date d expiration.
.PARAMETER MustChangePassword
    Force ou retire le changement de mot de passe a la prochaine ouverture de session.
.EXAMPLE
    Set-ADTUser -Identity 'jcote' -Title 'Analyste principal' -Department 'TI' -WhatIf
.EXAMPLE
    Set-ADTUser -Identity 'jcote' -AccountExpirationDate ([datetime]'2027-06-30') -PasswordNeverExpires $false
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('SamAccountName', 'User', 'DistinguishedName')]
        [string[]]$Identity,

        [string]$NewName,
        [string]$GivenName,
        [string]$Surname,
        [string]$Initials,
        [string]$DisplayName,
        [string]$Description,
        [string]$EmailAddress,
        [string]$OfficePhone,
        [string]$MobilePhone,
        [string]$Office,
        [string]$Title,
        [string]$Department,
        [string]$Company,
        [string]$Manager,
        [string]$StreetAddress,
        [string]$City,
        [string]$State,
        [string]$PostalCode,
        [string]$Country,
        [string]$EmployeeID,
        [string]$Notes,
        [string]$HomeDirectory,
        [string]$HomeDrive,
        [string]$ProfilePath,
        [string]$ScriptPath,
        [string]$UserPrincipalName,

        [AllowNull()]$AccountExpirationDate,
        [switch]$NeverExpires,

        [bool]$MustChangePassword,
        [bool]$PasswordNeverExpires,
        [bool]$PasswordNotRequired,
        [bool]$SmartcardLogonRequired,
        [bool]$AccountNotDelegated,
        [bool]$DoesNotRequirePreAuth,

        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential,
        [string]$LogPath
    )

    begin {
        $common = Initialize-ADTConnection -Server $Server -Credential $Credential -LogPath $LogPath

        # Parametre de la fonction -> attribut LDAP correspondant.
        $attributeMap = @{
            GivenName         = 'givenName'
            Surname           = 'sn'
            Initials          = 'initials'
            DisplayName       = 'displayName'
            Description       = 'description'
            EmailAddress      = 'mail'
            OfficePhone       = 'telephoneNumber'
            MobilePhone       = 'mobile'
            Office            = 'physicalDeliveryOfficeName'
            Title             = 'title'
            Department        = 'department'
            Company           = 'company'
            StreetAddress     = 'streetAddress'
            City              = 'l'
            State             = 'st'
            PostalCode        = 'postalCode'
            Country           = 'co'
            EmployeeID        = 'employeeID'
            Notes             = 'info'
            HomeDirectory     = 'homeDirectory'
            HomeDrive         = 'homeDrive'
            ProfilePath       = 'profilePath'
            ScriptPath        = 'scriptPath'
            UserPrincipalName = 'userPrincipalName'
        }

        # Option de compte -> bit de userAccountControl.
        $flagMap = @{
            PasswordNeverExpires   = 65536
            PasswordNotRequired    = 32
            SmartcardLogonRequired = 262144
            AccountNotDelegated    = 1048576
            DoesNotRequirePreAuth  = 4194304
        }

        if ($NeverExpires -and $PSBoundParameters.ContainsKey('AccountExpirationDate')) {
            throw '-NeverExpires et -AccountExpirationDate s excluent.'
        }
        if ($PSBoundParameters.ContainsKey('HomeDrive') -and $HomeDrive -and $HomeDrive -notmatch '^[A-Za-z]:$') {
            throw 'HomeDrive doit avoir la forme H: ou etre vide.'
        }
    }

    process {
        foreach ($id in $Identity) {
            if (-not $id) { continue }
            $sam = $id
            $status = 'Echec'
            $errorText = ''
            $changes = New-Object System.Collections.ArrayList
            try {
                $user = Resolve-ADTConsoleObject -Identity $id -ObjectFilter (Get-ADTConsoleClassFilter -Type User) @common
                $sam = [string]$user.SamAccountName
                $dn = [string]$user.DistinguishedName

                $attributes = @{}
                foreach ($parameterName in @($attributeMap.Keys)) {
                    if (-not $PSBoundParameters.ContainsKey($parameterName)) { continue }
                    $attributes[[string]$attributeMap[$parameterName]] = [string]$PSBoundParameters[$parameterName]
                    [void]$changes.Add($parameterName)
                }

                if ($PSBoundParameters.ContainsKey('Manager')) {
                    if ($Manager) {
                        $managerObject = Resolve-ADTConsoleObject -Identity $Manager -ObjectFilter (Get-ADTConsoleClassFilter -Type User) @common
                        $attributes['manager'] = [string]$managerObject.DistinguishedName
                    } else {
                        $attributes['manager'] = ''
                    }
                    [void]$changes.Add('Manager')
                }

                $setFlag = 0
                $clearFlag = 0
                foreach ($parameterName in @($flagMap.Keys)) {
                    if (-not $PSBoundParameters.ContainsKey($parameterName)) { continue }
                    $bit = [int]$flagMap[$parameterName]
                    if ([bool]$PSBoundParameters[$parameterName]) { $setFlag = $setFlag -bor $bit }
                    else { $clearFlag = $clearFlag -bor $bit }
                    [void]$changes.Add($parameterName)
                }

                $expirationRequested = ($NeverExpires -or $PSBoundParameters.ContainsKey('AccountExpirationDate'))
                if ($expirationRequested) { [void]$changes.Add('AccountExpirationDate') }
                if ($PSBoundParameters.ContainsKey('MustChangePassword')) { [void]$changes.Add('MustChangePassword') }
                if ($NewName) { [void]$changes.Add('NewName') }

                if (-not $changes.Count) { throw 'Aucune propriete a modifier : preciser au moins un parametre.' }

                if ($PSCmdlet.ShouldProcess($sam, ('Modifier : {0}' -f ($changes -join ', ')))) {
                    if ($attributes.Count) {
                        Set-ADTNativeObjectAttribute -DistinguishedName $dn -Attribute $attributes -ErrorAction Stop @common
                    }
                    if ($setFlag -ne 0 -or $clearFlag -ne 0) {
                        $null = Set-ADTNativeAccountControl -DistinguishedName $dn -SetFlag $setFlag -ClearFlag $clearFlag -ErrorAction Stop @common
                    }
                    if ($expirationRequested) {
                        $moment = $null
                        if (-not $NeverExpires -and $null -ne $AccountExpirationDate -and ([string]$AccountExpirationDate).Length -gt 0) {
                            # Le compte reste utilisable toute la journee indiquee :
                            # l expiration reelle est le debut du jour suivant.
                            $moment = ([datetime]$AccountExpirationDate).Date.AddDays(1)
                        }
                        Set-ADTNativeAccountExpiration -DistinguishedName $dn -ExpiresAfter $moment -ErrorAction Stop @common
                    }
                    if ($PSBoundParameters.ContainsKey('MustChangePassword')) {
                        Set-ADTNativeMustChangePassword -DistinguishedName $dn -Required $MustChangePassword -ErrorAction Stop @common
                    }
                    if ($NewName) {
                        $dn = Rename-ADTNativeObject -DistinguishedName $dn -NewName $NewName -ObjectClass 'user' -ErrorAction Stop @common
                    }
                    $status = 'Modifie'
                    Write-ADTLog -Level 'SUCCESS' -Message ('Compte {0} modifie : {1}' -f $sam, ($changes -join ', '))
                } else {
                    $status = 'Simulation'
                }
            } catch {
                $errorText = $_.Exception.Message
                Write-ADTLog -Level 'ERROR' -Message ('Modification de {0} echouee : {1}' -f $sam, $errorText)
            }
            $row = New-Object PSObject -Property @{
                SamAccountName = $sam; Status = $status; Changed = ($changes -join ', '); Error = $errorText
            }
            $row | Select-Object SamAccountName, Status, Changed, Error
        }
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


#--- Set-ADTUserLogonHours.ps1 ---------------------------------------------

function Set-ADTUserLogonHours {
<#
.SYNOPSIS
    Applique un horaire de connexion a des comptes, ou aux membres d un groupe.
.DESCRIPTION
    Le masque fourni decrit 168 heures en HEURE LOCALE, du dimanche 00 h au samedi
    23 h. La conversion vers le temps universel attendu par l annuaire est faite
    ici : un horaire 08 h - 18 h saisi a Montreal s affiche bien 08 h - 18 h dans
    la console Microsoft executee sur le meme fuseau.

    Trois portees sont possibles :
      - des comptes nommes, avec -Identity ;
      - les membres d un groupe, avec -Group ;
      - les membres d un groupe sauf certains, avec -Group et -ExcludeIdentity,
        pour qu une equipe garde un horaire different du reste du groupe.

    Un masque entierement autorise efface l attribut, ce qui correspond a
    "Toutes les heures" dans la console Microsoft. Un masque entierement interdit
    empeche toute ouverture de session : il exige -AllowNoLogonWindow, pour que ce
    soit un choix et non une faute de saisie.
.PARAMETER Identity
    Comptes vises.
.PARAMETER Group
    Groupe dont les membres recoivent l horaire.
.PARAMETER ExcludeIdentity
    Membres du groupe a laisser inchanges.
.PARAMETER Recursive
    Inclut les membres des groupes imbriques lorsque -Group est utilise.
.PARAMETER Schedule
    Masque de 168 caracteres 0 ou 1, produit par New-ADTLogonHourSchedule.
.PARAMETER AllowNoLogonWindow
    Autorise un horaire ne laissant aucune heure de connexion.
.EXAMPLE
    $horaire = New-ADTLogonHourSchedule -Day Monday,Tuesday,Wednesday,Thursday,Friday -StartHour 8 -EndHour 18
    Set-ADTUserLogonHours -Identity 'jcote' -Schedule $horaire.Mask -WhatIf
.EXAMPLE
    Set-ADTUserLogonHours -Group 'GS-Ventes' -ExcludeIdentity 'dgagnon' -Schedule $horaire.Mask
#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium', DefaultParameterSetName = 'Identity')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Identity', Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('SamAccountName', 'User')]
        [string[]]$Identity,

        [Parameter(Mandatory = $true, ParameterSetName = 'Group')]
        [Alias('GroupName')]
        [string]$Group,

        [Parameter(ParameterSetName = 'Group')]
        [string[]]$ExcludeIdentity,

        [Parameter(ParameterSetName = 'Group')]
        [switch]$Recursive,

        [Parameter(Mandatory = $true)]
        [Alias('Mask')]
        [string]$Schedule,

        [switch]$AllowNoLogonWindow,
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential,
        [string]$LogPath
    )

    begin {
        if (-not (Test-ADTLogonHoursMask -Mask $Schedule)) {
            throw 'Horaire invalide : 168 caracteres 0 ou 1 attendus. Utiliser New-ADTLogonHourSchedule.'
        }
        if ($Schedule -eq ('0' * 168) -and -not $AllowNoLogonWindow) {
            throw 'Cet horaire n autorise aucune heure de connexion. Confirmer avec -AllowNoLogonWindow.'
        }
        $common = Initialize-ADTConnection -Server $Server -Credential $Credential -LogPath $LogPath
        $summary = ConvertTo-ADTLogonHoursText -Mask $Schedule
        $targets = New-Object System.Collections.ArrayList

        if ($PSCmdlet.ParameterSetName -eq 'Group') {
            $excluded = @{}
            foreach ($item in @($ExcludeIdentity)) {
                if ($item) { $excluded[([string]$item).ToLowerInvariant()] = $true }
            }
            foreach ($member in @(Get-ADTGroupMember -Identity $Group -Recursive:$Recursive @common)) {
                if ([string]$member.ObjectClass -ne 'user') { continue }
                $sam = ([string]$member.SamAccountName).ToLowerInvariant()
                $dn = ([string]$member.DistinguishedName).ToLowerInvariant()
                if ($excluded.ContainsKey($sam) -or $excluded.ContainsKey($dn)) { continue }
                [void]$targets.Add([string]$member.DistinguishedName)
            }
            if (-not $targets.Count) { Write-Warning ('Aucun compte a traiter dans le groupe {0}.' -f $Group) }
        }
    }

    process {
        $queue = @()
        if ($PSCmdlet.ParameterSetName -eq 'Group') { $queue = @($targets) }
        else { $queue = @($Identity) }

        foreach ($id in $queue) {
            if (-not $id) { continue }
            $sam = $id
            $status = 'Echec'
            $errorText = ''
            try {
                $user = Resolve-ADTConsoleObject -Identity $id -ObjectFilter (Get-ADTConsoleClassFilter -Type User) @common
                $sam = [string]$user.SamAccountName
                if ($PSCmdlet.ShouldProcess($sam, ('Appliquer les horaires de connexion : {0}' -f $summary))) {
                    Set-ADTNativeLogonHours -DistinguishedName ([string]$user.DistinguishedName) -Mask $Schedule -ErrorAction Stop @common
                    $status = 'Applique'
                    Write-ADTLog -Level 'SUCCESS' -Message ('Horaires de connexion appliques a {0} : {1}' -f $sam, $summary)
                } else {
                    $status = 'Simulation'
                }
            } catch {
                $errorText = $_.Exception.Message
                Write-ADTLog -Level 'ERROR' -Message ('Horaires de connexion refuses pour {0} : {1}' -f $sam, $errorText)
            }
            $row = New-Object PSObject -Property @{
                SamAccountName = $sam; Status = $status; Schedule = $summary; Error = $errorText
            }
            $row | Select-Object SamAccountName, Status, Schedule, Error
        }
    }
}


#--- Set-ADTUserPassword.ps1 -----------------------------------------------

function Set-ADTUserPassword {
<#
.SYNOPSIS
    Reinitialise le mot de passe d un ou plusieurs comptes.
.DESCRIPTION
    Genere un mot de passe conforme a la strategie du domaine, ou applique celui
    fourni par l appelant, puis force par defaut son changement a la prochaine
    ouverture de session.

    Le mot de passe en clair n est JAMAIS journalise : le journal ne consigne que
    le compte, l horodatage et le resultat. Il est rendu dans la propriete
    Password de l objet de sortie, afin de pouvoir etre remis a l employe, par
    exemple avec New-ADTCredentialDocument. A l appelant de ne pas le conserver.

    Un compte verrouille peut etre deverrouille dans la foulee avec -Unlock, ce
    qui evite un second aller-retour vers l annuaire.
.PARAMETER Identity
    Comptes vises : sAMAccountName, UPN, DN ou SID.
.PARAMETER NewPassword
    Mot de passe impose, en SecureString. Si omis, il est genere.
.PARAMETER Length
    Longueur du mot de passe genere. Relevee au minimum de la strategie du domaine.
.PARAMETER NoChangeAtNextLogon
    Ne pas forcer le changement a la prochaine ouverture de session.
.PARAMETER Unlock
    Deverrouille egalement le compte.
.PARAMETER NoSpecial
    Genere un mot de passe sans caractere special.
.PARAMETER IncludeAmbiguous
    Autorise les caracteres ambigus O, 0, l, 1 et I dans le mot de passe genere.
.EXAMPLE
    Set-ADTUserPassword -Identity 'jcote' -WhatIf
.EXAMPLE
    Set-ADTUserPassword -Identity 'jcote' -Length 20 -Unlock | New-ADTCredentialDocument -Path C:\Temp\jcote.html
#>
    [System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams', '', Justification = 'Length est une metadonnee de generation; NewPassword est un SecureString et l authentification passe par PSCredential.')]
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true, Position = 0, ValueFromPipeline = $true, ValueFromPipelineByPropertyName = $true)]
        [Alias('SamAccountName', 'User', 'DistinguishedName')]
        [string[]]$Identity,

        [System.Security.SecureString]$NewPassword,
        [ValidateRange(12, 128)][int]$Length = 16,
        [switch]$NoChangeAtNextLogon,
        [switch]$Unlock,
        [switch]$NoSpecial,
        [switch]$IncludeAmbiguous,
        [string]$Server,
        [System.Management.Automation.Credential()][System.Management.Automation.PSCredential]$Credential,
        [string]$LogPath
    )

    begin {
        $common = Initialize-ADTConnection -Server $Server -Credential $Credential -LogPath $LogPath
        $policy = $null
        try { $policy = Get-ADTNativePasswordPolicy @common } catch { $policy = $null }
        $minimum = $Length
        if ($policy -and [int]$policy.MinimumPasswordLength -gt $minimum) {
            $minimum = [int]$policy.MinimumPasswordLength
            Write-Warning ('Longueur portee de {0} a {1} pour respecter la strategie du domaine.' -f $Length, $minimum)
        }
        if ($minimum -gt 128) { $minimum = 128 }
        $domainName = ''
        if ($policy) { $domainName = [string]$policy.DomainName }
    }

    process {
        foreach ($id in $Identity) {
            if (-not $id) { continue }
            $sam = $id
            $status = 'Echec'
            $errorText = ''
            $clear = ''
            $upn = ''
            $displayName = ''
            $secure = $null
            try {
                $user = Resolve-ADTConsoleObject -Identity $id -ObjectFilter (Get-ADTConsoleClassFilter -Type User) @common
                $sam = [string]$user.SamAccountName
                $upn = [string]$user.UserPrincipalName
                $displayName = [string]$user.DisplayName
                $dn = [string]$user.DistinguishedName

                if ($NewPassword) {
                    $secure = $NewPassword
                    $clear = '(fourni par l appelant)'
                } else {
                    $generated = New-ADTRandomPassword -Length $minimum -UseSpecial (-not $NoSpecial) -IncludeAmbiguous:$IncludeAmbiguous
                    $secure = ConvertTo-ADTSecurePassword -Text $generated
                    $clear = $generated
                }

                if ($PSCmdlet.ShouldProcess($sam, 'Reinitialiser le mot de passe')) {
                    Set-ADTNativePassword -Identity $dn -NewPassword $secure -Reset -ErrorAction Stop @common
                    Set-ADTNativeMustChangePassword -DistinguishedName $dn -Required (-not $NoChangeAtNextLogon) -ErrorAction Stop @common
                    if ($Unlock) { Unlock-ADTNativeAccount -DistinguishedName $dn -ErrorAction Stop @common }
                    $status = 'Reinitialise'
                    # Volontairement sans le mot de passe : le journal est un
                    # fichier texte conserve et potentiellement sauvegarde.
                    Write-ADTLog -Level 'SUCCESS' -Message ('Mot de passe reinitialise pour {0} (changement a la prochaine ouverture de session : {1}).' -f $sam, (-not $NoChangeAtNextLogon))
                } else {
                    $status = 'Simulation'
                    $clear = ''
                }
            } catch {
                $errorText = $_.Exception.Message
                $clear = ''
                Write-ADTLog -Level 'ERROR' -Message ('Reinitialisation du mot de passe echouee pour {0} : {1}' -f $sam, $errorText)
            } finally {
                if ($secure -and -not $NewPassword) { $secure.Dispose() }
                $secure = $null
            }

            $row = New-Object PSObject -Property @{
                SamAccountName     = $sam
                DisplayName        = $displayName
                UserPrincipalName  = $upn
                Domain             = $domainName
                Status             = $status
                Password           = $clear
                MustChangePassword = (-not $NoChangeAtNextLogon)
                Error              = $errorText
            }
            $row | Select-Object SamAccountName, DisplayName, UserPrincipalName, Domain, Status, Password, MustChangePassword, Error
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

