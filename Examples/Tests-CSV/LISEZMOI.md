# Fichiers CSV de test

Jeu de fixtures pour exercer l'import CSV de PSADToolkit, onglet **Importer un CSV** ou
`Import-ADTUserFromCsv`. Six fichiers doivent passer, cinq doivent être refusés : les refus
font partie du test, ils vérifient que l'outil s'arrête **avant** d'écrire dans Active Directory.

Les fichiers sont en UTF-8 avec BOM, comme ceux qu'exportent Excel et la plupart des SIRH.

| Fichier | Séparateur | Ce qu'il exerce | Résultat attendu |
|---|---|---|---|
| `01-nominal.csv` | `;` | Cas courant : toutes les colonnes reconnues, groupes entre guillemets, colonne `OU` | 4 lignes, aucun refus |
| `02-separateur-virgule.csv` | `,` | Option **Séparateur du CSV** = `,`, DN entre guillemets car il contient des virgules | 3 lignes, aucun refus |
| `03-groupes-non-quotes.csv` | `;` | Export où `;` sert à la fois de séparateur de colonnes et de groupes, sans guillemets, `Groups` n'étant pas la dernière colonne | 3 lignes ; groupes reconstitués (2, 3 et 1 groupes) et colonnes suivantes correctement décalées |
| `04-accents.csv` | `;` | Accents, trémas, cédille, trait d'union et apostrophe : normalisation ASCII de l'identifiant | 5 lignes, aucun refus ; `José Gagné` doit donner `jgagne` |
| `05-departements.csv` | `;` | Option **Créer automatiquement une sous-OU par département**, avec un département contenant une virgule (`Ventes, Grand Montreal`) et un département vide | 5 lignes ; le DN de la sous-OU doit être échappé `OU=Ventes\, Grand Montreal,...` et la ligne sans département doit rester dans l'OU parente |
| `11-volume-60-lignes.csv` | `;` | Volume : aperçu, défilement de la grille, durée du traitement | 60 lignes, aucun refus |
| `06-identifiants-dupliques.csv` | `;` | Collision d'identifiants **après** normalisation des accents | **Refus** : `Ligne 3 : identifiant duplique apres normalisation : jcote` |
| `07-colonne-obligatoire-absente.csv` | `;` | Colonne `Surname` absente | **Refus** : `Colonne obligatoire absente : Surname` |
| `08-lignes-incompletes.csv` | `;` | Prénom vide, nom vide, OU vide | **Refus** : trois messages, lignes 3, 4 et 5 |
| `09-colonne-dupliquee.csv` | `;` | En-tête contenant deux fois `Department` | **Refus** à la lecture : `Colonne CSV vide ou dupliquee : Department` |
| `10-sans-ou.csv` | `;` | Ni colonne `OU`, ni OU de destination | **Refus** : `Aucune colonne 'OU' dans le CSV et aucun -DefaultOU fourni.` Avec une OU choisie dans l'interface, le fichier passe |

Les numéros de ligne des messages sont ceux du fichier, en-tête comprise : la première ligne de
données est la ligne 2.

## Depuis l'interface

Onglet **Importer un CSV**, bouton `...` du champ **Fichier CSV**. Le sélecteur d'OU s'ouvre
aussitôt après le choix du fichier. Garder **Simulation** cochée : l'aperçu et la simulation
n'écrivent rien dans Active Directory.

## En ligne de commande

```powershell
Import-ADTUserFromCsv -Path .\Examples\Tests-CSV\01-nominal.csv `
    -DefaultOU 'OU=Employes,DC=contoso,DC=local' `
    -Server 'dc01.contoso.local' -WhatIf

Import-ADTUserFromCsv -Path .\Examples\Tests-CSV\02-separateur-virgule.csv -Delimiter ',' `
    -DefaultOU 'OU=Employes,DC=contoso,DC=local' -Server 'dc01.contoso.local' -WhatIf

Import-ADTUserFromCsv -Path .\Examples\Tests-CSV\05-departements.csv -CreateDepartmentOUs `
    -DefaultOU 'OU=Employes,DC=contoso,DC=local' -Server 'dc01.contoso.local' -WhatIf
```

Les DN, groupes et adresses de ces fichiers pointent vers `contoso.local` : les remplacer par
ceux du laboratoire, sans quoi la validation signalera des OU et des groupes inaccessibles.
Cette vérification-là exige un annuaire ; seules la lecture du fichier et les règles de
structure fonctionnent hors domaine.

## Ce qui a été vérifié

La lecture et les règles structurelles de ces onze fichiers ont été exécutées avec
`Read-ADTFlexibleCsv`, `Get-ADTCsvRowGroups` et `Get-ADTImportTargetOU` du module, et
chacun rend bien le résultat annoncé ci-dessus. Les vérifications qui demandent un annuaire
— existence des OU, résolution des groupes, unicité réelle des identifiants — n'ont pas
pu être exécutées.
