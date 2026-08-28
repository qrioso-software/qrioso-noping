#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/load-env.sh"

verify_aws_identity() {
  local actual_account actual_arn
  actual_account="$(aws sts get-caller-identity \
    --profile "${AWS_PROFILE}" \
    --query Account \
    --output text)"
  actual_arn="$(aws sts get-caller-identity \
    --profile "${AWS_PROFILE}" \
    --query Arn \
    --output text)"

  if [[ "${actual_account}" != "${AWS_ACCOUNT_ID}" ]]; then
    echo "Cuenta AWS incorrecta. Esperada=${AWS_ACCOUNT_ID}; actual=${actual_account}." >&2
    exit 1
  fi

  echo "Preflight AWS: perfil=${AWS_PROFILE} cuenta=${actual_account} región=${AWS_REGION} identidad=${actual_arn}"
  report_relevant_resources
}

report_relevant_resources() {
  echo "Stacks ${PROJECT_PREFIX}-noping-* en ${AWS_REGION}:"
  aws cloudformation list-stacks \
    --profile "${AWS_PROFILE}" \
    --region "${AWS_REGION}" \
    --stack-status-filter CREATE_IN_PROGRESS CREATE_COMPLETE ROLLBACK_IN_PROGRESS ROLLBACK_FAILED ROLLBACK_COMPLETE DELETE_IN_PROGRESS DELETE_FAILED UPDATE_IN_PROGRESS UPDATE_COMPLETE_CLEANUP_IN_PROGRESS UPDATE_COMPLETE UPDATE_FAILED UPDATE_ROLLBACK_IN_PROGRESS UPDATE_ROLLBACK_FAILED UPDATE_ROLLBACK_COMPLETE_CLEANUP_IN_PROGRESS UPDATE_ROLLBACK_COMPLETE REVIEW_IN_PROGRESS IMPORT_IN_PROGRESS IMPORT_COMPLETE IMPORT_ROLLBACK_IN_PROGRESS IMPORT_ROLLBACK_FAILED IMPORT_ROLLBACK_COMPLETE \
    --query "StackSummaries[?starts_with(StackName, '${PROJECT_PREFIX}-noping-')].[StackName,StackStatus]" \
    --output table

  echo "EC2 ${PROJECT_PREFIX}-noping-* en ${AWS_REGION}:"
  aws ec2 describe-instances \
    --profile "${AWS_PROFILE}" \
    --region "${AWS_REGION}" \
    --filters "Name=tag:Name,Values=${PROJECT_PREFIX}-noping-*" \
    --query "Reservations[].Instances[].[InstanceId,State.Name,InstanceType,PublicIpAddress,Tags[?Key=='Name']|[0].Value]" \
    --output table

  echo "Global Accelerators ${PROJECT_PREFIX}-noping-* (API us-west-2):"
  aws globalaccelerator list-accelerators \
    --profile "${AWS_PROFILE}" \
    --region us-west-2 \
    --query "Accelerators[?starts_with(Name, '${PROJECT_PREFIX}-noping-')].[Name,Status,DnsName]" \
    --output table

  echo "Budgets ${PROJECT_PREFIX}-noping-* y alarmas en ${AWS_REGION}:"
  aws budgets describe-budgets \
    --profile "${AWS_PROFILE}" \
    --region us-east-1 \
    --account-id "${AWS_ACCOUNT_ID}" \
    --query "Budgets[?starts_with(BudgetName, '${PROJECT_PREFIX}-noping-')].[BudgetName,BudgetLimit.Amount,BudgetLimit.Unit]" \
    --output table
  aws cloudwatch describe-alarms \
    --profile "${AWS_PROFILE}" \
    --region "${AWS_REGION}" \
    --alarm-name-prefix "${PROJECT_PREFIX}-noping-" \
    --query 'MetricAlarms[].[AlarmName,StateValue]' \
    --output table
}

require_docker() {
  if ! docker info >/dev/null 2>&1; then
    echo "Docker Desktop no está iniciado." >&2
    exit 1
  fi
}

require_budget_email() {
  if [[ -z "${BUDGET_EMAIL}" ]]; then
    echo "BUDGET_EMAIL es obligatorio antes de synth/deploy para no crear presupuesto y alarmas sin destinatario." >&2
    echo "Configúralo en .env con un buzón real que pueda confirmar la suscripción SNS." >&2
    exit 1
  fi
}

stack_exists() {
  local stack_name="$1"
  aws cloudformation describe-stacks \
    --profile "${AWS_PROFILE}" \
    --region "${AWS_REGION}" \
    --stack-name "${stack_name}" \
    >/dev/null 2>&1
}

stack_status() {
  local stack_name="$1"
  aws cloudformation describe-stacks \
    --profile "${AWS_PROFILE}" \
    --region "${AWS_REGION}" \
    --stack-name "${stack_name}" \
    --query 'Stacks[0].StackStatus' \
    --output text
}

require_stack_stable() {
  local stack_name="$1"
  local status
  status="$(stack_status "${stack_name}")"
  case "${status}" in
    CREATE_COMPLETE|UPDATE_COMPLETE|UPDATE_ROLLBACK_COMPLETE|IMPORT_COMPLETE)
      ;;
    *)
      echo "El stack ${stack_name} no está estable: ${status}. Revisa CloudFormation antes de continuar." >&2
      exit 1
      ;;
  esac
}

stack_output() {
  local stack_name="$1"
  local output_key="$2"
  local value
  value="$(aws cloudformation describe-stacks \
    --profile "${AWS_PROFILE}" \
    --region "${AWS_REGION}" \
    --stack-name "${stack_name}" \
    --query "Stacks[0].Outputs[?OutputKey=='${output_key}'].OutputValue | [0]" \
    --output text)"

  if [[ -z "${value}" || "${value}" == "None" ]]; then
    echo "El stack ${stack_name} no contiene el output ${output_key}." >&2
    exit 1
  fi
  printf '%s\n' "${value}"
}

instance_state() {
  local instance_id="$1"
  aws ec2 describe-instances \
    --profile "${AWS_PROFILE}" \
    --region "${AWS_REGION}" \
    --instance-ids "${instance_id}" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text
}
