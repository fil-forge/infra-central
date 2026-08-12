# The ECR repository holding the forge-provision Lambda image.
#
# One instance per account *and* region. ECR repositories are regional and
# Lambda pulls an image only from ECR in the same region as the function, so a
# stage in another region cannot reuse a repository from the first one. Stages
# sharing a region share this repository: they pin different digests, so they
# do not interfere.
#
# The repository name is the same in every region, which is what lets a stage's
# provision_image_repository_url differ only in the region part of the host.

resource "aws_ecr_repository" "provision" {
  name                 = "forge-provision"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

# Untagged images accumulate quickly when iterating: every `make publish` from
# a dev box replaces the sha- tag and orphans the previous manifest.
resource "aws_ecr_lifecycle_policy" "provision" {
  repository = aws_ecr_repository.provision.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire untagged images after 14 days"
      selection = {
        tagStatus   = "untagged"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = 14
      }
      action = { type = "expire" }
    }]
  })
}
