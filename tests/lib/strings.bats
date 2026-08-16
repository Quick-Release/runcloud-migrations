#!/usr/bin/env bats
# Tests for lib/strings.sh - pure string helpers.

setup() {
  # shellcheck source=../../lib/strings.sh
  . "${BATS_TEST_DIRNAME}/../../lib/strings.sh"
}

@test "human_bytes converts bytes to human readable" {
  [ "$(human_bytes 0)" = "0 B" ]
  [ "$(human_bytes 512)" = "512 B" ]
  [ "$(human_bytes 1024)" = "1 KiB" ]
  [ "$(human_bytes 1536)" = "1 KiB" ]
  [ "$(human_bytes 2147483648)" = "2 GiB" ]
  [ "$(human_bytes 1099511627776)" = "1 TiB" ]
}

@test "safe_name sanitizes filenames" {
  [ "$(safe_name "foo/bar baz")" = "foo_bar_baz" ]
  [ "$(safe_name "UPPER-123.test")" = "UPPER-123.test" ]
  [ "$(safe_name "a/b/c.d")" = "a_b_c.d" ]
}

@test "safe_domain normalizes domains" {
  [ "$(safe_domain "Foo BAR.com")" = "foo-bar.com" ]
  [ "$(safe_domain "---example.com---")" = "example.com" ]
  [ "$(safe_domain "My_Site.org")" = "my-site.org" ]
}

@test "safe_db_name normalizes and truncates db names" {
  [ "$(safe_db_name "my-blog-db")" = "my_blog_db" ]
  [ "$(safe_db_name "0123456789012345678901234567890123456789")" = "01234567890123456789012345678901" ]
}

@test "strip_ansi removes ANSI escape codes" {
  [ "$(strip_ansi $'\033[1;32m[OK]\033[0m done')" = "[OK] done" ]
  [ "$(strip_ansi "no color")" = "no color" ]
}

@test "shquote single-quotes values safely" {
  [ "$(shquote "hello")" = "'hello'" ]
  [ "$(shquote "it's")" = "'it'\\''s'" ]
}