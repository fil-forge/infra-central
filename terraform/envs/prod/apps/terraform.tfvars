# Pinned per service. Every repo publishes sha-<short> tags; a rolling tag here
# would mean a redeploy could silently change what is running.
image_tags = {
  sprue           = "sha-5e20d47"
  hilt            = "sha-c6afc4f"
  swarf           = "sha-695ba4a"
  delegator       = "sha-2ca7ff2"
  signing_service = "sha-d7c06ad"
  plc             = "main"
}
