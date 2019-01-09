output "asg-name" {
  value = "${aws_autoscaling_group.ASG_inst.name}"
}
output "elb-hostname" {
  value = "${aws_alb.main_alb.dns_name}"
}
output "instance-SG-id" {
  value = "${aws_security_group.SG_EC2.id}"
}
output "launch-configuration" {
  value = "${aws_launch_configuration.inst_config.id}"
}



