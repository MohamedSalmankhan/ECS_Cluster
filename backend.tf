terraform {
  backend "s3" {
    bucket = "tf-task-salman-ebiz"
    key    = "task3/tf-backend"
    region = "us-east-1"
  }
}
