provider "aws" {
  region     = "ap-south-1"
  access_key = "AKIAX3LT6HD6CGGIHCHS"
  secret_key = "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"
}

data "aws_availability_zones" "task_az" {
  blacklisted_names = ["ap-south-1c"]
}

resource "tls_private_key" "tlskey" {
  algorithm = "RSA"
}

resource "aws_key_pair" "tkey" {
  key_name   = "task-key"
  public_key = tls_private_key.tlskey.public_key_openssh
}

resource "aws_vpc" "vpc" {
  cidr_block = "10.1.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    "Name" = "task_vpc"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.vpc.id
  tags = {
    "Name" = "task_ig"
  }
}

resource "aws_subnet" "subnet_public" {
  vpc_id = aws_vpc.vpc.id
  cidr_block = "10.1.0.0/24"
  map_public_ip_on_launch = "true"
  availability_zone = data.aws_availability_zones.task_az.names[0]
  tags = {
    "Name" = "task_subnet"
  }
}

resource "aws_route_table" "rtb_public" {
  vpc_id = aws_vpc.vpc.id
  route {
        cidr_block = "0.0.0.0/0"
        gateway_id = aws_internet_gateway.igw.id
  }
  tags = {
     "Name" = "task_route"
  }
}

resource "aws_route_table_association" "rta_subnet_public" {
  subnet_id      = aws_subnet.subnet_public.id
  route_table_id = aws_route_table.rtb_public.id
  
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id       = aws_vpc.vpc.id
  service_name = "com.amazonaws.ap-south-1.s3"
}

resource "aws_vpc_endpoint_route_table_association" "verta_public" {
  route_table_id  = aws_route_table.rtb_public.id
  vpc_endpoint_id = aws_vpc_endpoint.s3.id
}


resource "aws_security_group" "sg_80" {
  name = "sg_80"
  vpc_id = aws_vpc.vpc.id
  
  ingress {
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { 
    Name = "task_sg"
  }
}

resource "aws_instance"  "myinstance"  {
  ami           = "ami-0447a12f28fddb066"
  instance_type = "t2.micro"
  availability_zone = data.aws_availability_zones.task_az.names[0]
  key_name      = aws_key_pair.tkey.key_name
  subnet_id = aws_subnet.subnet_public.id
  vpc_security_group_ids = [ aws_security_group.sg_80.id ]
 // iam_instance_profile = aws_iam_instance_profile.task_iam_instance_profile.name
  
  tags = {
    Name = "tfos"
  }
} 

resource "null_resource" "op_after_creation"  {

  depends_on = [
    aws_instance.myinstance
  ]

  connection {
    type     = "ssh"
    user     = "ec2-user"
    private_key = tls_private_key.tlskey.private_key_pem
    host     = aws_instance.myinstance.public_ip
  }

  provisioner "remote-exec" {
    inline = [
      "sudo yum install httpd git -y",
      "sudo systemctl restart httpd",
      "sudo systemctl enable httpd"
    ]
  }  
}


resource "aws_ebs_volume" "myebs" {
  depends_on = [
    null_resource.op_after_creation
  ]
  availability_zone = aws_instance.myinstance.availability_zone
  size              = 2

  tags = {
    Name = "webPageStore"
  }
}

resource "aws_volume_attachment" "ebs_att" {
  depends_on = [
    aws_ebs_volume.myebs
  ]
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.myebs.id
  force_detach = true
  instance_id = aws_instance.myinstance.id
}

resource "null_resource" "op_after_attach"  {

  depends_on = [
    aws_volume_attachment.ebs_att
  ]


  connection {
    type     = "ssh"
    user     = "ec2-user"
    private_key = tls_private_key.tlskey.private_key_pem
    host     = aws_instance.myinstance.public_ip
  }

  provisioner "remote-exec" {
      inline = [
        "sudo mkfs.ext4  /dev/xvdf",
        "sudo mount  /dev/xvdf  /var/www/html",
        "sudo rm -rf /var/www/html/*",
        "sudo git clone https://github.com/satyamcs1999/terraform_aws_jenkins.git /var/www/html/"
     ]
  }
}

resource "aws_s3_bucket" "task_bucket" {

  depends_on = [
   null_resource.op_after_attach
  ]
  bucket = "t1-aws-terraform"
  acl    = "public-read"
  region = "ap-south-1"
  force_destroy = "true"
  website{
    index_document = "index.html"
  }

  tags = {
    Name = "t1-aws-terraform"
  }
}

resource "aws_codepipeline" "task_codepipeline" {
   name = "task_codepipeline"
   role_arn = "arn:aws:iam::539798419708:role/sats"
   artifact_store {
    location = aws_s3_bucket.task_bucket.bucket
    type = "S3"
  }
  stage {
    name = "Source"
    
    action {
      name = "Source"
      category = "Source"
      owner = "ThirdParty"
      provider = "GitHub"
      version = "1"
      output_artifacts = ["source_output"]
      
      configuration = {
        Owner = "satyamcs1999"
        Repo = "terraform_aws_jenkins"
        Branch = "master"
        OAuthToken = "12d4533b9f05e0042e91638f83db6d07210a7e87"
      }
    }
  }
  
  stage {
    name = "Deploy"

    action {
      name = "Deploy"
      category = "Deploy"
      owner = "AWS"
      provider = "S3"
      version = "1"
      input_artifacts = ["source_output"]

      configuration = {
        BucketName = "t1-aws-terraform"
        Extract = "true"
      }
    }
  }
}

resource "time_sleep" "waiting_time" {
  depends_on = [
    aws_codepipeline.task_codepipeline
  ]
  create_duration = "5m" 
}

resource "null_resource" "codepipeline_cloudfront" {
   
  depends_on = [
    time_sleep.waiting_time 
  ]
  provisioner "local-exec" {
    command = "/usr/local/bin/aws s3api put-object-acl  --bucket t1-aws-terraform  --key freddie_mercury.jpg   --acl public-read"
    working_dir = "/root"
  }
}

resource "aws_cloudfront_distribution" "task_cloudfront_distribution" {
  depends_on = [
    null_resource.codepipeline_cloudfront  
  ]
  origin {
    domain_name = aws_s3_bucket.task_bucket.bucket_domain_name
    origin_id = "S3-t1-aws-terraform"
  }
  
  enabled = true
  is_ipv6_enabled = "true"

  default_cache_behavior {
    allowed_methods = ["GET", "HEAD", "OPTIONS"]
    cached_methods = ["GET", "HEAD","OPTIONS"]
    target_origin_id = "S3-t1-aws-terraform"
    
    forwarded_values {
      query_string = "false"
      
      cookies {
        forward = "none"
      }
    }
    viewer_protocol_policy = "redirect-to-https"
    min_ttl = 0
    default_ttl = 3600
    max_ttl = 86400
  }
  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }
  viewer_certificate {
    cloudfront_default_certificate = "true"
  }
}

resource "null_resource" "cloudfront_url_updation" {
  depends_on = [
    aws_cloudfront_distribution.task_cloudfront_distribution
  ]  
  connection {
    type     = "ssh"
    user     = "ec2-user"
    private_key = tls_private_key.tlskey.private_key_pem
    host     = aws_instance.myinstance.public_ip
  }

  provisioner "remote-exec"{
    inline = [
      "sudo sed -ie 's,freddie_mercury.jpg,https://${aws_cloudfront_distribution.task_cloudfront_distribution.domain_name}/freddie_mercury.jpg,g' /var/www/html/index.html"
    ]
  }
}

resource "aws_ebs_snapshot" "task_snapshot" {
   depends_on = [
    null_resource.cloudfront_url_updation
  ]
  volume_id = aws_ebs_volume.myebs.id
  
  tags = {
    Name = "Task 1 snapshot"
  }
}

resource "null_resource" "OpenFirefox" {
   depends_on = [
     aws_ebs_snapshot.task_snapshot 
   ]
   
   provisioner "local-exec" {
     command = "firefox ${aws_instance.myinstance.public_ip}/index.html"
   }
}
