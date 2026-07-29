# Provision an app schema in the core Supabase

Stage 1 of the single-Supabase design. Prepares the core stack to host one app
as a Postgres schema. Safe to run before anything migrates — it touches nothing
an app or user currently uses.

    ssh <box>
    cd ~/ollie-hermes-install
    printf 'APP_NAME=popbys\n' | bash scripts/26-provision-app-schema.sh

`APP_NAME` is a Postgres identifier: `^[a-z][a-z0-9_]*$`. Hyphens are not valid
— an app named `foo-bar` is provisioned as `foo_bar`.

What it does, idempotently:

- creates schema `<name>` owned by role `<name>_owner`
- grants the PostgREST roles `USAGE` on the schema, and `<name>_owner` to
  `authenticator` so PostgREST can switch into it
- grants `<name>_owner` only `USAGE` on `auth` and `REFERENCES` on `auth.users`
  — the narrow, unavoidable need for app rows to FK to identity
- revokes everything on `public` from `<name>_owner`
- appends the schema to `PGRST_DB_SCHEMAS` and recreates `rest`
- writes `~/supabase-stack/app-keys/<name>.jwt` (mode 600) — the app's runtime
  key, claiming `role: <name>_owner`

**The app never receives core's `service_role` key.** That key bypasses RLS and
reaches every schema plus `auth`; the whole point of the owner role is that a
compromised app cannot leave its own schema.

## Verify

    docker exec supabase-db psql -U postgres -d postgres \
      -c "\dn" -c "\du <name>_owner"
    grep PGRST_DB_SCHEMAS ~/supabase-stack/.env

Negative check — the owner must not be able to read another schema:

    docker exec supabase-db psql -U postgres -d postgres \
      -c "SET ROLE <name>_owner; SELECT count(*) FROM auth.users;"

Expected: `ERROR: permission denied for table users`. If that returns a count,
the grants are wrong and the isolation guarantee is not holding.
