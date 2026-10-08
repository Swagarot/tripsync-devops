
resource "aws_vpc" "this" {

    cidr_block = var.vpc_cidr
    enable_dns_support = true
    enable_dns_hostnames = true
   tags = merge(var.tags, {
    Name = "${var.project_name}-vpc"
  })
}

resource "aws_internet_gateway" "igw" {

    vpc_id = aws_vpc.this.id

   tags = merge(var.tags, {
    Name = "${var.project_name}-igw"
  })
}

resource "aws_subnet" "public_subnet" {
   count = length(var.zones)
   vpc_id = aws_vpc.this.id
   cidr_block = var.public_subnet_cidrs[count.index]
   availability_zone = var.zones[count.index]
   map_public_ip_on_launch = true
  
 tags = merge(var.tags, {
    Name = "${var.project_name}-public-subnet-${count.index}"
    "kubernetes.io/role/elb" = "1"
  })
}
