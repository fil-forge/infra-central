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
  sprue = "sha256:8e000ed3e7fb3a09d53c4ce35de943d454b0528678fcc6250679d5a1cc1f226c"

  hilt = "sha256:88570ff1b9343a1a06967b0ee1161b01205446d0ad1d5c75f940914a6c2482f0"

  swarf = "sha256:65e5dec9dd669fde9018e23135c999882329031a8ac42f24c34350556d631f07"

  delegator = "sha256:06ede396eb1ed1ab56ecafc4ae754443ddd6f259b161e22e20264dfca5c5d839"

  signing_service = "sha256:4493534d96a4f7f202e58f8811b7258da7feda4d79e710473c903f99ace76a98"

  plc = "sha256:ebb12470f6fc50906c0ed867d009a056e131db1a994b45d7c3f1c8d2eb26dee9"
}
