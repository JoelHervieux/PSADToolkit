# Changements

## 3.1.0-test1 - 2026-09-17

Console d administration Active Directory. Aucune fonction, aucun parametre et aucun onglet existant n est retire ni renomme : la 3.1.0 est additive.

### Interface

- Nouvel onglet **Console AD**, place en premier : arborescence du domaine a gauche, contenu de l unite selectionnee a droite. L arborescence couvre les unites d organisation et les conteneurs integres ; elle est lue en une requete LDAP, le contenu d une unite ne l est qu a sa selection.
- Selection multiple dans la liste : toutes les actions en lot portent sur la selection.
- Menus contextuels dans l arborescence et dans la liste, double-clic pour ouvrir les proprietes. Ces interactions sont branchees de maniere tolerante et **chaque action reste accessible par un bouton** : une version de GliderUI qui n exposerait pas `ContextMenu` ou `DoubleTapped` degrade l ergonomie, pas les fonctionnalites.
- Feuille de proprietes en sections : General, Compte, Organisation, Adresse, Profil, Groupes, Horaires de connexion, Objet. Seules les proprietes reellement modifiees sont ecrites.
- Editeur graphique des horaires de connexion : grille 7 jours x 24 heures, bascule par jour, par heure ou par modele.
- Recherche par nom, `sAMAccountName`, UPN, nom affiche, courriel ou description, dans l unite selectionnee ou dans tout le domaine, avec filtre par type d objet.
- Le clic droit sur une unite propose **Importer un CSV dans cette OU** : la console pre-remplit l OU de destination de l onglet d import et y bascule, plutot que de dupliquer l apercu d import.
- L interface est decoupee en `UI\Common.ps1`, `UI\LogonHours.ps1`, `UI\Dialogs.ps1`, `UI\Properties.ps1` et `UI\Console.ps1`, charges par `Start-PSADToolkit.ps1`. Les sept onglets historiques et leur schema `$specs` sont inchanges.
- La console n ecrit jamais dans l annuaire par un chemin qui lui serait propre : toutes ses ecritures passent par `Invoke-ADTUiCommand` et par les fonctions publiques du module, donc par la meme validation, la meme simulation, la meme confirmation, la meme journalisation et la meme grille de resultats que les onglets.

### Formats regionaux

- Tous les jours, dates et heures affiches suivent la culture de la machine : grilles, proprietes, grille des horaires, rapport HTML. `Format-ADTUiCellValue` remplace la conversion implicite en chaine, qui rendait un format invariant.
- Les booleens affiches dans les grilles se lisent Oui / Non. L export CSV conserve les valeurs brutes.
- Le journal garde volontairement un horodatage ISO 8601, triable et lisible de la meme facon sur tous les postes qui relisent un fichier d audit. La date inscrite dans la description d un compte lors d un depart reste ISO pour la meme raison.
- `Test-ADTUses24HourClock` retire les litteraux du motif horaire avant de l analyser : le francais du Canada utilise `HH 'h' mm`, dont le h entre apostrophes aurait ete pris pour un specificateur d heure sur 12.

### Nouvelles fonctions publiques

- Lecture : `Get-ADTDirectoryChild`, `Find-ADTDirectoryObject`, `Get-ADTObjectProperty`, `Get-ADTGroupMember`, `Get-ADTPasswordPolicy`, `Get-ADTUserLogonHours`.
- Ecriture : `Set-ADTUser`, `Set-ADTAccountState`, `Set-ADTUserPassword`, `Set-ADTUserLogonHours`, `Set-ADTGroupMember`, `New-ADTGroup`, `New-ADTOrganizationalUnit`, `Set-ADTOrganizationalUnit`, `Move-ADTObject`, `Remove-ADTObject`.
- Outils : `New-ADTPassword`, `New-ADTLogonHourSchedule`, `New-ADTCredentialDocument`.
- Toutes prennent en charge `-WhatIf`, journalisent et rendent une ligne de statut par objet traite, comme les fonctions historiques.

### Horaires de connexion

- `logonHours` est manipule par un masque de 168 caracteres en **heure locale**. La conversion vers le temps universel attendu par l annuaire applique le decalage du poste, comme le fait la console Microsoft : un horaire 8 h - 18 h saisi a Montreal s affiche bien 8 h - 18 h dans ADUC sur le meme fuseau. Les fuseaux a la demi-heure sont arrondis a l heure, faute de resolution plus fine dans l attribut.
- Un masque entierement autorise efface l attribut, ce qui correspond a Toutes les heures dans la console Microsoft.
- Un horaire n autorisant aucune heure exige `-AllowNoLogonWindow` : le compte ne pourrait plus ouvrir de session.
- L application aux membres d un groupe affiche la liste avant l ecriture et permet d **exclure** des comptes, qui conservent alors leur horaire.

### Mots de passe

- `New-ADTRandomPassword` accepte le choix des classes de caracteres, le jeu de symboles et les caracteres ambigus. Le comportement par defaut est inchange pour les appels existants.
- Le tirage rejette les valeurs de la tranche incomplete de l espace 32 bits : un simple modulo favorisait les premiers caracteres du jeu.
- La strategie du domaine est lue, y compris une strategie affinee applicable au compte (`msDS-ResultantPSO`), et la longueur demandee est relevee au minimum exige. PSADToolkit ne descend jamais sous 12 caracteres.
- `New-ADTCredentialDocument` produit une fiche HTML de remise : nom, identifiant, UPN, domaine, courriel, mot de passe temporaire et consignes. Sa generation est une action volontaire de l administrateur, jamais automatique. **Le mot de passe n est jamais journalise.**

### Backend

- `Private\DirectoryConsole.ps1` : recherche parametrable (portee, attributs, plafond), enumeration d un conteneur sur un seul niveau, fiche d attributs complete, membres directs d un groupe, strategie de mot de passe.
- `Private\DirectoryWrite.ps1` : ecriture d attributs, indicateurs de `userAccountControl`, expiration de compte, deverrouillage, `logonHours`, creation de groupe et d unite, renommage, suppression, protection contre la suppression accidentelle.
- `Private\LogonHours.ps1`, `Private\Format-ADTDisplay.ps1`, `Private\ObjectStatus.ps1`, `Private\Initialize-ADTConnection.ps1`.
- Les membres d un groupe sont lus par `memberOf` plutot que par l attribut `member` : au-dela d environ 1500 entrees, `member` est renvoye par tranches et une lecture naive perdrait des membres sans le signaler. Le groupe principal est ajoute a partir de `primaryGroupID`.
- Le tout reste compatible Windows PowerShell 2.0 : ni `[pscustomobject]`, ni `::new()`, ni operateur apparu en 3.0.

### Garde-fous

- Suppression : un conteneur non vide exige `-Recursive` et le nombre d objets emportes est annonce ; un objet protege contre la suppression accidentelle exige `-RemoveProtection`.
- Deplacement : une unite ne peut pas etre deplacee dans elle-meme ni dans l une de ses sous-unites, et la destination doit etre un conteneur.
- Groupes : le retrait d un membre de son groupe principal est refuse avec un message explicite plutot qu avec l echec brut du controleur.
- Recherche : le terme saisi est echappe avant l ajout des jokers, et un nom d attribut invalide est refuse. Une parenthese ou une etoile saisie par l operateur est du texte, pas de la syntaxe LDAP.
- `-WhatIf` et la confirmation recapitulative s appliquent a toutes les ecritures de la console, simulation cochee par defaut.

### Tests

- `Tests\Console.Tests.ps1` : 49 controles sans annuaire, dont la disposition d octets de `logonHours` telle que documentee par Active Directory, l aller-retour du masque pour tous les fuseaux, les formats regionaux, le generateur, l echappement des filtres, les garde-fous et l absence du mot de passe dans le journal.
- `Tests\ConsoleInterface.Tests.ps1` : analyse syntaxique de l interface sans lancer GliderUI. Verifie que toute ecriture passe par une fonction exportee, que chaque action de menu contextuel a un bouton equivalent, et que les grilles passent par le formatage regional.
- `Tests\PSADToolkit.Tests.ps1` derive desormais la liste des fonctions du manifeste : ajouter une fonction publique sans aide integree ou sans la declarer fait echouer la suite. Cela a revele l absence d exemple dans l aide de `Import-ADTUserFromCsv`, corrigee ici.
- `Tests\Test-Compatibility.ps1` refuse en plus `-shl`, `-shr`, `-in` et `-notin` dans les fichiers cibles PowerShell 2.0. Ces operateurs s analysent sans erreur sur un moteur moderne ; `-shl` avait ete introduit par megarde dans la conversion des horaires.
- `Tests\Regression.Tests.ps1` : le controle des cellules CSV excedentaires exigeait un refus, alors que le comportement documente - et couvert par `Examples\Tests-CSV\03-groupes-non-quotes.csv` - est de rattacher ces cellules a la colonne `Groups`. Le test verifie desormais cette reconstitution, et le refus est verifie sur un CSV sans colonne `Groups`.


## 3.0.0-test4 - 2026-09-17

- README : liens de telechargement de PowerShell 7 (versions publiees, commande winget, procedure Microsoft) dans l etape de demarrage, le tableau de compatibilite et les references. Precision que PowerShell 7 cohabite avec Windows PowerShell 5.1 au lieu de le remplacer.
- README : liens vers GliderUI, sur PowerShell Gallery et sur son depot.

## 3.0.0-test3 - 2026-09-17

- Correction de `Impossible de convertir la valeur GliderUI.Avalonia.Controls.DataGridTextColumn ... en type System.Collections.Hashtable[]`. Dans `New-ADTUiDataGrid` et `New-ADTUiDataSourceList`, la boucle `foreach ($column ...)` reutilisait le nom du parametre `[hashtable[]]$Column` : les noms de variables PowerShell etant insensibles a la casse, la contrainte de type du parametre s appliquait a la variable de boucle. Aucune grille de resultats ne pouvait s afficher, ni l apercu avant import.
- Ajout de `Tests\Test-ParameterShadowing.ps1` : le controle echoue si une boucle `foreach` reutilise le nom d un parametre type, dans tout le depot.

## 3.0.0-test2 - 2026-09-17

- Correction du refus `Lancer avec Windows PowerShell (powershell.exe), pas PowerShell 7 (pwsh.exe)` : `Test-ADTPrerequisite` interdisait encore PowerShell 7, ce qui bloquait la connexion au domaine depuis la nouvelle interface. La verification porte desormais sur Windows et sur la disponibilite de `System.DirectoryServices`, quel que soit le moteur.
- Repli lorsque `Add-Type -AssemblyName System.DirectoryServices` echoue alors que le type reste resolvable, cas possible sous PowerShell 7.
- Ajout de `Examples\Tests-CSV` : onze fichiers CSV de test et leur mode d emploi. Six doivent passer, cinq doivent etre refuses avant toute ecriture dans l annuaire.

## 3.0.0-test1 - 2026-09-17

- Interface Windows Forms remplacee par GliderUI (Avalonia). Les sept onglets, le selecteur d OU, l apercu d import, la grille de resultats et les exports sont conserves.
- L interface exige desormais PowerShell 7.4 et le module GliderUI avec son serveur (`Install-GLIServer`). `Lancer.cmd` demarre `pwsh.exe` ; le mode STA n est plus necessaire.
- Le runspace de travail et le minuteur de scrutation disparaissent : GliderUI affiche l interface dans un processus separe, les traitements longs s executent dans le runspace principal sans figer la fenetre.
- L apercu d import reutilise `Get-ADTImportTargetOU` et `Get-ADTCsvRowGroups` du module au lieu d en redupliquer la logique.
- Le selecteur d OU lit toutes les unites d organisation en une requete puis reconstruit l arbre a partir des DN : Avalonia n expose pas d evenement d expansion exploitable pour un chargement paresseux.
- Le module reste compatible Windows PowerShell 2.0 en ligne de commande. Manifeste, `Private`, `Public` et standalone inchanges.
- `Tests\Interface.Tests.ps1` remis d accord avec l interface : il verifiait encore 35 champs et un format de champ abandonne en 2.1.0. Ajout du controle des types de controles et des commandes exportees.
- `Tests\Test-Compatibility.ps1` n analyse plus l interface avec les regles PowerShell 2.0.
- Aucun changement du code d exploitation Active Directory.

## 2.1.4-test1 - 2026-09-17

- Ajout de `VERSIONING.md` : format des numeros, canaux `test` / `rc` / stable, emplacements ou la version est inscrite et procedure de publication.
- Canal de version explicite dans le manifeste (`PrivateData.PSData.Prerelease`), repris par `Build.ps1` pour l en-tete du standalone.
- Versions affichees remises d accord : le README et la validation annoncaient 2.1.1, le titre de l interface 2.1.2, le manifeste 2.1.3.
- Ajout de `Tests\Test-VersionConsistency.ps1`, qui echoue si un fichier annonce une version differente de celle du manifeste.
- Standalone regenere a partir des sources. Aucun changement du code d exploitation : 2.1.4-test1 se comporte comme 2.1.3.
- Le canal `test1` indique que la recette Windows de `VALIDATION.md` reste a faire.

## 2.1.3 - 2026-09-14

- Resolution des groupes CSV par sAMAccountName, Name ou CN dans tout le domaine.
- Un groupe absent ou non accessible ne bloque plus la creation de tous les utilisateurs du CSV.
- Les groupes non resolus sont affiches comme avertissements et rendent le compte cree `Partiel` plutot que `Echec`.
- L ajout aux groupes utilise leur DistinguishedName resolu pour eviter les ambiguities de nom.

## 2.1.2 - 2026-09-14

- Correction de l erreur `Colonne obligatoire absente : GivenName` qui affichait `Count, Length, LongLength...`.
- `Read-ADTFlexibleCsv` et le lecteur CSV de l interface ne renvoient plus un tableau imbrique.
- La detection des colonnes lit maintenant correctement les proprietes de la premiere ligne CSV.
- Correction equivalente de la liste des groupes pour retourner un tableau plat et valider chaque groupe separement.
- Ajout d un test de regression pour les en-tetes `GivenName` / `Surname` et les groupes multiples.

## 2.1.1 - 2026-09-14

- La sélection d’un fichier CSV dans l’interface ouvre immédiatement l’arborescence Active Directory pour choisir l’OU de destination.
- L’OU choisie dans l’interface a priorité sur une éventuelle colonne `OU` du CSV.
- L’OU de destination est maintenant obligatoire dans l’interface d’import.
- Avec la création automatique par département, les sous-OU sont créées sous l’OU choisie.

## 2.1.0 - 2026-09-14

- Ajout d'un selecteur graphique d'OU base sur l'arborescence Active Directory.
- Ajout de la creation automatique des sous-OU a partir de la colonne Department pendant l'import CSV.
- Ajout d'un apercu tabulaire avant tout import lance depuis l'interface.
- Lecture robuste de tous les groupes d'un CSV, y compris les exports non quotes ou `;` sert a la fois de separateur de colonnes et de groupes.
- Correction de la definition des champs WinForms pour eviter l'erreur `System.Char.EndsWith` sur les anciennes versions de Windows PowerShell.
- Conservation de la cible Windows PowerShell 2.0 a 5.1 / Windows Server 2008 SP2 a 2025.

## 2.0.1

- Correction du plantage au lancement : le champ unique de l’onglet Privilèges était aplati en trois chaînes. L’interface parcourait alors chaque chaîne et traitait le deuxième caractère comme un libellé, causant l’erreur `System.Char.EndsWith`.
- Conservation explicite du tableau imbriqué du champ unique, et validation de la structure de chaque champ avant de créer les contrôles.
- Trois tests de régression vérifient les définitions réelles des sept onglets et l’appel `EndsWith` pour les 35 champs. Ces tests reproduisaient le problème avant la correction.

## 2.0.0

- Interface Windows Forms en français : sept onglets, connexion avec autre compte, simulation, confirmation récapitulative, tableau et export CSV, traitements en arrière-plan.
- Lanceur Windows PowerShell STA, sans changement permanent de stratégie d'exécution.
- Backend LDAP/ADSI sans RSAT/ADWS pour cibler aussi Server 2008 SP2 non-R2. Authentification intégrée avec signature et chiffrement ; filtre LDAP et DN échappés séparément.
- Arrêt de la création si la recherche d'un identifiant unique échoue. Identifiant explicitement demandé déjà utilisé : échec au lieu d'un renommage silencieux.
- Contrôleur de domaine et identifiants correctement transmis, notamment dans SkipExisting. CN basé sur l'identifiant unique et permissions de dossier basées sur le SID AD.
- Validation structurelle du CSV et des lignes avant mutation, y compris cellules excédentaires et doublons normalisés. Correction des listes de groupes du CSV d'exemple.
- Départ : deux sauvegardes obligatoires, désactivation avant reset/retraits, une confirmation pour l'ensemble de la procédure, erreurs partielles et étapes exactes exposées.
- Créations partiellement terminées signalées. Aucun mot de passe affiché dans le résultat d'une simulation de création.
- Comptes nouvellement créés exclus du seuil d'inactivité lorsqu'ils n'ont pas encore ouvert de session.
- Audit : recherche paginée, prise en compte des groupes principaux, erreurs d'audit visibles, portée du domaine explicitée, nombre d'utilisateurs privilégiés distincts dans le résumé.
- Journal par défaut accessible dans le profil de l'opérateur, sans obligation d'élévation locale.
- Chargement du module interrompu si un fichier source échoue ; encodage UTF-8 avec BOM ; standalone reconstruit.
- Tests initiaux réparés pour les phases de découverte/exécution de Pester 5 ; régressions ajoutées et contrôle de syntaxe ciblant PS 2.0 / 5.1.
