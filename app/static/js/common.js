/**
 * 通用功能模块 - 处理所有共享的功能和工具函数
 */

/**
 * 日志处理功能 - 向日志区域添加新的日志条目
 * @param {string} message - 要显示的日志消息
 * @param {string} type - 日志类型 (info, success, warning, danger)
 */
function appendLog(message, type = 'info') {
    const logArea = document.getElementById('logArea');
    if (!logArea) return;
    
    const logEntry = document.createElement('div');
    logEntry.className = 'log-entry';
    const timestamp = new Date().toLocaleTimeString();
    logEntry.innerHTML = `<span class="text-${type}">[${timestamp}] ${message}</span>`;
    logArea.appendChild(logEntry);
    // 自动滚动到底部
    logArea.scrollTop = logArea.scrollHeight;
}

/**
 * 通用表单提交处理函数
 * @param {Event} event - 表单提交事件
 * @param {string} url - 提交的目标URL
 */
function submitForm(event, url) {
    event.preventDefault();
    const form = event.target;
    const formData = new FormData(form);
    
    console.log(`提交表单到 ${url}`, Object.fromEntries(formData));
    
    fetch(url, {
        method: 'POST',
        body: formData
    })
    .then(response => {
        if (!response.ok) {
            throw new Error(`HTTP error! status: ${response.status}`);
        }
        return response.text().then(text => {
            try {
                return text ? JSON.parse(text) : {};
            } catch (e) {
                console.error('解析响应失败:', e, text);
                return { success: true };
            }
        });
    })
    .then(data => {
        console.log('响应数据:', data);
        if (data.success) {
            window.location.reload();
        } else {
            alert(data.message || '操作失败');
        }
    })
    .catch(error => {
        console.error('Error:', error);
        alert('操作失败：' + error.message);
    });
}

/**
 * 通用AJAX操作函数 - 用于提交数据到服务器
 * @param {string} url - 请求URL
 * @param {Object} data - 要发送的数据
 * @param {string} confirmMsg - 确认消息，如果提供则会显示确认对话框
 */
function submitAction(url, data, confirmMsg) {
    if (confirmMsg && !confirm(confirmMsg)) {
        return;
    }
    
    fetch(url, {
        method: 'POST',
        headers: {
            'Content-Type': 'application/json'
        },
        body: JSON.stringify(data)
    })
    .then(response => response.json())
    .then(data => {
        if (data.success) {
            location.reload();
        } else {
            alert(data.message || '操作失败');
        }
    })
    .catch(error => {
        console.error('Error:', error);
        alert('操作失败');
    });
}

/**
 * 通用删除操作函数
 * @param {string} url - 删除请求的URL
 * @param {string} confirmMsg - 确认消息
 */
function submitDelete(url, confirmMsg) {
    if (confirmMsg && !confirm(confirmMsg)) {
        return;
    }
    
    fetch(url, {
        method: 'POST'
    })
    .then(response => response.json())
    .then(data => {
        if (data.success) {
            location.reload();
        } else {
            alert(data.message || '操作失败');
        }
    })
    .catch(error => {
        console.error('Error:', error);
        alert('操作失败');
    });
}

/**
 * 页面加载完成后初始化通用功能
 */
document.addEventListener('DOMContentLoaded', function() {
    // 清空旧日志
    const logArea = document.getElementById('logArea');
    if (logArea) {
        logArea.innerHTML = '';
        appendLog('系统就绪，等待操作...');
    }
    
    // 刷新Target列表按钮事件
    const refreshTargetsBtn = document.getElementById('refreshTargetsBtn');
    if (refreshTargetsBtn) {
        refreshTargetsBtn.addEventListener('click', async function() {
            try {
                appendLog('正在刷新Target列表...');
                const response = await fetch('/refresh_targets', {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/json'
                    }
                });
                const data = await response.json();
                if (data.success) {
                    appendLog('Target列表刷新成功', 'success');
                    // 刷新页面以显示更新后的列表
                    location.reload();
                } else {
                    appendLog('刷新失败: ' + data.message, 'danger');
                }
            } catch (error) {
                appendLog('刷新请求失败: ' + error.message, 'danger');
            }
        });
    }
    
    // 获取系统状态
    fetch('/api/status')
        .then(response => response.json())
        .then(data => {
            // 更新状态指示器
            const tgtStatus = document.getElementById('tgt-status');
            const tgtStatusText = document.getElementById('tgt-status-text');
            
            if (tgtStatus && tgtStatusText) {
                if (data.tgt_running) {
                    tgtStatus.className = 'status-indicator status-active';
                    tgtStatusText.textContent = 'iSCSI服务运行中';
                } else {
                    tgtStatus.className = 'status-indicator status-inactive';
                    tgtStatusText.textContent = 'iSCSI服务未运行';
                }
            }
            
            // 更新计数
            const targetCount = document.getElementById('target-count');
            const lunCount = document.getElementById('lun-count');
            const diskCount = document.getElementById('disk-count');
            
            if (targetCount) targetCount.textContent = data.target_count;
            if (lunCount) lunCount.textContent = data.lun_count;
            if (diskCount) diskCount.textContent = data.disk_count;
            
            // 更新扫描目录信息
            //const diskDirs = document.getElementById('disk-dirs');
            //if (diskDirs && data.disk_dirs) {
            //    diskDirs.textContent = data.disk_dirs.join(', ');
                
                // 填充磁盘目录下拉框
            //    const diskDirSelect = document.getElementById('disk_dir_select');
            //    if (diskDirSelect) {
                    // 清空现有选项
            //        while (diskDirSelect.options.length > 1) {
            //            diskDirSelect.remove(1);
            //        }
                    
                    // 添加目录选项
           //         data.disk_dirs.forEach(dir => {
            //            const option = document.createElement('option');
            //            option.value = dir;
            //            option.textContent = dir;
            //            diskDirSelect.appendChild(option);
           //         });
            //    }
           // }
            
            // 如果有默认IQN值，填充到下拉框
            if (data.default_iqns) {
                const defaultIqnSelect = document.getElementById('default_iqn_select');
                if (defaultIqnSelect) {
                    // 清空现有选项
                    while (defaultIqnSelect.options.length > 1) {
                        defaultIqnSelect.remove(1);
                    }
                    
                    // 添加默认IQN选项
                    if (data.default_iqns.default) {
                        const option = document.createElement('option');
                        option.value = data.default_iqns.default;
                        option.textContent = '默认IQN';
                        defaultIqnSelect.appendChild(option);
                    }
                    
                    if (data.default_iqns.env) {
                        const option = document.createElement('option');
                        option.value = data.default_iqns.env;
                        option.textContent = '环境变量IQN';
                        defaultIqnSelect.appendChild(option);
                    }
                }
            }
        })
        .catch(error => console.error('获取状态失败:', error));
});