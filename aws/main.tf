provider "aws" {
  region = var.region
}

data "aws_eks_cluster" "cluster" {
  name = module.eks.cluster_id
}

data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_id
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority.0.data)
  token                  = data.aws_eks_cluster_auth.cluster.token
}

data "aws_availability_zones" "available" {
}

locals {
  cluster_name = "cert-manager-cluster"
}

module "vpc" {
  source = "terraform-aws-modules/vpc/aws"

  name                 = var.vpc_name
  cidr                 = var.vpc_cidr
  azs                  = data.aws_availability_zones.available.names
  private_subnets      = var.vpc_private_subnets
  public_subnets       = var.vpc_public_subnets
  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                      = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"             = "1"
  }
}

module "eks" {
  source = "terraform-aws-modules/eks/aws"

  cluster_name    = local.cluster_name
  cluster_version = var.eks_cluster_version
  subnets         = module.vpc.private_subnets

  vpc_id = module.vpc.vpc_id

  node_groups = {
    eks_node = {
      desired_capacity = var.nodes_desired
      max_capacity     = var.nodes_max
      min_capacity     = var.nodes_min

      instance_type = var.nodes_type
    }
  }

  write_kubeconfig = var.write_kubeconfig
}

provider "helm" {
  kubernetes {
    config_path = var.kubeconfig_path ## check this
  }
}

resource "helm_release" "cert-manager" {
  name             = "jetstack"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  namespace        = "cert-manager"
  create_namespace = true
  version          = var.cert_manager_version
  set {
    name  = "installCRDs"
    value = "true"
  }
}

resource "helm_release" "ingress_nginx" {
  name       = "ingress-nginx"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  namespace  = "default"
}

data "kubernetes_service" "ingress_service" {
  metadata {
    name = "ingress-nginx" ## replace with what we see for the first time after running
  }
}

resource "aws_route53_zone" "test" {
  name = "test.example.com" ## repalce with one Zee gives, replace resource with data
}

resource "aws_route53_record" "www" {
  zone_id = aws_route53_zone.test.zone_id
  name    = "test.example.com"
  type    = "A"
  ttl     = "300"
  records = [data.kubernetes_service.ingress_service.status.0.load_balancer.0.ingress.0.hostname]
}

output "kubectl_config" {
  description = "kubectl config as generated by the module."
  value       = module.eks.kubeconfig
}

output "loadbalancer_hostname" {
  description = "hostname of the load balancer."
  value       = data.kubernetes_service.ingress_service.status.0.load_balancer.0.ingress.0.hostname
}
