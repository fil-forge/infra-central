# shellcheck shell=bash
# read_appliances <tfvars> — print "<region> <address>" for each entry of the
# appliances map in a platform root's terraform.tfvars, one entry per line as
# `tofu fmt` leaves it. A missing or empty map prints nothing.
read_appliances() {
  awk '
    /^appliances *= *\{ *\}/ { exit }
    /^appliances *= *\{/     { inside = 1; next }
    inside && /^\}/          { exit }
    inside {
      sub(/#.*/, ""); gsub(/[ \t"]/, "")
      if ($0 == "") next
      split($0, entry, "=")
      print entry[1], entry[2]
    }
  ' "$1"
}
