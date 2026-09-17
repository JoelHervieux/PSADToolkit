# PSADToolkit 3.1.0-test3

Administration Active Directory avec interface graphique en français : **console d'arborescence** à la manière d'« Utilisateurs et ordinateurs Active Directory », import CSV et rapports HTML. L'interface est bâtie sur **[GliderUI](https://github.com/mdgrs-mei/GliderUI)** (Avalonia) et exige **PowerShell 7.4 ou supérieur**. Les fonctions du module restent utilisables en ligne de commande depuis **Windows PowerShell 2.0 à 5.1**. Les contrôleurs de domaine visés vont de **Windows Server 2008 SP2 à Windows Server 2025** : l'accès se fait en LDAP par ADSI / .NET, donc **RSAT et AD Web Services ne sont pas nécessaires** et rien n'est installé sur le contrôleur de domaine.

**Version `3.1.0-test3` — canal de test.** Le canal `test` signifie que cette version n'a pas encore passé la recette Windows décrite dans `VALIDATION.md` : ne pas s'en servir pour des écritures en production. La 3.1.0 ajoute la console d'administration — arborescence, listes, propriétés, horaires de connexion, mots de passe — sans retirer ni renommer quoi que ce soit de la 3.0.0. La nomenclature, la portée de chaque numéro et la procédure de publication sont décrites dans `VERSIONING.md`.

> GliderUI annonce lui-même une phase de prototypage avec des ruptures d'API fréquentes. Épingler la version installée et relire `CHANGELOG.md` avant toute mise à jour.

## Démarrage

1. Installer **PowerShell 7.4 ou supérieur**. Il s'installe **à côté** de Windows PowerShell 5.1 et ne le remplace pas.

   - Téléchargement direct : [github.com/PowerShell/PowerShell/releases/latest](https://github.com/PowerShell/PowerShell/releases/latest) — prendre le fichier `PowerShell-<version>-win-x64.msi`.
   - Ou en ligne de commande : `winget install --id Microsoft.PowerShell -e`
   - Procédure détaillée : [Installation de PowerShell sur Windows — Microsoft](https://learn.microsoft.com/fr-fr/powershell/scripting/install/installing-powershell-on-windows)

   Vérifier ensuite la version depuis `pwsh.exe` :

   ```powershell
   $PSVersionTable.PSVersion
   ```

2. Installer le module [GliderUI](https://www.powershellgallery.com/packages/GliderUI) et son serveur :

   ```powershell
   Install-PSResource -Name GliderUI
   Install-GLIServer
   ```

   **Deux paquets, pas un.** `GliderUI` est le module ; `Install-GLIServer` installe à côté un **module distinct**, propre à la plateforme — `GliderUI.Server.win-x64` sur un Windows 64 bits. C'est lui qui porte les classes Avalonia utilisées par l'interface. Sans lui, `Import-Module GliderUI` réussit mais aucune classe n'existe. Le relancer **après chaque mise à jour** du module.

   Si la machine n'atteint pas PowerShell Gallery — serveur isolé, proxy, `Hôte inconnu` — voir *Installation hors ligne* ci-dessous.
3. Extraire complètement le ZIP dans un dossier local (par exemple `C:\Outils\PSADToolkit`). Ne pas lancer depuis l'intérieur de l'archive.
4. Double-cliquer sur **Lancer.cmd**. Il repère `pwsh.exe` et démarre l'interface. Le mode STA n'est plus nécessaire : GliderUI affiche la fenêtre dans un processus serveur distinct.
5. Saisir le **nom DNS complet d'un contrôleur de domaine**, par exemple `dc01.contoso.local`, puis cliquer sur **Tester la connexion**. Laisser vide pour utiliser le domaine du compte Windows courant.
6. Pour employer une autre identité, cocher **Autre compte**, saisir `DOMAINE\utilisateur` ou un UPN et son mot de passe. Les droits délégués dans AD sont nécessaires ; être administrateur local ne donne pas automatiquement ces droits.
7. Ouvrir l'onglet **Console AD** et cliquer sur **Charger / actualiser** pour afficher l'arborescence du domaine. Les autres onglets restent disponibles pour les traitements en lot.
8. Pour toute modification d'Active Directory, la **simulation est cochée par défaut**, dans la console comme dans les onglets. Décocher seulement après vérification : une confirmation récapitule la cible, l'action et la liste des objets concernés.

Les résultats s'affichent dans le tableau. Agrandir la fenêtre ou défiler horizontalement pour lire toutes les colonnes. Vérifier **Status**, **Error** et **Messages**. `Partiel` signifie que certaines modifications ont déjà été appliquées : examiner l'état du compte avant de relancer.

L'interface reste réactive pendant les opérations. Une seule opération est autorisée à la fois. Attendre sa fin avant de fermer. Les mots de passe générés sont masqués dans le tableau et exclus de l'export standard ; la case **Afficher / exporter les mots de passe générés** permet de les consulter ou de les exporter explicitement. Ils restent en mémoire jusqu'au prochain traitement ou à la fermeture.

### Installation hors ligne

Un contrôleur de domaine ou un serveur d'administration n'a souvent aucun accès à Internet. `Install-GLIServer` échoue alors sur `Hôte inconnu (www.powershellgallery.com:443)`, et l'interface refuse ensuite de démarrer faute de classes Avalonia.

Un paquet PowerShell Gallery est une archive ZIP servie en HTTPS direct : aucun outil n'est nécessaire sur la machine connectée, un navigateur suffit.

1. Depuis **n'importe quel appareil connecté**, télécharger le paquet du serveur. Remplacer `0.4.1` par la version de GliderUI réellement installée sur la machine cible, et `win-x64` par `win-arm64` le cas échéant :

   ```
   https://www.powershellgallery.com/api/v2/package/GliderUI.Server.win-x64/0.4.1
   ```

   Si GliderUI lui-même manque, le récupérer de la même façon : `.../package/GliderUI/0.4.1`.

2. Transférer le fichier dans un dossier de la machine cible, puis :

   ```powershell
   .\Tests\Install-GliderUIOffline.ps1 -Path C:\Transfert
   ```

   Le script trouve le paquet quel que soit le nom que le navigateur lui a donné — il ouvre chaque fichier du dossier et cherche le manifeste, ce qui écarte au passage une page d'erreur HTML enregistrée par mégarde. Il refuse une version qui ne correspond pas à celle de GliderUI, extrait au bon endroit, puis **vérifie** que le type `AvaloniaRuntimeXamlLoader` se résout.

3. Fermer **toutes** les fenêtres PowerShell, puis relancer `Lancer.cmd`. Un assembly déjà chargé dans une session ne peut pas y être remplacé.

La version du serveur doit être **exactement** celle du module. Après chaque `Update-PSResource -Name GliderUI`, refaire l'opération.

À défaut, `Install-GLIServer` accepte `-Repository` : on peut aussi enregistrer le dossier de transfert comme dépôt local avec `Register-PSResourceRepository -Name GliderUILocal -Uri C:\Transfert -Trusted`, puis `Install-GLIServer -Repository GliderUILocal -TrustRepository`.

`pwsh -NoProfile -File .\Tests\Test-GliderUI.ps1` vérifie à tout moment ce qui est installé et ce qui manque.

## Compatibilité et prérequis

| Rôle | Système | Prérequis |
|---|---|---|
| Poste qui affiche l'interface | Windows 10 / 11, ou Windows Server 2016 à 2025 avec bureau | [PowerShell 7.4+](https://github.com/PowerShell/PowerShell/releases/latest), module [GliderUI](https://www.powershellgallery.com/packages/GliderUI) et `Install-GLIServer` |
| Contrôleurs de domaine administrés | Windows Server 2008 SP2 à 2025 | Aucun composant à installer : accès LDAP / ADSI depuis le poste d'administration |
| Utilisation en ligne de commande | Tout hôte Windows joignant le domaine | Windows PowerShell 2.0 à 5.1, ou PowerShell 7 ; `.NET` et `System.DirectoryServices` du système |
| Server Core | Windows Server sans bureau | Ligne de commande seulement : lancer l'interface depuis un poste d'administration |

**L'interface ne s'exécute plus sous Windows PowerShell.** `powershell.exe` ne dépasse pas la version 5.1 ; [PowerShell 7.4+](https://github.com/PowerShell/PowerShell/releases/latest) est exigé par GliderUI. Lancer l'interface avec `pwsh.exe`, ce que fait `Lancer.cmd`. Les serveurs qui ne peuvent pas recevoir PowerShell 7, dont Server 2008 SP2, restent administrables : installer PSADToolkit sur un poste d'administration moderne, qui joint le contrôleur de domaine en LDAP.

**Le backend reste Windows.** GliderUI est multiplateforme, mais `System.DirectoryServices` ne l'est pas : l'interface refuse de démarrer ailleurs que sous Windows.

**Les fonctions du module restent compatibles Windows PowerShell 2.0.** Le manifeste déclare toujours `PowerShellVersion = '2.0'` et `Tests\Test-Compatibility.ps1` continue de le vérifier pour `Private`, `Public` et le standalone. Seule l'interface a changé de moteur.

La compatibilité ci-dessus est une **cible technique**, pas une certification obtenue sur chaque système. Le contrôle de syntaxe et les tests avec annuaire simulé ont été exécutés ; l'interface GliderUI n'a encore été exécutée sur aucune machine, et les écritures sur un véritable domaine 2008–2025 doivent être validées dans un laboratoire Windows. Le comportement dépend aussi des stratégies d'authentification, des délégations et des composants installés. Les versions futures de Windows Server ne sont pas garanties.

## Connexion et dépannage

- Utiliser un **FQDN de contrôleur de domaine accessible en écriture**, sans `LDAP://`, numéro de port ni chemin. Le serveur effectivement trouvé est affiché après le test et réutilisé par les opérations.
- DNS, horloge et accès réseau au domaine doivent être corrects. Le transport utilise LDAP avec authentification intégrée, signature et chiffrement de session (`Secure | Signing | Sealing`). Aucun repli vers une liaison LDAP anonyme ou un simple bind non protégé n'est prévu.
- Le test de connexion confirme la lecture du domaine, **pas les droits de modification**. Les politiques de mot de passe peuvent refuser une valeur générée.
- Si Windows bloque le fichier téléchargé, ouvrir les propriétés du ZIP et choisir **Débloquer**, si proposé, avant de l'extraire à nouveau. Le lanceur utilise `RemoteSigned` pour son processus uniquement. Une stratégie de groupe ou une obligation de signature peut toujours s'imposer ; faire signer les scripts si nécessaire.
- Une session élevée n'est normalement pas nécessaire pour les opérations AD déléguées. Les modifications d'un partage ou de ses ACL utilisent l'identité de la **session Windows courante**, même si un autre compte est fourni pour LDAP.
- **`Impossible de trouver le type [AvaloniaRuntimeXamlLoader]`, ou tout autre type `GliderUI...` introuvable.** Le module GliderUI se charge, mais les classes Avalonia qu'il expose — produites par un générateur livré avec le serveur — ne sont pas disponibles. Le serveur est absent, ou il date d'une version antérieure du module : **`Install-GLIServer` doit être relancé après chaque mise à jour de GliderUI**.

  ```powershell
  Update-PSResource -Name GliderUI
  Install-GLIServer -UninstallOldVersions
  ```

  Fermer ensuite toutes les fenêtres PowerShell avant de relancer : un assembly déjà chargé dans une session ne peut pas y être remplacé. Si `Install-GLIServer` échoue lui-même sur `Hôte inconnu`, la machine n'atteint pas PowerShell Gallery : suivre *Installation hors ligne*.

  Pour un rapport détaillé — versions installées, présence et version du module serveur, résolution de chaque type, assemblys chargés — lancer `pwsh -NoProfile -File .\Tests\Test-GliderUI.ps1` et joindre sa sortie à tout signalement.

  L'interface vérifie ces types au démarrage et rapporte précisément ceux qui manquent, au lieu d'échouer sur le premier rencontré.
- Journal par défaut : `%LOCALAPPDATA%\PSADToolkit\PSADToolkit.log`. Paramètre `-LogPath` disponible en ligne de commande. Les erreurs de journalisation sont affichées comme avertissements. Aucun mot de passe n'est volontairement écrit dans ce journal.

## La console Active Directory

L'onglet **Console AD** est le point d'entrée quotidien. Il reprend l'organisation d'« Utilisateurs et ordinateurs Active Directory » : l'arborescence du domaine à gauche, le contenu de l'unité sélectionnée à droite.

- **Arborescence** : domaine, unités d'organisation et conteneurs intégrés (`Builtin`, `Users`, `Computers`). Elle est lue en une seule requête LDAP ; le contenu d'une unité, lui, n'est lu qu'à sa sélection.
- **Liste** : utilisateurs, groupes, ordinateurs et sous-unités, avec leur état (actif, désactivé, verrouillé, expiré, mot de passe à changer). **Ctrl** et **Maj** sélectionnent plusieurs objets ; toutes les actions en lot portent sur la sélection.
- **Double-clic** sur un objet : sa feuille de propriétés.
- **Clic droit** dans l'arborescence ou dans la liste : les mêmes actions, appliquées à l'élément sélectionné. Le menu contextuel est un confort : **chaque action reste accessible par un bouton**, pour que l'outil reste complet si la version de GliderUI installée n'expose pas les menus contextuels.
- **Recherche** : par nom, `sAMAccountName`, UPN, nom affiché, courriel ou description, dans l'unité sélectionnée ou dans tout le domaine, avec un filtre par type d'objet. Le terme saisi est échappé avant d'entrer dans le filtre LDAP : une parenthèse ou une étoile y est du texte, pas de la syntaxe.

### Propriétés d'un objet

La feuille de propriétés est organisée en sections : **Général**, **Compte**, **Organisation**, **Adresse**, **Profil**, **Groupes**, **Horaires de connexion** et **Objet**. Seules les propriétés réellement modifiées sont écrites ; un champ laissé tel quel n'est jamais réécrit, et un champ vidé efface l'attribut.

La section **Compte** couvre les options de `userAccountControl` (mot de passe qui n'expire jamais, carte à puce obligatoire, compte sensible non délégué, pré-authentification Kerberos) et l'expiration du compte. Comme dans la console Microsoft, la date saisie est le **dernier jour ouvert** : le compte expire à minuit à la fin de cette journée.

« L'utilisateur ne peut pas changer de mot de passe » est affiché en **lecture seule** : dans Active Directory cette option est portée par les autorisations de l'objet et non par `userAccountControl`. PSADToolkit ne la modifie pas.

### Horaires de connexion

L'attribut `logonHours` se gère dans une grille de **7 jours × 24 heures**. Cliquer une case bascule une heure, cliquer un jour bascule la ligne, cliquer une heure bascule la colonne ; des modèles couvrent les cas courants. Les jours sont présentés dans l'ordre et la langue de la machine, les heures selon sa convention horaire.

**La grille est en heure locale.** Active Directory stocke `logonHours` en temps universel ; PSADToolkit applique le décalage du poste à l'écriture et à la lecture, comme le fait la console Microsoft. Un horaire 8 h – 18 h saisi à Montréal s'affiche bien 8 h – 18 h dans ADUC exécuté sur le même fuseau. Les fuseaux à la demi-heure sont arrondis à l'heure, `logonHours` n'ayant pas de résolution plus fine.

Un horaire s'applique à un compte, à plusieurs comptes sélectionnés, ou **aux membres d'un groupe**. Dans ce dernier cas la liste des membres est affichée avant l'écriture et des comptes peuvent en être **exclus** pour conserver un horaire différent. Un horaire n'autorisant aucune heure empêche toute ouverture de session : il demande une confirmation supplémentaire.

### Mots de passe et document de remise

Le générateur est configurable : longueur, majuscules, minuscules, chiffres, caractères spéciaux, caractères ambigus (`O`, `0`, `l`, `1`, `I`) exclus par défaut. Il lit la **stratégie de mot de passe du domaine** — y compris une stratégie affinée applicable au compte, sur un domaine de niveau 2008 ou supérieur — et relève la longueur demandée si elle est inférieure au minimum exigé. PSADToolkit ne descend jamais sous 12 caractères, même si le domaine l'autorise.

À la création d'un compte ou à la réinitialisation d'un mot de passe, un **document de remise** HTML peut être produit : nom, identifiant, UPN, domaine, courriel et mot de passe temporaire, avec les consignes de première connexion. Cette génération est une **action volontaire** : elle n'est jamais déclenchée d'office, l'administrateur coche la case puis choisit le dossier de destination. Le fichier contient un mot de passe en clair — choisir un dossier à accès restreint et le détruire après remise. **Le mot de passe n'apparaît à aucun moment dans le journal de PSADToolkit.**

### Formats régionaux

Tous les jours, dates et heures **affichés** suivent le format régional de la machine qui exécute l'application : grilles de résultats, feuilles de propriétés, grille des horaires, rapport HTML. Aucun format n'est codé en dur.

Deux exceptions délibérées : le **journal** garde un horodatage ISO 8601 (`AAAA-MM-JJ hh:mm:ss`), triable et lisible de la même façon sur tous les postes qui relisent un fichier d'audit ; et la **date inscrite dans la description** d'un compte lors d'un départ reste ISO, pour qu'elle ne dépende pas du poste qui a fait l'opération.

## Les onglets

| Onglet | Action |
|---|---|
| Console AD | Arborescence du domaine, contenu des unités, recherche, propriétés, création, déplacement, suppression, activation, déverrouillage, groupes, horaires de connexion et mots de passe |
| Créer un compte | Prénom, nom, OU, identifiant automatique ou imposé, groupes, courriel, service, fonction, dossier personnel facultatif |
| Importer un CSV | Aperçu obligatoire avant lancement, sélection de l’OU dans l’arborescence, création facultative d’une sous-OU par département, lecture de tous les groupes, choix `;` ou `,` et option d’ignorer les identifiants existants |
| Groupes | Ajouter ou retirer plusieurs utilisateurs à plusieurs groupes ; listes séparées par `;` |
| Départ | Sauvegarder l'état et les groupes, désactiver, réinitialiser le mot de passe, retirer les groupes, annoter et déplacer |
| Comptes inactifs | Seuil en jours, OU facultative, comptes désactivés et jamais connectés |
| Privilèges | Membres des groupes à privilèges du domaine sélectionné, y compris groupes imbriqués et groupes principaux |
| Rapport HTML | Rapport consolidé et exports CSV facultatifs |

Les paramètres avancés, dont `Manager`, `Company`, `Office`, `UserPrincipalNameSuffix` et un mot de passe initial fourni en `SecureString`, restent accessibles en ligne de commande.

## CSV d'exemple

Le dossier `Examples\Tests-CSV` contient onze fichiers de test — cas nominaux, séparateur `,`, groupes non entourés de guillemets, accents, sous-OU par département, volume, et cinq fichiers qui doivent être refusés. Voir `Examples\Tests-CSV\LISEZMOI.md`.

Le fichier `Examples\nouveaux-employes.csv` utilise `;` comme séparateur. La colonne `Groups` accepte plusieurs groupes séparés par `;`. Les guillemets restent recommandés, mais PSADToolkit 2.1 sait aussi reconstruire les groupes quand un export CSV a utilisé `;` à la fois comme séparateur du fichier et comme séparateur de groupes :

```csv
GivenName;Surname;SamAccountName;OU;Groups
Joël;Hervieux;jhervieux;OU=Employes,DC=contoso,DC=local;"GS-Employes;GS-VPN"
```

Adapter les OU, noms de groupes, domaine et gestionnaires avant d'utiliser l'exemple. Enregistrer en UTF-8, idéalement avec BOM pour les anciens outils Windows. Les colonnes `GivenName` et `Surname` sont obligatoires ; chaque ligne doit avoir une OU ou utiliser `DefaultOU`.

Le fichier entier est contrôlé avant toute création : structure, champs obligatoires, collisions entre identifiants explicitement fournis après normalisation et accès aux OU. Les groupes sont résolus dans tout le domaine par `sAMAccountName`, `Name` ou `CN`. Un groupe introuvable ou non accessible est signalé dans l’aperçu mais ne bloque plus tout l’import : l’utilisateur peut être créé avec le statut `Partiel`, et seuls les groupes résolus sont appliqués. Dans l’interface, la sélection du fichier CSV ouvre immédiatement l’arborescence Active Directory afin de choisir l’OU de destination. Cette OU choisie a priorité sur une éventuelle colonne `OU` du CSV. Un aperçu affiche ensuite le département, l’OU cible et tous les groupes avant de poursuivre. Si l’option de création des sous-OU est cochée, l’OU choisie devient l’OU parente et chaque valeur `Department` est utilisée pour créer ou réutiliser une sous-OU. Une course avec un autre administrateur reste possible entre la vérification et la création. Le statut de chaque création fait foi. La simulation ne réserve aucun identifiant dans AD.

Un identifiant imposé déjà utilisé provoque un échec, sauf si `SkipExisting` est demandé à l'import. Les identifiants automatiques reçoivent un suffixe numérique en cas de collision. Le CN du nouvel objet est basé sur l'identifiant unique ; son `displayName` reste le prénom et le nom.

Le rapport de mots de passe facultatif est **en clair** : choisir un emplacement à accès restreint et le supprimer après transmission. Les mots de passe de comptes partiellement créés peuvent ne pas avoir été acceptés ; vérifier leur statut avant distribution.

## Ligne de commande

Depuis Windows PowerShell ou PowerShell 7, dans le dossier extrait :

```powershell
Import-Module .\PSADToolkit.psd1 -Force
Test-ADTPrerequisite -Server 'dc01.contoso.local'

New-ADTUser -GivenName 'Joel' -Surname 'Hervieux' `
    -Path 'OU=Employes,DC=contoso,DC=local' `
    -Server 'dc01.contoso.local' -WhatIf

Import-ADTUserFromCsv -Path .\Examples\nouveaux-employes.csv `
    -Server 'dc01.contoso.local' -WhatIf

Start-ADTUserOffboarding -Identity 'jhervieux' `
    -BackupPath 'C:\SauvegardesAD' -Server 'dc01.contoso.local' -WhatIf

Export-ADTAccessReport -Path 'C:\Rapports\AD.html' `
    -Server 'dc01.contoso.local'
```

Les fonctions de la console s'utilisent aussi en ligne de commande :

```powershell
# Naviguer et chercher
Get-ADTDirectoryChild -Path 'OU=Employes,DC=contoso,DC=local' |
    Format-Table Name, ObjectType, Status
Find-ADTDirectoryObject -SearchTerm 'tremblay' -Type User
Get-ADTObjectProperty -Identity 'jhervieux' | Format-List

# Etat d'un compte
Set-ADTAccountState -Identity 'jhervieux' -Action Unlock
Set-ADTUser -Identity 'jhervieux' -Title 'Analyste principal' -Department 'TI' -WhatIf

# Horaires de connexion : un horaire, puis une portee
$horaire = New-ADTLogonHourSchedule -Day Monday,Tuesday,Wednesday,Thursday,Friday -StartHour 8 -EndHour 18
Set-ADTUserLogonHours -Identity 'jhervieux' -Schedule $horaire.Mask -WhatIf
Set-ADTUserLogonHours -Group 'GS-Ventes' -ExcludeIdentity 'dgagnon' -Schedule $horaire.Mask -WhatIf

# Mot de passe, puis document de remise - deux gestes distincts
Get-ADTPasswordPolicy -Identity 'jhervieux'
Set-ADTUserPassword -Identity 'jhervieux' -Length 20 -Unlock |
    New-ADTCredentialDocument -Path 'C:\Remises'

# Groupes et unites d'organisation
Get-ADTGroupMember -Identity 'GS-VPN' | Format-Table SamAccountName, Status
Set-ADTGroupMember -Identity 'GS-VPN' -Member 'jhervieux' -WhatIf
New-ADTOrganizationalUnit -Path 'DC=contoso,DC=local' -Name 'Stagiaires' -WhatIf
Move-ADTObject -Identity 'jhervieux' -TargetPath 'OU=Stagiaires,DC=contoso,DC=local' -WhatIf
```

Pour utiliser un autre compte : `$cred = Get-Credential`, puis ajouter `-Credential $cred` à la commande. Retirer `-WhatIf` pour appliquer les modifications après revue. `Get-Help New-ADTUser -Full` et les autres aides décrivent les paramètres.

### Version autonome

Copier `dist\PSADToolkit-Standalone.ps1`, puis le charger avec un point suivi d'une espace :

```powershell
. .\PSADToolkit-Standalone.ps1
Test-ADTPrerequisite
```

Le standalone fournit les fonctions en ligne de commande, sans rien installer, y compris sous Windows PowerShell 2.0. **L'interface, elle, exige le dossier complet**, PowerShell 7.4+ et GliderUI ; elle se lance avec `Lancer.cmd`. Pour régénérer le standalone après modification des sources, exécuter `Build.ps1` sur un poste de développement avec PowerShell 5.1 ou 7.

## Sauvegardes de départ et limites

Avant toute modification, le départ écrit un CSV des groupes secondaires et un CLIXML de l'état lu, comprenant le DN d'origine, les groupes, le groupe principal, la description et l'activation. Si l'une des sauvegardes échoue, AD n'est pas modifié. Après sauvegarde, le compte est désactivé **avant** les autres actions. Un échec ultérieur est indiqué comme `Partiel` avec les étapes réellement terminées.

Ces fichiers servent à reconstruire manuellement l'état du compte : **il n'y a pas de restauration automatique**. L'ancien mot de passe n'est pas récupérable. La désactivation ne garantit pas la fermeture instantanée de toutes les sessions ou l'invalidation de tous les tickets existants. Le groupe principal n'est pas retiré ; les appartenances d'autres domaines peuvent nécessiter une intervention séparée.

Les rapports sont limités au **domaine sélectionné**, pas à toute la forêt. Dans un domaine enfant, les groupes Enterprise Admins et Schema Admins du domaine racine doivent être audités séparément. Les erreurs sont indiquées par `NON AUDITE`; les objets `foreignSecurityPrincipal` restent des identités externes à vérifier. Une lecture tronquée de `memberOf` est interrompue explicitement pour éviter de sauvegarder ou de présenter une liste incomplète.

L'inactivité utilise `lastLogonTimestamp`, dont la réplication peut être retardée d'environ 9 à 14 jours. Un compte jamais utilisé est comparé à sa date de création ; un compte créé hier n'est plus classé comme inactif depuis 90 jours. La recherche est paginée, mais les rapports peuvent charger beaucoup de comptes en mémoire : utiliser une OU pour limiter le volume. Le filtre OU ne limite pas l'inventaire des groupes à privilèges du domaine.

Pour les dossiers personnels, les ACL héritées sont conservées et une règle `Modify` est ajoutée au **SID réel du nouveau compte**. Le partage et sa racine doivent donc déjà avoir des permissions adaptées ; l'outil ne reconfigure pas toute la sécurité du partage.

## Vérification

Voir `VALIDATION.md`. Les tests Pester nécessitent un poste de développement moderne, **pas** l'ancien serveur cible :

```powershell
Invoke-Pester -Path .\Tests -Output Detailed
.\Tests\Test-Compatibility.ps1
.\Tests\Test-VersionConsistency.ps1
.\Tests\Test-ParameterShadowing.ps1
```

`Tests\Test-GliderUI.ps1` et `Tests\Install-GliderUIOffline.ps1` ne sont pas des tests : le premier diagnostique l'installation de GliderUI sans rien modifier, le second installe son serveur depuis un paquet local. Ils ne font partie d'aucune suite et servent quand l'interface refuse de démarrer.

`Test-VersionConsistency.ps1` échoue si un fichier annonce une version différente de celle du manifeste. Le lancer avant toute étiquette git, comme indiqué dans `VERSIONING.md`.

`Tests\Console.Tests.ps1` couvre la console sans annuaire : conversion `logonHours` dans les deux sens et pour tous les fuseaux, formats régionaux, générateur de mots de passe, échappement des filtres de recherche, garde-fous de suppression et de déplacement, et absence du mot de passe dans le journal. Il vérifie aussi qu'aucune source du module n'emploie d'opérateur apparu en PowerShell 3.0 : `-shl`, `-shr`, `-in` et `-notin` s'analysent sans erreur sur un moteur moderne et échouent sous Windows PowerShell 2.0.

`Tests\ConsoleInterface.Tests.ps1` analyse l'arbre syntaxique de l'interface sans lancer GliderUI : toute écriture passe bien par une fonction exportée du module, chaque action du menu contextuel a bien un bouton équivalent, et les grilles mettent en forme leurs valeurs par la culture.

`Test-ParameterShadowing.ps1` échoue si une boucle `foreach` réutilise le nom d'un paramètre typé. Les noms de variables PowerShell sont insensibles à la casse et la contrainte de type du paramètre vaut pour toute la fonction : la boucle se casse alors sur une conversion impossible, comme en 3.0.0-test2 où la grille de résultats ne pouvait plus s'afficher.

Le pipeline GitHub Actions est configuré pour reconstruire et vérifier sous Windows PowerShell 5.1. Cette configuration ne signifie pas qu'une exécution GitHub Actions a été lancée lors de cette livraison.

## Références techniques

- [Versions Windows Server — Microsoft](https://learn.microsoft.com/en-us/windows/release-health/windows-server-release-info) : Server 2025 est la version LTSC actuelle dans la source consultée.
- [Authentification DirectoryServices — Microsoft](https://learn.microsoft.com/en-us/dotnet/api/system.directoryservices.authenticationtypes) : authentification intégrée, signature et chiffrement de session.
- [Dialecte LDAP ADSI — Microsoft](https://learn.microsoft.com/en-us/windows/win32/adsi/ldap-dialect) : recherches LDAP et paramètres de pagination.
- [Attribut memberOf — Microsoft](https://learn.microsoft.com/en-us/windows/win32/adschema/a-memberof) : appartenance aux groupes dans le schéma AD, notamment sur Server 2008.
- [PowerShell — versions publiées](https://github.com/PowerShell/PowerShell/releases/latest) et [installation sur Windows — Microsoft](https://learn.microsoft.com/fr-fr/powershell/scripting/install/installing-powershell-on-windows) : PowerShell 7 cohabite avec Windows PowerShell 5.1.
- [GliderUI — PowerShell Gallery](https://www.powershellgallery.com/packages/GliderUI) et [dépôt GitHub](https://github.com/mdgrs-mei/GliderUI) : moteur de l'interface, bâti sur Avalonia. Le dépôt annonce une phase de prototypage avec des ruptures d'API.

Licence MIT — voir `LICENSE`.
