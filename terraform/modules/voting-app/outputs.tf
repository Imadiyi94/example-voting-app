# Capstone 1 - The Voting App
# Voting App Module Outputs

output "vote_service_name" {
  value = kubernetes_service.vote.metadata[0].name
}

output "redis_service_name" {
  value = kubernetes_service.redis.metadata[0].name
}

output "worker_service_name" {
  value = kubernetes_service.worker.metadata[0].name
}

output "db_service_name" {
  value = kubernetes_service.db.metadata[0].name
}

output "result_service_name" {
  value = kubernetes_service.result.metadata[0].name
}

output "vote_deployment_name" {
  value = kubernetes_deployment.vote.metadata[0].name
}

output "worker_deployment_name" {
  value = kubernetes_deployment.worker.metadata[0].name
}

output "db_statefulset_name" {
  value = kubernetes_stateful_set.db.metadata[0].name
}

output "result_deployment_name" {
  value = kubernetes_deployment.result.metadata[0].name
}