# NUMA多副本工具 (app_numa_replica.sh)

## 简介

本功能面向众核多NUMA架构的HPC场景，提供用户态NUMA多副本特性的解决方案参考实现。NUMA架构下，跨节点访问会导致延迟增加。本功能通过自动化脚本为各NUMA节点创建应用副本并修改RPATH，使进程将各自的二进制和库文件加载到进程所在的NUMA node内存上，减少跨节点访存开销。

---

## 适用性评估

| 应用      | 推荐等级 | 实测收益  |
| ------- | ---- | ----- |
| WRF     | 推荐   | +6.8% |
| GROMACS | 可选   | +0.8% |
| LAMMPS  | 不推荐  | -0.8% |
| VASP    | 不推荐  | -0.4% |

## 使用建议

建议针对内存访问频率较高的应用进行使用。

以下场景使用多副本可能无法获得性能提升：

1. 短时批处理任务
2. 网络通信延迟主导的工作负载
3. 计算密集型且内存访问模式简单的工作负载

---

## NUMA多副本方式启动MPI应用案例

### 前置条件

- 目标系统具备NUMA架构
- patchelf工具已安装
- 具备目标目录写权限
- 磁盘空间充足（预估：程序二进制和库文件大小 x NUMA节点数 x 1.2）

### 参数

APP_ELF_PATH：必填，目标可执行文件路径

ENV_SCRIPT_PATH：选填，环境变量配置脚本

### 可配置项

FIX_NUMA_NODE_NUM：固定NUMA副本节点数量，按需修改。72F8机型请填16

### 步骤一：准备环境变量脚本

创建配置环境变量脚本env_script.sh，用于后续app_numa_replica.sh脚本调用：

```bash
#!/bin/bash
# HPCKit环境初始化
source /path/to/HPCKit/latest/setvars.sh --use-bisheng --force

# 应用依赖库路径
export LD_LIBRARY_PATH=/path/to/dep_lib1:/path/to/dep_lib2:$LD_LIBRARY_PATH

# 其他环境变量
export OMP_NUM_THREADS=1
```

### 步骤二：生成多副本

```bash
cd /path/to/application/bin
source /path/to/env_script.sh
./app_numa_replica.sh ./application_binary ./env_script.sh
```

生成目录结构：

```
./numa_replica/
├── numa_0/
│   ├── application_binary
│   └── lib/
├── numa_1/
│   ├── application_binary
│   └── lib/
└── ...
```

### 步骤三：启动MPI应用

**启动方式一：mpirun直接拉起可执行程序，示例**

```bash
mpirun -x PATH -x LD_LIBRARY_PATH --rankfile \$rankfile_path ./${app_name} # 默认启动方式
mpirun -x PATH -x LD_LIBRARY_PATH --rankfile \$rankfile_path sh -c './numa_replica/numa_\${OMPI_COMM_WORLD_LOCAL_RANK}/${app_name}' # 多副本启动方式
```

**启动方式二：mpirun调用启动脚本run.sh间接拉起程序，示例**

```bash
mpirun -x PATH -x LD_LIBRARY_PATH --rankfile \$rankfile_path ./run.sh

# 默认run.sh脚本内容
#!/bin/bash"
./${app_name}

# 多副本run.sh脚本内容
#!/bin/bash"
./numa_replica/numa_\${OMPI_COMM_WORLD_LOCAL_RANK}/${app_name}
```

---
