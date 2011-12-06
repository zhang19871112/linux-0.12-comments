/*
 *  linux/kernel/traps.c
 *
 *  (C) 1991  Linus Torvalds
 */

/*
 * 'Traps.c' handles hardware traps and faults after we have saved some
 * state in 'asm.s'. Currently mostly a debugging-aid, will be extended
 * to mainly kill the offending process (probably by giving it a signal,
 * but possibly by killing it outright if necessary).
 */
#include <string.h>

#include <linux/head.h>
#include <linux/sched.h>
#include <linux/kernel.h>
#include <asm/system.h>
#include <asm/segment.h>
#include <asm/io.h>
/* _res是输出的值，23行定义了一个寄存器变量__reg，该变量将被保存在一个寄存器中，以便于快速访问和操作，
 * 如果想指定寄存器(例如eax)，那么我们可以把该句写成"register char __res asm("ax");"
 * 取段seg中地址addr处的一个字节
 * 参数：seg - 段选择符；addr - 段内指定地址
 * 输出：%0 - eax(__res)；输入：%1 - eax(seg)；%2 - 内存地址(*(addr)) */
#define get_seg_byte(seg,addr) ({ \
register char __res; \
__asm__("push %%fs;mov %%ax,%%fs;movb %%fs:%2,%%al;pop %%fs" \
	:"=a" (__res):"0" (seg),"m" (*(addr))); \
__res;})

/* 取段seg中地址addr处的一个长字节(4字节)
 * 参数：seg - 段选择符；addr - 段内指定地址
 * 输出：%0 - eax(__res)；输入：%1 - eax(seg)；%2 - 内存地址(*(addr)) */
#define get_seg_long(seg,addr) ({ \
register unsigned long __res; \
__asm__("push %%fs;mov %%ax,%%fs;movl %%fs:%2,%%eax;pop %%fs" \
	:"=a" (__res):"0" (seg),"m" (*(addr))); \
__res;})

/* 取fs段寄存器的值(选择符)
 * 输出：%0 - eax(__res) */
#define _fs() ({ \
register unsigned short __res; \
__asm__("mov %%fs,%%ax":"=a" (__res):); \
__res;})

void page_exception(void);	/* 页异常。实际是page_fault(mm/page.s) */

void divide_error(void);	/* int0 (kernel/asm.s) */
void debug(void);		/* int1 (kernel/asm.s) */
void nmi(void);			/* int2 (kernel/asm.s) */
void int3(void);		/* int3 (kernel/asm.s) */
void overflow(void);		/* int4 (kernel/asm.s) */
void bounds(void);		/* int5 (kernel/asm.s) */
void invalid_op(void);		/* int6 (kernel/asm.s) */
void device_not_available(void);/* int7 (kernel/sys_call.s) */
void double_fault(void);	/* int8 (kernel/asm.s) */
void coprocessor_segment_overrun(void);/* int9 (kernel/asm.s) */
void invalid_TSS(void);		/* int10 (kernel/asm.s) */
void segment_not_present(void);	/* int11 (kernel/asm.s) */
void stack_segment(void);	/* int12 (kernel/asm.s) */
void general_protection(void);	/* int13 (kernel/asm.s) */
void page_fault(void);		/* int14 (mm/page/s) */
void coprocessor_error(void);	/* int16 (kernel/sys_call.s) */
void reserved(void);		/* int15 (kernel/asm.s) */
void parallel_interrupt(void);	/* int39 (kernel/sys_call.s) */
void irq13(void);		/* int45协处理器中断 (kernel/asm.s) */
void alignment_check(void);	/* int46 (kernel/asm.s) */

/* 打印出错中断的名称，错误号、调用程序的eip，eflags，esp，fs段寄存器值、段的基址、段的长度、进程号pid
 * 任务号、10字节指令码。如果堆栈在用户数据段，则还打印16字节的堆栈内容 */
static void die(char * str,long esp_ptr,long nr)
{
	long * esp = (long *) esp_ptr;
	int i;

	printk("%s: %04x\n\r",str,nr&0xffff);
	/* 打印当前调用进程的CS:EIP, EFLAGS和SS:ESP的值。参照图8-4，esp[0]即为esp0位置
	 * (1) EIP:\t%04x:%p\n -- esp[1]是段选择符(cs)，esp[0]是eip
	 * (2) EFLAGS:\t%p\n -- esp[2]是eflags
	 * (3) ESP:\t%04x:%p\n -- esp[4]是原ss，esp[3]是原esp */
	printk("EIP:\t%04x:%p\nEFLAGS:\t%p\nESP:\t%04x:%p\n",
		esp[1],esp[0],esp[2],esp[4],esp[3]);
	printk("fs: %04x\n",_fs());
	printk("base: %p, limit: %p\n",get_base(current->ldt[1]),get_limit(0x17));
	if (esp[4] == 0x17) {	/* 若原ss值为0x17(用户栈，则还打印出用户栈中的4个长字值(16字节)) */
		printk("Stack: ");
		for (i=0;i<4;i++)
			printk("%p ",get_seg_long(0x17,i+(long *)esp[3]));
		printk("\n");
	}
	str(i);	/* 取当前运行任务的任务号 */
	printk("Pid: %d, process nr: %d\n\r",current->pid,0xffff & i);	/* 进程号，任务号 */
	for(i=0;i<10;i++)
		printk("%02x ",0xff & get_seg_byte(esp[1],(i+(char *)esp[0])));
	printk("\n\r");
	do_exit(11);		/* play segment exception */
}

/* 以这些以do_开头的函数是asm.s中对应中断处理程序调用的C函数 */
void do_double_fault(long esp, long error_code)
{
	die("double fault",esp,error_code);
}

void do_general_protection(long esp, long error_code)
{
	die("general protection",esp,error_code);
}

void do_alignment_check(long esp, long error_code)
{
    die("alignment check",esp,error_code);
}

void do_divide_error(long esp, long error_code)
{
	die("divide error",esp,error_code);
}

/* 参数是进入中断后被顺序压入堆栈的寄存器值 */
void do_int3(long * esp, long error_code,
		long fs,long es,long ds,
		long ebp,long esi,long edi,
		long edx,long ecx,long ebx,long eax)
{
	int tr;

	__asm__("str %%ax":"=a" (tr):"0" (0));
	printk("eax\t\tebx\t\tecx\t\tedx\n\r%8x\t%8x\t%8x\t%8x\n\r",
		eax,ebx,ecx,edx);
	printk("esi\t\tedi\t\tebp\t\tesp\n\r%8x\t%8x\t%8x\t%8x\n\r",
		esi,edi,ebp,(long) esp);
	printk("\n\rds\tes\tfs\ttr\n\r%4x\t%4x\t%4x\t%4x\n\r",
		ds,es,fs,tr);
	printk("EIP: %8x   CS: %4x  EFLAGS: %8x\n\r",esp[0],esp[1],esp[2]);
}

void do_nmi(long esp, long error_code)
{
	die("nmi",esp,error_code);
}

void do_debug(long esp, long error_code)
{
	die("debug",esp,error_code);
}

void do_overflow(long esp, long error_code)
{
	die("overflow",esp,error_code);
}

void do_bounds(long esp, long error_code)
{
	die("bounds",esp,error_code);
}

void do_invalid_op(long esp, long error_code)
{
	die("invalid operand",esp,error_code);
}

void do_device_not_available(long esp, long error_code)
{
	die("device not available",esp,error_code);
}

void do_coprocessor_segment_overrun(long esp, long error_code)
{
	die("coprocessor segment overrun",esp,error_code);
}

void do_invalid_TSS(long esp,long error_code)
{
	die("invalid TSS",esp,error_code);
}

void do_segment_not_present(long esp,long error_code)
{
	die("segment not present",esp,error_code);
}

void do_stack_segment(long esp,long error_code)
{
	die("stack segment",esp,error_code);
}

void do_coprocessor_error(long esp, long error_code)
{
	if (last_task_used_math != current)
		return;
	die("coprocessor error",esp,error_code);
}

void do_reserved(long esp, long error_code)
{
	die("reserved (15,17-47) error",esp,error_code);
}

/* 下面是异常(陷阱)中断程序初始化子程序。设置它们的中断调用门(中断向量)
 * set_trap_gate()与set_system_gate()都使用了中断描述符表IDT中的陷阱门(TrapGate)，它们之间的主要
 * 区别在于前者设置的特权级为0，后者是3.因此断点陷阱中断int3、溢出中断overflow和边界出错中断bounds
 * 可以由任何程序调用。这两个函数均是嵌入式汇编宏程序 */
void trap_init(void)
{
	int i;

	set_trap_gate(0,&divide_error);	/* 设置除操作出错的中断向量值。以下相同 */
	set_trap_gate(1,&debug);
	set_trap_gate(2,&nmi);
	set_system_gate(3,&int3);	/* int3-5 can be called from all */
	set_system_gate(4,&overflow);
	set_system_gate(5,&bounds);
	set_trap_gate(6,&invalid_op);
	set_trap_gate(7,&device_not_available);
	set_trap_gate(8,&double_fault);
	set_trap_gate(9,&coprocessor_segment_overrun);
	set_trap_gate(10,&invalid_TSS);
	set_trap_gate(11,&segment_not_present);
	set_trap_gate(12,&stack_segment);
	set_trap_gate(13,&general_protection);
	set_trap_gate(14,&page_fault);
	set_trap_gate(15,&reserved);
	set_trap_gate(16,&coprocessor_error);
	set_trap_gate(17,&alignment_check);
	/* 下面把int17-47的陷阱门先均设置为reserved，以后各硬件初始化时会重新设置自己的陷阱门 */
	for (i=18;i<48;i++)
		set_trap_gate(i,&reserved);
	/* 设置协处理器中断0x2d(45)陷阱门描述符，并允许其产生中断请求。设置并行口中断描述符 */
	set_trap_gate(45,&irq13);
	outb_p(inb_p(0x21)&0xfb,0x21);	/* 允许8259A主芯片的IRQ2中断请求 */
	outb(inb_p(0xA1)&0xdf,0xA1);	/* 允许8259A从芯片的IRQ13中断请求 */
	set_trap_gate(39,&parallel_interrupt);	/* 设置并行口1的中断0x27陷阱门描述符 */
}
