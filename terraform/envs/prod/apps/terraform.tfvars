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
  sprue = "sha256:bb5952828e9ef120c5a5a1ab8832ce1a8b42bb2cf9a9010a53f401db5599d767"

  hilt = "sha256:c52a523576b78822a6c6d453f4cbb49c94373345a6d916a1203958ae025af53b"

  swarf = "sha256:c4227532065411b1092ee00be18cada1e17485fa67b979ab4deae9be6177c75d"

  delegator = "sha256:4ab71ee18bf15651e37af6519ff90b82e644e47b10bbd22595e8c4af351bf00c"

  signing_service = "sha256:9ae0559fa1d3976fd16f40000687b6c059011b1780ff5861c573a3bb30ce5dce"

  plc = "sha256:ebb12470f6fc50906c0ed867d009a056e131db1a994b45d7c3f1c8d2eb26dee9"
}
