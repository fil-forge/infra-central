# The provision Lambda's role. This is the one principal that can read across
# every service prefix, because it is the one thing that writes them all.

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = local.name
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy_attachment" "vpc_access" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

data "aws_iam_policy_document" "this" {
  statement {
    sid = "ManageStageParameters"

    actions = [
      "ssm:PutParameter",
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
      "ssm:DeleteParameters",
    ]

    resources = [
      "arn:aws:ssm:${var.region}:${var.account_id}:parameter/forge-central/${var.stage}/*",
    ]
  }

  # SecureStrings take the account's AWS-managed SSM key, which no stage owns
  # and no destroy can remove, so the parameters stay readable after the stage
  # that minted them is gone. The key has no stable ARN to name here without a
  # lookup that fails in an account which has never written one, so the grant
  # is bounded by the service that may use it instead.
  statement {
    sid       = "EncryptAndDecryptParameters"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.region}.amazonaws.com"]
    }
  }

  # The RDS master credentials, which Terraform never sees because
  # manage_master_user_password keeps them out of state.
  statement {
    sid       = "ReadRDSMasterSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.db_master_secret_arn]
  }

  statement {
    sid       = "DecryptRDSMasterSecret"
    actions   = ["kms:Decrypt"]
    resources = [var.db_master_secret_kms_key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${var.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "this" {
  name   = "provision"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.this.json
}
