
resource "aws_vpc" "this" {

  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
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
  count                   = length(var.zones)
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.zones[count.index]
  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name                     = "${var.project_name}-public-subnet-${count.index}"
    "kubernetes.io/role/elb" = "1"
  })
}

resource "aws_subnet" "private_subnet" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.private_subnet_cidr
  availability_zone       = var.zones[0]
  map_public_ip_on_launch = false

  tags = merge(var.tags, {
    Name                              = "${var.project_name}-private-subnet"
    "kubernetes.io/role/internal-elb" = "1"
  })
}

resource "aws_eip" "nat_eip" {
  count      = var.enable_nat_gateway ? 1 : 0
  domain     = "vpc"
  depends_on = [aws_internet_gateway.igw]
  tags = merge(var.tags, {
    Name = "${var.project_name}-nat_eip"
  })
}


resource "aws_nat_gateway" "nat_gateway" {
  count         = var.enable_nat_gateway ? 1 : 0
  allocation_id = aws_eip.nat_eip[0].id
  subnet_id     = aws_subnet.public_subnet[0].id
  depends_on    = [aws_internet_gateway.igw]
  tags = merge(var.tags, {
    Name = "${var.project_name}-nat_gateway"
  })
}

resource "aws_route_table" "public_route_table" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.project_name}-public-route-table"
  })
}


resource "aws_route" "public_route" {
  route_table_id         = aws_route_table.public_route_table.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.igw.id
}

resource "aws_route_table_association" "public_subnet_association" {
  count          = length(var.zones)
  subnet_id      = aws_subnet.public_subnet[count.index].id
  route_table_id = aws_route_table.public_route_table.id
}

resource "aws_route_table" "private_route_table" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, {
    Name = "${var.project_name}-private-route-table"
  })
}

resource "aws_route" "private_route" {
  count                  = var.enable_nat_gateway ? 1 : 0
  route_table_id         = aws_route_table.private_route_table.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.nat_gateway[0].id
}

resource "aws_route_table_association" "private_subnet_association" {
  subnet_id      = aws_subnet.private_subnet.id
  route_table_id = aws_route_table.private_route_table.id
}
