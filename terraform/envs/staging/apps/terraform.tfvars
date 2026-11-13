# Pinned per service, by digest. A digest names one artifact and cannot move
# underneath a running service, so staging runs the build that was promoted
# rather than whatever a rolling tag points at when a task restarts.
#
# Seeded from the digests dev ran when staging was created. Later versions
# arrive by merging the "Promote dev's images to staging" pull request, which
# scripts/promote.sh keeps open; each digest carries linux/arm64, which the
# tasks run on.
#
# The blank lines between the pins are what keeps two services' bumps from
# conflicting. Each bump rewrites one line, and git conflicts on changes to
# adjacent lines, so six consecutive pins made every pair of open bump pull
# requests a conflict waiting for the second one to merge.
image_digests = {
  sprue = "sha256:8e000ed3e7fb3a09d53c4ce35de943d454b0528678fcc6250679d5a1cc1f226c"

  hilt = "sha256:3a0a3c77f8ceef183a9568eb39b272cf101bcb563d95fb73fd9634bc5a8c6c01"

  swarf = "sha256:65e5dec9dd669fde9018e23135c999882329031a8ac42f24c34350556d631f07"

  delegator = "sha256:06ede396eb1ed1ab56ecafc4ae754443ddd6f259b161e22e20264dfca5c5d839"

  signing_service = "sha256:4493534d96a4f7f202e58f8811b7258da7feda4d79e710473c903f99ace76a98"

  plc = "sha256:ebb12470f6fc50906c0ed867d009a056e131db1a994b45d7c3f1c8d2eb26dee9"
}
