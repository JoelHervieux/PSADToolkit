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
