# Horaires de connexion Active Directory (attribut logonHours).
#
# L attribut est une chaine d octets de 21 octets, soit 168 bits : un bit par
# heure de la semaine. Le bit 0 de l octet 0 est le dimanche de 00 h a 01 h
# EN TEMPS UNIVERSEL. Un bit a 1 autorise la connexion.
#
#   indice UTC i (0..167) -> octet i \ 8, bit i % 8 (bit de poids faible d abord)
#
# ADUC affiche la grille en heure locale : il decale les bits du biais UTC du
# poste. PSADToolkit fait de meme, sinon un horaire "08 h - 18 h" saisi a Montreal
# deviendrait "03 h - 13 h" dans la console Microsoft. Toutes les fonctions qui
# manipulent un MASQUE travaillent donc en HEURE LOCALE, et la conversion en
# octets applique le decalage.
#
# Le masque est une chaine de 168 caracteres 0 ou 1, indice = jour * 24 + heure,
# jour 0 = dimanche local. Format texte volontaire : lisible dans un journal,
# transmissible en ligne de commande et comparable sans objet intermediaire.

function Get-ADTLogonHoursOffset {
<#
.SYNOPSIS
    Decalage horaire local a appliquer aux bits de logonHours, en heures entieres.
.DESCRIPTION
    System.TimeZone existe depuis .NET 2.0, contrairement a TimeZoneInfo : le
    module doit rester utilisable sous Windows PowerShell 2.0.
    logonHours n a qu une resolution d une heure. Les fuseaux a la demi-heure
    (Inde, Terre-Neuve) sont arrondis a l heure la plus proche, comme le fait ADUC.
.EXAMPLE
    Get-ADTLogonHoursOffset
#>
    [CmdletBinding()]
    param([datetime]$Reference = (Get-Date))
    $offset = [System.TimeZone]::CurrentTimeZone.GetUtcOffset($Reference)
    return [int][Math]::Round($offset.TotalHours, 0, [System.MidpointRounding]::AwayFromZero)
}

function Test-ADTLogonHoursMask {
<#
.SYNOPSIS
    Valide un masque d horaires de connexion.
.DESCRIPTION
    Un masque valide compte exactement 168 caracteres 0 ou 1.
.EXAMPLE
    Test-ADTLogonHoursMask -Mask ('1' * 168)
#>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true, Position = 0)][AllowEmptyString()][string]$Mask)
    if ($Mask.Length -ne 168) { return $false }
    return ($Mask -match '^[01]{168}$')
}

function New-ADTLogonHoursMask {
<#
.SYNOPSIS
    Construit un masque d horaires de connexion en heure locale.
.PARAMETER Day
    Jours autorises : Sunday..Saturday, ou 0..6. Vide avec -AllowAll = toute la semaine.
.PARAMETER StartHour
    Premiere heure autorisee (0..23).
.PARAMETER EndHour
    Heure de fin exclue (1..24). 18 signifie "jusqu a 18 h 00".
.PARAMETER AllowAll
    Autorise les 168 heures, en ignorant les autres parametres.
.PARAMETER DenyAll
    Interdit les 168 heures. Un compte sans aucune heure autorisee ne peut plus
    ouvrir de session : l appelant doit confirmer ce choix.
.EXAMPLE
    New-ADTLogonHoursMask -Day 'Monday','Tuesday','Wednesday','Thursday','Friday' -StartHour 8 -EndHour 18
#>
    [CmdletBinding()]
    param(
        [object[]]$Day,
        [ValidateRange(0, 23)][int]$StartHour = 0,
        [ValidateRange(1, 24)][int]$EndHour = 24,
        [switch]$AllowAll,
        [switch]$DenyAll
    )
    if ($AllowAll -and $DenyAll) { throw 'AllowAll et DenyAll s excluent.' }
    if ($AllowAll) { return ('1' * 168) }
    if ($DenyAll) { return ('0' * 168) }
    if ($EndHour -le $StartHour) { throw ('EndHour ({0}) doit etre superieure a StartHour ({1}).' -f $EndHour, $StartHour) }

    $days = New-Object System.Collections.ArrayList
    if (-not $Day -or @($Day).Count -eq 0) {
        for ($index = 0; $index -lt 7; $index++) { [void]$days.Add($index) }
    } else {
        foreach ($item in $Day) {
            if ($null -eq $item) { continue }
            $value = -1
            if ($item -is [int]) { $value = [int]$item }
            else {
                $text = ([string]$item).Trim()
                if ($text -match '^[0-6]$') { $value = [int]$text }
                else {
                    try { $value = [int][System.DayOfWeek]$text }
                    catch { throw ('Jour inconnu : {0}. Utiliser Sunday..Saturday ou 0..6.' -f $text) }
                }
            }
            if ($value -lt 0 -or $value -gt 6) { throw ('Jour hors bornes : {0}' -f $item) }
            if (-not $days.Contains($value)) { [void]$days.Add($value) }
        }
    }

    $mask = New-Object System.Text.StringBuilder
    for ($slot = 0; $slot -lt 168; $slot++) { [void]$mask.Append('0') }
    foreach ($dayIndex in $days) {
        for ($hour = $StartHour; $hour -lt $EndHour; $hour++) {
            $mask[($dayIndex * 24) + $hour] = '1'
        }
    }
    return $mask.ToString()
}

function ConvertFrom-ADTLogonHoursByte {
<#
.SYNOPSIS
    Convertit les 21 octets de logonHours en masque local de 168 caracteres.
.PARAMETER Byte
    Valeur brute de l attribut. $null ou vide signifie "aucune restriction" et
    rend un masque entierement autorise, comme l affiche ADUC.
.EXAMPLE
    ConvertFrom-ADTLogonHoursByte -Byte $user.LogonHours
#>
    [CmdletBinding()]
    param([AllowNull()][byte[]]$Byte, [int]$OffsetHours = ([int]::MinValue))
    if (-not $Byte -or $Byte.Length -eq 0) { return ('1' * 168) }
    if ($Byte.Length -ne 21) { throw ('logonHours doit contenir 21 octets, {0} recu(s).' -f $Byte.Length) }
    if ($OffsetHours -eq [int]::MinValue) { $OffsetHours = Get-ADTLogonHoursOffset }

    # Poids des huit bits d un octet : -shl et -shr n existent qu a partir de
    # PowerShell 3.0, et ce module doit tourner sous 2.0.
    $weight = @(1, 2, 4, 8, 16, 32, 64, 128)
    $mask = New-Object System.Text.StringBuilder
    for ($local = 0; $local -lt 168; $local++) {
        $utc = ((($local - $OffsetHours) % 168) + 168) % 168
        $bit = [int]$Byte[[int][Math]::Floor($utc / 8)] -band [int]$weight[$utc % 8]
        if ($bit -ne 0) { [void]$mask.Append('1') } else { [void]$mask.Append('0') }
    }
    return $mask.ToString()
}

function ConvertTo-ADTLogonHoursByte {
<#
.SYNOPSIS
    Convertit un masque local de 168 caracteres en 21 octets logonHours (UTC).
.EXAMPLE
    ConvertTo-ADTLogonHoursByte -Mask (New-ADTLogonHoursMask -AllowAll)
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Mask,
        [int]$OffsetHours = ([int]::MinValue)
    )
    if (-not (Test-ADTLogonHoursMask -Mask $Mask)) { throw 'Masque d horaires invalide : 168 caracteres 0 ou 1 attendus.' }
    if ($OffsetHours -eq [int]::MinValue) { $OffsetHours = Get-ADTLogonHoursOffset }

    $weight = @(1, 2, 4, 8, 16, 32, 64, 128)
    $bytes = New-Object 'System.Byte[]' 21
    for ($local = 0; $local -lt 168; $local++) {
        if ($Mask[$local] -ne '1') { continue }
        $utc = ((($local - $OffsetHours) % 168) + 168) % 168
        $index = [int][Math]::Floor($utc / 8)
        $bytes[$index] = [byte]([int]$bytes[$index] -bor [int]$weight[$utc % 8])
    }
    return , $bytes
}

function Get-ADTLogonHoursDayMask {
<#
.SYNOPSIS
    Extrait les 24 heures d un jour a partir d un masque complet.
.EXAMPLE
    Get-ADTLogonHoursDayMask -Mask $mask -DayOfWeek 1
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Mask,
        [Parameter(Mandatory = $true)][int]$DayOfWeek
    )
    if (-not (Test-ADTLogonHoursMask -Mask $Mask)) { throw 'Masque d horaires invalide.' }
    if ($DayOfWeek -lt 0 -or $DayOfWeek -gt 6) { throw ('Jour hors bornes : {0}' -f $DayOfWeek) }
    return $Mask.Substring($DayOfWeek * 24, 24)
}

function ConvertTo-ADTLogonHoursText {
<#
.SYNOPSIS
    Resume lisible d un masque d horaires, dans la langue et le format de la machine.
.DESCRIPTION
    Les jours dont l horaire est identique sont regroupes. Les noms de jours et
    les heures suivent la culture courante (Format-ADTDayName, Format-ADTHourLabel).
.EXAMPLE
    ConvertTo-ADTLogonHoursText -Mask $mask
#>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true, Position = 0)][string]$Mask)
    if (-not (Test-ADTLogonHoursMask -Mask $Mask)) { throw 'Masque d horaires invalide.' }
    if ($Mask -eq ('1' * 168)) { return 'Toutes les heures autorisees' }
    if ($Mask -eq ('0' * 168)) { return 'Aucune heure autorisee' }

    # Regrouper les jours consecutifs (dans l ordre d affichage de la culture)
    # qui partagent exactement le meme horaire.
    $segments = New-Object System.Collections.ArrayList
    $order = Get-ADTWeekDayOrder
    $currentDays = New-Object System.Collections.ArrayList
    $currentPattern = $null
    foreach ($dayIndex in $order) {
        $pattern = Get-ADTLogonHoursDayMask -Mask $Mask -DayOfWeek $dayIndex
        if ($null -ne $currentPattern -and $pattern -eq $currentPattern) {
            [void]$currentDays.Add($dayIndex)
            continue
        }
        if ($null -ne $currentPattern) { [void]$segments.Add((New-Object PSObject -Property @{ Days = @($currentDays); Pattern = $currentPattern })) }
        $currentDays = New-Object System.Collections.ArrayList
        [void]$currentDays.Add($dayIndex)
        $currentPattern = $pattern
    }
    if ($null -ne $currentPattern) { [void]$segments.Add((New-Object PSObject -Property @{ Days = @($currentDays); Pattern = $currentPattern })) }

    $parts = New-Object System.Collections.ArrayList
    foreach ($segment in $segments) {
        $days = @($segment.Days)
        $label = Format-ADTDayName -DayOfWeek $days[0] -Abbreviated
        if ($days.Count -gt 1) { $label = $label + '-' + (Format-ADTDayName -DayOfWeek $days[$days.Count - 1] -Abbreviated) }
        [void]$parts.Add(($label + ' ' + (ConvertTo-ADTLogonHoursRangeText -DayPattern ([string]$segment.Pattern))))
    }
    return ($parts -join ' ; ')
}

function ConvertTo-ADTLogonHoursRangeText {
<#
.SYNOPSIS
    Traduit les 24 bits d un jour en plages horaires lisibles.
.EXAMPLE
    ConvertTo-ADTLogonHoursRangeText -DayPattern ('0' * 8 + '1' * 10 + '0' * 6)
#>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true, Position = 0)][string]$DayPattern)
    if ($DayPattern.Length -ne 24) { throw 'Un jour compte 24 heures.' }
    if ($DayPattern -eq ('0' * 24)) { return 'aucune' }
    if ($DayPattern -eq ('1' * 24)) { return '24 h' }

    $ranges = New-Object System.Collections.ArrayList
    $start = -1
    for ($hour = 0; $hour -le 24; $hour++) {
        $allowed = $false
        if ($hour -lt 24 -and $DayPattern[$hour] -eq '1') { $allowed = $true }
        if ($allowed -and $start -lt 0) { $start = $hour }
        if (-not $allowed -and $start -ge 0) {
            [void]$ranges.Add(((Format-ADTHourLabel -Hour $start) + '-' + (Format-ADTHourLabel -Hour $hour)))
            $start = -1
        }
    }
    return ($ranges -join ', ')
}
