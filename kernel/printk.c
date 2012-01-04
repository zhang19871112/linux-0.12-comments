/*
 *  linux/kernel/printk.c
 *
 *  (C) 1991  Linus Torvalds
 */

/*
 * When in kernel-mode, we cannot use printf, as fs is liable to
 * point to 'interesting' things. Make a printf with fs-saving, and
 * all is well. 当处于内核模式时，我们不能使用printf，因为寄存器fs 指向
 * 其它不感兴趣的地方。自己编制一个printf 并在使用前保存fs，一切就解决了
 */
#include <stdarg.h>
#include <stddef.h>

#include <linux/kernel.h>

static char buf[1024];	/* 显示用临时缓冲区 */

/* 函数vsprintf()在linux/kernel/vsprintf.c 中92 行开始 */
extern int vsprintf(char * buf, const char * fmt, va_list args);

/* 内核使用的显示函数 */
int printk(const char *fmt, ...)
{
	va_list args;	/* va_list 实际上是一个字符指针类型 */
	int i;
	/* 运行参数处理开始函数。然后使用格式串fmt将参数列表args输出到buf中.
	 * 返回值i等于输出字符串的长度. 再运行参数处理结束函数. 最后调用控制
	 * 台显示函数并返回显示字符数 */
	va_start(args, fmt);
	i=vsprintf(buf,fmt,args);
	va_end(args);
	console_print(buf);	/* chr_drv/console.c */
	return i;
}
