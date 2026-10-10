variable "project_name" {
  type        = string
  description = "project name"
}

variable "vpc_cidr" {
  type        = string
  description = "vpc CIDR"
}

variable "zones" {
  type        = list(string)
  description = "Names of availability zones to use"
}

variable "public_subnet_cidrs" {
  type        = list(string)
  description = "public subnet CIDR"
}

variable "private_subnet_cidr" {
  type        = string
  description = "private subnet CIDR"
}

variable "enable_nat_gateway" {
  type        = bool
  description = "choose whether to enable a NAT or not"
  default     = true
}

variable "tags" {
  type        = map(string)
  description = "project tags"
  default     = {}
}
