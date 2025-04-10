/**
 * Target和LUN管理模块 - 处理所有与Target和LUN相关的功能
 */

/**
 * 删除Target的AJAX函数
 * @param {string} tid - Target ID
 */
function deleteTarget(tid) {
    if (!confirm('确定要删除此Target吗？这将同时删除其下的所有LUN！')) {
        return;
    }
    
    fetch(`/target/delete/${tid}`, {
        method: 'POST',
        headers: {
            'Content-Type': 'application/json'
        }
    })
    .then(response => response.json())
    .then(data => {
        if (data.success) {
            location.reload();
        } else {
            alert(data.message || '删除失败');
        }
    })
    .catch(error => {
        console.error('Error:', error);
        alert('删除失败');
    });
}

/**
 * 更新Target名称
 */
function updateTargetName() {
    const select = document.getElementById('default_iqn_select');
    const input = document.getElementById('target_name');
    if (select.value) {
        input.value = select.value;
    }
}

/**
 * 创建LUN的AJAX函数
 */
function createLun(event) {
    event.preventDefault();
    const form = document.getElementById('createLunForm');
    const formData = new FormData(form);
    
    fetch('/lun/create', {
        method: 'POST',
        body: formData
    })
    .then(response => response.json())
    .then(data => {
        if (data.success) {
            location.reload();
        } else {
            alert(data.message || 'LUN创建失败');
        }
    })
    .catch(error => {
        console.error('Error:', error);
        alert('操作失败，请检查网络连接');
    });
}

/**
 * 创建Target的AJAX函数
 */
function createTarget(event) {
    event.preventDefault();
    const form = document.getElementById('createTargetForm');
    const formData = new FormData(form);
    
    fetch('/target/create', {
        method: 'POST',
        body: formData
    })
    .then(response => response.json())
    .then(data => {
        if (data.success) {
            location.reload();
        } else {
            alert(data.message || 'Target创建失败');
        }
    })
    .catch(error => {
        console.error('Error:', error);
        alert('操作失败，请检查网络连接');
    });
}

/**
 * 初始化Target和LUN相关的模态框和事件
 */
function initTargetLunModals() {
    console.log('初始化Target和LUN模态框...');
    
    // 创建Target表单提交事件
    const createTargetForm = document.getElementById('createTargetForm');
    if (createTargetForm) {
        console.log('绑定创建Target表单事件');
        createTargetForm.addEventListener('submit', createTarget);
    }
    
    // 创建LUN表单提交事件
    const createLunForm = document.getElementById('createLunForm');
    if (createLunForm) {
        console.log('绑定创建LUN表单事件');
        createLunForm.addEventListener('submit', createLun);
    }

    // 刷新Target列表按钮事件已在common.js中定义，此处不再重复定义
    
    // 删除重复的初始化调用
    // initializeModals(); - 已移除重复调用

    // 创建LUN模态框
    const createLunModal = document.getElementById('createLunModal');
    if (createLunModal) {
        createLunModal.addEventListener('show.bs.modal', function(event) {
            const button = event.relatedTarget;
            const tid = button.getAttribute('data-tid');
            const diskPath = button.getAttribute('data-disk-path');
            
            if (tid) {
                document.getElementById('modal_tid').value = tid;
            }
            if (diskPath) {
                document.getElementById('backing_store').value = diskPath;
            }
        });
    }

    // 选择磁盘按钮点击事件
    document.querySelectorAll('.select-disk-btn').forEach(button => {
        button.addEventListener('click', function() {
            const diskPath = this.getAttribute('data-disk-path');
            document.getElementById('backing_store').value = diskPath;
            bootstrap.Modal.getInstance(document.getElementById('selectDiskModal')).hide();
        });
    });

    // 设置重新绑定LUN模态框事件
    const rebindLunModal = document.getElementById('rebindLunModal');
    if (rebindLunModal) {
        rebindLunModal.addEventListener('show.bs.modal', function(event) {
            const button = event.relatedTarget;
            const lunId = button.getAttribute('data-lun-id');
            const backingStore = button.getAttribute('data-backing-store');
            
            if (lunId) {
                document.getElementById('rebind_lun_id').value = lunId;
            }
            
            if (backingStore) {
                document.getElementById('rebind_backing_store').value = backingStore;
            }
        });
    }

    // 设置IQN选择事件
    const defaultIqnSelect = document.getElementById('default_iqn_select');
    if (defaultIqnSelect) {
        defaultIqnSelect.addEventListener('change', updateTargetName);
    }

    // 设置磁盘目录选择事件
    const diskDirSelect = document.getElementById('disk_dir_select');
    if (diskDirSelect) {
        diskDirSelect.addEventListener('change', function() {
            const diskPathInput = document.getElementById('disk_path');
            if (this.value) {
                // 否则只替换路径部分，保留文件名
                const currentPath = diskPathInput.value;
                if (!currentPath || currentPath.lastIndexOf('/') <= 0) {
                    diskPathInput.value = this.value + '/';
                } else {
                    const fileName = currentPath.substring(currentPath.lastIndexOf('/') + 1);
                    diskPathInput.value = this.value + '/' + fileName;
                }
            }
        });
    }

    // 设置磁盘选择模态框事件
    document.addEventListener('click', function(event) {
        if (event.target.classList.contains('select-disk-btn')) {
            const diskPath = event.target.getAttribute('data-disk-path');
            if (diskPath) {
                // 将选中的磁盘路径填入到LUN创建表单中
                document.getElementById('backing_store').value = diskPath;
                // 关闭磁盘选择模态框
                const selectDiskModal = bootstrap.Modal.getInstance(document.getElementById('selectDiskModal'));
                if (selectDiskModal) {
                    selectDiskModal.hide();
                }
            }
        }
    });

    // 设置选择磁盘按钮事件
    const selectDiskBtn = document.getElementById('select_disk_btn');
    if (selectDiskBtn) {
        selectDiskBtn.addEventListener('click', function() {
            // 打开磁盘选择模态框
            const selectDiskModal = new bootstrap.Modal(document.getElementById('selectDiskModal'));
            selectDiskModal.show();
        });
    }

    // 设置磁盘名称与路径的关联
    const diskNameInput = document.getElementById('disk_name');
    const diskPathInput = document.getElementById('disk_path');
    
    if (diskNameInput && diskPathInput) {
        diskNameInput.addEventListener('input', function() {
            // 更新隐藏的磁盘路径字段
            diskPathInput.value = '/app/iscsi/' + this.value;
        });
    }

    // 将LUN删除和解绑操作改为AJAX请求
    document.querySelectorAll('form[action^="/lun/delete"]').forEach(form => {
        form.addEventListener('submit', function(event) {
            event.preventDefault();
            if (!confirm('确定要删除此LUN吗？')) return;

            const formData = new FormData(this);
            fetch('/lun/delete', {
                method: 'POST',
                body: formData
            })
            .then(response => response.json())
            .then(data => {
                if (data.success) {
                    location.reload();
                } else {
                    alert('删除失败: ' + data.message);
                }
            })
            .catch(error => {
                console.error('Error:', error);
                alert('操作失败，请检查网络连接');
            });
        });
    });

    // LUN解绑操作
    document.querySelectorAll('form[action^="/lun/unbind"]').forEach(form => {
        form.addEventListener('submit', function(event) {
            event.preventDefault();
            if (!confirm('确定要解绑此LUN吗？解绑后可以重新绑定到其他Target。')) return;

            const formData = new FormData(this);
            fetch('/lun/unbind', {
                method: 'POST',
                body: formData
            })
            .then(response => response.json())
            .then(data => {
                if (data.success) {
                    location.reload();
                } else {
                    alert('解绑失败: ' + data.message);
                }
            })
            .catch(error => {
                console.error('Error:', error);
                alert('操作失败，请检查网络连接');
            });
        });
    });
    
    console.log('Target-LUN模块初始化完成');
}

/**
 * 初始化所有模态框，确保它们能被正确唤醒
 */
function initializeModals() {
    console.log('初始化所有模态框...');
    
    // 获取所有模态框元素
    const modalElements = [
        'createTargetModal',
        'setAclModal',
        'createLunModal',
        'selectDiskModal',
        'rebindLunModal'
    ];
    
    // 初始化每个模态框
    modalElements.forEach(modalId => {
        const modalElement = document.getElementById(modalId);
        if (modalElement) {
            console.log(`初始化模态框: ${modalId}`);
            // 使用Bootstrap的Modal构造函数初始化模态框
            new bootstrap.Modal(modalElement);
        } else {
            console.error(`找不到模态框元素: ${modalId}`);
        }
    });
    
    console.log('所有模态框初始化完成');
}

// 页面加载完成后初始化
document.addEventListener('DOMContentLoaded', function() {
    console.log('DOM加载完成，初始化Target-LUN模块...');
    initTargetLunModals();
});


/**
 * 删除LUN的AJAX函数
 * @param {string} tid - Target ID
 * @param {string} lun_id - LUN ID
 */
function deleteLun(tid, lun_id) {
    if (!confirm('确定要删除此LUN吗？\n此操作将永久删除LUN，无法恢复！')) {
        return;
    }
    
    const formData = new FormData();
    formData.append('tid', tid);
    formData.append('lun_id', lun_id);
    
    fetch('/lun/delete', {
        method: 'POST',
        body: formData
    })
    .then(response => response.json())
    .then(data => {
        if (data.success) {
            location.reload();
        } else {
            alert(data.message || '删除失败');
        }
    })
    .catch(error => {
        console.error('Error:', error);
        alert('操作失败，请检查网络连接');
    });
}

function showUpdateTargetIdModal(tid) {
    document.getElementById('old_tid').value = tid;
    new bootstrap.Modal(document.getElementById('updateTargetIdModal')).show();
}

function showUpdateLunIdModal(tid, lun_id) {
    document.getElementById('tid_for_lun').value = tid;
    document.getElementById('old_lun_id').value = lun_id;
    new bootstrap.Modal(document.getElementById('updateLunIdModal')).show();
}

function updateTargetId() {
    const form = document.getElementById('updateTargetIdForm');
    const formData = new FormData(form);
    
    fetch('/target/update_id', {
        method: 'POST',
        body: formData
    })
    .then(response => response.json())
    .then(data => {
        if (data.success) {
            location.reload();
        } else {
            alert(data.message || '修改Target ID失败');
        }
    })
    .catch(error => {
        console.error('Error:', error);
        alert('操作失败，请检查网络连接');
    });
}

function updateLunId() {
    const form = document.getElementById('updateLunIdForm');
    const formData = new FormData(form);
    
    fetch('/lun/update_id', {
        method: 'POST',
        body: formData
    })
    .then(response => response.json())
    .then(data => {
        if (data.success) {
            location.reload();
        } else {
            alert(data.message || '修改LUN ID失败');
        }
    })
    .catch(error => {
        console.error('Error:', error);
        alert('操作失败，请检查网络连接');
    });
}