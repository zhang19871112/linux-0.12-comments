/*
 *  linux/kernel/panic.c
 *
 *  (C) 1991  Linus Torvalds
 */

/*
 * This function is used through-out the kernel (includeinh mm and fs)
 * to indicate a major problem.
 */
#include <linux/kernel.h>
#include <linux/sched.h>

void sys_sync(void);	/* it's really int */

/* 该函数用来显示内核中出现的重大错误信息，并运行文件系统同步函数，然后
 * 进入死循环 -- 死机.
 * 如果当前进程是任务0 的话，还说明是交换任务出错，并且还没有运行文件系统同步函数
 * 函数名前的关键字volatile用于告诉编译器gcc该函数不会返回。这样可让gcc产生更好一些
 * 的代码，更重要的是使用这个关键字可以避免产生某些(未初始化变量的)假警告信息.
 * 等同于现在gcc的函数属性说明：void panic(const char *s) __attribute__((noreturn)); */
volatile void panic(const char * s)
{
	printk("Kernel panic: %s\n\r",s);
	if (current == task[0])
		printk("In swapper task - not syncing\n\r");
	else
		sys_sync();
	for(;;);
}
