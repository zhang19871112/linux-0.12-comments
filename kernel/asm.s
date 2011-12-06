/*
 *  linux/kernel/asm.s
 *
 *  (C) 1991  Linus Torvalds
 */

/*
 * asm.s contains the low-level code for most hardware faults.
 * page_exception is handled by the mm, so that isn't here. This
 * file also handles (hopefully) fpu-exceptions due to TS-bit, as
 * the fpu must be properly saved/resored. This hasn't been tested.
 */
/* asm.s 中包含了大部分的硬件故障(或出错)处理的低层次代码。页异常由内存管理程序mm处理，
 * 所以不在这里。此程序还处理由于TS位而造成的fpu异常，因为fpu必须正确的进行保存/恢复处理，
 * 这些还没有测试过 */
/* 本代码文件主要涉及对Intel保留中断int0-int16的处理(int17-int31留做今后使用)，以下是一些函数
 * 的声明，其圆形在traps.c中说明。 */
.globl _divide_error,_debug,_nmi,_int3,_overflow,_bounds,_invalid_op
.globl _double_fault,_coprocessor_segment_overrun
.globl _invalid_TSS,_segment_not_present,_stack_segment
.globl _general_protection,_coprocessor_error,_irq13,_reserved
.globl _alignment_check
/* 下面这段程序处理无出错号的情况
 * int0 - 处理被0除出错的情况，类型：错误，错误号：无
 * 在执行DIV或IDIV指令时，若除数是0，CPU就会产生这个异常。当eax(或ax，al)容纳不了一个合法除操作
 * 的结果时，也会产生这个异常。_do_divide_error实际上是C语言函数do_divide_error()编译后所产生模
 * 块中对应的名称。函数'do_divide_error'在traps.c中实现 */
_divide_error:
	pushl $_do_divide_error		/* 首先把将要调用的函数地址入栈 */
no_error_code:				/* 这里是无出错号处理的入口处 */
	xchgl %eax,(%esp)		/* _do_divide_error的地址->eax，eax被交换入栈 */
	pushl %ebx
	pushl %ecx
	pushl %edx
	pushl %edi
	pushl %esi
	pushl %ebp
	push %ds			/* 16位的段寄存器入栈后也要占用4个字节 */
	push %es
	push %fs
	pushl $0	# "error code"	/* 将数值0作为出错码入栈, C处理函数的第二个参数 */
	lea 44(%esp),%edx		/* 取有效地址，即栈中原调用返回地址处的栈指针位置, C处理函数的第一个参数 */
	pushl %edx			/* 并压入堆栈 */
	movl $0x10,%edx			/* 初始化段寄存器ds，es和fs，加载内核数据段选择符 */
	mov %dx,%ds
	mov %dx,%es
	mov %dx,%fs
	call *%eax			/* 加上*号表示调用操作数指定地址处的函数，称为间接调用。这句
					 * 的含义是调用引起本次异常的C处理函数，例如do_divide_error()等，
					 * 将堆栈指针加8相当于执行两次pop操作，弹出(丢弃)最后入栈的两个
					 * C函数参数，让堆栈指针重新指向寄存器fs入栈处 */
	addl $8,%esp
	pop %fs
	pop %es
	pop %ds
	popl %ebp
	popl %esi
	popl %edi
	popl %edx
	popl %ecx
	popl %ebx
	popl %eax			/* 弹出原来eax中的内容 */
	iret
/* int1 -- debug调试中断入口点。处理过程同上。类型：错误/陷阱(falut/trap)，无错误号。当eflags中TF标志置位时而引发的中断
 * 当发现硬件断点(数据：陷阱，代码：错误)，或者开启了指令跟踪陷阱或任务交换陷阱，或者调试寄存器访问无效(错误)，CPU就会
 * 产生该异常。 */
_debug:
	pushl $_do_int3		# _do_debug
	jmp no_error_code
/* int2 -- 非屏蔽中断调用入口点。类型：陷阱，无错误号
 * 每当接受到一个NMI信号，CPU内部就会产生中断向量2，并执行标准中断应答周期，因此很节省时间。NMI通常保留为重要的硬件事件
 * 使用。当CPU收到一个NMI信号并且开始执行其中断处理过程时，随后所有的硬件中断都将被忽略。 */
_nmi:
	pushl $_do_nmi
	jmp no_error_code
/* int3 -- 断点指令引起中断的入口点。类型：陷阱，无错误号
 * 由int3指令引发的中断，与硬件中断无关。该指令通常由调试器插入被调试程序的代码中。处理过程同_debug */
_int3:
	pushl $_do_int3
	jmp no_error_code
/* int4 -- 溢出出错处理中断入口点。类型：陷阱，无错误号
 * eflags中OF标志置位时CPU执行INTO指令就会引发该中断。通常用于编译器跟踪算数计算溢出。 */
_overflow:
	pushl $_do_overflow
	jmp no_error_code
/* int5 -- 边界检查出错中断入口点。类型：错误，无错误号
 * 当操作数在有效范围以外时引发的中断。当BOUND指令测试失败就会产生该中断。BOUND指令有3个操作数，如果第一个不在另外两个之间，
 * 就产生异常5 */
_bounds:
	pushl $_do_bounds
	jmp no_error_code
/* int6 -- 无效操作指令出错中断入口点。类型：错误，无错误号
 * CPU执行机构检测到一个无效的操作码而引起的中断 */
_invalid_op:
	pushl $_do_invalid_op
	jmp no_error_code
/* int9 -- 协处理器段超出出错中断入口点。类型：放弃，无错误号
 * 该异常基本上等同于协处理器出错保护。因为在浮点指令操作数太大时，我们就有这个机会来加载或保存超出数据段的浮点值 */
_coprocessor_segment_overrun:
	pushl $_do_coprocessor_segment_overrun
	jmp no_error_code
/* int15 -- 其他Intel保留中断的入口点 */
_reserved:
	pushl $_do_reserved
	jmp no_error_code
/* int45(0x20+13) -- Linux设置的数学协处理器硬件中断 */
_irq13:
	pushl %eax
	xorb %al,%al
	outb %al,$0xF0
	movb $0x20,%al
	outb %al,$0x20
	jmp 1f
1:	jmp 1f
1:	outb %al,$0xA0
	popl %eax
	jmp _coprocessor_error
/* int8 -- 双出错故障。类型：放弃，有错误码
 * 通常当CPU在调用前一个异常处理程序而又检测到一个新的异常时，这两个异常会被串行的进行处理，但也会碰到很少的情况，CPU
 * 不能进行这样的串行处理操作，此时就会引发该中断。 */
_double_fault:
	pushl $_do_double_fault
error_code:
	xchgl %eax,4(%esp)		# error code <-> %eax	error code <-> %eax, eax原来的值被保存在堆栈上
	xchgl %ebx,(%esp)		# &function <-> %ebx	error code <-> %ebx, ebx原来的值被保存在堆栈上
	pushl %ecx
	pushl %edx
	pushl %edi
	pushl %esi
	pushl %ebp
	push %ds
	push %es
	push %fs
	pushl %eax			# error code		出错号入栈
	lea 44(%esp),%eax		# offset		程序返回地址处堆栈指针位置值入栈
	pushl %eax
	movl $0x10,%eax			/* 置内核数据段选择符 */
	mov %ax,%ds
	mov %ax,%es
	mov %ax,%fs
	call *%ebx			/* 间接调用，调用相应的C函数，其参数已入栈 */
	addl $8,%esp			/* 丢弃入栈的2个用作C函数的参数 */
	pop %fs
	pop %es
	pop %ds
	popl %ebp
	popl %esi
	popl %edi
	popl %edx
	popl %ecx
	popl %ebx
	popl %eax
	iret
/* int10 -- 无效的任务状态段(TSS)。类型：错误；有出错码
 * CPU企图切换到一个进程，该进程的TSS无效。根据TSS中哪一部份引起了异常，当由于TSS长度超过104字节时，这个
 * 异常在当前任务中产生，因而切换被终止。其他问题则会导致在切换后的新任务中产生本异常 */
_invalid_TSS:
	pushl $_do_invalid_TSS
	jmp error_code

/* int11 -- 段不存在。类型：错误；有出错码
 * 被引用的段不在内存中。段描述符中标志着段不在内存中 */
_segment_not_present:
	pushl $_do_segment_not_present
	jmp error_code

/* int12 -- 堆栈段错误。类型：错误；有出错码
 * 指令操作试图超出堆栈段范围，或者堆栈段不在内存中。这是异常11和13的特例。有些操作系统可以利用这个异常
 * 来确定什么时候应该为程序分配更多的栈空间。*/
_stack_segment:
	pushl $_do_stack_segment
	jmp error_code

/* int13 -- 一般保护性错误。类型：错误；有出错码
 * 表明是不属于任何其他类的错误。若一个异常产生时没有对应的处理向量(0--16),通常会归到此类 */
_general_protection:
	pushl $_do_general_protection
	jmp error_code

/* int17 -- 边界对齐检查出错。
 * 在启用了内存边界检查时，若特权级3(用户级)数据非边界对齐时会产生该异常 */
_alignment_check:
	pushl $_do_alignment_check
	jmp error_code
/* int7 -- 设备不存在 _device_not_available kernel/sys_call.s
 * int14 -- 页错误    _page_fault mm/page.s
 * int16 -- 协处理器错误 _coprocessor_error kernel/sys_call.s
 * int 0x20 -- 时钟中断  _timer_interrupt  kernel/sys_call.s
 * int 0x80 -- 系统调用  _system_call kernel/sys_call.s */
