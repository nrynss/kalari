#!/usr/bin/env bash
# The gate fails if any checked declaration in Kalari/ or Aashaan/ rests on
# `sorryAx`, or if any scanned file declares a custom `axiom`.
#
# Method, per source file:
# 1. Textual fail-closed scans on the original file:
#    - an `axiom` declaration fails, unless listed in ALLOWED_AXIOMS below.
#      Unused axioms appear in no `#print axioms` report, so only text sees them.
#    - the token `sorry`/`sorryAx` fails anywhere, including comments. There is
#      no legitimate use in these trees today; this covers `#eval` bodies (which
#      step 2 drops) and anything `#print axioms` cannot name.
#    - `#eval` lines must be bare `#eval <ident>` (single line). Step 2 drops
#      them from the elaborated copy (they run live subprocesses; `lake build`
#      already runs them), and the shape guard proves dropping hides no `sorry`.
#    - `run_cmd`/`run_elab`/`initialize` would also run at elaboration and are
#      not covered: any such line fails with a pointer to extend this script.
# 2. Per-declaration `#print axioms` on a throwaway copy: anonymous `example`s
#    are rewritten to generated theorems, `#eval`s dropped, then one
#    `#print axioms <FQN>` line per `theorem`/`lemma`/`def`/`abbrev`/`opaque` is
#    appended and the copy is elaborated with `lake env lean`. Namespaces are
#    resolved by tracking `namespace`/`end` (these trees use one block each;
#    a `section` fails closed). Every report line must match its declaration by
#    name suffix: private names mangle to `_private.<hash>.<FQN>`, so the match
#    anchors on the trailing `.<name>'`, never on a hardcoded prefix. The report
#    line count must equal the declaration count, and any `sorryAx` fails.
# 3. PINS below name proof entry points extraction must find; if the extractor
#    rots, the pins fail closed instead of silently checking nothing.
#
# Known limits (fail closed, with a message pointing here):
# - anonymous `instance`s are not renamed or checked; the checked kinds are
#   `theorem`/`lemma`/`def`/`abbrev`/`opaque` plus rewritten `example`s.
#   A declaration-looking line inside a block comment or string literal would
#   fail as an unknown constant.
# Offline: imports resolve from the oleans `lake build` already produced, and
# the copies run no subprocesses (`#eval` is dropped, `#guard` is pure).
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail=0

# Explicitly allowed `axiom` declarations, one `path:FQN` per line. Empty: none.
ALLOWED_AXIOMS=""

# Proof entry points extraction must find, one `path:FQN` per line.
PINS="Kalari/Gate.lean:Kalari.Gate.decide_workspace
Kalari/Gate.lean:Kalari.Gate.decide_network
Kalari/Gate.lean:Kalari.Gate.decide_caps
Kalari/Gate.lean:Kalari.Gate.decide_secrets
Aashaan/Main.lean:timeout_json
Aashaan/Main.lean:outputCap_json
Aashaan/Main.lean:killed_timeout_iff
Aashaan/Main.lean:killed_output_cap_iff
Aashaan/Main.lean:clampBytes_le
Aashaan/Main.lean:jstr_quotes_are_delimiters
Aashaan/Main.lean:jstr_no_raw_control"

# rewrite_and_extract <src> <copy>: drop #evals, name anonymous examples,
# write the elaboration copy, and print `DECL <kind> <FQN>` / `AXIOM <FQN>`.
# Exits nonzero on `section` or an unparseable declaration line.
rewrite_and_extract() {
  awk -v copy="$2" '
BEGIN { nns = 0; exn = 0 }
{
  orig = $0
  s = $0; sub(/^[ \t]+/, "", s)
  if (match(s, /^namespace[ \t]+[A-Za-z0-9_'\''\.]+([ \t]|$)/)) {
    nstext = s; sub(/^namespace[ \t]+/, "", nstext); sub(/[ \t].*$/, "", nstext)
    m = split(nstext, parts, /\./)
    for (i = 1; i <= m; i++) nsstack[++nns] = parts[i]
    print orig > copy; next
  }
  if (s ~ /^section([ \t]|$)/) { print "SECTION:" FILENAME ":" NR > "/dev/stderr"; err = 1; next }
  if (match(s, /^end([ \t]|$)/)) {
    rest = s; sub(/^end[ \t]*/, "", rest); sub(/[ \t].*$/, "", rest)
    if (rest == "") { if (nns > 0) nns-- }
    else { m = split(rest, parts, /\./); nns -= m; if (nns < 0) nns = 0 }
    print orig > copy; next
  }
  if (s ~ /^#eval!?([ \t]|$)/) { next }  # shape-checked by caller; dropped here
  t = s
  sub(/^@\[[^]]*\][ \t]*/, "", t)
  while (match(t, /^(private|protected|noncomputable|unsafe|partial)[ \t]+/)) t = substr(t, RLENGTH + 1)
  if (match(t, /^(theorem|lemma|def|abbrev|opaque|example|axiom)([^A-Za-z0-9_'\''\.«]|$)/)) {
    kw = substr(t, 1, RLENGTH - 1); sub(/[^A-Za-z0-9_'\''«]+$/, "", kw)
    line = orig
    if (kw == "example") {
      exn++
      pre = substr(s, 1, length(s) - length(t))
      lead = substr(orig, 1, length(orig) - length(s))
      line = lead pre "theorem __axioms_example_" exn substr(t, length(kw) + 1)
    }
    rest = substr(t, RLENGTH + 1)
    if (kw == "axiom") {
      if (match(rest, /^«[^»]*»/)) name = substr(rest, 1, RLENGTH)
      else if (match(rest, /^[A-Za-z0-9_'\''\.?!]+/)) { name = substr(rest, 1, RLENGTH); sub(/\.\{.*$/, "", name) }
      else { print "NONAME:" FILENAME ":" NR ":" orig > "/dev/stderr"; err = 1; next }
      fqn = ""; for (i = 1; i <= nns; i++) fqn = fqn nsstack[i] "."
      print "AXIOM " fqn name; print line > copy; next
    }
    if (kw == "example") {
      fqn = ""; for (i = 1; i <= nns; i++) fqn = fqn nsstack[i] "."
      print "DECL theorem " fqn "__axioms_example_" exn; print line > copy; next
    }
    if (match(rest, /^«[^»]*»/)) name = substr(rest, 1, RLENGTH)
    else if (match(rest, /^[A-Za-z0-9_'\''\.?!]+/)) { name = substr(rest, 1, RLENGTH); sub(/\.\{.*$/, "", name) }
    else { print "NONAME:" FILENAME ":" NR ":" orig > "/dev/stderr"; err = 1; next }
    fqn = ""; for (i = 1; i <= nns; i++) fqn = fqn nsstack[i] "."
    print "DECL " kw " " fqn name; print line > copy; next
  }
  print orig > copy
}
END { if (err) exit 1 }
' "$1"
}

rx_escape() {
  printf '%s' "$1" | sed 's/[][\\.^$*+?(){|}]/\\&/g'
}

check_file() {
  local src=$1
  local bad

  # 1a. Custom axiom declarations fail unless explicitly allowed.
  bad=$(grep -nE '^[[:space:]]*(@\[[^]]*\][[:space:]]*)?(private[[:space:]]+|protected[[:space:]]+|noncomputable[[:space:]]+|unsafe[[:space:]]+|partial[[:space:]]+)*axiom([^A-Za-z0-9_.'\''"«]|$)' "$src" || true)
  if [ -n "$bad" ]; then
    echo "FAIL $src: axiom declaration (add to ALLOWED_AXIOMS or remove):"
    printf '%s\n' "$bad"
    fail=1; return
  fi
  # 1b. The sorry token fails anywhere; no legitimate use in these trees.
  bad=$(grep -nE "(^|[^A-Za-z0-9_'])sorry(Ax)?([^A-Za-z0-9_']|$)" "$src" || true)
  if [ -n "$bad" ]; then
    echo "FAIL $src: sorry token found:"
    printf '%s\n' "$bad"
    fail=1; return
  fi
  # 1c. #eval lines must be bare `#eval <ident>` so dropping them is safe.
  bad=$(grep -nE '^[[:space:]]*#eval' "$src" | grep -vE "^[0-9]+:[[:space:]]*#eval!?[[:space:]]+[A-Za-z0-9_.'\''«»?!]+[[:space:]]*$" || true)
  if [ -n "$bad" ]; then
    echo "FAIL $src: non-trivial #eval (keep #eval to a bare identifier):"
    printf '%s\n' "$bad"
    fail=1; return
  fi
  # 1d. Other elaboration-time runners are not covered.
  bad=$(grep -nE '^[[:space:]]*(run_cmd|run_elab|initialize|builtin_initialize)([^A-Za-z0-9_]|$)' "$src" || true)
  if [ -n "$bad" ]; then
    echo "FAIL $src: elaboration-time runner not covered (extend tools/axioms.sh):"
    printf '%s\n' "$bad"
    fail=1; return
  fi

  # 2. Rewrite + extract. The copy mirrors the repo layout so that
  # `include_str "../testdata/..."` resolves; testdata is symlinked in.
  # (`#eval`s are dropped by rewrite_and_extract; `lake env lean` runs from
  # the repo root, so CWD-relative `#guard` reads keep working.)
  local copy="$tmp/$src"
  mkdir -p "$(dirname "$copy")"
  [ -e "$tmp/testdata" ] || ln -s "$PWD/testdata" "$tmp/testdata"
  local listed
  if ! listed=$(rewrite_and_extract "$src" "$copy"); then
    echo "FAIL $src: declaration extraction failed (see NONAME/SECTION above; update tools/axioms.sh)"
    fail=1; return
  fi
  local axiomsDecls
  axiomsDecls=$(printf '%s\n' "$listed" | grep '^AXIOM ' || true)
  if [ -n "$axiomsDecls" ]; then
    # Reached only if 1a grew an allowlist but extraction still sees the decl.
    local a
    while IFS= read -r a; do
      local fqn=${a#AXIOM }
      if ! printf '%s\n' "$ALLOWED_AXIOMS" | grep -qx "$src:$fqn"; then
        echo "FAIL $src: axiom $fqn not in ALLOWED_AXIOMS"
        fail=1; return
      fi
    done <<< "$axiomsDecls"
  fi
  local names
  names=$(printf '%s\n' "$listed" | grep '^DECL ' | awk '{print $3}' || true)
  local n
  n=$(printf '%s' "$names" | grep -c . || true)
  if [ "$n" = "0" ]; then
    echo "ok   $src (0 declarations; textual scans only)"
    return
  fi

  # 3. Pins must resolve in this file.
  local pin
  while IFS= read -r pin; do
    [ -n "$pin" ] || continue
    if [ "${pin%%:*}" = "$src" ]; then
      if ! printf '%s\n' "$names" | grep -qx "${pin#*:}"; then
        echo "FAIL $src: pin ${pin#*:} not extracted (update tools/axioms.sh)"
        fail=1; return
      fi
    fi
  done <<< "$PINS"

  local fqn
  declare -A seen
  for fqn in $names; do
    printf '#print axioms %s\n' "$fqn" >> "$copy"
    # Lean displays «name» unescaped; match on the display form.
    seen["$(printf '%s' "$fqn" | tr -d '«»')"]=1
  done
  names=$(printf '%s\n' "${!seen[@]}")
  local out
  if ! out=$(lake env lean "$copy" 2>&1); then
    echo "FAIL $src: lean failed:"
    printf '%s\n' "$out"
    fail=1; return
  fi
  # Every name matches at least one report line, by suffix (private-proof);
  # the count check below makes the correspondence exact.
  for fqn in $names; do
    local esc
    esc=$(rx_escape "$fqn")
    if ! printf '%s\n' "$out" | grep -qE "(^|[.'])${esc}' (depends on axioms:|does not depend on any axioms)"; then
      echo "FAIL $src: no axioms report for $fqn:"
      printf '%s\n' "$out"
      fail=1; return
    fi
  done
  local reports
  reports=$(printf '%s\n' "$out" | grep -cE "' (depends on axioms:|does not depend on any axioms)" || true)
  if [ "$reports" != "$n" ]; then
    echo "FAIL $src: $reports axioms reports for $n declarations (unexpected extra output)"
    printf '%s\n' "$out"
    fail=1; return
  fi
  if printf '%s\n' "$out" | grep -q 'sorryAx'; then
    echo "FAIL $src: sorryAx found:"
    printf '%s\n' "$out" | grep 'sorryAx'
    fail=1; return
  fi
  echo "ok   $src ($n declarations, no sorryAx)"
  printf '%s\n' "$out" | grep -E "' (depends on axioms:|does not depend on any axioms)" | sed 's/^/  /'
}

files=$(find Kalari Aashaan -name '*.lean' | sort)
if [ -z "$files" ]; then echo "FAIL: no source files found"; exit 1; fi
for f in $files; do check_file "$f"; done

exit $fail
