REVOKE ALL ON ALL TABLES IN SCHEMA core FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA audit FROM PUBLIC;
REVOKE ALL ON ALL ROUTINES IN SCHEMA core FROM PUBLIC;
REVOKE ALL ON ALL ROUTINES IN SCHEMA audit FROM PUBLIC;

GRANT CONNECT ON DATABASE bankdb TO analysts, support, application, auditors;

GRANT USAGE ON SCHEMA core TO analysts, support, application, auditors;
GRANT USAGE ON SCHEMA audit TO auditors;

GRANT SELECT ON core.v_customer_analytics TO analysts;
GRANT SELECT ON core.mv_account_stats TO analysts;
GRANT SELECT ON core.transactions TO analysts;

GRANT SELECT ON core.v_customer_support TO support;
GRANT SELECT ON core.v_active_accounts TO support;
GRANT UPDATE (account_type) ON core.v_active_accounts TO support;

GRANT EXECUTE ON PROCEDURE core.safe_transfer(bigint, bigint, numeric, varchar, bigint) TO application;
GRANT EXECUTE ON PROCEDURE core.open_account(bigint, varchar, core.account_type, numeric, bigint) TO application;
GRANT EXECUTE ON FUNCTION core.get_statement(bigint, int) TO application;

GRANT SELECT ON audit.audit_log TO auditors;
GRANT SELECT ON core.transactions TO auditors;
GRANT SELECT ON core.transfers TO auditors;
GRANT SELECT ON core.fraud_alerts TO auditors;
GRANT SELECT ON core.accounts TO auditors;

\echo 'Matrice des droits :'
SELECT r.rolname AS role,
       o.object_name AS object,
       o.privilege,
       CASE o.kind
           WHEN 'table' THEN has_table_privilege(r.rolname, o.object_name, o.privilege)
           ELSE has_function_privilege(r.rolname, o.object_name, o.privilege)
       END AS allowed
FROM (VALUES ('alice_analyst'), ('bob_support'), ('app_user'), ('charlie_auditor')) AS r (rolname)
CROSS JOIN (VALUES
    ('table', 'core.customers', 'SELECT'),
    ('table', 'core.accounts', 'UPDATE'),
    ('table', 'core.transactions', 'SELECT'),
    ('table', 'core.transactions', 'INSERT'),
    ('table', 'core.v_customer_support', 'SELECT'),
    ('table', 'core.mv_account_stats', 'SELECT'),
    ('table', 'audit.audit_log', 'SELECT'),
    ('function', 'core.get_statement(bigint, int)', 'EXECUTE')
) AS o (kind, object_name, privilege)
ORDER BY 1, 2, 3;
