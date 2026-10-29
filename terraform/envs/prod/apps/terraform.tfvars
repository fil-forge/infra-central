# Pinned per service, by digest. A digest names one artifact and cannot move
# underneath a running service, so a redeploy cannot silently change what runs.
#
# Seeded from the digests staging ran when prod was created. Later versions
# arrive by merging the "Promote staging's images to prod" pull request, which
# scripts/promote.sh keeps open.
#
# The blank lines between the pins are what keeps two services' bumps from
# conflicting. Each bump rewrites one line, and git conflicts on changes to
# adjacent lines.
image_digests = {
  sprue = "sha256:dac4f50876d62fd1988f7384c614387fa23a2c60e5fe4283d4cc6296c555ec22"

  hilt = "sha256:147557d59ba50dcaf5f9ec13de44307c5c97a29663acdecdf77ca411ab8f13be"

  swarf = "sha256:87d48f8d7585ec65d11819bc2da836ac84fbae7b062a8ab941f678a2c4d93b35"

  delegator = "sha256:7fb4eb518859b62c11ddafaa3b88cdcf8c9623e8d7a68a366a6af647479f19b3"

  signing_service = "sha256:4493534d96a4f7f202e58f8811b7258da7feda4d79e710473c903f99ace76a98"

  plc = "sha256:ebb12470f6fc50906c0ed867d009a056e131db1a994b45d7c3f1c8d2eb26dee9"
}
