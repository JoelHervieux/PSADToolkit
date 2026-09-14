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
