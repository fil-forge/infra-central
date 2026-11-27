# Pinned per service, by digest. A digest names one artifact and cannot move
# underneath a running service, so staging runs the build that was merged
# rather than whatever a rolling tag points at when a task restarts.
#
# Every image a service publishes from its main branch arrives here through a
# bump pull request that bump-deployed-image.yml opens and the bot merges. Each
# digest carries linux/arm64, which the tasks run on. Bump one by hand with
# scripts/set-pin.sh.
#
# The blank lines between the pins are what keeps two services' bumps from
# conflicting. Each bump rewrites one line, and git conflicts on changes to
# adjacent lines, so six consecutive pins made every pair of open bump pull
# requests a conflict waiting for the second one to merge.
image_digests = {
  sprue = "sha256:e9cd607c5a5e6f40ab893c18d5d8decfe2fd8acb2eb1957348e315712f86153d"

  hilt = "sha256:c9ffeef57ad856e65ead8f04901166b2803721b18ce0bbd9b186608e12f94fb6"

  swarf = "sha256:d1c065a8e7cb7f931a2f4baede24f8f9dde73bd22e258a72f89be7751ae292f1"

  delegator = "sha256:1c52f05005050601cea87b07b7ff071c8ce9d8dcf439de6382a92d0a6aafd654"

  signing_service = "sha256:6c17e7eb59ce72f082458c4601c3b720d064cfd4319bf122eee449ecc98adf28"

  plc = "sha256:ebb12470f6fc50906c0ed867d009a056e131db1a994b45d7c3f1c8d2eb26dee9"
}
