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
  sprue = "sha256:8e72c0eb208d327891207f2b53ffabcfed2e34850def8b78774637230a13daa3"

  hilt = "sha256:51ffa8aa153bc1895294a3290bd0b8a5cfdf1fa7d1b5d8ddb9139b04e5c94903"

  swarf = "sha256:c4227532065411b1092ee00be18cada1e17485fa67b979ab4deae9be6177c75d"

  delegator = "sha256:ec178af506f7cd5ee679621db88ddfbc65fd95503fdfacb159810f034a9aee71"

  signing_service = "sha256:e15b207903e6d84e97e2766e0cc736a34428c882952a5c4301372e51169d17f4"

  plc = "sha256:ebb12470f6fc50906c0ed867d009a056e131db1a994b45d7c3f1c8d2eb26dee9"
}
