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
