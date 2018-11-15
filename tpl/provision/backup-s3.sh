#!/bin/bash -x

set -eu

yum install awscli screen -y

aws configure set default.aws_access_key_id ${access_key}
aws configure set default.aws_secret_access_key ${secret_key}
aws configure set default.region ${region}
aws configure set ${bucket}.s3.use_accelerate_endpoint true