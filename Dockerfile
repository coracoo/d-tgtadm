FROM ubuntu:22.04

# 配置国内源
RUN sed -i 's/archive.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list && \
    sed -i 's/security.ubuntu.com/mirrors.aliyun.com/g' /etc/apt/sources.list

LABEL maintainer="可爱的小cherry"

# 配置环境变量，避免交互式提示
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Asia/Shanghai
ENV PYTHONUNBUFFERED=1

# 安装依赖
RUN apt-get update && \
    ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone && \
    apt-get install -y \
    tgt \
    nginx \
    python3 \
    python3-pip \
    python3-flask \
    procps \
    sysstat \
    bc \
    qemu-utils \
    && rm -rf /var/lib/apt/lists/*

# 安装Python依赖
RUN pip3 install --no-cache-dir flask-wtf gunicorn

# 创建应用目录
RUN mkdir -p /app/iscsi /app/config/optimize /app/config/tgt /app/config/tgt_lib /app/templates
# 设置目录权限
RUN chmod 755 /app/iscsi /app/config/optimize
RUN chmod -R 755 /app/templates
RUN touch /app/config/app.log
# 复制Web应用文件
COPY app.py /app/app.py
COPY nginx.conf /nginx.conf
COPY /app/static/ /app/static/
COPY /app/templates/ /app/templates/


# 复制脚本并赋权
COPY iscsi_server.sh /iscsi_server.sh
RUN chmod +x /iscsi_server.sh

COPY optimize_lun.sh /optimize_lun.sh
RUN chmod +x /optimize_lun.sh

# 暴露端口：iSCSI和Web管理界面
EXPOSE 3260 13260

VOLUME ["/app/config","/app/iscsi"]

# 启动脚本
CMD ["/iscsi_server.sh"]