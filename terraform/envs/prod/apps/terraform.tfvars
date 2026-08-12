# Pinned per service, by digest. A digest names one artifact and cannot move
# underneath a running service, so a redeploy cannot silently change what runs.
#
# No values yet: prod is not set up, and the digests have to come from the
# images the services actually publish. A plan fails until they are filled in,
# which is the right outcome for a stage nobody has deployed.
#
# image_digests = {
#   sprue           = "sha256:..."
#   hilt            = "sha256:..."
#   swarf           = "sha256:..."
#   delegator       = "sha256:..."
#   signing_service = "sha256:..."
#   plc             = "sha256:..."
# }
