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

test_verifies_config_before_finishing() {
  assert_eq "runs nginx -t" "$(grep -c 'nginx -t' "$S")" "1"
}

test_is_executable_bash
test_removes_default_site
test_never_opens_public_ports
test_verifies_config_before_finishing
finish
