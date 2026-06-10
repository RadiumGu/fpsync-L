#!/bin/bash
# 清理东京 region fpsync 验证资源 (账号 926093770964)
# 顺序: 终止EC2 -> 删EFS挂载目标 -> 删EFS -> 删安全组
set -x
R=ap-northeast-1
INSTANCES="i-087839a44a550caf2 i-0be304b89f081ef1f"
MT_SRC=fsmt-018dcdf7286d82619
MT_DST=fsmt-04365f7c50c728e92
FS_SRC=fs-0abcb80fd7a747a30
FS_DST=fs-093a0dd8193e51c14
SG_EC2=sg-06d3982908235d2ad
SG_EFS=sg-0437aeecc664dc29b

# 1. 终止 EC2 (master + worker)
aws ec2 terminate-instances --region $R --instance-ids $INSTANCES
aws ec2 wait instance-terminated --region $R --instance-ids $INSTANCES

# 2. 删除 EFS 挂载目标 (会释放对应 ENI)
aws efs delete-mount-target --region $R --mount-target-id $MT_SRC
aws efs delete-mount-target --region $R --mount-target-id $MT_DST
# 等挂载目标/ENI 释放
sleep 30

# 3. 删除 EFS 文件系统
aws efs delete-file-system --region $R --file-system-id $FS_SRC
aws efs delete-file-system --region $R --file-system-id $FS_DST

# 4. 删除安全组 (先 EFS SG 再 EC2 SG; 若提示依赖未释放, 稍等再重试)
sleep 10
aws ec2 delete-security-group --region $R --group-id $SG_EFS
aws ec2 delete-security-group --region $R --group-id $SG_EC2

# 5. (可选) 删除 S3 上的临时脚本副本
# aws s3 rm s3://m2m-926093770964-ap-northeast-1/fpsync-m/fpsync-monitor-20260610.sh --region $R

echo "cleanup done"
