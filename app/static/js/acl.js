/**
 * 访问控制模块 - 处理所有与访问控制相关的功能
 */

/**
 * 设置访问控制的AJAX函数
 */
function setAcl(event) {
    event.preventDefault();
    const form = document.getElementById('aclForm');
    const formData = new FormData(form);
    
    // 检查输入值是否为ALL，如果是则设置action为all，否则为bind
    const initiatorInput = document.getElementById('initiator_address');
    const actionType = document.getElementById('action_type');
    
    if (initiatorInput && initiatorInput.value.trim().toUpperCase() === 'ALL') {
        formData.set('action', 'all');
    } else {
        formData.set('action', 'bind');
    }

    fetch('/target/acl', {
        method: 'POST',
        body: formData
    })
    .then(response => response.json())
    .then(data => {
        if (data.success) {
            location.reload();
        } else {
            alert('设置失败: ' + (data.message || '未知错误'));
        }
    })
    .catch(error => {
        console.error('Error:', error);
        alert('操作失败：' + error.message);
    });
}

// 初始化访问控制模态框事件
function initAclModal() {
    console.log('初始化访问控制模态框...');
    
    // 确保访问控制模态框被正确初始化
    const setAclModal = document.getElementById('setAclModal');
    if (setAclModal) {
        // 使用Bootstrap的Modal构造函数初始化模态框
        new bootstrap.Modal(setAclModal);
        
        setAclModal.addEventListener('show.bs.modal', function(event) {
            const button = event.relatedTarget;
            const tid = button.getAttribute('data-tid');
            const aclListJson = button.getAttribute('data-acl-list');
            
            console.log('访问控制模态框打开，Target ID:', tid);
            document.getElementById('acl_tid').value = tid;
            
            // 显示加载状态
            const initiatorInput = document.getElementById('initiator_address');
            
            // 获取ACL列表显示区域
            const currentAclList = document.getElementById('current_acl_list');
            
            // 从按钮属性中获取初始值
            try {
                if (aclListJson) {
                    const aclList = JSON.parse(aclListJson);
                    if (aclList && aclList.length > 0) {
                        // 清空输入框，只用于添加新的ACL
                        initiatorInput.value = '';
                        initiatorInput.placeholder = '添加新的访问控制项';
                        
                        // 显示当前ACL列表
                        displayAclList(currentAclList, aclList);
                    } else {
                        currentAclList.innerHTML = '<div class="text-center text-muted">暂无访问控制项</div>';
                        initiatorInput.placeholder = '输入ALL允许所有访问，或输入IP地址/IQN，用逗号分隔';
                    }
                } else {
                    currentAclList.innerHTML = '<div class="text-center text-muted">暂无访问控制项</div>';
                    initiatorInput.placeholder = '输入ALL允许所有访问，或输入IP地址/IQN，用逗号分隔';
                }
            } catch (e) {
                console.error('解析ACL列表失败:', e);
                currentAclList.innerHTML = '<div class="text-center text-muted">解析ACL列表失败</div>';
                initiatorInput.placeholder = '输入ALL允许所有访问，或输入IP地址/IQN，用逗号分隔';
            }

            
            // 从服务器获取最新的ACL信息
            console.log('正在获取Target ACL信息，请求URL:', `/target/get_acl/${tid}`);
            fetch(`/target/get_acl/${tid}`)
                .then(response => {
                    console.log('收到响应:', response.status);
                    if (!response.ok) {
                        throw new Error(`HTTP error! status: ${response.status}`);
                    }
                    return response.json();
                })
                .then(data => {
                    console.log('获取到ACL信息:', data);
                    
                    // 设置ACL值
                    if (data.data && data.data.acl_list && data.data.acl_list.length > 0) {
                        // 清空输入框，只用于添加新的ACL
                        initiatorInput.value = '';
                        initiatorInput.placeholder = '添加新的访问控制项';
                        
                        // 显示当前ACL列表
                        displayAclList(currentAclList, data.data.acl_list);
                    } else {
                        // 没有现有地址时设置默认提示
                        currentAclList.innerHTML = '<div class="text-center text-muted">暂无访问控制项</div>';
                        initiatorInput.placeholder = '输入ALL允许所有访问，或输入IP地址/IQN，用逗号分隔';
                    }
                    
                    console.log('ACL信息已更新');
                })
                .catch(error => {
                    console.error('获取ACL信息失败:', error);
                    initiatorInput.placeholder = '获取信息失败，请输入ALL或IP地址/IQN，用逗号分隔';
                });
        });
    } else {
        console.error('找不到setAclModal元素');
    }
    
    // 简化后不再需要访问控制模式切换
    const aclForm = document.getElementById('aclForm');

    // 表单提交处理
    if (aclForm) {
        console.log('绑定访问控制表单提交事件');
        aclForm.addEventListener('submit', setAcl);
    }
    
    console.log('访问控制模块初始化完成');
}

/**
 * 显示ACL列表
 * @param {HTMLElement} container - 显示ACL列表的容器元素
 * @param {Array} aclList - ACL列表数组
 */
function displayAclList(container, aclList) {
    // 清空容器
    container.innerHTML = '';
    
    // 检查是否有ALL模式
    if (aclList.includes('ALL') || aclList.includes('all')) {
        container.innerHTML = '<div class="alert alert-success mb-0">允许所有访问</div>';
        return;
    }
    
    // 创建列表显示
    if (aclList.length > 0) {
        const listGroup = document.createElement('div');
        listGroup.className = 'list-group';
        
        aclList.forEach(item => {
            if (item && item.trim()) {
                const listItem = document.createElement('div');
                listItem.className = 'list-group-item d-flex justify-content-between align-items-center';
                
                // 判断是IP还是IQN
                if (item.includes('iqn.')) {
                    listItem.innerHTML = `<span><i class="bi bi-hdd-network me-2"></i>${item}</span>`;
                } else {
                    listItem.innerHTML = `<span><i class="bi bi-pc-display me-2"></i>${item}</span>`;
                }
                
                listGroup.appendChild(listItem);
            }
        });
        
        container.appendChild(listGroup);
    } else {
        container.innerHTML = '<div class="text-center text-muted">暂无访问控制项</div>';
    }
}

/**
 * 清空Target的所有ACL规则
 * @param {string} tid - Target ID
 */
function clearAcl(tid) {
    if (!confirm('确定要清空此Target的所有访问控制规则吗？这将删除所有白名单设置。')) {
        return;
    }
    
    fetch('/target/clear_acl', {
        method: 'POST',
        headers: {
            'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: `tid=${tid}`
    })
    .then(response => response.json())
    .then(data => {
        if (data.success) {
            location.reload();
        } else {
            alert('清空白名单失败: ' + (data.message || '未知错误'));
        }
    })
    .catch(error => {
        console.error('Error:', error);
        alert('操作失败：' + error.message);
    });
}

// 页面加载完成后初始化
document.addEventListener('DOMContentLoaded', function() {
    console.log('DOM加载完成，初始化访问控制模块...');
    initAclModal();
});