# Two roles per service, both scoped to that service alone.
#
# The execution role pulls the image and reads secrets; the task role is what
# the running process uses. Keeping them separate means the application's own
# credentials cannot read the parameters it was started with.

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${local.name}-execution"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "execution_managed" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# The scoping that matters: /forge-central/<stage>/<service>/* and nothing
# else. A compromised sprue task cannot read hilt's AppRole secret_id, the
# delegator's transactor key, or the OpenBao root token.
data "aws_iam_policy_document" "execution_secrets" {
  statement {
    sid       = "ReadOwnParameters"
    actions   = ["ssm:GetParameters", "ssm:GetParameter"]
    resources = [local.ssm_prefix_arn]
  }

  statement {
    sid       = "DecryptOwnParameters"
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]

    # Bounds the grant to parameter decryption, so the key cannot be used to
    # read anything else it protects, such as OpenBao's storage.
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "execution_secrets" {
  name   = "read-own-secrets"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_secrets.json
}

resource "aws_iam_role" "task" {
  name               = "${local.name}-task"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

# Only sprue (S3) and the delegator (DynamoDB) need anything here. The other
# four get a role with no permissions at all, which is deliberate.
#
# for_each over the map, rather than count over a nullable string: the keys are
# known while planning even when a policy body is not, so a service still gets
# its policy when the permissions it grants name resources this same apply
# creates. OpenBao's seal policy names the KMS key, so this is the normal case.
resource "aws_iam_role_policy" "task" {
  for_each = var.task_policies

  name   = each.key
  role   = aws_iam_role.task.id
  policy = each.value
}
