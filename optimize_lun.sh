#!/bin/bash

# LUN优化脚本 - 提高iSCSI LUN的性能和可用性
# 作用：优化tgtd配置、LUN块大小和对齐、SCSI命令支持、自动重连机制

echo "[INFO] 开始执行LUN优化..."

# 检查是否以root权限运行
if [ "$(id -u)" -ne 0 ]; then
    echo "[ERROR] 此脚本需要root权限运行"
    exit 1
fi

# 检查tgtd是否运行
if ! pgrep -x "tgtd" > /dev/null; then
    echo "[ERROR] tgtd服务未运行，请先启动iSCSI服务"
    exit 1
fi

# 创建优化配置目录
OPTIMIZE_DIR="/app/config/optimize"
mkdir -p "$OPTIMIZE_DIR"

# 1. 优化tgtd配置参数
echo "[INFO] 优化tgtd配置参数..."

# 创建tgtd优化配置文件
TGT_CONF="/etc/tgt/conf.d/optimize.conf"
cat > "$TGT_CONF" << EOF
# tgtd性能优化配置
# 增加队列深度，提高并发性能
default-driver iscsi

# 全局参数优化
ioctl sg_io_timeout=120

# 增加最大连接数和会话数
iscsi-target-driver MaxConnections=16
iscsi-target-driver MaxSessions=64

# 增加SCSI命令队列深度
iscsi-target-driver QueuedCommands=128

# 启用多路径支持
iscsi-target-driver MultipathEnabled=Yes

# 优化数据传输
iscsi-target-driver MaxRecvDataSegmentLength=262144
iscsi-target-driver MaxXmitDataSegmentLength=262144
iscsi-target-driver FirstBurstLength=262144
iscsi-target-driver MaxBurstLength=16776192

# 启用即时数据传输
iscsi-target-driver ImmediateData=Yes
iscsi-target-driver InitialR2T=No

# 启用数据摘要和头部摘要（可选，会增加CPU开销）
# iscsi-target-driver DataDigest=CRC32C
# iscsi-target-driver HeaderDigest=CRC32C

# 启用错误恢复机制
iscsi-target-driver ErrorRecoveryLevel=2
EOF

# 2. 优化LUN块大小和对齐方式
echo "[INFO] 优化LUN块大小和对齐方式..."

# 获取所有Target信息
TARGETS=$(tgtadm --lld iscsi --mode target --op show | grep "Target" | awk '{print $2}' | sed 's/://')

# 遍历所有Target
for TID in $TARGETS; do
    # 获取Target下的所有LUN
    LUNS=$(tgtadm --lld iscsi --mode target --op show --tid $TID | grep "LUN:" | awk '{print $2}' | sed 's/://')
    
    # 遍历所有LUN
    for LUN in $LUNS; do
        echo "[INFO] 优化 Target $TID LUN $LUN..."
        
        # 设置最佳块大小 (512KB)
        tgtadm --lld iscsi --mode logicalunit --op update --tid $TID --lun $LUN --params optimal_blocksize=524288
        
        # 设置物理块大小 (4KB，适合大多数现代存储)
        tgtadm --lld iscsi --mode logicalunit --op update --tid $TID --lun $LUN --params physical_blocksize=4096
        
        # 启用块对齐
        tgtadm --lld iscsi --mode logicalunit --op update --tid $TID --lun $LUN --params alignment_offset=0
        
        # 启用缓存优化
        tgtadm --lld iscsi --mode logicalunit --op update --tid $TID --lun $LUN --params write_cache=on
        tgtadm --lld iscsi --mode logicalunit --op update --tid $TID --lun $LUN --params read_cache=on
    done
done

# 3. 添加SCSI命令支持，确保与不同操作系统的兼容性
echo "[INFO] 添加SCSI命令支持，提高兼容性..."

# 创建SCSI命令支持配置文件
SCSI_CONF="/etc/tgt/conf.d/scsi_commands.conf"
cat > "$SCSI_CONF" << EOF
# 增强SCSI命令支持配置

# 启用所有必要的SCSI命令集
iscsi-target-driver EnableSCSI_SPC=Yes
iscsi-target-driver EnableSCSI_SBC=Yes
iscsi-target-driver EnableSCSI_SSC=Yes
iscsi-target-driver EnableSCSI_MMC=Yes

# 启用Windows兼容性
iscsi-target-driver EnableMSFT_Compat=Yes

# 启用VMware兼容性
iscsi-target-driver EnableVMware_Compat=Yes

# 启用VAAI支持（VMware存储API）
iscsi-target-driver EnableVAAI=Yes
EOF

# 4. 实现自动重连机制
echo "[INFO] 配置自动重连机制，提高连接稳定性..."

# 创建自动重连配置文件
RECONN_CONF="/etc/tgt/conf.d/reconnect.conf"
cat > "$RECONN_CONF" << EOF
# 自动重连配置

# 启用自动重连
iscsi-target-driver EnableReconnect=Yes

# 设置重连超时时间（秒）
iscsi-target-driver ReconnectTimeout=120

# 设置最大重连尝试次数
iscsi-target-driver MaxReconnectAttempts=5

# 启用会话恢复
iscsi-target-driver EnableSessionRecovery=Yes
EOF

# 5. 创建LUN性能监控脚本
echo "[INFO] 创建LUN性能监控脚本..."

# 创建性能监控脚本
MONITOR_SCRIPT="$OPTIMIZE_DIR/monitor_lun_performance.sh"
cat > "$MONITOR_SCRIPT" << 'EOF'
#!/bin/bash

# LUN性能监控脚本
# 用于监控iSCSI LUN的性能指标

# 监控间隔（秒）
INTERVAL=5

# 输出文件
OUTPUT_FILE="/tmp/iscsi_performance.json"

# 上一次的统计数据
declare -A PREV_READ_IOS
declare -A PREV_WRITE_IOS
declare -A PREV_READ_BYTES
declare -A PREV_WRITE_BYTES
declare -A PREV_TIMESTAMP

# 初始化时间戳
PREV_TIME=$(date +%s)

# 监控循环
while true; do
    # 获取当前时间
    CURR_TIME=$(date +%s)
    TIME_DIFF=$((CURR_TIME - PREV_TIME))
    TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")
    
    # 获取tgt服务状态
    TGT_STATUS=$(tgtadm --lld iscsi --mode system --op show 2>/dev/null && echo "running" || echo "stopped")
    
    # 获取连接信息
    CONN_INFO=$(tgtadm --lld iscsi --mode conn --op show 2>/dev/null || echo "")
    CONN_COUNT=$(echo "$CONN_INFO" | grep -c "Connection:")
    
    # 获取会话信息
    SESSION_INFO=$(tgtadm --lld iscsi --mode session --op show 2>/dev/null || echo "")
    SESSION_COUNT=$(echo "$SESSION_INFO" | grep -c "Session:")
    
    # 初始化性能数据数组
    PERFORMANCE_DATA="[]"
    
    # 遍历所有Target
    TARGETS=$(tgtadm --lld iscsi --mode target --op show 2>/dev/null | grep "Target" | awk '{print $2}' | sed 's/://')
    
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
            
            # 生成唯一的LUN标识符
            LUN_ID="${TID}_${LUN}"
            
            # 获取LUN的I/O统计
            if [ -n "$BACKING_STORE" ] && [ -f "$BACKING_STORE" ]; then
                # 获取文件所在的设备
                DEVICE=$(df -P "$BACKING_STORE" 2>/dev/null | tail -1 | awk '{print $1}')
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
                        
                        # 计算IOPS和吞吐量（只有在有前一次数据时才计算）
                        READ_IOPS=0
                        WRITE_IOPS=0
                        READ_THROUGHPUT=0
                        WRITE_THROUGHPUT=0
                        
                        if [ -n "${PREV_READ_IOS[$LUN_ID]}" ] && [ $TIME_DIFF -gt 0 ]; then
                            READ_IOPS=$(( (READ_IOS - ${PREV_READ_IOS[$LUN_ID]}) / TIME_DIFF ))
                            WRITE_IOPS=$(( (WRITE_IOS - ${PREV_WRITE_IOS[$LUN_ID]}) / TIME_DIFF ))
                            
                            # 计算吞吐量（MB/s）
                            READ_THROUGHPUT=$(echo "scale=2; (${READ_BYTES} - ${PREV_READ_BYTES[$LUN_ID]}) / $TIME_DIFF / 1048576" | bc)
                            WRITE_THROUGHPUT=$(echo "scale=2; (${WRITE_BYTES} - ${PREV_WRITE_BYTES[$LUN_ID]}) / $TIME_DIFF / 1048576" | bc)
                        fi
                        
                        # 保存当前值作为下次计算的基准
                        PREV_READ_IOS[$LUN_ID]=$READ_IOS
                        PREV_WRITE_IOS[$LUN_ID]=$WRITE_IOS
                        PREV_READ_BYTES[$LUN_ID]=$READ_BYTES
                        PREV_WRITE_BYTES[$LUN_ID]=$WRITE_BYTES
                        
                        # 添加到性能数据
                        LUN_DATA="{\"target_id\":$TID,\"target_name\":\"$TARGET_NAME\",\"lun_id\":$LUN,\"backing_store\":\"$BACKING_STORE\",\"size\":\"$SIZE\",\"read_iops\":$READ_IOPS,\"write_iops\":$WRITE_IOPS,\"read_throughput\":$READ_THROUGHPUT,\"write_throughput\":$WRITE_THROUGHPUT,\"read_ios_total\":$READ_IOS,\"write_ios_total\":$WRITE_IOS,\"read_bytes_total\":$READ_BYTES,\"write_bytes_total\":$WRITE_BYTES}"
                        
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
    
    # 更新前一次的时间戳
    PREV_TIME=$CURR_TIME
    
    # 等待下一个监控周期
    sleep "$INTERVAL"
done
EOF

# 赋予执行权限
chmod +x "$MONITOR_SCRIPT"

# 6. 复制性能监控页面到正确的位置
echo "[INFO] 配置性能监控Web界面..."

# 确保目标目录存在
mkdir -p "/app/templates"
mkdir -p "/app/static"

# 7. 创建性能监控所需的JavaScript文件
echo "[INFO] 创建性能监控JavaScript文件..."

PERF_JS_FILE="/app/static/performance.js"
cat > "$PERF_JS_FILE" << 'EOF'
// LUN性能监控JavaScript

// 为LUN生成唯一颜色
function getColorForLun(lunId, alpha = 1) {
    // 使用简单的哈希算法为每个LUN ID生成唯一颜色
    let hash = 0;
    for (let i = 0; i < lunId.toString().length; i++) {
        hash = lunId.toString().charCodeAt(i) + ((hash << 5) - hash);
    }
    
    // 转换为HSL颜色（保持亮度和饱和度固定，只改变色相）
    const h = Math.abs(hash % 360);
    const s = 70;
    const l = 50;
    
    return `hsla(${h}, ${s}%, ${l}%, ${alpha})`;
}

// 格式化数字，添加千位分隔符
function formatNumber(num) {
    return num.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ",");
}

// 更新LUN性能表格
function updateLunPerformanceTable(data) {
    const container = document.getElementById('lunPerformanceContainer');
    
    if (!data || !data.lun_performance || data.lun_performance.length === 0) {
        container.innerHTML = '<div class="alert alert-info">没有可用的LUN性能数据</div>';
        return;
    }
    
    // 创建表格
    let tableHtml = `
        <div class="table-responsive">
            <table class="table table-striped table-hover">
                <thead>
                    <tr>
                        <th>Target</th>
                        <th>LUN ID</th>
                        <th>存储路径</th>
                        <th>大小</th>
                        <th>读取IOPS</th>
                        <th>写入IOPS</th>
                        <th>读取吞吐量</th>
                        <th>写入吞吐量</th>
                    </tr>
                </thead>
                <tbody>
    `;
    
    // 添加每个LUN的行
    data.lun_performance.forEach(lun => {
        tableHtml += `
            <tr>
                <td>${lun.target_name} (${lun.target_id})</td>
                <td>${lun.lun_id}</td>
                <td title="${lun.backing_store}">${lun.backing_store.split('/').pop()}</td>
                <td>${lun.size}</td>
                <td>${formatNumber(lun.read_iops)}</td>
                <td>${formatNumber(lun.write_iops)}</td>
                <td>${lun.read_throughput} MB/s</td>
                <td>${lun.write_throughput} MB/s</td>
            </tr>
        `;
    });
    
    tableHtml += `
                </tbody>
            </table>
        </div>
    `;
    
    container.innerHTML = tableHtml;
}

// 更新性能历史记录
function updatePerformanceHistory(data) {
    if (!data || !data.lun_performance) return;
    
    // 添加时间戳
    const timestamp = new Date(data.timestamp);
    performanceHistory.timestamps.push(timestamp);
    
    // 为每个LUN更新性能数据
    data.lun_performance.forEach(lun => {
        const lunId = `${lun.target_id}_${lun.lun_id}`;
        
        // 初始化数组（如果不存在）
        if (!performanceHistory.readThroughput[lunId]) {
            performanceHistory.readThroughput[lunId] = [];
            performanceHistory.writeThroughput[lunId] = [];
            performanceHistory.readIops[lunId] = [];
            performanceHistory.writeIops[lunId] = [];
        }
        
        // 添加数据点
        performanceHistory.readThroughput[lunId].push({
            x: timestamp,
            y: parseFloat(lun.read_throughput)
        });
        
        performanceHistory.writeThroughput[lunId].push({
            x: timestamp,
            y: parseFloat(lun.write_throughput)
        });
        
        performanceHistory.readIops[lunId].push({
            x: timestamp,
            y: lun.read_iops
        });
        
        performanceHistory.writeIops[lunId].push({
            x: timestamp,
            y: lun.write_iops
        });
    });
    
    // 限制历史记录长度（保留最近100个数据点）
    if (performanceHistory.timestamps.length > 100) {
        performanceHistory.timestamps.shift();
        
        Object.keys(performanceHistory.readThroughput).forEach(lunId => {
            if (performanceHistory.readThroughput[lunId].length > 100) {
                performanceHistory.readThroughput[lunId].shift();
                performanceHistory.writeThroughput[lunId].shift();
                performanceHistory.readIops[lunId].shift();
                performanceHistory.writeIops[lunId].shift();
            }
        });
    }
    
    // 更新图表
    updateCharts();
}

// 获取性能数据
function fetchPerformanceData() {
    fetch('/api/performance')
        .then(response => response.json())
        .then(data => {
            if (data.error) {
                console.error('获取性能数据失败:', data.error);
                document.getElementById('tgtStatus').className = 'badge bg-danger';
                document.getElementById('tgtStatus').textContent = '未运行';
                return;
            }
            
            // 更新状态卡片
            document.getElementById('tgtStatus').className = data.tgt_status === 'running' ? 'badge bg-success' : 'badge bg-danger';
            document.getElementById('tgtStatus').textContent = data.tgt_status === 'running' ? '运行中' : '未运行';
            document.getElementById('connectionCount').textContent = data.connections;
            document.getElementById('sessionCount').textContent = data.sessions;
            document.getElementById('lastUpdate').textContent = data.timestamp;
            
            // 更新LUN性能表格
            updateLunPerformanceTable(data);
            
            // 更新性能历史记录和图表
            updatePerformanceHistory(data);
        })
        .catch(error => {
            console.error('获取性能数据出错:', error);
        });
}

// 启动/停止监控
function toggleMonitoring() {
    const button = document.getElementById('toggleMonitoring');
    
    if (monitoringActive) {
        // 停止监控
        fetch('/api/performance/stop', { method: 'POST' })
            .then(response => response.json())
            .then(data => {
                if (data.success) {
                    monitoringActive = false;
                    button.className = 'btn btn-success';
                    button.textContent = '启动监控';
                    
                    // 停止刷新
                    if (refreshIntervalId) {
                        clearInterval(refreshIntervalId);
                        refreshIntervalId = null;
                    }
                } else {
                    alert('停止监控失败: ' + data.message);
                }
            })
            .catch(error => {
                console.error('停止监控出错:', error);
                alert('停止监控出错，请查看控制台');
            });
    } else {
        // 启动监控
        fetch('/api/performance/start', { method: 'POST' })
            .then(response => response.json())
            .then(data => {
                if (data.success) {
                    monitoringActive = true;
                    button.className = 'btn btn-danger';
                    button.textContent = '停止监控';
                    
                    // 立即获取一次数据
                    fetchPerformanceData();
                    
                    // 设置定时刷新
                    refreshIntervalId = setInterval(fetchPerformanceData, refreshRate);
                } else {
                    alert('启动监控失败: ' + data.message);
                }
            })
            .catch(error => {
                console.error('启动监控出错:', error);
                alert('启动监控出错，请查看控制台');
            });
    }
}

// 初始化页面
document.addEventListener('DOMContentLoaded', function() {
    // 初始化图表
    initCharts();
    
    // 绑定刷新间隔选择事件
    document.getElementById('refreshInterval').addEventListener('change', function() {
        refreshRate = parseInt(this.value);
        
        // 如果正在监控，重新设置刷新间隔
        if (monitoringActive && refreshIntervalId) {
            clearInterval(refreshIntervalId);
            refreshIntervalId = setInterval(fetchPerformanceData, refreshRate);
        }
    });
    
    // 绑定监控按钮事件
    document.getElementById('toggleMonitoring').addEventListener('click', toggleMonitoring);
    
    // 检查监控状态
    fetch('/api/performance')
        .then(response => response.json())
        .then(data => {
            if (!data.error) {
                // 如果有数据，说明监控已经在运行
                monitoringActive = true;
                document.getElementById('toggleMonitoring').className = 'btn btn-danger';
                document.getElementById('toggleMonitoring').textContent = '停止监控';
                
                // 立即获取一次数据
                fetchPerformanceData();
                
                // 设置定时刷新
                refreshIntervalId = setInterval(fetchPerformanceData, refreshRate);
            }
        })
        .catch(error => {
            console.error('检查监控状态出错:', error);
        });
});
EOF

# 8. 创建性能监控所需的CSS文件
echo "[INFO] 创建性能监控CSS文件..."

# 确保样式文件存在
if [ ! -f "/app/static/style.css" ]; then
    cat > "/app/static/style.css" << 'EOF'
/* iSCSI管理界面样式 */
body {
    background-color: #f8f9fa;
    font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
}

.logo {
    width: 48px;
    height: 48px;
    margin-right: 15px;
}

.card {
    border-radius: 8px;
    margin-bottom: 20px;
    box-shadow: 0 2px 4px rgba(0, 0, 0, 0.05);
}

.card-header {
    background-color: #f8f9fa;
    border-bottom: 1px solid rgba(0, 0, 0, 0.125);
    font-weight: 600;
}

.btn {
    border-radius: 4px;
}

.table th {
    font-weight: 600;
    background-color: #f8f9fa;
}

/* 性能监控页面特定样式 */
.performance-card {
    margin-bottom: 20px;
    box-shadow: 0 0.125rem 0.25rem rgba(0, 0, 0, 0.075);
}

.chart-container {
    position: relative;
    height: 250px;
    margin-bottom: 20px;
}

.status-badge {
    font-size: 0.8rem;
    padding: 0.25rem 0.5rem;
}

.metric-value {
    font-size: 1.5rem;
    font-weight: bold;
}

.metric-label {
    font-size: 0.8rem;
    color: #6c757d;
}
EOF
fi

# 9. 创建iSCSI图标文件
echo "[INFO] 创建iSCSI图标文件..."

# 创建SVG图标
cat > "/app/static/iscsi-icon.svg" << 'EOF'
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
  <circle cx="256" cy="256" r="240" fill="#f8f9fa" stroke="#0d6efd" stroke-width="32"/>
  <g fill="#0d6efd">
    <rect x="128" y="176" width="256" height="32" rx="16"/>
    <rect x="128" y="240" width="256" height="32" rx="16"/>
    <rect x="128" y="304" width="256" height="32" rx="16"/>
    <circle cx="160" cy="192" r="24"/>
    <circle cx="352" cy="256" r="24"/>
    <circle cx="160" cy="320" r="24"/>
  </g>
</svg>
EOF

# 10. 重新加载tgt配置
echo "[INFO] 重新加载tgt配置..."
tgt-admin --update ALL

# 11. 完成优化
echo "[SUCCESS] LUN优化完成！"
echo "性能监控脚本已创建: $MONITOR_SCRIPT"
echo "可以通过Web界面的'性能监控'页面查看LUN性能指标"
echo "或者手动运行: bash $MONITOR_SCRIPT"