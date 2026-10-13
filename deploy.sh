#!/bin/bash

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
    exit 1
fi

DB_NAME="bankdb"
HBA_FILE="/etc/postgresql/18/main/pg_hba.conf"
CONF_FILE="/etc/postgresql/18/main/postgresql.conf"

hostnamectl set-hostname novabank-server || true

export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y postgresql postgresql-client ufw

ufw allow OpenSSH
ufw allow from 192.168.122.0/24 to any port 5432 proto tcp
ufw --force enable

cat > "$HBA_FILE" << 'EOF'
local   all             postgres                                peer
local   all             all                                     scram-sha-256
hostnossl   bankdb      all             0.0.0.0/0               reject
hostnossl   bankdb      all             ::/0                    reject
hostssl     bankdb      bank_owner      127.0.0.1/32            scram-sha-256
hostssl     bankdb      bank_owner      ::1/128                 scram-sha-256
hostssl     bankdb      +analysts       192.168.122.0/24        scram-sha-256
hostssl     bankdb      +analysts       127.0.0.1/32            scram-sha-256
hostssl     bankdb      +support        192.168.122.0/24        scram-sha-256
hostssl     bankdb      +auditors       192.168.122.0/24        scram-sha-256
EOF

sed -i "s/#log_connections = 'off'/log_connections = 'on'/" "$CONF_FILE" || true
sed -i "s/#log_connections = ''/log_connections = 'on'/" "$CONF_FILE" || true

systemctl reload postgresql

sudo -u postgres psql << 'EOF'
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'bankdb';
DROP DATABASE IF EXISTS bankdb;
DROP ROLE IF EXISTS bank_owner, app_user, alice_analyst, bob_support, charlie_auditor, analysts, support, auditors;
EOF

sudo -u postgres psql << 'EOF'
CREATE ROLE bank_owner LOGIN PASSWORD 'SecurePass2026!';
CREATE DATABASE bankdb OWNER bank_owner;
EOF

sudo -u postgres psql -d "$DB_NAME" << 'EOF'
CREATE SCHEMA IF NOT EXISTS core;
CREATE SCHEMA IF NOT EXISTS audit;

CREATE TABLE IF NOT EXISTS core.customers (
    customer_id BIGSERIAL PRIMARY KEY,
    first_name VARCHAR(50) NOT NULL,
    last_name VARCHAR(50) NOT NULL,
    email VARCHAR(100) UNIQUE NOT NULL,
    phone BYTEA,
    birth_date DATE CHECK (birth_date <= CURRENT_DATE - INTERVAL '18 years'),
    kyc_status VARCHAR(20) DEFAULT 'PENDING',
    risk_level INT DEFAULT 1,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS core.accounts (
    account_id BIGSERIAL PRIMARY KEY,
    customer_id BIGINT REFERENCES core.customers(customer_id),
    iban VARCHAR(34) UNIQUE NOT NULL,
    account_type VARCHAR(20) NOT NULL,
    balance NUMERIC(15, 2) NOT NULL DEFAULT 0.00 CHECK (balance >= 0.00),
    status VARCHAR(20) DEFAULT 'ACTIVE',
    opened_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS core.transfers (
    transfer_id BIGSERIAL PRIMARY KEY,
    from_account_id BIGINT REFERENCES core.accounts(account_id),
    to_account_id BIGINT REFERENCES core.accounts(account_id),
    amount NUMERIC(15, 2) NOT NULL CHECK (amount > 0),
    label TEXT,
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT ck_different_accounts CHECK (from_account_id <> to_account_id)
);

CREATE TABLE IF NOT EXISTS core.transactions (
    tx_id BIGSERIAL PRIMARY KEY,
    account_id BIGINT REFERENCES core.accounts(account_id),
    tx_type VARCHAR(20) NOT NULL,
    amount NUMERIC(15, 2) NOT NULL,
    balance_after NUMERIC(15, 2) NOT NULL,
    transfer_id BIGINT REFERENCES core.transfers(transfer_id),
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS core.fraud_alerts (
    alert_id BIGSERIAL PRIMARY KEY,
    account_id BIGINT REFERENCES core.accounts(account_id),
    tx_id BIGINT REFERENCES core.transactions(tx_id),
    rule_code VARCHAR(50) NOT NULL,
    status VARCHAR(20) DEFAULT 'NEW',
    created_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS audit.audit_log (
    log_id BIGSERIAL PRIMARY KEY,
    table_name VARCHAR(50) NOT NULL,
    operation VARCHAR(20) NOT NULL,
    old_data JSONB,
    new_data JSONB,
    db_user VARCHAR(50) NOT NULL,
    changed_at TIMESTAMPTZ DEFAULT CURRENT_TIMESTAMP
);

CREATE ROLE analysts NOLOGIN;
CREATE ROLE support NOLOGIN;
CREATE ROLE auditors NOLOGIN;
CREATE ROLE app_user LOGIN PASSWORD 'AppPass2026!';

CREATE ROLE alice_analyst LOGIN IN ROLE analysts PASSWORD 'Pass2026!';
CREATE ROLE bob_support LOGIN IN ROLE support PASSWORD 'Pass2026!';
CREATE ROLE charlie_auditor LOGIN IN ROLE auditors PASSWORD 'Pass2026!';

GRANT CONNECT ON DATABASE bankdb TO analysts, support, auditors, app_user;
GRANT USAGE ON SCHEMA core TO analysts, support, auditors, app_user;
GRANT SELECT ON ALL TABLES IN SCHEMA core TO analysts, support, auditors;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA core TO app_user;
GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA core TO app_user;

CREATE OR REPLACE VIEW core.v_customer_support AS
SELECT customer_id, first_name, last_name, CONCAT('***@', split_part(email, '@', 2)) AS masked_email, kyc_status
FROM core.customers;

CREATE MATERIALIZED VIEW IF NOT EXISTS core.mv_account_stats AS
SELECT account_id, balance, status FROM core.accounts;

CREATE UNIQUE INDEX idx_mv_account_stats ON core.mv_account_stats(account_id);
REFRESH MATERIALIZED VIEW core.mv_account_stats;

CREATE INDEX IF NOT EXISTS idx_customers_email ON core.customers(email);
CREATE INDEX IF NOT EXISTS idx_accounts_customer ON core.accounts(customer_id);
CREATE INDEX IF NOT EXISTS idx_transactions_account ON core.transactions(account_id);
CREATE INDEX IF NOT EXISTS idx_accounts_frozen ON core.accounts(status) WHERE status = 'FROZEN';
ANALYZE core.customers;
ANALYZE core.accounts;
ANALYZE core.transactions;

CREATE OR REPLACE FUNCTION core.fn_prevent_tx_modification()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'Modification ou suppression interdite.';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_prevent_tx_mod
BEFORE UPDATE OR DELETE ON core.transactions
FOR EACH ROW EXECUTE FUNCTION core.fn_prevent_tx_modification();

CREATE OR REPLACE PROCEDURE core.safe_transfer(p_sender BIGINT, p_receiver BIGINT, p_amount NUMERIC)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    v_sender_balance NUMERIC;
    v_first BIGINT;
    v_second BIGINT;
BEGIN
    IF p_amount <= 0 THEN
        RAISE EXCEPTION 'Montant invalide.';
    END IF;

    IF p_sender < p_receiver THEN
        v_first := p_sender;
        v_second := p_receiver;
    ELSE
        v_first := p_receiver;
        v_second := p_sender;
    END IF;

    SELECT balance INTO v_sender_balance FROM core.accounts WHERE account_id = v_first FOR UPDATE;
    SELECT balance INTO v_sender_balance FROM core.accounts WHERE account_id = v_second FOR UPDATE;

    SELECT balance INTO v_sender_balance FROM core.accounts WHERE account_id = p_sender FOR UPDATE;
    IF v_sender_balance < p_amount THEN
        RAISE EXCEPTION 'Solde insuffisant.';
    END IF;

    UPDATE core.accounts SET balance = balance - p_amount WHERE account_id = p_sender;
    UPDATE core.accounts SET balance = balance + p_amount WHERE account_id = p_receiver;

    INSERT INTO core.transfers (from_account_id, to_account_id, amount, label)
    VALUES (p_sender, p_receiver, p_amount, 'Virement sécurisé');
END;
$$;

CREATE EXTENSION IF NOT EXISTS pgcrypto;
ALTER TABLE core.customers ALTER COLUMN phone TYPE BYTEA USING phone::bytea;

CREATE OR REPLACE FUNCTION core.search_client_vulnerable(p_name VARCHAR)
RETURNS TABLE (customer_id BIGINT, first_name VARCHAR, last_name VARCHAR) AS $$
BEGIN
    RETURN QUERY EXECUTE 'SELECT customer_id, first_name, last_name FROM core.customers WHERE first_name = ''' || p_name || '''';
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION core.search_client_safe(p_name VARCHAR)
RETURNS TABLE (customer_id BIGINT, first_name VARCHAR, last_name VARCHAR) AS $$
BEGIN
    RETURN QUERY EXECUTE format('SELECT customer_id, first_name, last_name FROM core.customers WHERE first_name = %L', p_name);
END;
$$ LANGUAGE plpgsql;
EOF

BACKUP_DIR="/var/backups/novabank"
mkdir -p "$BACKUP_DIR"
chown postgres:postgres "$BACKUP_DIR"
sudo -u postgres pg_dump -d "$DB_NAME" -F c -b -v -f "$BACKUP_DIR/bankdb_$(date +%Y%m%d_%H%M%S).dump"
