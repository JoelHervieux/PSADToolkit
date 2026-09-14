# Changements — 2.0.1

- Correction du plantage au lancement : le champ unique de l’onglet Privilèges était aplati en trois chaînes. L’interface parcourait alors chaque chaîne et traitait le deuxième caractère comme un libellé, causant l’erreur `System.Char.EndsWith`.
- Conservation explicite du tableau imbriqué du champ unique, et validation de la structure de chaque champ avant de créer les contrôles.
- Trois tests de régression vérifient les définitions réelles des sept onglets et l’appel `EndsWith` pour les 35 champs. Ces tests reproduisaient le problème avant la correction.

# Changements — 2.0.0

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
