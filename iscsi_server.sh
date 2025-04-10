#!/bin/bash

# =====================================================
# 配置参数定义
# =====================================================

# 配置文件持久化目录
ISCSI_CONFIG_DIR="/app/config"
TGT_CONFIG_DIR="/etc/tgt"
TGT_LIB_DIR="/var/lib/tgt"

# iSCSI Target配置
TARGET_IQN="iqn.2025-05.com.cherry:target1"
DISK_INFO_FILE="/tmp/iscsi_disk_info.json"

# 默认存储目录
DEFAULT_DIRS=("/app/iscsi")

# 支持从环境变量覆盖配置
[ -n "$TARGET_IQN_ENV" ] && TARGET_IQN="$TARGET_IQN_ENV"
[ -n "$DISK_PATH_ENV" ] && SINGLE_DISK_PATH="$DISK_PATH_ENV"

# 递归扫描深度（默认为4级）
SCAN_DEPTH=${SCAN_DEPTH:-4}

# =====================================================
# 函数定义
# =====================================================

# 启动tgt服务并等待就绪
start_tgt_service() {
  echo "[INFO] 启动tgt服务..."
  
  # 启动服务（必须指定--foreground防止后台退出）
  /usr/sbin/tgtd --foreground &
  
  # 等待服务启动（最多10秒）
  timeout=10
  while [ $timeout -gt 0 ]; do
    if tgtadm --lld iscsi --mode system --op show; then
      break
    fi
    sleep 1
    ((timeout--))
  done
  
  if [ $timeout -eq 0 ]; then
    echo "[ERROR] tgt服务启动超时(10s)！"
    exit 1
  fi
  
  echo "[SUCCESS] tgt服务已启动"
}

# 获取磁盘类型函数
get_disk_type() {
  local disk_name=$1
  local disk_type="img"
  
  # 根据文件名后缀或前缀判断磁盘类型
  if [[ "$disk_name" == lvm-* ]]; then
    disk_type="lvm"
  elif [[ "$disk_name" == *".vhd" ]] || [[ "$disk_name" == *".vhdx" ]]; then
    disk_type="vhd"
  elif [[ "$disk_name" == *".vmdk" ]]; then
    disk_type="vmdk"
  elif [[ "$disk_name" == *".qcow2" ]]; then
    disk_type="qcow2"
  elif [[ "$disk_name" == *".img" ]]; then
    disk_type="img"
  elif [[ "$disk_name" == *".iso" ]]; then
    disk_type="iso"
  elif [[ "$disk_name" == *".raw" ]]; then
    disk_type="raw"
  fi
  
  echo "$disk_type"
}

# 添加磁盘到LUN函数
add_disk_to_lun() {
  local disk=$1
  local lun_num=$2
  
  # 检查文件是否存在且可读
  if [ ! -f "$disk" ] || [ ! -r "$disk" ]; then
    echo "[ERROR] 磁盘文件 $disk 不存在或无法读取！"
    return 1
  fi
  
  # 获取磁盘大小（字节）
  local disk_size=$(stat -c %s "$disk")
  # 转换为GB并保留两位小数
  local size_gb=$(awk "BEGIN {printf \"%.2f\", $disk_size/(1024*1024*1024)}")
  
  # 判断磁盘类型
  local disk_name=$(basename "$disk")
  local disk_type=$(get_disk_type "$disk_name")
  
  # 添加为LUN
  tgtadm --lld iscsi --mode logicalunit --op new --tid 1 --lun $lun_num -b "$disk"
  
  if [ $? -eq 0 ]; then
    echo "[SUCCESS] 已添加LUN$lun_num: $disk ($size_gb GB, $disk_type)"
    
    # 将磁盘信息添加到JSON文件
    # 先读取现有内容
    local disks_json=$(cat "$DISK_INFO_FILE")
    # 添加新磁盘信息并写回文件
    local new_disk_json="{\"path\":\"$disk\",\"lun_id\":$lun_num,\"size\":\"$size_gb GB\",\"type\":\"$disk_type\",\"target_id\":1,\"used_by\":{\"target_id\":1,\"lun_id\":$lun_num}}"
    if [ "$disks_json" == "[]" ]; then
      echo "[$new_disk_json]" > "$DISK_INFO_FILE"
    else
      # 移除最后的 ]
      disks_json=${disks_json%]}
      # 添加新磁盘信息
      echo "${disks_json},${new_disk_json}]" > "$DISK_INFO_FILE"
    fi
    
    return 0
  else
    echo "[ERROR] 添加LUN失败: $disk"
    return 1
  fi
}

# 递归扫描目录中的磁盘文件
scan_directory() {
  local dir=$1
  local current_depth=$2
  local max_depth=$3
  local lun_ref=$4
  
  # 检查当前深度是否超过最大深度
  if [ $current_depth -gt $max_depth ]; then
    return
  fi
  
  echo "[INFO] 扫描目录: $dir (深度: $current_depth/$max_depth)"
  
  # 检查目录是否存在
  if [ ! -d "$dir" ]; then
    echo "[WARNING] 目录 $dir 不存在，尝试创建..."
    mkdir -p "$dir"
    chmod 755 "$dir"
    if [ ! -d "$dir" ]; then
      echo "[ERROR] 无法创建目录 $dir"
      return
    fi
  fi
  
  # 检查目录是否为空
  if [ -z "$(ls -A "$dir" 2>/dev/null)" ]; then
    echo "[INFO] 目录 $dir 为空"
    return
  fi
  
  # 扫描当前目录中的文件
  for item in "$dir"/*; do
    # 处理通配符不匹配的情况
    if [ ! -e "$item" ]; then
      echo "[WARNING] 目录 $dir 中没有找到任何文件"
      break
    fi
    
    echo "[DEBUG] 检查项目: $item"
    # 如果是文件，尝试添加为LUN
    if [ -f "$item" ] && [ -r "$item" ]; then
      echo "[DEBUG] 发现磁盘文件: $item"
      if add_disk_to_lun "$item" "${!lun_ref}"; then
        # 增加LUN编号
        eval "$lun_ref=$((${!lun_ref} + 1))"
      fi
    # 如果是目录且未超过最大深度，递归扫描
    elif [ -d "$item" ] && [ $current_depth -lt $max_depth ]; then
      scan_directory "$item" $((current_depth + 1)) $max_depth "$lun_ref"
    fi
  done
}

# 配置iSCSI Target
setup_iscsi_target() {
  echo "[INFO] 启动iSCSI服务..."
  
  # 检查是否存在持久化的targets.conf配置文件
  if [ -f "$ISCSI_CONFIG_DIR/tgt/conf.d/docker.conf" ]; then
    echo "[INFO] 发现持久化的./config/tgt/conf.d/docker.conf配置文件，尝试加载..."
    if tgt-admin -e -c "$ISCSI_CONFIG_DIR/tgt/targets.conf"; then
      echo "[SUCCESS] 成功加载targets.conf配置文件"
      # 开放访问
      tgtadm --lld iscsi --mode target --op bind --tid 1 -I ALL
      return 0
    else
      echo "[WARNING] 加载targets.conf配置文件失败，将执行自动扫描流程"
    fi
  else
    echo "[INFO] 未找到targets.conf配置文件，将执行自动扫描流程"
  fi
  
  # 创建主Target
  tgtadm --lld iscsi --mode target --op new --tid 1 --targetname $TARGET_IQN
  
  # 记录发现的磁盘信息到文件，供Web界面使用
  echo "[]" > "$DISK_INFO_FILE"
  
  # 自动发现存储目录中的虚拟磁盘文件并添加为LUN
  LUN_NUM=1
  
  # 处理单磁盘模式（如果指定了DISK_PATH_ENV）
  if [ -n "$DISK_PATH_ENV" ]; then
    echo "[INFO] 使用指定磁盘: $SINGLE_DISK_PATH"
    
    # 检查存储文件是否存在
    if [ ! -e "$SINGLE_DISK_PATH" ]; then
      echo "[ERROR] 存储文件 $SINGLE_DISK_PATH 不存在！"
      exit 1
    fi
    
    # 添加单个磁盘
    if add_disk_to_lun "$SINGLE_DISK_PATH" $LUN_NUM; then
      ((LUN_NUM++))
    else
      echo "[ERROR] 无法添加指定磁盘: $SINGLE_DISK_PATH"
      exit 1
    fi
  else
    # 多磁盘模式
    # 解析自定义目录
    CUSTOM_DIRS=()
    if [ -n "$ISCSI_DISK_DIRS" ]; then
      IFS=',' read -ra CUSTOM_DIRS <<< "$ISCSI_DISK_DIRS"
      echo "[INFO] 已配置自定义存储目录: ${CUSTOM_DIRS[*]}"
    fi
    
    # 合并默认目录和自定义目录
    ALL_DIRS=("${DEFAULT_DIRS[@]}" "${CUSTOM_DIRS[@]}")
    
    # 创建所有目录
    for dir in "${ALL_DIRS[@]}"; do
      if [ ! -d "$dir" ]; then
        mkdir -p "$dir"
        chmod 755 "$dir"
        echo "[INFO] 创建存储目录: $dir"
      fi
    done
    
    # 支持多种格式的虚拟磁盘
    echo "[INFO] 开始扫描虚拟磁盘(最大深度: $SCAN_DEPTH)..."
    
    # 扫描所有配置的目录
    for dir in "${ALL_DIRS[@]}"; do
      if [ -d "$dir" ]; then
        scan_directory "$dir" 1 $SCAN_DEPTH "LUN_NUM"
      fi
    done
  fi
  
  # 开放访问
  tgtadm --lld iscsi --mode target --op bind --tid 1 -I ALL
  
  # 验证 target 是否真正创建成功
  if ! tgtadm --lld iscsi --mode target --op show | grep -q "Target 1"; then
    echo "[ERROR] Target 创建失败，尝试重新创建..."
    # 重新创建 target
    tgtadm --lld iscsi --mode target --op new --tid 1 --targetname $TARGET_IQN
    # 重新添加 LUN
    LUN_NUM=1
    # ... 重新扫描磁盘并添加 LUN 的代码 ...
  fi

  # 检查是否成功添加了LUN
  if [ $LUN_NUM -eq 1 ]; then
    echo "[WARNING] 未找到任何虚拟磁盘文件，请确认已正确映射磁盘到容器"
    echo "[INFO] 支持的目录: ${ALL_DIRS[*]}"
    echo "[INFO] 您可以通过环境变量ISCSI_DISK_DIRS添加额外的扫描目录"
  else
    echo "[SUCCESS] iSCSI服务已启动 | Target IQN: $TARGET_IQN | LUN总数: $((LUN_NUM-1))"
    
    # 输出磁盘信息摘要
    echo "[INFO] 磁盘信息已保存到 $DISK_INFO_FILE"
    cat "$DISK_INFO_FILE"
  fi
}

# 应用LUN优化
apply_lun_optimization() {
  if [ -f "/optimize_lun.sh" ]; then
    echo "[INFO] 正在应用LUN优化..."
    
    # 确保优化配置目录存在
    mkdir -p "/app/config/optimize"
    chmod 755 "/app/config/optimize"
    
    # 确保Web界面目录存在
    mkdir -p "/app/templates"
    chmod 755 "/app/templates"
    
    # 执行优化脚本
    if bash /optimize_lun.sh; then
      echo "[SUCCESS] LUN优化完成"
    else
      echo "[WARNING] LUN优化过程中出现一些警告，但服务仍可继续运行"
    fi
  else
    echo "[WARNING] 未找到LUN优化脚本，跳过优化步骤"
  fi
}

# 启动Web管理界面
start_web_interface() {
  # 检查应用文件是否已存在，不存在则复制到正确位置
  if [ ! -f "/app/app.py" ] && [ -f "/app.py" ]; then
    echo "[INFO] 复制app.py到/app/目录"
    cp -r /app.py /app/
  fi
  
  if [ ! -d "/app/templates" ] && [ -d "/templates" ]; then
    echo "[INFO] 复制templates目录到/app/目录"
    cp -r /templates /app/templates
  fi
  
  if [ ! -d "/app/static" ] && [ -d "/static" ]; then
    echo "[INFO] 复制static目录到/app/目录"
    cp -r /static /app/static
  fi
  
  if [ ! -d "/app/assets" ] && [ -d "/assets" ]; then
    echo "[INFO] 复制assets目录到/app/目录"
    cp -r /assets /app/assets
  fi

  # 确保Nginx配置目录存在
  mkdir -p /etc/nginx/conf.d
  
  # 复制并检查Nginx配置
  cp -r /nginx.conf /etc/nginx/conf.d/iscsi.conf
  echo "[INFO] 已复制Nginx配置到 /etc/nginx/conf.d/iscsi.conf"
  
  # 检查Nginx配置是否有效
  nginx -t
  if [ $? -ne 0 ]; then
    echo "[WARNING] Nginx配置测试失败，尝试使用默认配置"
    cat > /etc/nginx/conf.d/iscsi.conf << EOF
# 全局配置
worker_processes auto;
pid /run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    
    sendfile        on;
    keepalive_timeout  65;
    
    server {
        listen 13260;
        server_name localhost;
        
        location / {
            proxy_pass http://127.0.0.1:5000;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        }
        
        location /app/static {
            alias /app/static;
            expires 30d;
        }
        
        location /app/assets {
            alias /app/assets;
            expires 30d;
        }

        access_log /var/log/nginx/iscsi_access.log;
        error_log /var/log/nginx/iscsi_error.log;
    }
}
EOF
  fi
  
  # 启动Web管理界面
  echo "[INFO] 正在启动Web管理界面..."
  cd /app && gunicorn -b 127.0.0.1:5000 app:app --daemon
  
  # 启动Nginx
  echo "[INFO] 启动Nginx服务..."
  # 先停止可能已经运行的nginx实例
  nginx -s stop 2>/dev/null || true
  # 备份并替换默认nginx配置
  if [ -f "/etc/nginx/nginx.conf" ]; then
    mv /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak
  fi
  # 创建主配置文件，直接包含我们的配置
  cat > /etc/nginx/nginx.conf << EOF
# 包含自定义配置
include /etc/nginx/conf.d/iscsi.conf;
EOF
  
  # 启动nginx，使用默认配置路径（现在已经指向我们的配置）
  /usr/sbin/nginx -g "daemon off;" &
  
  echo "[SUCCESS] Web管理界面已启动，访问地址: http://<容器IP>:13260"
}

# 保存配置到持久化目录
save_config() {
  echo "[INFO] 正在保存tgt配置到持久化目录..."
  
  # 使用tgt-admin --dump获取当前配置并保存到targets.conf
  echo "[INFO] 导出当前target配置..."
  tgt-admin --dump | grep -v '^>' | grep -v '^default-driver' > "$TGT_CONFIG_DIR/conf.d/docker.conf"
  
  # 复制配置文件到持久化目录
  cp -rf "$TGT_CONFIG_DIR/"* "$ISCSI_CONFIG_DIR/tgt/"
  
  # 保存运行时数据
  if [ -d "$TGT_LIB_DIR" ] && [ "$(ls -A $TGT_LIB_DIR)" ]; then
    cp -rf "$TGT_LIB_DIR/"* "$ISCSI_CONFIG_DIR/tgt_lib/"
  fi
  
  echo "[INFO] 配置文件已保存到持久化目录"
 
  # 验证配置是否正确保存
  if [ -f "$ISCSI_CONFIG_DIR/tgt/targets.conf" ] && [ -s "$ISCSI_CONFIG_DIR/tgt/targets.conf" ]; then
    echo "[SUCCESS] 配置文件成功保存"
  else
    echo "[ERROR] 配置文件保存失败或为空"
  fi
}

# =====================================================
# 主程序
# =====================================================

# 确保持久化目录存在
mkdir -p "$ISCSI_CONFIG_DIR/tgt" "$ISCSI_CONFIG_DIR/tgt_lib"

# 如果持久化目录中存在配置文件，则复制到系统目录
if [ -d "$ISCSI_CONFIG_DIR/tgt" ] && [ "$(ls -A $ISCSI_CONFIG_DIR/tgt)" ]; then
  echo "[INFO] 正在加载持久化的tgt配置文件..."
  cp -rf "$ISCSI_CONFIG_DIR/tgt/"* "$TGT_CONFIG_DIR/"
else
  # 首次运行，将默认配置复制到持久化目录
  echo "[INFO] 首次运行，初始化tgt配置文件..."
  cp -rf "$TGT_CONFIG_DIR/"* "$ISCSI_CONFIG_DIR/tgt/"
fi

# 处理tgt运行时数据目录
if [ -d "$ISCSI_CONFIG_DIR/tgt_lib" ] && [ "$(ls -A $ISCSI_CONFIG_DIR/tgt_lib)" ]; then
  echo "[INFO] 正在加载持久化的tgt运行时数据..."
  cp -rf "$ISCSI_CONFIG_DIR/tgt_lib/"* "$TGT_LIB_DIR/"
fi

# 启动tgt服务
start_tgt_service

# 配置iSCSI服务
setup_iscsi_target

# 启动Web管理界面
start_web_interface

# 保存初始化配置
save_config

# 应用LUN优化
apply_lun_optimization

# 注册退出信号处理
trap save_config SIGTERM SIGINT

# 启动后台配置保存进程，每5分钟保存一次配置
(while true; do
  sleep 300
  echo "[INFO] 每5分钟，定期保存配置文件到持久化目录..."
  save_config
done) &

# 持久化运行
echo "[INFO] iSCSI服务已启动，配置文件将自动持久化保存"
exec tail -f /dev/null