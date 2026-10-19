CREATE FUNCTION core.fn_transactions_apply_balance()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_balance numeric(14,2);
    v_status  core.account_status;
BEGIN
    SELECT balance, status INTO v_balance, v_status
    FROM core.accounts
    WHERE account_id = NEW.account_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Compte % introuvable', NEW.account_id;
    END IF;

    IF v_status <> 'ACTIVE' THEN
        RAISE EXCEPTION 'Compte % non actif (statut %) : operation refusee', NEW.account_id, v_status;
    END IF;

    IF NEW.tx_type IN ('DEPOSIT', 'TRANSFER_IN') THEN
        v_balance := v_balance + NEW.amount;
    ELSE
        v_balance := v_balance - NEW.amount;
    END IF;

    IF v_balance < 0 THEN
        RAISE EXCEPTION 'Solde insuffisant sur le compte % : operation de % refusee', NEW.account_id, NEW.amount;
    END IF;

    UPDATE core.accounts SET balance = v_balance WHERE account_id = NEW.account_id;

    NEW.balance_after := v_balance;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_transactions_before_insert_balance
    BEFORE INSERT ON core.transactions
    FOR EACH ROW EXECUTE FUNCTION core.fn_transactions_apply_balance();


CREATE FUNCTION core.fn_accounts_protect_balance()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF pg_trigger_depth() < 2 THEN
        RAISE EXCEPTION 'Le solde du compte % ne se modifie que par une ecriture dans core.transactions', OLD.account_id;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_accounts_before_update_balance
    BEFORE UPDATE OF balance ON core.accounts
    FOR EACH ROW
    WHEN (OLD.balance IS DISTINCT FROM NEW.balance)
    EXECUTE FUNCTION core.fn_accounts_protect_balance();


CREATE FUNCTION core.fn_forbid_change()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    RAISE EXCEPTION '% interdit sur %.% : cette table ne peut pas etre modifiee', TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME;
END;
$$;

CREATE TRIGGER trg_transactions_before_update_delete_immutable
    BEFORE UPDATE OR DELETE ON core.transactions
    FOR EACH ROW EXECUTE FUNCTION core.fn_forbid_change();

CREATE TRIGGER trg_transactions_before_truncate_immutable
    BEFORE TRUNCATE ON core.transactions
    FOR EACH STATEMENT EXECUTE FUNCTION core.fn_forbid_change();

CREATE TRIGGER trg_audit_log_before_update_delete_immutable
    BEFORE UPDATE OR DELETE ON audit.audit_log
    FOR EACH ROW EXECUTE FUNCTION core.fn_forbid_change();

CREATE TRIGGER trg_audit_log_before_truncate_immutable
    BEFORE TRUNCATE ON audit.audit_log
    FOR EACH STATEMENT EXECUTE FUNCTION core.fn_forbid_change();


CREATE FUNCTION core.fn_transfers_check_entries()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_out   int;
    v_in    int;
    v_total int;
BEGIN
    SELECT count(*) FILTER (WHERE account_id = NEW.from_account_id AND tx_type = 'TRANSFER_OUT' AND amount = NEW.amount),
           count(*) FILTER (WHERE account_id = NEW.to_account_id AND tx_type = 'TRANSFER_IN' AND amount = NEW.amount),
           count(*)
    INTO v_out, v_in, v_total
    FROM core.transactions
    WHERE transfer_id = NEW.transfer_id;

    IF v_out <> 1 OR v_in <> 1 OR v_total <> 2 THEN
        RAISE EXCEPTION 'Le virement % doit avoir exactement 2 ecritures (1 debit, 1 credit)', NEW.transfer_id;
    END IF;
    RETURN NULL;
END;
$$;

CREATE CONSTRAINT TRIGGER trg_transfers_after_insert_entries
    AFTER INSERT ON core.transfers
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION core.fn_transfers_check_entries();


CREATE FUNCTION core.fn_transactions_detect_fraud()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_count int;
BEGIN
    IF NEW.tx_type = 'WITHDRAWAL' AND NEW.amount >= 5000 THEN
        INSERT INTO core.fraud_alerts (account_id, tx_id, rule_code)
        VALUES (NEW.account_id, NEW.tx_id, 'LARGE_WITHDRAWAL');
    END IF;

    IF NEW.tx_type = 'TRANSFER_OUT' THEN
        SELECT count(*) INTO v_count
        FROM core.transfers
        WHERE from_account_id = NEW.account_id
          AND created_at > NEW.created_at - INTERVAL '10 minutes'
          AND created_at <= NEW.created_at;

        IF v_count >= 5 AND NOT EXISTS (
            SELECT 1
            FROM core.fraud_alerts
            WHERE account_id = NEW.account_id
              AND rule_code = 'TRANSFER_BURST'
              AND created_at > NEW.created_at - INTERVAL '10 minutes'
        ) THEN
            INSERT INTO core.fraud_alerts (account_id, tx_id, rule_code)
            VALUES (NEW.account_id, NEW.tx_id, 'TRANSFER_BURST');
        END IF;
    END IF;

    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_transactions_after_insert_fraud
    AFTER INSERT ON core.transactions
    FOR EACH ROW EXECUTE FUNCTION core.fn_transactions_detect_fraud();


CREATE FUNCTION audit.fn_audit_row()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    INSERT INTO audit.audit_log (table_name, operation, old_data, new_data, db_user)
    VALUES (
        TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME,
        TG_OP,
        CASE WHEN TG_OP IN ('UPDATE', 'DELETE') THEN to_jsonb(OLD) END,
        CASE WHEN TG_OP IN ('INSERT', 'UPDATE') THEN to_jsonb(NEW) END,
        session_user
    );
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_customers_after_change_audit
    AFTER INSERT OR UPDATE OR DELETE ON core.customers
    FOR EACH ROW EXECUTE FUNCTION audit.fn_audit_row();

CREATE TRIGGER trg_accounts_after_insert_delete_audit
    AFTER INSERT OR DELETE ON core.accounts
    FOR EACH ROW EXECUTE FUNCTION audit.fn_audit_row();

CREATE TRIGGER trg_accounts_after_update_audit
    AFTER UPDATE ON core.accounts
    FOR EACH ROW
    WHEN (OLD.status IS DISTINCT FROM NEW.status
       OR OLD.account_type IS DISTINCT FROM NEW.account_type
       OR OLD.customer_id IS DISTINCT FROM NEW.customer_id
       OR OLD.iban IS DISTINCT FROM NEW.iban)
    EXECUTE FUNCTION audit.fn_audit_row();

CREATE TRIGGER trg_transfers_after_insert_audit
    AFTER INSERT ON core.transfers
    FOR EACH ROW EXECUTE FUNCTION audit.fn_audit_row();

CREATE TRIGGER trg_fraud_alerts_after_change_audit
    AFTER INSERT OR UPDATE OR DELETE ON core.fraud_alerts
    FOR EACH ROW EXECUTE FUNCTION audit.fn_audit_row();
