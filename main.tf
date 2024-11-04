# VPC Setup
resource "aws_vpc" "db_monitor_vpc" {
  cidr_block = var.vpc_cidr
  enable_dns_support = true
  enable_dns_hostnames = true

  tags = {
    Name = "db-monitor-vpc"
  }
}

# Public Subnets
resource "aws_subnet" "public_subnet_a" {
  vpc_id                  = aws_vpc.db_monitor_vpc.id
  cidr_block              = var.public_subnet_cidrs[0]
  availability_zone       = var.availability_zones[0]
  map_public_ip_on_launch = true

  tags = {
    Name = "public-subnet-a"
  }
}

resource "aws_subnet" "public_subnet_b" {
  vpc_id                  = aws_vpc.db_monitor_vpc.id
  cidr_block              = var.public_subnet_cidrs[1]
  availability_zone       = var.availability_zones[1]
  map_public_ip_on_launch = true

  tags = {
    Name = "public-subnet-b"
  }
}

# Private Subnet
resource "aws_subnet" "private_subnet_a" {
  vpc_id            = aws_vpc.db_monitor_vpc.id
  cidr_block        = var.private_subnet_cidrs[0]
  availability_zone = var.availability_zones[0]

  tags = {
    Name = "private-subnet-a"
  }
}

resource "aws_subnet" "private_subnet_b" {
  vpc_id            = aws_vpc.db_monitor_vpc.id
  cidr_block        = var.private_subnet_cidrs[1]
  availability_zone = var.availability_zones[1]

  tags = {
    Name = "private-subnet-b"
  }
}

# RDS Instance
resource "aws_db_instance" "db_monitor_rds" {
  identifier               = var.db_instance_name
  engine                   = var.db_engine
  engine_version           = var.db_engine_version
  instance_class           = var.db_instance_class
  allocated_storage        = var.db_allocated_storage
  storage_type             = "gp2"
  publicly_accessible      = false
  multi_az                 = false
  db_subnet_group_name     = aws_db_subnet_group.db_monitor_subnet_group.name
  vpc_security_group_ids   = [aws_security_group.db_monitor_sg.id]

  username                 = "admin"
  password                 = var.db_password
  apply_immediately        = true

  auto_minor_version_upgrade = true
  storage_encrypted          = true
  skip_final_snapshot        = true
}

# Security Group for RDS
resource "aws_security_group" "db_monitor_sg" {
  name   = "db_monitor_rds_sg"
  vpc_id = aws_vpc.db_monitor_vpc.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# DB Subnet Group
resource "aws_db_subnet_group" "db_monitor_subnet_group" {
  name       = "db-monitor-subnet-group"
  subnet_ids = [aws_subnet.private_subnet_a.id, aws_subnet.private_subnet_b.id]

  tags = {
    Name = "db-monitor-subnet-group"
  }
}

# ECS Cluster
resource "aws_ecs_cluster" "db_monitor_cluster" {
  name = "db_monitor_cluster"
}

# Default Security Group for ECS Cluster
resource "aws_security_group" "ecs_default_sg" {
  name_prefix = "ecs-default-sg"
  vpc_id      = aws_vpc.db_monitor_vpc.id

  # Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "ecs-default-security-group"
  }
}

# EC2 Instance for ECS
resource "aws_instance" "ecs_instance" {
  ami               = "ami-00f7e5c52c0f43726"
  instance_type     = "t2.micro"
  subnet_id         = aws_subnet.public_subnet_a.id
  security_groups   = [aws_security_group.ecs_default_sg.id]
  iam_instance_profile = aws_iam_instance_profile.ecs_agent.name

  associate_public_ip_address = null

  user_data = base64encode(<<-EOF
              #!/bin/bash
              echo ECS_CLUSTER=${aws_ecs_cluster.db_monitor_cluster.name} >> /etc/ecs/ecs.config
              EOF
  )

  tags = {
    Name = "ecs-instance"
  }
}

# IAM Role for ECS
resource "aws_iam_role" "ecs_agent" {
  name = "ecs-agent"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

# Attach ECS Policy to Role
resource "aws_iam_role_policy_attachment" "ecs_agent" {
  role       = aws_iam_role.ecs_agent.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

# Create Instance Profile
resource "aws_iam_instance_profile" "ecs_agent" {
  name = "ecs-agent"
  role = aws_iam_role.ecs_agent.name
}

# Update RDS Security Group to allow access from ECS instances
resource "aws_security_group_rule" "rds_ingress" {
  type                     = "ingress"
  from_port                = 3306
  to_port                  = 3306
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.ecs_default_sg.id
  security_group_id        = aws_security_group.db_monitor_sg.id
}

# Task Definition for phpMyAdmin
resource "aws_ecs_task_definition" "phpmyadmin" {
  family                = "td-phpmyadmin"
  container_definitions = jsonencode([
    {
      name         = "phpmyadmin"
      image        = "docker.io/phpmyadmin:latest"
      cpu          = 224
      memory       = 182
      essential    = true
      
      portMappings = [
        {
          containerPort = 80
          hostPort     = 8080
          protocol     = "tcp"
        }
      ]

      environment = [
        {
          name  = "PMA_HOST"
          value = aws_db_instance.db_monitor_rds.endpoint
        }
      ]

      mountPoints = []
      volumesFrom = []
    }
  ])

  # Use EC2 launch type
  requires_compatibilities = ["EC2"]
  network_mode            = "bridge"  # Default for Linux EC2 instances
  
  # Task-level resource limits
  memory = 182  # MiB
  cpu    = 224  # CPU units
}

# Update ECS security group to allow inbound traffic on port 8080
resource "aws_security_group_rule" "ecs_phpmyadmin_ingress" {
  type              = "ingress"
  from_port         = 8080
  to_port           = 8080
  protocol          = "tcp"
  cidr_blocks       = [var.my_ip]  # Replace with your IP
  security_group_id = aws_security_group.ecs_default_sg.id
  description       = "Allow phpMyAdmin access from my IP"
}

# ECS Service for phpMyAdmin
resource "aws_ecs_service" "phpmyadmin" {
  name            = "phpmyadmin"
  cluster         = aws_ecs_cluster.db_monitor_cluster.id
  task_definition = aws_ecs_task_definition.phpmyadmin.arn
  desired_count   = 1
  
  # Use EC2 launch type
  launch_type = "EC2"
}

# EFS File System for Metabase
resource "aws_efs_file_system" "metabase_efs" {
  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }

  tags = {
    Name = "metabase-efs"
  }
}

# EFS Mount Targets in both subnets
resource "aws_efs_mount_target" "metabase_mount_a" {
  file_system_id  = aws_efs_file_system.metabase_efs.id
  subnet_id       = aws_subnet.private_subnet_a.id
  security_groups = [aws_security_group.db_monitor_sg.id]
}

resource "aws_efs_mount_target" "metabase_mount_b" {
  file_system_id  = aws_efs_file_system.metabase_efs.id
  subnet_id       = aws_subnet.private_subnet_b.id
  security_groups = [aws_security_group.db_monitor_sg.id]
}

# Task Definition for Metabase
resource "aws_ecs_task_definition" "metabase" {
  family                   = "td-metabase"
  container_definitions    = jsonencode([{
    name                   = "metabase"
    image                  = "metabase/metabase:latest"
    cpu                    = 800
    memory                 = 800
    essential              = true

    portMappings = [
      {
        containerPort     = 3000
        hostPort          = 3000
        protocol          = "tcp"
      }
    ]

    mountPoints = [
      {
        sourceVolume      = "efs-storage"
        containerPath     = "/metabase-data"
        readOnly          = false
      }
    ]
  }])


  requires_compatibilities = ["EC2"]
  network_mode             = "bridge"
}

# Security Group rule for Metabase access
resource "aws_security_group_rule" "metabase_ingress" {
  type              = "ingress"
  from_port         = 3000
  to_port           = 3000
  protocol          = "tcp"
  cidr_blocks       = [var.my_ip]  # Replace with your IP
  security_group_id = aws_security_group.ecs_default_sg.id
  description       = "Allow Metabase access from my IP"
}

# ECS Service for Metabase
resource "aws_ecs_service" "metabase" {
  name            = "metabase"
  cluster         = aws_ecs_cluster.db_monitor_cluster.id
  task_definition = aws_ecs_task_definition.metabase.arn
  desired_count   = 1
  launch_type     = "EC2"
}
