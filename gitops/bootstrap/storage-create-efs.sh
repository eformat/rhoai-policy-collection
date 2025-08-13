#!/bin/bash
set -o pipefail

readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly ORANGE='\033[38;5;214m'
readonly NC='\033[0m' # No Color
readonly RUN_DIR=$(pwd)

EFSID=

echo "🌴 Create EFS storage..."

# Check for EnvVars
[ ! -z "$AWS_PROFILE" ] && echo "🌴 Using AWS_PROFILE: $AWS_PROFILE"
[ -z "$AWS_PROFILE" ] && [ -z "$AWS_ACCESS_KEY_ID" ] && echo "🕱 Error: AWS_ACCESS_KEY_ID not set in env" && exit 1
[ -z "$AWS_PROFILE" ] && [ -z "$AWS_SECRET_ACCESS_KEY" ] && echo "🕱 Error: AWS_SECRET_ACCESS_KEY not set in env" && exit 1
[ -z "$AWS_PROFILE" ] && [ -z "$AWS_DEFAULT_REGION" ] && echo "🕱 Error: AWS_DEFAULT_REGION not set in env" && exit

oc get sc/efs-sc
if [ "$?" == 0 ]; then
    echo "🌴 Found EFS storage class OK - Done."
    exit 0
fi

vpcid=$(aws ec2 describe-vpcs --region=${AWS_DEFAULT_REGION} | jq -r '.Vpcs[0].VpcId')
if [ -z "$vpcid" ]; then
    echo -e "🚨${RED}Failed - no vpcid found for region ${AWS_DEFAULT_REGION} ? ${NC}"
    exit 1
fi

vpcname=$(aws ec2 describe-vpcs --region=${AWS_DEFAULT_REGION} | jq -r '.Vpcs[0].Tags[] | select(.Key=="Name").Value')
if [ -z "$vpcname" ]; then
    echo -e "🚨${RED}Failed - no vpcname found for region ${AWS_DEFAULT_REGION} ? ${NC}"
    exit 1
fi

export INSTANCE_ID=$(aws ec2 describe-instances \
--query "Reservations[].Instances[].InstanceId" \
--filters "Name=tag-value,Values=$CLUSTER_NAME-*-master-0" "Name=instance-state-name,Values=running" \
--output text)
IFS=$'\n' read -d '' -r -a lines < <(aws ec2 describe-tags --filters "Name=resource-id,Values=${INSTANCE_ID}" --output text)
TAGS+=Key=Name,Value=ocp-efs
TAGS+=" "
TAGS_SPEC=
if [ ! -z "$lines" ]; then
    set -o pipefail
    for line in "${lines[@]}"; do
        read -r type key resourceid resourcetype value <<< "$line"
        # troublesome, quoting, adding tags for deletion
        if [ "$key" != "Name" ] && [ "$key" != "description" ] && [ "$key" != "owner" ] ; then
            TAGS+=Key=$key,Value=$value
            TAGS+=" "
            TAGS_SPEC+={Key="$key",Value="$value"},
        fi
    done
else 
    echo -e "💀${ORANGE} No tags found for instance ${INSTANCE_ID} ? ${NC}";
fi

fsid=$(aws efs create-file-system --region=${AWS_DEFAULT_REGION} --performance-mode=generalPurpose --encrypted --tags ${TAGS%?} | jq --raw-output '.FileSystemId')
if [ -z "$fsid" ]; then
    echo -e "🚨${RED}Failed - to create efs filesystem ocp-efs ? ${NC}"
    exit 1
fi
EFSID=${fsid}

sleep 10

cidr_block=$(aws ec2 describe-vpcs --region=${AWS_DEFAULT_REGION} --vpc-ids ${vpcid} --query "Vpcs[].CidrBlock" --output text)
if [ -z "$cidr_block" ]; then
    echo -e "🚨${RED}Failed - failed to find CIDR for vpcid: ${vpcid} region: ${AWS_DEFAULT_REGION} ? ${NC}"
    exit 1
fi

mount_target_group_name="ec2-efs-group"
mount_target_group_desc="NFS access to EFS from EC2 worker nodes"
mount_target_group_id=$(aws ec2 create-security-group --region=${AWS_DEFAULT_REGION} --group-name $mount_target_group_name --description "${mount_target_group_desc}" --tag-specifications "ResourceType=security-group,Tags=[${TAGS_SPEC%?}]" --vpc-id ${vpcid} | jq --raw-output '.GroupId')
if [ -z "$mount_target_group_id" ]; then
    echo -e "🚨${RED}Failed - failed to create SG for mount target group: ${mount_target_group_name} in region: ${AWS_DEFAULT_REGION} ? ${NC}"
    exit 1
fi

aws ec2 authorize-security-group-ingress --region=${AWS_DEFAULT_REGION} --group-id ${mount_target_group_id} --protocol tcp --port 2049 --cidr ${cidr_block} | jq .
if [ "${PIPESTATUS[0]}" != 0 ]; then
    echo -e "🚨${RED}Failed - to authorize security group ingress for group-id: ${mount_target_group_id} in region: ${AWS_DEFAULT_REGION}?${NC}"
    exit 1
fi

# us-east-2
TAG1=${vpcname%%-vpc}-subnet-public-${AWS_DEFAULT_REGION}a
TAG2=${vpcname%%-vpc}-subnet-public-${AWS_DEFAULT_REGION}b
TAG3=${vpcname%%-vpc}-subnet-public-${AWS_DEFAULT_REGION}c
subnets=$(aws ec2 describe-subnets --region=${AWS_DEFAULT_REGION} --filters "Name=tag:Name,Values=$TAG1,$TAG2,$TAG3" | jq --raw-output '.Subnets[].SubnetId')
for subnet in ${subnets};
do
  echo "creating mount target in " $subnet
  aws efs create-mount-target --region=${AWS_DEFAULT_REGION} --file-system-id ${fsid} --subnet-id ${subnet} --security-groups ${mount_target_group_id}
  if [ "$?" != 0 ]; then
      echo -e "💀${ORANGE} Failed to create mount target for fsid: ${fsid} and subnet: ${subnet} with sg: ${mount_target_group_id} in region: ${AWS_DEFAULT_REGION} ? ${NC}";
  fi
done
if [ -z "$subnets" ]; then
    echo -e "💀${ORANGE} Could not find subnets for vpc ${vpcname}, mount targets not created - check TAG names $TAG1,$TAG2,$TAG3 ? ${NC}";
fi

configure_sc() {
    echo "🌴 Running configure_sc..."

cat << EOF > /tmp/storage-class-${AWS_PROFILE}.yaml
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
  name: efs-sc
provisioner: efs.csi.aws.com
parameters:
  provisioningMode: efs-ap 
  fileSystemId: $EFSID
  directoryPerms: "700" 
  gidRangeStart: "1000" 
  gidRangeEnd: "2000" 
  basePath: "/dynamic_provisioning" 
EOF

    oc apply -f /tmp/storage-class-${AWS_PROFILE}.yaml -n openshift-config
    if [ "$?" != 0 ]; then
      echo -e "🚨${RED}Failed - to create storage class, configure_sc ?${NC}"
      exit 1
    fi
    rm -f /tmp/storage-class-${AWS_PROFILE}.yaml 2>&1>/dev/null
    echo "🌴 configure_sc ran OK"
}
configure_sc

echo "🌴 Create EFS storage Done."
exit 0
