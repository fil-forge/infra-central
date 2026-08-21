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
image_digests = {
  sprue           = "sha256:b513f0a2612d3ba72a46a994879078f792ddec371f94314c6a8062a8182d75d8"
  hilt            = "sha256:87470e2a5ab30863e9e62e776639ea72c0cba93c42b9df874f32fd37a6acf5b4"
  swarf           = "sha256:6c6c209c7cc88ebd9ce4693db8f675dfeefea6635c438585bb7778f5ad25dfa4"
  delegator       = "sha256:b83f860bf91b27d33673db4d6f2458902abef16aa4a7c567ab4e60fb6dd65966"
  signing_service = "sha256:b7ef5f0ea7e035c183d69ae90c98f30a4e04b944dfbf7ccbf27608e1b904e461"
  plc             = "sha256:ebb12470f6fc50906c0ed867d009a056e131db1a994b45d7c3f1c8d2eb26dee9"
}
