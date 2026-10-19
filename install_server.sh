#!/usr/bin/env bash
set -euo pipefail

PG_VERSION="${PG_VERSION:-18}"
ADMIN_NETWORK="${ADMIN_NETWORK:-192.168.56.0/24}"
DB_NAME="bankdb"
CLUSTER_DIR="/etc/postgresql/$PG_VERSION/main"
CONF_FILE="$CLUSTER_DIR/conf.d/novabank.conf"
HBA_FILE="$CLUSTER_DIR/pg_hba.conf"
SSL_DIR="$CLUSTER_DIR/ssl"

step() {
    echo
    echo "==> $*"
}

if [[ $EUID -ne 0 ]]; then
    echo "Ce script doit etre lance en root : sudo $0" >&2
    exit 1
fi

if [[ ! $ADMIN_NETWORK =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]]; then
    echo "ADMIN_NETWORK invalide : $ADMIN_NETWORK (exemple : 192.168.56.0/24)" >&2
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

step "Mise a jour de la liste des paquets"
apt-get update -q

if ! apt-cache policy "postgresql-$PG_VERSION" | grep -q 'Candidate: [0-9]'; then
    step "Ajout du depot officiel PostgreSQL (apt.postgresql.org)"
    apt-get install -y -q postgresql-common ca-certificates
    /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y
    apt-get update -q
fi

step "Installation de postgresql-$PG_VERSION, postgresql-client, ufw et openssl"
apt-get install -y -q "postgresql-$PG_VERSION" "postgresql-client-$PG_VERSION" ufw openssl

if [[ ! -d $CLUSTER_DIR ]]; then
    echo "Cluster $PG_VERSION/main introuvable dans /etc/postgresql." >&2
    exit 1
fi

step "Adresse d'ecoute sur le reseau d'administration $ADMIN_NETWORK"
first_host="$(echo "${ADMIN_NETWORK%/*}" | awk -F. '{ printf "%d.%d.%d.%d", $1, $2, $3, $4 + 1 }')"
vm_ip="$(ip -4 route get "$first_host" 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1) }' | head -n 1)"
if [[ -n $vm_ip ]]; then
    listen_addresses="localhost,$vm_ip"
else
    echo "Aucune adresse de la VM sur $ADMIN_NETWORK : ecoute locale uniquement." >&2
    listen_addresses="localhost"
fi
echo "listen_addresses = '$listen_addresses'"

step "Certificat TLS ($SSL_DIR)"
install -d -o postgres -g postgres -m 700 "$SSL_DIR"
if [[ ! -f $SSL_DIR/server.crt || ! -f $SSL_DIR/server.key ]]; then
    openssl req -new -x509 -nodes -days 365 -newkey rsa:2048 \
        -subj "/CN=$(hostname)" \
        -keyout "$SSL_DIR/server.key" -out "$SSL_DIR/server.crt" 2>/dev/null
    chown postgres:postgres "$SSL_DIR/server.key" "$SSL_DIR/server.crt"
    chmod 600 "$SSL_DIR/server.key"
    chmod 644 "$SSL_DIR/server.crt"
    echo "Certificat auto-signe cree."
else
    echo "Certificat deja present."
fi

step "Reglages dans $CONF_FILE"
install -d -o postgres -g postgres -m 755 "$CLUSTER_DIR/conf.d"
cat > "$CONF_FILE" <<EOF
listen_addresses = '$listen_addresses'
port = 5432
password_encryption = 'scram-sha-256'
ssl = on
ssl_cert_file = '$SSL_DIR/server.crt'
ssl_key_file = '$SSL_DIR/server.key'
ssl_min_protocol_version = 'TLSv1.2'
log_connections = on
log_disconnections = on
log_statement = 'ddl'
log_line_prefix = '%m [%p] %q%u@%d from %h '
EOF
chown postgres:postgres "$CONF_FILE"
chmod 644 "$CONF_FILE"

step "Regles de connexion dans $HBA_FILE"
if [[ ! -f $HBA_FILE.orig ]]; then
    cp -p "$HBA_FILE" "$HBA_FILE.orig"
fi
cat > "$HBA_FILE" <<EOF
local      all        postgres                              peer
local      $DB_NAME     bank_owner                            scram-sha-256
local      $DB_NAME     app_user                              scram-sha-256
hostssl    $DB_NAME     bank_owner      127.0.0.1/32          scram-sha-256
hostssl    $DB_NAME     bank_owner      ::1/128               scram-sha-256
hostssl    $DB_NAME     app_user        127.0.0.1/32          scram-sha-256
hostssl    $DB_NAME     app_user        ::1/128               scram-sha-256
hostssl    $DB_NAME     +analysts       $ADMIN_NETWORK      scram-sha-256
hostssl    $DB_NAME     +support        $ADMIN_NETWORK      scram-sha-256
hostssl    $DB_NAME     +auditors       $ADMIN_NETWORK      scram-sha-256
hostnossl  all        all             0.0.0.0/0             reject
hostnossl  all        all             ::/0                  reject
host       all        all             0.0.0.0/0             reject
host       all        all             ::/0                  reject
local      all        all                                   reject
EOF
chown postgres:postgres "$HBA_FILE"
chmod 640 "$HBA_FILE"

step "Redemarrage de PostgreSQL (listen_addresses demande un restart)"
systemctl enable --now postgresql >/dev/null
systemctl restart "postgresql@$PG_VERSION-main"

for _ in {1..20}; do
    if sudo -u postgres pg_isready -q; then
        break
    fi
    sleep 1
done
sudo -u postgres pg_isready

step "Pare-feu ufw"
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow OpenSSH >/dev/null
ufw allow from "$ADMIN_NETWORK" to any port 5432 proto tcp >/dev/null
ufw --force enable >/dev/null

step "Verifications"
pg_lsclusters
systemctl is-active "postgresql@$PG_VERSION-main"
sudo -u postgres psql -X -q -c "SHOW listen_addresses;" -c "SHOW ssl;" -c "SHOW log_connections;"
errors="$(sudo -u postgres psql -X -At -c "SELECT count(*) FROM pg_hba_file_rules WHERE error IS NOT NULL;")"
if [[ $errors -ne 0 ]]; then
    sudo -u postgres psql -X -c "SELECT line_number, error FROM pg_hba_file_rules WHERE error IS NOT NULL;"
    echo "pg_hba.conf contient $errors erreur(s)." >&2
    exit 1
fi
echo "pg_hba.conf : aucune erreur."
ufw status verbose

echo
echo "=================================================================="
echo "     SERVEUR POSTGRESQL $PG_VERSION PRET - lancer ensuite : sudo ./setup_project.sh"
echo "=================================================================="
