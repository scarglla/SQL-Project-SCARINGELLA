CREATE VIEW core.v_customer_support WITH (security_barrier = true) AS
SELECT c.customer_id,
       c.first_name,
       left(c.last_name, 1) || '.' AS last_name,
       left(c.email, 1) || '***' || substr(c.email, strpos(c.email, '@')) AS email,
       CASE WHEN c.phone IS NULL THEN NULL ELSE '** ** ** ** **' END AS phone,
       c.kyc_status,
       c.created_at
FROM core.customers AS c;

CREATE VIEW core.v_customer_analytics WITH (security_barrier = true) AS
SELECT c.customer_id,
       md5(c.email) AS customer_hash,
       date_part('year', age(c.birth_date))::int AS age,
       c.kyc_status,
       c.risk_level,
       c.created_at
FROM core.customers AS c;

CREATE VIEW core.v_active_accounts AS
SELECT account_id, customer_id, iban, account_type, status, opened_at
FROM core.accounts
WHERE status = 'ACTIVE'
WITH LOCAL CHECK OPTION;

CREATE MATERIALIZED VIEW core.mv_account_stats AS
SELECT a.account_id,
       a.customer_id,
       a.account_type,
       a.status,
       a.balance,
       count(t.tx_id) AS tx_count,
       coalesce(sum(t.amount) FILTER (WHERE t.tx_type IN ('DEPOSIT', 'TRANSFER_IN')), 0) AS total_in,
       coalesce(sum(t.amount) FILTER (WHERE t.tx_type IN ('WITHDRAWAL', 'TRANSFER_OUT')), 0) AS total_out,
       max(t.created_at) AS last_tx_at
FROM core.accounts AS a
LEFT JOIN core.transactions AS t ON t.account_id = a.account_id
GROUP BY a.account_id
WITH DATA;

CREATE UNIQUE INDEX ux_mv_account_stats_account_id ON core.mv_account_stats (account_id);
