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
  sprue = "sha256:419e16afeb7ad1588faae91f9fd4dcf85cc35fb37717cc385d07d94604b48dbe"

  hilt = "sha256:a792017f4a9ff1e7e778b8bf7276f4e9d9ff8884439c07bcc54b4ed4eb2e1e76"

  swarf = "sha256:9066674b99e6d040e48b2986dd2fd14e9db0d9704e13a8be368a4b26567cb96a"

  delegator = "sha256:30b1757986ce213a8eecacbd7a463142a242b0f3932180796aad62c2f2ccc2fe"

  signing_service = "sha256:b7ef5f0ea7e035c183d69ae90c98f30a4e04b944dfbf7ccbf27608e1b904e461"

  plc = "sha256:ebb12470f6fc50906c0ed867d009a056e131db1a994b45d7c3f1c8d2eb26dee9"
}
