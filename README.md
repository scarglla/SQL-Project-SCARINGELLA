# NovaBank - Core Banking Database Architecture

NovaBank est un système de base de données relationnelle hautement sécurisé, performant et automatisé pour une banque en ligne. Ce projet implémente une architecture PostgreSQL robuste garantissant l'intégrité financière, la sécurité des accès, l'immuabilité de l'historique et l'optimisation des performances pour un volume de un million d'écritures.

---

## Arborescence des Fichiers

.
Documentation-SQL.pdf
deploy.sh
README.md

---

## Schéma des Tables et Modélisation

* core.customers : Informations d'identification et profils des clients (contrainte d'âge majeur).
* core.accounts : Comptes bancaires rattachés aux clients (solde positif, IBAN unique).
* core.transfers : Enregistrement des virements inter-comptes (comptes distincts, montant positif).
* core.transactions : Le grand livre financier central (immuable, traçabilité des soldes après opération).
* core.fraud_alerts : Détection et journalisation des alertes de retraits ou flux suspects.
* audit.audit_log : Journal des modifications et traçabilité globale des actions.

---

## Droits et Gestion des Rôles

* postgres : Administrateur global du serveur et de l'instance PostgreSQL.
* bank_owner : Propriétaire des objets de la base de données et des schémas core et audit.
* analysts : Rôle sans connexion directe (NOLOGIN), accès restreint aux vues agrégées et statistiques.
* support : Rôle sans connexion directe, accès aux données clients via des vues masquées pour protéger la vie privée.
* auditors : Rôle sans connexion directe, accès en consultation stricte aux journaux d'audit et à l'historique financier.

---

## Commandes dans l'Ordre pour Tout Refaire

Pour exécuter le déploiement complet de zéro à partir du script d'automatisation :

1. Rendre le script exécutable :
   chmod +x deploy.sh

2. Lancer le script de réinitialisation globale :
   sudo ./deploy.sh

## BONUS

## Recapitulatif des Defis Realises

### Defi C1 : Chiffrement des connexions (TLS / pg_hba.conf)
* Objectif : Garantir la confidentalite des echanges client-serveur et interdire le trafic en clair.
* Realisation : 
  * Configuration du fichier `pg_hba.conf` avec des regles `hostnossl ... reject` pour bloquer les connexions non chiffrees.
  * Utilisation de regles `hostssl` associees a l'authentification `scram-sha-256`.
  * Validation par test de connexion forcant (`sslmode=require`) et rejetant (`sslmode=disable`) le chiffrement.

### Defi C2 : Analyse forensique et detection des attaques
* Objectif : Assurer la traçabilite des acces et reperer les tentatives de compromission.
* Realisation : 
  * Activation du parametre `log_connections = on` dans `postgresql.conf`.
  * Simulation d'attaques par force brute via des echecs d'authentification repetes.
  * Analyse et comptage des occurrences d'erreur dans les journaux systeme via `grep`.

### Defi C3 : Chiffrement symetrique des donnees au repos (pgcrypto)
* Objectif : proteger les donnees sensibles (numeros de telephone) stockees en base.
* Realisation : 
  * Installation de l'extension `CREATE EXTENSION pgcrypto;`.
  * Migration de la colonne `phone` du type `VARCHAR(20)` vers le format binaire `BYTEA`.
  * Utilisation des fonctions `pgp_sym_encrypt` et `pgp_sym_decrypt` pour chiffrer a l'insertion et dechiffrer a la volee.

### Defi C4 : Injection SQL et remediaton (PL/pgSQL)
* Objectif : Identifier une faille d'injection SQL dans une fonction dynamique et appliquer un correctif.
* Realisation : 
  * Creation d'une fonction vulnerable construite par concatenation directe (`||`).
  * Demonstration d'un contournement de condition (`OR '1'='1'`).
  * Reecriture securisee de la fonction a l'aide de `format()` et du specificateur `%L` pour echapper les entrees.
