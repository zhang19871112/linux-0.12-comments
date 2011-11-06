/*
 *  linux/init/main.c
 *
 *  (C) 1991  Linus Torvalds
 */

#define __LIBRARY__	/* 为了包括unistd.h中的内嵌汇编代码等信息 */
#include <unistd.h>
#include <time.h>	/* 定义了tm结构和一些有关时间的函数原型 */

/*
 * we need this inline - forking from kernel space will result
 * in NO COPY ON WRITE (!!!), until an execve is executed. This
 * is no problem, but for the stack. This is handled by not letting
 * main() use the stack at all after fork(). Thus, no function
 * calls - which means inline code for fork too, as otherwise we
 * would use the stack upon exit from 'fork()'.
 *
 * Actually only pause and fork are needed inline, so that there
 * won't be any messing with the stack from main(), but we define
 * some others too.
 */
/*
 * Linux在内核空间创建进程时不使用写时复制技术. main()在移动到用户模式(到任务0)后执行内嵌
 * 方式的fork()和pause()，因此可以保证不使用任务0的用户栈。在执行move_to_user_mode()之后，
 * 本程序main()就以任务0的身份在运行了。而任务0是所有将创建子进程的父进程。当它创建一个子
 * 进程时(init进程)，由于任务1代码属于内核空间，因此没有使用写时复制功能。此时任务0的用户
 * 栈就是任务1的用户栈，即它们共同使用一个栈空间。因此希望在main.c运行在任务0的环境下时不要
 * 有对堆栈的任何操作，以免弄乱堆栈。而在再次执行fork()并执行过execve()函数后，被加载程序
 * 已不属于内核空间，因此可以使用写时复制技术。
 */
/*
 * 定义在unistd.h中，内联函数，不会操作堆栈，0表示没有参数，1表示有一个参数。
 * 通过内联汇编的形式调用Linux的中断0x80，该中断是所有系统调用的入口
 */
static inline _syscall0(int,fork)		/* int fork(void)系统调用：创建进程 */
static inline _syscall0(int,pause)		/* int pause(void)系统调用：暂停进程的执行，直到收到一个信号 */
static inline _syscall1(int,setup,void *,BIOS)	/* int setup(void * BIOS)系统调用：仅用于Linux初始化(仅在这个程序中被调用) */
static inline _syscall0(int,sync)		/* int sync(void)系统调用：更新文件系统 */

#include <linux/tty.h>		/* 定义了有关tty_io，串行通信方面的参数、常数 */
#include <linux/sched.h>	/* 调度程序头文件，定义了任务结构task_struct、第一个初始任务的数据。 */
#include <linux/head.h>		/* 定义了段描述符的简单结构，和几个选择符常量 */
#include <asm/system.h>		/* 系统头文件，定义了许多有关设置或修改描述符/中断门等的嵌入式汇编子程序 */
#include <asm/io.h>		/* 定义了对io端口操作的函数 */

#include <stddef.h>		/* 定义了NULL，offsetof(TYPE,MEMBER) */
#include <stdarg.h>		/* 定义了变量参数列表，主要说明了一个类型(va_list)和三个宏(va_start, va_arg和va_end) */
#include <unistd.h>
#include <fcntl.h>		/* 用于文件及其描述符的操作控制常数符号的定义 */
#include <sys/types.h>		/* 定义了基本的系统数据类型 */

#include <linux/fs.h>		/* 定义文件表结构(file, buffer_head, m_inode等)，其中有定义: extern int ROOT_DEV */

#include <string.h>		/* 定义了一些关于内存或字符串操作的函数 */

static char printbuf[1024];	/* 用作内核显示信息的缓存 */

extern char *strcpy();
extern int vsprintf();			/* 格式化输出到一字符串中 */
extern void init(void);			/* 初始化 */
extern void blk_dev_init(void);		/* 块设备初始化 */
extern void chr_dev_init(void);		/* 字符设备初始化 */
extern void hd_init(void);		/* 硬盘初始化 */
extern void floppy_init(void);		/* 软驱初始化 */
extern void mem_init(long start, long end);	/* 内存管理初始化 */
extern long rd_init(long mem_start, int length);	/* 虚拟盘初始化 */
extern long kernel_mktime(struct tm * tm);		/* 计算系统开机启动时间(秒) */

/* 内核专用sprintf函数。该函数用于产生格式化信息并输出到指定缓冲区str中 */
static int sprintf(char * str, const char *fmt, ...)
{
	va_list args;
	int i;

	va_start(args, fmt);
	i = vsprintf(str, fmt, args);
	va_end(args);
	return i;
}

/*
 * This is set up by the setup-routine at boot-time
 */
/*
 * 以下数据是在setup.S中设置的
 * */
#define EXT_MEM_K (*(unsigned short *)0x90002)			/* 1M以后扩展内存的大小 */
#define CON_ROWS ((*(unsigned short *)0x9000e) & 0xff)		/* 选定的控制台屏幕行数 */
#define CON_COLS (((*(unsigned short *)0x9000e) & 0xff00) >> 8)	/* 选定的控制台屏幕列数 */
#define DRIVE_INFO (*(struct drive_info *)0x90080)		/* 硬盘参数表32字节内容, 见setup.S里面Get hd0 data */
#define ORIG_ROOT_DEV (*(unsigned short *)0x901FC)		/* 根文件系统所在的设备号 */
#define ORIG_SWAP_DEV (*(unsigned short *)0x901FA)		/* 交换文件所在的设备号 */

/*
 * Yeah, yeah, it's ugly, but I cannot find how to do this correctly
 * and this seems to work. I anybody has more info on the real-time
 * clock I'd be interested. Most of this was trial and error, and some
 * bios-listing reading. Urghh.
 */
/* 读取CMOS实时时钟信息
 * 0x70是写地址端口号,
 * 0x80 | addr是要读取的CMOS内存地址
 * 0x71是读数据端口号
 */
#define CMOS_READ(addr) ({ \
outb_p(0x80|addr,0x70); \
inb_p(0x71); \
})
/* 将BCD码转换成二进制数值. BCD码用4位表示一个10进制数.
 * val&15是取个位，右移动4位后拿到十位值，再乘以10和个位相加得到二进制值.
 * 例如0x89就是二进制的89
 */
#define BCD_TO_BIN(val) ((val)=((val)&15) + ((val)>>4)*10)

/*
 * 读取CMOS时钟信息作为开机时间，并保存到全局变量startup_time(秒)中。其中kernel_mktime()用于计算
 * 从1970年1月1日0时起到开机当日经过的秒数，作为开机时间。
 */
static void time_init(void)
{
	struct tm time;

	do {
		time.tm_sec = CMOS_READ(0);	/* 当前时间秒值, 所有的值都是BCD码 */
		time.tm_min = CMOS_READ(2);	/* 当前时间分钟值 */
		time.tm_hour = CMOS_READ(4);	/* 当前小时值 */
		time.tm_mday = CMOS_READ(7);	/* 一个月中的当天日期 */
		time.tm_mon = CMOS_READ(8);	/* 当前的月份 */
		time.tm_year = CMOS_READ(9);	/* 当前的年份 */
	} while (time.tm_sec != CMOS_READ(0));	/* 因为CMOS访问比较慢，读取了CMOS中的所有值后，
						 * 如果发现秒值发生了变化，则重新读取，这样将时间误差控制在1秒内
						 */
	BCD_TO_BIN(time.tm_sec);		/* 转换成二进制数 */
	BCD_TO_BIN(time.tm_min);
	BCD_TO_BIN(time.tm_hour);
	BCD_TO_BIN(time.tm_mday);
	BCD_TO_BIN(time.tm_mon);
	BCD_TO_BIN(time.tm_year);
	time.tm_mon--;				/* tm_mon中的月份范围为0-11 */
	startup_time = kernel_mktime(&time);	/* 计算开机时间, 从1970年1月1日0时起到开机当日经过的秒数 */
}

static long memory_end = 0;		/* 机器具有的物理内存的容量(字节数) */
static long buffer_memory_end = 0;	/* 高速缓冲区的末端地址 */
static long main_memory_start = 0;	/* 主内存(将用于分页) */
static char term[32];			/* 终端设置字符串(环境参数) */

/* 读取并执行/etc/rc文件时所使用的命令行参数和环境变量 */
static char * argv_rc[] = { "/bin/sh", NULL };		/* 调用执行程序时参数的字符串数组 */
static char * envp_rc[] = { "HOME=/", NULL ,NULL };	/* 调用执行程序时参数的字符串数组 */

/* 运行登录shell时所使用的命令行参数和环境变量 */
static char * argv[] = { "-/bin/sh",NULL };		/* - 是传给shell程序sh的一个标志。通过识别这个标志，sh程序会
							 * 作为登录shell执行，其执行过程与在shell提示符下执行sh不一样
							 */
static char * envp[] = { "HOME=/usr/root", NULL, NULL };

struct drive_info { char dummy[32]; } drive_info;	/* 用于存放硬盘参数表信息 */

/*  内核初始化主程序，初始化结束后将以任务0(idle任务即空闲任务)的身份运行。  */
void main(void)		/* This really IS void, no error here. */
{			/* The startup routine assumes (well, ...) this */
/*
 * Interrupts are still disabled. Do necessary setups, then
 * enable them
 */
	/* 此时中断仍被禁止着，做完必要的设置后就将其打开 */
	/*
	 * 首先保存根文件系统设备号和交换文件设备号，并根据setup.s程序中获取的信息设置控制台终端屏幕行、列
	 * 数环境变量TERM，并用其设置初始init进程中执行etc/rc文件和shell程序使用的环境变量，以及复制内存
	 * 0x90080处的硬盘参数表.
	 * 其中ROOT_DEV已在前面包含进的include/linux/fs.h文件上被声明为extern int，而SWAP_DEV在include/linux/mm.h
	 * 文件内也作了相同的声明。这里mm.h文件并没有显示的列在程序的前部，因为include/linux/sched.h文件中已经包含了
	 */
	ROOT_DEV = ORIG_ROOT_DEV;	/* fs/super.c中定义 */
	SWAP_DEV = ORIG_SWAP_DEV;	/* mm/swap.c中定义 */
	sprintf(term, "TERM=con%dx%d", CON_COLS, CON_ROWS);
	envp[1] = term;	
	envp_rc[1] = term;
	drive_info = DRIVE_INFO;	/* 复制内存0x90080处的硬盘参数表 */
	/* 根据机器物理内存容量设置高速缓冲区和主内存区的位置和范围。
	 * 高速缓存末端地址->buffer_memory_end; 机器内存容量->memory_end; 主内存开始地址->main_memory_start */
	memory_end = (1<<20) + (EXT_MEM_K<<10);	/* 内存大小=1MB+扩展内存大小(MB) */
	memory_end &= 0xfffff000;		/* 忽略不到4KB的内存数 */
	if (memory_end > 16*1024*1024)		/* 如果内存超过16MB，则按16MB计 */
		memory_end = 16*1024*1024;
	if (memory_end > 12*1024*1024)		/* 如果内存大于12MB，则设置缓冲区末端=4MB */
		buffer_memory_end = 4*1024*1024;
	else if (memory_end > 6*1024*1024)	/* 否则若内存>6MB，则设置缓冲区末端=2MB */
		buffer_memory_end = 2*1024*1024;
	else
		buffer_memory_end = 1*1024*1024;/* 否则设置缓冲区末端 = 1MB */
	main_memory_start = buffer_memory_end;	/* 主内存起始地址 = 缓冲区末端 */
#ifdef RAMDISK
	/* 如果在Makefile文件中定义了内存虚拟盘符号RAMDISK, 则初始化虚拟盘, 此时主内存将减少 */
	main_memory_start += rd_init(main_memory_start, RAMDISK*1024);
#endif
	/* 主内存区初始化 */
	mem_init(main_memory_start,memory_end);
	/* 陷阱门(硬件中断向量)初始化 */
	trap_init();
	/* 块设备初始化 */
	blk_dev_init();
	/* 字符设备初始化 */
	chr_dev_init();
	/* tty初始化 */
	tty_init();
	/* 设置开机启动时间 */
	time_init();
	/* 调度程序初始化(加载任务0的tr, ldtr) */
	sched_init();
	/* 缓冲管理初始化, 建内存链表等 */
	buffer_init(buffer_memory_end);
	/* 硬盘初始化 */
	hd_init();
	/* 软驱初始化 */
	floppy_init();
	/* 所有初始化工作都结束了，于是开启中断 */
	sti();
	/* 下面过程通过在堆栈中设置的参数，利用中断返回指令启动任务0执行 */
	move_to_user_mode();	/* 移动到用户模式下执行 */
	if (!fork()) {		/* we count on this going ok */
		init();		/* 在新建的子进程(任务1即init进程)中执行 */
	}
	/* 下面代码开始以任务0的身份运行 */
/*
 *   NOTE!!   For any other task 'pause()' would mean we have to get a
 * signal to awaken, but task0 is the sole exception (see 'schedule()')
 * as task 0 gets activated at every idle moment (when no other tasks
 * can run). For task0 'pause()' just means we go check if some other
 * task can run, and if not we return here.
 */
/*
 * 对于任何其他的任务，pause()意味着我们必须等待收到一个信号才会返回就绪状态，但任务0(task0)是唯一
 * 例外情况，因为任务0在任何空闲时间里都会被激活(当没有其他任务在运行时)，因为对于任务0，pause()仅
 * 意味着我们返回来查看是否有其他任务可以运行，如果没有的话我们就回到这里，一直循环执行pause();
 * pause()系统调用会把任务0转换成可中断等待状态，再执行调度函数。但是调度函数只要发现系统中没有其他任务
 * 可以运行时就会切换到任务0，而不依赖与任务0的状态。
 */
	for(;;)
		__asm__("int $0x80"::"a" (__NR_pause):"ax");
}

/*
 * 下面函数产生格式化信息并输出到标准输出设备stdout(1), 这里是指屏幕上显示
 * vsprintf将格式化的字符串放入printbuf缓冲区,然后用write()将缓冲区的内容输出到标准设备(1--stdout)
 * */
static int printf(const char *fmt, ...)
{
	va_list args;
	int i;

	va_start(args, fmt);
	write(1,printbuf,i=vsprintf(printbuf, fmt, args));
	va_end(args);
	return i;
}

/*
 * 在main()中已经进行了系统初始化，包括内存管理、各种硬件设备和驱动程序。init()函数运行在任务0第1次
 * 创建的子进程(任务1)中。它首先对第一个将要执行的程序(shell)的环境进行初始化，然后以登录shell方式
 * 加载该程序并执行之。
 */
void init(void)
{
	int pid,i;
	/* setup是一个系统调用。用于读取硬盘参数包括分区表信息并加载虚拟盘(若存在的话)和安装根文件系统 */
	setup((void *) &drive_info);
	/* 下面以读写访问方式打开设备/dev/tty1, 他对应终端控制台。由于这是第一次打开文件操作，因此产生的
	 * 文件句柄号(文件描述符)肯定是0. 该句柄是UNIX类操作系统默认的控制台标准输入句柄stdin。这里再把
	 * 它以读和写的方式分别打开是为了复制产生标准输出(写)句柄stdout和标准出错句柄stderr。函数前面的
	 * void前缀用于表示强制函数无需返回值 */
	(void) open("/dev/tty1",O_RDWR,0);
	(void) dup(0);	/* 复制句柄，产生句柄1号--stdout标准输出设备 */
	(void) dup(0);	/* 复制句柄，产生句柄2号--stderr标准出错输出设备 */
	/* 打印缓冲区块数和总字节数，每块1024字节，以及主内存区空闲内存字节数 */
	printf("%d buffers = %d bytes buffer space\n\r",NR_BUFFERS,
		NR_BUFFERS*BLOCK_SIZE);
	printf("Free mem: %d bytes\n\r",memory_end-main_memory_start);
	/* 下面fork用于创建一个子进程(任务2).对于被创建的子进程，fork()将返回0值，对于原进程(父进程)则返回
	 * 子进程号pid.  */
	if (!(pid=fork())) {
	/* 子进程，关闭了句柄0(stdin)、以只读方式打开/etc/rc文件，并使用execve()函数将进程自身替换成/bin/sh
	 * 程序(即shell), 然后执行/bin/sh程序，所携带的参数和环境变量分别由argv_rc和envp_rc数组给出。关闭句柄
	 * 0并立刻打开/etc/rc文件的作用是把标准输入stdin重定向到/etc/rc文件。这样shell程序/bin/sh就可以运行rc
	 * 文件中设置的命令，由于这里sh的运行方式是非交互式的，因此在执行完rc文件中的命令后就会立刻退出，进程
	 * 2也随之结束。_exit()退出时的错误码1-操作未许可，2-文件或目录不存在 */
		close(0);
		if (open("/etc/rc",O_RDONLY,0))
			_exit(1);
		execve("/bin/sh",argv_rc,envp_rc);
		_exit(2);
	}
	if (pid>0)	/* 父进程. wait等待子进程停止或终止，返回值应是子进程的进程号pid。i返回的时子进程的进程号 */
		while (pid != wait(&i))		/* 如果返回值不等于子进程号，则继续等待 */
			/* nothing */;
	/* 如果执行到这里，说明刚创建的子进程的执行已停止或终止了。下面循环中首先再创建一个子进程，如果出错，则显示
	 * "初始化程序创建子进程失败"信息并继续执行。对于所创建的子进程将关闭所有以前还遗留的句柄(stdin, stdout, stderr)
	 * 新创建一个会话并设置进程组号，然后重新打开/dev/tty1作为stdin，并复制成stdout和stderr。再次执行系统解释程序/bin/sh.
	 * 但这次执行所选用的参数和环境数组另选了一套。然后父进程再次运行wait()等待。如果子进程又停止了执行，则在标准输出上
	 * 显示出错信息"子进程pid停止了运行，返回码是i"，然后继续重试下去...，形成"大"死循环 */
	while (1) {
		if ((pid=fork())<0) {
			printf("Fork failed in init\r\n");
			continue;
		}
		if (!pid) {		/* 新的子进程 */
			close(0);close(1);close(2);
			setsid();	/* 创建一新的会话期 */
			(void) open("/dev/tty1",O_RDWR,0);
			(void) dup(0);
			(void) dup(0);
			_exit(execve("/bin/sh",argv,envp));
		}
		while (1)
			if (pid == wait(&i))
				break;
		printf("\n\rchild %d died with code %04x\n\r",pid,i);
		sync();		/* 同步操作，刷新缓冲区 */
	}
	_exit(0);	/* NOTE! _exit, not exit()，注意是_exit，而不是exit。他们都用于正常终止一个函数。但_exit()直接是一个
			 * sys_exit系统调用，而exit()则通常是普通函数库中的一个函数。他会先执行一些清除操作，例如调用执行各
			 * 终止处理程序、关闭所有标准IO等，然后调用sys_exit */
}
