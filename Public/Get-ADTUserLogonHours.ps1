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
