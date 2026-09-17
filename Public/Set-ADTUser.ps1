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
