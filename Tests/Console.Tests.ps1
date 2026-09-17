# Regressions de la console d administration, sans Active Directory : le backend
# LDAP est simule, seule la logique du module est exercee.
BeforeAll {
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'PSADToolkit.psd1') -Force
}

Describe 'Horaires de connexion : conversion logonHours' {
    It 'Produit la disposition d octets documentee par Active Directory' {
        InModuleScope PSADToolkit {
            # Lundi 08 h - 18 h, sans decalage : dimanche occupe les octets 0 a 2,
            # lundi commence au bit 24. Les heures 8 a 17 couvrent les bits 32 a 41.
            $mask = New-ADTLogonHoursMask -Day 'Monday' -StartHour 8 -EndHour 18
            $bytes = ConvertTo-ADTLogonHoursByte -Mask $mask -OffsetHours 0
            $bytes.Length | Should -Be 21
            ($bytes | ForEach-Object { '{0:x2}' -f $_ }) -join '' | Should -Be '00000000ff0300000000000000000000000000'.PadRight(42, '0')
        }
    }
    It 'Fait l aller-retour masque -> octets -> masque pour tous les decalages horaires' {
        InModuleScope PSADToolkit {
            $mask = New-ADTLogonHoursMask -Day 1, 2, 3, 4, 5 -StartHour 8 -EndHour 18
            foreach ($offset in -12..14) {
                $bytes = ConvertTo-ADTLogonHoursByte -Mask $mask -OffsetHours $offset
                ConvertFrom-ADTLogonHoursByte -Byte $bytes -OffsetHours $offset | Should -Be $mask -Because ('decalage ' + $offset)
            }
        }
    }
    It 'Decale bien les bits selon le fuseau plutot que de les recopier' {
        InModuleScope PSADToolkit {
            # 08 h locale a UTC-5 correspond a 13 h UTC : les octets doivent differer.
            $mask = New-ADTLogonHoursMask -Day 'Monday' -StartHour 8 -EndHour 18
            $utc = ConvertTo-ADTLogonHoursByte -Mask $mask -OffsetHours 0
            $montreal = ConvertTo-ADTLogonHoursByte -Mask $mask -OffsetHours -5
            (Compare-Object $utc $montreal -SyncWindow 0) | Should -Not -BeNullOrEmpty
            # Relu avec le meme decalage, l horaire local reste 08 h - 18 h.
            ConvertFrom-ADTLogonHoursByte -Byte $montreal -OffsetHours -5 | Should -Be $mask
        }
    }
    It 'Traite un attribut absent comme "toutes les heures autorisees"' {
        InModuleScope PSADToolkit {
            ConvertFrom-ADTLogonHoursByte -Byte $null | Should -Be ('1' * 168)
            ConvertFrom-ADTLogonHoursByte -Byte ([byte[]]@()) | Should -Be ('1' * 168)
        }
    }
    It 'Refuse un masque de longueur ou d alphabet invalide' {
        InModuleScope PSADToolkit {
            Test-ADTLogonHoursMask -Mask ('1' * 167) | Should -BeFalse
            Test-ADTLogonHoursMask -Mask (('1' * 167) + '2') | Should -BeFalse
            { ConvertTo-ADTLogonHoursByte -Mask 'abc' } | Should -Throw '*invalide*'
        }
    }
    It 'Refuse un nombre d octets different de 21' {
        InModuleScope PSADToolkit {
            { ConvertFrom-ADTLogonHoursByte -Byte ([byte[]]@(1, 2, 3)) } | Should -Throw '*21 octets*'
        }
    }
}

Describe 'Horaires de connexion : construction et resume' {
    It 'Cumule deux plages avec -BaseSchedule' {
        $semaine = New-ADTLogonHourSchedule -Day Monday, Tuesday, Wednesday, Thursday, Friday -StartHour 8 -EndHour 18
        $complet = New-ADTLogonHourSchedule -Day Saturday -StartHour 9 -EndHour 13 -BaseSchedule $semaine.Mask
        $complet.AllowedHours | Should -Be ($semaine.AllowedHours + 4)
        $complet.Mask.Substring(6 * 24, 24) | Should -Be ('000000000' + '1111' + '00000000000')
    }
    It 'Signale un horaire sans restriction' {
        $tout = New-ADTLogonHourSchedule -AllowAll
        $tout.Restricted | Should -BeFalse
        $tout.Summary | Should -Be 'Toutes les heures autorisees'
    }
    It 'Regroupe les jours identiques dans le resume' {
        InModuleScope PSADToolkit {
            $mask = New-ADTLogonHoursMask -Day 1, 2, 3, 4, 5 -StartHour 8 -EndHour 18
            $texte = ConvertTo-ADTLogonHoursText -Mask $mask
            $texte | Should -BeLike '*-*'
            ($texte -split ';').Count | Should -BeLessOrEqual 3
        }
    }
    It 'Refuse une plage dont la fin precede le debut' {
        InModuleScope PSADToolkit {
            { New-ADTLogonHoursMask -Day 1 -StartHour 18 -EndHour 8 } | Should -Throw '*superieure*'
        }
    }
}

Describe 'Formats regionaux' {
    It 'Suit la culture de la machine pour les dates' {
        InModuleScope PSADToolkit {
            $moment = [datetime]'2026-09-17 17:05:00'
            $reference = [System.Threading.Thread]::CurrentThread.CurrentCulture
            try {
                [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::new('fr-FR')
                Format-ADTDateTime -Value $moment -Kind Date | Should -Be '17/09/2026'
                [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::new('en-US')
                Format-ADTDateTime -Value $moment -Kind Date | Should -Be '9/17/2026'
            } finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $reference }
        }
    }
    It 'Ne prend pas le separateur d heure francais pour une horloge de 12 heures' {
        InModuleScope PSADToolkit {
            $reference = [System.Threading.Thread]::CurrentThread.CurrentCulture
            try {
                # fr-CA utilise le motif "HH 'h' mm" : le h entre apostrophes est un
                # litteral, pas le specificateur d heure sur 12.
                [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::new('fr-CA')
                Test-ADTUses24HourClock | Should -BeTrue
                Format-ADTHourHeader -Hour 13 | Should -Be '13'
                [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::new('en-US')
                Test-ADTUses24HourClock | Should -BeFalse
                Format-ADTHourHeader -Hour 13 | Should -Be '1p'
            } finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $reference }
        }
    }
    It 'Ordonne les jours a partir du premier jour de la semaine de la culture' {
        InModuleScope PSADToolkit {
            $reference = [System.Threading.Thread]::CurrentThread.CurrentCulture
            try {
                [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::new('fr-FR')
                (Get-ADTWeekDayOrder)[0] | Should -Be 1
                [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::new('en-US')
                (Get-ADTWeekDayOrder)[0] | Should -Be 0
            } finally { [System.Threading.Thread]::CurrentThread.CurrentCulture = $reference }
            @(Get-ADTWeekDayOrder) | Sort-Object | Should -Be @(0, 1, 2, 3, 4, 5, 6)
        }
    }
    It 'Rend une chaine vide pour une date absente' {
        InModuleScope PSADToolkit {
            Format-ADTDateTime -Value $null | Should -Be ''
            Format-ADTDateTime -Value '' | Should -Be ''
            Format-ADTDateTime -Value ([datetime]::MinValue) | Should -Be ''
        }
    }
}

Describe 'Nom relatif d un objet' {
    It 'Retire le prefixe et les echappements du RDN' {
        InModuleScope PSADToolkit {
            Get-ADTRdnValue -DistinguishedName 'CN=GS-VPN,OU=Groupes,DC=contoso,DC=local' | Should -Be 'GS-VPN'
            Get-ADTRdnValue -DistinguishedName 'CN=Cote\, Joel,OU=Employes,DC=contoso,DC=local' | Should -Be 'Cote, Joel'
            Get-ADTRdnValue -DistinguishedName 'OU=Ventes,DC=contoso,DC=local' | Should -Be 'Ventes'
            Get-ADTRdnValue -DistinguishedName '' | Should -Be ''
        }
    }
    It 'Trouve le conteneur parent malgre une virgule echappee' {
        InModuleScope PSADToolkit {
            Get-ADTParentDistinguishedName -DistinguishedName 'CN=Cote\, Joel,OU=Employes,DC=contoso,DC=local' |
                Should -Be 'OU=Employes,DC=contoso,DC=local'
        }
    }
}

Describe 'Generateur de mots de passe' {
    It 'Respecte les classes de caracteres demandees' {
        $sansSpecial = (New-ADTPassword -NoPolicyCheck -Length 32 -NoSpecial).Password
        $sansSpecial | Should -Match '^[A-Za-z0-9]+$'
        $chiffres = (New-ADTPassword -NoPolicyCheck -Length 20 -NoUppercase -NoLowercase -NoSpecial).Password
        $chiffres | Should -Match '^[0-9]+$'
    }
    It 'Exclut les caracteres ambigus sauf demande contraire' {
        $mots = 1..40 | ForEach-Object { (New-ADTPassword -NoPolicyCheck -Length 24).Password }
        # -Match ignore la casse : un o minuscule satisferait [O]. La comparaison
        # doit donc etre explicitement sensible a la casse.
        ($mots -join '') | Should -Not -MatchExactly '[O0lI1]'
        (New-ADTPassword -NoPolicyCheck -Length 24 -IncludeAmbiguous).Password | Should -Not -BeNullOrEmpty
    }
    It 'Produit la longueur demandee et des valeurs distinctes' {
        $mots = @(New-ADTPassword -NoPolicyCheck -Length 18 -Count 25)
        $mots.Count | Should -Be 25
        foreach ($item in $mots) { $item.Length | Should -Be 18 }
        (@($mots | Select-Object -ExpandProperty Password | Sort-Object -Unique)).Count | Should -Be 25
    }
    It 'Releve la longueur au minimum de la strategie du domaine' {
        InModuleScope PSADToolkit {
            Mock Initialize-ADTConnection { return @{} }
            Mock Get-ADTNativePasswordPolicy {
                return (New-Object PSObject -Property @{
                        DomainName = 'contoso.local'; MinimumPasswordLength = 24; ComplexityEnabled = $true
                        Source = 'Strategie de domaine par defaut'; LockoutDurationTicks = [long]0
                    })
            }
            $result = New-ADTPassword -Length 12 -WarningAction SilentlyContinue
            $result.Length | Should -Be 24
            $result.MeetsPolicy | Should -BeTrue
        }
    }
    It 'Refuse une longueur insuffisante pour couvrir les classes demandees' {
        InModuleScope PSADToolkit {
            { New-ADTRandomPassword -Length 12 -UseUppercase $false -UseLowercase $false -UseDigit $false -UseSpecial $false } |
                Should -Throw '*Aucune classe*'
        }
    }
    It 'Evalue la complexite comme Active Directory' {
        InModuleScope PSADToolkit {
            (Test-ADTPasswordComplexity -Password 'Abcdef1!' -MinimumLength 8).Valid | Should -BeTrue
            (Test-ADTPasswordComplexity -Password 'abcdefgh' -MinimumLength 8).Valid | Should -BeFalse
            (Test-ADTPasswordComplexity -Password 'Abc1!' -MinimumLength 8).Issues | Should -BeLike '*Longueur*'
        }
    }
}

Describe 'Recherche dans l annuaire' {
    It 'Echappe le terme avant d ajouter les jokers' {
        InModuleScope PSADToolkit {
            $script:CapturedFilter = ''
            Mock Initialize-ADTConnection { return @{} }
            Mock Get-ADTNativePasswordPolicy { return (New-Object PSObject -Property @{ LockoutDurationTicks = [long]0 }) }
            Mock Search-ADTDirectoryEntry { param($LDAPFilter) $script:CapturedFilter = $LDAPFilter; return @() }
            $null = Find-ADTDirectoryObject -SearchTerm 'a*)(objectClass=*' -Type User
            # L etoile et les parentheses saisies deviennent du texte; seuls les
            # jokers ajoutes par la fonction restent des jokers.
            $script:CapturedFilter | Should -BeLike '*\2a\29\28objectClass=\2a*'
            # Le terme brut ne doit apparaitre nulle part tel quel : il fermerait la
            # clause courante et ajouterait la sienne.
            $script:CapturedFilter.Contains('a*)(objectClass=*') | Should -BeFalse
            $texte = $script:CapturedFilter
            (@($texte.ToCharArray() | Where-Object { $_ -eq '(' })).Count |
                Should -Be (@($texte.ToCharArray() | Where-Object { $_ -eq ')' })).Count
        }
    }
    It 'Limite la recherche a l unite demandee' {
        InModuleScope PSADToolkit {
            $script:CapturedBase = ''
            Mock Initialize-ADTConnection { return @{} }
            Mock Get-ADTNativePasswordPolicy { return (New-Object PSObject -Property @{ LockoutDurationTicks = [long]0 }) }
            Mock Search-ADTDirectoryEntry { param($LDAPFilter, $SearchBase) $script:CapturedBase = [string]$SearchBase; return @() }
            $null = Find-ADTDirectoryObject -SearchTerm 'test' -SearchBase 'OU=Ventes,DC=contoso,DC=local'
            $script:CapturedBase | Should -Be 'OU=Ventes,DC=contoso,DC=local'
        }
    }
    It 'Refuse un nom d attribut qui n en est pas un' {
        InModuleScope PSADToolkit {
            Mock Initialize-ADTConnection { return @{} }
            Mock Get-ADTNativePasswordPolicy { return (New-Object PSObject -Property @{ LockoutDurationTicks = [long]0 }) }
            Mock Search-ADTDirectoryEntry { return @() }
            { Find-ADTDirectoryObject -SearchTerm 'test' -Attribute 'name)(objectClass=*' } | Should -Throw '*invalide*'
        }
    }
}

Describe 'Modification d un compte' {
    It 'N ecrit que les proprietes explicitement fournies' {
        InModuleScope PSADToolkit {
            $script:Written = $null
            Mock Initialize-ADTConnection { return @{} }
            Mock Resolve-ADTConsoleObject {
                return (New-Object PSObject -Property @{
                        SamAccountName = 'jcote'; DistinguishedName = 'CN=jcote,OU=Employes,DC=contoso,DC=local'; ObjectClass = 'user'
                    })
            }
            Mock Set-ADTNativeObjectAttribute { param($DistinguishedName, $Attribute) $script:Written = $Attribute }
            Mock Set-ADTNativeAccountControl { }
            $result = Set-ADTUser -Identity 'jcote' -Title 'Analyste' -Department '' -Confirm:$false
            $result.Status | Should -Be 'Modifie'
            @($script:Written.Keys) | Should -Contain 'title'
            @($script:Written.Keys) | Should -Contain 'department'
            # Une chaine vide efface l attribut; les champs non fournis restent absents.
            $script:Written['department'] | Should -Be ''
            @($script:Written.Keys) | Should -Not -Contain 'mail'
            @($script:Written.Keys) | Should -Not -Contain 'givenName'
        }
    }
    It 'Fait expirer le compte a la fin du jour indique' {
        InModuleScope PSADToolkit {
            $script:Expiry = 'absent'
            Mock Initialize-ADTConnection { return @{} }
            Mock Resolve-ADTConsoleObject {
                return (New-Object PSObject -Property @{
                        SamAccountName = 'jcote'; DistinguishedName = 'CN=jcote,DC=contoso,DC=local'; ObjectClass = 'user'
                    })
            }
            Mock Set-ADTNativeAccountExpiration { param($DistinguishedName, $ExpiresAfter) $script:Expiry = $ExpiresAfter }
            $null = Set-ADTUser -Identity 'jcote' -AccountExpirationDate ([datetime]'2027-06-30 14:00') -Confirm:$false
            ([datetime]$script:Expiry) | Should -Be ([datetime]'2027-07-01 00:00:00')

            $null = Set-ADTUser -Identity 'jcote' -NeverExpires -Confirm:$false
            $script:Expiry | Should -BeNullOrEmpty
        }
    }
    It 'Refuse une expiration a la fois datee et perpetuelle' {
        InModuleScope PSADToolkit {
            Mock Initialize-ADTConnection { return @{} }
            { Set-ADTUser -Identity 'jcote' -NeverExpires -AccountExpirationDate ([datetime]'2027-01-01') -Confirm:$false } |
                Should -Throw '*excluent*'
        }
    }
    It 'Exige au moins une propriete a modifier' {
        InModuleScope PSADToolkit {
            Mock Initialize-ADTConnection { return @{} }
            Mock Resolve-ADTConsoleObject {
                return (New-Object PSObject -Property @{
                        SamAccountName = 'jcote'; DistinguishedName = 'CN=jcote,DC=contoso,DC=local'; ObjectClass = 'user'
                    })
            }
            $result = Set-ADTUser -Identity 'jcote' -Confirm:$false
            $result.Status | Should -Be 'Echec'
            $result.Error | Should -BeLike '*au moins un parametre*'
        }
    }
}

Describe 'Application d horaires a un groupe' {
    It 'Applique aux membres sauf ceux exclus' {
        InModuleScope PSADToolkit {
            $script:Applied = New-Object System.Collections.ArrayList
            Mock Initialize-ADTConnection { return @{} }
            Mock Get-ADTGroupMember {
                return @(
                    (New-Object PSObject -Property @{ SamAccountName = 'jcote'; DistinguishedName = 'CN=jcote,DC=t,DC=l'; ObjectClass = 'user' }),
                    (New-Object PSObject -Property @{ SamAccountName = 'mtremblay'; DistinguishedName = 'CN=mtremblay,DC=t,DC=l'; ObjectClass = 'user' }),
                    (New-Object PSObject -Property @{ SamAccountName = 'dgagnon'; DistinguishedName = 'CN=dgagnon,DC=t,DC=l'; ObjectClass = 'user' }),
                    (New-Object PSObject -Property @{ SamAccountName = 'GS-Imbrique'; DistinguishedName = 'CN=GS-Imbrique,DC=t,DC=l'; ObjectClass = 'group' })
                )
            }
            Mock Resolve-ADTConsoleObject {
                param($Identity)
                return (New-Object PSObject -Property @{
                        SamAccountName = (Get-ADTRdnValue -DistinguishedName $Identity); DistinguishedName = $Identity; ObjectClass = 'user'
                    })
            }
            Mock Set-ADTNativeLogonHours { param($DistinguishedName, $Mask) [void]$script:Applied.Add($DistinguishedName) }

            $mask = New-ADTLogonHoursMask -Day 1, 2, 3, 4, 5 -StartHour 8 -EndHour 18
            $results = @(Set-ADTUserLogonHours -Group 'GS-Ventes' -ExcludeIdentity 'dgagnon' -Schedule $mask -Confirm:$false)

            $results.Count | Should -Be 2
            @($script:Applied) | Should -Contain 'CN=jcote,DC=t,DC=l'
            @($script:Applied) | Should -Contain 'CN=mtremblay,DC=t,DC=l'
            # L exclu garde son horaire, et le groupe imbrique n est pas un compte.
            @($script:Applied) | Should -Not -Contain 'CN=dgagnon,DC=t,DC=l'
            @($script:Applied) | Should -Not -Contain 'CN=GS-Imbrique,DC=t,DC=l'
        }
    }
    It 'Refuse un horaire sans aucune heure sans confirmation explicite' {
        InModuleScope PSADToolkit {
            Mock Initialize-ADTConnection { return @{} }
            { Set-ADTUserLogonHours -Identity 'jcote' -Schedule ('0' * 168) -Confirm:$false } |
                Should -Throw '*AllowNoLogonWindow*'
        }
    }
    It 'Refuse un masque mal forme avant toute ecriture' {
        InModuleScope PSADToolkit {
            Mock Initialize-ADTConnection { return @{} }
            Mock Set-ADTNativeLogonHours { throw 'ne doit pas etre appele' }
            { Set-ADTUserLogonHours -Identity 'jcote' -Schedule '1010' -Confirm:$false } | Should -Throw '*168 caracteres*'
        }
    }
}

Describe 'Garde-fous de suppression et de deplacement' {
    It 'Refuse de supprimer une unite non vide sans -Recursive' {
        InModuleScope PSADToolkit {
            Mock Initialize-ADTConnection { return @{} }
            Mock Resolve-ADTConsoleObject {
                return (New-Object PSObject -Property @{
                        Name = 'Ventes'; SamAccountName = ''; ObjectClass = 'organizationalUnit'
                        ObjectType = 'Unite d organisation'; DistinguishedName = 'OU=Ventes,DC=contoso,DC=local'
                    })
            }
            Mock Get-ADTNativeContainerChild { return @(1, 2, 3) }
            Mock Get-ADTNativeDeletionProtection { return $false }
            Mock Remove-ADTNativeObject { throw 'ne doit pas etre appele' }
            $result = Remove-ADTObject -Identity 'OU=Ventes,DC=contoso,DC=local' -Confirm:$false
            $result.Status | Should -Be 'Echec'
            $result.Error | Should -BeLike '*3 objet(s)*'
        }
    }
    It 'Refuse de supprimer un objet protege sans -RemoveProtection' {
        InModuleScope PSADToolkit {
            Mock Initialize-ADTConnection { return @{} }
            Mock Resolve-ADTConsoleObject {
                return (New-Object PSObject -Property @{
                        Name = 'Ventes'; SamAccountName = ''; ObjectClass = 'organizationalUnit'
                        ObjectType = 'Unite d organisation'; DistinguishedName = 'OU=Ventes,DC=contoso,DC=local'
                    })
            }
            Mock Get-ADTNativeContainerChild { return @() }
            Mock Get-ADTNativeDeletionProtection { return $true }
            Mock Remove-ADTNativeObject { throw 'ne doit pas etre appele' }
            $result = Remove-ADTObject -Identity 'OU=Ventes,DC=contoso,DC=local' -Confirm:$false
            $result.Status | Should -Be 'Echec'
            $result.Error | Should -BeLike '*suppression accidentelle*'
        }
    }
    It 'Refuse de deplacer un conteneur dans sa propre sous-arborescence' {
        InModuleScope PSADToolkit {
            Mock Initialize-ADTConnection { return @{} }
            Mock Resolve-ADTConsoleObject {
                param($Identity)
                $class = 'organizationalUnit'
                return (New-Object PSObject -Property @{
                        Name = (Get-ADTRdnValue -DistinguishedName $Identity); SamAccountName = ''
                        ObjectClass = $class; ObjectType = 'Unite d organisation'; DistinguishedName = $Identity
                    })
            }
            Mock Move-ADTNativeObject { throw 'ne doit pas etre appele' }
            $result = Move-ADTObject -Identity 'OU=Ventes,DC=contoso,DC=local' `
                -TargetPath 'OU=Interne,OU=Ventes,DC=contoso,DC=local' -Confirm:$false
            $result.Status | Should -Be 'Echec'
            $result.Error | Should -BeLike '*sous-unites*'
        }
    }
    It 'Refuse une destination qui n est pas un conteneur' {
        InModuleScope PSADToolkit {
            Mock Initialize-ADTConnection { return @{} }
            Mock Resolve-ADTConsoleObject {
                return (New-Object PSObject -Property @{
                        Name = 'jcote'; ObjectClass = 'user'; ObjectType = 'Utilisateur'
                        DistinguishedName = 'CN=jcote,DC=contoso,DC=local'
                    })
            }
            { Move-ADTObject -Identity 'mtremblay' -TargetPath 'CN=jcote,DC=contoso,DC=local' -Confirm:$false } |
                Should -Throw '*pas un conteneur*'
        }
    }
}

Describe 'Membres d un groupe' {
    It 'Refuse de retirer un membre de son groupe principal' {
        InModuleScope PSADToolkit {
            Mock Initialize-ADTConnection { return @{} }
            Mock Resolve-ADTConsoleObject {
                param($Identity, $ObjectFilter)
                if ($ObjectFilter -like '*group*') {
                    # SecurityIdentifier n est pas constructible hors Windows : seul
                    # .Value est lu par la fonction testee.
                    $sid = New-Object PSObject -Property @{ Value = 'S-1-5-21-1-2-3-513' }
                    return (New-Object PSObject -Property @{
                            Name = 'Utilisateurs du domaine'; DistinguishedName = 'CN=Utilisateurs du domaine,DC=t,DC=l'
                            ObjectClass = 'group'; SID = $sid
                        })
                }
                return (New-Object PSObject -Property @{
                        Name = 'jcote'; SamAccountName = 'jcote'; DistinguishedName = 'CN=jcote,DC=t,DC=l'
                        ObjectClass = 'user'; PrimaryGroupID = '513'
                    })
            }
            Mock Remove-ADTNativeGroupMember { throw 'ne doit pas etre appele' }
            $result = Set-ADTGroupMember -Identity 'Utilisateurs du domaine' -RemoveMember 'jcote' -Confirm:$false
            $result.Status | Should -Be 'Echec'
            $result.Error | Should -BeLike '*groupe principal*'
        }
    }
    It 'Refuse un membre demande a la fois en ajout et en retrait' {
        InModuleScope PSADToolkit {
            Mock Initialize-ADTConnection { return @{} }
            { Set-ADTGroupMember -Identity 'GS-VPN' -Member 'jcote' -RemoveMember 'jcote' -Confirm:$false } |
                Should -Throw '*ajout ET le retrait*'
        }
    }
}

Describe 'Contenu d une unite d organisation' {
    It 'Interroge un seul niveau et ecarte les ordinateurs des utilisateurs' {
        InModuleScope PSADToolkit {
            $script:Filter = ''
            $script:Scope = ''
            Mock Initialize-ADTConnection { return @{} }
            Mock Get-ADTNativePasswordPolicy { return (New-Object PSObject -Property @{ LockoutDurationTicks = [long]0 }) }
            Mock Search-ADTDirectoryEntry {
                param($LDAPFilter, $SearchBase, $Scope)
                $script:Filter = $LDAPFilter
                $script:Scope = [string]$Scope
                return @()
            }
            $null = Get-ADTDirectoryChild -Path 'OU=Employes,DC=contoso,DC=local' -Type User
            $script:Scope | Should -Be 'OneLevel'
            # Un ordinateur est aussi un objet user : sans exclusion il apparaitrait
            # dans la liste des utilisateurs.
            $script:Filter | Should -BeLike '*(!(objectCategory=computer))*'
        }
    }
}

Describe 'Document de remise des identifiants' {
    It 'Ecrit le mot de passe dans le document mais jamais dans le journal' {
        $log = Join-Path $TestDrive 'remise.log'
        $folder = Join-Path $TestDrive 'documents'
        $null = New-Item -Path $folder -ItemType Directory -Force
        $secret = 'Temporaire-9x!Kq'
        $result = New-ADTCredentialDocument -SamAccountName 'jcote' -Password $secret -DisplayName 'Joel Cote' `
            -UserPrincipalName 'jcote@contoso.local' -Path $folder -NoDirectoryLookup -LogPath $log -Confirm:$false

        $result.Status | Should -Be 'Genere'
        Test-Path -LiteralPath $result.Path | Should -BeTrue
        $document = [IO.File]::ReadAllText($result.Path)
        $document | Should -BeLike ('*' + $secret + '*')
        $document | Should -BeLike '*jcote@contoso.local*'
        $document | Should -BeLike '*contoso.local*'

        Test-Path -LiteralPath $log | Should -BeTrue
        $journal = [IO.File]::ReadAllText($log)
        $journal | Should -BeLike '*Document de remise genere pour jcote*'
        $journal | Should -Not -BeLike ('*' + $secret + '*')
    }
    It 'Refuse d ecraser un document existant sans -Force' {
        $file = Join-Path $TestDrive 'existant.html'
        Set-Content -Path $file -Value 'deja la'
        { New-ADTCredentialDocument -SamAccountName 'jcote' -Password 'Abc123!xyzQ' -Path $file `
                -NoDirectoryLookup -Confirm:$false -ErrorAction Stop } | Should -Throw '*existe deja*'
        [IO.File]::ReadAllText($file).Trim() | Should -Be 'deja la'
    }
    It 'Echappe le contenu injecte dans le document HTML' {
        $folder = Join-Path $TestDrive 'documents-echappement'
        $null = New-Item -Path $folder -ItemType Directory -Force
        $result = New-ADTCredentialDocument -SamAccountName 'jcote' -Password 'Abc<script>1!' `
            -DisplayName '<b>Joel</b>' -Path $folder -NoDirectoryLookup -Confirm:$false
        $document = [IO.File]::ReadAllText($result.Path)
        $document | Should -Not -BeLike '*<script>*'
        $document | Should -Not -BeLike '*<b>Joel</b>*'
        $document | Should -BeLike '*&lt;b&gt;Joel*'
    }
}

Describe 'Compatibilite Windows PowerShell 2.0 des sources du module' {
    It 'N utilise aucun operateur apparu en PowerShell 3.0' {
        # -shl, -shr, -in et -notin s analysent sans erreur sur un moteur moderne et
        # echouent a l execution sur Windows PowerShell 2.0. Le controle est ici pour
        # qu il tourne meme sans PSScriptAnalyzer.
        $root = Split-Path $PSScriptRoot -Parent
        $files = @(Get-ChildItem -Path (Join-Path $root 'Private') -Filter '*.ps1') +
        @(Get-ChildItem -Path (Join-Path $root 'Public') -Filter '*.ps1')
        foreach ($file in $files) {
            $tokens = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$null)
            foreach ($token in $tokens) {
                # Le mot-cle "in" de foreach porte le meme TokenKind que l operateur
                # -in : seul le tiret initial distingue l operateur du mot-cle.
                if (-not ([string]$token.Extent.Text).StartsWith('-')) { continue }
                @('Shl', 'Shr', 'In', 'NotIn') | Should -Not -Contain ([string]$token.Kind) -Because ($file.Name + ' ligne ' + $token.Extent.StartLineNumber)
            }
        }
    }
    It 'N utilise aucune API interdite sur Windows PowerShell 2.0' {
        $root = Split-Path $PSScriptRoot -Parent
        $files = @(Get-ChildItem -Path (Join-Path $root 'Private') -Filter '*.ps1') +
        @(Get-ChildItem -Path (Join-Path $root 'Public') -Filter '*.ps1')
        foreach ($file in $files) {
            $text = [IO.File]::ReadAllText($file.FullName)
            $tokens = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$null)
            foreach ($comment in ($tokens | Where-Object { $_.Kind -eq 'Comment' } | Sort-Object { $_.Extent.StartOffset } -Descending)) {
                $text = $text.Remove($comment.Extent.StartOffset, $comment.Extent.EndOffset - $comment.Extent.StartOffset)
            }
            $text | Should -Not -Match '\[pscustomobject\]' -Because $file.Name
            $text | Should -Not -Match '\[ordered\]' -Because $file.Name
            $text | Should -Not -Match '::new\(' -Because $file.Name
            $text | Should -Not -Match '\$PSScriptRoot' -Because $file.Name
        }
    }
}

Describe 'Projection des lignes affichees par la console' {
    It 'Classe les conteneurs en premier et resume l etat de chaque compte' {
        InModuleScope PSADToolkit {
            Mock Initialize-ADTConnection { return @{} }
            Mock Get-ADTNativePasswordPolicy {
                return (New-Object PSObject -Property @{ LockoutDurationTicks = [long]-18000000000 })
            }
            Mock Get-ADTNativeContainerChild {
                return @(
                    (New-Object PSObject -Property @{
                            Name = 'Joel Cote'; ObjectClass = 'user'; ObjectType = 'Utilisateur'
                            DistinguishedName = 'CN=jcote,OU=E,DC=c,DC=l'; SamAccountName = 'jcote'; Description = ''
                            Enabled = $false; LockedOut = $true; LastLogonDate = ([datetime]'2026-09-01 08:12')
                            whenCreated = ([datetime]'2024-03-02'); UserPrincipalName = 'jcote@contoso.local'
                            MustChangePassword = $true; AccountExpirationDate = $null
                        }),
                    (New-Object PSObject -Property @{
                            Name = 'Comptabilite'; ObjectClass = 'organizationalUnit'; ObjectType = 'Unite d organisation'
                            DistinguishedName = 'OU=Comptabilite,OU=E,DC=c,DC=l'; SamAccountName = ''; Description = 'Service'
                            Enabled = $true; LockedOut = $false; LastLogonDate = $null
                            whenCreated = ([datetime]'2025-01-05'); UserPrincipalName = ''
                            MustChangePassword = $false; AccountExpirationDate = $null
                        })
                )
            }
            $rows = @(Get-ADTDirectoryChild -Path 'OU=E,DC=c,DC=l')
            $rows.Count | Should -Be 2
            # Les conteneurs viennent en tete, comme dans la console Microsoft.
            $rows[0].Name | Should -Be 'Comptabilite'
            $rows[0].IsContainer | Should -BeTrue
            # Un conteneur n a pas d etat de compte : mieux vaut une colonne vide
            # qu un "Actif" trompeur.
            $rows[0].Status | Should -Be ''
            $rows[1].IsContainer | Should -BeFalse
            $rows[1].Status | Should -BeLike '*Desactive*'
            $rows[1].Status | Should -BeLike '*Verrouille*'
            $rows[1].Status | Should -BeLike '*Mot de passe a changer*'
        }
    }
}

Describe 'Fiche de proprietes' {
    It 'Calcule les valeurs derivees attendues par la feuille de proprietes' {
        InModuleScope PSADToolkit {
            Mock Initialize-ADTConnection { return @{} }
            Mock Get-ADTNativePasswordPolicy {
                return (New-Object PSObject -Property @{
                        LockoutDurationTicks = [long]0; MinimumPasswordLength = 14; Source = 'Strategie de domaine par defaut'
                    })
            }
            Mock Get-ADTNativeDeletionProtection { return $true }
            Mock Resolve-ADTConsoleObject {
                return (New-Object PSObject -Property @{
                        Name = 'jcote'; DisplayName = 'Joel Cote'; ObjectClass = 'user'; ObjectType = 'Utilisateur'
                        DistinguishedName = 'CN=jcote,OU=Employes,DC=contoso,DC=local'; SamAccountName = 'jcote'
                        UserPrincipalName = 'jcote@contoso.local'; SID = 'S-1-5-21-1-2-3-1105'
                        GivenName = 'Joel'; Surname = 'Cote'; Initials = ''; Description = ''; EmailAddress = ''
                        OfficePhone = ''; MobilePhone = ''; Office = ''; Title = ''; Department = ''; Company = ''
                        Manager = 'CN=Marie Tremblay,OU=Employes,DC=contoso,DC=local'; ManagedBy = ''
                        StreetAddress = ''; City = ''; State = ''; PostalCode = ''; Country = ''; EmployeeID = ''
                        Notes = ''; HomeDirectory = ''; HomeDrive = ''; ProfilePath = ''; ScriptPath = ''
                        Enabled = $true; LockedOut = $false; MustChangePassword = $false; CannotChangePassword = $false
                        PasswordNeverExpires = $false; PasswordNotRequired = $false; SmartcardLogonRequired = $false
                        AccountNotDelegated = $false; DoesNotRequirePreAuth = $false; UserAccountControl = 512
                        PasswordLastSet = ([datetime]'2026-01-10'); LastLogonDate = ([datetime]'2026-09-15')
                        # accountExpires pointe sur l instant ou le compte cesse d etre
                        # utilisable, soit le debut du jour suivant le dernier jour ouvert.
                        AccountExpirationDate = ([datetime]'2027-07-01 00:00:00')
                        whenCreated = ([datetime]'2024-03-02'); whenChanged = ([datetime]'2026-09-10')
                        LogonHours = (ConvertTo-ADTLogonHoursByte -Mask (New-ADTLogonHoursMask -Day 1, 2, 3, 4, 5 -StartHour 8 -EndHour 18))
                        MemberOf = @('CN=GS-VPN,OU=Groupes,DC=contoso,DC=local', 'CN=Cote\, equipe,OU=Groupes,DC=contoso,DC=local')
                        GroupScope = ''; GroupCategory = ''; OperatingSystem = ''; OperatingSystemVersion = ''
                        DnsHostName = ''; PrimaryGroupID = '513'
                    })
            }
            $fiche = Get-ADTObjectProperty -Identity 'jcote'

            $fiche.Container | Should -Be 'OU=Employes,DC=contoso,DC=local'
            # Le dernier jour ouvert affiche est la veille de l instant d expiration.
            $fiche.AccountExpiresEndOfDay | Should -Be ([datetime]'2027-06-30')
            $fiche.LogonHoursRestricted | Should -BeTrue
            $fiche.LogonHoursMask.Length | Should -Be 168
            $fiche.LogonHoursText | Should -Not -BeNullOrEmpty
            # Les appartenances sont rendues lisibles, echappements du DN compris.
            @($fiche.MemberOfNames) | Should -Contain 'GS-VPN'
            @($fiche.MemberOfNames) | Should -Contain 'Cote, equipe'
            $fiche.ProtectedFromDeletion | Should -BeTrue
            $fiche.MinimumPasswordLength | Should -Be 14
        }
    }
}

Describe 'Etat des comptes' {
    It 'Traite chaque compte de la selection et rend une ligne par compte' {
        InModuleScope PSADToolkit {
            $script:Unlocked = New-Object System.Collections.ArrayList
            Mock Initialize-ADTConnection { return @{} }
            Mock Resolve-ADTConsoleObject {
                param($Identity)
                return (New-Object PSObject -Property @{
                        SamAccountName = $Identity; Name = $Identity; DistinguishedName = ('CN=' + $Identity + ',DC=t,DC=l')
                        ObjectClass = 'user'
                    })
            }
            Mock Unlock-ADTNativeAccount { param($DistinguishedName) [void]$script:Unlocked.Add($DistinguishedName) }
            $results = @(Set-ADTAccountState -Identity 'jcote', 'mtremblay' -Action Unlock -Confirm:$false)
            $results.Count | Should -Be 2
            foreach ($row in $results) { $row.Status | Should -Be 'Termine' }
            @($script:Unlocked).Count | Should -Be 2
        }
    }
    It 'Isole l echec d un compte sans interrompre les suivants' {
        InModuleScope PSADToolkit {
            Mock Initialize-ADTConnection { return @{} }
            Mock Resolve-ADTConsoleObject {
                param($Identity)
                if ($Identity -eq 'inconnu') { throw 'Objet introuvable : inconnu' }
                return (New-Object PSObject -Property @{
                        SamAccountName = $Identity; Name = $Identity; DistinguishedName = ('CN=' + $Identity + ',DC=t,DC=l')
                        ObjectClass = 'user'
                    })
            }
            Mock Disable-ADTNativeAccount { }
            $results = @(Set-ADTAccountState -Identity 'jcote', 'inconnu', 'mtremblay' -Action Disable -Confirm:$false)
            $results.Count | Should -Be 3
            @($results | Where-Object { $_.Status -eq 'Termine' }).Count | Should -Be 2
            @($results | Where-Object { $_.Status -eq 'Echec' }).Count | Should -Be 1
        }
    }
    It 'Ne modifie rien en simulation' {
        InModuleScope PSADToolkit {
            Mock Initialize-ADTConnection { return @{} }
            Mock Resolve-ADTConsoleObject {
                return (New-Object PSObject -Property @{
                        SamAccountName = 'jcote'; Name = 'jcote'; DistinguishedName = 'CN=jcote,DC=t,DC=l'; ObjectClass = 'user'
                    })
            }
            Mock Disable-ADTNativeAccount { throw 'ne doit pas etre appele' }
            $result = Set-ADTAccountState -Identity 'jcote' -Action Disable -WhatIf
            $result.Status | Should -Be 'Simulation'
        }
    }
}
