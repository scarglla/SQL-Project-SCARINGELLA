CREATE FUNCTION core.fn_phone_encrypt(p_phone text)
RETURNS bytea
LANGUAGE sql
VOLATILE
SET search_path = pg_catalog, public, pg_temp
AS $$
    SELECT pgp_sym_encrypt(p_phone, current_setting('novabank.phone_key'));
$$;

CREATE FUNCTION core.fn_phone_decrypt(p_phone bytea)
RETURNS text
LANGUAGE sql
STABLE
SET search_path = pg_catalog, public, pg_temp
AS $$
    SELECT pgp_sym_decrypt(p_phone, current_setting('novabank.phone_key'));
$$;

CREATE PROCEDURE core.set_customer_phone(p_customer_id bigint, p_phone text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF p_phone !~ '^\+?[0-9 ]{10,20}$' THEN
        RAISE EXCEPTION 'Numero de telephone invalide';
    END IF;

    UPDATE core.customers
    SET phone = core.fn_phone_encrypt(replace(p_phone, ' ', ''))
    WHERE customer_id = p_customer_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Client % introuvable', p_customer_id;
    END IF;
END;
$$;


CREATE FUNCTION core.search_client_unsafe(p_first_name text)
RETURNS TABLE (customer_id bigint, first_name text, last_name text)
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    RETURN QUERY EXECUTE
        'SELECT customer_id, first_name::text, last_name::text FROM core.customers WHERE first_name = '''
        || p_first_name || '''';
END;
$$;

CREATE FUNCTION core.search_client_safe(p_first_name text)
RETURNS TABLE (customer_id bigint, first_name text, last_name text)
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    RETURN QUERY EXECUTE
        'SELECT customer_id, first_name::text, last_name::text FROM core.customers WHERE first_name = $1'
        USING p_first_name;
END;
$$;


CREATE VIEW core.v_d1_richest_by_age AS
WITH wealth AS (
    SELECT c.customer_id,
           (date_part('year', age(c.birth_date))::int / 10) * 10 AS age_group,
           sum(a.balance) AS total_balance
    FROM core.customers AS c
    JOIN core.accounts AS a ON a.customer_id = c.customer_id
    GROUP BY c.customer_id
)
SELECT age_group, customer_id, total_balance, rnk
FROM (
    SELECT w.*, rank() OVER (PARTITION BY age_group ORDER BY total_balance DESC) AS rnk
    FROM wealth AS w
) AS ranked
WHERE rnk <= 3;

CREATE VIEW core.v_d1_monthly_deposits AS
WITH monthly AS (
    SELECT date_trunc('month', created_at) AS month, sum(amount) AS total_deposits
    FROM core.transactions
    WHERE tx_type = 'DEPOSIT'
    GROUP BY 1
)
SELECT month,
       total_deposits,
       lag(total_deposits) OVER (ORDER BY month) AS previous_month,
       round(100 * (total_deposits - lag(total_deposits) OVER (ORDER BY month))
             / NULLIF(lag(total_deposits) OVER (ORDER BY month), 0), 2) AS variation_pct
FROM monthly
ORDER BY month;

CREATE VIEW core.v_d1_balance_deciles AS
SELECT decile, count(*) AS accounts, min(balance) AS min_balance, max(balance) AS max_balance, round(avg(balance), 2) AS avg_balance
FROM (
    SELECT balance, ntile(10) OVER (ORDER BY balance) AS decile
    FROM core.accounts
) AS d
GROUP BY decile
ORDER BY decile;

CREATE VIEW core.v_d1_median_balance_by_risk AS
SELECT c.risk_level,
       count(*) AS accounts,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY a.balance) AS median_balance,
       round(avg(a.balance), 2) AS avg_balance
FROM core.accounts AS a
JOIN core.customers AS c ON c.customer_id = a.customer_id
GROUP BY c.risk_level;

CREATE VIEW core.v_d1_most_active_accounts AS
SELECT account_type, account_id, tx_count, rnk
FROM (
    SELECT account_type, account_id, tx_count,
           dense_rank() OVER (PARTITION BY account_type ORDER BY tx_count DESC) AS rnk
    FROM core.mv_account_stats
) AS r
WHERE rnk <= 5;


CREATE TABLE core.withdrawal_anomalies AS
SELECT tx_id, account_id, amount, created_at, round(z_score, 2) AS z_score
FROM (
    SELECT tx_id, account_id, amount, created_at,
           (amount - avg(amount) OVER ()) / NULLIF(stddev_samp(amount) OVER (), 0) AS z_score
    FROM core.transactions
    WHERE tx_type = 'WITHDRAWAL'
) AS z
WHERE z_score > 3;

ALTER TABLE core.withdrawal_anomalies ADD CONSTRAINT pk_withdrawal_anomalies PRIMARY KEY (tx_id);

\echo 'Retraits anormaux (score z > 3) :'
SELECT count(*) AS anomalies, min(amount) AS min_amount, max(z_score) AS max_z_score
FROM core.withdrawal_anomalies;


GRANT EXECUTE ON PROCEDURE core.set_customer_phone(bigint, text) TO application;

GRANT SELECT ON core.v_d1_richest_by_age TO analysts;
GRANT SELECT ON core.v_d1_monthly_deposits TO analysts;
GRANT SELECT ON core.v_d1_balance_deciles TO analysts;
GRANT SELECT ON core.v_d1_median_balance_by_risk TO analysts;
GRANT SELECT ON core.v_d1_most_active_accounts TO analysts;
GRANT SELECT ON core.withdrawal_anomalies TO analysts, auditors;
