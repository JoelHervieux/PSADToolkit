# Validation

> **État au 17 septembre 2026 : version du dépôt `3.1.0-test1`.** Aucune version de ce dépôt n'a passé la recette Windows. Ce qui est décrit ci-dessous a été **réellement exécuté**, sous Linux, avec PowerShell 7.4.6 et Pester 5.7.1 ; ce qui ne l'a pas été est listé explicitement. Voir `VERSIONING.md` pour la nomenclature et les conditions de passage en version stable.

## Ce qui a été exécuté pour 3.1.0-test1

Environnement : Linux, PowerShell 7.4.6, Pester 5.7.1. **PSScriptAnalyzer n'était pas installable dans cet environnement** ; `Tests\Test-Compatibility.ps1` n'a donc pas pu être lancé et doit l'être sur le poste de développement Windows.

| Vérification | Résultat |
|---|---|
| Analyse syntaxique native des 59 fichiers PowerShell du dépôt | Réussie, aucune erreur |
| Import du module et export des 27 fonctions publiques | Réussi |
| `Invoke-Pester -Path .\Tests` | **129 réussis, 0 échec** |
| `Tests\Test-ParameterShadowing.ps1` | PASS, 57 fichiers analysés (le standalone est exclu) |
| `Tests\Test-VersionConsistency.ps1` | PASS |
| `Build.ps1` : génération et analyse syntaxique du standalone | Réussies, 41 fonctions, 5588 lignes |
| Chargement du standalone et appel des nouvelles fonctions hors annuaire | Réussi |
| Aide intégrée des 27 fonctions : synopsis et exemple | Présents pour toutes |

Répartition des 129 tests : `Console.Tests.ps1` 49, `PSADToolkit.Tests.ps1` 45, `Regression.Tests.ps1` 21, `ConsoleInterface.Tests.ps1` 9, `Interface.Tests.ps1` 5.

## Ce que ces tests couvrent

**Horaires de connexion.** Disposition d'octets de `logonHours` comparée à la convention documentée par Active Directory ; aller-retour masque → octets → masque pour les 27 décalages horaires de −12 à +14 ; vérification que les bits sont bien **décalés** selon le fuseau et non recopiés ; attribut absent traité comme « toutes les heures » ; refus d'un masque mal formé ou d'un nombre d'octets différent de 21.

**Formats régionaux.** Mise en forme des dates sous `fr-FR` et `en-US` ; ordre des jours selon le premier jour de semaine de la culture ; détection de l'horloge 24 heures y compris pour `fr-CA`, dont le motif `HH 'h' mm` contient un `h` littéral qui aurait été pris pour un spécificateur d'heure sur 12.

**Mots de passe.** Respect des classes demandées ; exclusion des caractères ambigus ; unicité et longueur sur 25 tirages ; relèvement de la longueur au minimum de la stratégie du domaine simulée ; règle de complexité Microsoft.

**Lecture.** Les conteneurs sont classés avant les objets feuilles et l'état d'un compte résume activation, verrouillage, expiration et changement de mot de passe ; un conteneur n'affiche pas d'état de compte. La feuille de propriétés calcule bien le conteneur parent, le dernier jour ouvert du compte, le masque d'horaires et les appartenances rendues lisibles malgré les échappements de DN.

**Écritures.** Seules les propriétés fournies sont écrites, une chaîne vide efface l'attribut ; un échec sur un compte n'interrompt pas le traitement des suivants et la simulation n'écrit rien ; l'expiration est bien fixée au début du jour suivant le dernier jour ouvert ; l'horaire appliqué aux membres d'un groupe épargne les comptes exclus et ignore les groupes imbriqués ; refus de supprimer un conteneur non vide ou protégé ; refus de déplacer une unité dans sa propre sous-arborescence ; refus de retirer un membre de son groupe principal.

**Recherche.** Le terme saisi est échappé avant l'ajout des jokers ; un nom d'attribut invalide est refusé ; le filtre produit reste équilibré en parenthèses. Le contrôle vérifie qu'une tentative d'injection LDAP saisie dans le champ de recherche ressort comme du texte.

**Document de remise.** Le mot de passe figure dans le document, **jamais dans le journal** ; le contenu injecté est échappé ; un fichier existant n'est pas écrasé sans `-Force`.

**Interface.** L'arbre syntaxique de `Start-PSADToolkit.ps1` et des cinq fichiers `UI\` est analysé sans lancer GliderUI : toute écriture passe par une fonction exportée du module, aucune fonction `*-ADT*` appelée n'est inconnue, chaque action de menu contextuel a bien un bouton équivalent, et les grilles passent par le formatage régional.

**Compatibilité PowerShell 2.0.** Absence de `[pscustomobject]`, `[ordered]`, `::new()`, `$PSScriptRoot` et des opérateurs `-shl`, `-shr`, `-in`, `-notin` dans `Private\` et `Public\`. Ce contrôle a été vérifié en réintroduisant volontairement un `-shl` : la suite passe au rouge, puis revient au vert une fois la correction rétablie.

## Non vérifié dans cet environnement

- **L'interface graphique n'a été exécutée sur aucune machine.** Ni GliderUI, ni Avalonia, ni Windows n'étaient disponibles. L'affichage réel de l'arborescence, de la grille des horaires, des menus contextuels, de la sélection multiple et des feuilles de propriétés reste entièrement à valider.
- Les interactions dépendantes de la version de GliderUI installée : `ContextMenu`, `DoubleTapped`, `DataGrid.SelectedItems`. Elles sont branchées de façon tolérante et chaque action dispose d'un bouton équivalent, mais ce repli n'a pas été observé en conditions réelles.
- Toute écriture LDAP réelle : `logonHours`, `accountExpires`, `lockoutTime`, `userAccountControl`, création de groupe et d'unité, renommage, suppression, et la protection contre la suppression accidentelle qui passe par le descripteur de sécurité.
- La lecture d'une stratégie de mot de passe affinée (`msDS-ResultantPSO`) sur un domaine de niveau 2008 ou supérieur.
- L'exécution sur Windows PowerShell 2.0 / .NET 2.0 sous Server 2008 SP2.
- `Tests\Test-Compatibility.ps1` et PSScriptAnalyzer.
- Le pipeline GitHub Actions.

## Recette Windows à effectuer dans une OU de laboratoire

Reprendre d'abord la recette 2.1.1 : connexion au domaine et avec un compte délégué, création d'un utilisateur jetable en simulation puis réellement, import CSV avec ligne multigroupe, refus de délégation, départ avec sauvegarde inaccessible puis avec sauvegarde valide, audit avec groupe imbriqué et groupe principal privilégié.

Ajouter ensuite, pour la console :

1. **Arborescence.** Charger l'arborescence, déplier le domaine, sélectionner plusieurs unités et vérifier que le contenu correspond à celui d'ADUC, y compris `Builtin`, `Users` et `Computers`.
2. **Sélection multiple et menus.** Sélectionner plusieurs comptes avec Ctrl et Maj, vérifier que les actions en lot portent bien sur toute la sélection. Tester le clic droit dans l'arborescence et dans la liste, et le double-clic sur un utilisateur. **Si l'une de ces interactions ne répond pas, vérifier que le bouton équivalent, lui, fonctionne** : c'est le repli prévu.
3. **Propriétés.** Ouvrir un utilisateur, modifier un seul champ, enregistrer, puis rouvrir la fiche dans ADUC et vérifier que **seul** ce champ a changé. Vider un champ et vérifier que l'attribut est effacé.
4. **Expiration.** Fixer une date d'expiration, puis comparer avec « Fin de : » dans ADUC : les deux doivent afficher le même jour.
5. **Horaires de connexion.** Appliquer un horaire 8 h – 18 h du lundi au vendredi, puis ouvrir les horaires du même compte dans ADUC sur un poste du **même fuseau** : la grille doit être identique. Répéter sur un poste d'un **autre fuseau** pour confirmer le décalage. Tester l'application aux membres d'un groupe avec au moins un compte exclu, et vérifier que l'exclu a conservé son horaire.
6. **Mots de passe.** Générer avec et sans caractères spéciaux, vérifier qu'un domaine exigeant plus de 12 caractères relève bien la longueur, puis réinitialiser un compte de test et ouvrir une session avec le mot de passe obtenu.
7. **Document de remise.** Le produire, vérifier son contenu, puis **ouvrir `%LOCALAPPDATA%\PSADToolkit\PSADToolkit.log` et confirmer que le mot de passe n'y figure pas**.
8. **Suppression et protection.** Tenter de supprimer une unité protégée et non vide, vérifier les deux refus, puis recommencer avec les options de levée.
9. **Formats régionaux.** Basculer le format régional du poste entre français (Canada), français (France) et anglais (États-Unis), relancer l'interface et vérifier les dates des grilles, l'ordre des jours et les en-têtes d'heures de la grille des horaires.
10. **Volume.** Ouvrir une unité contenant plusieurs milliers d'objets et un groupe de plus de 1500 membres, pour vérifier les temps de réponse et l'absence de troncature silencieuse.

Réaliser cette recette au minimum sur Server 2008 SP2 / PowerShell 2.0 pour la ligne de commande, et sur un serveur récent pour l'interface, avant toute écriture en production.

## Rapport antérieur : livraison 2.1.1

Validation réalisée le 14 septembre 2026 sous Linux, avec PowerShell 7.4.6, Pester 5.7.1 et PSScriptAnalyzer 1.24.0 : 41 tests Pester réussis, règle `PSUseCompatibleSyntax` ciblant 2.0 et 5.1 sans signalement, analyse de gravité Error sans erreur non justifiée, construction et analyse du standalone réussies.

Une suppression locale et documentée de `PSAvoidUsingUsernameAndPasswordParams` est présente dans `New-ADTUser`, et de `PSAvoidUsingPlainTextForPassword` dans `New-ADTPassword` et `New-ADTCredentialDocument`. L'analyseur confond les noms de paramètres `UserPrincipalNameSuffix`, `PasswordLength` et `Length` avec des identifiants d'authentification ; le paramètre `Password` de `New-ADTUser` est un `SecureString` et l'authentification utilise `PSCredential`. `New-ADTPassword` et `New-ADTCredentialDocument` manipulent délibérément un mot de passe temporaire en clair, puisque c'est leur objet : le produire et le remettre à l'employé.

L'interface Windows Forms décrite dans ce rapport a été remplacée par GliderUI en 3.0.0, puis complétée par la console en 3.1.0 ; ces deux interfaces n'ont encore été exécutées sur aucune machine.
