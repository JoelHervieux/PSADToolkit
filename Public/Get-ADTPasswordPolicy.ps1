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
