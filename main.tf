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