# -----------------------------------------------------------------------------------------
# VPC Configuration
# -----------------------------------------------------------------------------------------
module "vpc" {
  source                  = "./modules/vpc"
  vpc_name                = "vpc"
  vpc_cidr                = "10.0.0.0/16"
  azs                     = var.azs
  public_subnets          = var.public_subnets
  private_subnets         = var.private_subnets
  enable_dns_hostnames    = true
  enable_dns_support      = true
  create_igw              = true
  map_public_ip_on_launch = true
  enable_nat_gateway      = true
  single_nat_gateway      = false
  one_nat_gateway_per_az  = true
  tags = {
    Project     = "mlops-telco-customer-churn"
  }
}

# -----------------------------------------------------------------------------------------
# Load Balancer Configuration
# -----------------------------------------------------------------------------------------
module "lb" {
  source                     = "terraform-aws-modules/alb/aws"
  name                       = "lb"
  load_balancer_type         = "application"
  vpc_id                     = module.vpc.vpc_id
  subnets                    = module.vpc.public_subnets
  enable_deletion_protection = false
  drop_invalid_header_fields = true
  ip_address_type            = "ipv4"
  internal                   = false
  security_groups = [
    aws_security_group.lb_sg.id
  ]
  access_logs = {
    bucket = "${module.lb_logs.bucket}"
  }
  listeners = {
    lb_http_listener = {
      port     = 80
      protocol = "HTTP"
      forward = {
        target_group_key = "lb_target_group"
      }
    }
  }
  target_groups = {
    lb_target_group = {
      backend_protocol = "HTTP"
      backend_port     = 3000
      target_type      = "ip"
      health_check = {
        enabled             = true
        healthy_threshold   = 3
        interval            = 30
        path                = "/auth/signin"
        port                = 3000
        protocol            = "HTTP"
        unhealthy_threshold = 3
      }
      create_attachment = false
    }
  }
  tags = {
    Project = "mlops-telco-customer-churn"
  }
}

# -----------------------------------------------------------------------------------------
# Autoscaling configuration
# -----------------------------------------------------------------------------------------
module "autoscaling_policy" {
  source                    = "./modules/autoscaling"
  min_capacity              = 2
  max_capacity              = 10
  target_resource_id        = "service/${aws_ecs_cluster.carshub_cluster.name}/${module.carshub_frontend_ecs.name}"
  target_scalable_dimension = "ecs:service:DesiredCount"
  target_service_namespace  = "ecs"
  policies = [
    {
      name                    = "autoscaling-policy"
      adjustment_type         = "ChangeInCapacity"
      cooldown                = 60
      metric_aggregation_type = "Average"
      steps = [
        {
          metric_interval_lower_bound = 0
          metric_interval_upper_bound = 20
          scaling_adjustment          = 1
        },
        {
          metric_interval_lower_bound = 20
          scaling_adjustment          = 2
        }
      ]
    }
  ]
}

# -----------------------------------------------------------------------------------------
# ECR configuration
# -----------------------------------------------------------------------------------------
module "container_registry" {
  source               = "./modules/ecr"
  force_delete         = true
  scan_on_push         = false
  image_tag_mutability = "IMMUTABLE"
  bash_command         = "bash ${path.cwd}/../src/frontend/artifact_push.sh serving-repo ${var.region} http://${module.lb.lb_dns_name} ${module.media_cloudfront_distribution.domain_name}"
  name                 = "serving-repo"
}

# ---------------------------------------------------------------------
# ECS configuration
# ---------------------------------------------------------------------
module "ecs" {
  source       = "terraform-aws-modules/ecs/aws"
  cluster_name = "text-to-sql-cluster"
  default_capacity_provider_strategy = {
    FARGATE = {
      weight = 50
      base   = 20
    }
    FARGATE_SPOT = {
      weight = 50
    }
  }
  autoscaling_capacity_providers = {
    ASG = {
      auto_scaling_group_arn         = module.autoscaling.arn
      managed_draining               = "ENABLED"
      managed_termination_protection = "ENABLED"
      managed_scaling = {
        maximum_scaling_step_size = 5
        minimum_scaling_step_size = 1
        status                    = "ENABLED"
        target_capacity           = 60
      }
    }
  }

  services = {
    ecs-frontend = {
      cpu    = 1024
      memory = 4096
      # Container definition(s)
      container_definitions = {
        fluent-bit = {
          cpu       = 512
          memory    = 1024
          essential = true
          image     = nonsensitive(data.aws_ssm_parameter.fluentbit.value)
          user      = "0"
          firelensConfiguration = {
            type = "fluentbit"
          }
          memoryReservation                      = 50
          cloudwatch_log_group_retention_in_days = 30
        }

        ecs_frontend = {
          cpu       = 1024
          memory    = 2048
          essential = true
          image     = "${module.container_registry.repository_url}:latest"
          placementStrategy = [
            {
              type  = "spread",
              field = "attribute:ecs.availability-zone"
            }
          ]
          healthCheck = {
            command = ["CMD-SHELL", "curl -f http://localhost:3000/auth/signin || exit 1"]
          }
          ulimits = [
            {
              name      = "nofile"
              softLimit = 65536
              hardLimit = 65536
            }
          ]
          portMappings = [
            {
              name          = "ecs-frontend"
              containerPort = 3000
              hostPort      = 3000
              protocol      = "tcp"
            }
          ]
          environment = [
            {
              name  = "BASE_URL"
              value = "${module.backend_lb.dns_name}"
            }
          ]
          capacity_provider_strategy = {
            ASG = {
              base              = 20
              capacity_provider = "ASG"
              weight            = 50
            }
          }
          readonlyRootFilesystem = false
          dependsOn = [{
            containerName = "fluent-bit"
            condition     = "START"
          }]
          enable_cloudwatch_logging = false
          logConfiguration = {
            logDriver = "awsfirelens"
            options = {
              Name                    = "firehose"
              region                  = var.region
              delivery_stream         = "ecs-stream"
              log-driver-buffer-limit = "2097152"
            }
          }
          memoryReservation = 100
          restartPolicy = {
            enabled              = true
            ignoredExitCodes     = [1]
            restartAttemptPeriod = 60
          }
        }
      }
      load_balancer = {
        service = {
          target_group_arn = module.lb.target_groups["lb_target_group"].arn
          container_name   = "ecs-frontend"
          container_port   = 3000
        }
      }
      subnet_ids                    = module.vpc.private_subnets
      vpc_id                        = module.vpc.vpc_id
      availability_zone_rebalancing = "ENABLED"
    }    
  }
}