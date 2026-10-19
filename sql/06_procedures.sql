CREATE PROCEDURE core.safe_transfer(
    p_from_account_id bigint,
    p_to_account_id   bigint,
    p_amount          numeric,
    p_label           varchar DEFAULT NULL,
    INOUT p_transfer_id bigint DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_from core.accounts%ROWTYPE;
    v_to   core.accounts%ROWTYPE;
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Montant invalide : % (il doit etre strictement positif)', p_amount;
    END IF;

    IF p_amount <> round(p_amount, 2) THEN
        RAISE EXCEPTION 'Montant invalide : % (2 decimales maximum)', p_amount;
    END IF;

    IF p_from_account_id IS NULL OR p_to_account_id IS NULL THEN
        RAISE EXCEPTION 'Les deux comptes sont obligatoires';
    END IF;

    IF p_from_account_id = p_to_account_id THEN
        RAISE EXCEPTION 'Virement refuse : le compte debiteur et le compte crediteur sont identiques (%)', p_from_account_id;
    END IF;

    PERFORM 1 FROM core.accounts WHERE account_id = least(p_from_account_id, p_to_account_id) FOR UPDATE;
    PERFORM 1 FROM core.accounts WHERE account_id = greatest(p_from_account_id, p_to_account_id) FOR UPDATE;

    SELECT * INTO v_from FROM core.accounts WHERE account_id = p_from_account_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Compte debiteur % introuvable', p_from_account_id;
    END IF;

    SELECT * INTO v_to FROM core.accounts WHERE account_id = p_to_account_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Compte crediteur % introuvable', p_to_account_id;
    END IF;

    IF v_from.status <> 'ACTIVE' THEN
        RAISE EXCEPTION 'Compte debiteur % non actif (statut %)', p_from_account_id, v_from.status;
    END IF;

    IF v_to.status <> 'ACTIVE' THEN
        RAISE EXCEPTION 'Compte crediteur % non actif (statut %)', p_to_account_id, v_to.status;
    END IF;

    IF v_from.balance < p_amount THEN
        RAISE EXCEPTION 'Solde insuffisant sur le compte % (solde %, demande %)', p_from_account_id, v_from.balance, p_amount;
    END IF;

    INSERT INTO core.transfers (from_account_id, to_account_id, amount, label)
    VALUES (p_from_account_id, p_to_account_id, p_amount, p_label)
    RETURNING transfer_id INTO p_transfer_id;

    INSERT INTO core.transactions (account_id, tx_type, amount, transfer_id)
    VALUES (p_from_account_id, 'TRANSFER_OUT', p_amount, p_transfer_id),
           (p_to_account_id,   'TRANSFER_IN',  p_amount, p_transfer_id);
END;
$$;


CREATE PROCEDURE core.open_account(
    p_customer_id     bigint,
    p_iban            varchar,
    p_account_type    core.account_type,
    p_initial_deposit numeric DEFAULT 0,
    INOUT p_account_id bigint DEFAULT NULL
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_kyc core.kyc_status;
BEGIN
    IF p_initial_deposit IS NULL OR p_initial_deposit < 0 THEN
        RAISE EXCEPTION 'Depot initial invalide : %', p_initial_deposit;
    END IF;

    IF p_account_type IS NULL THEN
        RAISE EXCEPTION 'Type de compte obligatoire (CHECKING ou SAVINGS)';
    END IF;

    SELECT kyc_status INTO v_kyc
    FROM core.customers
    WHERE customer_id = p_customer_id
    FOR SHARE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Client % introuvable', p_customer_id;
    END IF;

    IF v_kyc <> 'VERIFIED' THEN
        RAISE EXCEPTION 'Ouverture refusee : identite du client % non verifiee (KYC %)', p_customer_id, v_kyc;
    END IF;

    INSERT INTO core.accounts (customer_id, iban, account_type)
    VALUES (p_customer_id, upper(replace(p_iban, ' ', '')), p_account_type)
    RETURNING account_id INTO p_account_id;

    IF p_initial_deposit > 0 THEN
        INSERT INTO core.transactions (account_id, tx_type, amount)
        VALUES (p_account_id, 'DEPOSIT', p_initial_deposit);
    END IF;
END;
$$;


CREATE FUNCTION core.get_statement(p_account_id bigint, p_limit int DEFAULT 50)
RETURNS TABLE (
    tx_id         bigint,
    created_at    timestamptz,
    tx_type       core.tx_type,
    amount        numeric(14,2),
    balance_after numeric(14,2),
    transfer_id   bigint
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT t.tx_id, t.created_at, t.tx_type, t.amount, t.balance_after, t.transfer_id
    FROM core.transactions AS t
    WHERE t.account_id = p_account_id
    ORDER BY t.created_at DESC, t.tx_id DESC
    LIMIT least(greatest(p_limit, 1), 500);
$$;
