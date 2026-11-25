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
  sprue = "sha256:bb5952828e9ef120c5a5a1ab8832ce1a8b42bb2cf9a9010a53f401db5599d767"

  hilt = "sha256:f59d013a474613e40a847e92b21edcdbb7708ad911ad154a091a6c0528615ccd"

  swarf = "sha256:c4227532065411b1092ee00be18cada1e17485fa67b979ab4deae9be6177c75d"

  delegator = "sha256:db87b2f75acaa79b6cfb95c87332268addc916796f75617a03ff0b60f7937384"

  signing_service = "sha256:8e065b7ab54167b269878bbded56faa3527b744e6d2ba4bf03a773044db0197e"

  plc = "sha256:ebb12470f6fc50906c0ed867d009a056e131db1a994b45d7c3f1c8d2eb26dee9"
}
