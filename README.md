# NovaBank Core

Base de données PostgreSQL 18 d'une banque en ligne :

- chacun voit seulement ce dont il a besoin ;
- un virement se fait en entier ou pas du tout ;
- l'historique d'un compte s'affiche tout de suite, même avec 1 000 000 d'écritures.

## Installation

```bash
chmod +x install_server.sh setup_project.sh tests.sh
sudo ./install_server.sh
sudo ./setup_project.sh
sudo ./tests.sh
```

- `install_server.sh` : installe PostgreSQL, configure `pg_hba.conf`, TLS et le pare-feu. Réseau autorisé par défaut : `192.168.56.0/24` (autre réseau : `sudo ADMIN_NETWORK=x.x.x.x/24 ./install_server.sh`).
- `setup_project.sh` : supprime et recrée toute la base. Demande une confirmation puis les mots de passe (aucun mot de passe dans Git).
- `tests.sh` : vérifie que tout marche et que les interdits sont refusés.

## Fichiers

```
install_server.sh      installation du serveur
setup_project.sh       tout refaire
tests.sh               tests
sql/00_database.sql    rôles et base
sql/01_tables.sql      tables et protections
sql/02_data.sql        1 000 000 d'écritures
sql/03_views.sql       vues
sql/04_indexes.sql     index (avec mesures avant / après)
sql/05_triggers.sql    triggers
sql/06_procedures.sql  procédures
sql/07_rights.sql      droits
sql/08_bonus.sql       bonus
```

## Tables

```
customers 1 ── n accounts 1 ── n transactions n ── 1 transfers
                    │                  │
                    └──── n fraud_alerts

audit.audit_log : historique des changements
```

| Table | Règles |
|---|---|
| `core.customers` | email unique et valide, client majeur |
| `core.accounts` | IBAN unique, solde jamais négatif |
| `core.transfers` | montant positif, deux comptes différents |
| `core.transactions` | jamais modifiée ni supprimée, un virement = 2 écritures |
| `core.fraud_alerts` | alerte si retrait ≥ 5 000 ou 5 virements en 10 minutes |
| `audit.audit_log` | qui, quand, avant, après |

## Rôles

| Compte | Groupe | Droits |
|---|---|---|
| `bank_owner` | — | propriétaire de tout |
| `alice_analyst` | `analysts` | statistiques sans nom ni email |
| `bob_support` | `support` | clients avec email et nom masqués |
| `app_user` | `application` | uniquement les procédures (virement, ouverture de compte, relevé) |
| `charlie_auditor` | `auditors` | lecture du journal d'audit et des opérations |

## Utilisation

```sql
CALL core.open_account(1, 'FR7612345000000000000000001', 'CHECKING', 100, NULL);
CALL core.safe_transfer(1, 2, 50.00);
SELECT * FROM core.get_statement(1);
```

## Sauvegarde

```bash
sudo -u postgres pg_dump -Fc -d bankdb -f /tmp/bankdb.dump
sudo -u postgres createdb bankdb_restore
sudo -u postgres pg_restore -d bankdb_restore /tmp/bankdb.dump
```

## Bonus

- **C1** : connexions chiffrées en TLS, connexion sans TLS refusée.
- **C2** : `sudo grep -c "password authentication failed" /var/log/postgresql/postgresql-18-main.log`
- **C3** : téléphone chiffré avec pgcrypto (`core.set_customer_phone`, `core.fn_phone_decrypt`).
- **C4** : injection SQL avec `core.search_client_unsafe`, corrigée dans `core.search_client_safe`.
- **D1** : 5 analyses (`core.v_d1_*`).
- **D2** : retraits anormaux dans `core.withdrawal_anomalies`.
