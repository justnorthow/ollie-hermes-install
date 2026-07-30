# Reaching the native Hermes dashboard

The `<box>-hermes.jnow.io` hostnames are being retired. The native Hermes
dashboard is now reached over an SSH port-forward to a loopback proxy that
injects the session token for you.

## Connect

    ssh -o IdentityAgent=none -i <key> -L 9219:127.0.0.1:9219 ollie@<box>

Then open <http://127.0.0.1:9219>.

Ports are `dashboard port + 100`:

| Agent | Dashboard | Forward |
|---|---|---|
| default | 9119 | 9219 |
| second agent | 9121 | 9221 |

Confirm a box's ports with:

    grep -h -oE '\-\-port[= ]+[0-9]+' ~/.config/systemd/user/hermes-dashboard*.service

## Why the plain forward to 9119 does not work

Hermes 0.19.0 requires an `Authorization: Bearer <session token>` header on its
API routes. A browser cannot send one on navigation, there is no query-param or
cookie fallback, and `/login` is disabled. Forwarding 9119 directly gives you
the SPA shell over a 401 wall. The proxy exists to supply that header.

## Why it can look broken when it isn't

This proxy is reached only through an SSH forward. If the forward drops, the
browser reports a connection error that looks identical to a server-side failure.
Always confirm the tunnel is up before investigating the box itself.

## Troubleshooting

**Everything 401s.** The auth file is stale or missing. Check the gate first:

    bash ~/ollie-hermes-install/scripts/check-box-config.sh | grep hermes-ui

This reports `PASS: hermes-ui-auth matches orchestrator token` or a FAIL naming
the stale file. Checking is cheaper than re-running. Two other FAILs are worth
telling apart: `hermes-ui-auth could not be read` means the gate itself could not
open the mode-600 file (no passwordless sudo, or the file is empty) — it is NOT a
stale token, and re-running the token script will not fix it. `hermes-ui-proxy
conf stale` means a listener is rendered for the wrong upstream port, which
`ensure-hermes-ui-proxy.sh` will correct. If the gate reports FAIL or you need to
refresh, run:

    bash ~/ollie-hermes-install/scripts/lib/ensure-dashboard-token.sh

Then retry.

**Chat or the events feed will not connect, but pages load.** The `Origin`
rewrite is missing or nginx did not reload. Check with `sudo nginx -t` and
`grep Origin /etc/nginx/conf.d/hermes-ui-proxy-*.conf`. Note that nginx logs a
WebSocket as `101` only when it CLOSES, so a working chat shows **no** 101 —
check for `pty accepted` in `~/.hermes/logs/` instead.

**Connection refused on the forward.** `systemctl is-active nginx` on the box.
A full (non-`CHECK_SKIP_LIVE`) gate run covers this: it asserts nginx is active
and that each agent's listener actually answers 200 on `/api/files`, so a box
whose files are perfect but whose nginx is dead or never reloaded now FAILs
instead of reporting done-done.

## After rotating the dashboard token

`ensure-dashboard-token.sh` re-renders the proxy auth file automatically. Verify
with `bash ~/ollie-hermes-install/scripts/check-box-config.sh | grep hermes-ui`.
