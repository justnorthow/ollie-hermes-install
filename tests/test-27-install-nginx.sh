#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/assert.sh"
S="$HERE/../scripts/27-install-nginx.sh"

test_is_executable_bash() {
  assert_eq "file exists" "$([[ -f "$S" ]] && echo yes || echo no)" "yes"
  assert_eq "bash shebang" "$(head -1 "$S")" "#!/usr/bin/env bash"
}

test_removes_default_site() {
  # grep -c counts matching LINES, and the path legitimately appears on both the
  # existence check and the rm. Assert the removal specifically.
  assert_eq "rm -f on sites-enabled/default" \
    "$(grep -cE 'rm -f .*sites-enabled/default' "$S")" "1"
}

test_never_opens_public_ports() {
  assert_eq "no ufw allow 80/443" "$(grep -cE 'ufw +allow +(80|443)' "$S")" "0"
  assert_eq "no certbot/letsencrypt" "$(grep -ciE 'certbot|letsencrypt' "$S")" "0"
}

test_restart_is_gated_on_config_check() {
  # A plain substring count on "nginx -t" only proves the text is present —
  # a script that ran `nginx -t` as a dead no-op and then restarted nginx
  # unconditionally would still pass that. Extract the actual if/then/else/fi
  # block gated on the config check and assert the control-flow safety
  # property the plan requires: restart only in the success branch, a
  # non-zero exit in the failure branch, and no restart anywhere outside
  # that gated branch. Not anchored to exact whitespace or to the FATAL
  # message's wording, so it survives reasonable reformatting.
  local block success failure
  block="$(awk '/if[[:space:]].*nginx[[:space:]]+-t.*then[[:space:]]*$/,/^fi[[:space:]]*$/' "$S")"
  success="$(printf '%s\n' "$block" | awk '/then[[:space:]]*$/{flag=1; next} /^else[[:space:]]*$/{flag=0} flag')"
  failure="$(printf '%s\n' "$block" | awk '/^else[[:space:]]*$/{flag=1; next} /^fi[[:space:]]*$/{flag=0} flag')"

  assert_eq "found an if/then block gated on nginx -t" \
    "$([[ -n "$block" ]] && echo yes || echo no)" "yes"

  assert_eq "restart happens only in the config-check success branch" \
    "$(printf '%s\n' "$success" | grep -cE 'systemctl restart nginx')" "1"

  assert_eq "config-check failure branch exits non-zero" \
    "$(printf '%s\n' "$failure" | grep -cE 'exit +[1-9][0-9]*')" "1"

  assert_eq "no restart outside the gated success branch" \
    "$(grep -cE 'systemctl restart nginx' "$S")" \
    "$(printf '%s\n' "$success" | grep -cE 'systemctl restart nginx')"
}

test_is_executable_bash
test_removes_default_site
test_never_opens_public_ports
test_restart_is_gated_on_config_check
finish
