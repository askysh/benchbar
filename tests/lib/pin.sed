# The part of pin_check's normalization that does not depend on the run (sed -E). The folders of the
# test (TMP_DIR, ROOT) are replaced before this file runs. Everything that changes from run to run
# or from machine to machine is replaced here, so a golden holds the same bytes on every machine.
s#"token":"[0-9a-f]{64}"#"token":"<TOKEN>"#g
s#"secs":[0-9]+#"secs":<N>#g
s#[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z#<TS>#g
s#([ (])[0-9]+s([ ),".]|$)#\1<N>s\2#g
s#/benches/frappe-bench-[^/ ]*#/benches/frappe-bench-<H>#g
s#op-[0-9]{8}-[0-9]{6}-[0-9]+(-[0-9]+)?#op-<ID>#g
s#/logs/[0-9]{8}-[0-9]{6}-[0-9]+#/logs/<LOG>#g
s#[^ ]*/benchbar-[a-z]+\.[A-Za-z0-9]+#/tmp/benchbar-X.<R>#g
s#gui/[0-9]+/#gui/<UID>/#g
# the message of a failing mkdir (the mock build makes the same folder twice) differs between GNU, uutils and BSD
s#mkdir: .*#mkdir: <ERR>#
s#near line [0-9]+#near line N#g
s#: line [0-9]+: #: line N: #g
s#\.tmp\.[0-9]+#.tmp.<PID>#g
# the width of a box or a table follows the longest path in it: runs of spaces inside a line and at its end,
# and runs of dashes, are one
s#([^ ]) {2,}#\1 #g
s# +$##
s#-{4,}#---#g
# a long folder is cut with ... inside the header box (macOS temp folders are long): the line is one
s#^\| bench .* \|$#| bench <PATH> |#
