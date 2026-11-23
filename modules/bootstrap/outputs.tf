output "compartment_id" {
  description = "Compartment holding all project resources."
  value       = oci_identity_compartment.this.id
}

output "state_bucket" {
  description = "Bucket holding state for every stack."
  value       = oci_objectstorage_bucket.state.name
}

output "state_namespace" {
  description = "Object Storage namespace of the tenancy."
  value       = data.oci_objectstorage_namespace.this.namespace
}

output "state_s3_endpoint" {
  description = "S3-compatible endpoint used by the state backend."
  value       = "https://${var.state_namespace}.compat.objectstorage.${var.region}.oraclecloud.com"
}

output "ci_groups" {
  description = "Put the CI plan/apply users in these groups (README -> CI setup)."
  value       = { for k, g in oci_identity_group.ci : k => g.name }
}

output "a1_availability_domain" {
  description = "The AD the quotas allow A1 nodes in."
  value       = local.a1_ad
}

output "alerts_topic_id" {
  description = "Notifications topic for cost/traffic alarms; reuse it for your own alarms."
  value       = oci_ons_notification_topic.alerts.id
}

output "state_access_group" {
  description = "Put the dedicated state user in this group, then create its Customer Secret Key."
  value       = oci_identity_group.state_access.name
}
