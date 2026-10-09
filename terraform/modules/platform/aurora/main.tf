# One Aurora PostgreSQL cluster shared by every service, each with its own
# database and owning role: the same shape as the RDS instance in ../database,
# with a writer and a reader in different availability zones. ../compat-database
# runs a second, named copy for the compatibility server's database.
#
# The roles and databases themselves are not Terraform resources. HCP Terraform
# runs outside the VPC and cannot reach the cluster, so the provision Lambda
# creates them from inside the private subnets instead.

locals {
  name          = coalesce(var.name, "fc-${var.stage}")
  engine_family = "aurora-postgresql${split(".", var.engine_version)[0]}"
}

resource "aws_db_subnet_group" "this" {
  name       = local.name
  subnet_ids = var.subnet_ids

  tags = { Name = local.name }
}

# Aurora PostgreSQL 16 defaults rds.force_ssl to off, where RDS PostgreSQL 16
# and Aurora 17 default it to on. plc connects with sslmode=no-verify (see
# cmd/provision/seed.go), which encrypts only when the server insists, so the
# setting is stated here rather than inherited.
resource "aws_rds_cluster_parameter_group" "this" {
  name   = "${local.name}-${local.engine_family}"
  family = local.engine_family

  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot"
  }

  tags = { Name = local.name }
}

resource "aws_rds_cluster" "this" {
  cluster_identifier = local.name
  engine             = "aurora-postgresql"
  engine_version     = var.engine_version

  # storage_type is left unset, which is Aurora Standard: I/O is billed per
  # request. The test run's I/O rate decides whether I/O-Optimized
  # ("aurora-iopt1") is cheaper; AWS allows a switch once every 30 days.
  storage_encrypted = true
  kms_key_id        = var.kms_key_arn

  database_name   = null # databases are created per service by the provision Lambda
  master_username = var.master_username

  # Aurora generates the master password and keeps it in Secrets Manager, so it
  # never appears in Terraform state or in a variable file. The provision
  # Lambda reads it from there when it creates the per-service roles.
  manage_master_user_password = true

  db_subnet_group_name            = aws_db_subnet_group.this.name
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.this.name
  vpc_security_group_ids          = [var.security_group_id]

  backup_retention_period = var.backup_retention_days
  copy_tags_to_snapshot   = true

  # OpenBao stores its data here, so losing this cluster means losing every
  # regional appliance's ability to unseal.
  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${local.name}-final"

  tags = { Name = local.name }
}

# The subnet group spans one subnet per zone. Instance N goes in zone N, so the
# reader never shares the writer's zone.
data "aws_subnet" "this" {
  count = length(var.subnet_ids)
  id    = var.subnet_ids[count.index]
}

resource "aws_rds_cluster_instance" "this" {
  count = var.instance_count

  identifier         = "${local.name}-${count.index + 1}"
  cluster_identifier = aws_rds_cluster.this.id
  engine             = aws_rds_cluster.this.engine
  engine_version     = aws_rds_cluster.this.engine_version
  instance_class     = var.instance_class
  availability_zone  = data.aws_subnet.this[count.index % length(data.aws_subnet.this)].availability_zone

  publicly_accessible = false

  # The engine version is pinned to a minor release and moves only through a
  # reviewed change. The provider keeps a major-only version in state when AWS
  # upgrades the minor underneath it, but it does not do the same for a full
  # version, so automatic upgrades would leave every later plan asking for a
  # downgrade.
  auto_minor_version_upgrade = false

  performance_insights_enabled = var.performance_insights_enabled

  # Stated rather than left to the provider, so neither a console change nor a
  # default moving underneath us can put the instance on paid retention. Null
  # when the feature is off, which is what the API expects.
  performance_insights_retention_period = var.performance_insights_enabled ? 7 : null

  tags = { Name = "${local.name}-${count.index + 1}" }
}

# Aurora reports the encrypting key by ID, while an IAM policy naming it in
# resources needs the ARN. The data source accepts either form, so this keeps
# working if Aurora changes what it reports.
data "aws_kms_key" "master_secret" {
  key_id = aws_rds_cluster.this.master_user_secret[0].kms_key_id
}
