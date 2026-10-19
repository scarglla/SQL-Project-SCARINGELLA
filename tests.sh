#!/bin/bash

set -euo pipefail

DB_NAME="bankdb"

echo "=== 1. TEST ÉTAPE 1 ==="
sudo -u postgres psql -d "$DB_NAME" -c "SHOW listen_addresses;"
sudo -u postgres psql -d "$DB_NAME" -c "SELECT * FROM pg_hba_file_rules WHERE error IS NOT NULL;"

echo "=== 2. TEST ÉTAPE 2 ==="
sudo -u postgres psql -d "$DB_NAME" << 'EOF'
INSERT INTO core.customers (first_name, last_name, email, birth_date)
VALUES ('Alice', 'Dupont', 'alice.dupont.test@test.com', '1995-05-12')
ON CONFLICT (email) DO NOTHING;
EOF

if sudo -u postgres psql -d "$DB_NAME" -c "INSERT INTO core.customers (first_name, last_name, email, birth_date) VALUES ('Bébé', 'Client', 'bebe@test.com', '2015-01-01');" 2>/dev/null; then
    echo "[-] Erreur : Client accepté à tort."
    exit 1
else
    echo "[+] Succès : Client rejeté."
fi

sudo -u postgres psql -d "$DB_NAME" << 'EOF'
INSERT INTO core.accounts (customer_id, iban, account_type, balance)
VALUES (1, 'FR7630002000123456789012999', 'CHECKING', 1000.00)
ON CONFLICT (iban) DO NOTHING;

INSERT INTO core.accounts (customer_id, iban, account_type, balance)
VALUES (1, 'FR7630002000123456789012888', 'SAVINGS', 500.00)
ON CONFLICT (iban) DO NOTHING;
EOF

echo "=== 3. TEST ÉTAPE 3 ==="
sudo -u postgres psql -d "$DB_NAME" << 'EOF'
SELECT has_table_privilege('alice_analyst', 'core.customers', 'SELECT');
SELECT has_table_privilege('app_user', 'core.accounts', 'INSERT');
EOF

echo "=== 4. TEST ÉTAPE 4 ==="
sudo -u postgres psql -d "$DB_NAME" << 'EOF'
SELECT * FROM core.v_customer_support;
SELECT * FROM core.mv_account_stats;
REFRESH MATERIALIZED VIEW CONCURRENTLY core.mv_account_stats;
EOF

echo "=== 5. TEST ÉTAPE 5 ==="
sudo -u postgres psql -d "$DB_NAME" << 'EOF'
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM core.customers WHERE email = 'alice.dupont.test@test.com';
EOF

echo "=== 6. TEST ÉTAPE 6 ==="
sudo -u postgres psql -d "$DB_NAME" << 'EOF'
INSERT INTO core.transactions (account_id, tx_type, amount, balance_after)
VALUES (1, 'DEPOSIT', 100.00, 1100.00);
EOF

if sudo -u postgres psql -d "$DB_NAME" -c "UPDATE core.transactions SET amount = 0.00 WHERE amount = 100.00;" 2>/dev/null; then
    echo "[-] Erreur : Modification du grand livre autorisée à tort."
    exit 1
else
    echo "[+] Succès : Modification du grand livre correctement bloquée par le trigger."
fi

echo "=== 7. TEST ÉTAPE 7 & 8 ==="
sudo -u postgres psql -d "$DB_NAME" << 'EOF'
CALL core.safe_transfer(1, 2, 200.00);
EOF

if sudo -u postgres psql -d "$DB_NAME" -c "CALL core.safe_transfer(1, 2, 99999.00);" 2>/dev/null; then
    echo "[-] Erreur : Virement avec solde insuffisant accepté à tort."
    exit 1
else
    echo "[+] Succès : Virement excessif correctement bloqué."
fi

echo "=== 8. TESTS BONUS CYBER (C1 à C4) ==="
sudo -u postgres psql -d "$DB_NAME" -c "SHOW ssl;"

sudo -u postgres psql -d "$DB_NAME" << 'EOF'
UPDATE core.customers 
SET phone = pgp_sym_encrypt('0612345678', 'MaCleSecreteSuperSolide')
WHERE email = 'alice.dupont.test@test.com';

SELECT customer_id, first_name, pgp_sym_decrypt(phone, 'MaCleSecreteSuperSolide') AS decrypted_phone 
FROM core.customers 
WHERE email = 'alice.dupont.test@test.com';
EOF

sudo -u postgres psql -d "$DB_NAME" << 'EOF'
SELECT * FROM core.search_client_safe('Alice');
SELECT * FROM core.search_client_safe('Alice'' OR ''1''=''1');
EOF

echo "=== TESTS PROJET VALIDÉS ==="
