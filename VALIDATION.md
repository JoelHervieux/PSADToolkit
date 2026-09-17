# Validation de la livraison 2.1.1

> État au 17 septembre 2026 : la version courante du dépôt est `2.1.4-test1`. Le rapport ci-dessous porte sur la livraison 2.1.1 ; les correctifs 2.1.2, 2.1.3 et 2.1.4 n'ont pas été revalidés et la recette Windows reste entièrement à faire. Ce fichier garde volontairement le numéro réellement validé : voir `VERSIONING.md` pour la nomenclature et les conditions de passage en version stable.

Validation réalisée le 14 septembre 2026 dans un environnement Linux, avec PowerShell 7.4.6, Pester 5.7.1 et PSScriptAnalyzer 1.24.0.

| Vérification | Résultat |
|---|---|
| Analyse syntaxique native des fichiers PowerShell | Réussie |
| Import du module et des huit fonctions publiques | Réussi |
| Tests Pester initiaux et régressions | **41 réussis, 0 échec** |
| Règle PSScriptAnalyzer PSUseCompatibleSyntax ciblant 2.0 et 5.1 | Aucune incompatibilité signalée |
| Analyse PSScriptAnalyzer, gravité Error, fichiers d'exploitation | Aucune erreur non justifiée |
| Recherche des principales API modernes interdites dans les sources d'exploitation | Aucune trouvée |
| Construction et analyse syntaxique du standalone | Réussies |
| CSV d'exemple : structure et conservation des groupes | Réussies |

Une suppression locale et documentée de `PSAvoidUsingUsernameAndPasswordParams` est présente dans `New-ADTUser`. L'analyseur confond les noms de paramètres `UserPrincipalNameSuffix` / `PasswordLength` avec des identifiants d'authentification. Le véritable paramètre `Password` est un `SecureString`; l'authentification utilise `PSCredential`. Les autres avertissements de style ne sont pas tous supprimés.

## Régressions vérifiées avec des fonctions LDAP simulées

Échappement des filtres LDAP et RDN ; fichier CSV mal formé ; conservation des groupes du CSV ; arrêt si l'annuaire ne peut pas vérifier l'unicité ; refus d'un identifiant explicite existant ; simulation sans création ni mot de passe retourné ; échec partiel d'ajout à un groupe ; contrôleur sélectionné réutilisé ; validation de toutes les lignes avant création ; collisions après normalisation des accents ; transmission du serveur et du compte alternatif dans SkipExisting ; simulation de départ sans écriture ; aucune modification AD si la sauvegarde échoue ; désactivation avant réinitialisation et poursuite des retraits après échec du mot de passe ; seuil d'inactivité appliqué aux comptes jamais utilisés.

## Correctifs de l’interface 2.1.0

Les trois nouveaux tests reproduisent le défaut avant correction et vérifient ensuite la structure des 35 champs des sept onglets, le calcul des champs obligatoires par `EndsWith`, et le champ unique `IncludeBuiltin` de l’onglet Privilèges. La reproduction utilise les définitions réelles extraites du script ; elle ne lance pas Windows Forms.

## Non vérifié dans cet environnement

- Affichage et interaction réels de Windows Forms sous Windows.
- Exécution du moteur Windows PowerShell 2.0 / .NET 2.0 sur Server 2008 SP2.
- Connexions LDAP réelles, politiques de domaine, refus d'accès et opérations sur un contrôleur AD.
- Création et ACL de dossiers sur un partage Windows.
- Exécution du pipeline GitHub Actions configuré pour Windows PowerShell 5.1.

Les tests modernes et les mocks vérifient la logique et la syntaxe ; ils ne prouvent pas à eux seuls la compatibilité d'exécution sur tous les systèmes ciblés.

## Recette Windows à effectuer dans une OU de laboratoire

Lancer `Lancer.cmd`, tester le domaine et un autre compte délégué, puis créer un utilisateur jetable en simulation avant création réelle. Vérifier le CN, le displayName, l'UPN, le changement de mot de passe, les groupes et le SID dans l'ACL éventuelle. Importer un CSV de test et vérifier les trois groupes d'une ligne multigroupe. Tester un refus de délégation, puis un départ avec sauvegarde inaccessible : le compte doit rester intact. Réaliser ensuite un départ avec sauvegarde valide et contrôler les fichiers, la désactivation et les étapes indiquées. Vérifier enfin l'audit avec un groupe imbriqué et un groupe principal privilégié, ainsi que les résultats `NON AUDITE` lorsque la lecture est impossible.

Réaliser cette recette au minimum sur Server 2008 SP2 / PowerShell 2.0 et sur un serveur récent / PowerShell 5.1 avant d'utiliser les écritures en production.
