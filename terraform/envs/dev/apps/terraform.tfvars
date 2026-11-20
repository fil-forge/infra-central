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
  sprue = "sha256:c3ec713cad406b0375933a4703c97a711f64b501e7ec037f075ace295182ad47"

  hilt = "sha256:c419bc3208610be1660262d58a4ceae2f9a21576a7de74cd1ce8cfff4b6655c6"

  swarf = "sha256:e47a0fe51857195e484f0b6ed5cd1a95e8b0849e76450fb51e851281b00edd04"

  delegator = "sha256:4ac95ed1442a889a0471e778ce9e1e4d2533b5412ce1cb17fff2a7bbb737228e"

  signing_service = "sha256:e15b207903e6d84e97e2766e0cc736a34428c882952a5c4301372e51169d17f4"

  plc = "sha256:ebb12470f6fc50906c0ed867d009a056e131db1a994b45d7c3f1c8d2eb26dee9"
}
