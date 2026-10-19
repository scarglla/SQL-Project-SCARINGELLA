ALTER TABLE core.transactions DISABLE TRIGGER USER;
ALTER TABLE core.transfers DISABLE TRIGGER USER;
ALTER TABLE core.accounts DISABLE TRIGGER USER;
ALTER TABLE core.customers DISABLE TRIGGER USER;

TRUNCATE core.fraud_alerts, core.transactions, core.transfers, core.accounts, core.customers RESTART IDENTITY;

SELECT setseed(0.42);

INSERT INTO core.customers (first_name, last_name, email, birth_date, kyc_status, risk_level, created_at)
SELECT
    (ARRAY['Emma','Louis','Jade','Gabriel','Louise','Raphael','Alice','Arthur','Lina','Jules'])[1 + g % 10],
    (ARRAY['Martin','Bernard','Dubois','Thomas','Robert','Richard','Petit','Durand','Leroy','Moreau'])[1 + (g / 10) % 10],
    'client' || g || '@novabank.test',
    DATE '1945-01-01' + (random() * 20000)::int,
    (ARRAY['VERIFIED','VERIFIED','VERIFIED','PENDING','REJECTED']::core.kyc_status[])[1 + g % 5],
    (ARRAY['LOW','LOW','LOW','MEDIUM','HIGH']::core.risk_level[])[1 + (g / 5) % 5],
    TIMESTAMPTZ '2023-01-01' + random() * INTERVAL '365 days'
FROM generate_series(1, 20000) AS g;

INSERT INTO core.accounts (customer_id, iban, account_type, opened_at)
SELECT
    1 + (g - 1) % 20000,
    'FR76' || lpad(g::text, 23, '0'),
    (ARRAY['CHECKING','SAVINGS']::core.account_type[])[1 + (g / 20000) % 2],
    TIMESTAMPTZ '2024-01-01' + random() * INTERVAL '30 days'
FROM generate_series(1, 30000) AS g;

INSERT INTO core.transfers (from_account_id, to_account_id, amount, label, created_at)
SELECT
    1 + g % 30000,
    1 + (g % 30000 + 1 + g % 29999) % 30000,
    round((1 + random() * 99)::numeric, 2),
    'Virement ' || g,
    TIMESTAMPTZ '2024-02-01' + random() * INTERVAL '973 days'
FROM generate_series(1, 150000) AS g;

CREATE TEMP TABLE tmp_entries AS
SELECT account_id, tx_type, amount, transfer_id, created_at
FROM (
    SELECT a.account_id,
           'DEPOSIT'::core.tx_type AS tx_type,
           round((5000 + random() * 5000)::numeric, 2) AS amount,
           NULL::bigint AS transfer_id,
           a.opened_at AS created_at
    FROM core.accounts AS a

    UNION ALL

    SELECT 1 + s.g % 30000,
           s.tx_type,
           CASE
               WHEN s.tx_type = 'WITHDRAWAL' AND s.g % 997 = 0 THEN round((1000 + random() * 1000)::numeric, 2)
               WHEN s.tx_type = 'WITHDRAWAL' THEN round((1 + random() * 99)::numeric, 2)
               ELSE round((10 + random() * 190)::numeric, 2)
           END,
           NULL,
           TIMESTAMPTZ '2024-02-01' + random() * INTERVAL '973 days'
    FROM (
        SELECT g, CASE WHEN random() < 0.4 THEN 'WITHDRAWAL' ELSE 'DEPOSIT' END::core.tx_type AS tx_type
        FROM generate_series(1, 670000) AS g
    ) AS s

    UNION ALL

    SELECT from_account_id, 'TRANSFER_OUT', amount, transfer_id, created_at FROM core.transfers

    UNION ALL

    SELECT to_account_id, 'TRANSFER_IN', amount, transfer_id, created_at FROM core.transfers
) AS e;

ALTER TABLE tmp_entries ADD COLUMN seq bigint GENERATED ALWAYS AS IDENTITY;

INSERT INTO core.transactions (account_id, tx_type, amount, balance_after, transfer_id, created_at)
SELECT account_id, tx_type, amount,
       sum(CASE WHEN tx_type IN ('DEPOSIT', 'TRANSFER_IN') THEN amount ELSE -amount END)
           OVER (PARTITION BY account_id ORDER BY created_at, seq),
       transfer_id, created_at
FROM tmp_entries
ORDER BY created_at, seq;

UPDATE core.accounts AS a
SET balance = l.balance_after
FROM (
    SELECT DISTINCT ON (account_id) account_id, balance_after
    FROM core.transactions
    ORDER BY account_id, tx_id DESC
) AS l
WHERE a.account_id = l.account_id;

UPDATE core.accounts SET status = 'FROZEN' WHERE account_id % 50 = 0;

DROP TABLE tmp_entries;

ALTER TABLE core.transactions ENABLE TRIGGER USER;
ALTER TABLE core.transfers ENABLE TRIGGER USER;
ALTER TABLE core.accounts ENABLE TRIGGER USER;
ALTER TABLE core.customers ENABLE TRIGGER USER;

ANALYZE core.customers;
ANALYZE core.accounts;
ANALYZE core.transfers;
ANALYZE core.transactions;

\echo 'Volumes :'
SELECT (SELECT count(*) FROM core.customers)    AS customers,
       (SELECT count(*) FROM core.accounts)     AS accounts,
       (SELECT count(*) FROM core.transfers)    AS transfers,
       (SELECT count(*) FROM core.transactions) AS transactions;

\echo 'Controle de coherence (0 ligne attendue) :'
SELECT 'solde' AS anomaly, a.account_id
FROM core.accounts AS a
JOIN (
    SELECT DISTINCT ON (account_id) account_id, balance_after
    FROM core.transactions
    ORDER BY account_id, tx_id DESC
) AS l ON l.account_id = a.account_id
WHERE a.balance <> l.balance_after
UNION ALL
SELECT 'virement', t.transfer_id
FROM core.transfers AS t
LEFT JOIN core.transactions AS x ON x.transfer_id = t.transfer_id
GROUP BY t.transfer_id
HAVING count(x.tx_id) <> 2;
