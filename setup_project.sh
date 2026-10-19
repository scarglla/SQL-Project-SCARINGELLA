#!/usr/bin/env bash
set -euo pipefail

DB_NAME="bankdb"
OWNER="bank_owner"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SQL_DIR="$SCRIPT_DIR/sql"
PROJECT_ROLES="bank_owner, app_user, alice_analyst, bob_support, charlie_auditor, analysts, support, application, auditors"

declare -A PASSWORD_VARS=(
    [bank_owner]=owner_password
    [app_user]=app_password
    [alice_analyst]=analyst_password
    [bob_support]=support_password
    [charlie_auditor]=auditor_password
)

step() {
    echo
    echo "==> $*"
}

as_postgres() {
    sudo -u postgres psql -X -q -v ON_ERROR_STOP=1 "$@"
}

psql_quote() {
    local value=${1//\\/\\\\}
    printf "'%s'" "${value//\'/\'\'}"
}

if [[ $EUID -ne 0 ]]; then
    echo "Ce script doit etre lance en root : sudo $0" >&2
    exit 1
fi

if ! systemctl is-active --quiet postgresql; then
    echo "Le service postgresql ne tourne pas." >&2
    exit 1
fi

echo "=================================================================="
echo "          REINITIALISATION COMPLETE DU PROJET NOVABANK"
echo "=================================================================="
echo "La base '$DB_NAME' et les roles du projet vont etre supprimes."
read -r -p "Continuer ? (y/N) " reply
if [[ ! $reply =~ ^[Yy]$ ]]; then
    echo "Operation annulee."
    exit 1
fi

step "Mots de passe des comptes (rien n'est ecrit sur le disque)"
declare -A PASSWORDS
for role in bank_owner app_user alice_analyst bob_support charlie_auditor; do
    env_var="NOVABANK_${role^^}_PASSWORD"
    password="${!env_var:-}"
    while [[ -z $password ]]; do
        read -r -s -p "  Mot de passe de $role : " password
        echo
        if [[ -n $password ]]; then
            read -r -s -p "  Confirmation : " confirmation
            echo
            if [[ $password != "$confirmation" ]]; then
                echo "  Les mots de passe ne correspondent pas."
                password=""
            fi
        fi
    done
    PASSWORDS[$role]=$password
done

step "Suppression de la base $DB_NAME et des roles"
as_postgres -d postgres <<SQL
DROP DATABASE IF EXISTS $DB_NAME WITH (FORCE);
DROP ROLE IF EXISTS $PROJECT_ROLES;
SQL

step "00_database.sql (postgres)"
{
    for role in "${!PASSWORD_VARS[@]}"; do
        printf '\\set %s %s\n' "${PASSWORD_VARS[$role]}" "$(psql_quote "${PASSWORDS[$role]}")"
    done
    cat "$SQL_DIR/00_database.sql"
} | as_postgres -d postgres -f -

for file in "$SQL_DIR"/[0-9][0-9]_*.sql; do
    name="$(basename "$file")"
    [[ $name == 00_* ]] && continue
    step "$name ($OWNER)"
    {
        echo "SET ROLE $OWNER;"
        cat "$file"
    } | as_postgres -d "$DB_NAME" -1 -f -
done

step "Verification"
as_postgres -d "$DB_NAME" <<SQL
SELECT (SELECT count(*) FROM core.customers)    AS customers,
       (SELECT count(*) FROM core.accounts)     AS accounts,
       (SELECT count(*) FROM core.transfers)    AS transfers,
       (SELECT count(*) FROM core.transactions) AS transactions;
SQL

echo
echo "=================================================================="
echo "          DEPLOIEMENT TERMINE AVEC SUCCES POUR NOVABANK"
echo "=================================================================="
