#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/load-env.sh"

echo "Perfil: ${AWS_PROFILE}"
echo "Región: ${AWS_REGION}"
aws sts get-caller-identity --profile "${AWS_PROFILE}" --output table
actual_account="$(aws sts get-caller-identity --profile "${AWS_PROFILE}" --query Account --output text)"
if [[ "${actual_account}" != "${AWS_ACCOUNT_ID}" ]]; then
  echo "Cuenta AWS incorrecta. Esperada=${AWS_ACCOUNT_ID}; actual=${actual_account}." >&2
  exit 1
fi

echo "Stacks existentes con prefijo ${PROJECT_PREFIX}-:"
aws cloudformation list-stacks \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE UPDATE_ROLLBACK_COMPLETE \
  --query "StackSummaries[?starts_with(StackName, '${PROJECT_PREFIX}-')].[StackName,StackStatus]" \
  --output table

echo "EC2 existentes con prefijo ${PROJECT_PREFIX}-:"
aws ec2 describe-instances \
  --profile "${AWS_PROFILE}" \
  --region "${AWS_REGION}" \
  --filters "Name=tag:Name,Values=${PROJECT_PREFIX}-*" \
  --query "Reservations[].Instances[].[InstanceId,State.Name,InstanceType,PublicIpAddress,Tags[?Key=='Name']|[0].Value]" \
  --output table
