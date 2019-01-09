variable "region" {
  default = "us-east-1"
}
variable "vpc-cidr-block" {
  default = "10.10.0.0/16"
}
variable "azs-count" {
  default = 2
}
variable "admin-cidr" {
}
variable "key-name" {
}
variable "asg_min" {
  default = 1
}
variable "asg_max" {
  default = 2
}
variable "asg_desired" {
  default = 1
}