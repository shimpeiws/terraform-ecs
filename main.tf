resource "aws_instance" "example" {
  ami = "ami-0289fbf73734505e2"
  instance_type = "t3.micro"

  tags = {
    Name = "example"
  }
}
