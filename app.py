#!/usr/bin/env python3
# -*- coding: utf-8 -*-

from flask import Flask, render_template, request, redirect, url_for, flash, jsonify
import subprocess
import os
import re
import json
import time
import datetime
import logging
import subprocess
from jinja2.utils import F
from werkzeug.utils import secure_filename
import urllib.parse

MAX_TARGET_ID = 65535  # tgt最大支持65535个target
MAX_LUN_ID = 255      # 每个target最大支持255个LUN

# 配置日志
log_handler_stdout = logging.StreamHandler()
log_handler_file = logging.FileHandler('/app/config/app.log')

# 配置日志
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[log_handler_stdout, log_handler_file]
)
logger = logging.getLogger(__name__)


app = Flask(__name__, 
    static_folder='/app/static', 
    template_folder='/app/templates')
app.secret_key = os.urandom(24)

# 工具函数：执行shell命令并返回结果
def run_command(cmd):
    logger.info(f"执行命令: {cmd}")
    try:
        result = subprocess.run(cmd, shell=True, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, encoding='utf-8')
        output = result.stdout
        logger.info(f"执行命令成功,output: {cmd}")
        return {
            'success': True,
            'output': output,
            'error': None,
            'details': {
                'command': cmd,
                'exit_code': result.returncode,
                'stdout': output,
                'stderr': result.stderr
            }
        }
    except subprocess.CalledProcessError as e:
        error = e.stderr if isinstance(e.stderr, str) else e.stderr.decode('utf-8') if e.stderr else '命令执行失败'
        output = e.stdout if isinstance(e.stdout, str) else e.stdout.decode('utf-8') if e.stdout else ''
        logger.error(f"命令执行失败:\n错误: {error}\n输出: {output}")
        return {
            'success': False,
            'output': output,
            'error': error,
            'details': {
                'command': cmd,
                'exit_code': e.returncode,
                'stdout': output,
                'stderr': error
            }
        }
    except Exception as e:
        error_msg = str(e)
        logger.error(f"执行命令时发生未知错误: {error_msg}")
        return {
            'success': False,
            'output': '',
            'error': error_msg,
            'details': {
                'command': cmd,
                'exit_code': -1,
                'stdout': '',
                'stderr': error_msg
            }
        }

# 获取TGT信息
def get_targets(max_retries=3, retry_delay=1):
    logger.info("获取Target信息...")
    
    for attempt in range(max_retries):
        try:
            result = run_command('tgtadm --lld iscsi --mode target --op show')
            if result['success']:
                break
            logger.warning(f"尝试 {attempt + 1}/{max_retries} 失败: {result['error']}")
            if attempt < max_retries - 1:
                time.sleep(retry_delay)
        except Exception as e:
            logger.warning(f"尝试 {attempt + 1}/{max_retries} 发生异常: {str(e)}")
            if attempt < max_retries - 1:
                time.sleep(retry_delay)
    
    if not result['success']:
        logger.error("获取Target信息失败，已达到最大重试次数")
        return []
    
    logger.info("解析Target信息...")
    targets = []
    current_data = {}
    current_section = None
    current_lun = None
    current_nexus = None
    current_connection = False
    
    for line in result['output'].split('\n'):
        line_content = line.rstrip()
        if not line_content:
            continue
            
        # 计算缩进级别
        indent = len(line_content) - len(line_content.lstrip())
        content = line_content.lstrip()
        
        # Target行处理
        if content.startswith('Target '):
            if current_data:
                targets.append(process_target_data(current_data))
            match = re.search(r'Target (\d+): (.+)', content)
            if match:
                tid, name = match.groups()
                current_data = {
                    'target': {
                        'tid': tid,
                        'name': name
                    },
                    'system_information': {},
                    'lun_information': {},
                    'acl_information': [],
                    'nexus_information': []
                }
            current_section = None
            current_lun = None
            current_nexus = None
            current_connection = False
            continue
        
        # 处理4空格缩进的主要部分（一级数组）
        if indent == 4:
            if content.endswith(':'):
                current_section = content[:-1]
                if current_section == 'LUN information':
                    current_data['lun_information'] = {}
                elif current_section == 'System information':
                    current_data['system_information'] = {}
                elif current_section == 'ACL information':
                    current_data['acl_information'] = []
                elif current_section == 'I_T nexus information':
                    current_data['nexus_information'] = []
            continue
        
        # 处理8空格缩进的子部分（二级数组）
        if indent == 8 and current_section:
            if current_section == 'LUN information':
                if content.startswith('LUN:'):
                    lun_id = content.split(':')[1].strip()
                    current_lun = lun_id
                    current_data['lun_information'][lun_id] = {
                        'lun_id': lun_id,
                        'type': None,
                        'size': None,
                        'backing_store': None,
                        'status': None
                    }
            elif current_section == 'System information':
                if ':' in content:
                    key, value = content.split(':', 1)
                    current_data['system_information'][key.strip()] = value.strip()
            elif current_section == 'ACL information':
                current_data['acl_information'].append(content.strip())
            elif current_section == 'I_T nexus information':
                if content.startswith('I_T nexus:'):
                    nexus_id = content.split(':')[1].strip()
                    current_nexus = {
                        'nexus_id': nexus_id,
                        'initiator': None,
                        'ip_address': None
                    }
                    current_data['nexus_information'].append(current_nexus)
                    current_connection = False
                elif content.startswith('Connection:'):
                    current_connection = True
            continue

        # 处理12空格缩进的部分（LUN详细信息和I_T nexus详细信息）
        if indent == 12:
            if current_section == 'LUN information' and current_lun:
                if ':' in content:
                    key, value = [x.strip() for x in content.split(':', 1)]
                    if key == 'Type':
                        current_data['lun_information'][current_lun]['type'] = value
                    elif key == 'Size':
                        # 将MB转换为GB
                        size_str = value.split(',')[0].strip()
                        try:
                            size_mb = float(size_str.split()[0])
                            size_gb = size_mb / 1024
                            current_data['lun_information'][current_lun]['size'] = f"{size_gb:.2f} GB"
                        except (ValueError, IndexError):
                            current_data['lun_information'][current_lun]['size'] = size_str
                    elif key == 'Backing store path':
                        if value.lower() != 'none':
                            current_data['lun_information'][current_lun]['backing_store'] = value
                    elif key == 'Online':
                        current_data['lun_information'][current_lun]['status'] = 'online' if value == 'Yes' else 'offline'
            elif current_section == 'I_T nexus information' and current_nexus:
                if content.startswith('Initiator:'):
                    current_nexus['initiator'] = content.split(':', 1)[1].strip()

        if indent == 16:
            if current_section == 'I_T nexus information'  and current_nexus:
                if content.startswith('IP Address:'):
                    current_nexus['ip_address'] = content.split(':', 1)[1].strip()

        # if indent == 16:

    # 处理最后一个Target的数据
    if current_data:
        targets.append(process_target_data(current_data))
    
    logger.info(f"Target信息解析完成，{targets}")
    return targets

# 更新LUN信息
def update_lun_info(lun, content):
    type_match = re.search(r'Type:\s+([\w-]+)', content)
    if type_match:
        lun['type'] = type_match.group(1)
        return
    
    size_match = re.search(r'Size:\s+([\d\.]+\s*[KMGTP]?B)', content)
    if size_match:
        lun['size'] = size_match.group(1)
        return
    
    bs_match = re.search(r'Backing store path:\s+([^\s]+)', content)
    if bs_match:
        backing_store = bs_match.group(1).strip('" ')
        if backing_store.lower() != 'none':
            lun['backing_store'] = backing_store
        return
    
    status_match = re.search(r'Online:\s+(Yes|No)', content)
    if status_match:
        lun['status'] = 'online' if status_match.group(1) == 'Yes' else 'offline'

# 处理Target数据并返回标准格式
def process_target_data(data):
    target_info = {
        'tid': data['target']['tid'],
        'name': data['target']['name'],
        'luns': [],
        'initiators': [],
        'acl_list': [],
        'acl_mode': 'whitelist',
        'nexus_information': data.get('nexus_information', [])
    }

    # 处理LUN信息
    if 'lun_information' in data:
        for lun_id, lun_data in data['lun_information'].items():
            if isinstance(lun_data, dict) and lun_data.get('type') != 'controller':
                target_info['luns'].append(lun_data)
    
    # 处理ACL信息
    if 'acl_information' in data:
        # 确保acl_list始终是一个有效的列表
        acl_info = data['acl_information']
        if isinstance(acl_info, list):
            target_info['acl_list'] = acl_info
        else:
            target_info['acl_list'] = []
            
        target_info['acl_mode'] = 'all' if 'ALL' in data.get('acl_information', []) else 'whitelist'
    
    return target_info

# 获取默认IQN值
def get_default_iqns():
    # 使用统一的IQN值，与iscsi_server.sh保持一致
    default_iqns = {}
    
    # 默认IQN值，确保与iscsi_server.sh中的TARGET_IQN保持一致
    default_iqn = 'iqn.2025-05.com.cherry:target1'
    default_iqns['default'] = default_iqn
    
    # 检查环境变量是否覆盖了默认IQN
    env_iqn = os.environ.get('TARGET_IQN_ENV')
    if env_iqn:
        default_iqns['env'] = env_iqn
    
    return default_iqns

# 获取系统中的磁盘文件
def get_disk_files():
    disk_files = []
    base_disk_dir = '/app/iscsi'
    
    # 确保目录存在
    if not os.path.exists(base_disk_dir):
        os.makedirs(base_disk_dir)
        logger.info(f"创建磁盘目录: {base_disk_dir}")

    # 获取当前所有Target的LUN信息
    targets = get_targets()
    lun_mappings = {}
    for target in targets:
        for lun in target.get('luns', []):
            if lun.get('backing_store') and lun.get('type') != 'controller':
                lun_mappings[lun['backing_store']] = {
                    'target_id': target['tid'],
                    'lun_id': lun['lun_id'],
                    'target_name': target['name'],
                    'lun_size': lun['size']
                }
    
    # 按文件名排序
    disk_files = sorted(disk_files, key=lambda x: x['name'].lower())

    # 尝试读取磁盘创建方法信息
    disk_methods = {}
    disk_methods_file = '/app/config/disk_methods.json'
    if os.path.exists(disk_methods_file):
        try:
            with open(disk_methods_file, 'r') as f:
                disk_methods = json.load(f)
            logger.info(f"已加载磁盘创建方法信息: {len(disk_methods)}个记录")
        except Exception as e:
            logger.error(f"读取磁盘创建方法信息失败: {str(e)}")

    # 递归扫描目录及其子目录
    for root, dirs, files in os.walk(base_disk_dir):
        for file in files:
            path = os.path.join(root, file)
            if os.path.isfile(path) and os.access(path, os.R_OK):
                size = os.path.getsize(path) / (1024 * 1024 * 1024)  # 转换为GB
                
                # 根据文件扩展名判断磁盘类型
                disk_type = 'raw'  # 默认为raw类型
                file_lower = file.lower()
                if file_lower.startswith('lvm-'):
                    disk_type = 'lvm'
                elif file_lower.endswith(('.vhd', '.vhdx')):
                    disk_type = 'vhd'
                elif file_lower.endswith('.vmdk'):
                    disk_type = 'vmdk'
                elif file_lower.endswith('.qcow2'):
                    disk_type = 'qcow2'
                elif file_lower.endswith('.img'):
                    disk_type = 'img'
                elif file_lower.endswith('.iso'):
                    disk_type = 'iso'
                elif file_lower.endswith('.raw'):
                    disk_type = 'raw'

                disk_info = {
                    'path': path,
                    'name': file,
                    'size': f"{size:.2f} GB",
                    'type': disk_type,
                    'create_method': disk_methods.get(file, '未知') 
                }
                
                # 添加LUN映射信息
                if path in lun_mappings:
                    disk_info['used_by'] = lun_mappings[path]
                else:
                    disk_info['used_by'] = ''
                
                disk_files.append(disk_info)
    
    return disk_files

# 获取tgtadm命令的原始输出
def get_tgtadm_output():
    logger.info("获取tgtadm命令原始输出...")
    result = run_command('tgtadm --lld iscsi --mode target --op show')
    if result['success']:
        return result['output']
    else:
        logger.error(f"获取tgtadm命令输出失败: {result['error']}")
        return "获取tgtadm命令输出失败，请检查iSCSI服务是否正常运行。"

# 路由：主页
@app.route('/')
def index():
    targets = get_targets()
    disk_files = get_disk_files()
    default_iqns = get_default_iqns()
    tgtadm_output = get_tgtadm_output()
    return render_template('index.html', targets=targets, disk_files=disk_files, default_iqns=default_iqns, tgtadm_output=tgtadm_output)

# 路由：刷新Target列表
@app.route('/refresh_targets', methods=['POST'])
def refresh_targets():
    targets = get_targets()
    return jsonify({
        'success': True,
        'targets': targets
    })

# 添加save_config函数
def save_config():
    logger.info("保存tgt配置到持久化目录...")
    try:
         # 设置正确的locale环境变量
        env = os.environ.copy()
        env['LC_ALL'] = 'C.UTF-8'
        env['LANG'] = 'C.UTF-8'
        
        subprocess.run(
            f'tgt-admin --dump | grep -v "^>" | grep -v "^default-driver" > /etc/tgt/conf.d/docker.conf',
            shell=True, check=True, env=env
        )
        subprocess.run(
            f'cp -rf /etc/tgt/* /app/config/tgt/',
            shell=True, check=True, env=env
        )
        subprocess.run(
            'if [ -d "/var/lib/tgt" ] && [ "$(ls -A /var/lib/tgt)" ]; then '
            'cp -rf /var/lib/tgt/* /app/config/tgt_lib/; '
            'fi',
            shell=True, check=True, env=env
        )
        logger.info("配置保存成功")
        return True
    except subprocess.CalledProcessError as e:
        logger.error(f"配置保存失败: {e.stderr.decode() if e.stderr else str(e)}")
        return False

# 路由：增加Target
@app.route('/target/create', methods=['POST'])
def create_target():
    target_name = request.form.get('target_name')
    tid = request.form.get('tid')
    acl_mode = request.form.get('acl_mode')
    initiator_address = request.form.get('initiator_address')
    
    # 增加ID范围验证
    try:
        tid_num = int(tid)
        if tid_num < 1 or tid_num > MAX_TARGET_ID:
            return jsonify({
                'success': False,
                'message': f'Target ID必须在1到{MAX_TARGET_ID}之间'
            })
    except ValueError:
        return jsonify({
            'success': False,
            'message': 'Target ID必须是有效的数字'
        })
    
    if not target_name or not tid:
        return jsonify({
            'success': False,
            'message': 'Target名称和ID不能为空'
        })
    
    # 在白名单模式下验证initiator_address
    if acl_mode == 'whitelist' and not initiator_address:
        return jsonify({
            'success': False,
            'message': '白名单模式下必须提供至少一个Initiator或IP地址'
        })
    
    # 创建Target
    cmd = f"tgtadm --lld iscsi --mode target --op new --tid {tid} --targetname {target_name}"
    result = run_command(cmd)
    
    if result['success']:
        # 根据ACL模式设置访问控制
        if acl_mode == 'all':
            # 允许所有访问
            cmd_acl = f"tgtadm --lld iscsi --mode target --op bind --tid {tid} -I ALL"
            acl_result = run_command(cmd_acl)
            acl_message = '已设置为允许所有initiator访问'
        else:
            # 配置白名单
            acl_result = {'success': True}
            # 解析并添加每个initiator地址
            initiators = [addr.strip() for addr in initiator_address.split(',') if addr.strip()]
            if not initiators:
                return jsonify({
                    'success': False,
                    'message': '白名单模式下必须提供有效的Initiator或IP地址'
                })
            
            for initiator in initiators:
                cmd_acl = f"tgtadm --lld iscsi --mode target --op bind --tid {tid} -I {initiator}"
                acl_result = run_command(cmd_acl)
                if not acl_result['success']:
                    break
            acl_message = '已配置指定的initiator白名单'
        
        if acl_result['success']:
            # 保存配置
            save_config()
            return jsonify({
                'success': True,
                'message': f'Target {target_name} 创建成功，{acl_message}'
            })
        else:
            return jsonify({
                'success': False,
                'message': f'Target创建成功但设置访问控制失败: {acl_result["error"]}'
            })
    else:
        return jsonify({
            'success': False,
            'message': f'Target创建失败: {result["error"]}'
        })

# 路由：删除Target
@app.route('/target/delete/<tid>', methods=['POST'])
def delete_target(tid):
    # 删除Target
    cmd = f"tgtadm --lld iscsi --mode target --op delete --tid {tid}"
    result = run_command(cmd)
    
    if result['success']:
        # 保存配置
        save_config()
        return jsonify({
            'success': True,
            'message': f'Target (ID: {tid}) 删除成功',
            'data': {
                'tid': tid
            }
        })
    else:
        return jsonify({
            'success': False,
            'message': f'Target删除失败: {result["error"]}',
            'error': result['error'],
            'details': result.get('details', {})
        })

# 路由：修改Target ID
@app.route('/target/update_id', methods=['POST'])
def update_target_id():
    old_tid = request.form.get('old_tid')
    new_tid = request.form.get('new_tid')
    
    try:
        new_tid_num = int(new_tid)
        if new_tid_num < 1 or new_tid_num > MAX_TARGET_ID:
            return jsonify({
                'success': False,
                'message': f'新Target ID必须在1到{MAX_TARGET_ID}之间'
            })
    except ValueError:
        return jsonify({
            'success': False,
            'message': '新Target ID必须是有效的数字'
        })
    
    # 获取旧target的信息
    targets = get_targets()
    old_target = next((t for t in targets if t['tid'] == old_tid), None)
    
    if not old_target:
        return jsonify({
            'success': False,
            'message': '未找到原Target'
        })
    
    # 创建新target
    cmd = f"tgtadm --lld iscsi --mode target --op new --tid {new_tid} --targetname {old_target['name']}"
    result = run_command(cmd)
    
    if not result['success']:
        return jsonify({
            'success': False,
            'message': f'创建新Target失败: {result["error"]}'
        })
    
    # 复制所有LUN到新target
    success = True
    for lun in old_target['luns']:
        cmd = f"tgtadm --lld iscsi --mode logicalunit --op new --tid {new_tid} --lun {lun['lun_id']} -b {lun['backing_store']}"
        result = run_command(cmd)
        if not result['success']:
            success = False
            break
    
    if success:
        # 复制ACL设置
        if old_target['acl_mode'] == 'all':
            cmd = f"tgtadm --lld iscsi --mode target --op bind --tid {new_tid} -I ALL"
            run_command(cmd)
        else:
            for initiator in old_target['acl_list']:
                cmd = f"tgtadm --lld iscsi --mode target --op bind --tid {new_tid} -I {initiator}"
                run_command(cmd)
        
        # 删除旧target
        cmd = f"tgtadm --lld iscsi --mode target --op delete --tid {old_tid}"
        result = run_command(cmd)
        
        if result['success']:
            save_config()
            return jsonify({
                'success': True,
                'message': f'Target ID已更新为 {new_tid}'
            })
    
    return jsonify({
        'success': False,
        'message': '更新Target ID失败'
    })

# 路由：修改LUN ID
@app.route('/lun/update_id', methods=['POST'])
def update_lun_id():
    tid = request.form.get('tid')
    old_lun_id = request.form.get('old_lun_id')
    new_lun_id = request.form.get('new_lun_id')
    
    try:
        new_lun_num = int(new_lun_id)
        if new_lun_num < 1 or new_lun_num > MAX_LUN_ID:
            return jsonify({
                'success': False,
                'message': f'新LUN ID必须在1到{MAX_LUN_ID}之间'
            })
    except ValueError:
        return jsonify({
            'success': False,
            'message': '新LUN ID必须是有效的数字'
        })
    
    # 获取旧LUN的信息
    targets = get_targets()
    target = next((t for t in targets if t['tid'] == tid), None)
    if not target:
        return jsonify({
            'success': False,
            'message': '未找到Target'
        })
    
    old_lun = next((l for l in target['luns'] if l['lun_id'] == old_lun_id), None)
    if not old_lun:
        return jsonify({
            'success': False,
            'message': '未找到原LUN'
        })
    
    # 创建新LUN
    cmd = f"tgtadm --lld iscsi --mode logicalunit --op new --tid {tid} --lun {new_lun_id} -b {old_lun['backing_store']}"
    result = run_command(cmd)
    
    if result['success']:
        # 删除旧LUN
        cmd = f"tgtadm --lld iscsi --mode logicalunit --op delete --tid {tid} --lun {old_lun_id}"
        result = run_command(cmd)
        
        if result['success']:
            save_config()
            return jsonify({
                'success': True,
                'message': f'LUN ID已更新为 {new_lun_id}'
            })
    
    return jsonify({
        'success': False,
        'message': '更新LUN ID失败'
    })

# 路由：创建LUN
@app.route('/lun/create', methods=['POST'])
def create_lun():
    tid = request.form.get('tid')
    lun_id = request.form.get('lun_id')
    backing_store = request.form.get('backing_store')
     
    # 增加LUN ID范围验证
    try:
        lun_id_num = int(lun_id)
        if lun_id_num < 1 or lun_id_num > MAX_LUN_ID:
            return jsonify({
                'success': False,
                'message': f'LUN ID必须在1到{MAX_LUN_ID}之间'
            })
    except ValueError:
        return jsonify({
            'success': False,
            'message': 'LUN ID必须是有效的数字'
        })
   
    if not tid or not lun_id or not backing_store:
        return jsonify({
            'success': False,
            'message': 'Target ID、LUN ID和后备存储不能为空'
        })
    
    # 创建LUN
    cmd = f"tgtadm --lld iscsi --mode logicalunit --op new --tid {tid} --lun {lun_id} -b {backing_store}"
    result = run_command(cmd)
    
    if result['success']:
        # 保存配置
        save_config()
        return jsonify({
            'success': True,
            'message': f'LUN (ID: {lun_id}) 创建成功'
        })
    else:
        return jsonify({
            'success': False,
            'message': f'LUN创建失败: {result["error"]}'
        })

# 路由：删除LUN
@app.route('/lun/delete', methods=['POST'])
def delete_lun():
    tid = request.form.get('tid')
    lun_id = request.form.get('lun_id')
    
    if not tid or not lun_id:
        return jsonify({
            'success': False,
            'message': 'Target ID和LUN ID不能为空',
            'error_code': 'MISSING_PARAMS',
            'required_params': ['tid', 'lun_id']
        })
    
    # 删除LUN
    cmd = f"tgtadm --lld iscsi --mode logicalunit --op delete --tid {tid} --lun {lun_id}"
    result = run_command(cmd)
    
    if result['success']:
        # 保存配置
        save_config()
        return jsonify({
            'success': True,
            'message': f'LUN (ID: {lun_id}) 删除成功',
            'data': {
                'tid': tid,
                'lun_id': lun_id,
                'operation': 'delete'
            }
        })
    else:
        return jsonify({
            'success': False,
            'message': f'LUN删除失败: {result["error"]}',
            'error': result['error'],
            'details': result.get('details', {})
        })

# 路由：重新绑定LUN到指定Target
@app.route('/lun/rebind', methods=['POST'])
def rebind_lun():
    new_tid = request.form.get('new_tid')
    lun_id = request.form.get('lun_id')
    backing_store = request.form.get('backing_store')
    
    if not new_tid or not lun_id or not backing_store:
        return jsonify({
            'success': False,
            'message': 'Target ID、LUN ID和后备存储不能为空',
            'error_code': 'MISSING_PARAMS'
        })
    
    # 创建LUN到新的Target
    cmd = f"tgtadm --lld iscsi --mode logicalunit --op new --tid {new_tid} --lun {lun_id} -b {backing_store}"
    result = run_command(cmd)
    
    if result['success']:
        return jsonify({
            'success': True,
            'message': f'LUN (ID: {lun_id}) 已重新绑定到Target (ID: {new_tid})',
            'data': {
                'new_tid': new_tid,
                'lun_id': lun_id,
                'backing_store': backing_store
            }
        })
    else:
        return jsonify({
            'success': False,
            'message': 'LUN重新绑定失败',
            'error': result['error'],
            'details': result.get('details', {})
        })

# 路由：获取Target的ACL信息
@app.route('/target/get_acl/<tid>', methods=['GET'])
def get_target_acl(tid):
    logger.info(f"收到获取Target ACL信息请求: {tid}")
    
    # 获取所有target信息
    targets = get_targets()
    
    # 查找指定的target
    target = next((t for t in targets if t['tid'] == tid), None)
    logger.info(f"获取Target ACL信息: {tid}, 找到: {bool(target)}")

    if not target:
        logger.warning(f"未找到指定的Target (ID: {tid})")
        return jsonify({
            'success': False,
            'message': f'未找到指定的Target (ID: {tid})',
            'error_code': 'TARGET_NOT_FOUND'
        })
    
    # 返回target的ACL信息
    response_data = {
        'success': True,
        'data': {
            'tid': tid,
            'name': target['name'],
            'acl_mode': target['acl_mode'],
            'acl_list': target['acl_list']
        }
    }
    logger.info(f"返回Target ACL信息: {response_data}")
    return jsonify(response_data)

# 路由：清空Target的所有ACL规则
@app.route('/target/clear_acl', methods=['POST'])
def clear_acl():
    tid = request.form.get('tid')
    
    if not tid:
        return jsonify({
            'success': False,
            'message': 'Target ID不能为空',
            'error_code': 'MISSING_PARAMS'
        })
    
    # 获取当前target的信息
    targets = get_targets()
    current_target = next((t for t in targets if t['tid'] == tid), None)
    
    if not current_target:
        return jsonify({
            'success': False,
            'message': f'未找到指定的Target (ID: {tid})',
            'error_code': 'TARGET_NOT_FOUND'
        })
    
    # 解绑当前target的所有ACL规则
    success = True
    error_message = ''
    
    if current_target.get('acl_list'):
        for initiator in current_target['acl_list']:
            unbind_cmd = f"tgtadm --lld iscsi --mode target --op unbind --tid {tid} -I {initiator}"
            unbind_result = run_command(unbind_cmd)
            if not unbind_result['success']:
                success = False
                error_message = unbind_result['error']
                break
    
    if success:
        # 保存配置
        save_config()
        return jsonify({
            'success': True,
            'message': f'Target (ID: {tid}) 的所有访问控制规则已清空',
            'data': {
                'tid': tid
            }
        })
    else:
        return jsonify({
            'success': False,
            'message': f'清空访问控制规则失败: {error_message}',
            'error': error_message
        })

# 路由：设置访问控制
@app.route('/target/acl', methods=['POST'])
def set_acl():
    tid = request.form.get('tid')
    initiator_address = request.form.get('initiator_address')
    action = request.form.get('action')  # bind, unbind 或 all
    
    if not tid or not action:
        return jsonify({
            'success': False,
            'message': '参数不完整',
            'error_code': 'MISSING_PARAMS',
            'required_params': ['tid', 'action']
        })
    
    if action not in ['bind', 'unbind', 'all']:
        return jsonify({
            'success': False,
            'message': '无效的操作类型',
            'error_code': 'INVALID_ACTION',
            'allowed_actions': ['bind', 'unbind', 'all']
        })
    
    # 获取当前target的信息
    targets = get_targets()
    current_target = next((t for t in targets if t['tid'] == tid), None)
    
    if not current_target:
        return jsonify({
            'success': False,
            'message': f'未找到指定的Target (ID: {tid})',
            'error_code': 'TARGET_NOT_FOUND'
        })
    
    # 如果是all模式，先解绑当前target的所有initiator，然后设置ALL访问
    if action == 'all':
        # 只解绑当前target的ACL列表中的initiator
        if current_target.get('acl_list'):
            for initiator in current_target['acl_list']:
                if initiator != 'ALL':  # 避免重复解绑ALL
                    unbind_cmd = f"tgtadm --lld iscsi --mode target --op unbind --tid {tid} -I {initiator}"
                    unbind_result = run_command(unbind_cmd)
                    if not unbind_result['success']:
                        return jsonify({
                            'success': False,
                            'message': f'解绑initiator {initiator}失败',
                            'error': unbind_result['error']
                        })
        
        # 设置ALL访问
        cmd = f"tgtadm --lld iscsi --mode target --op bind --tid {tid} -I ALL"
        result = run_command(cmd)
        
        if result['success']:
            # 保存配置
            save_config()
            return jsonify({
                'success': True,
                'message': '访问控制设置成功',
                'data': {
                    'tid': tid,
                    'initiator_address': 'ALL',
                    'action': action
                }
            })
        else:
            return jsonify({
                'success': False,
                'message': '访问控制设置失败',
                'error': result['error'],
                'details': result.get('details', {})
            })
    else:
        if not initiator_address:
            return jsonify({
                'success': False,
                'message': 'Initiator地址不能为空',
                'error_code': 'MISSING_PARAMS',
                'required_params': ['initiator_address']
            })
        
        # 如果是bind操作，检查并解绑当前target的ALL访问规则
        if action == 'bind' and 'ALL' in current_target.get('acl_list', []):
            all_unbind_cmd = f"tgtadm --lld iscsi --mode target --op unbind --tid {tid} -I ALL"
            unbind_result = run_command(all_unbind_cmd)
            if not unbind_result['success']:
                return jsonify({
                    'success': False,
                    'message': '解除ALL访问失败',
                    'error': unbind_result['error']
                })
        
        # 处理多个initiator地址，将逗号分隔的地址拆分为单独的地址
        initiator_list = [addr.strip() for addr in initiator_address.split(',') if addr.strip()]
        if not initiator_list:
            return jsonify({
                'success': False,
                'message': 'Initiator地址格式无效',
                'error_code': 'INVALID_INITIATOR_FORMAT'
            })
        
        # 对每个initiator地址执行操作
        success_count = 0
        failed_initiators = []
        
        for initiator in initiator_list:
            cmd = f"tgtadm --lld iscsi --mode target --op {action} --tid {tid} -I {initiator}"
            result = run_command(cmd)
            
            if result['success']:
                success_count += 1
            else:
                failed_initiators.append({
                    'initiator': initiator,
                    'error': result['error']
                })
        
        # 保存配置
        save_config()
        
        # 返回结果
        if success_count == len(initiator_list):
            return jsonify({
                'success': True,
                'message': f'所有 {len(initiator_list)} 个initiator地址的访问控制设置成功',
                'data': {
                    'tid': tid,
                    'initiator_address': initiator_list,
                    'action': action
                }
            })
        elif success_count > 0:
            return jsonify({
                'success': True,
                'message': f'部分initiator地址的访问控制设置成功 ({success_count}/{len(initiator_list)})',
                'data': {
                    'tid': tid,
                    'initiator_address': initiator_list,
                    'action': action,
                    'failed_initiators': failed_initiators
                }
            })
        else:
            return jsonify({
                'success': False,
                'message': '所有initiator地址的访问控制设置失败',
                'error': failed_initiators[0]['error'] if failed_initiators else '未知错误',
                'details': {
                    'failed_initiators': failed_initiators
                }
            })
    
    if result['success']:
        # 保存配置
        save_config()
        return jsonify({
            'success': True,
            'message': '访问控制设置成功',
            'data': {
                'tid': tid,
                'initiator_address': initiator_address if action != 'all' else 'ALL',
                'action': action
            }
        })
    else:
        return jsonify({
            'success': False,
            'message': '访问控制设置失败',
            'error': result['error'],
            'details': result.get('details', {})
        })

# 路由：创建虚拟磁盘
@app.route('/disk/create', methods=['POST'])
def create_disk():
    disk_name = request.form.get('disk_name')
    disk_size = request.form.get('disk_size')
    disk_unit = request.form.get('disk_unit', 'G')  # 默认单位为GB
    create_method = request.form.get('create_method', 'qemu')  # 默认使用qemu方式

    if not disk_name or not disk_size:
        return jsonify({
            'success': False,
            'message': '磁盘名称和大小不能为空'
        })
    
    # 确保磁盘名称不包含路径分隔符和特殊字符
    disk_name = secure_filename(disk_name)
    
    # 如果用户没有添加.img后缀，自动添加
    if not disk_name.lower().endswith('.img'):
        disk_name = f"{disk_name}.img"

    # 构建完整的磁盘路径
    base_disk_dir = '/app/iscsi'
    disk_path = os.path.join(base_disk_dir, disk_name)
    
    # 检查目录是否存在，不存在则创建
    if not os.path.exists(base_disk_dir):
        os.makedirs(base_disk_dir)
        logger.info(f"创建磁盘目录: {base_disk_dir}")
    
    # 检查文件是否已存在
    if os.path.exists(disk_path):
        return jsonify({
            'success': False,
            'message': f'磁盘文件 {disk_name} 已存在'
        })

    # 根据选择的方法创建虚拟磁盘
    if create_method == 'qemu':
        # 使用qemu-img创建虚拟磁盘
        cmd = f"qemu-img create -f raw {disk_path} {disk_size}{disk_unit}"
        method_description = "QEMU方式"
    else:
        # 使用dd命令创建虚拟磁盘
        count_value = int(disk_size)
        bs_value = f"1{disk_unit}"
        cmd = f"dd if=/dev/zero of={disk_path} bs={bs_value} count={count_value}"
        method_description = "DD方式"
    
    result = run_command(cmd)

    if result['success']:
        logger.info(f"成功创建虚拟磁盘({method_description}): {disk_path}, 大小: {disk_size}{disk_unit}")

        # 保存磁盘创建方法信息
        disk_methods_file = '/app/config/disk_methods.json'
        disk_methods = {}
        
        # 确保配置目录存在
        os.makedirs(os.path.dirname(disk_methods_file), exist_ok=True)
        
        # 读取现有的磁盘创建方法信息
        if os.path.exists(disk_methods_file):
            try:
                with open(disk_methods_file, 'r') as f:
                    disk_methods = json.load(f)
            except Exception as e:
                logger.error(f"读取磁盘创建方法信息失败: {str(e)}")

        # 添加新磁盘的创建方法
        disk_methods[disk_name] = method_description

        # 保存回文件
        try:
            with open(disk_methods_file, 'w') as f:
                json.dump(disk_methods, f)
            logger.info(f"已保存磁盘 {disk_name} 的创建方法: {method_description}")
        except Exception as e:
            logger.error(f"保存磁盘创建方法信息失败: {str(e)}")        

        return jsonify({
            'success': True,
            'message': f'虚拟磁盘 {disk_name} 创建成功，大小: {disk_size}{disk_unit}，使用{method_description}',
            'data': {
                'name': disk_name,
                'path': disk_path,
                'size': f"{disk_size}{disk_unit}",
                'method': create_method
            }
        })
    else:
        logger.error(f"创建虚拟磁盘失败({method_description}): {result['error']}")
        return jsonify({
            'success': False,
            'message': f'创建虚拟磁盘失败: {result["error"]}',
            'error': result['error'],
            'details': result.get('details', {})
        })

# 路由：获取系统状态
@app.route('/api/status')
def get_status():
    # 获取tgt服务状态
    tgt_status = run_command('tgtadm --lld iscsi --mode system --op show')
    
    # 获取Target数量
    targets = get_targets()
    target_count = len(targets)
    
    # 获取LUN总数
    lun_count = sum(len(target['luns']) for target in targets)
    
    # 获取磁盘文件数量
    disk_files = get_disk_files()
    disk_count = len(disk_files)
    
    # 获取磁盘目录信息
    # disk_dirs = ['/app/'] 

    # 获取默认IQN值
    default_iqns = get_default_iqns()
    
    return jsonify({
        'tgt_running': tgt_status['success'],
        'target_count': target_count,
        'lun_count': lun_count,
        'disk_count': disk_count,
        'default_iqns': default_iqns
    })

# 路由：性能监控页面
@app.route('/performance')
def performance_page():
    return render_template('performance.html')

# 路由：运行LUN优化
@app.route('/optimize', methods=['POST'])
def run_optimization():
    # 运行LUN优化脚本
    result = run_command('bash /optimize_lun.sh')
    
    if result['success']:
        flash('LUN优化成功完成', 'success')
    else:
        flash(f'LUN优化失败: {result["error"]}', 'error')
    
    return redirect(url_for('index'))

# 路由：获取LUN性能数据
@app.route('/api/performance')
def get_performance():
    # 从性能监控文件读取数据
    perf_file = '/tmp/iscsi_performance.json'
    
    if os.path.exists(perf_file):
        try:
            with open(perf_file, 'r') as f:
                perf_data = json.load(f)
                return jsonify(perf_data)
        except (json.JSONDecodeError, IOError) as e:
            return jsonify({
                'error': f'读取性能数据失败: {str(e)}',
                'timestamp': datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
            })
    else:
        return jsonify({
            'error': '性能监控未启动',
            'timestamp': datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        })

# 路由：启动性能监控
@app.route('/api/performance/start', methods=['POST'])
def start_performance_monitoring():
    # 检查监控脚本是否存在
    monitor_script = '/app/config/optimize/monitor_lun_performance.sh'
    
    logger.info(f"检查性能监控脚本路径: {monitor_script}")
    if not os.path.exists(monitor_script):
        logger.error(f"性能监控脚本不存在: {monitor_script}")
        return jsonify({
            'success': False,
            'message': '性能监控脚本不存在，请先运行LUN优化脚本'
        })
    
    # 检查监控是否已经运行
    if subprocess.run('pgrep -f monitor_lun_performance.sh', shell=True).returncode == 0:
        return jsonify({
            'success': True,
            'message': '性能监控已经在运行'
        })
    
    # 启动监控脚本
    try:
        logger.info("正在启动性能监控脚本...")
        process = subprocess.Popen(['bash', monitor_script], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        logger.info(f"性能监控脚本启动成功，进程ID: {process.pid}")
        return jsonify({
            'success': True,
            'message': '性能监控已启动'
        })
    except Exception as e:
        return jsonify({
            'success': False,
            'message': f'启动性能监控失败: {str(e)}'
        })

# 路由：停止性能监控
@app.route('/api/performance/stop', methods=['POST'])
def stop_performance_monitoring():
    # 停止监控脚本
    result = subprocess.run('pkill -f monitor_lun_performance.sh', shell=True)
    
    if result.returncode == 0:
        return jsonify({
            'success': True,
            'message': '性能监控已停止'
        })
    else:
        return jsonify({
            'success': False,
            'message': '没有运行中的性能监控进程'
        })

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=True)