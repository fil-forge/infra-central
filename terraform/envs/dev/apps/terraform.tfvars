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
  sprue           = "sha256:dd4b4f93dfb9cfe4e493cd94c627e6f3f178ad3bc9454d2c9504b206f6cd0f73"
  hilt            = "sha256:87470e2a5ab30863e9e62e776639ea72c0cba93c42b9df874f32fd37a6acf5b4"
  swarf           = "sha256:6c6c209c7cc88ebd9ce4693db8f675dfeefea6635c438585bb7778f5ad25dfa4"
  delegator       = "sha256:1df0976e1682d60f71ad32b95025a972fb9f4c8b1df27b835d542424cf782a40"
  signing_service = "sha256:75435d72ebb7cff150548f656e8013962d14262fdb322181249412b79dec2ba5"
  plc             = "sha256:d68851e5f53ee6511ec628ecfbd4398d8ec55e4625f20c61e1bb74cf5ad17738"
}
