!
! SYS_SIZE is the number of clicks (16 bytes) to be loaded.
! 0x3000 is 0x30000 bytes = 196kB, more than enough for current
! versions of linux
!
#include <linux/config.h>
SYSSIZE = DEF_SYSSIZE	!大小为0x3000
!
!	bootsect.s		(C) 1991 Linus Torvalds
!	modified by Drew Eckhardt
!
! bootsect.s is loaded at 0x7c00 by the bios-startup routines, and moves
! iself out of the way to address 0x90000, and jumps there.
!
! It then loads 'setup' directly after itself (0x90200), and the system
! at 0x10000, using BIOS interrupts. 
!
! NOTE! currently system is at most 8*65536 bytes long. This should be no
! problem, even in the future. I want to keep it simple. This 512 kB
! kernel size should be enough, especially as this doesn't contain the
! buffer cache as in minix
!
! The loader has been made as simple as possible, and continuos
! read errors will result in a unbreakable loop. Reboot by hand. It
! loads pretty fast by getting whole sectors at a time whenever possible.

.globl begtext, begdata, begbss, endtext, enddata, endbss
.text
begtext:
.data
begdata:
.bss
begbss:
.text

SETUPLEN = 4				! nr of setup-sectors
BOOTSEG  = 0x07c0			! original address of boot-sector
INITSEG  = DEF_INITSEG			! we move boot here - out of the way, 0x9000, 左移4位后为0x90000, 576KB
SETUPSEG = DEF_SETUPSEG			! setup starts here, 0x9020, 左移4位后为0x90200, 576.5KB
SYSSEG   = DEF_SYSSEG			! system loaded at 0x10000 (65536). 0x1000, 左移4位后为0x10000, 64KB
ENDSEG   = SYSSEG + SYSSIZE		! where to stop loading. 0x1000:0x3000

! ROOT_DEV & SWAP_DEV are now written by "build".
ROOT_DEV = 0
SWAP_DEV = 0

entry start
start:
	mov	ax, #BOOTSEG
	mov	ds, ax
	mov	ax, #INITSEG
	mov	es, ax
	mov	cx, #256
	sub	si, si
	sub	di, di
	! 将0x7c0:0的512字节移动到0x9000:0处, 并跳到那里执行
	! 开机后BIOS会把第一个扇区512字节的内容读取到0x7c0:0处执行
	rep
	movw
	jmpi	go, INITSEG

go:	mov	ax, cs
	mov	dx, #0xfef4	! arbitrary value >>512 - disk parm size
	! 将ds, es和ss都设置成为0x9000(jmpi指令会改变cs的值)
	mov	ds, ax
	mov	es, ax
	push	ax

	mov	ss, ax		! put stack at 0x9ff00 - 12.
	mov	sp, dx
/*
 *	Many BIOS's default disk parameter tables will not 
 *	recognize multi-sector reads beyond the maximum sector number
 *	specified in the default diskette parameter tables - this may
 *	mean 7 sectors in some cases.
 *
 *	Since single sector reads are slow and out of the question,
 *	we must take care of this by creating new parameter tables
 *	(for the first disk) in RAM.  We will set the maximum sector
 *	count to 18 - the most we will encounter on an HD 1.44.  
 *
 *	High doesn't hurt.  Low does.
 *
 *	Segments are as follows: ds=es=ss=cs - INITSEG,
 *		fs = 0, gs = parameter table segment
 */

	! BISO设置的中断0x1E的中断向量表值是软驱参数表地址. 该向量值位于内存
	! 0x1E*4=0x78处. 一下代码复制原软驱参数表到0x9000:0xfef4处, 然后修改
	! 表中的每磁道最大扇区数为18
	push	#0
	pop	fs
	mov	bx, #0x78		! fs:bx is parameter table address
	seg fs
	lgs	si, (bx)			! gs:si is source
	! dx=0xfef4
	mov	di, dx			! es:di is destination
	mov	cx, #6			! copy 12 bytes
	cld

	rep
	seg gs
	movw
	! 修改软驱参数表最大扇区数为18
	mov	di, dx
	movb	4(di), *18		! patch sector count

	! 把di和es的值(0x9000:0xfef4)的内容放到bx指向的内存处, 即0x0:0x78
	seg fs
	mov	(bx), di
	seg fs
	mov	2(bx), es

	pop	ax
	mov	fs, ax
	mov	gs, ax
	! 磁盘系统复位中断, 让其采用新的参数. dl=0 第一个软驱
	xor	ah, ah			! reset FDC
	xor	dl, dl
	int 	0x13	

! load the setup-sectors directly after the bootblock.
! Note that 'es' is already set up.

load_setup:
	! 用0x13号中断的2号功能(读扇区)将setup读到es:bx处
	!
	! AL:扇区数, CH:柱面数, CL:扇区数, DH: 磁头, DL:驱动器, 00h~7fh为软盘, 80h~ffh为硬盘
	! SETUPLEN = 4
	! 以下将0号软盘的0磁头, 0磁道, 2扇区开始的4个扇区读取到0x9000:0x200处
	xor	dx, dx			! drive 0, head 0
	mov	cx, #0x0002		! sector 2,track 0
	mov	bx, #0x0200		! address = 512,in INITSEG
	mov	ax, #0x0200+SETUPLEN	! service 2,nr of sectors
	int	0x13			! read it
	! CF等于0, 操作成功, AH=0, AL=传输的扇区数
	jnc	ok_load_setup		! ok - continue

	! 操作失败, AH保存了状态码
	push	ax			! dump error code
	call	print_nl		! 打印出错码
	mov	bp, sp
	call	print_hex
	pop	ax	
	
	xor	dl, dl			! 复位软驱, 重试
	xor	ah, ah
	int	0x13
	j	load_setup

ok_load_setup:

! Get disk drive parameters, specifically nr of sectors/track
! 功能描述：读取驱动器参数
! 入口参数：AH＝08H
! DL＝驱动器, 00H~7FH：软盘; 80H~0FFH：硬盘
! 出口参数：CF＝1——操作失败, AH＝状态代码, 参见功能号01H中的说明,否则， BL＝01H — 360K
! ＝02H — 1.2M
! ＝03H — 720K
! ＝04H — 1.44M
! CH＝柱面数的低8位
! CL的位7-6＝柱面数的高2位
! CL的位5-0＝扇区数
! DH＝磁头数
! DL＝驱动器数
! ES:DI＝磁盘驱动器参数表地址
	xor	dl, dl			! 驱动器0
	mov	ah, #0x08		! AH=8 is get drive parameters
	int	0x13
	xor	ch, ch			! 不需要获得柱面数
	seg cs
	mov	sectors, cx		! 获得扇区数,保存起来
	mov	ax, #INITSEG
	mov	es, ax			! es=0x9000

! Print some inane message
! 功能描述：在文本坐标下, 读取光标各种信息
! 入口参数：AH＝03H
! BH＝显示页码
! 出口参数：CH＝光标的起始行
! CL＝光标的终止行
! DH＝行(Y坐标)
! DL＝列(X坐标)
	mov	ah, #0x03		! read cursor pos
	xor	bh, bh
	int	0x10
! 功能描述：在Teletype模式下显示字符串
! 入口参数：AH＝13H
! BH＝页码
! BL＝属性(若AL=00H或01H)
! CX＝显示字符串长度
! (DH、DL)＝坐标(行、列)
! ES:BP＝显示字符串的地址 AL＝显示输出方式
! 0——字符串中只含显示字符, 其显示属性在BL中.显示后，光标位置不变
! 1——字符串中只含显示字符, 其显示属性在BL中.显示后，光标位置改变
! 2——字符串中含显示字符和显示属性.显示后, 光标位置不变
! 3——字符串中含显示字符和显示属性.显示后, 光标位置改变
! 出口参数：无
! 显示"Loading"字符串, 输出后光标位置改变, msg1一开始为CR和LF,所以总共为9个
	mov	cx, #9
	mov	bx, #0x0007		! page 0,attribute 7 (normal)
	mov	bp, #msg1
	mov	ax, #0x1301		! write string,move cursor
	int	0x10

! ok, we've written the message, now
! we want to load the system (at 0x10000)
! 加载system到0x10000(64K处)
	mov	ax, #SYSSEG
	mov	es, ax		! segment of 0x010000
	call	read_it
	call	kill_motor	! 关闭驱动器马达, 这样就可以知道驱动器的状态了
	call	print_nl	! 回车

! After that we check which root-device to use. If the device is
! defined (!= 0), nothing is done and the given device is used.
! Otherwise, either /dev/PS0 (2,28) or /dev/at0 (2,8), depending
! on the number of sectors that the BIOS reports currently.
! root_dev是通过build工具写到508和509字节处的, 用来告诉系统用哪个根文件系统设备,
! 如果已经指定了设备(!=0), 就直接使用给定的设备. 否则就需要根据BIOS报告的每磁道
! 扇区数来确定到底使用/dev/PS0(2, 28),还是/dev/at0(2,8)
! linux中软驱的主设备号为2, 次设备号=type*4+nr，其中nr为0-3分别对应软驱A,B,C,D;
! type是软驱的类型(2->1.2MB或7->1.44MB等), 因为7*4+0=28，所以/dev/PS0(2,28)指的
! 是1.44MB A驱动器, 其设备号是0x021c,同理/dev/at0(2,8)指的是1.2MB A驱动器,设备
! 号为0x0208
	seg cs
	mov	ax, root_dev
	or	ax, ax
	jne	root_defined
	seg cs
	mov	bx, sectors
	mov	ax, #0x0208		! /dev/ps0 - 1.2Mb
	cmp	bx, #15
	je	root_defined
	mov	ax, #0x021c		! /dev/PS0 - 1.44Mb
	cmp	bx, #18
	je	root_defined
undef_root:
	jmp undef_root
root_defined:
	seg cs
	mov	root_dev, ax

! after that (everyting loaded), we jump to
! the setup-routine loaded directly after
! the bootblock:
! 跳转到0x9020:0处运行, 即从软盘load进来的setup
	jmpi	0, SETUPSEG

! This routine loads the system at address 0x10000, making sure
! no 64kB boundaries are crossed. We try to load it as fast as
! possible, loading whole tracks whenever we can.
!
! in:	es - starting address segment (normally 0x1000)
!
sread:	.word 1+SETUPLEN	! sectors read of current track
head:	.word 0			! current head
track:	.word 0			! current track

read_it:
	mov ax, es
	test ax, #0x0fff	! test以位逻辑与两个操作数, 影响ZF位
				! es为0x1000, 上述执行后结果为0, ZF置位, jne条件不成立
die:	jne die			! es must be at 64kB boundary, 否则死循环
	xor bx, bx		! bx is starting address within segment, es:bx为目标地址即0x1000:0
rp_read:
	mov ax, es
	cmp ax, #ENDSEG		! have we loaded all yet? ENDSEG=0x1000:0x3000
	jb ok1_read
	ret
ok1_read:
	seg cs
	mov ax, sectors
	sub ax, sread
	mov cx, ax
	shl cx, #9
	add cx, bx
	jnc ok2_read
	je ok2_read
	xor ax, ax
	sub ax, bx
	shr ax, #9
ok2_read:
	call read_track
	mov cx, ax
	add ax, sread
	seg cs
	cmp ax, sectors
	jne ok3_read
	mov ax, #1
	sub ax, head
	jne ok4_read
	inc track
ok4_read:
	mov head, ax
	xor ax, ax
ok3_read:
	mov sread, ax
	shl cx, #9
	add bx, cx
	jnc rp_read
	mov ax, es
	add ah, #0x10
	mov es, ax
	xor bx, bx
	jmp rp_read

read_track:
	pusha
	pusha	
	mov	ax, #0xe2e 	! loading... message 2e = .
	mov	bx, #7
 	int	0x10
	popa		

	mov dx, track
	mov cx, sread
	inc cx
	mov ch, dl
	mov dx, head
	mov dh, dl
	and dx, #0x0100
	mov ah, #2
	
	push	dx				! save for error dump
	push	cx
	push	bx
	push	ax

	int 0x13
	jc bad_rt
	add	sp, #8   	
	popa
	ret

bad_rt:	push	ax				! save error code
	call	print_all			! ah = error, al = read
	
	
	xor ah, ah
	xor dl, dl
	int 0x13
	

	add	sp, #10
	popa	
	jmp read_track

/*
 *	print_all is for debugging purposes.  
 *	It will print out all of the registers.  The assumption is that this is
 *	called from a routine, with a stack frame like
 *	dx 
 *	cx
 *	bx
 *	ax
 *	error
 *	ret <- sp
 *
*/
 
print_all:
	mov	cx, #5		! error code + 4 registers
	mov	bp, sp	

print_loop:
	push	cx		! save count left
	call	print_nl	! nl for readability
	jae	no_reg		! see if register name is needed
	
	mov	ax, #0xe05 + 0x41 - 1
	sub	al, cl
	int	0x10

	mov	al, #0x58 	! X
	int	0x10

	mov	al, #0x3a 	! :
	int	0x10

no_reg:
	add	bp, #2		! next register
	call	print_hex	! print it
	pop	cx
	loop	print_loop
	ret

! 0x10中断的0xe功能: 用电传模式下显示字符, AL:字符, BH为页码, BL为前景色(图形模式)
! 回车(CR)和换行(LF)符都是用来表示"下一行"的. 而标准没有规定要使用哪一个. 于是产生了三种
! 不同的用法: Dos和windows采用回车换行(CR+LF)表示下一行(亦即所谓的PC格式). UNIX采用换行符
! (LF)表示下一行, MAC机采用回车符(CR)表示下一行. 当在不同的系统间传递文件, 就要涉及格式的转换
! 電報機每當打印到一行結尾時便需要「跳進下一行」並「回到第一格」, 因此ASCII有LF(Line Feed, 0×0A)
! 和CR(Carriage Return, 0×0D). 在電腦的世其實並不需要用兩個字符代表「下一行」的意思, 為了省資源,
! 在設計OS時一些人就決定用其中一個字符代表「下一行」1, 因為大家選擇不同, 造成了不同系統的「下一行」
! 符號不同的問題.
! 回车
print_nl:
	mov	ax, #0xe0d	! CR
	int	0x10
	mov	al, #0xa	! LF回车
	int 	0x10
	ret

/*
 *	print_hex is for debugging purposes, and prints the word
 *	pointed to by ss:bp in hexadecmial.
*/

print_hex:
	mov	cx, #4		! 4 hex digits
	mov	dx, (bp)	! load word into dx
print_digit:
	rol	dx, #4		! rotate so that lowest 4 bits are used
	mov	ah, #0xe	
	mov	al, dl		! mask off so we have only next nibble
	and	al, #0xf
	add	al, #0x30	! convert to 0 based digit, '0'
	cmp	al, #0x39	! check for overflow
	jbe	good_digit
	add	al, #0x41 - 0x30 - 0xa 	! 'A' - '0' - 0xa

good_digit:
	int	0x10
	loop	print_digit
	ret


/*
 * This procedure turns off the floppy drive motor, so
 * that we enter the kernel in a known state, and
 * don't have to worry about it later.
 */
kill_motor:
	push dx
	mov dx, #0x3f2
	xor al, al
	outb
	pop dx
	ret

sectors:
	.word 0

msg1:
	.byte 13, 10
	.ascii "Loading"

.org 506
swap_dev:
	.word SWAP_DEV
root_dev:
	.word ROOT_DEV
boot_flag:
	.word 0xAA55

.text
endtext:
.data
enddata:
.bss
endbss:

