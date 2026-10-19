\echo '=== Releve d un compte : AVANT index'
EXPLAIN (ANALYZE, BUFFERS)
SELECT tx_id, created_at, tx_type, amount, balance_after
FROM core.transactions
WHERE account_id = 4242
ORDER BY created_at DESC, tx_id DESC
LIMIT 20;

CREATE INDEX idx_transactions_account_created ON core.transactions (account_id, created_at, tx_id);

\echo '=== Recherche de client insensible a la casse : AVANT index'
EXPLAIN (ANALYZE, BUFFERS)
SELECT customer_id, first_name, last_name
FROM core.customers
WHERE lower(last_name) = 'moreau';

CREATE INDEX idx_customers_last_name_lower ON core.customers (lower(last_name));

\echo '=== Comptes geles : AVANT index'
EXPLAIN (ANALYZE, BUFFERS)
SELECT account_id, iban, balance
FROM core.accounts
WHERE status = 'FROZEN';

CREATE INDEX idx_accounts_frozen ON core.accounts (account_id) WHERE status = 'FROZEN';

\echo '=== Somme des depots sur un mois : AVANT index'
EXPLAIN (ANALYZE, BUFFERS)
SELECT sum(amount)
FROM core.transactions
WHERE tx_type = 'DEPOSIT'
  AND created_at >= TIMESTAMPTZ '2025-03-01'
  AND created_at <  TIMESTAMPTZ '2025-04-01';

CREATE INDEX idx_transactions_created_brin ON core.transactions USING brin (created_at);

CREATE INDEX idx_accounts_customer_id ON core.accounts (customer_id);
CREATE INDEX idx_transfers_from_created ON core.transfers (from_account_id, created_at);
CREATE INDEX idx_transfers_to_account_id ON core.transfers (to_account_id);
CREATE INDEX idx_transactions_transfer_id ON core.transactions (transfer_id) WHERE transfer_id IS NOT NULL;
CREATE INDEX idx_fraud_alerts_account_created ON core.fraud_alerts (account_id, created_at);
CREATE INDEX idx_fraud_alerts_tx_id ON core.fraud_alerts (tx_id);

ANALYZE core.customers;
ANALYZE core.accounts;
ANALYZE core.transfers;
ANALYZE core.transactions;

\echo '=== Releve d un compte : APRES index'
EXPLAIN (ANALYZE, BUFFERS)
SELECT tx_id, created_at, tx_type, amount, balance_after
FROM core.transactions
WHERE account_id = 4242
ORDER BY created_at DESC, tx_id DESC
LIMIT 20;

\echo '=== Recherche de client insensible a la casse : APRES index'
EXPLAIN (ANALYZE, BUFFERS)
SELECT customer_id, first_name, last_name
FROM core.customers
WHERE lower(last_name) = 'moreau';

\echo '=== Comptes geles : APRES index'
EXPLAIN (ANALYZE, BUFFERS)
SELECT account_id, iban, balance
FROM core.accounts
WHERE status = 'FROZEN';

\echo '=== Somme des depots sur un mois : APRES index'
EXPLAIN (ANALYZE, BUFFERS)
SELECT sum(amount)
FROM core.transactions
WHERE tx_type = 'DEPOSIT'
  AND created_at >= TIMESTAMPTZ '2025-03-01'
  AND created_at <  TIMESTAMPTZ '2025-04-01';

\echo '=== Taille des index'
SELECT indexrelname AS index_name, pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes
WHERE schemaname = 'core'
ORDER BY pg_relation_size(indexrelid) DESC;
