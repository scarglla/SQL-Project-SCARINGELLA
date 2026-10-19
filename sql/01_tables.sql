CREATE SCHEMA core;
CREATE SCHEMA audit;

REVOKE ALL ON SCHEMA core FROM PUBLIC;
REVOKE ALL ON SCHEMA audit FROM PUBLIC;

ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON ROUTINES FROM PUBLIC;

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;

CREATE TYPE core.kyc_status AS ENUM ('PENDING', 'VERIFIED', 'REJECTED');
CREATE TYPE core.risk_level AS ENUM ('LOW', 'MEDIUM', 'HIGH');
CREATE TYPE core.account_type AS ENUM ('CHECKING', 'SAVINGS');
CREATE TYPE core.account_status AS ENUM ('ACTIVE', 'FROZEN', 'CLOSED');
CREATE TYPE core.tx_type AS ENUM ('DEPOSIT', 'WITHDRAWAL', 'TRANSFER_IN', 'TRANSFER_OUT');
CREATE TYPE core.alert_status AS ENUM ('OPEN', 'REVIEWED', 'CLOSED');

CREATE TABLE core.customers (
    customer_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    first_name  varchar(50)  NOT NULL,
    last_name   varchar(50)  NOT NULL,
    email       varchar(254) NOT NULL,
    phone       bytea,
    birth_date  date         NOT NULL,
    kyc_status  core.kyc_status NOT NULL DEFAULT 'PENDING',
    risk_level  core.risk_level NOT NULL DEFAULT 'LOW',
    created_at  timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT uq_customers_email UNIQUE (email),
    CONSTRAINT ck_customers_email_format CHECK (email ~ '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$'),
    CONSTRAINT ck_customers_first_name CHECK (btrim(first_name) <> ''),
    CONSTRAINT ck_customers_last_name CHECK (btrim(last_name) <> ''),
    CONSTRAINT ck_customers_adult CHECK (birth_date <= CURRENT_DATE - INTERVAL '18 years'),
    CONSTRAINT ck_customers_birth_date CHECK (birth_date > DATE '1900-01-01')
);

CREATE TABLE core.accounts (
    account_id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id  bigint NOT NULL REFERENCES core.customers (customer_id),
    iban         varchar(34) NOT NULL,
    account_type core.account_type NOT NULL,
    balance      numeric(14,2) NOT NULL DEFAULT 0,
    status       core.account_status NOT NULL DEFAULT 'ACTIVE',
    opened_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_accounts_iban UNIQUE (iban),
    CONSTRAINT ck_accounts_iban_format CHECK (iban ~ '^[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}$'),
    CONSTRAINT ck_accounts_balance_positive CHECK (balance >= 0)
);

CREATE TABLE core.transfers (
    transfer_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    from_account_id bigint NOT NULL REFERENCES core.accounts (account_id),
    to_account_id   bigint NOT NULL REFERENCES core.accounts (account_id),
    amount          numeric(14,2) NOT NULL,
    label           varchar(140),
    created_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_transfers_amount_positive CHECK (amount > 0),
    CONSTRAINT ck_transfers_different_accounts CHECK (from_account_id <> to_account_id)
);

CREATE TABLE core.transactions (
    tx_id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_id    bigint NOT NULL REFERENCES core.accounts (account_id),
    tx_type       core.tx_type NOT NULL,
    amount        numeric(14,2) NOT NULL,
    balance_after numeric(14,2) NOT NULL,
    transfer_id   bigint REFERENCES core.transfers (transfer_id),
    created_at    timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_transactions_amount_positive CHECK (amount > 0),
    CONSTRAINT ck_transactions_balance_after_positive CHECK (balance_after >= 0),
    CONSTRAINT ck_transactions_transfer_link CHECK (
        (tx_type IN ('TRANSFER_IN', 'TRANSFER_OUT')) = (transfer_id IS NOT NULL)
    )
);

CREATE TABLE core.fraud_alerts (
    alert_id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    account_id bigint NOT NULL REFERENCES core.accounts (account_id),
    tx_id      bigint NOT NULL REFERENCES core.transactions (tx_id),
    rule_code  varchar(30) NOT NULL,
    status     core.alert_status NOT NULL DEFAULT 'OPEN',
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_fraud_alerts_rule_code CHECK (rule_code IN ('LARGE_WITHDRAWAL', 'TRANSFER_BURST'))
);

CREATE TABLE audit.audit_log (
    log_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    table_name text NOT NULL,
    operation  text NOT NULL,
    old_data   jsonb,
    new_data   jsonb,
    db_user    text NOT NULL DEFAULT session_user,
    changed_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT ck_audit_log_operation CHECK (operation IN ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE'))
);
