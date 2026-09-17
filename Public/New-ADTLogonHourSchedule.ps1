function New-ADTLogonHourSchedule {
<#
.SYNOPSIS
    Construit un horaire de connexion reutilisable, en heure locale.
.DESCRIPTION
    Un horaire est decrit par un masque de 168 caracteres 0 ou 1 : une heure de la
    semaine par caractere, du dimanche 00 h au samedi 23 h, en HEURE LOCALE.
    Set-ADTUserLogonHours applique ce masque a un ou plusieurs comptes ; la
    conversion vers le temps universel attendu par l annuaire est automatique.

    Plusieurs appels peuvent etre combines avec -BaseSchedule pour cumuler des
    plages : une plage de semaine puis une plage du samedi matin, par exemple.
.PARAMETER Day
    Jours vises : Sunday..Saturday ou 0..6. Vide = les sept jours.
.PARAMETER StartHour
    Premiere heure autorisee, de 0 a 23.
.PARAMETER EndHour
    Heure de fin, exclue, de 1 a 24. 18 signifie "jusqu a 18 h 00".
.PARAMETER AllowAll
    Autorise les 168 heures : aucune restriction.
.PARAMETER DenyAll
    Interdit toutes les heures. Le compte ne peut alors plus ouvrir de session.
.PARAMETER BaseSchedule
    Masque existant auquel ajouter la nouvelle plage.
.EXAMPLE
    New-ADTLogonHourSchedule -Day Monday,Tuesday,Wednesday,Thursday,Friday -StartHour 8 -EndHour 18
.EXAMPLE
    $semaine = New-ADTLogonHourSchedule -Day Monday,Tuesday,Wednesday,Thursday,Friday -StartHour 7 -EndHour 19
    New-ADTLogonHourSchedule -Day Saturday -StartHour 9 -EndHour 13 -BaseSchedule $semaine.Mask
#>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][object[]]$Day,
        [ValidateRange(0, 23)][int]$StartHour = 0,
        [ValidateRange(1, 24)][int]$EndHour = 24,
        [switch]$AllowAll,
        [switch]$DenyAll,
        [string]$BaseSchedule
    )

    $addition = New-ADTLogonHoursMask -Day $Day -StartHour $StartHour -EndHour $EndHour -AllowAll:$AllowAll -DenyAll:$DenyAll

    $mask = $addition
    if ($BaseSchedule) {
        if (-not (Test-ADTLogonHoursMask -Mask $BaseSchedule)) { throw 'BaseSchedule invalide : 168 caracteres 0 ou 1 attendus.' }
        if ($DenyAll) { $mask = $addition }
        else {
            $merged = New-Object System.Text.StringBuilder
            for ($slot = 0; $slot -lt 168; $slot++) {
                if ($BaseSchedule[$slot] -eq '1' -or $addition[$slot] -eq '1') { [void]$merged.Append('1') }
                else { [void]$merged.Append('0') }
            }
            $mask = $merged.ToString()
        }
    }

    $allowed = 0
    for ($slot = 0; $slot -lt 168; $slot++) { if ($mask[$slot] -eq '1') { $allowed++ } }

    $result = New-Object PSObject -Property @{
        Mask         = $mask
        Summary      = (ConvertTo-ADTLogonHoursText -Mask $mask)
        AllowedHours = $allowed
        Restricted   = ($mask -ne ('1' * 168))
        OffsetHours  = (Get-ADTLogonHoursOffset)
    }
    return ($result | Select-Object Mask, Summary, AllowedHours, Restricted, OffsetHours)
}
