# One RDS Postgres instance shared by every service, each with its own database
# and owning role.
#
# The roles and databases themselves are not Terraform resources. HCP Terraform
# runs outside the VPC and cannot reach RDS, so the provision Lambda creates
# them from inside the private subnets instead.

locals {
  name = "fc-${var.stage}"
}

resource "aws_db_subnet_group" "this" {
  name       = local.name
  subnet_ids = var.subnet_ids

  tags = { Name = local.name }
}

resource "aws_db_instance" "this" {
  identifier     = local.name
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = null # databases are created per service by the provision Lambda
  username = var.master_username

  # RDS generates the master password and keeps it in Secrets Manager, so it
  # never appears in Terraform state or in a variable file. The provision
  # Lambda reads it from there when it creates the per-service roles.
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.security_group_id]
  publicly_accessible    = false

  multi_az = var.multi_az

  backup_retention_period = var.backup_retention_days
  copy_tags_to_snapshot   = true

  # OpenBao stores its data here, so losing this instance means losing every
  # regional appliance's ability to unseal.
  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${local.name}-final"

  auto_minor_version_upgrade   = true
  performance_insights_enabled = var.performance_insights_enabled

  tags = { Name = local.name }
}
