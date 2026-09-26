#!/usr/bin/env bash
#
# toml.sh: a strict subset of TOML, read with awk, for benchbar.toml (the
# team lockfile) and team profiles.
#
# Allowed: comments, top level keys, [table], [[array of tables]],
# key = "string", true / false, integers, and one line arrays of strings.
# Keys are [a-z_]+; strings hold no backslash and no double quote. Anything
# else stops with FILE:LINE: not supported: WHY. A file this accepts is
# valid TOML, so any other TOML tool reads it the same way.
#
# fl_toml_parse FILE KEYS TABLES ARRAYS REQUIRED prints one record per value:
#   SECTION<TAB>INDEX<TAB>KEY<TAB>VALUE
# SECTION is "top", a table or an array of tables; INDEX counts the
# entries of an array of tables from 1 (0 otherwise). Arrays are space
# separated. KEYS lists "section.key=type" (type s, b, i or a), REQUIRED
# lists "section.key". Exit 1 with the message on stderr.

fl_toml_parse() {
  local file="$1" keys="$2" tables="$3" arrays="$4" required="$5"
  [[ -f "$file" ]] || { printf '%s: no such file\n' "$file" >&2; return 1; }
  awk -v fname="$(basename "$file")" -v keys="$keys" -v tables="$tables" -v arrays="$arrays" -v required="$required" '
    function fail(msg, ln) { printf "%s:%d: not supported: %s\n", fname, (ln ? ln : NR), msg > "/dev/stderr"; bad = 1; exit 1 }
    function header_close(   k, n, r) {
      # the required keys of the table or entry that just ended
      if (sec == "top" || sec == "") return
      n = split(required, r, " ")
      for (k = 1; k <= n; k++) {
        split(r[k], p, ".")
        if (p[1] == sec && !((sec SUBSEP idx SUBSEP p[2]) in seen)) fail("[" ((sec in isarr) ? "[" sec "]" : sec) "] needs " p[2], hline)
      }
    }
    BEGIN {
      n = split(keys, kk, " "); for (i = 1; i <= n; i++) { split(kk[i], p, "="); ktype[p[1]] = p[2] }
      n = split(tables, kk, " "); for (i = 1; i <= n; i++) istab[kk[i]] = 1
      n = split(arrays, kk, " "); for (i = 1; i <= n; i++) isarr[kk[i]] = 1
      sec = "top"; idx = 0
    }
    {
      line = $0; sub(/\r$/, "", line)
      if (line ~ /^[ \t]*(#.*)?$/) next
      if (match(line, /^[ \t]*\[\[[a-z_]+\]\][ \t]*(#.*)?$/)) {
        name = line; sub(/^[ \t]*\[\[/, "", name); sub(/\]\].*$/, "", name)
        if (!(name in isarr)) fail("unknown array of tables [[" name "]]")
        header_close(); sec = name; count[name]++; idx = count[name]; hline = NR; next
      }
      if (match(line, /^[ \t]*\[[a-z_]+\][ \t]*(#.*)?$/)) {
        name = line; sub(/^[ \t]*\[/, "", name); sub(/\].*$/, "", name)
        if (!(name in istab)) fail("unknown table [" name "]")
        if (name in tabseen) fail("a second [" name "]")
        header_close(); tabseen[name] = 1; sec = name; idx = 0; hline = NR; next
      }
      if (line ~ /^[ \t]*\[/) fail("table header; only [" tables "] and [[" arrays "]] are known")
      if (!match(line, /^[ \t]*[a-z_]+[ \t]*=[ \t]*/)) fail("expected key = value (keys are lower case letters and _)")
      key = substr(line, RSTART, RLENGTH); gsub(/[ \t=]/, "", key)
      rest = substr(line, RSTART + RLENGTH)
      if (!((sec "." key) in ktype)) fail("unknown key " key (sec == "top" ? "" : " in [" sec "]"))
      if ((sec SUBSEP idx SUBSEP key) in seen) fail("duplicate key " key)
      seen[sec SUBSEP idx SUBSEP key] = 1
      c = substr(rest, 1, 1); t = ""
      if (substr(rest, 1, 3) == "\"\"\"" || substr(rest, 1, 3) == "\047\047\047") fail("multi line strings")
      else if (c == "\"") {
        if (!match(rest, /^"[^"\\]*"/)) fail("escapes or quotes inside a string")
        val = substr(rest, 2, RLENGTH - 2); tail = substr(rest, RLENGTH + 1); t = "s"
      } else if (c == "\047") fail("literal strings; use double quotes")
      else if (c == "{") fail("inline tables")
      else if (c == "[") {
        if (!match(rest, /^\[[ \t]*("[^"\\]*"[ \t]*(,[ \t]*"[^"\\]*"[ \t]*)*,?)?[ \t]*\]/)) fail("arrays other than one line arrays of plain strings")
        val = substr(rest, 2, RLENGTH - 2); tail = substr(rest, RLENGTH + 1); t = "a"
        gsub(/[" \t]/, "", val); gsub(/,/, " ", val); sub(/ +$/, "", val)
      } else if (match(rest, /^(true|false)/)) { val = substr(rest, 1, RLENGTH); tail = substr(rest, RLENGTH + 1); t = "b" }
      else if (match(rest, /^[+-]?[0-9]+/)) { val = substr(rest, 1, RLENGTH); tail = substr(rest, RLENGTH + 1); t = "i" }
      else fail("value of " key)
      if (tail !~ /^[ \t]*(#.*)?$/) fail("text after the value of " key)
      if (t != ktype[sec "." key]) fail(key " must be " (ktype[sec "." key] == "s" ? "a string" : ktype[sec "." key] == "b" ? "true or false" : ktype[sec "." key] == "i" ? "an integer" : "an array of strings"))
      if (key == "repo" && val ~ /^[a-zA-Z+]+:\/\/[^\/]*@/ && val !~ /^ssh:\/\//) fail("a user name or token in a repo URL (the file gets committed)")
      if (key == "commit" && (val !~ /^[0-9a-f]+$/ || length(val) < 7 || length(val) > 40)) fail("commit must be 7 to 40 lower case hex characters")
      if (key == "name" && val !~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/) fail("name " val)
      printf "%s\t%d\t%s\t%s\n", sec, idx, key, val
    }
    END {
      if (bad) exit 1
      header_close()
      if (bad) exit 1
      n = split(required, r, " ")
      for (k = 1; k <= n; k++) { split(r[k], p, "."); if (p[1] == "top" && !(("top" SUBSEP 0 SUBSEP p[2]) in seen)) { printf "%s: not supported: %s is missing\n", fname, p[2] > "/dev/stderr"; exit 1 } }
    }' "$file"
}
