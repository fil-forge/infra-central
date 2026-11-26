# Pinned per service, by digest. A digest names one artifact and cannot move
# underneath a running service, so what dev runs is what was merged rather than
# whatever a rolling tag pointed at when a task last restarted.
#
# These are the manifest indexes each repository's `main` tag pointed at when
# the stage was first brought up. Each carries linux/arm64, which the tasks run
# on. Bump one by reading the digest its tag now names:
#
#   crane digest ghcr.io/fil-forge/sprue:main
#
# The blank lines between the pins are what keeps two services' bumps from
# conflicting. Each bump rewrites one line, and git conflicts on changes to
# adjacent lines, so six consecutive pins made every pair of open bump pull
# requests a conflict waiting for the second one to merge.
image_digests = {
  sprue = "sha256:7f551f54b4fe92622eb44d88b82a6b2dd8654546b3da15271ce3025734f00ad1"

  hilt = "sha256:1c2a303e341c1c61553c7cf3c230fbe3091bb113cef93508c0e2b5d76e415230"

  swarf = "sha256:c4227532065411b1092ee00be18cada1e17485fa67b979ab4deae9be6177c75d"

  delegator = "sha256:db87b2f75acaa79b6cfb95c87332268addc916796f75617a03ff0b60f7937384"

  signing_service = "sha256:8e065b7ab54167b269878bbded56faa3527b744e6d2ba4bf03a773044db0197e"

  plc = "sha256:ebb12470f6fc50906c0ed867d009a056e131db1a994b45d7c3f1c8d2eb26dee9"
}
