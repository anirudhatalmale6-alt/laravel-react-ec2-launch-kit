#!/usr/bin/env bash
#
# Creates the EC2 instance OctoError will run on, from nothing.
#
#   export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... AWS_DEFAULT_REGION=us-east-1
#   ./aws-provision.sh --dry-run     # prints what it WOULD create, touches nothing
#   ./aws-provision.sh
#
# Deliberately boring and idempotent: every resource is looked up by name
# first and only created if absent, so running it twice does not produce a
# second instance the client gets billed for.
#
# What it makes:
#   - a key pair, private key written here with 0600
#   - a security group: 22 from MY_IP only, 80 and 443 from anywhere
#   - one t3.small Ubuntu 24.04 instance, 30GB gp3
#   - an Elastic IP, associated
#
# Why t3.small and not t3.micro: this box runs nginx, php-fpm, Postgres 17,
# a queue worker and a Reverb websocket server. 1GB would start OOM-killing
# under a composer install. Why an Elastic IP: a plain public IPv4 changes
# every time the instance stops, and the GoDaddy A record would then point
# at someone else's server.

set -Eeuo pipefail

NAME=${NAME:-octoerror}
REGION=${AWS_DEFAULT_REGION:-us-east-1}
TYPE=${TYPE:-t3.small}
DISK_GB=${DISK_GB:-30}
DRY=0
[[ ${1:-} == --dry-run ]] && DRY=1

KEY_NAME="$NAME-key"
SG_NAME="$NAME-sg"
KEY_FILE="$(cd "$(dirname "$0")" && pwd)/${KEY_NAME}.pem"

say()  { printf '\e[1m==>\e[0m %s\n' "$*"; }
skip() { printf '    exists, reusing: %s\n' "$*"; }
die()  { printf '\e[31mFAILED:\e[0m %s\n' "$*" >&2; exit 1; }
run()  { if (( DRY )); then printf '    [dry-run] aws %s\n' "$*"; else aws "$@"; fi; }

command -v aws >/dev/null || die "the aws cli is not installed"
aws sts get-caller-identity --output text >/dev/null 2>&1 \
  || die "these credentials do not authenticate; check AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY"

say "account $(aws sts get-caller-identity --query Account --output text), region $REGION"

# ---------------------------------------------------------------- safety
# The brief said an instance was already waiting and the client later said he
# has never touched AWS. Rather than believe either, look.
# `|| true` here would be a trap: a DENIED describe-instances returns an empty
# string exactly like a genuinely empty account, and the script would then
# announce "the account is empty" having learned nothing. An authorization
# failure is not an answer, so it stops instead.
if ! EXISTING=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].[InstanceId,InstanceType,State.Name,Tags[?Key==`Name`].Value|[0]]' \
  --output text 2>&1); then
  printf '%s\n' "$EXISTING" | sed 's/^/    /' >&2
  if printf '%s' "$EXISTING" | grep -q 'service control policy'; then
    die "EC2 is blocked by an Organizations SCP on this account. No IAM policy,
       and not even the account root user, can override an SCP deny. The owner
       of the management account has to change it, or this needs a different
       AWS account."
  fi
  die "cannot list instances, so I cannot tell whether one already exists. Refusing to create one blind."
fi
if [[ -n $EXISTING ]]; then
  say "this account ALREADY has instances:"
  printf '%s\n' "$EXISTING" | sed 's/^/    /'
  if printf '%s' "$EXISTING" | grep -q "$NAME"; then
    die "an instance tagged $NAME already exists. Reuse it or rename, do not create a second billable box."
  fi
  say "none of them are tagged $NAME, continuing"
else
  say "no existing instances; the account is empty"
fi

MY_IP=$(curl -s --max-time 10 https://checkip.amazonaws.com | tr -d '[:space:]')
[[ $MY_IP =~ ^[0-9.]+$ ]] || die "could not determine my own public IP for the SSH rule"
say "SSH will be restricted to $MY_IP/32"

# ---------------------------------------------------------------- key pair
if aws ec2 describe-key-pairs --region "$REGION" --key-names "$KEY_NAME" >/dev/null 2>&1; then
  skip "$KEY_NAME"
  [[ -f $KEY_FILE ]] || say "WARNING: the key pair exists in AWS but $KEY_FILE is missing locally"
else
  say "creating key pair $KEY_NAME"
  if (( DRY )); then
    printf '    [dry-run] would write %s\n' "$KEY_FILE"
  else
    aws ec2 create-key-pair --region "$REGION" --key-name "$KEY_NAME" \
      --query 'KeyMaterial' --output text > "$KEY_FILE"
    chmod 600 "$KEY_FILE"
  fi
fi

# ----------------------------------------------------------- security group
SG_ID=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=group-name,Values=$SG_NAME" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")
if [[ $SG_ID == "None" || -z $SG_ID ]]; then
  say "creating security group $SG_NAME"
  if (( DRY )); then
    SG_ID="sg-dryrun"
    printf '    [dry-run] would open 22 from %s/32, 80 and 443 from 0.0.0.0/0\n' "$MY_IP"
  else
    SG_ID=$(aws ec2 create-security-group --region "$REGION" \
      --group-name "$SG_NAME" --description "OctoError web + ssh" \
      --query 'GroupId' --output text)
    aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_ID" \
      --ip-permissions \
        "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=$MY_IP/32,Description='deploy ssh'}]" \
        "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=0.0.0.0/0,Description='http + acme'}]" \
        "IpProtocol=tcp,FromPort=443,ToPort=443,IpRanges=[{CidrIp=0.0.0.0/0,Description='https + wss'}]" \
      >/dev/null
  fi
else
  skip "$SG_NAME ($SG_ID)"
fi
# Reverb listens on 8080 but is NEVER exposed: nginx proxies wss on 443 to
# 127.0.0.1:8080. Postgres 5432 is local only for the same reason. Opening
# either to the internet would be the easiest mistake to make here.

# ------------------------------------------------------------------- AMI
AMI=$(aws ec2 describe-images --region "$REGION" --owners 099720109477 \
  --filters 'Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*' \
            'Name=state,Values=available' \
  --query 'sort_by(Images,&CreationDate)[-1].ImageId' --output text)
[[ $AMI == ami-* ]] || die "could not resolve an Ubuntu 24.04 AMI in $REGION"
say "Ubuntu 24.04 AMI: $AMI"

# -------------------------------------------------------------- instance
say "launching $TYPE with ${DISK_GB}GB gp3"
if (( DRY )); then
  printf '    [dry-run] would launch and then allocate an Elastic IP\n'
  say "dry run complete, nothing was created"
  exit 0
fi

IID=$(aws ec2 run-instances --region "$REGION" \
  --image-id "$AMI" --instance-type "$TYPE" \
  --key-name "$KEY_NAME" --security-group-ids "$SG_ID" \
  --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=$DISK_GB,VolumeType=gp3,DeleteOnTermination=true,Encrypted=true}" \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME}]" \
  --query 'Instances[0].InstanceId' --output text)
say "instance $IID, waiting for it to run"
aws ec2 wait instance-running --region "$REGION" --instance-ids "$IID"

# --------------------------------------------------------------- elastic ip
ALLOC=$(aws ec2 allocate-address --region "$REGION" --domain vpc \
  --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=$NAME}]" \
  --query 'AllocationId' --output text)
aws ec2 associate-address --region "$REGION" --instance-id "$IID" --allocation-id "$ALLOC" >/dev/null
EIP=$(aws ec2 describe-addresses --region "$REGION" --allocation-ids "$ALLOC" \
  --query 'Addresses[0].PublicIp' --output text)

cat <<EOF

  instance    $IID
  elastic ip  $EIP
  ssh key     $KEY_FILE
  ssh         ssh -i $KEY_FILE ubuntu@$EIP

  GoDaddy DNS, two A records, TTL 600:
      @     $EIP
      www   $EIP

  An Elastic IP stays with the instance across a stop/start. A plain public
  IPv4 would not, and the DNS would end up pointing at another customer's
  server.

  Next: ./server-bootstrap.sh, then deploy.
EOF
