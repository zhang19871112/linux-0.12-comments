/*
 *  linux/kernel/system_call.s
 *
 *  (C) 1991  Linus Torvalds
 */

/*
 *  system_call.s  contains the system-call low-level handling routines.
 * This also contains the timer-interrupt handler, as some of the code is
 * the same. The hd- and flopppy-interrupts are also here.
 *
 * NOTE: This code handles signal-recognition, which happens every time
 * after a timer-interrupt and after each system call. Ordinary interrupts
 * don't handle signal-recognition, as that would clutter them up totally
 * unnecessarily. 这段代码处理信号识别，在每次时钟中断和系统调用之后都会进行
 * 识别。一般中断过程并不处理信号识别，因为会给系统造成混乱
 *
 * Stack layout in 'ret_from_system_call': 从系统调用返回时堆栈的内容
 *
 *	 0(%esp) - %eax
 *	 4(%esp) - %ebx
 *	 8(%esp) - %ecx
 *	 C(%esp) - %edx
 *	10(%esp) - original %eax	(-1 if not system call)
 *	14(%esp) - %fs
 *	18(%esp) - %es
 *	1C(%esp) - %ds
 *	20(%esp) - %eip
 *	24(%esp) - %cs
 *	28(%esp) - %eflags
 *	2C(%esp) - %oldesp
 *	30(%esp) - %oldss
 */
/* 上述一般中断过程是指除了系统调用中断和时钟中断以外的其他中断。这些中断会在
 * 内核态或用户态随机发生，若在这些中断过程中也处理信号识别的话，就有可能与系
 * 统调用中断和时钟中断过程对信号的识别处理过程相冲突，违反了内核代码非抢占原
 * 则。因此系统既无必要在这些"其他"中断中处理信号，也不允许这样做 */
SIG_CHLD	= 17	/* 定义SIG_CHLD信号(子进程停止或结束) */

EAX		= 0x00	/* 堆栈中各个寄存器的偏移位置 */
EBX		= 0x04
ECX		= 0x08
EDX		= 0x0C
ORIG_EAX	= 0x10	/* 如果不是系统调用(是其他中断)时，该值为-1 */
FS		= 0x14
ES		= 0x18
DS		= 0x1C
EIP		= 0x20	/* 以下4行由CPU自动入栈 */
CS		= 0x24
EFLAGS		= 0x28
OLDESP		= 0x2C	/* 当特权级变化时，原堆栈指针也会入栈 */
OLDSS		= 0x30

/* 以下这些是任务结构(task_struct)中变量的偏移值 */
state	= 0		# these are offsets into the task-struct.进程状态码
counter	= 4		# 任务运行时间计数(递减)(滴答数)，运行时间片。
priority = 8		# 运行优先数。任务开始运行时counter=priority，越大则运行时间越长
signal	= 12		# 是信号位图，每个位代表一种信号，信号值=位偏移值+1
sigaction = 16		# MUST be 16 (=len of sigaction)，sigaction结构长度必须是16字节
blocked = (33*16)	# 受阻塞信号位图的偏移量

# offsets within sigaction，以下定义在sigaction结构中的偏移值
sa_handler = 0		# 信号处理过程句柄
sa_mask = 4		# 信号屏蔽码
sa_flags = 8		# 信号集
sa_restorer = 12	# 恢复函数指针

nr_system_calls = 82	# 0.12版本中的系统调用总数

ENOSYS = 38		# 系统调用号出错码

/*
 * Ok, I get parallel printer interrupts while using the floppy for some
 * strange reason. Urgel. Now I just ignore them.
 */
.globl _system_call,_sys_fork,_timer_interrupt,_sys_execve
.globl _hd_interrupt,_floppy_interrupt,_parallel_interrupt
.globl _device_not_available, _coprocessor_error

# 系统调用号错误时将返回出错码-ENOSYS
.align 2			# 内存4字节对齐
bad_sys_call:
	pushl $-ENOSYS		# eax中置-ENOSYS
	jmp ret_from_sys_call
# 重新执行调度程序入口。当调度程序schedule()返回时就从ret_from_sys_call处继续执行
.align 2
reschedule:
	pushl $ret_from_sys_call# 将ret_from_sys_call的地址入栈
	jmp _schedule
# int0x80 -- linux系统调用入口点(调用中断int0x80, eax中是调用号)
.align 2
_system_call:
	push %ds		# 保存原段寄存器值
	push %es
	push %fs
	pushl %eax		# save the orig_eax，保存eax原值
# 一个系统调用最多可带有3个参数，也可以不带参数。下面入栈的ebx、ecx和edx中放着系统调用
# 相应C语言函数的调用参数。这几个寄存器入栈的顺序是由GNU gcc规定的，ebx中存放第一个参数
# ecx中存放第二个参数，edx中存放第三个参数
	pushl %edx		
	pushl %ecx		# push %ebx,%ecx,%edx as parameters
	pushl %ebx		# to the system call
# 在保护过段寄存器之后，让ds，es指向内核数据段，而fs指向当前局部数据段，即指向执行本次系统
# 调用的用户程序的数据段。注意，在0.12中内核给任务分配的代码和数据内存段是重叠的，它们的段
# 基址和段限长相同。参见fork.c程序中的copy_mem()函数
	movl $0x10,%edx		# set up ds,es to kernel space
	mov %dx,%ds
	mov %dx,%es
	movl $0x17,%edx		# fs points to local data space
	mov %dx,%fs
	cmpl _NR_syscalls,%eax	# 调用号如果超出范围的话就跳转
	jae bad_sys_call
# 下面这句操作的含义是：调用地址=[_sys_call_table + %eax*4]。_sys_call_table[]是一个指针数组，
# 该数组中设置了内核所有的82个系统调用C处理函数的地址
	call _sys_call_table(,%eax,4)	# 间接调用指定功能C函数
	pushl %eax		# 把系统调用返回值入栈
# 下面查看当前任务的运行状态。如果不在就绪状态(state不等于0)就去执行调度程序。如果该任务在就绪
# 状态，但是其时间片已经用完(counter=0)，则也去执行调度程序。例如当后台进程组中的进程执行控制
# 终端读写操作时，那么默认条件下该后台进程组所有进程会收到SIGTTIN或SIGTTOU信号，导致进程组中所有
# 进程处于停止状态。而当前进程则会立刻返回。
2:
	movl _current,%eax		# 取当前任务(进程)数据结构指针->eax
	cmpl $0,state(%eax)		# state, 不在就绪状态
	jne reschedule
	cmpl $0,counter(%eax)		# counter, 时间片用完
	je reschedule			# 执行调度程序
# 以下这段代码执行从系统调用C函数返回后，对信号进行识别处理。其他中断服务程序退出时也将跳转到这里
# 进行处理后才退出中断过程，例如后面的处理器出错中断int16.首先判断当前任务是不是初始任务task0，如果
# 是则不必对其进行信号量方面的处理，直接返回。
ret_from_sys_call:
	movl _current,%eax
	cmpl _task,%eax			# task[0] cannot have signals，_task对应C程序中的task[]数组
					# 直接引用task相当于引用task[0]
	je 3f				# 向前跳转到标号3处退出中断处理

# 通过对原调用程序代码选择符的检查赖判断调用程序是不是用户任务。如果不是则直接退出中断。这是因为任务
# 在内核态执行时不可抢占。否则对任务进行信号量的识别处理。这里通过比较选择符是否为用户代码段的选择符
# 0x000f(RPL=3，局部表，代码段)来判断是否为用户任务。如果不是则说明是某个中断服务程序(例如中断16)跳转
# 到ret_from_sys_call执行到此，于是跳转退出中断程序。另外，如果原堆栈段选择符不为0x17(即原堆栈不再用户
# 段中)，也说明本次系统调用的调用者不是用户任务，则也退出。
	cmpw $0x0f,CS(%esp)		# was old code segment supervisor ?
	jne 3f
	cmpw $0x17,OLDSS(%esp)		# was stack segment = 0x17 ?
	jne 3f
# 下面用于处理当前任务中的信号。首先取当前任务结构中的信号位图，然后用任务结构中的信号阻塞(屏蔽)码，阻
# 塞不允许的信号位，取得数值最小的信号值，再把原信号位图中该信号对应的位复位(置0)，最后将该信号值作为
# 参数之一调用do_signal()。do_signal()其参数包括13个入栈的信息。在do_signal()或信号处理函数返回之后，若
# 返回值不为0则再看看是否需要切换进程或继续处理其他信号。
	movl signal(%eax),%ebx		# 取信号位图->ebx, 每一位代表一种信号，共32个信号
	movl blocked(%eax),%ecx		# 取阻塞(屏蔽)信号位图->ecx
	notl %ecx			# 每位取反
	andl %ebx,%ecx			# 获取许可的信号位图
	bsfl %ecx,%ecx			# 从低位(0位)开始扫描位图，看是否有1的位
					# 若有，则ecx保留该位的偏移值(即地址位0--31)
	je 3f				# 如果没有信号则向前跳转退出
	btrl %ecx,%ebx			# 复位该信号(ebx含有原signal位图)
	movl %ebx,signal(%eax)		# 重新保存signal位图信息->current->signal
	incl %ecx			# 将信号调整为从1开始的数(1--32)
	pushl %ecx			# 信号值入栈作为调用do_signal的参数之一
	call _do_signal			# 调用C函数信号处理程序
	popl %ecx			# 弹出入栈的信号值
	testl %eax, %eax		# 测试返回值，若不为0则跳转到前面标号2
	jne 2b		# see if we need to switch tasks, or do more signals

3:	popl %eax			# eax中含有系统调用的返回值，见116行
	popl %ebx
	popl %ecx
	popl %edx
	addl $4, %esp	# skip orig_eax， 跳过原eax值
	pop %fs
	pop %es
	pop %ds
	iret
# int16 -- 处理器错误中断。类型：错误，无错误码
# 这是一个外部的基于硬件的异常。当协处理器检测到自己发生错误时，就会通过ERROR引脚通知CPU
# 下面代码用于处理协处理器发出的出错信号。并跳转去执行C函数math_error()。返回后将跳转到
# 标号ret_from_sys_call处继续执行
.align 2
_coprocessor_error:
	push %ds
	push %es
	push %fs
	pushl $-1		# fill in -1 for orig_eax，填-1，表明不是系统调用
	pushl %edx
	pushl %ecx
	pushl %ebx
	pushl %eax
	movl $0x10,%eax		# ds，es置为指向内核数据段
	mov %ax,%ds
	mov %ax,%es
	movl $0x17,%eax		# fs置为指向局部数据段
	mov %ax,%fs
	pushl $ret_from_sys_call# 把下面调用返回的地址入栈
	jmp _math_error		# 执行math_error()

# int17 -- 设备不存在或协处理器不存在。类型：错误；无错误码
# 如果控制器CR0中EM(模拟)标志置位，则当CPU执行一条协处理器指令时就会引发该中断，这样CPU
# 就可以有机会让这个中断处理程序模拟协处理器指令。
# CR0的交换标志TS是在CPU执行任务转换时设置的。TS可以用来确定什么时候协处理器中的内容与CPU
# 正在执行的任务不匹配了。当CPU在运行一个协处理器转移指令时发现TS置位时，就会引发该中断。
# 此时就可以保存前一个任务的协处理器内容，并恢复新任务的协处理器执行状态。该中断最后将转移
# 到标号ret_from_sys_call处执行下去(检测并处理信号)
.align 2
_device_not_available:
	push %ds
	push %es
	push %fs
	pushl $-1		# fill in -1 for orig_eax, 填-1表明不是系统调用
	pushl %edx
	pushl %ecx
	pushl %ebx
	pushl %eax
	movl $0x10,%eax		# ds，es置为指向内核数据段
	mov %ax,%ds
	mov %ax,%es
	movl $0x17,%eax		# fs置为指向局部数据段(出错程序的数据段)
	mov %ax,%fs
# 清CR0中任务已交换标志TS，并取CR0值，若其中协处理器仿真标志EM没有置位，说明不是EM引起的中断，
# 则恢复任务协处理器状态，执行C函数math_state_restore(),并在返回时去执行ret_from_sys_call处的代码
	pushl $ret_from_sys_call	# 把下面跳转或调用的返回地址入栈
	clts				# clear TS so that we can use math
	movl %cr0,%eax
	testl $0x4,%eax			# EM (math emulation bit)
	je _math_state_restore		# 执行math_state_restore
# 若EM标志置位，则去执行数学仿真程序math_emulate()
	pushl %ebp
	pushl %esi
	pushl %edi
	pushl $0		# temporary storage for ORIG_EIP
	call _math_emulatea	# 调用C函数
	addl $4,%esp		# 丢弃临时存储
	popl %edi
	popl %esi
	popl %ebp
	ret			# 这里的ret跳转到ret_from_sys_call

# int32 -- (int0x20)时钟中断处理程序。中断频率设置为100HZ，定时芯片8253/8254是在kernel/sched.c中
# 初始化的。因此这里的jiffies每10毫秒加1.这段代码将jiffies增1，发送结束中断指令给8259控制器，然后
# 用当前特权级作为参数调用C函数do_timer(Long CPL). 当调用返回时转去检测并处理信号
.align 2
_timer_interrupt:
	push %ds		# save ds,es and put kernel data space
	push %es		# into them. %fs is used by _system_call
	push %fs		# 保存ds、es并让其指向内核数据段。fs将用于system_call
	pushl $-1		# fill in -1 for orig_eax, 填-1表明不是系统调用
# 下面保存寄存器eax、ecx和edx。这是因为gcc编译器在调用函数时不会保存它们。这里也保存了
# ebx寄存器，因为在后面ret_from_sys_call中会用到它
	pushl %edx		# we save %eax,%ecx,%edx as gcc doesn't
	pushl %ecx		# save those across function calls. %ebx
	pushl %ebx		# is saved as we use that in ret_sys_call
	pushl %eax
	movl $0x10,%eax		# ds、es置为指向内核数据段
	mov %ax,%ds
	mov %ax,%es
	movl $0x17,%eax		# fs置为指向局部数据段(程序的数据段)
	mov %ax,%fs
	incl _jiffies		# jiffies加1
# 由于初始化中断控制芯片时没有采用自动EOI，所以这里需要发指令结束该硬件中断
	movb $0x20,%al		# EOI to interrupt controller #1
	outb %al,$0x20
# 下面从堆栈中取出执行系统调用代码的选择符(CS段寄存器值)中的当前特权级别(0或3)并压入堆栈，作为
# do_timer的参数。do_timer()函数执行任务切换、计时等工作
	movl CS(%esp),%eax
	andl $3,%eax		# %eax is CPL (0 or 3, 0=supervisor)
	pushl %eax
	call _do_timer		# 'do_timer(long CPL)' does everything from
	addl $4,%esp		# task switching to accounting ...
	jmp ret_from_sys_call

# 这是sys_execve()系统调用。取中断调用程序的代码指针作为参数调用C函数do_execve()
.align 2
_sys_execve:
	lea EIP(%esp),%eax	# eax指向堆栈中保存用户程序eip指针处
	pushl %eax
	call _do_execve
	addl $4,%esp		# 丢弃调用时压入栈的eip值
	ret

# sys_fork()调用，用于创建子进程，是system_call功能2.首先调用C函数find_empty_process()，
# 取得一个进程号last_pid. 若返回负数则说明目前任务数组已满，然后调用copy_process()复制进程
.align 2
_sys_fork:
	call _find_empty_process# 为新进程取得进程号last_pid
	testl %eax,%eax		# 在eax中返回进程号。若返回负数则退出
	js 1f
	push %gs
	pushl %esi
	pushl %edi
	pushl %ebp
	pushl %eax
	call _copy_process	# 调用C函数copy_process()
	addl $20,%esp		# 丢弃这里所有压栈内容
1:	ret

# int46 -- (int0x2E)硬盘中断处理程序，相应硬件中断请求IRQ14
# 当请求的硬盘操作完成或出错就会发出此中断信号。首先向8259A中断控制从芯片发送结束硬件中断指令EOI，然后
# 取变量do_hd中的函数指针放入edx寄存器中，并置do_hd为NULL，接着判断edx函数指针是否为空。如果为空，则给
# edx赋值指向unexpected_hd_interrupt(),用于显示出错信息。随后向8259A主芯片发送EOI指令。并调用edx中指针
# 指向的函数：read_intr()、write_intr()或unexpected_hd_interrupt()
_hd_interrupt:
	pushl %eax
	pushl %ecx
	pushl %edx
	push %ds
	push %es
	push %fs
	movl $0x10,%eax		# ds, es置为内核数据段
	mov %ax,%ds
	mov %ax,%es
	movl $0x17,%eax		# fs置为调用程序的局部数据段
	mov %ax,%fs
# 由于初始化8259A没有采用自动EOI，所以这里需要发送指令结束该硬件中断
	movb $0x20,%al
	outb %al,$0xA0		# EOI to interrupt controller #1 送从8259A
	jmp 1f			# give port chance to breathe，这里jmp起延时作用
1:	jmp 1f
# do_hd定义为一个函数指针，将被赋值read_intr()或write_intr()函数地址。放到edx寄存器后就将do_hd指针变量
# 置为NULL.然后测试得到的函数指针，若该指针为空，则赋予该指针指向C函数unexpected_hd_interrupt(),以处理
# 未知硬盘中断
1:	xorl %edx,%edx
	movl %edx,_hd_timeout	# hd_timeout置0，表示控制器已在规定时间内产生了中断
	xchgl _do_hd,%edx	# 把do_hd变量放入edx，同时把edx(0)放到do_hd
	testl %edx,%edx
	jne 1f			# 若空，则让指针指向C函数unexpected_hd_interrupt()
	movl $_unexpected_hd_interrupt,%edx
1:	outb %al,$0x20		# 送8259A主芯片EOI指令
	call *%edx		# "interesting" way of handling intr.
	pop %fs			# 上句调用do_hd指向的C函数
	pop %es
	pop %ds
	popl %edx
	popl %ecx
	popl %eax
	iret

# int38 -- (int0x26)软盘驱动器中断处理程序，响应硬件中断请求IRQ6.
# 其处理过程与上面对硬盘的处理基本一样。首先向8259A中断控制从芯片发送结束硬件中断指令EOI，然后
# 取变量do_floppy中的函数指针放入eax寄存器中，并置do_floppy为NULL，接着判断eax函数指针是否为空。如果为空，则给
# eax赋值指向unexpected_floppy_interrupt(),用于显示出错信息。随后调用eax指向的函数：rw_interrupt，seek_interrupt，
# recal_interrupt，reset_interrupt或unexpected_floppy_interrupt
_floppy_interrupt:
	pushl %eax
	pushl %ecx
	pushl %edx
	push %ds
	push %es
	push %fs
	movl $0x10,%eax		# ds，es置为内核数据段
	mov %ax,%ds
	mov %ax,%es
	movl $0x17,%eax		# fs置为调用程序的局部数据段
	mov %ax,%fs
	movb $0x20,%al		# 送主8259A中断控制器EOI指令
	outb %al,$0x20		# EOI to interrupt controller #1
# do_floppy定义为一个函数指针，将被赋值实际处理C函数指针。放到eax寄存器后就将do_floppy指针变量
# 置为NULL.然后测试eax中原指针是否为空，若是则使指针指向C函数unexpected_floppy_interrupt()
# 未知硬盘中断
	xorl %eax,%eax
	xchgl _do_floppy,%eax
	testl %eax,%eax		# 测试函数指针是否=NULL？
	jne 1f			# 若空，则使指针指向C函数unexpected_floppy_interrupt
	movl $_unexpected_floppy_interrupt,%eax
1:	call *%eax		# "interesting" way of handling intr. 间接调用
	pop %fs			# 上句调用do_floppy指向的函数
	pop %es
	pop %ds
	popl %edx
	popl %ecx
	popl %eax
	iret

# int39 -- (int0x27)并行口中断处理程序，对应硬件中断请求信号IRQ7. 未实现，只是发送EOI指令
_parallel_interrupt:
	pushl %eax
	movb $0x20,%al
	outb %al,$0x20
	popl %eax
	iret
