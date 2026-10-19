CREATE ROLE bank_owner LOGIN PASSWORD :'owner_password';

CREATE ROLE analysts NOLOGIN;
CREATE ROLE support NOLOGIN;
CREATE ROLE application NOLOGIN;
CREATE ROLE auditors NOLOGIN;

CREATE ROLE alice_analyst LOGIN IN ROLE analysts PASSWORD :'analyst_password';
CREATE ROLE bob_support LOGIN IN ROLE support PASSWORD :'support_password';
CREATE ROLE app_user LOGIN IN ROLE application PASSWORD :'app_password';
CREATE ROLE charlie_auditor LOGIN IN ROLE auditors PASSWORD :'auditor_password';

ALTER ROLE alice_analyst SET statement_timeout = '60s';
ALTER ROLE bob_support SET statement_timeout = '5s';
ALTER ROLE app_user SET statement_timeout = '5s';
ALTER ROLE charlie_auditor SET statement_timeout = '60s';

CREATE DATABASE bankdb OWNER bank_owner ENCODING 'UTF8' TEMPLATE template0;

REVOKE ALL ON DATABASE bankdb FROM PUBLIC;
