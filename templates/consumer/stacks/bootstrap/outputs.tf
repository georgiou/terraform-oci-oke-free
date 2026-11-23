output "compartment_id" {
  description = "Project compartment."
  value       = module.bootstrap.compartment_id
}

output "ci_groups" {
  description = "Put your CI plan/apply users in these groups (README -> CI setup)."
  value       = module.bootstrap.ci_groups
}

output "state_access_group" {
  description = "Put your dedicated state user in this group, then create its Customer Secret Key."
  value       = module.bootstrap.state_access_group
}

output "alerts_topic_id" {
  description = "Notifications topic; reuse it for your own alarms."
  value       = module.bootstrap.alerts_topic_id
}
