#!/bin/bash

# LUN性能监控脚本
# 用于监控iSCSI LUN的性能指标

# 监控间隔（秒）
INTERVAL=5

# 输出文件
OUTPUT_FILE="/tmp/iscsi_performance.json"

# 监控循环
while true; do
    # 获取当前时间
    TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")
    
    # 获取tgt服务状态
    TGT_STATUS=$(tgtadm --lld iscsi --mode system --op show 2>/dev/null && echo "running" || echo "stopped")
    
    # 获取连接信息
    CONN_INFO=$(tgtadm --lld iscsi --mode conn --op show 2>/dev/null || echo "")
    CONN_COUNT=$(echo "$CONN_INFO" | grep -c "Connection:")
    
    # 获取会话信息
    SESSION_INFO=$(tgtadm --lld iscsi --mode session --op show 2>/dev/null || echo "")
    SESSION_COUNT=$(echo "$SESSION_INFO" | grep -c "Session:")
    
    # 获取I/O统计信息
    declare -A TARGET_STATS
    declare -A LUN_STATS
    
    # 解析Target和LUN信息
    TARGETS=$(tgtadm --lld iscsi --mode target --op show 2>/dev/null | grep "Target" | awk '{print $2}' | sed 's/://')
    
    # 初始化性能数据数组
    PERFORMANCE_DATA="[]"
    
    # 遍历所有Target
    for TID in $TARGETS; do
        TARGET_INFO=$(tgtadm --lld iscsi --mode target --op show --tid $TID 2>/dev/null)
        TARGET_NAME=$(echo "$TARGET_INFO" | grep "Target $TID" | awk '{print $3}')
        
        # 获取Target下的所有LUN
        LUNS=$(echo "$TARGET_INFO" | grep "LUN:" | awk '{print $2}' | sed 's/://')
        
        # 遍历所有LUN
        for LUN in $LUNS; do
            # 获取LUN信息
            LUN_INFO=$(echo "$TARGET_INFO" | grep -A 10 "LUN: $LUN")
            BACKING_STORE=$(echo "$LUN_INFO" | grep "Backing store path" | awk '{print $4}')
            SIZE=$(echo "$LUN_INFO" | grep "Size:" | awk '{print $2,$3}' | tr -d ',')
            
            # 获取LUN的I/O统计（从/proc/diskstats或iostat）
            # 这里使用简化的方法，实际生产环境可能需要更复杂的统计
            if [ -n "$BACKING_STORE" ] && [ -f "$BACKING_STORE" ]; then
                # 获取文件所在的设备
                DEVICE=$(df -P "$BACKING_STORE" | tail -1 | awk '{print $1}')
                DEVICE_NAME=$(basename "$DEVICE")
                
                # 从/proc/diskstats获取I/O统计
                if [ -n "$DEVICE_NAME" ]; then
                    DISK_STATS=$(grep "$DEVICE_NAME" /proc/diskstats 2>/dev/null || echo "")
                    
                    if [ -n "$DISK_STATS" ]; then
                        # 解析I/O统计
                        READ_IOS=$(echo "$DISK_STATS" | awk '{print $4}')
                        READ_SECTORS=$(echo "$DISK_STATS" | awk '{print $6}')
                        WRITE_IOS=$(echo "$DISK_STATS" | awk '{print $8}')
                        WRITE_SECTORS=$(echo "$DISK_STATS" | awk '{print $10}')
                        
                        # 计算读写速率（扇区*512字节=字节数）
                        READ_BYTES=$((READ_SECTORS * 512))
                        WRITE_BYTES=$((WRITE_SECTORS * 512))
                        
                        # 添加到性能数据
                        LUN_DATA="{\"target_id\":$TID,\"target_name\":\"$TARGET_NAME\",\"lun_id\":$LUN,\"backing_store\":\"$BACKING_STORE\",\"size\":\"$SIZE\",\"read_ios\":$READ_IOS,\"write_ios\":$WRITE_IOS,\"read_bytes\":$READ_BYTES,\"write_bytes\":$WRITE_BYTES}"
                        
                        # 更新性能数据数组
                        if [ "$PERFORMANCE_DATA" = "[]" ]; then
                            PERFORMANCE_DATA="[$LUN_DATA]"
                        else
                            PERFORMANCE_DATA="${PERFORMANCE_DATA%]},$LUN_DATA]"
                        fi
                    fi
                fi
            fi
        done
    done
    
    # 创建完整的性能数据JSON
    FULL_DATA="{\"timestamp\":\"$TIMESTAMP\",\"tgt_status\":\"$TGT_STATUS\",\"connections\":$CONN_COUNT,\"sessions\":$SESSION_COUNT,\"lun_performance\":$PERFORMANCE_DATA}"
    
    # 输出到文件
    echo "$FULL_DATA" > "$OUTPUT_FILE"
    
    # 等待下一个监控周期
    sleep "$INTERVAL"
done
