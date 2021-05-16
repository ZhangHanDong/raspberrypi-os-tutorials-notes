# 00: 准备工作

因为国内的环境，需要对原来的 Dockerfile 和 命令做一些更改。

## 更改 Dockerfile

打开 `docker/rustembedded-osdev-utils/Dockerfile`，找到`# QEMU`，更改 `git` 地址为下面这行：

```
# QEMU
git clone https://git.qemu.org/git/qemu.git;    
```

## 更改 Makefile 中 Docker 命令

`docker build` 命令下要添加这一行：

```
  --add-host raw.githubusercontent.com:185.199.111.133 \
```

这是为了避免无法解析 `raw.githubusercontent.com` 域名而为，IP地址如果不行，则请自行`ping`获取最新的。

## 构建本地 Docker 镜像

进入 `docker` 目录，执行命令：

```
> make
```

即可。