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
  sprue = "sha256:dac4f50876d62fd1988f7384c614387fa23a2c60e5fe4283d4cc6296c555ec22"

  hilt = "sha256:394c463740953f8f26d5b2ae84eb122582913612fd8998a130732168d828a711"

  swarf = "sha256:34f724d70ba2255fd5ef8a1cb498d9b25e327c06da8c1a1d02f69eba35996901"

  delegator = "sha256:7fb4eb518859b62c11ddafaa3b88cdcf8c9623e8d7a68a366a6af647479f19b3"

  signing_service = "sha256:4493534d96a4f7f202e58f8811b7258da7feda4d79e710473c903f99ace76a98"

  plc = "sha256:ebb12470f6fc50906c0ed867d009a056e131db1a994b45d7c3f1c8d2eb26dee9"
}
