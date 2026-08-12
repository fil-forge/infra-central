# Every ECR repository this project publishes to, one resource per image.
#
# Repositories live under the `forge-central/` prefix. A repository per image is
# what makes per-image push permissions, lifecycle policies and tag mutability
# possible; a single shared repository distinguished by tag forfeits all three.
#
# ---
#
# The repository holding the forge-provision Lambda image.
#
# One instance per account *and* region. ECR repositories are regional and
# Lambda pulls an image only from ECR in the same region as the function, so a
# stage in another region cannot reuse a repository from the first one. Stages
# sharing a region share this repository: they pin different digests, so they
# do not interfere.
#
# The repository name is the same in every region, which is what lets a stage's
# provision_image_repository_url differ only in the region part of the host.
#
# Nothing in this repository is tagged. `make publish` pushes by digest, a stage
# pins that digest, and the Lambda is deployed from it. IMMUTABLE therefore
# changes no behaviour today and only rejects a tag pushed by hand, which is the
# right answer for a repository whose only reference is a digest.
#
# A repository for a service image deployed by tag needs a deliberate decision
# instead of this one: there the tag decides what runs, so it has to be
# immutable, with an exclusion filter for any rolling tag a stage follows.

resource "aws_ecr_repository" "provision" {
  name                 = "forge-central/provision"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

# No lifecycle policy on purpose. Every image here is untagged, including the one
# each stage pins, so any expiry rule ECR can express would eventually delete a
# running function's image, and Lambda cannot recover from that. The images are a
# few tens of MB and a dev iteration loop is the only thing that grows the count,
# so prune by hand when it bothers you, checking each digest against the stages
# that pin one:
#
#   aws ecr list-images --repository-name forge-central/provision
