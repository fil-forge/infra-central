# Who may use the jump host and where it may connect. Change it with a pull
# request: add or remove a key, get it reviewed, then apply (docs/jump-host.md).
# Each key ends with a comment naming its owner.
ssh_public_keys = [
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPHe9EiFXhPstL43d0SV9JLgDKNgm1Q3//XsrslK9HlS hannahhoward",
  "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC6nHLsaJeBKhpOlhNrU7QU3xQRoEGlDLMujny4IMNUjzIBAmPSC6useMd4rzKx6vbFOuEC///PofYu9Ruo2Djvuzpa9byYuRUaHk1L8PElIBRrIEhVHHDDuTmayWGJ051T1rRwB0qtNNrA6Bg5r+7yqNAjWj45OHMoGgUtfx7QgxUsXKNP03shE82mtVX+h6HD3zfOTgU7XtY5BMXSp1HKc/T06gaEsNIJ3fKkH5tpyubP5Ld9hiqDG9v+w3tCSHKazOq+1wXTHWgH3RzwcpFIjqXvHZEb5gLLmuFhKeO9y32+5Vnd5qh/wR2Nv8tcgnZsb6CcIk4/GssXwr6wLfEt hannahhoward",
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB92gunRkjSlP4eN+C71Cizrn1lhalot+n/w+olF2uzo alanshaw",
  "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBLRg8XR5fuk+JlO1ZifY9XulHGblL9TGyzKJju3D7NqwLjh/4iQZRn9218HgUIJQ4sQ9+OY/T+WF8mToCQ4Zwg4= miroslav.bajtos",
  "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBBbyV0VKcQdB55d6gTbyRuO0GrrO8Xb0OuSNfYLNpECUbsbp95E/S50NbKq7oZaSr/p+mMvwhHJ8inamOnbMcMk= miroslav.bajtos",
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPZ4TqDyk2ZJRk+TUrlY1vhC8ggzdo8+uBTHqlvqUtHD frrist",
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIRwdlSOZqOV70J4E1SODa2HrT5OhBirnspxWgdGz+xm frrist",
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPTo0/JkbRyHI22TkIe0gvXRi3Mm+Uzr4RFc6NINZKqB pwagner",
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBSu1mp89/Oka6EizK4qeIkGbcSFfftif/nKw/xQKVdx peeja",
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOsTKpsBEfD7HLD+k26XLeEefsM0oBeZfDD52+vCJTZ5 dominick",
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOe0T/Gd4e8h7jiTfe3OUpgwCqadUNxyFq8T8VJ+/WUY srdjan",
  "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBmZR+qmIxiyy8X0/FPMw1fCo3MHi21/3Pz9rXx4mXnh srdjan",
]
destination_cidrs = ["162.43.174.98/32"] # the appliance the jump host relays to
