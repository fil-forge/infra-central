# Pinned per service, by digest. A digest names one artifact and cannot move
# underneath a running service, so staging runs the build that was promoted
# rather than whatever a rolling tag points at when a task restarts.
#
# Seeded from the digests dev ran when staging was created. Promote later
# versions here in a deliberate pull request after they are healthy in dev.
# Copy the reviewed digest from dev's terraform.tfvars; each digest carries
# linux/arm64, which the tasks run on.
#
# The blank lines between the pins are what keeps two services' bumps from
# conflicting. Each bump rewrites one line, and git conflicts on changes to
# adjacent lines, so six consecutive pins made every pair of open bump pull
# requests a conflict waiting for the second one to merge.
image_digests = {
  sprue = "sha256:b6a4f84b497684ef4a53e53a3bea3a49d7b573742d32f7bbb15ad62c1d84b27e"

  hilt = "sha256:3992eef211db014e02a45c696692ddbc2dc96f4390877e0c1a768004eb8c3401"

  swarf = "sha256:1edd6ed2610a1c4fdb288ab6e21be2e56897af9aa513f68188c729fbd406c581"

  delegator = "sha256:30b1757986ce213a8eecacbd7a463142a242b0f3932180796aad62c2f2ccc2fe"

  signing_service = "sha256:b7ef5f0ea7e035c183d69ae90c98f30a4e04b944dfbf7ccbf27608e1b904e461"

  plc = "sha256:ebb12470f6fc50906c0ed867d009a056e131db1a994b45d7c3f1c8d2eb26dee9"
}
