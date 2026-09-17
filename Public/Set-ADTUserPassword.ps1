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
