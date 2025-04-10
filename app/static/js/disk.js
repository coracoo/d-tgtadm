// 磁盘管理相关JavaScript函数

// 创建虚拟磁盘
function createDisk(event) {
    event.preventDefault();
    
    // 获取表单数据
    const diskName = document.getElementById('disk_name').value;
    const diskSize = document.getElementById('disk_size').value;
    const diskUnit = document.getElementById('disk_unit').value;
    const createMethod = document.getElementById('create_method').value;

    // 显示加载状态
    const submitBtn = event.submitter;
    const originalText = submitBtn.innerHTML;
    submitBtn.disabled = true;
    submitBtn.innerHTML = '<span class="spinner-border spinner-border-sm" role="status" aria-hidden="true"></span> 创建中...';
    
    // 发送请求到后端
    fetch('/disk/create', {
        method: 'POST',
        headers: {
            'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: new URLSearchParams({
            'disk_name': diskName,
            'disk_size': diskSize,
            'disk_unit': diskUnit,
            'create_method': createMethod
        })
    })
    .then(response => response.json())
    .then(data => {
        // 恢复按钮状态
        submitBtn.disabled = false;
        submitBtn.innerHTML = originalText;
        
        // 关闭模态框
        const modal = bootstrap.Modal.getInstance(document.getElementById('createDiskModal'));
        modal.hide();
        
        // 显示结果消息
        if (data.success) {
            showAlert('success', data.message);
            // 刷新页面以显示新创建的磁盘
            setTimeout(() => {
                window.location.reload();
            }, 1500);
        } else {
            showAlert('danger', `创建失败: ${data.message}`);
        }
    })
    .catch(error => {
        // 恢复按钮状态
        submitBtn.disabled = false;
        submitBtn.innerHTML = originalText;
        
        // 显示错误消息
        showAlert('danger', `请求错误: ${error}`);
    });
}

// 显示提示消息
function showAlert(type, message) {
    const alertContainer = document.createElement('div');
    alertContainer.className = `alert alert-${type} alert-dismissible fade show`;
    alertContainer.setAttribute('role', 'alert');
    alertContainer.innerHTML = `
        ${message}
        <button type="button" class="btn-close" data-bs-dismiss="alert" aria-label="Close"></button>
    `;
    
    // 添加到页面顶部
    const container = document.querySelector('.container');
    container.insertBefore(alertContainer, container.firstChild);
    
    // 自动关闭
    setTimeout(() => {
        alertContainer.classList.remove('show');
        setTimeout(() => alertContainer.remove(), 150);
    }, 5000);
}