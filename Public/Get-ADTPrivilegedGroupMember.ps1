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
