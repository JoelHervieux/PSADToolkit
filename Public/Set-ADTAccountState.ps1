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
