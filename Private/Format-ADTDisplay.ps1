# Formats regionaux. Tout ce que PSADToolkit AFFICHE (grilles, dialogues, rapports)
# doit suivre la culture de la machine qui execute l application, jamais un format
# code en dur. Le journal fait exception : Write-ADTLog garde un horodatage ISO
# 8601, trie et lisible quel que soit le poste qui relit le fichier d audit.

function Get-ADTDisplayCulture {
<#
.SYNOPSIS
    Culture d affichage courante de la machine.
.DESCRIPTION
    CurrentCulture suit le format regional de l utilisateur Windows. En cas de
    culture invariante (service, tache planifiee), on retombe sur la culture de
    l interface utilisateur puis sur la culture installee.
.EXAMPLE
    (Get-ADTDisplayCulture).Name
#>
    [CmdletBinding()]
    param()
    $culture = [System.Globalization.CultureInfo]::CurrentCulture
    if ($culture -and -not $culture.Name) { $culture = [System.Globalization.CultureInfo]::CurrentUICulture }
    if ($culture -and -not $culture.Name) { $culture = [System.Globalization.CultureInfo]::InstalledUICulture }
    return $culture
}

function Format-ADTDateTime {
<#
.SYNOPSIS
    Met en forme une date/heure selon le format regional de la machine.
.PARAMETER Value
    DateTime, chaine convertible ou $null. $null et les dates vides rendent ''.
.PARAMETER Kind
    DateTime (defaut), Date, Time ou Long.
.EXAMPLE
    Format-ADTDateTime -Value (Get-Date) -Kind Date
#>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][AllowNull()]$Value,
        [ValidateSet('DateTime', 'Date', 'Time', 'Long')]
        [string]$Kind = 'DateTime'
    )
    if ($null -eq $Value) { return '' }
    if ($Value -is [string] -and -not $Value) { return '' }

    $moment = $null
    if ($Value -is [datetime]) { $moment = [datetime]$Value }
    else {
        try { $moment = [datetime]::Parse([string]$Value, (Get-ADTDisplayCulture)) }
        catch { return [string]$Value }
    }
    if ($moment -eq [datetime]::MinValue) { return '' }

    $culture = Get-ADTDisplayCulture
    switch ($Kind) {
        'Date' { return $moment.ToString('d', $culture) }
        'Time' { return $moment.ToString('t', $culture) }
        'Long' { return $moment.ToString('F', $culture) }
        default { return $moment.ToString('g', $culture) }
    }
}

function Format-ADTDayName {
<#
.SYNOPSIS
    Nom du jour de la semaine dans la langue de la machine.
.PARAMETER DayOfWeek
    0 = dimanche ... 6 = samedi, ou une valeur System.DayOfWeek.
.PARAMETER Abbreviated
    Rend l abreviation (lun., mar., ...) au lieu du nom complet.
.EXAMPLE
    Format-ADTDayName -DayOfWeek 1 -Abbreviated
#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]$DayOfWeek,
        [switch]$Abbreviated
    )
    $index = [int]$DayOfWeek
    if ($index -lt 0 -or $index -gt 6) { throw ('Jour de la semaine hors bornes : {0}' -f $index) }
    $format = (Get-ADTDisplayCulture).DateTimeFormat
    if ($Abbreviated) { return [string]$format.AbbreviatedDayNames[$index] }
    return [string]$format.DayNames[$index]
}

function Get-ADTWeekDayOrder {
<#
.SYNOPSIS
    Ordre d affichage des sept jours selon la culture de la machine.
.DESCRIPTION
    Rend les indices 0..6 (dimanche..samedi) reordonnes a partir du premier jour
    de la semaine de la culture : lundi en France et au Canada francais, dimanche
    aux Etats-Unis. La grille des horaires de connexion suit cet ordre.
.EXAMPLE
    Get-ADTWeekDayOrder
#>
    [CmdletBinding()]
    param()
    $first = [int](Get-ADTDisplayCulture).DateTimeFormat.FirstDayOfWeek
    $order = New-Object System.Collections.ArrayList
    for ($step = 0; $step -lt 7; $step++) { [void]$order.Add((($first + $step) % 7)) }
    return [int[]]@($order)
}

function Format-ADTHourLabel {
<#
.SYNOPSIS
    Libelle d une heure pleine selon le format regional (24 h ou AM/PM).
.PARAMETER Hour
    Heure locale de 0 a 24. 24 designe minuit de fin de journee.
.EXAMPLE
    Format-ADTHourLabel -Hour 13
#>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true, Position = 0)][int]$Hour)
    if ($Hour -lt 0 -or $Hour -gt 24) { throw ('Heure hors bornes : {0}' -f $Hour) }
    $culture = Get-ADTDisplayCulture
    $moment = (New-Object System.DateTime(2000, 1, 1, 0, 0, 0)).AddHours($Hour)
    return $moment.ToString($culture.DateTimeFormat.ShortTimePattern, $culture)
}

function Test-ADTUses24HourClock {
<#
.SYNOPSIS
    Indique si la culture de la machine affiche l heure sur 24 h.
.DESCRIPTION
    Sert a dimensionner les en-tetes de la grille des horaires de connexion :
    "13" tient dans une colonne etroite, "1 PM" demande plus de place.

    Les litteraux du motif sont retires avant l analyse : le francais du Canada
    utilise "HH 'h' mm", ou le h entre apostrophes est le separateur d heure et non
    le specificateur d heure sur 12. Sans ce nettoyage, une horloge de 24 heures
    serait prise pour une horloge de 12 heures.
.EXAMPLE
    Test-ADTUses24HourClock
#>
    [CmdletBinding()]
    param()
    $pattern = [string](Get-ADTDisplayCulture).DateTimeFormat.ShortTimePattern
    $pattern = [System.Text.RegularExpressions.Regex]::Replace($pattern, '\\.', '')
    $pattern = [System.Text.RegularExpressions.Regex]::Replace($pattern, "'[^']*'", '')
    $pattern = [System.Text.RegularExpressions.Regex]::Replace($pattern, '"[^"]*"', '')
    return ($pattern -cnotmatch 'h' -and $pattern -cnotmatch 't')
}

function Format-ADTHourHeader {
<#
.SYNOPSIS
    Etiquette compacte d une heure pour l en-tete de la grille des horaires.
.DESCRIPTION
    Une colonne de la grille des horaires de connexion fait quelques pixels de
    large : "13" y tient, "1:00 PM" non. La fonction respecte tout de meme la
    convention horaire de la culture : 00 a 23 sur une horloge de 24 heures,
    12a / 1p sur une horloge de 12 heures, avec le designateur de la culture.
.EXAMPLE
    Format-ADTHourHeader -Hour 13
#>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true, Position = 0)][int]$Hour)
    if ($Hour -lt 0 -or $Hour -gt 23) { throw ('Heure hors bornes : {0}' -f $Hour) }
    if (Test-ADTUses24HourClock) { return ('{0:00}' -f $Hour) }

    $format = (Get-ADTDisplayCulture).DateTimeFormat
    $designator = [string]$format.AMDesignator
    if ($Hour -ge 12) { $designator = [string]$format.PMDesignator }
    if ($designator) { $designator = $designator.Substring(0, 1).ToLower() }
    $display = $Hour % 12
    if ($display -eq 0) { $display = 12 }
    return ([string]$display + $designator)
}
