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
