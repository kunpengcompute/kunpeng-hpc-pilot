#!/bin/bash
#=========================================================================================
# 脚本功能：根据指定可执行程序，在程序同级目录生成多NUMA节点独立副本，自动修改ELF依赖路径为本地lib
# 入参格式：$0 <APP_ELF_PATH> [ENV_SCRIPT_PATH]
#        APP_ELF_PATH：必填，目标可执行文件路径
#        ENV_SCRIPT_PATH：选填，环境变量配置脚本
#=========================================================================================

# 可配置项：固定NUMA副本节点数量，按需修改。72F8机型请填16
FIX_NUMA_NODE_NUM=16

#=========================================================================================
# 函数：usage 帮助信息输出
#=========================================================================================
usage() {
    echo "==================== 使用帮助 ===================="
	echo "功能说明：为二进制程序生成多个独立副本目录，每个副本目录包含独立的二进制程序和它所依赖的所有动态库"
    echo "调用格式：$0 <APP_ELF_PATH> [ENV_SCRIPT_PATH]"
    echo "参数说明："
    echo "  APP_ELF_PATH      必填：目标二进制可执行程序路径"
    echo "  ENV_SCRIPT_PATH   选填：依赖环境变量脚本路径"
    echo "使用示例："
    echo "  $0 ./hello"
    echo "  $0 ./hello ./set_env.sh"
    echo "================================================="
    exit 0
}

# -h 参数触发帮助
if [[ "$1" == "-h" ]]; then
    usage
fi

# 参数数量校验：只支持1~2个入参
if [ $# -lt 1 ] || [ $# -gt 2 ]; then
    echo "[ERROR] 参数个数非法！"
    usage
    exit 1
fi

# 入参变量赋值，获取程序真实绝对路径
APP_ELF_PATH=$(readlink -f "$1")
ENV_SCRIPT_PATH="${2:-}"

# 自动计算副本根目录：程序所在目录/numa_replica
APP_BIN_DIR=$(dirname "$APP_ELF_PATH")
ROOT_REPLICA_DIR="${APP_BIN_DIR}/numa_replica"
app_name=$(basename "$APP_ELF_PATH")

# 全局变量定义
HOSTNAME=$(hostname)
SCRIPT_NAME=$(basename "$0")
PID=$$
ld_name='ld-linux-aarch64.so.1'          # aarch64默认动态链接器名称
declare -A soname_dep_map                # key:soname  value:库真实全路径
all_deps_list=()                        # 全量依赖库绝对路径数组

#=========================================================================================
# 函数：relink_elf_deps 修改ELF文件的RPATH依赖，替换为副本内本地lib路径
# $1：待修改elf文件全路径
# $2：当前numa副本根目录
#=========================================================================================
relink_elf_deps() {
    local elf=$1
    local replica_path=$2

    # 遍历elf所有依赖so，排除系统ld链接器
    for dep in $(patchelf --print-needed "$elf" | grep -Ev "$ld_name"); do
        local dep_absolute_path=${soname_dep_map[$dep]}
        if [ -n "$dep_absolute_path" ]; then
            local real_soname=$(basename "$dep_absolute_path")
            # 不存在则复制依赖库到副本lib目录
            [ -e "$replica_path/lib/$real_soname" ] || cp "$dep_absolute_path" "$replica_path/lib"
            # 替换依赖路径为本机目录
            patchelf --replace-needed "$dep" "$replica_path/lib/$real_soname" "$elf"
        fi
    done
}

#=========================================================================================
# 函数：create_elf_and_libs_replicas 扫描依赖 + 批量创建各NUMA节点副本
# $1：源可执行程序全路径
#=========================================================================================
create_elf_and_libs_replicas() {
    local app_elf=$1
    local filter='not found|not a dynamic executable'

    # ldd扫描程序所有依赖，过滤无效行
    echo "[INFO] 开始扫描程序所有依赖动态库..."
    for dep in $(ldd "$app_elf" | grep -Ev "$filter" | awk '/=>/ {print $3}'); do
        if [ -f "$dep" ]; then
            local dep_absolute_path=$(readlink -f "$dep")
            local soname=$(patchelf --print-soname "$dep")
            # 无soname标签则以文件名作为soname
            [ -z "$soname" ] && soname=$(basename "$dep")
            soname_dep_map["$soname"]="$dep_absolute_path"
            all_deps_list+=("$dep_absolute_path")
        fi
    done
    echo "[INFO] 依赖库扫描完成，共识别 ${#all_deps_list[@]} 个依赖文件"

    local numa_node_num=${FIX_NUMA_NODE_NUM}
    echo "[INFO] 配置副本节点总数：${numa_node_num} 个"
    # 循环逐个创建numa_0、numa_1...副本目录
    for i in $(seq 0 $((numa_node_num-1))); do
        local numa_replica_path="$ROOT_REPLICA_DIR/numa_$i"
        local timestamp=$(date +"%b %d %H:%M:%S")
        echo -n "$timestamp $HOSTNAME $SCRIPT_NAME[$PID]: [DOING] 正在构建numa_$i副本目录..."

        # 创建目录结构：副本目录 + lib子目录
        mkdir -p "$numa_replica_path" "$numa_replica_path/lib"
        # 复制主程序至副本目录
        cp "$app_elf" "$numa_replica_path"
        # 修改主程序内部依赖路径
        relink_elf_deps "$numa_replica_path/$app_name" "$numa_replica_path"
        # 批量复制所有依赖库并逐个修改库内依赖
        for dep in "${all_deps_list[@]}"; do
            [ -e "$numa_replica_path/lib/$(basename "$dep")" ] || cp "$dep" "$numa_replica_path/lib"
            relink_elf_deps "$numa_replica_path/lib/$(basename "$dep")" "$numa_replica_path"
        done

        echo " 完成"
    done
}

#=========================================================================================
# 脚本主逻辑入口：前置各项合法性校验
#=========================================================================================
echo "==================== NUMA副本生成任务启动 ===================="

# 校验1：副本目录已存在直接退出，禁止自动删除
if [ -d "$ROOT_REPLICA_DIR" ]; then
    echo "[ERROR] 异常检测：副本目录【$ROOT_REPLICA_DIR】已存在！"
    echo "[TIPS] 为防止误删数据，脚本不自动清理，请手动检查并删除上述目录后重新执行脚本"
    exit 1
fi

# 校验2：源可执行文件存在性+执行权限
if [ ! -f "$APP_ELF_PATH" ]; then
    echo "[ERROR] 可执行文件【$APP_ELF_PATH】不存在"
    exit 1
fi
if [ ! -x "$APP_ELF_PATH" ]; then
    echo "[ERROR] 可执行文件【$APP_ELF_PATH】缺少执行权限"
    exit 1
fi
echo "[INFO] 待处理程序：$APP_ELF_PATH"
echo "[INFO] 副本输出目录：$ROOT_REPLICA_DIR"

# 校验3：环境脚本文件（传入才校验）
if [ -n "$ENV_SCRIPT_PATH" ] && [ ! -f "$ENV_SCRIPT_PATH" ]; then
    echo "[ERROR] 指定的环境脚本【$ENV_SCRIPT_PATH】不存在！"
    exit 1
fi

# 校验4：父目录写入权限（用来创建numa_replica）
parent_dir=$(dirname "$ROOT_REPLICA_DIR")
if [ ! -w "$parent_dir" ];then
    echo "[ERROR] 上级目录【$parent_dir】无写入权限，无法创建副本目录"
    exit 1
fi
echo "[INFO] 目录权限校验通过"

# 加载环境变量脚本
if [ -n "$ENV_SCRIPT_PATH" ]; then
    echo "[INFO] 正在加载环境配置：$ENV_SCRIPT_PATH"
    if ! source "$ENV_SCRIPT_PATH"; then
        echo "[ERROR] 环境脚本加载执行失败！"
        exit 1
    fi
    echo "[INFO] 环境变量加载成功"
else
    echo "[INFO] 未传入环境脚本，跳过环境加载"
fi

# 校验依赖工具patchelf
if ! command -v patchelf &> /dev/null; then
    echo "[ERROR] 系统缺失patchelf工具，请执行 yum/dnf install patchelf 安装后重试"
    exit 1
fi
echo "[INFO] patchelf工具校验正常"

#=========================================================================================
# 正式执行副本生成逻辑，统计运行耗时
#=========================================================================================
start_time=$(date +%s)
create_elf_and_libs_replicas "$APP_ELF_PATH"
end_time=$(date +%s)
elapsed_time=$((end_time - start_time))
elapsed_minutes=$((elapsed_time / 60))
elapsed_seconds=$((elapsed_time % 60))

#=========================================================================================
# 任务收尾：结果汇总+空间耗时统计
#=========================================================================================
echo -e "\n==================== NUMA副本生成任务完成 ===================="
echo "应用名称：${app_name}"
echo "副本数量：${FIX_NUMA_NODE_NUM}"
echo "副本目录：${ROOT_REPLICA_DIR}/numa_*"
echo "副本目录包含：程序文件 + 所有依赖so库"

replica_total_dir="$ROOT_REPLICA_DIR"
dir_size=$(du -sh --exclude='.*' "$replica_total_dir" | awk '{print $1}')
echo "占用存储空间：$dir_size"
echo "任务总耗时：${elapsed_minutes}分${elapsed_seconds}秒（合计${elapsed_time}秒）"
#=========================================================================================
# MPI任务启动方式改造示例说明
#=========================================================================================
echo -e "\n==================== NUMA多副本方式启动MPI应用案例 ===================="
echo -e "\n案例1：mpirun直接拉起可执行程序"
echo -e "【默认启动方式】  ：mpirun -x PATH -x LD_LIBRARY_PATH --rankfile \$rankfile_path \033[1;32m ./${app_name} \033[0m"
echo -e "【多副本启动方式】：mpirun -x PATH -x LD_LIBRARY_PATH --rankfile \$rankfile_path \033[1;31m sh -c './numa_replica/numa_\${OMPI_COMM_WORLD_LOCAL_RANK}/${app_name}' \033[0m"

echo -e "\n案例2：mpirun调用启动脚本run.sh间接拉起程序"
echo -e "【启动方式不变】：mpirun -x PATH -x LD_LIBRARY_PATH --rankfile \$rankfile_path ./run.sh"
echo -e "【默认run.sh脚本内容】  ："
echo -e "   #!/bin/bash"
echo -e "  \033[1;32m ./${app_name}\033[0m"
echo -e "【多副本run.sh脚本内容】："
echo -e "   #!/bin/bash"
echo -e "  \033[1;31m ./numa_replica/numa_\${OMPI_COMM_WORLD_LOCAL_RANK}/${app_name} \033[0m"

