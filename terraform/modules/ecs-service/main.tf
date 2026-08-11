# One Forge service: task definition, service, ALB routing, DNS and IAM.
#
# Two things here are less obvious than they look.
#
# The entrypoint wrapper exists because ECS injects secrets as environment
# variables, while hilt and swarf accept their identity key only as a file path
# and the delegator's UCAN proofs are file-only in current code. Rather than
# mounting a volume or shipping a sidecar, the container writes what it needs to
# a tmpfs at startup and then execs the real process.
#
# The IAM scoping is per service, not per stage. Each execution role can read
# only /forge/<stage>/<service>/*, so a compromised sprue task cannot read
# hilt's AppRole secret_id or the delegator's transactor key.

locals {
  name = "forge-${var.stage}-${var.service}"

  # Every file-borne secret lands in one directory, so the mount is a single
  # known path rather than something derived from the caller's filenames.
  secret_dir = "/run/forge"

  # format() rather than interpolation because these are *shell* variable
  # references: the container expands $IDENTITY_PEM at startup, Terraform must
  # not try to. %% is a literal percent for printf.
  file_writes = [
    for env_var, filename in var.secret_files :
    format("printf '%%s' \"$%s\" > %s/%s && chmod 400 %s/%s",
    env_var, local.secret_dir, filename, local.secret_dir, filename)
  ]

  wrapper_prelude = length(var.secret_files) > 0 ? join(" && ", concat(
    [format("umask 077 && mkdir -p %s", local.secret_dir)],
    local.file_writes,
  )) : ""

  wrapped_command = var.shell_command == null ? null : (
    local.wrapper_prelude == "" ? var.shell_command : "${local.wrapper_prelude} && exec ${var.shell_command}"
  )

  ssm_prefix_arn = "arn:aws:ssm:${var.region}:${var.account_id}:parameter/forge/${var.stage}/${var.service}/*"
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/forge/${var.stage}/${var.service}"
  retention_in_days = var.log_retention_days
}

resource "aws_ecs_task_definition" "this" {
  family                   = local.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.cpu_architecture
  }

  # Fargate has no tmpfs, so this is task ephemeral storage. It is AES-256
  # encrypted and destroyed with the task, and it exists only when the service
  # actually has file-borne secrets.
  dynamic "volume" {
    for_each = length(var.secret_files) > 0 ? [1] : []

    content {
      name = "secrets"
    }
  }

  container_definitions = jsonencode([
    merge(
      {
        name      = var.service
        image     = var.image
        essential = true

        portMappings = [{
          containerPort = var.container_port
          protocol      = "tcp"
        }]

        environment = [
          for key, value in var.environment : { name = key, value = value }
        ]

        secrets = [
          for key, arn in var.secrets : { name = key, valueFrom = arn }
        ]

        logConfiguration = {
          logDriver = "awslogs"
          options = {
            "awslogs-group"         = aws_cloudwatch_log_group.this.name
            "awslogs-region"        = var.region
            "awslogs-stream-prefix" = var.service
          }
        }

        # ECS restarts an unhealthy container without waiting for the ALB to
        # drain it, which matters most for the services with no ALB route.
        healthCheck = {
          command     = ["CMD-SHELL", "${var.health_check_command} || exit 1"]
          interval    = 30
          timeout     = 5
          retries     = 3
          startPeriod = var.health_check_start_period
        }
      },
      local.wrapped_command == null ? {} : {
        entryPoint = ["/bin/sh", "-c"]
        command    = [local.wrapped_command]
      },
      length(var.secret_files) == 0 ? {} : {
        mountPoints = [{
          sourceVolume  = "secrets"
          containerPath = local.secret_dir
          readOnly      = false
        }]
      },
    )
  ])
}

resource "aws_ecs_service" "this" {
  name            = local.name
  cluster         = var.cluster_arn
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  # Migrations run in-process via goose for sprue, hilt, swarf and plc, and
  # concurrent starts race on the goose advisory lock. At desired_count 1 that
  # cannot happen; above it, set the service's *_SKIP_MIGRATIONS and run them
  # deliberately.
  deployment_minimum_healthy_percent = var.desired_count > 1 ? 100 : 0
  deployment_maximum_percent         = 200

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [var.security_group_id]
    assign_public_ip = false
  }

  dynamic "load_balancer" {
    for_each = var.hostname == null ? [] : [1]

    content {
      target_group_arn = aws_lb_target_group.this[0].arn
      container_name   = var.service
      container_port   = var.container_port
    }
  }

  dynamic "service_registries" {
    for_each = var.register_internal ? [1] : []

    content {
      registry_arn = aws_service_discovery_service.this[0].arn
    }
  }

  # Gives the container time to start before the ALB starts counting failures,
  # which the Postgres-backed services need for their migrations.
  health_check_grace_period_seconds = var.hostname == null ? null : var.health_check_start_period

  depends_on = [aws_lb_listener_rule.this]
}
