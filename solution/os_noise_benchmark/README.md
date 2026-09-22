# Netgauge OS噪声测试工具
## 工具简介
Netgauge是一个高精度的网络参数测量工具。它支持对多种不同的网络协议和通信模式进行基准测试。除了针对于网络的测试外，它也提供了一个能够测试OS操作系统噪声的手段，即噪声测试模式，能够精确测量操作系统的噪声，为衡量系统噪声量级提供直观的测试结果以供评估。当前版本支持三种不同的基准测试方法：
- Fixed Work Quantum（FWQ）
- Fixed Time Quantum（FTQ）
- Selfish Detour

其中Selfish Detour测试结果中，有一项指标“CPU overhead due to noise”显示了噪声所占CPU的开销，建议以此结果作为噪声对比及衡量的指标。

工具源代码链接：http://unixer.de/research/netgauge/

----
## 使用指导
### 编译指导
在Linux操作系统中，准备好编译环境，包括但不限于HPCKit。
首先进行编译前的config：

./configure MPICC=mpicc MPICXX=mpicxx

运行成功后可以直接编译：

make

### 运行指导
查看帮助信息：

./netgauge --help

进行Selfish Detour测试：

./netgauge -x noise

通过MPI运行：
mpirun --allow-run-as-root -n 1 --bind-to core --map-by numa ./netgauge -x noise

上述MPI运行命令仅为使用示例，实际测试时需要根据测试目的及规模来指定rankfile或通过其他方式来达成指定测试核范围的目的。
