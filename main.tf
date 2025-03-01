locals {
  enabled = module.this.enabled
  tags = {
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  }

  workers_role_arn       = var.use_existing_aws_iam_instance_profile ? join("", data.aws_iam_instance_profile.default.*.role_arn) : join("", aws_iam_role.default.*.arn)
  workers_role_name      = var.use_existing_aws_iam_instance_profile ? join("", data.aws_iam_instance_profile.default.*.role_name) : join("", aws_iam_role.default.*.name)
  security_group_enabled = module.this.enabled && var.security_group_enabled
}

module "label" {
  source  = "cloudposse/label/null"
  version = "0.25.0"

  attributes = ["workers"]
  tags       = local.tags

  context = module.this.context
}

data "aws_iam_policy_document" "assume_role" {
  count = local.enabled && var.use_existing_aws_iam_instance_profile == false ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "default" {
  count              = local.enabled && var.use_existing_aws_iam_instance_profile == false ? 1 : 0
  name               = module.label.id
  assume_role_policy = join("", data.aws_iam_policy_document.assume_role.*.json)
  tags               = module.label.tags
}

resource "aws_iam_role_policy_attachment" "amazon_eks_worker_node_policy" {
  count      = local.enabled && var.use_existing_aws_iam_instance_profile == false ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = join("", aws_iam_role.default.*.name)
}

resource "aws_iam_role_policy_attachment" "amazon_eks_cni_policy" {
  count      = local.enabled && var.use_existing_aws_iam_instance_profile == false ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = join("", aws_iam_role.default.*.name)
}

resource "aws_iam_role_policy_attachment" "amazon_ec2_container_registry_read_only" {
  count      = local.enabled && var.use_existing_aws_iam_instance_profile == false ? 1 : 0
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = join("", aws_iam_role.default.*.name)
}

resource "aws_iam_role_policy_attachment" "existing_policies_attach_to_eks_workers_role" {
  count      = local.enabled && var.use_existing_aws_iam_instance_profile == false ? var.workers_role_policy_arns_count : 0
  policy_arn = var.workers_role_policy_arns[count.index]
  role       = join("", aws_iam_role.default.*.name)
}

resource "aws_iam_instance_profile" "default" {
  count = local.enabled && var.use_existing_aws_iam_instance_profile == false ? 1 : 0
  name  = module.label.id
  role  = join("", aws_iam_role.default.*.name)
}

module "security_group" {
  source  = "cloudposse/security-group/aws"
  version = "0.3.3"

  use_name_prefix = var.security_group_use_name_prefix
  rules           = var.security_group_rules
  description     = var.security_group_description
  vpc_id          = var.vpc_id

  enabled = local.security_group_enabled
  context = module.label.context
}

data "aws_ami" "eks_worker" {
  count = local.enabled && var.use_custom_image_id == false ? 1 : 0

  most_recent = true
  name_regex  = var.eks_worker_ami_name_regex

  filter {
    name   = "name"
    values = [var.eks_worker_ami_name_filter]
  }

  owners = ["602401143452"] # Amazon
}

data "template_file" "userdata" {
  count    = local.enabled ? 1 : 0
  template = file("${path.module}/userdata.tpl")

  vars = {
    cluster_endpoint                = var.cluster_endpoint
    certificate_authority_data      = var.cluster_certificate_authority_data
    cluster_name                    = var.cluster_name
    bootstrap_extra_args            = var.bootstrap_extra_args
    kubelet_extra_args              = var.kubelet_extra_args
    before_cluster_joining_userdata = var.before_cluster_joining_userdata
    after_cluster_joining_userdata  = var.after_cluster_joining_userdata
  }
}

data "aws_iam_instance_profile" "default" {
  count = local.enabled && var.use_existing_aws_iam_instance_profile ? 1 : 0
  name  = var.aws_iam_instance_profile_name
}

module "autoscale_group" {
  source  = "cloudposse/ec2-autoscale-group/aws"
  version = "0.27.0"

  enabled = local.enabled
  tags    = merge(local.tags, var.autoscaling_group_tags)

  image_id                  = var.use_custom_image_id ? var.image_id : join("", data.aws_ami.eks_worker.*.id)
  iam_instance_profile_name = var.use_existing_aws_iam_instance_profile == false ? join("", aws_iam_instance_profile.default.*.name) : var.aws_iam_instance_profile_name

  security_group_ids = compact(concat(module.security_group.*.id, var.security_groups))

  user_data_base64 = base64encode(join("", data.template_file.userdata.*.rendered))

  instance_type                           = var.instance_type
  subnet_ids                              = var.subnet_ids
  min_size                                = var.min_size
  max_size                                = var.max_size
  associate_public_ip_address             = var.associate_public_ip_address
  block_device_mappings                   = var.block_device_mappings
  credit_specification                    = var.credit_specification
  disable_api_termination                 = var.disable_api_termination
  ebs_optimized                           = var.ebs_optimized
  elastic_gpu_specifications              = var.elastic_gpu_specifications
  instance_initiated_shutdown_behavior    = var.instance_initiated_shutdown_behavior
  instance_market_options                 = var.instance_market_options
  mixed_instances_policy                  = var.mixed_instances_policy
  key_name                                = var.key_name
  placement                               = var.placement
  enable_monitoring                       = var.enable_monitoring
  load_balancers                          = var.load_balancers
  health_check_grace_period               = var.health_check_grace_period
  health_check_type                       = var.health_check_type
  min_elb_capacity                        = var.min_elb_capacity
  wait_for_elb_capacity                   = var.wait_for_elb_capacity
  target_group_arns                       = var.target_group_arns
  default_cooldown                        = var.default_cooldown
  force_delete                            = var.force_delete
  termination_policies                    = var.termination_policies
  suspended_processes                     = var.suspended_processes
  placement_group                         = var.placement_group
  enabled_metrics                         = var.enabled_metrics
  metrics_granularity                     = var.metrics_granularity
  wait_for_capacity_timeout               = var.wait_for_capacity_timeout
  protect_from_scale_in                   = var.protect_from_scale_in
  service_linked_role_arn                 = var.service_linked_role_arn
  autoscaling_policies_enabled            = var.autoscaling_policies_enabled
  scale_up_cooldown_seconds               = var.scale_up_cooldown_seconds
  scale_up_scaling_adjustment             = var.scale_up_scaling_adjustment
  scale_up_adjustment_type                = var.scale_up_adjustment_type
  scale_up_policy_type                    = var.scale_up_policy_type
  scale_down_cooldown_seconds             = var.scale_down_cooldown_seconds
  scale_down_scaling_adjustment           = var.scale_down_scaling_adjustment
  scale_down_adjustment_type              = var.scale_down_adjustment_type
  scale_down_policy_type                  = var.scale_down_policy_type
  cpu_utilization_high_evaluation_periods = var.cpu_utilization_high_evaluation_periods
  cpu_utilization_high_period_seconds     = var.cpu_utilization_high_period_seconds
  cpu_utilization_high_threshold_percent  = var.cpu_utilization_high_threshold_percent
  cpu_utilization_high_statistic          = var.cpu_utilization_high_statistic
  cpu_utilization_low_evaluation_periods  = var.cpu_utilization_low_evaluation_periods
  cpu_utilization_low_period_seconds      = var.cpu_utilization_low_period_seconds
  cpu_utilization_low_statistic           = var.cpu_utilization_low_statistic
  cpu_utilization_low_threshold_percent   = var.cpu_utilization_low_threshold_percent
  metadata_http_endpoint_enabled          = var.metadata_http_endpoint_enabled
  metadata_http_put_response_hop_limit    = var.metadata_http_put_response_hop_limit
  metadata_http_tokens_required           = var.metadata_http_tokens_required

  context = module.this.context
}
