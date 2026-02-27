# ZFinal 安装指南

## 快速安装

### 一键安装（推荐）

在终端运行以下命令：

```bash
curl -fsSL https://raw.githubusercontent.com/chy3xyz/zfinal/main/install.sh | bash
```

或者使用 wget：

```bash
wget -qO- https://raw.githubusercontent.com/chy3xyz/zfinal/main/install.sh | bash
```

### 手动安装

1. **克隆仓库**

```bash
git clone https://github.com/chy3xyz/zfinal.git
cd zfinal
```

2. **运行安装脚本**

```bash
chmod +x install.sh
./install.sh
```

3. **重新加载 Shell 配置**

```bash
source ~/.bashrc  # 或 ~/.zshrc
```

## 系统要求

### 必需

- **Zig**: 0.14.0 或更高版本
- **Git**: 用于克隆仓库
- **Bash**: 运行安装脚本

### 可选

- **SQLite3**: 用于数据库功能
- **MySQL/PostgreSQL**: 如果需要使用这些数据库

## 各平台安装指南

### macOS

1. **安装 Zig**

```bash
brew install zig
```

2. **安装 SQLite (可选)**

```bash
brew install sqlite3
```

3. **运行安装脚本**

```bash
curl -fsSL https://raw.githubusercontent.com/chy3xyz/zfinal/main/install.sh | bash
```

### Linux (Ubuntu/Debian)

1. **安装 Zig**

```bash
# 从官网下载最新版本
wget https://ziglang.org/download/0.14.0/zig-linux-x86_64-0.14.0.tar.xz
tar -xf zig-linux-x86_64-0.14.0.tar.xz
sudo mv zig-linux-x86_64-0.14.0 /usr/local/zig
echo 'export PATH=$PATH:/usr/local/zig' >> ~/.bashrc
source ~/.bashrc
```

2. **安装 SQLite (可选)**

```bash
sudo apt-get update
sudo apt-get install sqlite3 libsqlite3-dev
```

3. **运行安装脚本**

```bash
curl -fsSL https://raw.githubusercontent.com/chy3xyz/zfinal/main/install.sh | bash
```

### Linux (CentOS/RHEL)

1. **安装 Zig**

```bash
# 从官网下载最新版本
wget https://ziglang.org/download/0.14.0/zig-linux-x86_64-0.14.0.tar.xz
tar -xf zig-linux-x86_64-0.14.0.tar.xz
sudo mv zig-linux-x86_64-0.14.0 /usr/local/zig
echo 'export PATH=$PATH:/usr/local/zig' >> ~/.bashrc
source ~/.bashrc
```

2. **安装 SQLite (可选)**

```bash
sudo yum install sqlite sqlite-devel
```

3. **运行安装脚本**

```bash
curl -fsSL https://raw.githubusercontent.com/chy3xyz/zfinal/main/install.sh | bash
```

### Windows (WSL)

1. **启用 WSL**

在 PowerShell (管理员) 中运行：

```powershell
wsl --install
```

2. **在 WSL 中安装 Zig**

```bash
wget https://ziglang.org/download/0.14.0/zig-linux-x86_64-0.14.0.tar.xz
tar -xf zig-linux-x86_64-0.14.0.tar.xz
sudo mv zig-linux-x86_64-0.14.0 /usr/local/zig
echo 'export PATH=$PATH:/usr/local/zig' >> ~/.bashrc
source ~/.bashrc
```

3. **运行安装脚本**

```bash
curl -fsSL https://raw.githubusercontent.com/chy3xyz/zfinal/main/install.sh | bash
```

## 验证安装

安装完成后，运行以下命令验证：

```bash
# 检查 zf 命令
zf version

# 查看帮助
zf help

# 创建测试项目
zf new testapp
cd testapp
zig build run
```

## 卸载

运行以下命令卸载 ZFinal：

```bash
curl -fsSL https://raw.githubusercontent.com/chy3xyz/zfinal/main/install.sh | bash -s -- --uninstall
```

或者手动卸载：

```bash
rm -rf ~/.zfinal
rm ~/.local/bin/zf
```

然后从你的 shell 配置文件中移除 PATH 条目。

## 常见问题

### 1. "zig: command not found"

确保 Zig 已正确安装并添加到 PATH：

```bash
which zig
zig version
```

### 2. "zf: command not found"

重新加载 shell 配置：

```bash
source ~/.bashrc  # 或 ~/.zshrc
```

或者手动添加到 PATH：

```bash
export PATH="$PATH:$HOME/.local/bin"
```

### 3. SQLite 相关错误

安装 SQLite 开发库：

```bash
# Ubuntu/Debian
sudo apt-get install libsqlite3-dev

# CentOS/RHEL
sudo yum install sqlite-devel

# macOS
brew install sqlite3
```

### 4. 权限错误

确保安装脚本有执行权限：

```bash
chmod +x install.sh
```

### 5. 网络问题

如果无法访问 GitHub，可以使用镜像：

```bash
# 使用国内镜像 (示例)
git clone https://gitee.com/chy3xyz/zfinal.git
cd zfinal
./install.sh
```

## 更新 ZFinal

重新运行安装脚本即可更新到最新版本：

```bash
curl -fsSL https://raw.githubusercontent.com/chy3xyz/zfinal/main/install.sh | bash
```

## 从源码构建

如果你想从源码手动构建：

```bash
# 克隆仓库
git clone https://github.com/chy3xyz/zfinal.git
cd zfinal

# 构建
zig build install

# 添加到 PATH
export PATH="$PATH:$(pwd)/zig-out/bin"

# 验证
zf version
```

## 开发环境设置

如果你想参与 ZFinal 开发：

```bash
# 克隆仓库
git clone https://github.com/chy3xyz/zfinal.git
cd zfinal

# 构建
zig build

# 运行测试
zig build test

# 运行示例
zig build run-blog
zig build run-htmx

# 运行基准测试
zig build run-bench
```

## 获取帮助

如果遇到问题：

1. 查看 [文档](https://github.com/chy3xyz/zfinal/tree/main/doc)
2. 搜索 [Issues](https://github.com/chy3xyz/zfinal/issues)
3. 提出新的 [Issue](https://github.com/chy3xyz/zfinal/issues/new)
4. 加入社区讨论

---

**祝你使用 ZFinal 愉快！** 🚀
