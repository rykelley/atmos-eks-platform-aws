# Standard Cloud Posse context — provides namespace/tenant/environment/stage
# to every resource and is the bridge to the remote-state module.
# Keep this file unedited; it's the same null-label pattern Cloud Posse uses
# in every component.

module "this" {
  source  = "cloudposse/label/null"
  version = "0.25.0"

  enabled             = var.enabled
  namespace           = var.namespace
  tenant              = var.tenant
  environment         = var.environment
  stage               = var.stage
  name                = var.name
  delimiter           = var.delimiter
  attributes          = var.attributes
  tags                = var.tags
  additional_tag_map  = var.additional_tag_map
  label_order         = var.label_order
  regex_replace_chars = var.regex_replace_chars
  id_length_limit     = var.id_length_limit
  label_key_case      = var.label_key_case
  label_value_case    = var.label_value_case
  descriptor_formats  = var.descriptor_formats
  labels_as_tags      = var.labels_as_tags

  context = var.context
}

variable "enabled" {
  type    = bool
  default = true
}
variable "namespace" {
  type    = string
  default = null
}
variable "tenant" {
  type    = string
  default = null
}
variable "environment" {
  type    = string
  default = null
}
variable "stage" {
  type    = string
  default = null
}
variable "name" {
  type    = string
  default = "three-tier-app"
}
variable "delimiter" {
  type    = string
  default = null
}
variable "attributes" {
  type    = list(string)
  default = []
}
variable "tags" {
  type    = map(string)
  default = {}
}
variable "additional_tag_map" {
  type    = map(string)
  default = {}
}
variable "label_order" {
  type    = list(string)
  default = null
}
variable "regex_replace_chars" {
  type    = string
  default = null
}
variable "id_length_limit" {
  type    = number
  default = null
}
variable "label_key_case" {
  type    = string
  default = null
}
variable "label_value_case" {
  type    = string
  default = null
}
variable "descriptor_formats" {
  type    = any
  default = {}
}
variable "labels_as_tags" {
  type    = set(string)
  default = ["default"]
}
variable "context" {
  type = any
  default = {
    enabled             = true
    namespace           = null
    tenant              = null
    environment         = null
    stage               = null
    name                = null
    delimiter           = null
    attributes          = []
    tags                = {}
    additional_tag_map  = {}
    regex_replace_chars = null
    label_order         = []
    id_length_limit     = null
    label_key_case      = null
    label_value_case    = null
    descriptor_formats  = {}
    labels_as_tags      = ["default"]
  }
}
