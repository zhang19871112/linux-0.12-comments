/*
 *  linux/boot/head.s
 *
 *  (C) 1991  Linus Torvalds
 */

/*
 *  head.s contains the 32-bit startup code.
 *
 * NOTE!!! Startup happens at absolute address 0x00000000, which is also where
 * the page directory will exist. The startup code will be overwritten by
 * the page directory.
 */
.text
.globl _idt, _gdt,_pg_dir,_tmp_floppy_area
_pg_dir:			# 页目录将会存放在这里, 这里的启动代码将会被页目录表删掉
startup_32:
# AT&T汇编语言格式
	movl $0x10, %eax
	mov %ax, %ds
	mov %ax, %es
	mov %ax, %fs
	mov %ax, %gs		# 进入保护模式.重新加载段描述符为0x10
	lss _stack_start, %esp	# _stack_start -> ss:esp.设置系统堆栈,在kernel/sched.c中定义
	call setup_idt		# 设置中断描述符表
	call setup_gdt
	movl $0x10, %eax	# reload all the segment registers, 重要! 因为修改了gdt, 所以需要重新装载所有的段寄存器.
	mov %ax, %ds		# after changing gdt. CS was already
	mov %ax, %es		# reloaded in 'setup_gdt'
	mov %ax, %fs
	mov %ax, %gs
	lss _stack_start, %esp
# 以下代码用于测试A20地址线是否开启, 方法是往0x000000处写任意值, 查看0x100000处的值和刚写入的值是否相同,
# 如果相同就一直比较下去
	xorl %eax, %eax
1:	incl %eax		# check that A20 really IS enabled
	movl %eax, 0x000000	# loop forever if it isn't
	cmpl %eax, 0x100000
	je 1b			# 1b表示向后跳转到标号1去, 若是5f, 则表示向前跳转到标号5去
/*
 * NOTE! 486 should set bit 16, to check for write-protect in supervisor
 * mode. Then it would be unnecessary with the "verify_area()"-calls.
 * 486 users probably want to set the NE (#5) bit also, so as to use
 * int 16 for math errors.
 */
# 检查数学协处理器是否存在，方法是修改控制寄存器CR0，在假设存在协处理器的情况下执行一个协处理器命令,
# 如果出错的话则说明协处理器芯片不存在, 需要设置CR0中的协处理器仿真位EM(bit2), 并复位协处理器存在标志MP(位1)
	movl %cr0, %eax		# check math chip
	andl $0x80000011, %eax	# Save PG,PE,ET
/* "orl $0x10020, %eax" here for 486 might be good */
	orl $2, %eax		# set MP
	movl %eax, %cr0
	call check_x87
	jmp after_page_tables

/*
 * We depend on ET to be correct. This checks for 287/387.
 */
check_x87:
	fninit
	fstsw %ax
	cmpb $0, %al
	je 1f			/* no coprocessor: have to set bits */
	movl %cr0, %eax
	xorl $6, %eax		/* reset MP,set EM */
	movl %eax, %cr0
	ret
.align 2	# 按4字节对齐
1:	.byte 0xDB, 0xE4		/* fsetpm for 287,ignored by 387 */
	ret

/*
 *  setup_idt
 *
 *  sets up a idt with 256 entries pointing to
 *  ignore_int, interrupt gates. It then loads
 *  idt. Everything that wants to install itself
 *  in the idt-table may do so themselves. Interrupts
 *  are enabled elsewhere, when we can be relatively
 *  sure everything is ok. This routine will be over-
 *  written by the page tables.
 */

/* 中断描述符表IDT中的中断门描述符格式:
 *
 * |31                                   16| 15|14 13| 12|11            8|7              0|
 * ----------------------------------------------------------------------------------------
 * |           过程入口点偏移值            |   |     |   |      TYPE     |                |
 * |                                       | P | DPL | 0 |  1  1  1  0   |                |
 * |               31..16                  |   |     |   |               |                |
 * ----------------------------------------------------------------------------------------
 * |              段选择符                 |               过程入口点偏移值               |
 * |                                       |                                              |
 * |                                       |                    15..0                     |
 * ----------------------------------------------------------------------------------------
 *  说明:
 *
 * (1) P: 存在(Present)位.
 *               P=1 表示描述符对地址转换是有效的.或者说该描述符所描述的段存在.即在内存中；
 *               P=0 表示描述符对地址转换无效.即该段不存在.使用该描述符进行内存访问时会引起异常。
 *
 * (2) DPL: 表示描述符特权级(Descriptor Privilege level).共2位.它规定了所描述段的特权级.用于特权检查，以决定对该段>能否访问。
 *
 * (3) S(bit12): 说明描述符的类型.
 *               对于存储段描述符而言.S=1.以区别与系统段描述符和门描述符(S=0).
 *
 * (4) TYPE: 说明存储段描述符所描述的存储段的具体属性.
 *
 * 	Decimal		11 10 9 8 	Description
 * 	1 		 0  0 0 1 	16-Bit TSS (Available)
 * 	2 		 0  0 1 0 	LDT
 * 	3 		 0  0 1 1 	16-Bit TSS (Busy)
 * 	4  		 0  1 0 0 	16-Bit Call Gate
 * 	5  		 0  1 0 1 	Task Gate
 * 	6  		 0  1 1 0 	16-Bit Interrupt Gate
 * 	7   		 0  1 1 1 	16-Bit Trap Gate
 * 	8  		 1  0 0 0 	Reserved
 * 	9  		 1  0 0 1 	32-Bit TSS (Available)
 * 	10 		 1  0 1 0 	Reserved
 * 	11 		 1  0 1 1 	32-Bit TSS (Busy)
 * 	12 		 1  1 0 0 	32-Bit Call Gate
 * 	13 		 1  1 0 1 	Reserved
 * 	14 		 1  1 1 0 	32-Bit Interrupt Gate
 * 	15 		 1  1 1 1 	32-Bit Trap Gate
 */
setup_idt:
	lea ignore_int, %edx	# 将哑中断ignore_int的偏移值->edx寄存器
	movl $0x00080000, %eax	# 选择符0x8
	movw %dx, %ax		# selector = 0x0008 = cs
				# 偏移值的低16位放入ax中中
	movw $0x8E00, %dx	# interrupt gate - dpl=0,present,低16位放入dx中
				# P	DPL	S	TYPE
				# 1	00	0	1110	00000000
	lea _idt, %edi		# _idt是中断描述符表的地址
	mov $256, %ecx		# 总共256个中断
rp_sidt:
	movl %eax, (%edi)	# (0x00080000 | 偏移值低16位) -> (%edi)
	movl %edx, 4(%edi)	# (偏移值高16位<<16 | 0x8E00) -> 4(%edi)
	addl $8, %edi		# 下一个idt表项,每个idt表项占8个字节,所以加上8
	dec %ecx
	jne rp_sidt		# 重复设置256个中断描述符表项, 都设置成哑中断
	lidt idt_descr		# 加载中断描述符表寄存器值
	ret

/*
 *  setup_gdt
 *
 *  This routines sets up a new gdt and loads it.
 *  Only two entries are currently built, the same
 *  ones that were built in init.s. The routine
 *  is VERY complicated at two whole lines, so this
 *  rather long comment is certainly needed :-).
 *  This routine will beoverwritten by the page tables.
 */
setup_gdt:
	lgdt gdt_descr		# 加载全局描述符表, 已经设置好
	ret

/*
 * I put the kernel page tables right after the page directory,
 * using 4 of them to span 16 Mb of physical memory. People with
 * more than 16MB will have to expand this.
 */
.org 0x1000
pg0:

.org 0x2000
pg1:

.org 0x3000
pg2:

.org 0x4000
pg3:

.org 0x5000
/*
 * tmp_floppy_area is used by the floppy-driver when DMA cannot
 * reach to a buffer-block. It needs to be aligned, so that it isn't
 * on a 64kB border.
 */
_tmp_floppy_area:
	.fill 1024, 1,0

after_page_tables:
	pushl $0		# These are the parameters to main :-)
	pushl $0
	pushl $0
	pushl $L6		# return address for main, if it decides to.
	pushl $_main
# jmp是不负责任的调度.不保存任何信息.不考虑会回头.跳过去就什么也不管了。
# call.保存eip等.以便程序重新跳回.ret是call的逆过程，是回头的过程。这都是cpu固有指令，因此要保存的信息，不用我们自己保存
	jmp setup_paging	# jmp不保存返回地址, 这里跳转到setup_paging之前把_main压栈,在setup_paging最后ret.ret会弹出_main.并跳转执行
				# JMP CALL和RET指令的近转移形式只是在当前代码段中执行程序控制转移.因此不会执行特权级检查.
				# JMP CALL或RET指令的远转移形式会把控制转移到另外一个代码段中.因此处理器一定会执行特权级检查.
				# 1. jmp指令仅仅进行执行流程的跳转.不会保存返回地址.
				# 2. call指令在进行流程跳转前会保存返回地址.以便在跳转目标代码中可以使用ret指令返回到call指令
				#    的下一条指令处继续执行.执行段内跳转时.只保存EIP；如果是段间跳转.还保存CS。
				# 3. ret和retf：这两个指令的功能都是调用返回.
				#	(1) ret在返回时只从堆栈中取得EIP；retf中的字母f表示far.即段间转移返回.要从堆栈中取出EIP和CS.
				#	(2) 两个指令都可以带参数.表示发生过程调用时参数的个数.返回时要从堆栈中退出相应个数的参数.
				#	(3) 恢复CS时.如果发现将发生特权级变化（当前CS的低2位不等于从堆栈中取得的新的CS值的低2位.
				#	    由跳转的相关理论可知.只有跳转到非一致代码段时才会发生特权级变化.那么，也只有从非一致代码段
				#           返回时才会发生特权级变化的返回）.则还要从调用者堆栈中取得ESP和SS恢复到相应寄存器中.也即恢复调用者堆栈
L6:
	jmp L6			# main should never return here, but
				# just in case, we know what happens.

/* This is the default interrupt "handler" :-) */
int_msg:
	.asciz "Unknown interrupt\n\r"
.align 2
ignore_int:
	pushl %eax
	pushl %ecx
	pushl %edx
	push %ds
	push %es
	push %fs
	movl $0x10, %eax
	mov %ax, %ds
	mov %ax, %es
	mov %ax, %fs
	pushl $int_msg
	call _printk
	popl %eax
	pop %fs
	pop %es
	pop %ds
	popl %edx
	popl %ecx
	popl %eax
	iret


/*
 * Setup_paging
 *
 * This routine sets up paging by setting the page bit
 * in cr0. The page tables are set up, identity-mapping
 * the first 16MB. The pager assumes that no illegal
 * addresses are produced (ie >4Mb on a 4Mb machine).
 *
 * NOTE! Although all physical memory should be identity
 * mapped by this routine, only the kernel page functions
 * use the >1Mb addresses directly. All "normal" functions
 * use just the lower 1Mb, or the local data space,which
 * will be mapped to some other place - mm keeps track of
 * that.
 *
 * For those with more memory than 16 Mb - tough luck. I've
 * not got it, why should you :-) The source is here. Change
 * it. (Seriously - it shouldn't be too difficult. Mostly
 * change some constants etc. I left it at 16Mb, as my machine
 * even cannot be extended past that (ok, but it was cheap :-)
 * I've tried to show which constants to change by having
 * some kind of marker at them (search for "16Mb"), but I
 * won't guarantee that's all :-( )
 *
 * 页目录项(4KB页)
 * |31                           12|11    9| 8 | 7  | 6 | 5 |  4  |  3  |  2  |  1  | 0 |
 * --------------------------------------------------------------------------------------
 * |    Page-Table Base Address    | Avail | G | PS | G | A | PCD | PWT | U/S | R/W | P |
 * --------------------------------------------------------------------------------------
 *
 * 页表项(4KB页)
 * |31                           12|11    9| 8 | 7  | 6 | 5 |  4  |  3  |  2  |  1  | 0 |
 * --------------------------------------------------------------------------------------
 * |       Page Base Address       | Avail | G | 0  | D | A | PCD | PWT | U/S | R/W | P |
 * --------------------------------------------------------------------------------------
 * TODO 每个位的作用
 */
.align 2
setup_paging:
# 总共映射16MB内存, 共需要4个页目录项
	movl $1024*5, %ecx		/* 5 pages - pg_dir+4 page tables, 首先对5页内存清零, 1页目录加4页表 */
	xorl %eax, %eax
	xorl %edi, %edi			/* pg_dir is at 0x000, 页目录从0x0开始 */
	cld;rep;stosl
	movl $pg0+7, _pg_dir		/* set present bit/user r/w, $pg0是取符号地址操作, 把0x00001007作为页目录表的第一项(0x0000), 映射0~4M */
					# 7是属性: 页存在，用户可读写
	movl $pg1+7, _pg_dir+4		/* 把0x00002007作为页目录表的第二项(0x0004), 映射4~8M */
	movl $pg2+7, _pg_dir+8		/* 把0x00003007作为页目录表的第三项(0x0008), 映射8~12M */
	movl $pg3+7, _pg_dir+12		/* 把0x00004007作为页目录表的第四项(0x000c), 映射12~16M */
	movl $pg3+4092, %edi		/* 0x00004000 + 4092 -> edi, 这个内存地址是第三个页表的最后一个页表项地址 */
	movl $0xfff007, %eax		/* 16Mb - 4096 + 7 (r/w user,p), Page Base Address = (0xfff+1) << 12 = 16M, 后12位不考虑 */
	std				/* edi值递减 */
1:	stosl				/* fill pages backwards - more efficient :-), 向后填好每一项 */
	subl $0x1000, %eax		/* 每次填写的值是递减4K后的值, 因为每个页表项可一映射4K */
	jge 1b				/* 填满整个页表项 */

	xorl %eax, %eax			/* pg_dir is at 0x0000, 页目录在0地址 */
	movl %eax, %cr3			/* cr3 - page directory start, 页目录基地值 */
	movl %cr0, %eax
	orl $0x80000000, %eax
	movl %eax, %cr0			/* set paging (PG) bit, 开启分页 */
	ret				/* this also flushes prefetch-queue, 使用转移指令刷行预取指令队列, 将main程序地址弹出, 跳转到init/main.c执行 */

.align 2
.word 0
idt_descr:
#	|47				16|15 	 		0|
# IDTR  |   32-bit Linear Base Address    |  16-Bit Table Limit	 |
	.word 256*8-1		# idt contains 256 entries, 256*8Byte -1
	.long _idt		# 偏移
.align 2
.word 0
gdt_descr:
#	|47				16|15 	 		0|
# GDTR  |   32-bit Linear Base Address    |  16-Bit Table Limit	 |
	.word 256*8-1		# so does gdt (not that that's any
	.long _gdt		# magic number, but it works for me :^)

	.align 3
_idt:	.fill 256, 8,0		# idt is uninitialized
# 见setup.S中的描述符定义
! 数据段描述符
! |31          24| 23| 22| 21| 20|19    16| 15|14 13| 12|11            8|7              0|
! ----------------------------------------------------------------------------------------
! |     基地址   |   |   |   | A | 段限长 |   |     |   |      TYPE     |     基地址     |
! |              | G | B | 0 | V |        | P | DPL | 1 |               |                |
! |  Base 31..24 |   |   |   | L | 19..16 |   |     |   | 0 | E | W | A |  Base 23..16   |
! ----------------------------------------------------------------------------------------
! |              基地址                   |               段限长                         |
! |                                       |                                              |
! |         Base Address 15..0            |         Segment Limit 15..0                  |
! ----------------------------------------------------------------------------------------
!
! 代码段描述符
! |31          24| 23| 22| 21| 20|19    16| 15|14 13| 12|11            8|7              0|
! ----------------------------------------------------------------------------------------
! |     基地址   |   |   |   | A | 段限长 |   |     |   |      TYPE     |     基地址     |
! |              | G | B | 0 | V |        | P | DPL | 1 |               |                |
! |  Base 31..24 |   |   |   | L | 19..16 |   |     |   | 1 | C | R | A |  Base 23..16   |
! ----------------------------------------------------------------------------------------
! |              基地址                   |               段限长                         |
! |                                       |                                              |
! |         Base Address 15..0            |         Segment Limit 15..0                  |
! ----------------------------------------------------------------------------------------
_gdt:	.quad 0x0000000000000000	/* NULL descriptor */
	.quad 0x00c09a0000000fff	/* 16Mb */	# 0b0000 0000 1100 0000 1001 1010 0000 0000 0..0 111111111111 16MB 代码段
	.quad 0x00c0920000000fff	/* 16Mb */	# 0b0000 0000 1100 0000 1001 0010 0000 0000 0..0 111111111111 16MB 数据段
	.quad 0x0000000000000000	/* TEMPORARY - don't use */
	.fill 252, 8,0			/* space for LDT's and TSS's etc */
