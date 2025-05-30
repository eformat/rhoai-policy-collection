#!/bin/bash

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly ORANGE='\033[38;5;214m'
readonly NC='\033[0m' # No Color
readonly RUN_DIR=$(pwd)

DRYRUN=${DRYRUN:-}
EXTRA_DISK_SIZE=${EXTRA_DISK_SIZE:-300}

setup_extra_storage() {
    echo "🌴 Running setup_extra_storage..."

    export INSTANCE_ID=$(aws ec2 describe-instances \
    --query "Reservations[].Instances[].InstanceId" \
    --filters "Name=tag-value,Values=$CLUSTER_NAME-*-master-0" "Name=instance-state-name,Values=running" \
    --output text)

    if [[ $(aws ec2 describe-volumes --region=${AWS_DEFAULT_REGION} \
              --filters=Name=attachment.instance-id,Values=${INSTANCE_ID} \
              --query "Volumes[*].{VolumeID:Attachments[0].VolumeId,InstanceID:Attachments[0].InstanceId,State:Attachments[0].State,Environment:Tags[?Key=='Environment']|[0].Value}" \
              | jq length) > 1 ]]; then 
         echo -e "💀${ORANGE} More than 1 volume attachment found, assuming this step been done previously, returning? ${NC}";
         return
    fi

    export AWS_ZONE=$(aws ec2 describe-instances \
    --query "Reservations[].Instances[].Placement.AvailabilityZone" \
    --filters "Name=tag-value,Values=$CLUSTER_NAME-*-master-0" "Name=instance-state-name,Values=running" \
    --output text)

    vol=$(aws ec2 create-volume \
    --availability-zone ${AWS_ZONE} \
    --volume-type gp3 \
    --size ${EXTRA_DISK_SIZE} \
    --region=${AWS_DEFAULT_REGION})

    sleep 5

    aws ec2 attach-volume \
    --volume-id $(echo ${vol} | jq -r '.VolumeId') \
    --instance-id ${INSTANCE_ID} \
    --device /dev/sdf

    if [ "$?" != 0 ]; then
      echo -e "🚨${RED}Failed - to run setup_extra_storage ?${NC}"
      exit 1
    else
      echo "🌴 setup_extra_storage ran OK"
    fi
}

usage() {
  cat <<EOF 2>&1
usage: $0 [ -d ]

Extra Storage Config
EOF
  exit 1
}


all() {
    setup_extra_storage
}

while getopts opts; do
  case $opts in
    *)
      usage
      ;;
  esac
done

shift `expr $OPTIND - 1`

# Check for EnvVars
[ ! -z "$AWS_PROFILE" ] && echo "🌴 Using AWS_PROFILE: $AWS_PROFILE"
[ -z "$AWS_PROFILE" ] && [ -z "$AWS_ACCESS_KEY_ID" ] && echo "🕱 Error: AWS_ACCESS_KEY_ID not set in env" && exit 1
[ -z "$AWS_PROFILE" ] && [ -z "$AWS_SECRET_ACCESS_KEY" ] && echo "🕱 Error: AWS_SECRET_ACCESS_KEY not set in env" && exit 1
[ -z "$AWS_PROFILE" ] && [ -z "$AWS_DEFAULT_REGION" ] && echo "🕱 Error: AWS_DEFAULT_REGION not set in env" && exit

all

echo -e "\n🌻${GREEN}Extra Storage Configured OK.${NC}🌻\n"
exit 0
