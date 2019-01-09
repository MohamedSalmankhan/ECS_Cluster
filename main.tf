provider "aws" {
  region = "${var.region}"
}
resource "aws_vpc" "Terra_vpc" {
  cidr_block = "${var.vpc-cidr-block}"
  instance_tenancy = "default"
  tags {
    Name = "terra-vpc"
  }
}
data "aws_availability_zones" "available_az" {
}

resource "aws_subnet" "public_subnet" {
  count = "${var.azs-count}"
  vpc_id = "${aws_vpc.Terra_vpc.id}"
  availability_zone = "${data.aws_availability_zones.available_az.names[count.index]}"
  cidr_block = "${cidrsubnet(aws_vpc.Terra_vpc.cidr_block, 8, count.index)}"
  map_public_ip_on_launch = "true"
  tags {
    Name = "terra-public-sub"
  }
}
resource "aws_subnet" "private_subnet" {
  count = "${var.azs-count}"
  vpc_id = "${aws_vpc.Terra_vpc.id}"
  availability_zone = "${data.aws_availability_zones.available_az.names[count.index]}"
  cidr_block = "${cidrsubnet(aws_vpc.Terra_vpc.cidr_block, 8, count.index+4)}"
  map_public_ip_on_launch = "false"
  tags {
    Name = "terra-private-sub"
  }
}

resource "aws_eip" "EIP-NG" {
  vpc = true
}
resource "aws_nat_gateway" "NG" {
  allocation_id = "${aws_eip.EIP-NG.id}"
  subnet_id = "${element(aws_subnet.public_subnet.*.id, count.index)}"
}

resource "aws_internet_gateway" "IG" {
  vpc_id = "${aws_vpc.Terra_vpc.id}"
}

resource "aws_route_table" "route_IG" {
  vpc_id = "${aws_vpc.Terra_vpc.id}"

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = "${aws_internet_gateway.IG.id}"
  }
  tags {
    Name = "terra_route_IG"
  }
}
resource "aws_route_table_association" "route_public_sub" {
  count = "${var.azs-count}"
  route_table_id = "${aws_route_table.route_IG.id}"
  subnet_id = "${element(aws_subnet.public_subnet.*.id, count.index)}"
}

resource "aws_route_table" "route_NG" {
  vpc_id = "${aws_vpc.Terra_vpc.id}"
  route {
    cidr_block = "0.0.0.0/0"
    nat_gateway_id = "${aws_nat_gateway.NG.id}"
  }
  tags {
    Name = "terra_route_NG"
  }
}
resource "aws_route_table_association" "route_private_sub" {
  count = "${var.azs-count}"
  route_table_id = "${aws_route_table.route_NG.id}"
  subnet_id = "${element(aws_subnet.private_subnet.*.id, count.index)}"
}

resource "aws_security_group" "SG_ALB" {
  vpc_id = "${aws_vpc.Terra_vpc.id}"

  ingress {
    from_port = 80
    protocol = "tcp"
    to_port = 80
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags {
    Name = "terra_elb_sg"
  }
}
resource "aws_security_group" "SG_EC2" {
  vpc_id = "${aws_vpc.Terra_vpc.id}"

  ingress {
    description = "ssh port"
    from_port = 22
    to_port = 22
    protocol = "tcp"
    cidr_blocks = ["${var.admin-cidr}"]
  }
  ingress {
    protocol = "tcp"
    from_port = 31768
    to_port = 61000
    security_groups = ["${aws_security_group.SG_ALB.id}"]
  }
  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags {
    Name = "terra_ec2_sg"
  }
}

resource "aws_alb" "main_alb" {
  name = "terra-alb-ecs"
  subnets = ["${aws_subnet.public_subnet.*.id}"]
  security_groups = ["${aws_security_group.SG_ALB.id}"]
  enable_deletion_protection = false
  enable_http2 = true
  idle_timeout = 60
  tags{
    name = "terra-alb"
  }
}
resource "aws_alb_listener" "alb_action" {
  "default_action" {
    target_group_arn = "${aws_alb_target_group.alb_target.id}"
    type = "forward"
  }
  load_balancer_arn = "${aws_alb.main_alb.id}"
  port = 80
  protocol = "HTTP"
}
resource "aws_alb_target_group" "alb_target" {
  name = "alb-ecs-target"
  port = 8080
  protocol = "HTTP"
  proxy_protocol_v2 = false
  deregistration_delay = 300
  vpc_id = "${aws_vpc.Terra_vpc.id}"
  target_type = "instance"
  health_check {
    healthy_threshold = 2
    unhealthy_threshold = 10
    interval = 6
    timeout = 4
  }
}

resource "aws_iam_role" "ecs_role" {
  name = "terra-ecs-role"
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ecs.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}
resource "aws_iam_role_policy" "ecs_role_policy" {
  role = "${aws_iam_role.ecs_role.id}"
  policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:Describe*",
        "elasticloadbalancing:RegisterInstancesWithLoadBalancer",
        "elasticloadbalancing:RegisterTargets",
        "elasticloadbalancing:DeregisterInstancesFromLoadBalancer",
        "elasticloadbalancing:DeregisterTargets",
        "elasticloadbalancing:Describe*"
      ],
      "Resource": "*"
    }
  ]
}
POLICY
}

resource "aws_ecs_cluster" "ecs_main" {
  name = "terra-ecs-cluster"
  tags {
    name = "terra-ecs"
  }
}

data "template_file" "task_definition" {
  template = "${file("temp/task-definition.json")}"

  vars {
    image_url        = "tomcat:latest"
    container_name   = "hellotom"
    log_group_region = "${var.region}"
    log_group_name   = "${aws_cloudwatch_log_group.inst_hn_log.name}"
  }
}
resource "aws_ecs_task_definition" "ecs_task" {
  container_definitions = "${data.template_file.task_definition.rendered}"
  family = "terra-container-task"
}
resource "aws_ecs_service" "ecs_hn_service" {
  name = "terra_ecs_service"
  cluster = "${aws_ecs_cluster.ecs_main.id}"
  iam_role = "${aws_iam_role.ecs_role.name}"
  launch_type = "EC2"
  desired_count = 1
  task_definition = "${aws_ecs_task_definition.ecs_task.arn}"
  load_balancer {
    container_name = "hellotom"
    container_port = 8080
    target_group_arn = "${aws_alb_target_group.alb_target.id}"
  }
  depends_on = [
    "aws_iam_role_policy.ecs_role_policy",
    "aws_alb_listener.alb_action"
  ]
}


resource "aws_iam_role" "instance_role" {
  name = "terra-inst-ecs-role"
  force_detach_policies = false
  max_session_duration = 3600
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}
data "template_file" "instance_profile" {
  template = "${file("temp/instance-policy.json")}"

  vars {
    inst_log_group_arn = "${aws_cloudwatch_log_group.inst_hn_log.arn}"
    ecs_log_group_arn = "${aws_cloudwatch_log_group.ecs_log.arn}"
  }
}
resource "aws_iam_role_policy" "instance_role_policy" {
  name = "terra-inst-ecs-policy"
  policy = "${data.template_file.instance_profile.rendered}"
  role = "${aws_iam_role.instance_role.id}"
}
resource "aws_iam_instance_profile" "instance_ecs_prof" {
  name = "terra-inst-ecs-prof"
  role = "${aws_iam_role.instance_role.name}"
}

resource "aws_autoscaling_group" "ASG_inst" {
  name = "terra_ASG"
  launch_configuration = "${aws_launch_configuration.inst_config.name}"
  vpc_zone_identifier = ["${aws_subnet.public_subnet.*.id}"]
  max_size = "${var.asg_max}"
  min_size = "${var.asg_min}"
  desired_capacity = "${var.asg_desired}"
  protect_from_scale_in = false
}
data "aws_ami" "stable_coreos_ami" {
  most_recent = true

  filter {
    name   = "description"
    values = ["CoreOS Container Linux stable *"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["595879546273"] # CoreOS
}
resource "aws_launch_configuration" "inst_config" {
  name = "terra-inst"
  image_id = "${data.aws_ami.stable_coreos_ami.id}"
  instance_type = "t2.micro"
  key_name = "${var.key-name}"
  associate_public_ip_address = true
  enable_monitoring = true
  security_groups = ["${aws_security_group.SG_EC2.id}"]
  iam_instance_profile = "${aws_iam_instance_profile.instance_ecs_prof.name}"
  user_data = "${data.template_file.cloud_config.rendered}"
}

data "template_file" "cloud_config" {
  template = "${file("temp/cloud-config.yml")}"

  vars {
    aws_region         = "${var.region}"
    ecs_cluster_name   = "${aws_ecs_cluster.ecs_main.name}"
    ecs_log_level      = "info"
    ecs_agent_version  = "latest"
    ecs_log_group_name = "${aws_cloudwatch_log_group.ecs_log.name}"
  }
}


resource "aws_cloudwatch_log_group" "ecs_log" {
  name = "tf-ecs-log-grp"
  retention_in_days = 0
}
resource "aws_cloudwatch_log_group" "inst_hn_log" {
  name = "tf-inst-hn-log"
  retention_in_days = 0
}
