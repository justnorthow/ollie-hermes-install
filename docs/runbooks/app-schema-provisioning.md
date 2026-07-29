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
- revokes any **explicit** grant `<name>_owner` holds on schema `public`. This
  does **not** remove the ambient `USAGE` every role inherits from the `PUBLIC`
  pseudo-role (verified on PG15.8) — that ambient `USAGE` provides name
  resolution only, not table access. Isolation from `public` rests on never
  granting this role table privileges there, not on the `REVOKE`
- appends the schema to `PGRST_DB_SCHEMAS` and recreates `rest`
- writes `~/supabase-stack/app-keys/<name>.jwt` (mode 600) — the app's runtime
  key, claiming `role: <name>_owner`

**The app never receives core's `service_role` key.** That key bypasses RLS and
reaches every schema plus `auth`; the whole point of the owner role is that a
compromised app cannot leave its own schema.

## Verify

**Privileges.** Do not use `\dn` / `\du` — they list schemas, owners, role
attributes and memberships, and **not one schema or table privilege**. They
print plausible output whether the grants landed or not. Read the privileges:

    docker exec supabase-db psql -U postgres -d postgres -c "
      SELECT has_schema_privilege('<name>_owner','auth','USAGE')           AS auth_usage,
             has_table_privilege ('<name>_owner','auth.users','SELECT')    AS users_select,
             has_table_privilege ('<name>_owner','auth.users','TRIGGER')   AS users_trigger,
             has_schema_privilege('<name>_owner','<name>','CREATE')        AS own_schema_create;"

Expected, exactly: `auth_usage` = **t**, `users_select` = **f**,
`users_trigger` = **f**, `own_schema_create` = **t**. Any other combination
means the grants are wrong — stop before any app data moves.

**Registration.** The `.env` value alone proves nothing: `rest` reads it only
because the compose file substitutes `${PGRST_DB_SCHEMAS:-public}`. Check what
the container actually got:

    grep '^PGRST_DB_SCHEMAS=' ~/supabase-stack/.env      # must list <name>
    docker exec supabase-rest env | grep PGRST_DB_SCHEMAS  # must list <name> too

If the second command still shows only `public`, the stack's compose file
predates the parameterisation — redeploy with `11-install-supabase.sh --deploy`.
(Script 26 refuses to run against such a stack, so this should not happen.)

**Mandatory RLS — the shared `ANON_KEY`.** Every app on the box is handed the
*same* core `ANON_KEY`, and `anon`/`authenticated` hold `USAGE` on every app
schema plus DML on its tables (they must, for user-context requests). So the
only thing keeping app A's browser bundle out of app B's data is RLS being
enabled on every table. Re-run this after any migration that creates one:

    docker exec supabase-db psql -U postgres -d postgres -c "
      SELECT relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = '<name>' AND c.relkind = 'r' AND NOT c.relrowsecurity;"

**Every row returned is a table that every app on the box can read — and write —
with the shared anon key.** An empty result is the gate; nothing else enforces
this boundary.

Negative check — the owner must not be able to read another schema:

    docker exec supabase-db psql -U postgres -d postgres \
      -c "SET ROLE <name>_owner; SELECT count(*) FROM auth.users;"

Expected: `ERROR: permission denied for table users`. If that returns a count,
the grants are wrong and the isolation guarantee is not holding.
